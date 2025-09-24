#!/bin/sh
set -e

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS=${5:-""}

CONFIG_DIR="/etc/nezha-agent"
CONFIG_FILE="$CONFIG_DIR/nezha.conf"
BIN_PATH="/usr/local/bin/nezha-agent"
LOG_FILE="/var/log/nezha-agent.log"

# ---------- 系统参数调优 ----------
optimize_limits() {
    echo "调优系统参数 (nofile / inotify / file-max)..."
    ulimit -n 65535 || true
    cat >> /etc/sysctl.conf <<EOF
fs.inotify.max_user_watches=1048576
fs.file-max=2097152
EOF
    sysctl -p >/dev/null 2>&1 || true
}

# ---------- 获取公网 IP ----------
get_public_ip() {
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if echo "$LOCAL_IP" | grep -qE '^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[01]\.|^192\.168\.'; then
        echo "检测到本地地址为私网: $LOCAL_IP, 正在获取公网 IP..."
        curl -s --max-time 5 ipv4.icanhazip.com || curl -s --max-time 5 ifconfig.me
    else
        echo "$LOCAL_IP"
    fi
}

# ---------- 下载探针 ----------
download_agent() {
    case $(uname -m) in
        x86_64|amd64) ARCH=amd ;;
        armv7l|armv8l|aarch64) ARCH=arm ;;
        *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    echo "检测到架构: $ARCH"

    BASE_URL="https://github.com/eooce/test/releases/download/$([ "$ARCH" = "arm" ] && echo "ARM" || echo "bulid")/swith"
    TMP_FILE=$(mktemp)

    echo "下载探针: $BASE_URL"
    if ! wget -qO "$TMP_FILE" "$BASE_URL"; then
        echo "主源下载失败，尝试代理源..."
        PROXY_URL="https://proxy.avotc.tk/$BASE_URL"
        wget -qO "$TMP_FILE" "$PROXY_URL" || { echo "下载失败"; exit 1; }
    fi

    chmod +x "$TMP_FILE"
    mv -f "$TMP_FILE" "$BIN_PATH"
}

# ---------- 写配置 ----------
write_config() {
    mkdir -p "$CONFIG_DIR"
    PUBLIC_IP=$(get_public_ip)
    echo "最终公网 IP: $PUBLIC_IP"

    cat > "$CONFIG_FILE" <<EOF
SERVER=$NEZHA_SERVER
PORT=$NEZHA_PORT
KEY=$NEZHA_KEY
TLS=$TLS
PUBLIC_IP=$PUBLIC_IP
EOF
}

# ---------- 配置 systemd ----------
setup_systemd() {
    echo "配置 systemd 服务..."
    cat > /etc/systemd/system/nezha-agent.service <<EOF
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
EnvironmentFile=$CONFIG_FILE
ExecStart=$BIN_PATH -s \${SERVER}:\${PORT} -p \${KEY} \${TLS} \\
  --skip-conn --disable-auto-update --skip-procs --report-delay 4 \\
  --public-ip=\${PUBLIC_IP}
Restart=always
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now nezha-agent
}

# ---------- 主逻辑 ----------
if [ "$ACTION" = "install_agent" ]; then
    optimize_limits
    download_agent
    write_config
    setup_systemd

    echo "安装完成!"
    echo "管理命令: systemctl [start|stop|status|restart] nezha-agent"
    echo "配置文件: $CONFIG_FILE"
    echo "日志文件: $LOG_FILE"
elif [ "$ACTION" = "uninstall_agent" ]; then
    systemctl stop nezha-agent 2>/dev/null || true
    systemctl disable nezha-agent 2>/dev/null || true
    rm -f /etc/systemd/system/nezha-agent.service
    rm -rf "$CONFIG_DIR"
    rm -f "$BIN_PATH" "$LOG_FILE"
    systemctl daemon-reload
    echo "卸载完成!"
else
    echo "用法:"
    echo "  $0 install_agent <server> <port> <key> [--tls]"
    echo "  $0 uninstall_agent"
    exit 1
fi