#!/bin/bash
set -Eeuo pipefail

# ===== MTProxy Docker entrypoint (基于 webbrain-one/MTProxy) =====
# 双引擎: telemt (Rust, 默认) + mtg-go (Go, 回退)
# 支持: 多用户/流量配额/到期时间/带宽限速/专属端口

# ---- 静默权限修复 (root 启动时自动降级) ----
DATA_DIR=${DATA_DIR:-/data}

if [ "$(id -u)" = "0" ] && command -v su-exec >/dev/null 2>&1 && id mtg >/dev/null 2>&1; then
    chown -R mtg:mtg "$DATA_DIR" 2>/dev/null || true
    chmod 700 "$DATA_DIR" 2>/dev/null || true
    exec su-exec mtg:mtg /bin/bash "$0" "$@"
fi

# ---- 默认配置 ----
PORT=${PORT:-443}
DOMAIN=${FAKEDOMAIN:-${DOMAIN:-www.apple.com}}
ENGINE=$(echo "${ENGINE:-telemt}" | tr '[:upper:]' '[:lower:]')
# IP 模式: v4 / v6 / dual
IP_MODE=${IP_MODE:-v4}
# 时区
export TZ=${TZ:-Asia/Shanghai}

case "$PORT" in
    ''|*[!0-9]*) echo ">>> ❌ PORT 必须是 1-65535 的整数"; exit 1 ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo ">>> ❌ PORT 必须是 1-65535 的整数"; exit 1; }
[[ "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || {
    echo ">>> ❌ FAKEDOMAIN 不是有效域名: $DOMAIN"
    exit 1
}
case "$IP_MODE" in
    v4|v6|dual) ;;
    *) echo ">>> ❌ IP_MODE 只能是 v4、v6 或 dual"; exit 1 ;;
esac

if [ "$ENGINE" = "mtg" ]; then
    ENGINE_NAME="mtg-go (Go)"
    CONF="$DATA_DIR/mtg.conf"
    ENGINE_BIN=$(command -v mtg-go || true)
else
    ENGINE="telemt"
    ENGINE_NAME="telemt (Rust)"
    CONF="$DATA_DIR/telemt.toml"
    ENGINE_BIN=$(command -v telemt || true)
fi

verify_binary_arch() {
    local expected actual host_arch
    [ -n "$ENGINE_BIN" ] && [ -r "$ENGINE_BIN" ] || { echo ">>> ❌ 找不到引擎二进制: $ENGINE"; exit 126; }
    # 测试替身可以是脚本；生产发布的引擎必须是 ELF。
    if [ "$(dd if="$ENGINE_BIN" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
        return
    fi
    host_arch=$(uname -m)
    case "$host_arch" in
        x86_64|amd64)  expected="3e00" ;;
        aarch64|arm64) expected="b700" ;;
        *) echo ">>> ❌ 不支持的宿主机架构: $host_arch"; exit 126 ;;
    esac
    actual=$(dd if="$ENGINE_BIN" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$actual" != "$expected" ]; then
        echo ">>> ❌ 镜像二进制架构错误: 宿主机=$host_arch, $ENGINE_BIN ELF=$actual"
        echo ">>> 请重新拉取已修复的多架构镜像，不会输出无效代理链接。"
        exit 126
    fi
}

verify_binary_arch

PROTO_MODE_DISPLAY="FakeTLS (伪装 $DOMAIN · $ENGINE_NAME)"

# ---- 公网 IP ----
# 优先用环境变量传入的 HOST_IP (由宿主机 tg.install.sh 传入公网 IP, 避免容器内探测误判为 Docker 内网)
# 仅当未传入时,才在容器内自行探测
HOST_IP=${HOST_IP:-}
HOST_IP_FROM_ENV=""
if [ -n "$HOST_IP" ]; then
    HOST_IP_FROM_ENV="$HOST_IP"
