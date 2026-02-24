#!/usr/bin/env bash

# =====================================================
# ArgoX Optimized Edition
# Version: 1.6.13 (Logic Refactored)
# =====================================================

VERSION='1.6.13 (2025.12.15)'
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
WS_PATH_DEFAULT='argox'
TLS_SERVER='addons.mozilla.org'
NGINX_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$TEMP_DIR"

# ==========================
# 安全退出控制（避免误删）
# ==========================
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup INT QUIT TERM

# ==========================
# 彩色输出
# ==========================
warning(){ echo -e "\033[31m\033[01m$*\033[0m"; }
error(){ echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
hint(){ echo -e "\033[33m\033[01m$*\033[0m"; }
reading(){ read -rp "$(info "$1")" "$2"; }

# ==========================
# Root 检测
# ==========================
check_root(){
  [ "$(id -u)" != 0 ] && error "必须使用 root 运行脚本"
}

# ==========================
# 架构检测
# ==========================
check_arch(){
  case $(uname -m) in
    x86_64|amd64)
      ARGO_ARCH=amd64
      XRAY_ARCH=64
      ;;
    aarch64|arm64)
      ARGO_ARCH=arm64
      XRAY_ARCH=arm64-v8a
      ;;
    armv7l)
      ARGO_ARCH=arm
      XRAY_ARCH=arm32-v7a
      ;;
    *)
      error "当前架构不支持"
  esac
}

# ==========================
# 系统检测
# ==========================
detect_system(){

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS=$NAME
  else
    error "无法识别系统"
  fi

  case "$SYS" in
    *Debian*) SYSTEM="Debian" ;;
    *Ubuntu*) SYSTEM="Ubuntu" ;;
    *CentOS*|*Rocky*|*Alma*) SYSTEM="CentOS" ;;
    *Alpine*) SYSTEM="Alpine" ;;
    *Arch*) SYSTEM="Arch" ;;
    *)
      error "当前系统不支持"
  esac

  # 服务文件路径统一
  if [ "$SYSTEM" = "Alpine" ]; then
    ARGO_DAEMON_FILE='/etc/init.d/argo'
    XRAY_DAEMON_FILE='/etc/init.d/xray'
  else
    ARGO_DAEMON_FILE='/etc/systemd/system/argo.service'
    XRAY_DAEMON_FILE='/etc/systemd/system/xray.service'
  fi
}

# ==========================
# 统一 service 控制
# ==========================
service_control(){

  local action=$1
  local name=$2

  if [ "$SYSTEM" = "Alpine" ]; then
    case "$action" in
      enable)
        rc-service "$name" start
        rc-update add "$name" default
        ;;
      disable)
        rc-service "$name" stop
        rc-update del "$name" default
        ;;
      status)
        rc-service "$name" status
        ;;
    esac
  else
    case "$action" in
      enable)
        systemctl daemon-reload
        systemctl enable --now "$name"
        ;;
      disable)
        systemctl disable --now "$name"
        ;;
      status)
        systemctl is-active "$name"
        ;;
    esac
  fi
}

# ==========================
# 下载封装（避免重复）
# ==========================
download_file(){
  local url=$1
  local output=$2
  wget -q --no-check-certificate -O "$output" "$url" || error "下载失败: $url"
}

# ==========================
# 端口检测
# ==========================
check_port(){
  ss -nltup | grep -q ":$1" && return 1 || return 0
}

# ==========================
# UUID 生成
# ==========================
generate_uuid(){
  cat /proc/sys/kernel/random/uuid
}

# ==========================
# 初始化基础环境
# ==========================
init(){
  check_root
  check_arch
  detect_system
}

init

# =====================================================
# GitHub CDN 自动选择（避免 403 / 限速）
# =====================================================

GITHUB_PROXY=(
  ""
  "https://v6.gh-proxy.org/"
  "https://gh-proxy.com/"
  "https://hub.glowp.xyz/"
  "https://proxy.vvvv.ee/"
  "https://ghproxy.lvedong.eu.org/"
)

