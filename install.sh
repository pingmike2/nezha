#!/bin/sh

set -e

# 参数检查
if [ "$1" != "install_agent" ] && [ "$1" != "uninstall_agent" ]; then
    echo "Usage:"
    echo "  $0 install_agent <server> <port> <key> [--tls]"
    echo "  $0 uninstall_agent"
    exit 1
fi

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS=${5:-""}

# 修复 /var/run 符号链接问题
if [ -L /var/run ] && [ "$(readlink -f /var/run)" = "/var/run" ]; then
    rm -f /var/run
    mkdir -p /var/run
fi

# 安装探针
if [ "$ACTION" = "install_agent" ]; then
    echo "开始安装哪吒探针..."
    
    # 检测架构
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

    # 检测是否为Alpine系统
    if [ -f /etc/alpine-release ]; then
        echo "检测到Alpine系统，配置OpenRC服务"
        
        # 安装openrc如果不存在
        if ! command -v openrc >/dev/null; then
            apk add --no-cache openrc
        fi

        # 创建OpenRC服务
        cat > /etc/init.d/nezha-agent <<EOF
#!/sbin/openrc-run

name="nezha-agent"
description="Nezha Agent Service"
command="/usr/local/bin/nezha-agent"
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
    start-stop-daemon --start \\
        --exec \$command \\
        --background \\
        --make-pidfile \\
        --pidfile \$pidfile \\
        --stdout /var/log/\$name.log \\
        --stderr /var/log/\$name.err \\
        -- \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping \$name"
    start-stop-daemon --stop --pidfile \$pidfile
    eend \$?
}
EOF

        chmod +x /etc/init.d/nezha-agent
        rc-update add nezha-agent default
        rc-service nezha-agent start
        echo "OpenRC服务已配置并启动"
    else
        echo "非Alpine系统，请使用其他安装方式"
        exit 1
    fi

    echo "哪吒探针安装完成!"
    echo "使用以下命令管理服务:"
    echo "启动: rc-service nezha-agent start"
    echo "停止: rc-service nezha-agent stop"
    echo "状态: rc-service nezha-agent status"
fi

# 卸载探针
if [ "$ACTION" = "uninstall_agent" ]; then
    echo "开始卸载哪吒探针..."
    
    if [ -f /etc/init.d/nezha-agent ]; then
        rc-service nezha-agent stop 2>/dev/null || true
        rc-update del nezha-agent 2>/dev/null || true
        rm -f /etc/init.d/nezha-agent
    fi
    
    rm -f /usr/local/bin/nezha-agent
    rm -f /var/log/nezha-agent.log /var/log/nezha-agent.err 2>/dev/null
    
    echo "哪吒探针已卸载"
fi