fi
if [ -z "$HOST_IP_FROM_ENV" ]; then
    HOST_IP=$(curl -4 -fsS --connect-timeout 1 --max-time 2 https://api.ip.sb/ip 2>/dev/null || \
        curl -4 -fsS --connect-timeout 1 --max-time 2 https://ipinfo.io/ip 2>/dev/null || echo "")
fi

# ---- 判断是否是内网/保留 IP ----
is_private_ip() {
    local s="$1"
    [ -z "$s" ] && return 0
    case "$s" in
        10.*)                 return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        192.168.*)            return 0 ;;
        127.*)                return 0 ;;
        169.254.*)            return 0 ;;
        0.*)                  return 0 ;;
        ::1|fe80:*|fc*:*|fd*:*) return 0 ;;
        "<服务器IP>")          return 0 ;;
        *)                    return 1 ;;
    esac
}

# ---- 信号处理 ----
ENGINE_PID=""
graceful_stop() {
    echo ""
    echo ">>> 收到停止信号,正在关闭 $ENGINE_NAME..."
    [ -n "$ENGINE_PID" ] && kill -0 "$ENGINE_PID" 2>/dev/null && kill -TERM "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
    echo ">>> 已停止"
    exit 0
}
trap graceful_stop SIGTERM SIGINT

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR" 2>/dev/null || true

SECRET_FILE="$DATA_DIR/.secret"
USERS_FILE="$DATA_DIR/users.json"
REGEN_FILE="$DATA_DIR/.regenerate-config"

# ---- FORCE_REGEN ----
FORCE_REGEN_LOWER=$(echo "${FORCE_REGEN:-}" | tr '[:upper:]' '[:lower:]')
SHOULD_REGEN=0
if [ ! -f "$CONF" ] || [ -f "$REGEN_FILE" ] || [ "$FORCE_REGEN_LOWER" = "true" ] || [ "$FORCE_REGEN_LOWER" = "1" ]; then
    [ -f "$CONF" ] && [ "$FORCE_REGEN_LOWER" = "true" -o "$FORCE_REGEN_LOWER" = "1" ] && {
        echo ">>> ⚠️  FORCE_REGEN=true, 重新生成配置(旧配置备份)"
        cp "$CONF" "${CONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    }
    SHOULD_REGEN=1
fi

# ---- 生成 32 HEX 密钥 ----
gen_secret() {
    local s=""
    s=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' 2>/dev/null || true)
    [ "${#s}" -ne 32 ] && s=$(openssl rand -hex 16 2>/dev/null || true)
    while [ "${#s}" -lt 32 ]; do s="${s}$(printf '%02x' $((RANDOM & 0xFF)))"; done
    echo "${s:0:32}"
}

# ---- 域名转 HEX (Go 版 mtg 需要把域名拼进 secret) ----
domain_to_hex() {
    echo -n "$1" | od -A n -t x1 | tr -d ' \n'
}

# ---- Base64URL 编码 MTProto tg://proxy secret ----
# 输入: 32hex 裸密钥, 域名
# 输出: Base64URL(0xEE字节 + 16字节密钥 + 域名字节), 去=, +→-, /→_
b64url_proxy_secret() {
    local s32="$1"
    local dom="$2"
    local hex="ee${s32}"
    local hb=""
    local i=0
    while [ "$i" -lt ${#hex} ]; do
        hb="${hb}\\x${hex:$i:2}"
        i=$((i + 2))
    done
    { printf '%b' "$hb"; printf '%s' "$dom"; } \
        | base64 -w0 2>/dev/null \
        | tr -d '\r\n' \
        | sed 's/=*$//; y/+\//-_/'
}

# ---- 初始化 users.json (多用户账本) ----
init_users_file() {
    if [ ! -f "$USERS_FILE" ]; then
        local default_secret
        default_secret=$(gen_secret)
        cat > "$USERS_FILE" <<EOF
{
  "users": [
    {
      "name": "admin",
      "secret": "$default_secret",
      "quota_gb": 0,
      "expire": "",
      "speed_limit": "",
      "port": 0
    }
  ]
}
EOF
        chmod 600 "$USERS_FILE"
    fi
}

# ========================================================================
# 引擎 A: mtg-go (Go)
# ========================================================================
if [ "$ENGINE" = "mtg" ]; then

    if [ "$SHOULD_REGEN" -eq 1 ]; then
        echo ">>> 生成 mtg-go 配置 ($PROTO_MODE_DISPLAY)"
        RAW_SECRET=$(gen_secret)
        DOMAIN_HEX=$(domain_to_hex "$DOMAIN")
        # Go 版完整 secret: ee + 32hex + 域名hex
        FULL_SECRET="ee${RAW_SECRET}${DOMAIN_HEX}"

        # IP 策略
        case "$IP_MODE" in
            v6)    IP_FLAG="prefer-ipv6" ;;
            dual)  IP_FLAG="prefer-ipv4" ;;
            *)     IP_FLAG="only-ipv4" ;;
        esac

        CONF_TMP=$(mktemp "$DATA_DIR/.mtg.conf.XXXXXX")
        cat > "$CONF_TMP" <<EOF
