#!/bin/bash
set -e

# 彩色输出函数
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# 检测并安装 Docker
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    yellow "> 未检测到 Docker,正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    green "✓ Docker 安装完成"
  else
    # 检查 Docker 服务是否运行
    if ! systemctl is-active --quiet docker 2>/dev/null; then
      yellow "> Docker 服务未运行,正在启动..."
      systemctl start docker
    fi
  fi
}

# 获取所有 MTG 容器
get_containers() {
  docker ps -a --filter "name=mtg_" --format "{{.Names}}" 2>/dev/null || true
}

# 获取运行中的 MTG 容器
get_running_containers() {
  docker ps --filter "name=mtg_" --format "{{.Names}}" 2>/dev/null || true
}

# 安装 MTG
install_mtg() {
  clear
  green "========== 安装 MTG 代理 =========="
  echo ""
  
  check_docker
  
  # 选择模式
  echo ""
  yellow "请选择模式:"
  echo "1) 要(更隐蔽 FakeTLS)"
  echo "2) 不要(简单 UDP)"
  read -p "请选择 [1/2] (默认1): " MODE
  
  if [ "$MODE" = "2" ]; then
    MODE="udp"
  else
    MODE="tls"
  fi
  
  # MTG 端口
  read -p "请输入 MTG 端口 (回车随机): " MTG_PORT
  if [ -z "$MTG_PORT" ]; then
    MTG_PORT=$(shuf -i 20000-65000 -n1)
  fi
  
  # FakeTLS 域名
  if [ "$MODE" = "tls" ]; then
    read -p "FakeTLS 域名 (默认 www.microsoft.com): " FAKEDOMAIN
    if [ -z "$FAKEDOMAIN" ]; then
      FAKEDOMAIN="www.microsoft.com"
    fi
  fi
  
  NAME="mtg_$MTG_PORT"
  
  # 检查容器是否已存在
  if docker ps -a --format "{{.Names}}" | grep -q "^${NAME}$"; then
    red "> 容器 $NAME 已存在!"
    yellow "> 请先卸载或使用不同的端口"
    return 1
  fi
  
  echo ""
  yellow "> 正在启动 MTG 容器..."
  
  docker run -d \
    --name $NAME \
    --restart always \
    -p $MTG_PORT:$MTG_PORT \
    -e PORT=$MTG_PORT \
    -e FAKEDOMAIN=$FAKEDOMAIN \
    shidahuilang/mtg
  
  green "✓ 容器启动成功"
  
  # 等待容器启动
  sleep 3
  
  # 获取公网 IP
  yellow "> 正在获取公网 IP..."
  IP=$(curl -s ifconfig.me || curl -s ip.sb || echo "获取失败")
  
  echo ""
  green "===================================="
  green " ✓ MTG 已启动"
  echo " 容器名称: $NAME"
  echo " MTG 端口: $MTG_PORT"
  if [ "$MODE" = "tls" ]; then
    echo " FakeTLS: $FAKEDOMAIN"
  fi
  echo ""
  echo " 服务器: $IP:$MTG_PORT"
  green "===================================="
  echo ""
  yellow "> 正在获取代理链接..."
  sleep 2
  docker logs $NAME 2>&1 | grep -E "(tg://|https://t.me/)" || yellow "> 请稍后使用 'docker logs $NAME' 查看代理链接"
  echo ""
  green "✓ 安装完成"
}

# 查看状态和代理链接
show_status() {
  clear
  green "========== 状态和代理链接 =========="
  echo ""
  
  containers=$(get_containers)
  
  if [ -z "$containers" ]; then
    yellow "未找到 MTG 容器"
    return
  fi
  
  for container in $containers; do
    echo ""
    yellow "=== 容器: $container ==="
    
    # 显示容器状态
    status=$(docker inspect --format='{{.State.Status}}' $container 2>/dev/null || echo "未知")
    if [ "$status" = "running" ]; then
      green "状态: 运行中 ✓"
    else
      red "状态: $status"
    fi
    
    # 显示端口
    port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{(index $conf 0).HostPort}}{{end}}{{end}}' $container 2>/dev/null || echo "未知")
    echo "端口: $port"
    
    # 显示代理链接
    if [ "$status" = "running" ]; then
      echo ""
      yellow "> 代理链接:"
      docker logs $container 2>&1 | grep -E "(tg://|https://t.me/)" | tail -5 || yellow "  无法获取链接,请检查日志"
    fi
    echo ""
  done
  
  yellow "> 提示: 使用 'docker logs <容器名>' 查看完整日志"
}

