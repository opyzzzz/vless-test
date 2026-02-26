#!/bin/bash
set -e
set -o pipefail

VERSION="3.2-自动递增+协议选择+自动清理版"

BASE_DIR="/opt/suoha"
BIN_DIR="$BASE_DIR/bin"
CONF_DIR="$BASE_DIR/config"
TUNNEL_DIR="$CONF_DIR/tunnels"
SYSTEMD_DIR="/etc/systemd/system"
DOMAIN="cloudflare.182682.xyz"
ARCH=$(uname -m)

########################################
检测系统() {
    source /etc/os-release
    case "$ID" in
        debian|ubuntu) PM_INSTALL="apt install -y"; PM_UPDATE="apt update -y" ;;
        centos|rocky|almalinux) PM_INSTALL="dnf install -y"; PM_UPDATE="dnf makecache" ;;
        *) echo "不支持系统"; exit 1 ;;
    esac
}

########################################
检测架构() {
    case "$ARCH" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        *) echo "不支持架构"; exit 1 ;;
    esac
}

########################################
安装基础() {

mkdir -p $BIN_DIR $CONF_DIR $TUNNEL_DIR

$PM_UPDATE
$PM_INSTALL curl unzip uuidgen 2>/dev/null || true

if [ ! -f "$BIN_DIR/xray" ]; then
    ARCH_SUFFIX=$(检测架构)
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH_SUFFIX.zip
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
systemctl restart suoha-xray
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

create_service_if_needed
systemctl restart suoha-xray
}

########################################
create_service_if_needed() {
if [ ! -f "$SYSTEMD_DIR/suoha-xray.service" ]; then
    创建Xray服务
fi
}

########################################
获取新编号() {
MAX=0
for file in $TUNNEL_DIR/*.port; do
    [ -f "$file" ] || continue
    ID=$(basename $file | sed 's/tunnel-//' | sed 's/.port//')
    if [ "$ID" -gt "$MAX" ]; then
        MAX=$ID
    fi
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
删除隧道() {
read -p "删除隧道编号: " ID
systemctl stop suoha-tunnel-$ID 2>/dev/null || true
systemctl disable suoha-tunnel-$ID 2>/dev/null || true
rm -f $SYSTEMD_DIR/suoha-tunnel-$ID.service
rm -f $TUNNEL_DIR/tunnel-$ID.*
systemctl daemon-reload
重写Xray配置
echo "隧道 $ID 已删除"
}

########################################
查看链接() {
UUID=$(cat $CONF_DIR/uuid)
echo ""
echo "===== 当前所有节点 ====="
for portfile in $TUNNEL_DIR/*.port; do
    [ -f "$portfile" ] || continue
    ID=$(basename $portfile | sed 's/tunnel-//' | sed 's/.port//')
    echo "隧道 $ID:"
    echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=grpc&serviceName=grpc#$DOMAIN-$ID"
    echo ""
done
}

########################################
自动清理残留() {
for svc in $SYSTEMD_DIR/suoha-tunnel-*.service; do
    [ -f "$svc" ] || continue
    ID=$(basename $svc | sed 's/suoha-tunnel-//' | sed 's/.service//')
    if [ ! -f "$TUNNEL_DIR/tunnel-$ID.port" ]; then
        systemctl stop suoha-tunnel-$ID 2>/dev/null || true
        systemctl disable suoha-tunnel-$ID 2>/dev/null || true
        rm -f "$svc"
    fi
done
systemctl daemon-reload
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

自动清理残留

while true; do
echo ""
echo "========= SUOHA $VERSION ========="
echo "1. 创建隧道"
echo "2. 删除隧道"
echo "3. 查看所有链接"
echo "4. 完全卸载"
echo "0. 退出"
read -p "选择: " NUM

case $NUM in
1) 创建隧道 ;;
2) 删除隧道 ;;
3) 查看链接 ;;
4) 完全卸载 ;;
0) exit ;;
esac
done
}

菜单
