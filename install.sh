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

# 判断系统
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

  # 下载对应二进制
  if [ "$ARCH" = "arm" ]; then
    FILE_URL="https://github.com/eooce/test/releases/download/ARM/swith"
  else
    FILE_URL="https://github.com/eooce/test/releases/download/bulid/swith"
  fi

  echo "下载探针二进制 $FILE_URL 到 $FILE_NAME"
  wget -q -O $FILE_NAME $FILE_URL
  chmod +x $FILE_NAME

  # 处理TLS参数
  if [ "$TLS_FLAG" = "--tls" ]; then
    TLS="--tls"
  else
    TLS=""
  fi

# Alpine 系统用 openrc 提供 supervise-daemon
if [ "$PKG_TOOL" = "apk" ]; then
  if ! command -v supervise-daemon >/dev/null 2>&1; then
    echo "安装 openrc（包含 supervise-daemon）..."
    apk add --no-cache openrc
  fi
fi

    SERVICE_FILE="/etc/init.d/$SERVICE_NAME"
    echo "创建 OpenRC 服务脚本 $SERVICE_FILE"
    cat > $SERVICE_FILE <<EOF
#!/sbin/openrc-run

name="$SERVICE_NAME"
description="Nezha Agent Daemon"

command="$FILE_NAME"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/$SERVICE_NAME.pid"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /var/run
}

start() {
  supervise-daemon --start --name \$name --pidfile \$pidfile --stdout /var/log/$SERVICE_NAME.log --stderr /var/log/$SERVICE_NAME.err --respawn -- \$command \$command_args
}

stop() {
  supervise-daemon --stop --name \$name --pidfile \$pidfile
}
EOF
    chmod +x $SERVICE_FILE
    rc-update add $SERVICE_NAME default
    rc-service $SERVICE_NAME start
    echo "OpenRC服务启动成功"

  else
    # Debian/Ubuntu
    echo "安装 supervise-daemon"
    apt-get update
    apt-get install -y supervise-daemon

    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
    echo "创建 systemd 服务文件 $SERVICE_FILE"
    cat > $SERVICE_FILE <<EOF
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
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME
    echo "systemd服务启动成功"
  fi

  echo "安装完成！"
  echo "查看服务状态:"
  if [ "$SYSTEM" = "alpine" ]; then
    echo "rc-service $SERVICE_NAME status"
  else
    echo "systemctl status $SERVICE_NAME"
  fi
  echo "日志文件: /var/log/$SERVICE_NAME.log 和 /var/log/$SERVICE_NAME.err"

elif [ "$ACTION" = "uninstall_agent" ]; then
  echo "开始卸载哪吒探针..."

  if [ "$SYSTEM" = "alpine" ]; then
    rc-service $SERVICE_NAME stop || true
    rc-update del $SERVICE_NAME || true
    rm -f /etc/init.d/$SERVICE_NAME
  else
    systemctl stop $SERVICE_NAME || true
    systemctl disable $SERVICE_NAME || true
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    systemctl daemon-reload
  fi

  rm -f $FILE_NAME
  rm -f /var/log/$SERVICE_NAME.log /var/log/$SERVICE_NAME.err

  echo "卸载完成！"
fi