# 重启容器
restart_container() {
  clear
  green "========== 重启容器 =========="
  echo ""
  
  containers=$(get_containers)
  
  if [ -z "$containers" ]; then
    yellow "未找到 MTG 容器"
    return
  fi
  
  # 如果只有一个容器,直接重启
  container_count=$(echo "$containers" | wc -l)
  if [ "$container_count" -eq 1 ]; then
    container=$containers
  else
    # 多个容器,让用户选择
    yellow "找到以下容器:"
    echo "$containers" | nl
    read -p "请输入要重启的容器编号: " num
    container=$(echo "$containers" | sed -n "${num}p")
  fi
  
  if [ -z "$container" ]; then
    red "无效的选择"
    return 1
  fi
  
  yellow "> 正在重启容器 $container..."
  docker restart $container
  sleep 2
  green "✓ 容器已重启"
  echo ""
  docker ps --filter "name=$container" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 停止容器
stop_container() {
  clear
  green "========== 停止容器 =========="
  echo ""
  
  containers=$(get_running_containers)
  
  if [ -z "$containers" ]; then
    yellow "未找到运行中的 MTG 容器"
    return
  fi
  
  # 如果只有一个容器,直接停止
  container_count=$(echo "$containers" | wc -l)
  if [ "$container_count" -eq 1 ]; then
    container=$containers
  else
    # 多个容器,让用户选择
    yellow "找到以下运行中的容器:"
    echo "$containers" | nl
    read -p "请输入要停止的容器编号: " num
    container=$(echo "$containers" | sed -n "${num}p")
  fi
  
  if [ -z "$container" ]; then
    red "无效的选择"
    return 1
  fi
  
  yellow "> 正在停止容器 $container..."
  docker stop $container
  green "✓ 容器已停止"
}

# 启动容器
start_container() {
  clear
  green "========== 启动容器 =========="
  echo ""
  
  # 获取所有容器
  all_containers=$(get_containers)
  # 获取运行中的容器
  running_containers=$(get_running_containers)
  # 计算停止的容器
  stopped_containers=$(comm -23 <(echo "$all_containers" | sort) <(echo "$running_containers" | sort))
  
  if [ -z "$stopped_containers" ]; then
    yellow "未找到停止的 MTG 容器"
    return
  fi
  
  # 如果只有一个容器,直接启动
  container_count=$(echo "$stopped_containers" | wc -l)
  if [ "$container_count" -eq 1 ]; then
    container=$stopped_containers
  else
    # 多个容器,让用户选择
    yellow "找到以下停止的容器:"
    echo "$stopped_containers" | nl
    read -p "请输入要启动的容器编号: " num
    container=$(echo "$stopped_containers" | sed -n "${num}p")
  fi
  
  if [ -z "$container" ]; then
    red "无效的选择"
    return 1
  fi
  
  yellow "> 正在启动容器 $container..."
  docker start $container
  sleep 2
  green "✓ 容器已启动"
  echo ""
  docker ps --filter "name=$container" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 卸载 MTG
uninstall_mtg() {
  clear
  green "========== 卸载 MTG 代理 =========="
  echo ""
  
  containers=$(get_containers)
  
  if [ -z "$containers" ]; then
    yellow "未找到 MTG 容器"
    return
  fi
  
  yellow "找到以下容器:"
  echo "$containers" | nl
  echo ""
  red "⚠️  警告: 此操作将删除容器及其配置!"
  echo ""
  read -p "确认卸载? 输入 yes 继续: " confirm
  
  if [ "$confirm" != "yes" ]; then
    yellow "已取消卸载"
    return
  fi
  
  # 如果只有一个容器,直接卸载
  container_count=$(echo "$containers" | wc -l)
  if [ "$container_count" -eq 1 ]; then
    container=$containers
  else
    # 多个容器,让用户选择
    read -p "请输入要卸载的容器编号 (0=全部): " num
    if [ "$num" = "0" ]; then
      container="$containers"
    else
      container=$(echo "$containers" | sed -n "${num}p")
    fi
  fi
  
  if [ -z "$container" ]; then
    red "无效的选择"
    return 1
  fi
  
  for c in $container; do
    yellow "> 正在删除容器 $c..."
    docker stop $c 2>/dev/null || true
    docker rm $c 2>/dev/null || true
    green "✓ 已删除 $c"
  done
  
  echo ""
  green "✓ 卸载完成"
}

# 升级镜像
upgrade_mtg() {
  clear
  green "========== 升级 MTG 镜像 =========="
  echo ""
  
  yellow "> 正在拉取最新镜像..."
  docker pull shidahuilang/mtg:latest
  
  echo ""
  green "✓ 镜像已更新"
  echo ""
  yellow "> 提示: 请重启容器以使用新镜像"
  yellow ">       或卸载后重新安装"
}

# 显示菜单
show_menu() {
  clear
  green "=================================================="
  green "         MTG Telegram 代理管理脚本"
  green "=================================================="
  echo ""
  yellow "请选择操作:"
  echo "  1) 安装 MTG 代理"
  echo "  2) 查看状态和代理链接"
  echo "  3) 重启容器"
  echo "  4) 停止容器"
  echo "  5) 启动容器"
  echo "  6) 卸载 MTG 代理"
  echo "  7) 升级镜像"
  echo "  0) 退出"
  echo ""
  read -p "请输入选项 [0-7]: " choice
}

# 暂停并返回菜单
pause_menu() {
  echo ""
  read -p "按回车键返回主菜单..." dummy
}

# 主循环
main() {
  while true; do
    show_menu
    case $choice in
      1)
        install_mtg
        pause_menu
        ;;
      2)
        show_status
        pause_menu
        ;;
      3)
        restart_container
        pause_menu
        ;;
      4)
        stop_container
        pause_menu
        ;;
      5)
        start_container
        pause_menu
        ;;
      6)
        uninstall_mtg
        pause_menu
        ;;
      7)
        upgrade_mtg
        pause_menu
        ;;
      0)
        green "再见!"
        exit 0
        ;;
      *)
        red "无效选项,请重试"
        sleep 1
        ;;
    esac
  done
}

# 运行主菜单
main "$@"
