#!/usr/bin/env bash

# =====================================================
# ArgoX Pro (Suoha Optimized Edition)
# Version: 1.6.19 (Final Stable)
# =====================================================

WORK_DIR='/etc/argox'
BIN_PATH='/usr/local/bin/argox'
NGINX_PORT='80'
XRAY_PORT='8080'
METRICS_PORT='3333'
DEFAULT_XRAY_VERSION='26.2.6'
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cf.090227.xyz")

# 彩色输出与交互
info(){ echo -e "\033[32m\033[01m$*\033[0m"; }
warning(){ echo -e "\033[31m\033[01m$*\033[0m"; }
reading(){ read -rp "$(echo -e "\033[32m\033[01m$1\033[0m")" "$2"; }

# 1. 参考 suoha.sh 的强力清理逻辑
cleanup_all(){
    info "正在深度清理旧环境..."
    systemctl stop argo xray nginx 2>/dev/null
    systemctl disable argo xray nginx 2>/dev/null
    # 强杀残留进程
    kill -9 $(ps -ef | grep -E 'xray|cloudflared' | grep -v grep | awk '{print $2}') >/dev/null 2>&1
    rm -rf "$WORK_DIR"
    rm -f /etc/systemd/system/argo.service /etc/systemd/system/xray.service
    systemctl daemon-reload
    mkdir -p "$WORK_DIR"
}

# 2. 系统环境与依赖准备
check_env(){
    [ "$(id -u)" != 0 ] && { warning "请以 root 运行"; exit 1; }
    # 自动识别系统安装工具
    if [ -f /etc/debian_version ]; then
        apt update -y && apt install -y wget curl unzip nginx 2>/dev/null
    elif [ -f /etc/alpine-release ]; then
        apk add wget curl unzip nginx 2>/dev/null
    else
        yum install -y wget curl unzip nginx 2>/dev/null
    fi
}

# 3. 组件下载
download_files(){
    case $(uname -m) in
        x86_64|amd64) ARGO_A=amd64; XRAY_A=64 ;;
        aarch64|arm64) ARGO_A=arm64; XRAY_A=arm64-v8a ;;
    esac
    info "正在下载 Cloudflared & Xray ($ARGO_A)..."
    wget -qO "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARGO_A"
    wget -qO "$WORK_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/v$DEFAULT_XRAY_VERSION/Xray-linux-$XRAY_A.zip"
    unzip -oj "$WORK_DIR/xray.zip" "xray" -d "$WORK_DIR"
    chmod +x "$WORK_DIR/cloudflared" "$WORK_DIR/xray"
    rm -f "$WORK_DIR/xray.zip"
}

# 4. 安装主程序
install_argox(){
    cleanup_all
    check_env
    
    # 恢复缺失的提示语交互
    info "--- ArgoX 安装向导 ---"
    reading "请输入 Argo 域名 (留空则创建临时隧道): " ARGO_DOMAIN
    if [ -n "$ARGO_DOMAIN" ]; then
        reading "请输入 Argo Token 或 Json 内容: " ARGO_AUTH
    fi
    
    reading "请输入优选域名 [默认: ${CDN_DOMAIN[0]}]: " SERVER
    SERVER=${SERVER:-${CDN_DOMAIN[0]}}
    
    UUID_DEFAULT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
    reading "请输入 Xray UUID [默认: $UUID_DEFAULT]: " UUID
    UUID=${UUID:-$UUID_DEFAULT}
    
    reading "请输入 WS 路径 [默认: argox]: " WS_PATH
    WS_PATH=${WS_PATH:-"argox"}

    download_files

    # 参考 suoha.sh 的 Xray 配置逻辑
    cat > "$WORK_DIR/config.json" <<EOF
{
    "inbounds": [{
        "port": $XRAY_PORT, "listen": "127.0.0.1", "protocol": "vless",
        "settings": { "clients": [{ "id": "$UUID" }], "decryption": "none" },
        "streamSettings": { "network": "ws", "wsSettings": { "path": "/$WS_PATH" } }
    }],
    "outbounds": [{ "protocol": "freedom" }]
}
EOF

    # 参考 suoha.sh 优化 Nginx 伪装
    cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    server {
        listen $NGINX_PORT;
        location / { proxy_pass https://www.bing.com; proxy_ssl_server_name on; }
        location /$WS_PATH {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:$XRAY_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }
    }
}
EOF

    # 5. 核心：参考 suoha.sh 改善 Argo 启动逻辑
    # 增加 --protocol http2 提高 NAT 环境稳定性
    if [ -z "$ARGO_DOMAIN" ]; then
        # 临时隧道
        ARGO_CMD="tunnel --protocol http2 --url http://localhost:$NGINX_PORT --no-autoupdate --metrics localhost:$METRICS_PORT"
    elif [[ "$ARGO_AUTH" =~ "eyJh" ]]; then
        # 固定 Token 模式 (Suoha.sh 核心优势)
        ARGO_CMD="tunnel --protocol http2 --no-autoupdate run --token $ARGO_AUTH"
    else
        # Json 证书模式
        echo "$ARGO_AUTH" > "$WORK_DIR/argo.json"
        ARGO_CMD="tunnel --protocol http2 --no-autoupdate --cred-file $WORK_DIR/argo.json run $ARGO_DOMAIN"
    fi

    # 写入 Service
    cat > /etc/systemd/system/argo.service <<EOF
[Unit]
Description=Argo Tunnel
After=network.target
[Service]
ExecStart=$WORK_DIR/cloudflared $ARGO_CMD
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
[Service]
ExecStart=$WORK_DIR/xray -config $WORK_DIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 启动所有服务
    systemctl daemon-reload
    systemctl restart nginx xray
    systemctl enable --now argo
    
    # 创建全局命令快捷方式
    ln -sf "$(realpath "$0")" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    show_node_info "$ARGO_DOMAIN" "$UUID" "$WS_PATH" "$SERVER"
}

show_node_info(){
    local domain=$1; local uuid=$2; local path=$3; local server=$4
    if [ -z "$domain" ]; then
        info "正在提取临时域名 (约10秒)..."
        sleep 10
        domain=$(curl -s http://localhost:$METRICS_PORT/metrics | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | head -n 1)
    fi
    clear
    info "=========================================="
    info "         ArgoX 安装部署成功"
    info "=========================================="
    echo "域名: $domain"
    echo "UUID: $uuid"
    echo "路径: /$path"
    echo "优选: $server"
    echo "------------------------------------------"
    echo "vless://$uuid@$server:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=%2F$path#ArgoX_$(hostname)"
    info "=========================================="
}

install_argox
