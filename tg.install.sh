#!/bin/bash
# ===== MTProxy Docker 管理脚本 =====
# 基于 webbrain-one/MTProxy 项目 Docker 化
# 双引擎: telemt (Rust, 默认) + mtg-go (Go, 回退)
# 支持: 多用户/流量配额/到期时间/带宽限速/专属端口

set -Ee

# ---------- 链接 secret 工具 ----------
# MTProto tg://proxy?secret= 的值必须是:
#   完整字节串 (0xEE + 16字节密钥 + 域名字节) 的 Base64URL 编码
# Base64URL: 去 = 填充, + → -, / → _
encode_proxy_secret_b64url() {
    local secret_32hex="$1"
    local domain="$2"
    local full="ee${secret_32hex}"
    local hex_bytes=""
    local i=0
    while [ "$i" -lt ${#full} ]; do
        hex_bytes="${hex_bytes}\\x${full:$i:2}"
        i=$((i + 2))
    done
    { printf '%b' "$hex_bytes"; printf '%s' "$domain"; } \
        | base64 -w0 2>/dev/null \
        | tr -d '\r\n' \
        | sed 's/=*$//; y/+\//-_/'
}

# ---------- 内网 IP 判定 ----------
is_private_ip() {
    local s="$1"
    [ -z "$s" ] && return 0
    case "$s" in
        10.*)                     return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        192.168.*)                return 0 ;;
        127.*)                    return 0 ;;
        169.254.*)                return 0 ;;
        0.*)                      return 0 ;;
        ::1|fe80:*|fc*:*|fd*:*)   return 0 ;;
        *)                        return 1 ;;
    esac
}

# ---------- 链接有效性过滤: 内网 IP 丢弃 / secret=纯 hex 丢弃 ----------
# 输入: 一条 tg:// 或 https://t.me/ proxy 链接
# 输出: 干净链接 / 空 (表示应丢弃)
filter_valid_proxy_link() {
    local link="$1"
    [ -z "$link" ] && return
    server=$(echo "$link" | sed -E 's/^.*[?&]server=([^&#]+).*$/\1/')
    secret=$(echo "$link" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/')
    [ -z "$secret" ] && return
    # 1) 内网 server 直接丢弃
    is_private_ip "$server" && return
    # 2) 纯 hex 或 只有 0-9a-f 的 secret 丢弃(应为 Base64URL,含 A-Z 或 - 或 _)
    if [[ "$secret" =~ ^[0-9a-fA-F]{30,}$ ]]; then
        return
    fi
    # 3) 必须含 Base64URL 特征(长度>=20,只能含 A-Za-z0-9_-)
    if [[ "$secret" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
        echo "$link"
    fi
}

# ---- 颜色 ----
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue()   { echo -e "\033[34m$*\033[0m"; }
cyan()   { echo -e "\033[36m$*\033[0m"; }

IMAGE_NAME="shidahuilang/mtg"
CONTAINER_NAME="mtg"
DATA_DIR="/root/mtg_data"
DEFAULT_DOMAIN="www.apple.com"

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_username() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]
}

# ---- 检查 Docker ----
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        red "❌ 未检测到 Docker,请先安装: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        red "❌ Docker 服务未运行或当前用户无权访问 Docker"
        exit 1
    fi
}

