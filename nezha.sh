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
WRAPPER_PATH="/usr/local/bin/nezha-wrapper.sh"
LOG_FILE="/var/log/nezha-agent.log"

# ---------- 系统参数优化 ----------
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
        echo "检测到内网地址: $LOCAL_IP, 尝试获取公网 IP..."
        curl -s --max-time 5 ipv4.icanhazip.com || \
        curl -s --max-time 5 ifconfig.me || \
        curl -s --max-time 5 ip.sb || \
        echo "$LOCAL_IP"
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
BIN_PATH=$BIN_PATH
EOF
}

# ---------- 写 wrapper 脚本 ----------
write_wrapper() {
    cat > "$WRAPPER_PATH" <<'EOF'
#!/bin/sh
. /etc/nezha-agent/nezha.conf

ARGS="-s ${SERVER}:${PORT} -p ${KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"

# 检测 --public-ip 支持
if $BIN_PATH --help 2>&1 | grep -q -- "--public-ip"; then
    ARGS="$ARGS --public-ip=${PUBLIC_IP}"
fi

exec $BIN_PATH $ARGS
EOF
    chmod +x "$WRAPPER_PATH"
}

# ---------- systemd ----------
setup_systemd() {
    echo "配置 systemd 服务..."
    cat > /etc/systemd/system/nezha-agent.service <<EOF
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
ExecStart=$WRAPPER_PATH
Restart=always
User=root
LimitNOFILE=65535
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now nezha-agent
}

# ---------- openrc (alpine) ----------
setup_openrc() {
    echo "配置 OpenRC 服务 (Alpine)..."
    mkdir -p /etc/init.d
    cat > /etc/init.d/nezha-agent <<EOF
#!/sbin/openrc-run
description="Nezha Agent"

command="$WRAPPER_PATH"
pidfile="/run/nezha-agent.pid"
command_background="yes"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
}
EOF
    chmod +x /etc/init.d/nezha-agent
    rc-update add nezha-agent default
    rc-service nezha-agent restart
}

# ---------- 主逻辑 ----------
if [ "$ACTION" = "install_agent" ]; then
    optimize_limits
    download_agent
    write_config
    write_wrapper

    if command -v systemctl >/dev/null 2>&1; then
        setup_systemd
    elif command -v rc-update >/dev/null 2>&1; then
        setup_openrc
    else
        echo "未检测到 systemd 或 openrc，需手动配置守护进程"
        exit 1
    fi

    echo "安装完成!"
    echo "管理命令: systemctl [start|stop|status|restart] nezha-agent (systemd)"
    echo "        rc-service nezha-agent start|stop|status (openrc/alpine)"
    echo "配置文件: $CONFIG_FILE"
    echo "日志文件: $LOG_FILE"

elif [ "$ACTION" = "uninstall_agent" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nezha-agent 2>/dev/null || true
        systemctl disable nezha-agent 2>/dev/null || true
        rm -f /etc/systemd/system/nezha-agent.service
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service nezha-agent stop 2>/dev/null || true
        rc-update del nezha-agent 2>/dev/null || true
        rm -f /etc/init.d/nezha-agent
    fi
    rm -rf "$CONFIG_DIR"
    rm -f "$BIN_PATH" "$WRAPPER_PATH" "$LOG_FILE"
    echo "卸载完成!"

else
    echo "用法:"
    echo "  $0 install_agent <server> <port> <key> [--tls]"
    echo "  $0 uninstall_agent"
    exit 1
fi