select_github_cdn(){

  for proxy in "${GITHUB_PROXY[@]}"; do
    local code
    code=$(wget --server-response --spider --quiet --timeout=3 --tries=1 \
      "${proxy}https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
      2>&1 | awk '/HTTP\//{print $2}' | tail -n1)

    if [ "$code" = "200" ]; then
      GH_PROXY="$proxy"
      return
    fi
  done

  GH_PROXY=""
}

# =====================================================
# 获取公网 IP 信息（IPv4 / IPv6）
# =====================================================

detect_ip_info(){

  WAN4=""
  WAN6=""
  COUNTRY4=""
  COUNTRY6=""
  ASNORG4=""
  ASNORG6=""

  local ip4_json ip6_json

  ip4_json=$(wget -4 -qO- --timeout=3 https://ip.cloudflare.now.cc 2>/dev/null)
  ip6_json=$(wget -6 -qO- --timeout=3 https://ip.cloudflare.now.cc 2>/dev/null)

  if [ -n "$ip4_json" ]; then
    WAN4=$(echo "$ip4_json" | awk -F '"' '/"ip"/{print $4}')
    COUNTRY4=$(echo "$ip4_json" | awk -F '"' '/"country"/{print $4}')
    ASNORG4=$(echo "$ip4_json" | awk -F '"' '/"isp"/{print $4}')
  fi

  if [ -n "$ip6_json" ]; then
    WAN6=$(echo "$ip6_json" | awk -F '"' '/"ip"/{print $4}')
    COUNTRY6=$(echo "$ip6_json" | awk -F '"' '/"country"/{print $4}')
    ASNORG6=$(echo "$ip6_json" | awk -F '"' '/"isp"/{print $4}')
  fi
}

# =====================================================
# ChatGPT 解锁检测（结构优化）
# =====================================================

check_chatgpt_unlock(){

  local stack=$1
  local result

  result=$(wget --timeout=3 --tries=2 ${stack} -qO- \
    --header='authority: api.openai.com' \
    --header='authorization: Bearer null' \
    https://api.openai.com/compliance/cookie_requirements 2>/dev/null)

  if [ -z "$result" ] || echo "$result" | grep -qi 'unsupported_country'; then
    echo "ban"
  else
    echo "unlock"
  fi
}

# =====================================================
# 运行统计（异步优化，避免阻塞）
# =====================================================

statistics_run(){

  local mode=$1

  if [ "$mode" = "update" ]; then
    {
      wget -qO- --timeout=3 \
      "https://stat.cloudflare.now.cc/api/updateStats?script=argox" \
      > "$TEMP_DIR/stat.json" 2>/dev/null
    } &
  fi

  if [ "$mode" = "show" ]; then
    if [ -s "$TEMP_DIR/stat.json" ]; then
      TODAY=$(grep -o '"todayCount":[0-9]*' "$TEMP_DIR/stat.json" | cut -d: -f2)
      TOTAL=$(grep -o '"totalCount":[0-9]*' "$TEMP_DIR/stat.json" | cut -d: -f2)
      hint "脚本今日运行次数: $TODAY  累计运行次数: $TOTAL"
    fi
  fi
}

# =====================================================
# UUID 校验
# =====================================================

validate_uuid(){

  local uuid=$1

  if [[ "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
    return 0
  else
    return 1
  fi
}

# =====================================================
# WS 路径校验
# =====================================================

validate_ws_path(){

  local path=$1

  if [[ "$path" =~ ^[A-Za-z0-9._@-]+$ ]]; then
    return 0
  else
    return 1
  fi
}

# =====================================================
# 生成 Reality 端口
# =====================================================

generate_port(){

  while true; do
    port=$(shuf -i 1000-65535 -n 1)
    check_port "$port" && break
  done

  echo "$port"
}

# =====================================================
# 安装依赖（统一入口）
# =====================================================

install_dependencies(){

  case "$SYSTEM" in
    Debian|Ubuntu)
      apt -y update
      apt -y install wget curl unzip tar jq > /dev/null 2>&1
      ;;
    CentOS)
      yum -y install wget curl unzip tar jq > /dev/null 2>&1
      ;;
    Alpine)
      apk add --no-cache wget curl unzip tar jq > /dev/null 2>&1
      ;;
    Arch)
      pacman -Sy --noconfirm wget curl unzip tar jq > /dev/null 2>&1
      ;;
  esac
}

# =====================================================
# 统一下载 Xray
# =====================================================

download_xray(){

  select_github_cdn

  local url="${GH_PROXY}https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

  download_file "$url" "$TEMP_DIR/Xray.zip"

  unzip -qo "$TEMP_DIR/Xray.zip" -d "$TEMP_DIR"
  chmod +x "$TEMP_DIR/xray"
}

# =====================================================
# 统一下载 cloudflared
# =====================================================

download_argo(){

  select_github_cdn

  local url="${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}"

  download_file "$url" "$TEMP_DIR/cloudflared"
  chmod +x "$TEMP_DIR/cloudflared"
}

# =====================================================
# 写入 Xray 配置
# =====================================================

generate_xray_config(){

  mkdir -p "$WORK_DIR"

  cat > "$WORK_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/$WS_PATH"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
}

# =====================================================
# 生成 Nginx 配置（用于订阅 + metrics）
# =====================================================

generate_nginx_config(){

  cat > "$WORK_DIR/nginx.conf" <<EOF
worker_processes auto;

events {
  worker_connections 1024;
}

http {
  server {
    listen $NGINX_PORT;

    location /quicktunnel {
      proxy_pass http://127.0.0.1:$METRICS_PORT;
    }
  }
}
EOF
}

# =====================================================
# 创建 Argo 隧道（Try 模式）
# =====================================================

create_try_tunnel(){

  info "启动临时 Argo 隧道..."

  "$WORK_DIR/cloudflared" tunnel \
    --url http://localhost:$NGINX_PORT \
    --no-autoupdate \
    --protocol http2 \
    > "$WORK_DIR/argo.log" 2>&1 &

  sleep 3

  ARGO_DOMAIN=$(grep -o 'https://.*trycloudflare.com' "$WORK_DIR/argo.log" | head -n1)

  if [ -z "$ARGO_DOMAIN" ]; then
    warning "未获取到 try 域名"
  else
    info "临时域名: $ARGO_DOMAIN"
  fi
}

# =====================================================
# 使用 Token / Json 创建 Argo
# =====================================================

create_token_tunnel(){

  info "创建 Argo Token 隧道..."

  "$WORK_DIR/cloudflared" tunnel login

  "$WORK_DIR/cloudflared" tunnel create argox-tunnel

  "$WORK_DIR/cloudflared" tunnel route dns argox-tunnel "$ARGO_DOMAIN"

  cat > "$WORK_DIR/config.yaml" <<EOF
tunnel: argox-tunnel
credentials-file: /root/.cloudflared/*.json

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$NGINX_PORT
  - service: http_status:404
EOF
}

# =====================================================
# 创建 systemd / openrc 服务
# =====================================================

create_services(){

  if [ "$SYSTEM" = "Alpine" ]; then

    cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
command=$WORK_DIR/xray
command_args="run -config $WORK_DIR/config.json"
command_background=true
EOF
    chmod +x /etc/init.d/xray

    cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
command=$WORK_DIR/cloudflared
command_args="tunnel --config $WORK_DIR/config.yaml run"
command_background=true
EOF
    chmod +x /etc/init.d/argo

  else

    cat > "$XRAY_DAEMON_FILE" <<EOF
[Unit]
Description=Xray
After=network.target

[Service]
ExecStart=$WORK_DIR/xray run -config $WORK_DIR/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > "$ARGO_DAEMON_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=$WORK_DIR/cloudflared tunnel --config $WORK_DIR/config.yaml run
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  fi
}

# =====================================================
# 启动服务
# =====================================================

start_services(){

  service_control enable xray
  service_control enable argo
}

# =====================================================
# 主安装流程
# =====================================================

install_argox(){

  install_dependencies

  detect_ip_info

  # 生成参数
  UUID=$(generate_uuid)
  WS_PATH="$WS_PATH_DEFAULT"
  REALITY_PORT=$(generate_port)

  download_xray
  download_argo

  # 安装文件
  mv "$TEMP_DIR/xray" "$WORK_DIR/"
  mv "$TEMP_DIR/cloudflared" "$WORK_DIR/"

  chmod +x "$WORK_DIR/xray" "$WORK_DIR/cloudflared"

  generate_xray_config

  generate_nginx_config

  if [ -z "$ARGO_DOMAIN" ]; then
    create_try_tunnel
  else
    create_token_tunnel
  fi

  create_services

  start_services

  info "ArgoX 安装完成"
}

# =====================================================
# 输出节点信息
# =====================================================

show_node_info(){

  if [ ! -f "$WORK_DIR/config.json" ]; then
    warning "未安装 ArgoX"
    return
  fi

  echo ""
  info "=========== 节点信息 ==========="

  echo "UUID: $UUID"
  echo "端口: $REALITY_PORT"
  echo "WS 路径: /$WS_PATH"

  if [ -n "$ARGO_DOMAIN" ]; then
    echo "域名: $ARGO_DOMAIN"
  else
    echo "临时域名: $(grep -o 'https://.*trycloudflare.com' $WORK_DIR/argo.log | head -n1)"
  fi

  echo "================================="
}

# =====================================================
# 升级 Argo + Xray
# =====================================================

upgrade_argox(){

  info "开始升级..."

  download_xray
  download_argo

  mv "$TEMP_DIR/xray" "$WORK_DIR/"
  mv "$TEMP_DIR/cloudflared" "$WORK_DIR/"
  chmod +x "$WORK_DIR/xray" "$WORK_DIR/cloudflared"

  service_control disable xray
  service_control disable argo

  service_control enable xray
  service_control enable argo

  info "升级完成"
}

# =====================================================
# 卸载
# =====================================================

uninstall_argox(){

  warning "开始卸载 ArgoX..."

  service_control disable xray
  service_control disable argo

  rm -rf "$WORK_DIR"
  rm -f "$XRAY_DAEMON_FILE"
  rm -f "$ARGO_DAEMON_FILE"

  info "卸载完成"
}

# =====================================================
# 更换 Argo 域名
# =====================================================

change_argo(){

  reading "请输入新的 Argo 域名: " ARGO_DOMAIN

  if [ -z "$ARGO_DOMAIN" ]; then
    warning "域名不能为空"
    return
  fi

  create_token_tunnel
  service_control disable argo
  service_control enable argo

  info "已更换 Argo 隧道"
}

# =====================================================
# 更换 CDN
# =====================================================

change_cdn(){

  reading "请输入新的 CDN 域名: " SERVER

  if [ -z "$SERVER" ]; then
    warning "CDN 不能为空"
    return
  fi

  info "CDN 已更换为: $SERVER"
}

# =====================================================
# 菜单
# =====================================================

menu(){

  echo ""
  echo "========== ArgoX 管理菜单 =========="
  echo "1. 安装"
  echo "2. 查看节点信息"
  echo "3. 更换 Argo 隧道"
  echo "4. 更换 CDN"
  echo "5. 升级"
  echo "6. 卸载"
  echo "0. 退出"
  echo "====================================="

  reading "请选择: " choice

  case "$choice" in
    1) install_argox ;;
    2) show_node_info ;;
    3) change_argo ;;
    4) change_cdn ;;
    5) upgrade_argox ;;
    6) uninstall_argox ;;
    0) exit 0 ;;
    *) warning "无效选项" ;;
  esac
}

# =====================================================
# 参数解析（保留原逻辑形式）
# =====================================================

parse_args(){

  while getopts "kltvdun" opt; do
    case $opt in
      k|l)
        install_argox
        exit
        ;;
      v)
        upgrade_argox
        exit
        ;;
      t)
        change_argo
        exit
        ;;
      d)
        change_cdn
        exit
        ;;
      u)
        uninstall_argox
        exit
        ;;
      n)
        show_node_info
        exit
        ;;
    esac
  done
}

# =====================================================
# 主入口
# =====================================================

main(){

  statistics_run update

  parse_args "$@"

  while true; do
    menu
  done
}

main "$@"