PORT=$PORT
SECRET=$FULL_SECRET
RAW_SECRET=$RAW_SECRET
DOMAIN=$DOMAIN
DOMAIN_HEX=$DOMAIN_HEX
IP_MODE=$IP_MODE
IP_FLAG=$IP_FLAG
EOF
        chmod 600 "$CONF_TMP"
        mv -f "$CONF_TMP" "$CONF"
        echo -n "$FULL_SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        rm -f "$REGEN_FILE"

        echo "=============================="
        echo " mtg-go 配置已创建"
        echo " 引擎: $ENGINE_NAME"
        echo " 模式: $PROTO_MODE_DISPLAY"
        echo " 端口: $PORT"
        echo " 域名: $DOMAIN"
        echo " IP模式: $IP_MODE"
        echo " 密钥(掩码): ${RAW_SECRET:0:4}****${RAW_SECRET: -4}"
        echo "=============================="
    fi

    # 启动 mtg-go (simple-run 命令, 和 webbrain-one 一致)
    CONF_PORT=$(sed -n 's/^PORT=//p' "$CONF" | tail -1)
    SECRET=$(sed -n 's/^SECRET=//p' "$CONF" | tail -1)
    [[ "$CONF_PORT" =~ ^[0-9]+$ ]] && [ "$CONF_PORT" -ge 1 ] && [ "$CONF_PORT" -le 65535 ] || {
        echo ">>> ❌ mtg.conf 中的 PORT 无效"
        exit 1
    }
    [[ "$SECRET" =~ ^ee[0-9a-fA-F]{32,}$ ]] || { echo ">>> ❌ mtg.conf 中的 SECRET 无效"; exit 1; }
    PORT="$CONF_PORT"
    echo ">>> mtg-go 启动中..."
    DNS_FLAG="-n 1.1.1.1"
    case "$IP_MODE" in
        v6)    IP_FLAG="prefer-ipv6" ;;
        dual)  IP_FLAG="prefer-ipv4" ;;
        *)     IP_FLAG="only-ipv4" ;;
    esac
    case "$IP_MODE" in
        v6|dual) BIND_ADDR="[::]:$PORT" ;;
        *)       BIND_ADDR="0.0.0.0:$PORT" ;;
    esac
    mtg-go simple-run $DNS_FLAG -t 30s -a 1mb -c 65535 -i "$IP_FLAG" "$BIND_ADDR" "$SECRET" &
    ENGINE_PID=$!

    # 等待就绪
    sleep 2
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        wait "$ENGINE_PID"
        exit $?
    fi

    # 输出链接
    echo ""
    echo "=============================="
    echo " 代理链接 (mtg-go · Telegram 内直接点击)"
    echo "=============================="
    if [ -n "$HOST_IP" ]; then
        echo "tg://proxy?server=$HOST_IP&port=$PORT&secret=$SECRET"
        echo "https://t.me/proxy?server=$HOST_IP&port=$PORT&secret=$SECRET"
    else
        echo "tg://proxy?server=<服务器IP>&port=$PORT&secret=$SECRET"
        echo "https://t.me/proxy?server=<服务器IP>&port=$PORT&secret=$SECRET"
    fi
    echo "=============================="
    echo ""

