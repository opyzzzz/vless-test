#!/bin/bash

clear
echo "ArgoX + Suoha + Nginx 增强版"
echo

if [ "$(id -u)" != 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

mkdir -p /opt/suoha
cd /opt/suoha || exit

# 架构检测
case $(uname -m) in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  *) echo "架构不支持"; exit ;;
esac

apt update -y
apt install -y wget unzip curl nginx

# 下载 Xray
wget -q https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip -O xray.zip
unzip -qo xray.zip
mv xray /opt/suoha/
chmod +x /opt/suoha/xray
rm -rf xray.zip geo*

# 下载 Cloudflared
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH -O cloudflared
chmod +x cloudflared
mv cloudflared /opt/suoha/

# 协议选择
read -p "1.vmess 2.vless (默认2): " protocol
[ -z "$protocol" ] && protocol=2

UUID=$(cat /proc/sys/kernel/random/uuid)
PORT=10000
WSPATH=$(echo $UUID | cut -d '-' -f1)

# 生成 Xray 配置
if [ "$protocol" == "1" ]; then
PROTO="vmess"
else
PROTO="vless"
fi

cat >/opt/suoha/config.json<<EOF
{
  "inbounds":[
    {
      "port":$PORT,
      "listen":"127.0.0.1",
      "protocol":"$PROTO",
      "settings":{
        "decryption":"none",
        "clients":[{"id":"$UUID"}]
      },
      "streamSettings":{
        "network":"ws",
        "wsSettings":{"path":"/$WSPATH"}
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

# Nginx 反代
mkdir -p /var/www/html
echo "<h1>Welcome</h1>" >/var/www/html/index.html

cat >/etc/nginx/sites-available/suoha<<EOF
server {
    listen 80;
    server_name _;

    location /$WSPATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$PORT;
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

ln -sf /etc/nginx/sites-available/suoha /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# 启动 Argo
nohup /opt/suoha/cloudflared tunnel --url http://localhost:80 >argo.log 2>&1 &
sleep 5
DOMAIN=$(grep trycloudflare argo.log | sed -n 's/.*https:\/\///p' | head -1)

# 优选域名设置
read -p "请输入优选域名(可留空): " BESTDOMAIN

if [ -n "$BESTDOMAIN" ]; then
  DOMAIN=$BESTDOMAIN
fi

# 生成节点
if [ "$PROTO" == "vmess" ]; then
LINK="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"argo\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/$WSPATH\",\"tls\":\"tls\"}" | base64 -w 0)"
else
LINK="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=/$WSPATH#argo"
fi

echo "$LINK" >/opt/suoha/v2ray.txt

# systemd
cat >/lib/systemd/system/xray.service<<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=/opt/suoha/xray run -config /opt/suoha/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 管理命令
cat >/usr/bin/suoha<<EOF
#!/bin/bash
echo "1. 启动"
echo "2. 停止"
echo "3. 重启"
echo "4. 查看节点"
echo "5. 修改优选域名"
read -p "选择: " m
case \$m in
1) systemctl start xray nginx ;;
2) systemctl stop xray nginx ;;
3) systemctl restart xray nginx ;;
4) cat /opt/suoha/v2ray.txt ;;
5)
 read -p "输入新优选域名: " NEWDOMAIN
 sed -i "s/@.*:443/@\$NEWDOMAIN:443/" /opt/suoha/v2ray.txt
 echo "修改完成"
 ;;
esac
EOF

chmod +x /usr/bin/suoha

echo
echo "安装完成"
cat /opt/suoha/v2ray.txt
echo
echo "管理命令: suoha"
