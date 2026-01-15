#!/bin/bash
set -e

# 默认配置
PORT=${PORT:-443}
DOMAIN=${DOMAIN:-hostupdate.vmware.com}
HOST_IP=${HOST_IP:-$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 ip.sb || echo "0.0.0.0")}

DATA_DIR=/data
mkdir -p "$DATA_DIR"

CONF="$DATA_DIR/mtg.toml"

# 如果配置不存在,就生成
if [ ! -f "$CONF" ]; then
    echo ">>> 正在创建 MTG 配置文件"

    SECRET=$(mtg generate-secret "$DOMAIN")

    cat > "$CONF" <<EOF
# MTG Configuration
# refer to https://github.com/9seconds/mtg/blob/master/example.config.toml

secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"
concurrency = 8192
tcp-buffer = "128kb"
prefer-ip = "prefer-ipv4"
domain-fronting-port = 443
tolerate-time-skewness = "5s"

[network]
doh-ip = "9.9.9.9"
proxies = [
    # "socks5://user:password@host:port?open_threshold=5&half_open_timeout=1m&reset_failures_timeout=10s"
]

[network.timeout]
tcp = "5s"
http = "10s"
idle = "1m"

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001

[defense.blocklist]
enabled = true
download-concurrency = 2
urls = [
    # "https://iplists.firehol.org/files/firehol_level1.netset",
    # "/local.file"
]
update-each = "24h"
EOF

    echo "=============================="
    echo " MTG 配置已创建"
    echo " 端口: $PORT"
    echo " 域名: $DOMAIN"
    echo " 密钥: $SECRET"
    echo "=============================="
    echo
fi

# 启动 MTG 服务(后台运行以便打印链接)
echo ">>> MTG 服务正在启动..."
mtg run "$CONF" &
MTG_PID=$!

# 等待服务启动
sleep 3

# 打印代理链接
echo ""
echo "=============================="
echo " 代理链接"
echo "=============================="

# 尝试使用 mtg access 命令获取链接
if command -v jq > /dev/null 2>&1; then
    MTG_OUTPUT=$(mtg access "$CONF" 2>/dev/null || echo "")
    
    if [ -n "$MTG_OUTPUT" ]; then
        IPV6_URL=$(echo "$MTG_OUTPUT" | jq -r '.ipv6.tme_url // empty' 2>/dev/null || echo "")
        IPV4_URL=$(echo "$MTG_OUTPUT" | jq -r '.ipv4.tme_url // empty' 2>/dev/null || echo "")
        
        if [ -n "$IPV6_URL" ]; then
            echo ">>> IPv6 访问链接:"
            echo "$IPV6_URL"
            echo ""
        fi
        
        if [ -n "$IPV4_URL" ]; then
            echo ">>> IPv4 访问链接:"
            echo "$IPV4_URL"
            echo ""
        fi
    fi
fi

# 如果 mtg access 没有返回链接,手动构造
if [ -z "$IPV4_URL" ] && [ -z "$IPV6_URL" ]; then
    echo ">>> 手动构造的代理链接:"
    SECRET=$(grep '^secret' "$CONF" | sed 's/.*= "\(.*\)"/\1/')
    echo "tg://proxy?server=$HOST_IP&port=$PORT&secret=$SECRET"
    echo ""
fi

echo "=============================="
echo ">>> 查看所有可用链接,运行: docker exec <container_name> mtg access /data/mtg.toml"
echo "=============================="
echo ""

# 等待 MTG 进程
wait $MTG_PID
