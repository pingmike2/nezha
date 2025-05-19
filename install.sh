#!/bin/sh
set -e

# 参数检查
if [ "$1" != "install_agent" ] && [ "$1" != "uninstall_agent" ]; then
    echo "Usage:"
    echo "  $0 install_agent <server> <port> <key> [--tls]"
    echo "  $0 uninstall_agent"
    exit 1
fi

# 修复 /var/run 符号链接问题
if [ -L /var/run ] && [ "$(readlink -f /var/run 2>/dev/null)" = "/var/run" ]; then
    rm -f /var/run
    mkdir -p /var/run
fi

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS=${5:-""}

if [ "$ACTION" = "install_agent" ]; then
    echo "开始安装哪吒探针..."
    
    # 架构检测
    case $(uname -m) in
        x86_64|amd64) ARCH=amd ;;
        armv7l|armv8l|aarch64) ARCH=arm ;;
        *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    echo "检测到架构: $ARCH"

    # 下载探针
    BIN_URL="https://github.com/eooce/test/releases/download/$([ "$ARCH" = "arm" ] && echo "ARM" || echo "bulid")/swith"
    echo "下载探针: $BIN_URL"
    wget -qO /usr/local/bin/nezha-agent "$BIN_URL" || { echo "下载失败"; exit 1; }
    chmod +x /usr/local/bin/nezha-agent

    # Alpine 服务配置
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/nezha-agent <<EOF
#!/sbin/openrc-run
name="nezha-agent"
command="/usr/local/bin/nezha-agent"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/\${RC_SVCNAME}.pid"

depend() { need net; }

start() {
    start-stop-daemon --start \\
        --exec \$command \\
        --background \\
        --make-pidfile \\
        --pidfile \$pidfile \\
        --stdout /var/log/\$name.log \\
        --stderr /var/log/\$name.err \\
        -- \$command_args
}
EOF
        chmod +x /etc/init.d/nezha-agent
        rc-update add nezha-agent default
        rc-service nezha-agent start
    fi
    echo "安装完成!"
fi

if [ "$ACTION" = "uninstall_agent" ]; then
    rc-service nezha-agent stop 2>/dev/null || true
    rc-update del nezha-agent 2>/dev/null || true
    rm -f /etc/init.d/nezha-agent /usr/local/bin/nezha-agent
    echo "卸载完成!"
fi
