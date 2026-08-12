# MTProxy Docker

基于 [webbrain-one/MTProxy](https://github.com/webbrain-one/MTProxy) / [0xdabiaoge/MTProxy](https://github.com/0xdabiaoge/MTProxy) 的 Docker 化版本。

## 特性

- **双引擎**: telemt (Rust, 默认) + mtg-go (Go, 回退), 运行时 `ENGINE` 环境变量切换
- **多用户管理**: telemt 原生多用户, 每用户独立密钥和分享链接
- **流量配额**: 按用户设置 GB 级流量上限, 超量自动断流
- **到期时间**: ISO 8601 格式, 到期自动封禁
- **带宽限速**: 上行/下行分别限速 (MB/s)
- **抗 AI DPI**: TLS 证书长度仿真 + 未知流量掩码转发
- **多架构**: amd64 + arm64, GitHub Actions 自动构建

## 快速开始

```bash
# 一键脚本 (交互菜单)
wget -N --no-check-certificate https://raw.githubusercontent.com/shidahuilang/mtg/main/tg.install.sh && chmod +x tg.install.sh && bash tg.install.sh
```

## Docker 手动运行

```bash
# telemt (Rust, 默认, 多用户)
docker run -d --name mtg -p 8443:8443 -v ./data:/data --user root \
  -e PORT=8443 -e FAKEDOMAIN=www.apple.com -e ENGINE=telemt \
  shidahuilang/mtg:latest

# mtg-go (Go, 单用户)
docker run -d --name mtg -p 8443:8443 -v ./data:/data --user root \
  -e PORT=8443 -e FAKEDOMAIN=www.apple.com -e ENGINE=mtg \
  shidahuilang/mtg:latest
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ENGINE` | `telemt` | 引擎: `telemt` (Rust多用户) / `mtg` (Go单用户) |
| `PORT` | `443` | 代理端口 |
| `FAKEDOMAIN` | `www.apple.com` | FakeTLS 伪装域名 |
| `IP_MODE` | `v4` | IP模式: `v4` / `v6` / `dual` |
| `FORCE_REGEN` | (空) | `true` 时本次启动强制重新生成配置；`mtg-go` 会更换密钥，不应长期设置 |
| `TZ` | `Asia/Shanghai` | 时区 |

## 查看代理链接

```bash
# telemt 引擎 (官方推荐)
docker exec mtg curl -s http://127.0.0.1:9091/v1/users | jq -r '.data[].links.tls[]?'

# mtg-go 引擎
docker exec mtg cat /data/.secret

# 通用 (日志)
docker logs mtg 2>&1 | grep -E "(tg://|https://t\.me/)" | tail -10
```

## 多用户管理

运行 `bash tg.install.sh` 选 `6) Telemt 多用户管理`:

- 查看所有用户及分享链接
- 添加/删除用户
- 设置流量配额 (GB)
- 设置到期时间
- 设置带宽限速

## docker-compose

```yaml
version: "3.8"
services:
  mtg:
    image: shidahuilang/mtg:latest
    container_name: mtg
    restart: unless-stopped
    ports:
      - "8443:8443"
    volumes:
      - ./data:/data
    environment:
      - PORT=8443
      - FAKEDOMAIN=www.apple.com
      - ENGINE=telemt
      - IP_MODE=v4
      - TZ=Asia/Shanghai
    user: root
```

## 致谢

- [webbrain-one/MTProxy](https://github.com/webbrain-one/MTProxy) - 原始管理脚本
- [0xdabiaoge/MTProxy](https://github.com/0xdabiaoge/MTProxy) - 优化编译二进制
- [9seconds/mtg](https://github.com/9seconds/mtg) - Go 版 MTProto 代理
- [telemt/telemt](https://github.com/telemt/telemt) - Rust 版 MTProto 代理
