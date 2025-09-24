#!/bin/sh
set -e

# 参数检查
if [ "$1" != "install_agent" ] && [ "$1" != "uninstall_agent" ]; then
    echo "Usage:"
    echo "  $0 install_agent <server> <port> <key> [--tls]"
    echo "  $0 uninstall_agent"
    exit 1
fi

# 修复 /var/run 符号链接问题（Alpine 特有 bug）
if [ -L /var/run ] && [ "$(readlink -f /var/run 2>/dev/null)" = "/var/run" ]; then
    rm -f /var/run
    mkdir -p /var/run
fi

ACTION=$1
NEZHA_SERVER=$2
NEZHA_PORT=$3
NEZHA_KEY=$4
TLS=${5:-""}

# 系统检测与依赖准备
prepare_system() {
    if [ -f /etc/alpine-release ]; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        if [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
            echo "检测到 Debian/Ubuntu 但未安装 systemd，正在安装..."
            apt-get update && apt-get install -y systemd
            INIT_SYSTEM="systemd"
        else
            echo "不支持的初始化系统"
            exit 1
        fi
    fi

    if ! command -v start-stop-daemon >/dev/null 2>&1 && [ "$INIT_SYSTEM" = "openrc" ]; then
        echo "正在安装 start-stop-daemon..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache openrc
        else
            apt-get update && apt-get install -y start-stop-daemon || {
                echo "无法安装 start-stop-daemon，切换到 systemd"
                INIT_SYSTEM="systemd"
            }
        fi
    fi

    # 自动修复 inotify/file-max 限制
    echo "调整系统资源限制..."
    sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1 || true
    sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
    ulimit -n 1048576 || true

    export INIT_SYSTEM
}

prepare_system

if [ "$ACTION" = "install_agent" ]; then
    echo "开始安装哪吒探针..."

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
    mv -f "$TMP_FILE" /usr/local/bin/nezha-agent

    mkdir -p /var/log

    case "$INIT_SYSTEM" in
        openrc)
            echo "配置 OpenRC 服务"
            cat > /etc/init.d/nezha-agent <<EOF
#!/sbin/openrc-run
name="nezha-agent"
command="/usr/local/bin/nezha-agent"
command_args="-s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4"
pidfile="/var/run/\${RC_SVCNAME}.pid"
output_log="/var/log/\$name.log"
error_log="/var/log/\$name.err"

depend() { need net; }
EOF
            chmod +x /etc/init.d/nezha-agent
            rc-update add nezha-agent default
            rc-service nezha-agent restart || rc-service nezha-agent start
            ;;

        systemd)
            echo "配置 systemd 服务"
            cat > /etc/systemd/system/nezha-agent.service <<EOF
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nezha-agent -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${TLS} --skip-conn --disable-auto-update --skip-procs --report-delay 4
Restart=always
User=root
StandardOutput=append:/var/log/nezha-agent.log
StandardError=append:/var/log/nezha-agent.err
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable nezha-agent
            systemctl restart nezha-agent || systemctl start nezha-agent
            ;;
    esac

    echo "安装完成!"
    echo "管理命令:"
    case "$INIT_SYSTEM" in
        openrc) echo "  rc-service nezha-agent [start|stop|status|restart]" ;;
        systemd) echo "  systemctl [start|stop|status|restart] nezha-agent" ;;
    esac
    echo "日志文件: /var/log/nezha-agent.log"
fi

if [ "$ACTION" = "uninstall_agent" ]; then
    echo "卸载哪吒探针..."
    case "$INIT_SYSTEM" in
        openrc)
            rc-service nezha-agent stop 2>/dev/null || true
            rc-update del nezha-agent 2>/dev/null || true
            rm -f /etc/init.d/nezha-agent
            ;;
        systemd)
            systemctl stop nezha-agent 2>/dev/null || true
            systemctl disable nezha-agent 2>/dev/null || true
            rm -f /etc/systemd/system/nezha-agent.service
            systemctl daemon-reload 2>/dev/null || true
            ;;
    esac

    rm -f /usr/local/bin/nezha-agent
    rm -f /var/log/nezha-agent.log /var/log/nezha-agent.err 2>/dev/null
    echo "卸载完成!"
fi