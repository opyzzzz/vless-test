#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 路径定义
CONFIG_FILE="/etc/xray/config.json"
CERT_PATH="/etc/xray/certs/server.crt"
KEY_PATH="/etc/xray/certs/server.key"
LOG_FILE="/var/log/xray/access.log"
ERROR_LOG="/var/log/xray/error.log"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 权限运行此脚本！${NC}" && exit 1

# 快捷命令设置
install_shortcut() {
    if [[ ! -f "/usr/local/bin/proxy" ]]; then
        ln -sf "$(readlink -f "$0")" /usr/local/bin/proxy
        chmod +x /usr/local/bin/proxy
    fi
}

# 获取当前配置并生成链接
get_link() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}错误：未检测到配置文件，请先安装代理。${NC}"
        return
    fi
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
    PORT=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    SERVICE_NAME=$(jq -r '.inbounds[0].streamSettings.grpcSettings.serviceName' $CONFIG_FILE)
    DOMAIN=$(grep -oP '(?<=SNI: ).*' /etc/xray/domain_record.txt 2>/dev/null || echo "您的域名")

    LINK="vless://${UUID}@${DOMAIN}:${PORT}?security=tls&encryption=none&type=grpc&serviceName=${SERVICE_NAME}&sni=${DOMAIN}#CF_VLESS_gRPC"
    
    echo -e "${GREEN}=== 当前代理连接信息 ===${NC}"
    echo -e "${YELLOW}域名:${NC} $DOMAIN"
    echo -e "${YELLOW}UUID:${NC} $UUID"
    echo -e "${YELLOW}传输:${NC} gRPC (Service Name: $SERVICE_NAME)"
    echo -e "----------------------------------"
    echo -e "${GREEN}VLESS 节点链接:${NC}"
    echo -e "${RED}${LINK}${NC}"
    echo -e "----------------------------------"
}

# 1. 安装功能
install_proxy() {
    echo -e "${GREEN}正在安装基础依赖...${NC}"
    apt update && apt install -y curl socat wget jq openssl
    
    read -p "请输入你的域名 (例如 example.com): " DOMAIN
    echo -e "${YELLOW}请粘贴 Cloudflare 根源证书 (Origin Certificate)，按 Ctrl+D 保存:${NC}"
    CERT_CONTENT=$(cat)
    echo -e "${YELLOW}请粘贴 Cloudflare 私钥 (Private Key)，按 Ctrl+D 保存:${NC}"
    KEY_CONTENT=$(cat)
    
    mkdir -p /etc/xray/certs /var/log/xray
    echo "$CERT_CONTENT" > $CERT_PATH
    echo "$KEY_CONTENT" > $KEY_PATH
    echo "SNI: $DOMAIN" > /etc/xray/domain_record.txt
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    # 配置中 loglevel 设为 warning，只记录错误信息
    cat <<EOF > $CONFIG_FILE
{
    "log": {
        "access": "$LOG_FILE",
        "error": "$ERROR_LOG",
        "loglevel": "warning"
    },
    "dns": { "servers": ["https://1.1.1.1/dns-query"] },
    "inbounds": [{
        "port": 2083,
        "protocol": "vless",
        "settings": { "clients": [{"id": "$UUID", "level": 0}], "decryption": "none" },
        "streamSettings": {
            "network": "grpc",
            "security": "tls",
            "tlsSettings": {
                "certificates": [{ "certificateFile": "$CERT_PATH", "keyFile": "$KEY_PATH" }],
                "alpn": ["h2"]
            },
            "grpcSettings": { "serviceName": "grpc-proxy" }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    touch $LOG_FILE $ERROR_LOG
    chown -R nobody:nogroup /var/log/xray
    systemctl restart xray
    systemctl enable xray
    clear
    echo -e "${GREEN}安装完成！日志级别已设为 warning。${NC}"
    get_link
}

# 2. 日志管理
view_log() {
    echo -e "${YELLOW}正在实时查看错误日志 (按 Ctrl+C 退出):${NC}"
    tail -f $ERROR_LOG
}

clear_log() {
    > $LOG_FILE
    > $ERROR_LOG
    echo -e "${GREEN}代理日志已清空。${NC}"
}

# 3. 基础设置更改
change_domain() {
    read -p "请输入新的域名: " NEW_DOMAIN
    echo "SNI: $NEW_DOMAIN" > /etc/xray/domain_record.txt
    echo -e "${GREEN}域名记录已更新。${NC}"
}

change_certs() {
    echo -e "${YELLOW}请粘贴新的证书，按 Ctrl+D 结束:${NC}"
    NEW_CERT=$(cat)
    echo -e "${YELLOW}请粘贴新的私钥，按 Ctrl+D 结束:${NC}"
    NEW_KEY=$(cat)
    echo "$NEW_CERT" > $CERT_PATH
    echo "$NEW_KEY" > $KEY_PATH
    systemctl restart xray
    echo -e "${GREEN}证书已更新。${NC}"
}

change_dns() {
    read -p "请输入新的 DoH 地址: " NEW_DNS
    jq ".dns.servers[0] = \"$NEW_DNS\"" $CONFIG_FILE > /tmp/xray.json && mv /tmp/xray.json $CONFIG_FILE
    systemctl restart xray
    echo -e "${GREEN}DNS 已更新。${NC}"
}

# 4. 卸载
uninstall_proxy() {
    read -p "确定卸载吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        systemctl stop xray
        rm -rf /etc/xray /var/log/xray /usr/local/bin/xray /usr/local/bin/proxy
        echo -e "${RED}已彻底卸载。${NC}"
        exit 0
    fi
}

# 主菜单
show_menu() {
    install_shortcut
    echo -e "${GREEN}=== Debian 12 VLESS+CF 管理脚本 ===${NC}"
    echo -e "1. 一键安装代理 (VLESS+gRPC+2083)"
    echo -e "2. 查看代理连接 (分享链接)"
    echo -e "3. 更改域名 / 证书 / DNS"
    echo -e "----------------------------------"
    echo -e "4. ${YELLOW}实时查看错误日志${NC}"
    echo -e "5. ${YELLOW}清空代理日志${NC}"
    echo -e "----------------------------------"
    echo -e "6. ${RED}卸载代理${NC}"
    echo -e "0. 退出"
    echo -e "----------------------------------"
    read -p "请选择: " OPT
    case $OPT in
        1) install_proxy ;;
        2) get_link ;;
        3) 
           echo "1.更改域名 2.更改证书 3.更改DNS"
           read -p "选择: " SUB_OPT
           [[ $SUB_OPT == 1 ]] && change_domain
           [[ $SUB_OPT == 2 ]] && change_certs
           [[ $SUB_OPT == 3 ]] && change_dns
           ;;
        4) view_log ;;
        5) clear_log ;;
        6) uninstall_proxy ;;
        0) exit 0 ;;
        *) echo "无效输入"; sleep 1; show_menu ;;
    esac
}

while true; do show_menu; done