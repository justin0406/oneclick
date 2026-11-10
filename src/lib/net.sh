# lib/net.sh —— 公网 IP 探测 / 端口占用检查
#
# 本脚本不修改系统防火墙：不写 iptables/nftables/firewalld/ufw 规则，端口是否
# 可达由你自己的防火墙策略决定。唯一例外是 hysteria2 的端口跳跃——那由 hysteria
# 按其 listen 端口段自行安装/清理转发规则（见 src/proto/hysteria2.sh）。

# ===========================================================================
# 内部工具：公网 IP 校验 / 端口数字校验
# ===========================================================================

_net_is_ipv4() {
    local rest="$1" octet
    [[ "$rest" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    while [[ -n "$rest" ]]; do
        octet="${rest%%.*}"
        ((10#$octet <= 255)) || return 1
        [[ "$rest" == *.* ]] || break
        rest="${rest#*.}"
    done
    return 0
}

# 端口合法则规范化输出（去前导零），否则返回 1
_net_port_num() {
    local p="$1" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    ((n >= 1 && n <= 65535)) || return 1
    printf '%s' "$n"
}

# ===========================================================================
# 公网 IPv4（多源兜底；全失败输出空，绝不 exit）
# ===========================================================================

net_primary_ip() {
    local ip url
    if ! command -v curl >/dev/null 2>&1; then
        oc_warn "缺少 curl，无法探测公网 IP"
        return 0
    fi
    for url in https://ip.sb https://ifconfig.me https://api.ipify.org https://4.ipw.cn; do
        ip="$(curl -4 -fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]')"
        if _net_is_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    # 全部源失败时输出空串，由调用方决定是否提示（安装流程不能因此中断）
    return 0
}

# ===========================================================================
# 端口占用：ss -> netstat -> /proc（容器/精简系统最后兜底）
# ===========================================================================

_net_proc_port_in_use() {
    local port="$1" proto="$2" hex f
    hex="$(printf '%04X' "$port")" || return 1
    if [[ "$proto" == "udp" ]]; then
        for f in /proc/net/udp /proc/net/udp6; do
            [[ -r "$f" ]] || continue
            if awk -v h=":$hex" 'NR > 1 && index(toupper($2), h) { f = 1 } END { exit !f }' "$f"; then
                return 0
            fi
        done
    else
        for f in /proc/net/tcp /proc/net/tcp6; do
            [[ -r "$f" ]] || continue
            if awk -v h=":$hex" 'NR > 1 && index(toupper($2), h) && $4 == "0A" { f = 1 } END { exit !f }' "$f"; then
                return 0
            fi
        done
    fi
    return 1
}

# net_port_in_use <port> <tcp|udp>：0 = 已占用
net_port_in_use() {
    local port proto
    port="$(_net_port_num "$1")" || return 1
    proto="${2:-tcp}"
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            ss -lun 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { f = 1 } END { exit !f }'
        else
            ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { f = 1 } END { exit !f }'
        fi
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            netstat -lnu 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { f = 1 } END { exit !f }'
        else
            netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") { f = 1 } END { exit !f }'
        fi
        return
    fi
    _net_proc_port_in_use "$port" "$proto"
}

# net_port_random：在 OC_PORT_MIN..OC_PORT_MAX 内随机挑一个 tcp/udp 都空闲的端口
net_port_random() {
    local min="${OC_PORT_MIN:-20000}" max="${OC_PORT_MAX:-60000}"
    local i p span
    span=$((max - min + 1))
    for ((i = 0; i < 50; i++)); do
        p=$(( (RANDOM * 32768 + RANDOM) % span + min ))
        if ! net_port_in_use "$p" tcp && ! net_port_in_use "$p" udp; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

# net_port_pick <start_hint> <tcp|udp>：从 hint 起找空闲端口（先向上，再回头扫 1024+）
net_port_pick() {
    local start proto p
    start="$(_net_port_num "${1:-8443}")" || start=8443
    proto="${2:-tcp}"
    for ((p = start; p <= 65535; p++)); do
        if ! net_port_in_use "$p" "$proto"; then
            printf '%s' "$p"
            return 0
        fi
    done
    for ((p = 1024; p < start; p++)); do
        if ! net_port_in_use "$p" "$proto"; then
            printf '%s' "$p"
            return 0
        fi
    done
    # 一个都找不到属于极端情况：输出空，由调用方报错
    return 1
}

# IPv6 栈可用性：有栈才敢绑 ::（Linux 下绑 :: 默认双栈，IPv4 连接也能进来）
oc_ipv6_ready() {
    [[ -r /proc/net/if_inet6 && -s /proc/net/if_inet6 ]] && return 0
    command -v ip >/dev/null 2>&1 && ip -6 addr show 2>/dev/null | grep -q 'inet6 ' && return 0
    return 1
}

# 监听主机：有 IPv6 栈用 "::"（双栈），否则 "0.0.0.0"
oc_listen_host() {
    if oc_ipv6_ready; then
        printf '::'
    else
        printf '0.0.0.0'
    fi
}

# 监听地址:端口：有 IPv6 栈用 "[::]:port"，否则 "0.0.0.0:port"
oc_listen_addr() {
    local port="$1"
    if oc_ipv6_ready; then
        printf '[::]:%s' "$port"
    else
        printf '0.0.0.0:%s' "$port"
    fi
}
