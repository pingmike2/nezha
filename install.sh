#!/bin/sh

set -e

# 参数处理
ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS_FLAG=$5

[ "$ACTION" != "install_agent" ] && [ "$ACTION" != "uninstall_agent" ] && {
  echo "Usage:"
  echo "  $0 install_agent <server> <port> <key> [--tls]"
  echo "  $0 uninstall_agent"
  exit 1
}

# 修复 /var/run 问题
[ -L /var/run ] && [ "$(readlink -f /var/run 2>/dev/null)" = "/var/run" ] && {
  rm -f /var/run
  mkdir -p /var/run
}

# 安装探针
if [ "$ACTION" = "install_agent" ]; then
  echo "开始安装哪吒探针..."
  
  # 架构检测
  case $(uname -m) in
    x86_64|amd64) ARCH=amd ;;
    arm*) ARCH=arm ;;
    *) echo "不支持的架构"; exit 1 ;;
  esac
  echo "检测到架构：$ARCH"

  # 下载探针
  URL="https://github.com/eooce/test/releases/download/$([ "$ARCH" = "arm" ] && echo "ARM" || echo "bulid")/swith"
  echo "下载探针: $URL"
  wget -qO /usr/local/bin/nezha-agent "$URL" || { echo "下载失败"; exit 1; }
  chmod +x /usr/local/bin/nezha-agent

  # 创建服务
  if [ -f /etc/alpine-release ]; then
    # Alpine 系统
    cat > /etc/init.d/nezha-agent <<EOF
#!/sbin/openrc-run
name="nezha-agent"
command="/usr/local/bin/nezha-agent"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS_FLAG} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/\${RC_SVCNAME}.pid"

depend() { need net; }

start() {
  start-stop-daemon --start --exec \$command \\
    --background --make-pidfile --pidfile \$pidfile \\
    --stdout /var/log/\$name.log --stderr /var/log/\$name.err \\
    -- \$command_args
}

stop() {
  start-stop-daemon --stop --pidfile \$pidfile
}
EOF
    chmod +x /etc/init.d/nezha-agent
    rc-update add nezha-agent default
    rc-service nezha-agent start
  else
    # 其他系统
    cat > /etc/systemd/system/nezha-agent.service <<EOF
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nezha-agent -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS_FLAG} --skip-conn --disable-auto-update --skip-procs --report-delay 4
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable nezha-agent
    systemctl start nezha-agent
  fi

  echo "安装完成!"
fi

# 卸载探针
[ "$ACTION" = "uninstall_agent" ] && {
  [ -f /etc/alpine-release ] && {
    rc-service nezha-agent stop
    rc-update del nezha-agent
    rm -f /etc/init.d/nezha-agent
  } || {
    systemctl stop nezha-agent
    systemctl disable nezha-agent
    rm -f /etc/systemd/system/nezha-agent.service
    systemctl daemon-reload
  }
  rm -f /usr/local/bin/nezha-agent
  echo "卸载完成!"
}
