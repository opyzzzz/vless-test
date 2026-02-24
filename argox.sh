#!/usr/bin/env bash
set -e

WORK_DIR="/etc/argox"
mkdir -p $WORK_DIR
cd $WORK_DIR

echo "===== ArgoX LXC PRO MODE ====="

if [ "$(id -u)" != 0 ]; then
  echo "Run as root"
  exit 1
fi

apt update -y
apt install -y curl wget unzip nginx uuid-runtime

# ===== 基础参数 =====
read -p "Enter VPS IP: " SERVER_IP
read -p "Enter Argo Domain: " ARGO_DOMAIN
read -p "Enter Argo Token or Json: " ARGO_AUTH
read -p "Enter Node Name: " NODE_NAME

REALITY_PORT=$(shuf -i 10000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH=$(echo $UUID | cut -d- -f1)

# ===== 下载组件（串行）=====
echo "Downloading Xray..."
wget -q -O Xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -oq Xray.zip
chmod +x xray
rm -f Xray.zip
sleep 2

echo "Downloading cloudflared..."
wget -q -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
sleep 2

# ===== 生成 Xray 配置 =====
cat > config.json <<EOF
{
  "inbounds": [{
    "port": $REALITY_PORT,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "decryption": "none",
      "clients": [{ "id": "$UUID" }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "/$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ===== nginx 独立配置（不依赖 systemctl）=====
cat > nginx.conf <<EOF
worker_processes  1;

events { worker_connections  1024; }

http {
  server {
    listen 80;
    server_name $ARGO_DOMAIN;

    location /$WS_PATH {
      proxy_pass http://127.0.0.1:$REALITY_PORT;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
    }
  }
}
EOF

mkdir -p /run
pkill nginx 2>/dev/null || true
sleep 1
/usr/sbin/nginx -c $WORK_DIR/nginx.conf
sleep 2

# ===== 启动 Xray =====
nohup $WORK_DIR/xray run -config $WORK_DIR/config.json > xray.log 2>&1 &
echo $! > xray.pid
sleep 3

# ===== 启动 Argo =====
nohup $WORK_DIR/cloudflared tunnel --no-autoupdate run --token "$ARGO_AUTH" > argo.log 2>&1 &
echo $! > argo.pid
sleep 3

# ===== 守护机制（参考 suoha Alpine 模式）=====
cat > monitor.sh <<EOF
#!/usr/bin/env bash
WORK_DIR="$WORK_DIR"
while true
do
  if ! ps -p \$(cat \$WORK_DIR/xray.pid 2>/dev/null) > /dev/null 2>&1; then
    nohup \$WORK_DIR/xray run -config \$WORK_DIR/config.json > xray.log 2>&1 &
    echo \$! > \$WORK_DIR/xray.pid
  fi

  if ! ps -p \$(cat \$WORK_DIR/argo.pid 2>/dev/null) > /dev/null 2>&1; then
    nohup \$WORK_DIR/cloudflared tunnel --no-autoupdate run --token "$ARGO_AUTH" > argo.log 2>&1 &
    echo \$! > \$WORK_DIR/argo.pid
  fi

  sleep 20
done
EOF

chmod +x monitor.sh
nohup ./monitor.sh > monitor.log 2>&1 &
echo $! > monitor.pid

# ===== 管理脚本 =====
cat > /usr/bin/argox <<EOF
#!/usr/bin/env bash
WORK_DIR="$WORK_DIR"

while true
do
echo "1. Status"
echo "2. Restart"
echo "3. Stop"
echo "4. Start"
echo "5. Uninstall"
echo "0. Exit"
read -p "Select: " menu

case \$menu in
1)
  ps aux | grep xray | grep -v grep
  ps aux | grep cloudflared | grep -v grep
  ;;
2)
  pkill xray
  pkill cloudflared
  sleep 2
  nohup \$WORK_DIR/xray run -config \$WORK_DIR/config.json > xray.log 2>&1 &
  echo \$! > \$WORK_DIR/xray.pid
  nohup \$WORK_DIR/cloudflared tunnel --no-autoupdate run --token "$ARGO_AUTH" > argo.log 2>&1 &
  echo \$! > \$WORK_DIR/argo.pid
  ;;
3)
  pkill xray
  pkill cloudflared
  ;;
4)
  nohup \$WORK_DIR/xray run -config \$WORK_DIR/config.json > xray.log 2>&1 &
  echo \$! > \$WORK_DIR/xray.pid
  nohup \$WORK_DIR/cloudflared tunnel --no-autoupdate run --token "$ARGO_AUTH" > argo.log 2>&1 &
  echo \$! > \$WORK_DIR/argo.pid
  ;;
5)
  pkill xray
  pkill cloudflared
  pkill nginx
  rm -rf \$WORK_DIR /usr/bin/argox
  echo "Uninstalled"
  exit
  ;;
0)
  exit
  ;;
esac
done
EOF

chmod +x /usr/bin/argox

echo ""
echo "===== INSTALL COMPLETE ====="
echo "Node Name: $NODE_NAME"
echo "UUID: $UUID"
echo "WS Path: /$WS_PATH"
echo "Domain: $ARGO_DOMAIN"
echo ""
echo "VLESS:"
echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=/$WS_PATH#$NODE_NAME"
echo ""
