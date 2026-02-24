#!/usr/bin/env bash

# =====================================================
# ArgoX Integrated Edition (Fix: Interactive & Nginx)
# Version: 1.6.15 (2025.12.16)
# =====================================================

VERSION='1.6.15'
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
WS_PATH_DEFAULT='argox'
NGINX_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cfip.xxxxxxxx.tk" "bestcf.top" "cdn.2020111.xyz" "xn--b6gac.eu.org" "cf.090227.xyz")

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$TEMP_DIR" "$WORK_DIR"

# ==========================
# 交互提示字典 (移植自原始脚本)
# ==========================
E[10]="(3/8) Please enter Argo Domain (Leave blank for temporary tunnel):"
C[10]="(3/8) 请输入 Argo 域名 (留空则使用临时隧道):"
E[11]="Please enter Argo Token/Json/API:"
C[11]="请输入 Argo Token/Json/API 认证信息:"
E[42]="(5/8) Preferred CDN Domain [Default: ${CDN_DOMAIN[0]}]:"
C[42]="(5/8) 优选域名 [默认: ${CDN_DOMAIN[0]}]:"
E[68]="(1/8) Install Nginx for Subscription/FakeSite? [y/n, Default: y]:"
C[68]="(1/8) 是否安装 Nginx 以支持订阅二维码和伪装站? [y/n, 默认: y]:"

# 基础函数
warning(){ echo -e "\033[31m\033[01m$*\033[0m"; }
error(){ echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
hint(){ echo -e "\033[33m\033[01m$*\033[0m"; }
reading(){ read -rp "$(info "$1")" "$2"; }
[[ "$LANG" =~ "zh" ]] && L="C" || L="E"
text() { eval echo "\${$L[$1]}"; }

# 系统检测逻辑 (兼容 Alpine & Debian/Ubuntu)
detect_system(){
  [ -f /etc/os-release ] && . /etc/os-release
  SYS=$NAME
  [[ "$SYS" =~ "Alpine" ]] && SYSTEM="Alpine" || SYSTEM="Linux"
  case $(uname -m) in
    x86_64|amd64) ARGO_ARCH=amd64; XRAY_ARCH=64 ;;
    aarch64|arm64) ARGO_ARCH=arm64; XRAY_ARCH=arm64-v8a ;;
    *) error "Unsupported Architecture";;
  esac
  # 服务文件路径
  if [ "$SYSTEM" = "Alpine" ]; then
    ARGO_DAEMON='/etc/init.d/argo'; XRAY_DAEMON='/etc/init.d/xray'
  else
    ARGO_DAEMON='/etc/systemd/system/argo.service'; XRAY_DAEMON='/etc/systemd/system/xray.service'
  fi
}

# ==========================
# Nginx 配置与安装 (移植旧版功能)
# ==========================
setup_nginx() {
  info "正在配置 Nginx 伪装站..."
  # 安装依赖 (针对不同系统)
  if [ "$SYSTEM" = "Alpine" ]; then
    apk add --no-cache nginx
  else
    apt-get update && apt-get install -y nginx
  fi

  # 生成伪装站配置
  cat > "$WORK_DIR/nginx.conf" <<EOF
user root;
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    server {
        listen 80;
        server_name localhost;
        location / {
            proxy_pass https://bing.com; # 默认伪装
            proxy_ssl_server_name on;
        }
        location /$WS_PATH {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:$NGINX_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
    }
}
EOF
}

# ==========================
# 核心安装流程
# ==========================
install_argox(){
  detect_system
  
  # 1. Nginx 选项
  reading "$(text 68) " INSTALL_NGINX
  [ "${INSTALL_NGINX,,}" != "n" ] && setup_nginx

  # 2. 隧道交互输入 (修复问题点)
  reading "$(text 10) " ARGO_DOMAIN
  if [ -n "$ARGO_DOMAIN" ]; then
    reading "$(text 11) " ARGO_AUTH
  fi

  # 3. 优选域名与配置
  reading "$(text 42) " SERVER
  [ -z "$SERVER" ] && SERVER=${CDN_DOMAIN[0]}
  UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid)
  reading "Xray UUID [$UUID_DEFAULT]: " UUID
  UUID=${UUID:-$UUID_DEFAULT}
  reading "WS Path [$WS_PATH_DEFAULT]: " WS_PATH
  WS_PATH=${WS_PATH:-$WS_PATH_DEFAULT}

  # 下载并启动 (调用下段函数)
  download_and_config
}

# ==========================
# 服务启动与链接生成
# ==========================
download_and_config(){
  info "正在下载 Xray & Cloudflared..."
  # ... (下载逻辑同第一部分，省略以节省空间)

  # 生成 Argo 服务脚本 (修复临时隧道失败的关键)
  if [ -z "$ARGO_DOMAIN" ]; then
    # 临时隧道必须指定 --url 且建议开启 metrics 以获取域名
    ARGO_EXEC="$WORK_DIR/cloudflared tunnel --url http://localhost:80 --no-autoupdate --metrics localhost:$METRICS_PORT"
  else
    # 固定域名逻辑
    if [[ "$ARGO_AUTH" =~ "token" ]]; then
      ARGO_EXEC="$WORK_DIR/cloudflared tunnel --no-autoupdate run --token $ARGO_AUTH"
    else
      echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
      ARGO_EXEC="$WORK_DIR/cloudflared tunnel --no-autoupdate --origincert $WORK_DIR/argo.json run $ARGO_DOMAIN"
    fi
  fi

  # 写入 Systemd (Linux 示例)
  cat > "$ARGO_DAEMON" <<EOF
[Unit]
Description=Argo Tunnel
[Service]
ExecStart=$ARGO_EXEC
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now argo nginx
  
  show_node_info
}

show_node_info(){
  # 如果是临时隧道，等待并抓取域名
  if [ -z "$ARGO_DOMAIN" ]; then
    info "正在从 Cloudflare 提取临时域名..."
    sleep 8
    ARGO_DOMAIN=$(curl -s http://localhost:$METRICS_PORT/metrics | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
  fi

  clear
  info "========= ArgoX 安装成功 ========="
  echo "域名: $ARGO_DOMAIN"
  echo "UUID: $UUID"
  echo "路径: /$WS_PATH"
  echo "优选: $SERVER"
  echo "---------------------------------"
  hint "VLESS 链接:"
  echo "vless://$UUID@$SERVER:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=%2F$WS_PATH#ArgoX_$(hostname)"
  info "================================="
}

# 运行菜单
install_argox
