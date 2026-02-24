#!/usr/bin/env bash
set -e

WORK_DIR="/etc/argox"
mkdir -p $WORK_DIR
cd $WORK_DIR

echo "===== ArgoX LXC DualStack Edition ====="

if [ "$(id -u)" != 0 ]; then
  echo "Run as root"
  exit 1
fi

apt update -y
apt install -y curl wget unzip nginx uuid-runtime

# ===============================
# 选择 IPv4 或 IPv6（参考 suoha）
# ===============================

read -p "请选择 Argo 连接模式 IPv4 或 IPv6 (输入 4 或 6，默认 4): " IPS
IPS=${IPS:-4}

if [[ "$IPS" != "4" && "$IPS" != "6" ]]; then
  echo "请输入正确的模式 (4 或 6)"
  exit 1
fi

echo "使用 IPv$IPS 连接 Cloudflare"

# ===============================
# 基本参数
# ===============================

read -p "Enter Argo Domain: " ARGO_DOMAIN
read -p "Enter Argo Token or Json: " ARGO_AUTH
read -p "Enter Node Name: " NODE_NAME

UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH=$(echo $UUID | cut -d- -f1)
PORT=$((RANDOM%20000+10000))

# ===============================
# 下载组件（串行）
# ===============================

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

# ===============================
# 生成 Xray 配置
# ===============================

cat > config.json <<EOF
{
  "inbounds": [{
    "port": $PORT,
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
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

# ===============================
# 独立 nginx（不使用 systemctl）
# ===============================

cat > nginx.conf <<EOF
worker_processes 1;
events { worker_connections 1024; }

http {
  server {
    listen 80;
    server_name $ARGO_DOMAIN;

    location /$WS_PATH {
      proxy_pass http://127.0.0.1:$PORT;
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

# ===============================
# 启动 Xray
# ===============================

echo "Starting Xray..."
nohup $WORK_DIR/xray run -config $WORK_DIR/config.json > xray.log 2>&1 &
echo $! > xray.pid
sleep 3

# ===============================
# 启动 Argo（关键：--edge-ip-version）
# ===============================

echo "Starting Cloudflare Tunnel..."
nohup $WORK_DIR/cloudflared \
  --edge-ip-version $IPS \
  --protocol http2 \
  tunnel --no-autoupdate run --token "$ARGO_AUTH" \
  > argo.log 2>&1 &

echo $! > argo.pid
sleep 3

# ===============================
# 守护机制（参考 suoha）
# ===============================

cat > monitor.sh <<EOF
#!/usr/bin/env bash
WORK_DIR="$WORK_DIR"
IPS="$IPS"
TOKEN="$ARGO_AUTH"

while true
do
  if ! ps -p \$(cat \$WORK_DIR/xray.pid 2>/dev/null) > /dev/null 2>&1; then
    nohup \$WORK_DIR/xray run -config \$WORK_DIR/config.json > xray.log 2>&1 &
    echo \$! > \$WORK_DIR/xray.pid
  fi

  if ! ps -p \$(cat \$WORK_DIR/argo.pid 2>/dev/null) > /dev/null 2>&1; then
    nohup \$WORK_DIR/cloudflared \
      --edge-ip-version \$IPS \
      --protocol http2 \
      tunnel --no-autoupdate run --token "\$TOKEN" \
      > argo.log 2>&1 &
    echo \$! > \$WORK_DIR/argo.pid
  fi

  sleep 20
done
EOF

chmod +x monitor.sh
nohup ./monitor.sh > monitor.log 2>&1 &
echo $! > monitor.pid

# ===============================
# 管理脚本（类似 suoha 菜单）
# ===============================

cat > /usr/bin/argox <<EOF
#!/usr/bin/env bash
WORK_DIR="$WORK_DIR"

while true
do
echo "1. 状态"
echo "2. 重启"
echo "3. 停止"
echo "4. 启动"
echo "5. 卸载"
echo "0. 退出"
read -p "请选择: " menu

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
  nohup \$WORK_DIR/cloudflared tunnel run --token "$ARGO_AUTH" > argo.log 2>&1 &
  ;;
3)
  pkill xray
  pkill cloudflared
  ;;
4)
  nohup \$WORK_DIR/xray run -config \$WORK_DIR/config.json > xray.log 2>&1 &
  nohup \$WORK_DIR/cloudflared tunnel run --token "$ARGO_AUTH" > argo.log 2>&1 &
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
echo "IPv$IPS 模式"
echo "UUID: $UUID"
echo "WS Path: /$WS_PATH"
echo ""
echo "VLESS:"
echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&type=ws&host=$ARGO_DOMAIN&path=/$WS_PATH#$NODE_NAME"
echo ""