# ========================================================================
# 引擎 B: telemt (Rust, 默认)
# ========================================================================
else

    if [ "$SHOULD_REGEN" -eq 1 ]; then
        echo ">>> 生成 telemt 配置 ($PROTO_MODE_DISPLAY)"
        init_users_file

        # 从 users.json 读取所有用户, 生成 TOML [access.users] 段
        generate_users_toml() {
            jq -r '.users[] | "\(.name | @json) = \(.secret | @json)"' "$USERS_FILE" 2>/dev/null || printf '"admin" = "%s"\n' "$(gen_secret)"
        }

        # 生成 [access.user_ports] 段 (有专属端口的用户)
        generate_ports_toml() {
            jq -r '.users[] | select(.port > 0) | "\(.name | @json) = \(.port)"' "$USERS_FILE" 2>/dev/null || true
        }

        # 生成 [access.user_data_quota] 段 (有配额的用户, GB→字节)
        generate_quota_toml() {
            jq -r '.users[] | select(.quota_gb > 0) | "\(.name | @json) = \((.quota_gb * 1073741824) | floor)"' "$USERS_FILE" 2>/dev/null || true
        }

        # 生成 [access.user_expirations] 段 (有到期的用户)
        generate_expirations_toml() {
            jq -r '.users[] | select(.expire != "" and .expire != null) | "\(.name | @json) = \(.expire)"' "$USERS_FILE" 2>/dev/null || true
        }

        # 生成 [access.user_speed_limits] 段 (有限速的用户)
        generate_speed_limits_toml() {
            jq -r '.users[] | select(.speed_limit != "" and .speed_limit != null) | "\(.name | @json) = \(.speed_limit | @json)"' "$USERS_FILE" 2>/dev/null || true
        }

        # listener 配置
        LISTENER_V4=""
        LISTENER_V6=""
        case "$IP_MODE" in
            v4)
                LISTENER_V4='ip = "0.0.0.0"'
                ;;
            v6)
                LISTENER_V6='ip = "::"'
                ;;
            dual)
                LISTENER_V4='ip = "0.0.0.0"'
                LISTENER_V6='ip = "::"'
                ;;
            *)
                LISTENER_V4='ip = "0.0.0.0"'
                ;;
        esac

        # 生成完整 telemt.toml
        CONF_TMP=$(mktemp "$DATA_DIR/.telemt.toml.XXXXXX")
        {
            echo "# Telemt Configuration (Rust + Tokio)"
            echo "# 基于 webbrain-one/MTProxy 配置格式"
            echo ""
            echo "[general]"
            echo "use_middle_proxy = false"
            echo "log_level = \"normal\""
            echo ""
            echo "[general.modes]"
            echo "classic = false"
            echo "secure  = false"
            echo "tls     = true"
            echo ""
            echo "[general.links]"
            echo "show = \"*\""
            echo ""
            echo "[server]"
            echo "port = $PORT"
            echo ""
            echo "[server.api]"
            echo "enabled = true"
            echo "listen = \"127.0.0.1:9091\""
            echo "whitelist = [\"127.0.0.1/32\", \"::1/128\"]"
            echo "minimal_runtime_enabled = false"
            echo ""
            if [ -n "$LISTENER_V4" ]; then
                echo "[[server.listeners]]"
                echo "$LISTENER_V4"
            fi
            if [ -n "$LISTENER_V6" ]; then
                [ -n "$LISTENER_V4" ] && echo ""
                echo "[[server.listeners]]"
                echo "$LISTENER_V6"
            fi
            echo ""
            echo "[censorship]"
            printf 'tls_domain = %s\n' "$(jq -Rn --arg value "$DOMAIN" '$value | @json')"
            echo "mask = true"
            echo "tls_emulation = true"
            echo "tls_front_dir = \"/data/tlsfront\""
            echo ""
            echo "[access.users]"
            generate_users_toml
            echo ""

            # 可选段: 仅在有数据时输出
            PORTS_TOML=$(generate_ports_toml)
            if [ -n "$PORTS_TOML" ]; then
                echo "[access.user_ports]"
                echo "$PORTS_TOML"
                echo ""
            fi

            QUOTA_TOML=$(generate_quota_toml)
            if [ -n "$QUOTA_TOML" ]; then
                echo "[access.user_data_quota]"
                echo "$QUOTA_TOML"
                echo ""
            fi

            EXP_TOML=$(generate_expirations_toml)
            if [ -n "$EXP_TOML" ]; then
                echo "[access.user_expirations]"
                echo "$EXP_TOML"
                echo ""
            fi

            SPEED_TOML=$(generate_speed_limits_toml)
            if [ -n "$SPEED_TOML" ]; then
                echo "[access.user_speed_limits]"
                echo "$SPEED_TOML"
                echo ""
            fi
        } > "$CONF_TMP"

        chmod 600 "$CONF_TMP"
        mv -f "$CONF_TMP" "$CONF"
        rm -f "$REGEN_FILE"

        # 取第一个用户的 secret 存入 .secret (兼容脚本快速读取)
        FIRST_SECRET=$(jq -r '.users[0].secret' "$USERS_FILE" 2>/dev/null || echo "")
        [ -n "$FIRST_SECRET" ] && echo -n "$FIRST_SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"

        echo "=============================="
        echo " Telemt 配置已创建"
        echo " 引擎: $ENGINE_NAME"
        echo " 模式: $PROTO_MODE_DISPLAY"
        echo " 端口: $PORT"
        echo " 域名: $DOMAIN"
        echo " IP模式: $IP_MODE"
        echo " 用户数: $(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 1)"
        echo "=============================="
        echo
    fi

    # ---- 启动 telemt ----
    echo ">>> Telemt 启动中..."
    export RUST_LOG=info
    telemt "$CONF" &
    ENGINE_PID=$!

    # 后台启动即使发生 Exec format error，启动语句本身也可能返回 0。
    # 必须显式确认子进程仍存活，禁止在引擎未运行时输出假链接。
    sleep 0.2
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo ">>> ❌ telemt 启动失败，可能是镜像架构与宿主机不匹配"
        wait "$ENGINE_PID"
        exit $?
    fi

    # ---- 立即准备链接；Control API 仅用于补充官方链接 ----
    API_OK=0
    API_JSON=""
    EE_SECRET=""
    IPV4_LINKS=""
    IPV6_LINKS=""
    if [ -f "$USERS_FILE" ] && jq -e '.users | type == "array" and length > 0' "$USERS_FILE" >/dev/null 2>&1; then
        USER_COUNT=$(jq '.users | length' "$USERS_FILE")
        for i in $(seq 0 $((USER_COUNT - 1))); do
            UNAME=$(jq -r ".users[$i].name // \"user$i\"" "$USERS_FILE")
            USECRET=$(jq -r ".users[$i].secret // empty" "$USERS_FILE")
            [ -z "$USECRET" ] && continue
            B64=$(b64url_proxy_secret "$USECRET" "$DOMAIN")
            [ -z "$EE_SECRET" ] && EE_SECRET="$B64"
            if [ -n "$HOST_IP" ]; then
                IPV4_LINKS="${IPV4_LINKS}用户: $UNAME\ntg://proxy?server=$HOST_IP&port=$PORT&secret=$B64\nhttps://t.me/proxy?server=$HOST_IP&port=$PORT&secret=$B64\n\n"
            else
                IPV4_LINKS="${IPV4_LINKS}用户: $UNAME\ntg://proxy?server=<服务器IP>&port=$PORT&secret=$B64\nhttps://t.me/proxy?server=<服务器IP>&port=$PORT&secret=$B64\n\n"
            fi
        done
    fi

    # API 只做一次短探测；users.json 链接已经足够直接使用
    API_JSON=$(curl -s --max-time 0.2 http://127.0.0.1:9091/v1/users 2>/dev/null || true)
    if [ -n "$API_JSON" ] && echo "$API_JSON" | jq -e '.data | type == "array" and length > 0' >/dev/null 2>&1; then
        API_OK=1
        echo ">>> ✅ Control API 就绪"
    fi

    # ---- 从 API 提取每个用户的最终 Base64URL secret (不用 API 返回的 server/port,避免 Docker 内网 IP) ----
    if [ "$API_OK" -eq 1 ] && [ -z "$IPV4_LINKS" ] && command -v jq >/dev/null 2>&1; then
        USER_COUNT=$(echo "$API_JSON" | jq '.data | length' 2>/dev/null || echo 0)
        if [ "$USER_COUNT" -gt 0 ]; then
            for i in $(seq 0 $((USER_COUNT - 1))); do
                UNAME=$(echo "$API_JSON" | jq -r ".data[$i].name // \"user$i\"" 2>/dev/null)
                # 从该用户第一条 tls 链接里提取 Base64URL secret
                USER_TLS_LINK=$(echo "$API_JSON" | jq -r ".data[$i].links.tls[0] // empty" 2>/dev/null || echo "")
                USER_SECRET_B64=""
                if [ -n "$USER_TLS_LINK" ]; then
                    USER_SECRET_B64=$(echo "$USER_TLS_LINK" | sed -E 's/^.*[?&]secret=([^&#]+).*$/\1/' 2>/dev/null || echo "")
                fi
                [ -z "$USER_SECRET_B64" ] && continue
                [ -z "$EE_SECRET" ] && EE_SECRET="$USER_SECRET_B64"

                # 输出用 HOST_IP (宿主机传入) + PORT + 官方 secret 拼链接
                if [ -n "$HOST_IP" ]; then
                    IPV4_LINKS="${IPV4_LINKS}用户: $UNAME\ntg://proxy?server=$HOST_IP&port=$PORT&secret=$USER_SECRET_B64\nhttps://t.me/proxy?server=$HOST_IP&port=$PORT&secret=$USER_SECRET_B64\n\n"
                else
                    IPV4_LINKS="${IPV4_LINKS}用户: $UNAME\ntg://proxy?server=<服务器IP>&port=$PORT&secret=$USER_SECRET_B64\nhttps://t.me/proxy?server=<服务器IP>&port=$PORT&secret=$USER_SECRET_B64\n\n"
                fi
            done
        fi
    fi

    [ -n "$EE_SECRET" ] && echo -n "$EE_SECRET" > "$SECRET_FILE" && chmod 600 "$SECRET_FILE"

    # ---- 打印链接 ----
    echo ""
    echo "=============================="
    echo " ⚠️  安全警告: 以下链接含代理密钥,请勿泄露"
    echo "=============================="
    echo ""
    echo "=============================="
    echo " 代理链接 ($ENGINE_NAME · 点击即用)"
    echo "=============================="

    HAD_OUTPUT=0
    [ -n "$IPV6_LINKS" ] && { echo ">>> IPv6:"; echo -e "$IPV6_LINKS" | sed '/^$/d' | awk '!seen[$0]++'; echo ""; HAD_OUTPUT=1; }
    [ -n "$IPV4_LINKS" ] && { echo ">>> IPv4:"; echo -e "$IPV4_LINKS" | sed '/^$/d' | awk '!seen[$0]++'; echo ""; HAD_OUTPUT=1; }

    if [ "$HAD_OUTPUT" -ne 1 ] && [ -n "$EE_SECRET" ]; then
        echo ">>> 兜底 (HOST_IP 拼装):"
        if [ -z "$HOST_IP" ]; then
            echo "tg://proxy?server=<服务器IP>&port=$PORT&secret=$EE_SECRET"
            echo "https://t.me/proxy?server=<服务器IP>&port=$PORT&secret=$EE_SECRET"
        else
            echo "tg://proxy?server=$HOST_IP&port=$PORT&secret=$EE_SECRET"
            echo "https://t.me/proxy?server=$HOST_IP&port=$PORT&secret=$EE_SECRET"
        fi
        echo ""
    fi

    if [ "$HAD_OUTPUT" -ne 1 ] && [ -z "$EE_SECRET" ]; then
        echo ">>> ❌ 未能生成链接,请检查日志:"
        echo "    docker logs <name>"
        echo ">>> 手动获取 (API 就绪后):"
        echo "    docker exec <name> curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[]?'"
    fi

    echo "=============================="
    echo ">>> 查看所有用户链接(官方推荐):"
    echo "    docker exec <name> curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[]?'"
    echo ">>> 多用户管理: bash tg.install.sh → 选 6"
    echo ">>> 切换引擎: -e ENGINE=mtg (Go回退)"
    echo "=============================="
    echo ""

fi

# ---- 等待引擎进程 ----
wait "$ENGINE_PID"
