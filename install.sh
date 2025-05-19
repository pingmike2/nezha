#!/bin/sh

set -e

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS_FLAG=$5

if [ "$ACTION" != "install_agent" ] && [ "$ACTION" != "uninstall_agent" ]; then
  echo "Usage:"
  echo "  $0 install_agent <server> <port> <key> [--tls]"
  echo "  $0 uninstall_agent"
  exit 1
fi

# 提前修复 /var/run 循环问题
if [ -L /var/run ] && [ "$(readlink -f /var/run 2>/dev/null)" = "/var/run" ]; then
  echo "检测到 /var/run 符号链接循环，修复中..."
  rm -f /var/run
  mkdir -p /var/run
  echo "已修复 /var/run"
fi

# 判断系统类型
detect_system() {
  if [ -f /etc/alpine-release ]; then
    echo "alpine"
  elif [ -f /etc/debian_version ]; then
    echo "debian"
  elif [ -f /etc/lsb-release ]; then
    echo "ubuntu"
  else
    echo "unsupported"
  fi
}

SYSTEM=$(detect_system)
if [ "$SYSTEM" = "unsupported" ]; then
  echo "不支持的系统"
  exit 1
fi

FILE_NAME="/usr/local/bin/nezha-agent"
SERVICE_NAME="nezha-agent"

if [ "$ACTION" = "install_agent" ]; then
  echo "开始安装哪吒探针..."

  # 判断架构
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
    ARCH="amd"
  elif echo "$ARCH" | grep -q "arm"; then
    ARCH="arm"
  else
    echo "不支持的架构: $ARCH"
    exit 1
  fi
  echo "检测到架构：$ARCH"

  # 下载探针二进制
  if [ "$ARCH" = "arm" ]; then
    FILE_URL="https://github.com/eooce/test/releases/download/ARM/swith"
  else
    FILE_URL="https://github.com/eooce/test/releases/download/bulid/swith"
  fi

  echo "下载探针二进制 $FILE_URL 到 $FILE_NAME"
  wget -q -O "$FILE_NAME" "$FILE_URL" || { echo "下载失败"; exit 1; }
  chmod +x "$FILE_NAME"

  # 处理 TLS 参数
  if [ "$TLS_FLAG" = "--tls" ]; then
    TLS="--tls"
  else
    TLS=""
  fi
  
  if [ "$SYSTEM" = "alpine" ]; then
    # Alpine 系统使用 openrc + supervise-daemon
    if ! command -v supervise-daemon >/dev/null 2>&1; then
      echo "安装 openrc（包含 supervise-daemon）..."
      apk add --no-cache openrc || { echo "安装 openrc 失败"; exit 1; }
    fi

    SERVICE_FILE="/etc/init.d/$SERVICE_NAME"
    echo "创建 OpenRC 服务脚本 $SERVICE_FILE"

    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="$SERVICE_NAME"
description="Nezha Agent Daemon"

command="$FILE_NAME"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/\${RC_SVCNAME}.pid"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /var/run || return 1
}

start() {
  ebegin "Starting \$name"
  start-stop-daemon --start --exec \$command \
    --background --make-pidfile --pidfile \$pidfile \
    --stdout /var/log/\$name.log --stderr /var/log/\$name.err \
    -- \$command_args
  eend \$?
}

stop() {
  ebegin "Stopping \$name"
  start-stop-daemon --stop --pidfile \$pidfile
  eend \$?
}
EOF

    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" start || { echo "启动服务失败"; exit 1; }
    echo "OpenRC 服务启动成功"

  else
    # Debian/Ubuntu 使用 systemd
    if ! command -v systemctl >/dev/null 2>&1; then
      echo "安装 systemd..."
      apt-get update && apt-get install -y systemd || { echo "安装 systemd 失败"; exit 1; }
    fi

    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    echo "创建 systemd 服务文件 $SERVICE_FILE"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
ExecStart=$FILE_NAME -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4
Restart=always
RestartSec=5
StandardOutput=file:/var/log/$SERVICE_NAME.log
StandardError=file:/var/log/$SERVICE_NAME.err
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || { echo "systemd 重载失败"; exit 1; }
    systemctl enable "$SERVICE_NAME" || { echo "启用服务失败"; exit 1; }
    systemctl start "$SERVICE_NAME" || { echo "启动服务失败"; exit 1; }
    echo "systemd 服务启动成功"
  fi

  echo "安装完成！"
  echo "查看服务状态:"
  if [ "$SYSTEM" = "alpine" ]; then
    rc-service "$SERVICE_NAME" status
  else
    systemctl status "$SERVICE_NAME"
  fi
  echo "日志文件: /var/log/$SERVICE_NAME.log 和 /var/log/$SERVICE_NAME.err"

elif [ "$ACTION" = "uninstall_agent" ]; then
  echo "开始卸载哪吒探针..."

  if [ "$SYSTEM" = "alpine" ]; then
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/init.d/$SERVICE_NAME"
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$SERVICE_NAME.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$FILE_NAME"
  rm -f "/var/log/$SERVICE_NAME.log" "/var/log/$SERVICE_NAME.err"

  echo "卸载完成！"
fi
