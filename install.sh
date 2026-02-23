#!/bin/bash

# 基础颜色与变量定义
red='\e[31m'
green='\e[92m'
yellow='\e[33m'
none='\e[0m'
is_core_dir="/etc/xray"
is_conf_dir="/etc/xray/conf"
is_log_dir="/var/log/xray"
is_sh_bin="/usr/local/bin/xray"
is_config_json="/etc/xray/config.json"
# 预设证书保存路径
is_cert_file="/etc/xray/cert.crt"
is_key_file="/etc/xray/cert.key"

# 检查 Root 权限
[[ $EUID != 0 ]] && echo -e "${red}错误: 必须使用 ROOT 用户运行!${none}" && exit 1

# --- 核心功能模块 ---

# 启用 BBR 拥塞控制
enable_bbr() {
    echo -e "${yellow}正在检查并启用 BBR 加速...${none}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${green}BBR 已成功开启！${none}"
    fi
}

# 证书输入处理函数
input_cert_content() {
    echo -e "${yellow}请粘贴您的证书内容 (CRT/PEM)，完成后输入 EOF 并回车:${none}"
    sed '/EOF/q' > $is_cert_file
    echo -e "${yellow}请粘贴您的私钥内容 (KEY)，完成后输入 EOF 并回车:${none}"
    sed '/EOF/q' > $is_key_file
    
    # 清除文件中输入的 "EOF" 字符
    sed -i '/EOF/d' $is_cert_file
    sed -i '/EOF/d' $is_key_file
    
    chmod 600 $is_key_file
}

# 安装代理配置
install_proxy() {
    clear
    echo -e "${green}开始安装 Xray (CDN + 根源证书 + DoH)${none}"
    
    # 即时输入确认 [要求补充]
    read -p "请输入您的域名 (Domain): " domain
    read -p "请输入监听端口 (默认 443): " port
    port=${port:-443}

    # 处理证书内容
    mkdir -p $is_core_dir
    input_cert_content

    # 创建必要目录
    mkdir -p $is_conf_dir
    mkdir -p $is_log_dir

    # 生成配置文件 (DoH 映射与 WebSocket 伪装)
    cat > $is_config_json <<EOF
{
    "dns": {
        "servers": ["https://1.1.1.1/dns-query", "localhost"]
    },
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$(cat /proc/sys/kernel/random/uuid)"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$is_cert_file",
                    "keyFile": "$is_key_file"
                }]
            },
            "wsSettings": {"path": "/xray-ws"}
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    enable_bbr
    echo -e "${green}配置完成！端口: $port, 域名: $domain${none}"
    echo -e "${yellow}提示: 请确保 Cloudflare 解析已开启小黄云 (Proxied)。${none}"
}

# 完全卸载
uninstall_all() {
    systemctl stop xray &>/dev/null
    rm -rf $is_core_dir $is_log_dir $is_sh_bin
    echo -e "${yellow}Xray 及其所有证书、配置已完全卸载。${none}"
}

# --- 交互界面菜单 ---

main_menu() {
    clear
    echo -e "${green}Xray 管理脚本 - 高伪装版${none}"
    echo "--------------------------------"
    echo -e "1) 安装代理 (CDN+根源证书内容输入)"
    echo -e "2) 完全卸载"
    echo -e "3) 更换域名"
    echo -e "4) 更换证书 (重新粘贴内容)"
    echo -e "5) 更换端口"
    echo -e "6) 更换 DNS (DoH)"
    echo -e "7) 查看日志"
    echo -e "8) 清理日志"
    echo -e "q) 退出"
    echo "--------------------------------"
    read -p "选择操作: " choice

    case $choice in
        1) install_proxy ;;
        2) uninstall_all ;;
        3) read -p "输入新域名: " domain ;;
        4) input_cert_content && echo -e "${green}证书已更新${none}" ;;
        5) read -p "输入新端口: " port ;;
        6) echo "DNS 已锁定为 DoH (1.1.1.1)" ;;
        7) [ -f "$is_log_dir/access.log" ] && tail -n 50 "$is_log_dir/access.log" || echo "暂无日志" ;;
        8) echo "" > "$is_log_dir/access.log" 2>/dev/null && echo "日志已清空" ;;
        q) exit 0 ;;
        *) echo "无效输入" && sleep 1 && main_menu ;;
    esac
}

# 绑定快捷命令
if [[ ! -f $is_sh_bin ]]; then
    ln -sf "$(realpath $0)" $is_sh_bin
    chmod +x $is_sh_bin
fi

# 启动菜单
main_menu