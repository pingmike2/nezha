#!/bin/sh
set -e

# Usage:
#   ./install.sh install_agent <server> <port> <key> [--tls] [--public-ip=1.2.3.4] [--no-nat-detect] [--extra-args="..."]
#   ./install.sh uninstall_agent

if [ "$1" != "install_agent" ] && [ "$1" != "uninstall_agent" ]; then
    echo "Usage:"
    echo "  $0 install_agent <server> <port> <key> [--tls] [--public-ip=1.2.3.4] [--no-nat-detect] [--extra-args=\"...\"]"
    echo "  $0 uninstall_agent"
    exit 1
fi

ACTION=$1

# 修复 /var/run 符号链接问题（Alpine 软链循环）
if [ -L /var/run ] && [ "$(readlink -f /var/run 2>/dev/null)" = "/var/run" ]; then
    rm -f /var/run
    mkdir -p /var/run
fi

# helper: 获取本机 IPv4（尽量多种方式尝试）
get_local_ip() {
    ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 2>/dev/null && return 0
    hostname -I 2>/dev/null | awk '{print $1}' && return 0
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' 2>/dev/null && return 0
    return 1
}

# helper: 判断是否为私网 IP
is_private_ip() {
    ip=$1
    case "$ip" in
      10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|127.*) return 0 ;;
      *) return 1 ;;
    esac
}

# helper: 获取公网 IP（尝试 curl/wget/dig）
get_public_ip() {
    for cmd in \
        "curl -s --max-time 3 https://ifconfig.co" \
        "curl -s --max-time 3 https://icanhazip.com" \
        "curl -s --max-time 3 https://ifconfig.me" \
        "wget -qO- https://ifconfig.co" \
        "wget -qO- https://icanhazip.com" \
        "wget -qO- https://ifconfig.me" \
        "dig +short myip.opendns.com @resolver1.opendns.com"; do
        ip=$(sh -c "$cmd" 2>/dev/null || true)
        ip=$(echo "$ip" | tr -d ' \t\r\n')
        if [ -n "$ip" ] && echo "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    return 1
}

# prepare system (detect init, install helper, tune sysctl)
prepare_system() {
    if [ -f /etc/alpine-release ]; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        if [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
            echo "检测到 Debian/Ubuntu 但未安装 systemd，正在尝试安装 systemd ..."
            apt-get update && apt-get install -y systemd
            INIT_SYSTEM="systemd"
        else
            echo "不支持的初始化系统"
            exit 1
        fi
    fi

    if [ "$INIT_SYSTEM" = "openrc" ] && ! command -v start-stop-daemon >/dev/null 2>&1; then
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

    # 尝试提升 inotify / file-max 等，避免 Too many open files
    echo "调整系统内核参数（inotify / file-max）..."
    sysctl -w fs.inotify.max_user_instances=1024 >/dev/null 2>&1 || true
    sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true
    ulimit -n 1048576 2>/dev/null || true

    export INIT_SYSTEM
}

# -------- main logic --------
if [ "$ACTION" = "install_agent" ]; then
    # 需要至少 4 个参数
    if [ $# -lt 4 ]; then
        echo "参数不足. 用法: $0 install_agent <server> <port> <key> [--tls] [--public-ip=IP] [--no-nat-detect] [--extra-args='...']"
        exit 1
    fi

    NEZHA_SERVER=$2
    NEZHA_PORT=$3
    NEZHA_KEY=$4

    # shift 4 后解析可选参数
    shift 4
    TLS=""
    PUBLIC_IP_OVERRIDE=""
    DO_NAT_DETECT=1
    EXTRA_ARGS=""

    for opt in "$@"; do
        case "$opt" in
            --tls) TLS="--tls" ;;
            --no-nat-detect) DO_NAT_DETECT=0 ;;
            --nat) DO_NAT_DETECT=1 ;;
            --public-ip=*) PUBLIC_IP_OVERRIDE="${opt#*=}" ;;
            --extra-args=*) EXTRA_ARGS="${opt#*=}" ;;
            *) echo "忽略未知选项: $opt" ;;
        esac
    done

    prepare_system

    # 架构检测
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

    # 为了实现 wrapper，我们把实际二进制放到 nezha-agent.bin，然后创建 nezha-agent wrapper
    mkdir -p /usr/local/bin
    mv -f "$TMP_FILE" /usr/local/bin/nezha-agent.bin
    chmod +x /usr/local/bin/nezha-agent.bin

    # 创建 /etc/nezha-agent 配置目录
    mkdir -p /etc/nezha-agent

    # NAT 检测（可被 override）
    PUBLIC_IP=""
    LOCAL_IP="$(get_local_ip 2>/dev/null || true)"
    if [ -n "$PUBLIC_IP_OVERRIDE" ]; then
        PUBLIC_IP="$PUBLIC_IP_OVERRIDE"
        echo "使用用户传入的公网 IP: $PUBLIC_IP"
    elif [ "$DO_NAT_DETECT" -eq 1 ]; then
        if [ -n "$LOCAL_IP" ]; then
            echo "本地 IP: $LOCAL_IP"
            if is_private_ip "$LOCAL_IP"; then
                echo "检测到本地地址为私网，尝试获取公网 IP..."
                PUB="$(get_public_ip 2>/dev/null || true)"
                if [ -n "$PUB" ]; then
                    PUBLIC_IP="$PUB"
                    echo "检测到公网 IP: $PUBLIC_IP （机器可能在 NAT 后面）"
                else
                    echo "无法自动获取公网 IP（网络访问受限或无 curl/wget/dig）"
                fi
            else
                echo "本地 IP 不是私网（可能直接有公网 IP）: $LOCAL_IP"
            fi
        else
            echo "无法获取本地 IP，跳过 NAT 自动检测"
        fi
    else
        echo "已禁用 NAT 自动检测（--no-nat-detect）"
    fi

    # 写入配置（PUBLIC_IP 可为空）
    cat > /etc/nezha-agent/nezha.conf <<EOF