# ---- 获取公网 IP ----
get_public_ip() {
    local ip=""
    # 三个探测源串行时最多会阻塞 15 秒；安装时只需要尽快拿到一个地址
    ip=$(curl -4 -fsS --connect-timeout 1 --max-time 2 https://api.ip.sb/ip 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -fsS --connect-timeout 1 --max-time 2 https://ipinfo.io/ip 2>/dev/null || true)
    [ -z "$ip" ] && ip=$(curl -4 -fsS --connect-timeout 1 --max-time 2 https://ifconfig.me/ip 2>/dev/null || true)
    echo "$ip"
}

# ---- 获取容器名 ----
get_container_name() {
    local choice i
    local -a names=()
    mapfile -t names < <(docker ps -a --format '{{.Names}} {{.Labels}}' 2>/dev/null | \
        awk '$1 ~ /^mtg(_[0-9]+)?$/ || $0 ~ /com\.shidahuilang\.mtg\.managed=true/ {print $1}' | sort -u)
    if [ "${#names[@]}" -eq 0 ]; then
        echo "$CONTAINER_NAME"
        return
    fi
    if [ "${#names[@]}" -eq 1 ]; then
        echo "${names[0]}"
        return
    fi

    yellow "检测到多个 MTProxy 容器,请选择目标:" >&2
    for i in "${!names[@]}"; do
        echo "  $((i + 1))) ${names[$i]}" >&2
    done
    read -r -p "请选择 [1-${#names[@]}]: " choice
    valid_port "$choice" && [ "$choice" -le "${#names[@]}" ] || {
        red "无效选择" >&2
        return 1
    }
    echo "${names[$((choice - 1))]}"
}

# ==================== 安装 ====================
install_proxy() {
    clear
    green "========== 安装 Telegram MTProxy =========="
    echo ""
    check_docker

    # 引擎选择
    yellow "引擎选择:"
    echo "  1) telemt (Rust, 默认, 多用户/配额/限速, 抗 AI DPI 更强)"
    echo "  2) mtg-go (Go, 经典稳定, 单用户高性能)"
    read -p "请选择 [1-2, 默认 1]: " engine_choice
    case "$engine_choice" in
        2) ENGINE="mtg"; ENGINE_DISPLAY="mtg-go (Go)" ;;
        *) ENGINE="telemt"; ENGINE_DISPLAY="telemt (Rust)" ;;
    esac
    echo ""

    # 端口
    read -p "请输入代理端口 (回车随机 10000-60000): " PORT
    if [ -z "$PORT" ]; then
        PORT=$((RANDOM % 50000 + 10000))
    fi
    valid_port "$PORT" || { red "端口必须是 1-65535 的整数"; read -p "按回车返回..."; return; }
    echo ""

    # 伪装域名
    read -p "请输入 FakeTLS 伪装域名 (回车默认 $DEFAULT_DOMAIN): " FAKEDOMAIN
    FAKEDOMAIN=${FAKEDOMAIN:-$DEFAULT_DOMAIN}
    valid_domain "$FAKEDOMAIN" || { red "请输入有效域名,不要包含协议、路径或端口"; read -p "按回车返回..."; return; }
    echo ""

    # IP 模式
    yellow "IP 模式:"
    echo "  1) 仅 IPv4 (默认)"
    echo "  2) 仅 IPv6"
    echo "  3) 双栈 (IPv4 + IPv6)"
    read -p "请选择 [1-3, 默认 1]: " ip_choice
    case "$ip_choice" in
        2) IP_MODE="v6" ;;
        3) IP_MODE="dual" ;;
        *) IP_MODE="v4" ;;
    esac
    echo ""

    # 容器名
    CONTAINER_NAME="mtg_${PORT}"
    DATA_DIR="/root/mtg_${PORT}_data"

    # 停止旧容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        yellow "> 停止并删除旧容器 $CONTAINER_NAME..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi

    # 创建数据目录
    mkdir -p "$DATA_DIR"
    chown root:root "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    touch "$DATA_DIR/.regenerate-config"

    # 拉取最新镜像
    yellow "> 拉取最新镜像..."
    docker pull "$IMAGE_NAME:latest"

    # 先拿到公网 IP (传给容器避免容器内探测到 Docker 内网)
    IP=$(get_public_ip)

    # 启动容器
    yellow "> 启动 $ENGINE_DISPLAY 容器..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --label com.shidahuilang.mtg.managed=true \
        --restart=unless-stopped \
        -p "${PORT}:${PORT}" \
        -v "${DATA_DIR}:/data" \
        --user root \
        -e PORT="$PORT" \
        -e FAKEDOMAIN="$FAKEDOMAIN" \
        -e ENGINE="$ENGINE" \
        -e IP_MODE="$IP_MODE" \
        -e TZ=Asia/Shanghai \
        -e HOST_IP="$IP" \
        "$IMAGE_NAME:latest"

    echo ""
    green "===================================="
    green " ✓ $ENGINE_DISPLAY 已启动"
    echo " 容器名称: $CONTAINER_NAME"
    echo " 引擎: $ENGINE_DISPLAY"
    echo " 端口: $PORT"
    echo " 伪装域名: $FAKEDOMAIN"
    echo " IP模式: $IP_MODE"
    echo " 数据目录: $DATA_DIR"
    [ -n "$IP" ] && echo " 服务器: $IP:$PORT"
    green "===================================="
    echo ""

    # 获取代理链接
    yellow "> 正在获取代理链接..."
    get_proxy_links "$CONTAINER_NAME" "$PORT" "$IP" "$ENGINE" "$FAKEDOMAIN"

    echo ""
    green "✓ 安装完成"
    echo ""
    read -p "按回车键返回主菜单..."
}

