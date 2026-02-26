#!/bin/bash
set -e
set -o pipefail

VERSION="3.3-Debian稳定版"

BASE_DIR="/opt/suoha"
BIN_DIR="$BASE_DIR/bin"
CONF_DIR="$BASE_DIR/config"
TUNNEL_DIR="$CONF_DIR/tunnels"
SYSTEMD_DIR="/etc/systemd/system"
DOMAIN="cloudflare.182682.xyz"

########################################
检测系统() {
    if ! grep -qi debian /etc/os-release; then
        echo "本版本仅支持 Debian"
        exit 1
    fi
}

########################################
安装基础() {

mkdir -p $BIN_DIR $CONF_DIR $TUNNEL_DIR

apt update -y

apt install -y curl unzip >/dev/null 2>&1

if ! command -v uuidgen >/dev/null 2>&1; then
    apt install -y uuid-runtime >/dev/null 2>&1
fi

if [ ! -f "$BIN_DIR/xray" ]; then
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        FILE="Xray-linux-64.zip"
    else
        FILE="Xray-linux-arm64-v8a.zip"
    fi

    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/$FILE
    unzip -o /tmp/xray.zip -d /tmp/xray
    mv /tmp/xray/xray $BIN_DIR/
    chmod +x $BIN_DIR/xray
fi

if [ ! -f "$BIN_DIR/cloudflared" ]; then
    curl -L -o $BIN_DIR/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x $BIN_DIR/cloudflared
fi
}

########################################
初始化UUID() {
if [ ! -f "$CONF_DIR/uuid" ]; then
    uuidgen > $CONF_DIR/uuid
fi
UUID=$(cat $CONF_DIR/uuid)
}

########################################
创建Xray服务() {
cat > $SYSTEMD_DIR/suoha-xray.service <<EOF
[Unit]
Description=Suoha Xray
After=network.target
[Service]
ExecStart=$BIN_DIR/xray run -config $CONF_DIR/xray.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable suoha-xray
}

########################################
重写Xray配置() {

UUID=$(cat $CONF_DIR/uuid)

cat > $CONF_DIR/xray.json <<EOF
{
  "inbounds": [
EOF

FIRST=1
for portfile in $TUNNEL_DIR/*.port; do
    [ -f "$portfile" ] || continue
    PORT=$(cat $portfile)

    if [ $FIRST -eq 0 ]; then
        echo "," >> $CONF_DIR/xray.json
    fi
    FIRST=0

cat >> $CONF_DIR/xray.json <<EOT
{
  "port": $PORT,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "$UUID" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": { "serviceName": "grpc" }
  }
}
EOT
done

cat >> $CONF_DIR/xray.json <<EOF
],
"outbounds": [{ "protocol": "freedom" }]
}
EOF

if [ ! -f "$SYSTEMD_DIR/suoha-xray.service" ]; then
    创建Xray服务
fi

systemctl restart suoha-xray
}

########################################
获取新编号() {
MAX=0
for file in $TUNNEL_DIR/*.port; do
    [ -f "$file" ] || continue
    ID=$(basename $file | sed 's/tunnel-//' | sed 's/.port//')
    [ "$ID" -gt "$MAX" ] && MAX=$ID
done
echo $((MAX+1))
}

########################################
提取Token() {
read -p "粘贴 Tunnel 命令或 Token: " INPUT
if [[ "$INPUT" == *"--token"* ]]; then
    TOKEN=$(echo "$INPUT" | sed -E 's/.*--token[= ]+([^ ]+).*/\1/')
else
    TOKEN="$INPUT"
fi
TOKEN=$(echo "$TOKEN" | tr -d '"' | tr -d "'")
}

########################################
创建隧道() {

检测系统
安装基础
初始化UUID

ID=$(获取新编号)
PORT=$((21000 + ID))

echo "新隧道编号: $ID"

echo "$PORT" > $TUNNEL_DIR/tunnel-$ID.port

提取Token
echo "$TOKEN" > $TUNNEL_DIR/tunnel-$ID.token
chmod 600 $TUNNEL_DIR/tunnel-$ID.token

echo "选择协议:"
echo "1. HTTP/2"
echo "2. QUIC"
read -p "选择: " MODE

if [ "$MODE" = "1" ]; then
    PROTO="http2"
else
    PROTO="quic"
fi

cat > $SYSTEMD_DIR/suoha-tunnel-$ID.service <<EOF
[Unit]
Description=Suoha Tunnel $ID
After=network.target
[Service]
ExecStart=$BIN_DIR/cloudflared tunnel --protocol $PROTO run --token $TOKEN --url http://127.0.0.1:$PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable suoha-tunnel-$ID
systemctl start suoha-tunnel-$ID

重写Xray配置

echo "隧道 $ID 创建完成"
}

########################################
查看链接() {
UUID=$(cat $CONF_DIR/uuid)
echo ""
echo "===== 当前节点 ====="
for portfile in $TUNNEL_DIR/*.port; do
    [ -f "$portfile" ] || continue
    ID=$(basename $portfile | sed 's/tunnel-//' | sed 's/.port//')
    echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=grpc&serviceName=grpc#$DOMAIN-$ID"
done
}

########################################
完全卸载() {

echo "确认完全卸载? (y/n)"
read CONFIRM
[ "$CONFIRM" != "y" ] && return

systemctl stop suoha-xray 2>/dev/null || true
systemctl disable suoha-xray 2>/dev/null || true
rm -f $SYSTEMD_DIR/suoha-xray.service

for svc in $SYSTEMD_DIR/suoha-tunnel-*.service; do
    [ -f "$svc" ] || continue
    systemctl stop $(basename $svc .service) 2>/dev/null || true
    systemctl disable $(basename $svc .service) 2>/dev/null || true
    rm -f "$svc"
done

rm -rf $BASE_DIR
systemctl daemon-reload
echo "已完全卸载"
}

########################################
菜单() {
while true; do
echo ""
echo "========= SUOHA $VERSION ========="
echo "1. 创建隧道"
echo "2. 查看所有链接"
echo "3. 完全卸载"
echo "0. 退出"
read -p "选择: " NUM

case $NUM in
1) 创建隧道 ;;
2) 查看链接 ;;
3) 完全卸载 ;;
0) exit ;;
esac
done
}

菜单
