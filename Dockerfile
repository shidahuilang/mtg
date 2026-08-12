# MTProxy Docker 镜像 (基于 webbrain-one/MTProxy / 0xdabiaoge/MTProxy 双内核优化版)
# 引擎: telemt (Rust, 多用户/配额/限速) + mtg-go (Go, 单用户高性能)
# 二进制来源: https://github.com/0xdabiaoge/MTProxy/releases (源码优化编译版,非官方原版)
FROM alpine:3.19

# 系统依赖:
#   curl/wget      公网IP探测 + 调用 Control API
#   bash           entrypoint 脚本
#   ca-certificates TLS 证书链
#   jq             解析 telemt /v1/users JSON
#   libcap         setcap(允许非root绑定特权端口)
#   su-exec        轻量级用户切换
#   openssl        生成密钥
#   coreutils      date/timeout 等
#   tzdata         时区(配额到期判断用北京时间)
RUN apk add --no-cache \
    curl wget bash ca-certificates jq libcap su-exec openssl coreutils tzdata

WORKDIR /data

ARG TARGETARCH

# ===== 下载双引擎二进制 =====
# 兼容上游 release 各种命名惯例: amd64=x86_64, arm64=aarch64, arm/v7=armv7l
# 每个二进制都按优先级尝试多个候选文件名,第一个命中即使用;随后用 ELF machine header 强校验架构匹配
RUN set -eu; \
    apk add --no-cache --virtual .bin-deps curl ca-certificates file; \
    BASE_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/Go-Rust"; \
    [ -n "$TARGETARCH" ] || { echo "TARGETARCH is required; use Docker Buildx" >&2; exit 1; }; \
    \
    case "$TARGETARCH" in \
        amd64)  ELF_MACHINE="3e00"; ELF_FILE_PAT='x86[-_ ]?64'; \
                TELEMT_CAND="telemt-linux-amd64 telemt-linux-x86_64 telemt-x86_64-unknown-linux-musl telemt-x86_64-unknown-linux-gnu telemt-amd64"; \
                MTG_CAND="mtg-go-amd64 mtg-go-linux-amd64 mtg-go-linux-x86_64 mtg-linux-amd64 mtg-go-x86_64-unknown-linux-musl mtg-amd64" ;; \
        arm64)  ELF_MACHINE="b700"; ELF_FILE_PAT='aarch64|ARM aarch64'; \
                TELEMT_CAND="telemt-linux-arm64 telemt-linux-aarch64 telemt-aarch64-unknown-linux-musl telemt-aarch64-unknown-linux-gnu telemt-arm64"; \
                MTG_CAND="mtg-go-arm64 mtg-go-linux-arm64 mtg-go-linux-aarch64 mtg-linux-arm64 mtg-go-aarch64-unknown-linux-musl mtg-aarch64" ;; \
        arm/v7) ELF_MACHINE="2800"; ELF_FILE_PAT='ARM.*(EABI|HF|32-bit)'; \
                TELEMT_CAND="telemt-linux-armv7l telemt-linux-arm telemt-armv7-unknown-linux-musleabihf telemt-arm-unknown-linux-musleabihf"; \
                MTG_CAND="mtg-go-linux-armv7l mtg-go-linux-arm mtg-linux-armv7l mtg-go-armv7-unknown-linux-musleabihf" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    \
    download_first_match() { \
        local outfile="$1"; shift; \
        local ok=0 name rc; \
        for name in "$@"; do \
            if curl -fL --retry 3 --retry-delay 2 -o "$outfile" "$BASE_URL/$name" >/dev/null 2>&1; then \
                ok=1; echo "[install] $outfile <= $BASE_URL/$name"; break; \
            fi; \
        done; \
        [ "$ok" -eq 1 ] || { echo "[install] All candidates failed for $outfile: $*" >&2; exit 1; }; \
    }; \
    verify_elf_arch() { \
        local binary="$1"; \
        local INFO; INFO=$(file "$binary" 2>/dev/null || true); \
        echo "[verify] $binary: $INFO"; \
        # 1) ELF magic bytes
        head -c 4 "$binary" | od -An -tx1 | grep -q '7f 45 4c 46' || { echo "  -> NOT ELF" >&2; head -c 300 "$binary" | od -c | head -n 5 >&2; return 1; }; \
        # 2) ELF machine bytes (offset 18, 2 bytes little-endian -> string)
        local ACTUAL_MACHINE; ACTUAL_MACHINE="$(dd if="$binary" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"; \
        [ "$ACTUAL_MACHINE" = "$ELF_MACHINE" ] || { echo "  -> machine bytes mismatch: want=$ELF_MACHINE got=$ACTUAL_MACHINE" >&2; return 1; }; \
        # 3) `file` output pattern sanity
        echo "$INFO" | grep -qiE "$ELF_FILE_PAT" || { echo "  -> file output mismatch pattern ($ELF_FILE_PAT)" >&2; return 1; }; \
        return 0; \
    }; \
    \
    download_first_match /usr/bin/telemt $TELEMT_CAND; \
    verify_elf_arch  /usr/bin/telemt || { echo "[fatal] telemt architecture mismatch (target=$TARGETARCH)" >&2; exit 1; }; \
    \
    download_first_match /usr/bin/mtg-go $MTG_CAND; \
    verify_elf_arch  /usr/bin/mtg-go || { echo "[fatal] mtg-go architecture mismatch (target=$TARGETARCH)" >&2; exit 1; }; \
    \
    chmod 0755 /usr/bin/telemt /usr/bin/mtg-go; \
    # 允许非 root 绑定特权端口
    setcap 'cap_net_bind_service=+ep' /usr/bin/telemt; \
    setcap 'cap_net_bind_service=+ep' /usr/bin/mtg-go; \
    \
    apk del .bin-deps; \
    rm -rf /var/cache/apk/* /tmp/* /root/.cache; \
    echo "✅ Both binaries installed ($TARGETARCH)"; \
    ls -lh /usr/bin/telemt /usr/bin/mtg-go

# 创建非特权用户
RUN addgroup -g 1000 -S mtg && \
    adduser -u 1000 -S -G mtg -h /data -s /sbin/nologin mtg

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh && chown -R mtg:mtg /data

VOLUME /data

# 代理端口 443/8443 + Control API 9091 + metrics 9090
EXPOSE 443 8443 9090 9091

USER mtg

ENTRYPOINT ["/entrypoint.sh"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD pidof telemt >/dev/null 2>&1 || pidof mtg-go >/dev/null 2>&1 || exit 1