# nezha-agent config (auto-generated)
PUBLIC_IP="${PUBLIC_IP}"
EXTRA_ARGS="${EXTRA_ARGS}"
EOF

    # 创建 wrapper（仅在能识别 agent 支持哪种“广告/外部地址”flag 时，才追加对应 flag）
    cat > /usr/local/bin/nezha-agent <<'EOF'
#!/bin/sh
CONF=/etc/nezha-agent/nezha.conf
PUBLIC_IP=""
EXTRA_ARGS=""
[ -f "$CONF" ] && . "$CONF"

AGENT_BIN="/usr/local/bin/nezha-agent.bin"
# 尝试检测 agent 支持的命令行 flag（谨慎添加额外参数）
HELP=$("$AGENT_BIN" --help 2>&1 || true)

FLAG=""
# 优先常见 flag 名称（可根据实际 agent 帮助扩展）
case "$HELP" in
  *"--public-ip"*) FLAG="--public-ip" ;;
  *"--advertise-addr"*) FLAG="--advertise-addr" ;;
  *"--advertise"*) FLAG="--advertise" ;;
  *"--external-ip"*) FLAG="--external-ip" ;;
  *) FLAG="" ;;
esac

EXTRA=""
if [ -n "$PUBLIC_IP" ] && [ -n "$FLAG" ]; then
  EXTRA="$FLAG $PUBLIC_IP"
fi

# 如果用户设置了 EXTRA_ARGS（来自 /etc/nezha-agent/nezha.conf），追加它（安全起见不会拆分）
if [ -n "$EXTRA_ARGS" ]; then
  EXTRA="$EXTRA $EXTRA_ARGS"
fi

# 最终执行：把所有传给 wrapper 的参数传递给真实二进制，并在末尾追加自动检测到的参数（如果有）
exec "$AGENT_BIN" "$@" $EXTRA
EOF
    chmod +x /usr/local/bin/nezha-agent

    mkdir -p /var/log

    # 安装服务单元
    case "$INIT_SYSTEM" in
        openrc)
            echo "配置 OpenRC 服务"
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
EnvironmentFile=-/etc/nezha-agent/nezha.conf
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
    echo "配置文件: /etc/nezha-agent/nezha.conf"
    echo "日志文件: /var/log/nezha-agent.log"
    if [ -n "$PUBLIC_IP" ]; then
        echo "检测到公网 IP 并写入配置: $PUBLIC_IP"
        echo "wrapper 会在 agent 支持对应参数时自动将其传入（例如 --public-ip / --advertise-addr 等）"
    else
        echo "未检测到可用公网 IP（或检测被禁用）。如果机器在 NAT 后面，需要在路由器做端口映射，或在安装时传入 --public-ip=你的公网IP，或在 /etc/nezha-agent/nezha.conf 手动设置 EXTRA_ARGS"
    fi

    exit 0
fi

# 卸载
if [ "$ACTION" = "uninstall_agent" ]; then
    # 先探测 init
    if [ -f /etc/alpine-release ]; then
        INIT_SYSTEM="openrc"
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="unknown"
    fi

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

    rm -f /usr/local/bin/nezha-agent /usr/local/bin/nezha-agent.bin
    rm -f /etc/nezha-agent/nezha.conf
    rm -f /var/log/nezha-agent.log /var/log/nezha-agent.err 2>/dev/null || true
    echo "卸载完成!"
    exit 0
fi