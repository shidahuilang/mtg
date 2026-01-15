# 多架构 MTG 镜像
FROM alpine:3.19 AS base

# 安装必要依赖(添加 jq 用于解析 mtg access 输出)
RUN apk add --no-cache curl bash ca-certificates jq

WORKDIR /data

ARG TARGETARCH

# 如果本地文件存在则使用,否则从 GitHub 下载
RUN MTG_VERSION=2.1.7; \
    if [ -f "bin/mtg-${TARGETARCH}" ]; then \
    echo "✅ Using local MTG binary for ${TARGETARCH}"; \
    cp bin/mtg-${TARGETARCH} /usr/bin/mtg; \
    chmod +x /usr/bin/mtg; \
    else \
    echo "📥 Local binary not found, downloading from GitHub..."; \
    if [ "$TARGETARCH" = "amd64" ]; then \
    URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-amd64.tar.gz"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
    URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-arm64.tar.gz"; \
    else \
    echo "❌ Unsupported arch: $TARGETARCH"; exit 1; \
    fi; \
    echo "Downloading from $URL"; \
    curl -L "$URL" -o /tmp/mtg.tar.gz; \
    mkdir /tmp/mtg_tmp; \
    tar -xzf /tmp/mtg.tar.gz -C /tmp/mtg_tmp --strip-components=1; \
    mv /tmp/mtg_tmp/mtg /usr/bin/mtg; \
    chmod +x /usr/bin/mtg; \
    rm -rf /tmp/mtg.tar.gz /tmp/mtg_tmp; \
    echo "✅ Downloaded successfully"; \
    fi

# 验证二进制文件
RUN mtg --version

# 拷贝 entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME /data
EXPOSE 443

ENTRYPOINT ["/entrypoint.sh"]
