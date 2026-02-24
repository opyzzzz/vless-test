#!/bin/bash

# =================================
#  Argox-Suoha Fusion Edition
#  Path: /opt/suoha
# =================================

WORK_DIR="/opt/suoha"
mkdir -p $WORK_DIR
cd $WORK_DIR

ARCH=$(uname -m)
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH=$(echo $UUID | cut -d- -f1)
XRAY_PORT=$((RANDOM%20000+10000))
PREFERRED_DOMAIN="skk.moe"

install_base(){
apt update -y
apt install -y curl wget unzip nginx
}

install_xray(){
case $ARCH in
x86_64|amd64)
wget -O xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
;;
aarch64|arm64)
wget -O xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip
;;
*)
echo "架构不支持"
exit 1
;;
esac

unzip -o xray.zip
mv xray $WORK_DIR/
rm -f xray.zip
chmod +x xray
}

install_cloudflared(){
case $ARCH in
x86_64|amd64)
wget -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
;;
aarch64|arm64)
wget -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64
;;
*)
echo "架构不支持"
exit 1
;;
esac
chmod +x cloudflared
}

config_xray(){
cat > $WORK_DIR/config.json <<EOF
{
  "inbounds":[
    {
      "port":$XRAY_PORT,
      "listen":"127.0.0.1",
      "protocol":"vless",
      "settings":{
        "clients":[{"id":"$UUID"}],
        "decryption":"none"
      },
      "streamSettings":{
        "network":"ws",
        "wsSettings":{"path":"/$WS_PATH"}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF
}

config_nginx(){
cat > /etc/nginx/conf.d/suoha.conf <<EOF
server {
    listen 80;
    server_name _;
    location /$WS_PATH {
        proxy_pass http://127.0.0.1:$XRAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF

systemctl restart nginx
}

create_systemd(){
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target

[Service]
ExecStart=$WORK_DIR/xray run -config $WORK_DIR/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=$WORK_DIR/cloudflared tunnel --config $WORK_DIR/config.yaml run
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray cloudflared
}

quick_tunnel(){
$WORK_DIR/cloudflared tunnel --url http://localhost:80 --no-autoupdate > argo.log 2>&1 &
sleep 5
ARGO_DOMAIN=$(grep trycloudflare.com argo.log | head -n1 | awk '{print $NF}')
generate_node $ARGO_DOMAIN
}

token_tunnel(){
read -p "请输入完整域名: " DOMAIN
read -p "请输入Token: " TOKEN

echo $TOKEN > $WORK_DIR/token.txt

$WORK_DIR/cloudflared tunnel login
$WORK_DIR/cloudflared tunnel create suoha
$WORK_DIR/cloudflared tunnel route dns suoha $DOMAIN

cat > $WORK_DIR/config.yaml <<EOF
tunnel: suoha
credentials-file: /root/.cloudflared/*.json
ingress:
  - hostname: $DOMAIN
    service: http://localhost:80
  - service: http_status:404
EOF

generate_node $DOMAIN
}

generate_node(){
DOMAIN=$1
cat > $WORK_DIR/v2ray.txt <<EOF
vless://$UUID@$PREFERRED_DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=/$WS_PATH#suoha_tls

vless://$UUID@$PREFERRED_DOMAIN:80?encryption=none&security=none&type=ws&host=$DOMAIN&path=/$WS_PATH#suoha
EOF

cat $WORK_DIR/v2ray.txt
}

menu(){
clear
echo "===== Suoha 管理 ====="
echo "1. Quick Tunnel"
echo "2. Token Tunnel"
echo "3. 修改优选域名"
echo "4. 查看节点"
echo "5. 重启服务"
echo "0. 退出"
read -p "选择: " num

case $num in
1) quick_tunnel ;;
2) token_tunnel ;;
3)
read -p "输入新的优选域名/IP: " PREFERRED_DOMAIN
echo "修改成功"
;;
4) cat $WORK_DIR/v2ray.txt ;;
5)
systemctl restart xray
systemctl restart cloudflared
;;
0) exit ;;
esac
}

main_install(){
install_base
install_xray
install_cloudflared
config_xray
config_nginx
create_systemd
systemctl start xray
}

if [ ! -f "$WORK_DIR/xray" ]; then
main_install
fi

menu