# ==================== 获取代理链接 ====================
get_proxy_links() {
    local NAME="$1"
    local PORT="$2"
    local IP="$3"
    local ENGINE="$4"
    local FAKEDOMAIN="${5:-www.apple.com}"

    PROXY_LINKS=""
    # users.json 在入口初始化后即可生成；只做短轮询，不等待 Control API
    MAX_ITER=12
    ITER=0
    TMPJSON=$(mktemp)

    while [ "$ITER" -lt "$MAX_ITER" ]; do
        # 清空临时文件, 避免上一轮 docker exec 失败写入空文件卡住后续轮次
        : > "$TMPJSON"

        # ---- telemt ----
        if [ "$ENGINE" != "mtg" ]; then
            # 策略1: docker exec cat 直接读 users.json + Base64URL 编码 (最快, 1~2秒可用)
            GOT_JSON=0
            # 去掉 || true, 真正根据 docker exec 的退出码判断是否成功 (失败时不读空文件)
            if docker exec "$NAME" cat /data/users.json > "$TMPJSON" 2>/dev/null; then
                USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
                [ "$USER_COUNT" -gt 0 ] && GOT_JSON=1
            fi
            if [ "$GOT_JSON" -ne 1 ]; then
                if docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null; then
                    USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
                    [ "$USER_COUNT" -gt 0 ] && GOT_JSON=1
                fi
            fi
            if [ "$GOT_JSON" -eq 1 ]; then
                USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
                for i in $(seq 0 $((USER_COUNT - 1))); do
                    UNAME=$(jq -r ".users[$i].name" "$TMPJSON" 2>/dev/null || true)
                    USECRET=$(jq -r ".users[$i].secret" "$TMPJSON" 2>/dev/null || true)
                    [ -z "$USECRET" ] && continue
                    B64=$(encode_proxy_secret_b64url "$USECRET" "$FAKEDOMAIN")
                    [ -z "$B64" ] && continue
                    if [ -n "$IP" ]; then
                        PROXY_LINKS="${PROXY_LINKS}用户: $UNAME"$'\n'"tg://proxy?server=$IP&port=$PORT&secret=$B64"$'\n'"https://t.me/proxy?server=$IP&port=$PORT&secret=$B64"$'\n'
                    else
                        PROXY_LINKS="${PROXY_LINKS}用户: $UNAME"$'\n'"tg://proxy?server=<服务器IP>&port=$PORT&secret=$B64"$'\n'"https://t.me/proxy?server=<服务器IP>&port=$PORT&secret=$B64"$'\n'
                    fi
                done
                [ -n "$PROXY_LINKS" ] && break
            fi

            # 策略2: Control API（仅在 users.json 尚未就绪时短暂兜底）
            API_LINKS=$(docker exec "$NAME" sh -c 'curl -s --max-time 0.2 http://127.0.0.1:9091/v1/users 2>/dev/null | jq -r ".data[].links.tls[]?" 2>/dev/null' || true)
            if [ -n "$API_LINKS" ]; then
                while IFS= read -r link; do
                    [ -z "$link" ] && continue
                    filtered=$(filter_valid_proxy_link "$link")
                    if [ -n "$filtered" ]; then
                        PROXY_LINKS="${PROXY_LINKS}${filtered}"$'\n'
                    else
                        api_secret=$(echo "$link" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/' 2>/dev/null || true)
                        if [ -n "$api_secret" ] && [ -n "$IP" ]; then
                            # ee+hex 的 secret 也直接用 (telemt Control API 有时会返 hex 格式)
                            PROXY_LINKS="${PROXY_LINKS}tg://proxy?server=$IP&port=$PORT&secret=$api_secret"$'\n'"https://t.me/proxy?server=$IP&port=$PORT&secret=$api_secret"$'\n'
                        fi
                    fi
                done <<EOF
$API_LINKS
EOF
                [ -n "$PROXY_LINKS" ] && break
            fi

            # 策略3: grep 容器日志 (entrypoint 横幅 + telemt tracing) + 去反引号 + 去 ANSI
            # 先统一去 ANSI 控制字符和反引号, 再提取链接
            LOG_CLEAN=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '`' 2>/dev/null || true)
            LOG_TG=$(echo "$LOG_CLEAN" | grep -oE 'tg://proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | sort -u 2>/dev/null || true)
            LOG_HTTPS=$(echo "$LOG_CLEAN" | grep -oE 'https://t\.me/proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | sort -u 2>/dev/null || true)
            LOG_LINKS=""
            if [ -n "$LOG_TG" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    if [ -n "$filtered" ]; then
                        LOG_LINKS="${LOG_LINKS}${filtered}
"
                    else
                        # filter 失败可能是: server=内网IP 或 secret=纯hex(telemt EE-TLS)
                        # 提取 secret, 只要有效就重拼公网IP
                        log_secret=$(echo "$line" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/' 2>/dev/null || true)
                        if [ -n "$log_secret" ] && [ -n "$IP" ]; then
                            # 判断是否 ee 开头纯 hex (telemt tracing 的 EE-TLS 格式, 完整有效 secret)
                            if [[ "$log_secret" =~ ^ee[0-9a-fA-F]{34,}$ ]]; then
                                # ee + 至少 17 字节 hex (34 字符) = 完整 secret, 直接用, 转 B64 保险
                                # 先把 hex 转字节, 再 base64url 编码
                                hex_bytes=""
                                i=0
                                while [ "$i" -lt ${#log_secret} ]; do
                                    hex_bytes="${hex_bytes}\\x${log_secret:$i:2}"
                                    i=$((i + 2))
                                done
                                B64_SEC=$(printf '%b' "$hex_bytes" | base64 -w0 2>/dev/null | tr -d '\r\n' | sed 's/=*$//; y/+\//-_/')
                                if [ -n "$B64_SEC" ]; then
                                    LOG_LINKS="${LOG_LINKS}tg://proxy?server=$IP&port=$PORT&secret=$B64_SEC
https://t.me/proxy?server=$IP&port=$PORT&secret=$B64_SEC
"
                                else
                                    LOG_LINKS="${LOG_LINKS}tg://proxy?server=$IP&port=$PORT&secret=$log_secret
https://t.me/proxy?server=$IP&port=$PORT&secret=$log_secret
"
                                fi
                            else
                                LOG_LINKS="${LOG_LINKS}tg://proxy?server=$IP&port=$PORT&secret=$log_secret
https://t.me/proxy?server=$IP&port=$PORT&secret=$log_secret
"
                            fi
                        fi
                    fi
                done <<EOF
$LOG_TG
EOF
            fi
            if [ -n "$LOG_HTTPS" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    if [ -n "$filtered" ]; then
                        LOG_LINKS="${LOG_LINKS}${filtered}
"
                    else
                        log_secret=$(echo "$line" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/' 2>/dev/null || true)
                        if [ -n "$log_secret" ] && [ -n "$IP" ]; then
                            LOG_LINKS="${LOG_LINKS}tg://proxy?server=$IP&port=$PORT&secret=$log_secret
https://t.me/proxy?server=$IP&port=$PORT&secret=$log_secret
"
                        fi
                    fi
                done <<EOF
$LOG_HTTPS
EOF
            fi
            if [ -n "$LOG_LINKS" ]; then
                PROXY_LINKS="$LOG_LINKS"
                break
            fi
        fi

        # ---- mtg ----
        if [ "$ENGINE" = "mtg" ]; then
            SECRET=$(docker exec "$NAME" sh -c 'cat /data/.secret 2>/dev/null' || true)
            SECRET=$(echo "$SECRET" | tr -d '\r\n ')
            if [ -n "$SECRET" ] && [ -n "$IP" ]; then
                PROXY_LINKS="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"$'\n'"https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
                break
            fi
            LOG_TG=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'tg://proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | tr -d '`' | sort -u 2>/dev/null || true)
            LOG_HTTPS=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'https://t\.me/proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | tr -d '`' | sort -u 2>/dev/null || true)
            LOG_LINKS=""
            if [ -n "$LOG_TG" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    [ -n "$filtered" ] && LOG_LINKS="${LOG_LINKS}${filtered}
"
                done <<EOF
$LOG_TG
EOF
            fi
            if [ -n "$LOG_HTTPS" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    [ -n "$filtered" ] && LOG_LINKS="${LOG_LINKS}${filtered}
"
                done <<EOF
$LOG_HTTPS
EOF
            fi
            if [ -n "$LOG_LINKS" ]; then
                PROXY_LINKS="$LOG_LINKS"
                break
            fi
        fi

        ITER=$((ITER + 1))
            sleep 0.2
        elapsed=$((ITER / 2))
        # 前 5 秒 1s 打一次,之后 5s 打一次,避免刷屏
        if [ "$elapsed" -le 5 ] && [ $((ITER % 2)) -eq 0 ]; then
            yellow "  已等待 ${elapsed}s,继续轮询中..."
        elif [ $((ITER % 10)) -eq 0 ]; then
            yellow "  已等待 ${elapsed}s,继续轮询中..."
        fi
    done

    rm -f "$TMPJSON"

    if [ -n "$PROXY_LINKS" ]; then
        green "===================================="
        green " 代理链接 (直接复制使用)"
        green "===================================="
        echo "$PROXY_LINKS"
        green "===================================="
    else
        red "> 自动获取超时,请手动获取:"
        echo "  docker logs $NAME 2>&1 | grep -oE '(tg://proxy\?|https://t\.me/proxy\?)[^ ]*'"
        if [ "$ENGINE" != "mtg" ]; then
            echo "  docker exec $NAME curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[]?'"
        fi

        echo ""
        yellow "----- 诊断信息(贴给开发者) -----"
        echo "容器:"
        docker ps --filter "name=$NAME" --format '  {{.Names}} / {{.Status}}' 2>/dev/null || echo "  (docker ps 失败)"
        echo "容器内 /data:"
        docker exec "$NAME" sh -c 'ls -la /data 2>/dev/null' 2>/dev/null | sed 's/^/  /' || echo "  (docker exec 失败)"
        if [ "$ENGINE" != "mtg" ]; then
            echo "Control API 状态:"
            docker exec "$NAME" sh -c 'curl -sS -o /dev/null -w "  %{http_code} (size=%{size_download})\n" --max-time 3 http://127.0.0.1:9091/v1/users 2>/dev/null' || echo "  curl 无法调用 API"
            echo "Control API 原始响应 (前 300 字符):"
            docker exec "$NAME" sh -c 'curl -s --max-time 3 http://127.0.0.1:9091/v1/users 2>/dev/null | head -c 300' 2>/dev/null || true
            echo ""
        fi
        echo "docker logs 最后 20 行 (过滤控制字符):"
        docker logs --tail 20 "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/  /' || echo "  (docker logs 失败)"
        echo "----- 诊断结束 -----"
    fi
}

# ==================== 查看状态和链接 ====================
show_status() {
    clear
    green "========== 状态和代理链接 =========="
    echo ""
    NAME=$(get_container_name)

    if ! docker ps --filter "name=$NAME" --format '{{.Names}}' | grep -q "$NAME"; then
        red "❌ 容器 $NAME 未运行"
        echo ""
        yellow "已停止的容器:"
        docker ps -a --filter "ancestor=$IMAGE_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  (无)"
        echo ""
        read -p "按回车返回主菜单..."
        return
    fi

    # 容器状态
    cyan "--- 容器状态 ---"
    docker ps --filter "name=$NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    # 引擎
    ENGINE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^ENGINE=' | cut -d= -f2 | tr -d '\r\n')
    ENGINE=${ENGINE:-telemt}
    PORT=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^PORT=' | cut -d= -f2 | tr -d '\r\n')
    PORT=${PORT:-443}
    IP=$(get_public_ip)

    # 容器刚启动(<10秒)时先等一下, 给 entrypoint 留出初始化 users.json 的时间
    UPTIME_SEC=$(docker ps --filter "name=$NAME" --format '{{.Status}}' 2>/dev/null | grep -oE '[0-9]+ second' | head -1 | awk '{print $1}')
    if [ -n "$UPTIME_SEC" ] && [ "$UPTIME_SEC" -lt 10 ]; then
        sleep 1
    fi

    echo ""
    cyan "--- 代理链接 ---"
    if [ "$ENGINE" = "mtg" ]; then
        SECRET=$(docker exec "$NAME" cat /data/.secret 2>/dev/null | tr -d '\r\n ' || true)
        if [ -n "$SECRET" ] && [ -n "$IP" ]; then
            echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
            echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$SECRET"
        else
            red "获取密钥失败,查看日志: docker logs $NAME"
        fi
    else
        # telemt: 3 个策略串联, 优先用最快就绪的 (users.json 比 API 先写好)
        LINKS=""

        # 策略1: docker exec cat users.json + Base64URL 编码 (entrypoint 启动 telemt 前就生成, 1~2 秒可用)
        TMPJSON=$(mktemp)
        : > "$TMPJSON"
        DOMAIN=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^FAKEDOMAIN=' | cut -d= -f2 | tr -d '\r\n')
        DOMAIN=${DOMAIN:-www.apple.com}
        GOT=0
        # 去掉 || true, 真正根据 docker exec 的返回值判断是否成功
        if docker exec "$NAME" cat /data/users.json > "$TMPJSON" 2>/dev/null; then
            USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
            [ "$USER_COUNT" -gt 0 ] && GOT=1
        fi
        if [ "$GOT" -ne 1 ]; then
            if docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null; then
                USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
                [ "$USER_COUNT" -gt 0 ] && GOT=1
            fi
        fi
        if [ "$GOT" -eq 1 ]; then
            USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
            for i in $(seq 0 $((USER_COUNT - 1))); do
                UNAME=$(jq -r ".users[$i].name" "$TMPJSON" 2>/dev/null || true)
                USECRET=$(jq -r ".users[$i].secret" "$TMPJSON" 2>/dev/null || true)
                [ -z "$USECRET" ] && continue
                B64=$(encode_proxy_secret_b64url "$USECRET" "$DOMAIN")
                [ -z "$B64" ] && continue
                LINKS="${LINKS}用户: $UNAME"$'\n'"tg://proxy?server=$IP&port=$PORT&secret=$B64"$'\n'"https://t.me/proxy?server=$IP&port=$PORT&secret=$B64"$'\n\n'
            done
        fi
        rm -f "$TMPJSON"

        # 策略2: Control API + 过滤(内网IP链接提取secret重拼)
        if [ -z "$LINKS" ]; then
            API_RAW=$(docker exec "$NAME" sh -c 'curl -s --max-time 3 http://127.0.0.1:9091/v1/users 2>/dev/null | jq -r ".data[].links.tls[]?" 2>/dev/null' || true)
            if [ -n "$API_RAW" ]; then
                while IFS= read -r link; do
                    [ -z "$link" ] && continue
                    filtered=$(filter_valid_proxy_link "$link")
                    if [ -n "$filtered" ]; then
                        LINKS="${LINKS}${filtered}"$'\n'
                    else
                        api_secret=$(echo "$link" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/' 2>/dev/null || true)
                        if [ -n "$api_secret" ] && [ -n "$IP" ]; then
                            LINKS="${LINKS}tg://proxy?server=$IP&port=$PORT&secret=$api_secret"$'\n'"https://t.me/proxy?server=$IP&port=$PORT&secret=$api_secret"$'\n'
                        fi
                    fi
                done <<EOF
$API_RAW
EOF
            fi
        fi

        # 策略3: grep 日志 + 去反引号 + tg优先 + 有效性过滤
        if [ -z "$LINKS" ]; then
            # 修复正则: 允许反引号作为链接的前置字符 (entrypoint 输出的 https 链接带反引号包裹: `https://...`)
            # 同时 sed 去掉开头所有非 t/h 字符(含反引号), 末尾再单独去掉反引号
            LOG_TG=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'tg://proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | tr -d '`' | sort -u 2>/dev/null || true)
            LOG_HTTPS=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'https://t\.me/proxy\?server=[A-Za-z0-9._:-]+&port=[0-9]+&secret=[A-Za-z0-9_-]+' | tr -d '`' | sort -u 2>/dev/null || true)
            if [ -n "$LOG_TG" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    [ -n "$filtered" ] && LINKS="${LINKS}${filtered}"$'\n'
                done <<EOF
$LOG_TG
EOF
            fi
            if [ -n "$LOG_HTTPS" ]; then
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    filtered=$(filter_valid_proxy_link "$line")
                    [ -n "$filtered" ] && LINKS="${LINKS}${filtered}"$'\n'
                done <<EOF
$LOG_HTTPS
EOF
            fi
        fi

        if [ -n "$LINKS" ]; then
            echo "$LINKS"
        else
            yellow "尚未获取到链接,稍等几秒再试或查看日志:"
            echo "  docker logs $NAME 2>&1 | grep -oE '(tg://proxy\?|https://t\.me/proxy\?)[^ ]*'"
        fi
    fi

    echo ""
    cyan "--- 用户列表 (telemt) ---"
    if [ "$ENGINE" != "mtg" ]; then
        TMPJSON=$(mktemp)
        : > "$TMPJSON"
        GOT=0
        USER_COUNT=0
        # 去掉 || true, 真正判断 docker exec 是否成功 (失败时不写入空文件污染后续判断)
        if docker exec "$NAME" cat /data/users.json > "$TMPJSON" 2>/dev/null; then
            USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
            [ "$USER_COUNT" -gt 0 ] && GOT=1
        fi
        if [ "$GOT" -ne 1 ]; then
            if docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null; then
                USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
                [ "$USER_COUNT" -gt 0 ] && GOT=1
            fi
        fi
        if [ "$GOT" -eq 1 ]; then
            jq -r '.users[] | "  用户: \(.name)  配额: \(.quota_gb)GB  到期: \(.expire // "永久")  限速: \(.speed_limit // "无")"' "$TMPJSON" 2>/dev/null || echo "  (解析失败)"
        else
            # 最后兜底: 从日志里正则提取用户名 (entrypoint 输出格式 "用户: xxx" + 后面带反引号包裹链接的整段)
            # 先去掉 ANSI 控制字符再匹配, 并放宽用户名的字符允许范围
            ULOG=$(docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '用户:[[:space:]]*[A-Za-z0-9._\u4e00-\u9fa5-]+' | sort -u 2>/dev/null || true)
            if [ -n "$ULOG" ]; then
                echo "$ULOG" | sed 's/^/  /; s/:[[:space:]]*/: /'
            else
                # 再兜底: 直接列出所有 "admin" 等常见用户名 (如果 grep 连这个都匹配不到)
                echo "  (无用户数据 - 容器刚启动<10秒时可能出现,请稍后再查)"
            fi
        fi
        rm -f "$TMPJSON"
    else
        echo "  (mtg-go 引擎为单用户模式)"
    fi

    echo ""
    read -p "按回车返回主菜单..."
}

# ==================== 多用户管理 ====================
manage_users() {
    clear
    green "========== Telemt 多用户管理 =========="
    echo ""
    NAME=$(get_container_name)
    ENGINE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^ENGINE=' | cut -d= -f2 | tr -d '\r\n')
    ENGINE=${ENGINE:-telemt}

    if [ "$ENGINE" = "mtg" ]; then
        red "mtg-go 引擎不支持多用户,请切换到 telemt 引擎"
        read -p "按回车返回..."
        return
    fi
    while true; do
        echo ""
        cyan "--- 当前用户列表 ---"
        TMPJSON=$(mktemp)
        docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null && \
            jq -r '.users[] | "  [\(.name)] 配额:\(.quota_gb)GB 到期:\(.expire // "永久") 限速:\(.speed_limit // "无") 端口:\(.port // "共享")"' "$TMPJSON" 2>/dev/null || echo "  (无数据)"
        rm -f "$TMPJSON"
        echo ""
        yellow "多用户管理:"
        echo "  1) 查看所有用户及分享链接"
        echo "  2) 添加新用户"
        echo "  3) 删除用户"
        echo "  4) 设置流量配额"
        echo "  5) 设置到期时间"
        echo "  6) 设置带宽限速"
        echo "  0) 返回主菜单"
        read -p "请选择 [0-6]: " sub_choice

        case "$sub_choice" in
            1) view_user_links "$NAME" ;;
            2) add_user "$NAME" ;;
            3) delete_user "$NAME" ;;
            4) set_user_quota "$NAME" ;;
            5) set_user_expire "$NAME" ;;
            6) set_user_speed "$NAME" ;;
            0) break ;;
        esac
    done
}

# ---- 查看用户链接 ----
view_user_links() {
    local NAME="$1"
    echo ""
    cyan "--- 所有用户分享链接 ---"
    # 从容器 API 获取链接
    API_JSON=$(docker exec "$NAME" curl -fsS --max-time 5 http://127.0.0.1:9091/v1/users 2>/dev/null || true)
    LINKS=$(printf '%s' "$API_JSON" | jq -r '.data[] | "用户: \(.name)\n\(.links.tls[]?)\n"' 2>/dev/null || true)
    if [ -n "$LINKS" ]; then
        echo "$LINKS"
    else
        # API 没就绪,从 users.json 手动拼
        yellow "API 未就绪,从 users.json 构造链接..."
        TMPJSON=$(mktemp)
        docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null || { red "无法读取用户数据"; return; }
        PORT=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^PORT=' | cut -d= -f2 | tr -d '\r\n')
        DOMAIN=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^FAKEDOMAIN=' | cut -d= -f2 | tr -d '\r\n')
        DOMAIN=${DOMAIN:-www.apple.com}
        IP=$(get_public_ip)
        USER_COUNT=$(jq '.users | length' "$TMPJSON" 2>/dev/null || echo 0)
        for i in $(seq 0 $((USER_COUNT - 1))); do
            UNAME=$(jq -r ".users[$i].name" "$TMPJSON" 2>/dev/null)
            USECRET=$(jq -r ".users[$i].secret" "$TMPJSON" 2>/dev/null)
            [ -z "$USECRET" ] && continue
            B64=$(encode_proxy_secret_b64url "$USECRET" "$DOMAIN")
            echo "用户: $UNAME"
            echo "tg://proxy?server=$IP&port=$PORT&secret=$B64"
            echo ""
        done
        rm -f "$TMPJSON"
    fi
    echo ""
    read -p "按回车继续..."
}

# ---- 修改 users.json 的通用函数 (用 docker cp 避免引号嵌套问题) ----
update_users_json() {
    local NAME="$1"
    shift
    local TMPJSON
    TMPJSON=$(mktemp)
    # 从容器拷贝出来
    docker cp "$NAME:/data/users.json" "$TMPJSON" 2>/dev/null || { red "无法读取 users.json"; return 1; }
    # 本地用 jq 修改
    jq "$@" "$TMPJSON" > "${TMPJSON}.new" 2>/dev/null || { red "jq 修改失败"; rm -f "$TMPJSON" "${TMPJSON}.new"; return 1; }
    jq -e '.users | type == "array"' "${TMPJSON}.new" >/dev/null 2>&1 || {
        red "修改后的 users.json 无效"
        rm -f "$TMPJSON" "${TMPJSON}.new"
        return 1
    }
    mv "${TMPJSON}.new" "$TMPJSON"
    # 拷贝回容器
    docker cp "$TMPJSON" "$NAME:/data/users.json" 2>/dev/null || { red "无法写回 users.json"; rm -f "$TMPJSON"; return 1; }
    rm -f "$TMPJSON"
    docker exec "$NAME" sh -c 'touch /data/.regenerate-config' >/dev/null 2>&1 || {
        red "无法创建配置重建标记"
        return 1
    }
    return 0
}

restart_after_user_change() {
    local NAME="$1"
    yellow "> 重新生成配置并重启..."
    if ! docker restart "$NAME" >/dev/null 2>&1; then
        red "容器重启失败"
        return 1
    fi
    sleep 2
    if [ "$(docker inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
        red "容器启动失败,请运行: docker logs $NAME"
        return 1
    fi
}

ensure_user_exists() {
    local NAME="$1"
    local USERNAME="$2"
    if ! docker exec "$NAME" jq -e --arg name "$USERNAME" '.users[] | select(.name == $name)' /data/users.json >/dev/null 2>&1; then
        red "用户 $USERNAME 不存在"
        return 1
    fi
}

# ---- 添加用户 ----
add_user() {
    local NAME="$1"
    read -p "输入新用户名: " USERNAME
    [ -z "$USERNAME" ] && { red "用户名不能为空"; return; }
    valid_username "$USERNAME" || { red "用户名仅支持字母、数字、点、下划线和横线,最长 64 字符"; return; }

    if docker exec "$NAME" jq -e --arg name "$USERNAME" '.users[] | select(.name == $name)' /data/users.json >/dev/null 2>&1; then
        red "用户 $USERNAME 已存在"
        return
    fi

    # 生成密钥
    NEW_SECRET=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null)
    [ -z "$NEW_SECRET" ] && NEW_SECRET=$(openssl rand -hex 16 2>/dev/null)

    # 追加到 users.json (本地 jq 修改,避免容器内引号问题)
    update_users_json "$NAME" --arg name "$USERNAME" --arg secret "$NEW_SECRET" \
        '.users += [{name:$name,secret:$secret,quota_gb:0,expire:"",speed_limit:"",port:0}]' || return

    # 重新生成 telemt.toml 并重启
    restart_after_user_change "$NAME" || return
    green "✓ 用户 $USERNAME 已添加"
    echo ""

    # 显示链接 (先查 Control API,拿不到就手动 Base64URL 编码拼接兜底)
    cyan "分享链接:"
    PORT=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^PORT=' | cut -d= -f2 | tr -d '\r\n')
    DOMAIN=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^FAKEDOMAIN=' | cut -d= -f2 | tr -d '\r\n')
    DOMAIN=${DOMAIN:-www.apple.com}
    IP=$(get_public_ip)
    LINKS=$(docker exec "$NAME" curl -fsS --max-time 3 http://127.0.0.1:9091/v1/users 2>/dev/null | jq -r --arg name "$USERNAME" '.data[] | select(.name==$name) | .links.tls[]?' 2>/dev/null || true)
    if [ -n "$LINKS" ]; then
        echo "$LINKS"
    else
        B64=$(encode_proxy_secret_b64url "$NEW_SECRET" "$DOMAIN")
        echo "tg://proxy?server=$IP&port=$PORT&secret=$B64"
        echo "https://t.me/proxy?server=$IP&port=$PORT&secret=$B64"
    fi
    echo ""
    read -p "按回车继续..."
}

# ---- 删除用户 ----
delete_user() {
    local NAME="$1"
    read -p "输入要删除的用户名: " USERNAME
    [ -z "$USERNAME" ] && { red "用户名不能为空"; return; }
    valid_username "$USERNAME" || { red "用户名格式无效"; return; }
    ensure_user_exists "$NAME" "$USERNAME" || return
    USER_COUNT=$(docker exec "$NAME" jq '.users | length' /data/users.json 2>/dev/null || echo 0)
    [ "$USER_COUNT" -gt 1 ] || { red "不能删除最后一个用户"; return; }

    update_users_json "$NAME" --arg name "$USERNAME" '.users |= map(select(.name != $name))' || return

    restart_after_user_change "$NAME" || return
    green "✓ 用户 $USERNAME 已删除"
    echo ""
    read -p "按回车继续..."
}

# ---- 设置流量配额 ----
set_user_quota() {
    local NAME="$1"
    read -p "输入用户名: " USERNAME
    read -p "输入流量配额 (GB, 0=无限): " QUOTA
    QUOTA=${QUOTA:-0}
    valid_username "$USERNAME" || { red "用户名格式无效"; return; }
    ensure_user_exists "$NAME" "$USERNAME" || return
    [[ "$QUOTA" =~ ^([0-9]+)(\.[0-9]+)?$ ]] || { red "配额必须是大于等于 0 的数字"; return; }

    update_users_json "$NAME" --arg name "$USERNAME" --argjson quota "$QUOTA" \
        '(.users[] | select(.name==$name) | .quota_gb) = $quota' || return

    restart_after_user_change "$NAME" || return
    green "✓ $USERNAME 配额已设为 ${QUOTA}GB"
    echo ""
    read -p "按回车继续..."
}

# ---- 设置到期时间 ----
set_user_expire() {
    local NAME="$1"
    read -p "输入用户名: " USERNAME
    echo "  格式: 2026-12-31T23:59:59+08:00"
    read -p "输入到期时间 (留空=永久): " EXPIRE
    valid_username "$USERNAME" || { red "用户名格式无效"; return; }
    ensure_user_exists "$NAME" "$USERNAME" || return
    if [ -n "$EXPIRE" ]; then
        [[ "$EXPIRE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] && \
            date -d "$EXPIRE" +%s >/dev/null 2>&1 || { red "到期时间必须是有效 ISO 8601,例如 2026-12-31T23:59:59+08:00"; return; }
    fi

    update_users_json "$NAME" --arg name "$USERNAME" --arg expire "$EXPIRE" \
        '(.users[] | select(.name==$name) | .expire) = $expire' || return

    restart_after_user_change "$NAME" || return
    if [ -n "$EXPIRE" ]; then
        green "✓ $USERNAME 到期时间已设为 $EXPIRE"
    else
        green "✓ $USERNAME 已设为永久"
    fi
    echo ""
    read -p "按回车继续..."
}

# ---- 设置带宽限速 ----
set_user_speed() {
    local NAME="$1"
    read -p "输入用户名: " USERNAME
    echo "  格式: 上行下行 (MB/s), 例如: 1.5 5.0"
    read -p "输入限速 (留空=不限): " SPEED
    valid_username "$USERNAME" || { red "用户名格式无效"; return; }
    ensure_user_exists "$NAME" "$USERNAME" || return
    if [ -n "$SPEED" ] && ! [[ "$SPEED" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]+([0-9]+([.][0-9]+)?)$ ]]; then
        red "限速格式必须为两个非负数字,例如: 1.5 5.0"
        return
    fi

    update_users_json "$NAME" --arg name "$USERNAME" --arg speed "$SPEED" \
        '(.users[] | select(.name==$name) | .speed_limit) = $speed' || return

    restart_after_user_change "$NAME" || return
    if [ -n "$SPEED" ]; then
        green "✓ $USERNAME 限速已设为 $SPEED MB/s"
    else
        green "✓ $USERNAME 已解除限速"
    fi
    echo ""
    read -p "按回车继续..."
}

# ==================== 服务控制 ====================
restart_proxy() {
    NAME=$(get_container_name)
    yellow "> 重启 $NAME..."
    docker restart "$NAME" 2>/dev/null && green "✓ 已重启" || red "❌ 重启失败"
    sleep 2
    read -p "按回车返回..."
}

stop_proxy() {
    NAME=$(get_container_name)
    yellow "> 停止 $NAME..."
    docker stop "$NAME" 2>/dev/null && green "✓ 已停止" || red "❌ 停止失败"
    read -p "按回车返回..."
}

start_proxy() {
    NAME=$(get_container_name)
    yellow "> 启动 $NAME..."
    docker start "$NAME" 2>/dev/null && green "✓ 已启动" || red "❌ 启动失败"
    read -p "按回车返回..."
}

# ==================== 升级镜像 ====================
upgrade_proxy() {
    clear
    green "========== 升级镜像 =========="
    NAME=$(get_container_name)

    yellow "> 拉取最新镜像..."
    docker pull "$IMAGE_NAME:latest"

    if docker ps -a --filter "name=^/${NAME}$" --format '{{.Names}}' | grep -Fxq "$NAME"; then
        yellow "> 重建容器..."
        # 提取原启动参数
        PORT=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^PORT=' | cut -d= -f2 | tr -d '\r\n')
        ENGINE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^ENGINE=' | cut -d= -f2 | tr -d '\r\n')
        FAKEDOMAIN=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^FAKEDOMAIN=' | cut -d= -f2 | tr -d '\r\n')
        IP_MODE=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" 2>/dev/null | grep '^IP_MODE=' | cut -d= -f2 | tr -d '\r\n')

        PORT=${PORT:-443}; ENGINE=${ENGINE:-telemt}; FAKEDOMAIN=${FAKEDOMAIN:-www.apple.com}; IP_MODE=${IP_MODE:-v4}
        # 数据目录从挂载点提取
        DATA_DIR=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$NAME" 2>/dev/null)
        if [ -z "$DATA_DIR" ]; then
            red "无法确定 $NAME 的 /data 挂载,为避免丢失配置已取消升级"
            read -p "按回车返回..."
            return
        fi

        docker rm -f "$NAME" 2>/dev/null || true
        docker run -d \
            --name "$NAME" \
            --label com.shidahuilang.mtg.managed=true \
            --restart=unless-stopped \
            -p "${PORT}:${PORT}" \
            -v "${DATA_DIR}:/data" \
            --user root \
            -e PORT="$PORT" \
            -e FAKEDOMAIN="$FAKEDOMAIN" \
            -e ENGINE="$ENGINE" \
            -e IP_MODE="$IP_MODE" \
            -e TZ=Asia/Shanghai \
            -e HOST_IP="$(get_public_ip)" \
            "$IMAGE_NAME:latest"

        green "✓ 升级完成 (配置保留, 不强制重新生成密钥)"
    else
        green "✓ 镜像已更新,运行 bash tg.install.sh 选 1 安装"
    fi
    echo ""
    read -p "按回车返回..."
}

# ==================== 卸载 ====================
uninstall_proxy() {
    clear
    green "========== 卸载 MTProxy =========="
    echo ""
    red "⚠️  此操作将删除所有容器、镜像和数据!"
    read -p "确认卸载? (输入 yes 确认): " confirm
    [ "$confirm" != "yes" ] && { echo "已取消"; read -p "按回车返回..."; return; }

    # 停止并删除所有相关容器
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        yellow "> 删除容器 $c..."
        docker rm -f "$c" 2>/dev/null || true
        # 删除数据目录
        ddir="/root/mtg_${c#mtg_}_data"
        [ -d "$ddir" ] && rm -rf "$ddir" 2>/dev/null && echo "  已删除 $ddir"
    done < <(docker ps -a --format '{{.Names}} {{.Labels}}' 2>/dev/null | \
        awk '$1 ~ /^mtg(_[0-9]+)?$/ || $0 ~ /com\.shidahuilang\.mtg\.managed=true/ {print $1}' | sort -u)

    # 删除镜像
    yellow "> 删除镜像 $IMAGE_NAME..."
    docker rmi "$IMAGE_NAME:latest" 2>/dev/null && green "✓ 镜像已删除" || yellow "  (镜像可能已被删除或不存在)"

    green "✓ 卸载完成"
    echo ""
    read -p "按回车返回..."
}

# ==================== 主菜单 ====================
show_menu() {
    clear
    green "=================================================="
    green "   MTProxy Docker 管理脚本"
    green "   (基于 webbrain-one/MTProxy 双内核版)"
    green "=================================================="
    echo ""
    yellow "请选择操作:"
    echo "  1) 安装代理 (telemt/mtg-go 双引擎可选)"
    echo "  2) 查看状态和代理链接"
    echo "  3) 重启容器"
    echo "  4) 停止容器"
    echo "  5) 启动容器"
    echo "  6) Telemt 多用户管理"
    echo "  7) 升级镜像"
    echo "  8) 卸载代理 (容器+镜像+数据)"
    echo "  0) 退出"
    echo ""
    read -p "请输入选项 [0-8]: " choice
}

# ==================== 主循环 ====================
main() {
    check_docker
    while true; do
        show_menu
        case "$choice" in
            1) install_proxy ;;
            2) show_status ;;
            3) restart_proxy ;;
            4) stop_proxy ;;
            5) start_proxy ;;
            6) manage_users ;;
            7) upgrade_proxy ;;
            8) uninstall_proxy ;;
            0) echo "再见!"; exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}

main
