#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

echo "===== CF CDN VLESS 低内存部署 ====="

read -p "输入域名: " domain
read -p "选择端口 (443/8443 默认443): " port
read -p "选择模式 (1普通 2高并发 默认1): " mode

[ -z "$port" ] && port=443
[ -z "$mode" ] && mode=1

uuid=$(cat /proc/sys/kernel/random/uuid)
wspath=$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)

apt update -y
apt install -y nginx-light curl unzip

# 启用BBR
echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
sysctl --system

# 低内存优化
cat > /etc/sysctl.d/99-lowmem.conf <<EOF
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 10
EOF

sysctl --system

# 安装 Xray
curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o xray.zip
install -m 755 xray /usr/local/bin/xray

mkdir -p /etc/xray
mkdir -p /etc/ssl/cf

echo "粘贴 Cloudflare 15年 Origin 证书 (Ctrl+D 结束):"
cat > /etc/ssl/cf/origin.crt

echo "粘贴 私钥 (Ctrl+D 结束):"
cat > /etc/ssl/cf/origin.key

chmod 600 /etc/ssl/cf/*

# Xray配置（含DoH）
cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "none" },
  "dns": {
    "servers": [
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "skipFallback": true
      }
    ]
  },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$uuid" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/$wspath" }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" }
    }
  ]
}
EOF

cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
LimitNOFILE=512

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl start xray

# Nginx优化
if [ "$mode" = "1" ]; then
  worker_conn=512
else
  worker_conn=2048
fi

cat > /etc/nginx/nginx.conf <<EOF
worker_processes 1;
events { worker_connections $worker_conn; }
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 15;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    error_log off;
    include /etc/nginx/conf.d/*.conf;
}
EOF

cat > /etc/nginx/conf.d/$domain.conf <<EOF
server {
    listen $port ssl http2;
    server_name $domain;

    ssl_certificate /etc/ssl/cf/origin.crt;
    ssl_certificate_key /etc/ssl/cf/origin.key;
    ssl_protocols TLSv1.3 TLSv1.2;

    location /$wspath {
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF

nginx -t
systemctl restart nginx

echo ""
echo "===== 部署完成 ====="
echo "UUID: $uuid"
echo "路径: /$wspath"
echo ""
echo "VLESS链接："
echo "vless://$uuid@$domain:$port?encryption=none&security=tls&type=ws&host=$domain&path=/$wspath#CF-CDN"