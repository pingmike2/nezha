#!/bin/sh

set -e

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS_FLAG=$5

if [ "$ACTION" != "install_agent" ]; then
  echo "Usage: $0 install_agent <server> <port> <key> [--tls]"
  exit 1
fi

echo "开始安装哪吒探针..."

# 判断系统
if [ -f /etc/alpine-release ]; then
  SYSTEM="alpine"
elif [ -f /etc/debian_version ]; then
  SYSTEM="debian"
elif [ -f /etc/lsb-release ]; then
  SYSTEM="ubuntu"
else
  echo "不支持的系统"
  exit 1
fi
echo "检测到系统：$SYSTEM"

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

# 安装 supervise-daemon
echo "安装 supervise-daemon"
if [ "$SYSTEM" = "alpine" ]; then
  apk add --no-cache supervise-daemon
elif [ "$SYSTEM" = "ubuntu" ] || [ "$SYSTEM" = "debian" ]; then
  apt-get update && apt-get install -y supervise-daemon
fi

# 下载对应二进制
if [ "$ARCH" = "arm" ]; then
  FILE_URL="https://github.com/eooce/test/releases/download/ARM/swith"
else
  FILE_URL="https://github.com/eooce/test/releases/download/bulid/swith"
fi

FILE_NAME="/usr/local/bin/nezha-agent"

echo "下载探针二进制 $FILE_URL 到 $FILE_NAME"
wget -q -O $FILE_NAME $FILE_URL
chmod +x $FILE_NAME

# 处理TLS参数
if [ "$TLS_FLAG" = "--tls" ]; then
  TLS="--tls"
else
  TLS=""
fi

# 写 OpenRC 服务脚本 (兼容 Alpine、Debian、Ubuntu)
SERVICE_FILE="/etc/init.d/nezha-agent"

echo "创建 OpenRC 服务脚本 $SERVICE_FILE"

cat > $SERVICE_FILE <<EOF
#!/sbin/openrc-run

name="nezha-agent"
description="Nezha Agent Daemon"

command="$FILE_NAME"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/nezha-agent.pid"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath --directory --mode 0755 /var/run
}

start() {
  supervise-daemon --start --name \$name --pidfile \$pidfile --stdout /var/log/nezha-agent.log --stderr /var/log/nezha-agent.err --respawn -- $command $command_args
}

stop() {
  supervise-daemon --stop --name \$name --pidfile \$pidfile
}
EOF

chmod +x $SERVICE_FILE

# 启用服务
echo "添加服务并启动 nezha-agent"
rc-update add nezha-agent default
rc-service nezha-agent start

echo "安装完成！"
echo "你可以用 'rc-service nezha-agent status' 查看状态"
echo "日志文件: /var/log/nezha-agent.log 和 /var/log/nezha-agent.err"
