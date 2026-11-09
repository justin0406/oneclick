# lib/net.sh —— 公网 IP / 端口占用 / 防火墙四后端 / BBR+TFO / UDP 端口跳跃
#
# 防火墙纪律（SPEC §6）：只增删本脚本自己的规则，绝不清表、绝不碰别人的规则。
#   * nft      —— 独立 table `inet oneclick`，每条规则带 comment "oneclick-*"
#   * iptables —— `-m comment --comment "oneclick-*"`，删除前先 -C 确认存在
#   * firewalld/ufw —— 按端口精确增删；ufw 额外写 comment 便于回收
# 探测顺序按契约：nft -> firewalld -> ufw -> iptables。

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

# ===========================================================================
# 防火墙：后端探测
# ===========================================================================

_net_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

_net_ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    ufw status 2>/dev/null | grep -qw 'active'
}

# 契约顺序：nft（root + nft 可用）-> firewalld -> ufw(active) -> iptables -> none
net_fw_backend() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v nft >/dev/null 2>&1 \
        && nft list tables >/dev/null 2>&1; then
        printf 'nft'
        return 0
    fi
    if _net_firewalld_active; then
        printf 'firewalld'
        return 0
    fi
    if _net_ufw_active; then
        printf 'ufw'
        return 0
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -S INPUT >/dev/null 2>&1; then
        printf 'iptables'
        return 0
    fi
    printf 'none'
}

# ===========================================================================
# 防火墙：nft 后端（独立 table inet oneclick）
# ===========================================================================

_net_nft_ready() {
    command -v nft >/dev/null 2>&1 || return 1
    if ! nft list table inet oneclick >/dev/null 2>&1; then
        nft add table inet oneclick 2>/dev/null || return 1
    fi
    if ! nft list chain inet oneclick input >/dev/null 2>&1; then
        nft add chain inet oneclick input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || return 1
    fi
    return 0
}

# nat prerouting 链：inet 族的 nat 链需要较新内核，老内核（如 RHEL8）会失败，
# 由调用方回退到 iptables nat，不在这里硬失败。
_net_nft_prerouting_ready() {
    _net_nft_ready || return 1
    if ! nft list chain inet oneclick prerouting >/dev/null 2>&1; then
        nft add chain inet oneclick prerouting '{ type nat hook prerouting priority -100 ; policy accept ; }' 2>/dev/null || return 1
    fi
    return 0
}

_net_nft_list() {
    nft -a list chain inet oneclick "$1" 2>/dev/null
}

# 规则里是否已存在同 proto/port/tag 的规则（避免重复叠加）
_net_nft_has_rule() {
    local chain="$1" proto="$2" port="$3" tag="$4"
    _net_nft_list "$chain" | awk -v proto="$proto" -v port="$port" -v tag="\"$tag\"" '
        index($0, proto " dport " port " ") && index($0, "comment " tag) { f = 1 }
        END { exit !f }'
}

# 把规则文本"proto dport <port>"里命中的 oneclick- 规则 handle 打出来
_net_nft_handles_for_port() {
    local chain="$1" proto="$2" port="$3" tag="${4:-}"
    _net_nft_list "$chain" | awk -v proto="$proto" -v port="$port" -v tag="$tag" '
        {
            if ($0 !~ /# handle [0-9]+$/) next
            if (index($0, "comment \"oneclick-") == 0) next
            if (index($0, proto " dport " port " ") == 0) next
            if (tag != "" && index($0, "comment \"" tag "\"") == 0) next
            print $NF
        }'
}

# 按 tag 精确取 handle（端口跳跃用）
_net_nft_handles_for_tag() {
    local chain="$1" tag="$2"
    _net_nft_list "$chain" | awk -v tag="\"$tag\"" '
        index($0, "comment " tag) && /# handle [0-9]+$/ { print $NF }'
}

_net_nft_del_handles() {
    local chain="$1" h
    shift
    for h in "$@"; do
        [[ "$h" =~ ^[0-9]+$ ]] || continue
        nft delete rule inet oneclick "$chain" handle "$h" 2>/dev/null || true
    done
}

# 让 table inet oneclick 在重启后自动恢复：dump 到 /etc/oneclick，再挂一个 oneshot unit。
# （nft 规则不写盘重启即丢；不能去改系统的 /etc/nftables.conf，避免动别人的规则。）
_net_nft_persist() {
    local dump="$OC_ROOT/nft-oneclick.nft" unit="oneclick-firewall" unitfile
    command -v nft >/dev/null 2>&1 || return 0
    nft list table inet oneclick >/dev/null 2>&1 || return 0
    mkdir -p "$OC_ROOT" 2>/dev/null || return 0
    nft list table inet oneclick > "$dump" 2>/dev/null || return 0
    chmod 600 "$dump" 2>/dev/null || true
    [[ -d /run/systemd/system ]] || return 0
    unitfile="$OC_UNIT_DIR/$unit.service"
    [[ -f "$unitfile" ]] && return 0
    cat > "$unitfile" <<EOF
[Unit]
Description=OneClick firewall restore (nftables table inet oneclick)
ConditionPathExists=$dump
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=-$(command -v nft) delete table inet oneclick
ExecStart=$(command -v nft) -f $dump
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unitfile" 2>/dev/null || true
    os_service_reload
    svc_enable "$unit" || oc_warn "oneclick-firewall 自启注册失败（重启后需重新放行端口）"
    return 0
}

_net_nft_allow() {
    local port="$1" proto="$2" tag="$3"
    _net_nft_ready || return 1
    _net_nft_has_rule input "$proto" "$port" "$tag" && return 0
    nft add rule inet oneclick input "$proto" dport "$port" accept comment "\"$tag\"" 2>/dev/null || return 1
    _net_nft_persist
    return 0
}

_net_nft_deny() {
    local port="$1" proto="$2" tag="${3:-}"
    nft list chain inet oneclick input >/dev/null 2>&1 || return 0
    local -a hs=()
    mapfile -t hs < <(_net_nft_handles_for_port input "$proto" "$port" "$tag")
    [[ ${#hs[@]} -eq 0 ]] && return 0
    _net_nft_del_handles input "${hs[@]}"
    _net_nft_persist
    return 0
}

# ===========================================================================
# 防火墙：iptables / ip6tables 后端（只动带 oneclick- comment 的规则）
# ===========================================================================

_net_ipt_available() {
    command -v "$1" >/dev/null 2>&1 || return 1
    "$1" -S INPUT >/dev/null 2>&1
}

# 列出 INPUT 里命中 port/proto 且 comment 为 oneclick-* 的 tag
_net_ipt_tags() {
    local cmd="$1" port="$2" proto="$3" tag="${4:-}"
    "$cmd" -S INPUT 2>/dev/null | awk -v proto="$proto" -v port="$port" -v tag="$tag" '
        {
            p = ""; d = ""; c = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-p") p = $(i + 1)
                else if ($i == "--dport") d = $(i + 1)
                else if ($i == "--comment") { c = $(i + 1); gsub(/"/, "", c) }
            }
            if (p != proto || d != port) next
            if (c !~ /^oneclick-/) next
            if (tag != "" && c != tag) next
            print c
        }'
}

# iptables 规则不落盘重启即丢：有 netfilter-persistent 就交给它，否则写发行版标准文件
_net_ipt_save() {
    command -v iptables-save >/dev/null 2>&1 || return 0
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
        return 0
    fi
    if [[ -f /etc/sysconfig/iptables ]]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        if command -v ip6tables-save >/dev/null 2>&1 && [[ -f /etc/sysconfig/ip6tables ]]; then
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
        fi
        return 0
    fi
    # 非 root / 无该目录时直接放弃，避免 shell 重定向报错泄漏
    if ! mkdir -p /etc/iptables 2>/dev/null || [[ ! -w /etc/iptables ]]; then
        return 0
    fi
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        chmod 600 /etc/iptables/rules.v6 2>/dev/null || true
    fi
    chmod 600 /etc/iptables/rules.v4 2>/dev/null || true
    return 0
}

# 把当前带 oneclick- comment 的规则固化成可重复执行的脚本，并挂 oneshot 单元开机重放。
# 云主机上 iptables 规则重启即丢；这样即使没装 iptables-persistent，重启后端口也不会失联。
_net_fw_persist() {
    local tmp unit n
    tmp="${OC_FW_FILE}.tmp.$$"
    unit="$OC_UNIT_DIR/${OC_FW_UNIT}.service"
    command -v iptables-save >/dev/null 2>&1 || return 0
    mkdir -p "$OC_ROOT" 2>/dev/null || return 0
    {
        printf '#!/bin/sh\n'
        printf '# generated by oneclick: replay oneclick-* firewall rules at boot\n'
        _net_fw_persist_dump iptables ip6tables
    } >"$tmp" 2>/dev/null || {
        rm -f -- "$tmp"
        return 0
    }
    n=$(($(wc -l <"$tmp") - 2))
    if ((n <= 0)); then
        rm -f -- "$tmp"
        systemctl disable --now "$OC_FW_UNIT" >/dev/null 2>&1 || true
        rm -f -- "$unit"
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 0
    fi
    chmod 700 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$OC_FW_FILE" || return 0
    if [[ ! -f "$unit" ]]; then
        mkdir -p "$OC_UNIT_DIR" 2>/dev/null || return 0
        cat >"$unit" <<EOF
[Unit]
Description=OneClick firewall restore (oneclick-* rules only)
ConditionPathExists=$OC_FW_FILE
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh $OC_FW_FILE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    systemctl enable "$OC_FW_UNIT" >/dev/null 2>&1 || true
    return 0
}

# 只导出 filter/INPUT 与 nat/PREROUTING 里 comment 命中 oneclick- 的规则
_net_fw_persist_dump() {
    local t
    for t in "$@"; do
        command -v "${t}-save" >/dev/null 2>&1 || continue
        "${t}-save" 2>/dev/null | awk -v cmd="$t" '
            /^\*filter$/ { table = "filter"; next }
            /^\*nat$/    { table = "nat"; next }
            /^\*/        { table = ""; next }
            /^COMMIT$/    { table = ""; next }
            table == "filter" && $1 == "-A" && $2 == "INPUT" {
                spec = $0
                sub(/^-A INPUT /, "", spec)
                if (spec ~ /oneclick-/) {
                    printf "%s -C INPUT %s >/dev/null 2>&1 || %s -A INPUT %s\n", cmd, spec, cmd, spec
                }
                next
            }
            table == "nat" && $1 == "-A" && $2 == "PREROUTING" {
                spec = $0
                sub(/^-A PREROUTING /, "", spec)
                if (spec ~ /oneclick-/) {
                    printf "%s -t nat -C PREROUTING %s >/dev/null 2>&1 || %s -t nat -A PREROUTING %s\n", cmd, spec, cmd, spec
                }
                next
            }
        '
    done
}

_net_ipt_allow() {
    local port="$1" proto="$2" tag="$3" t changed=0 ok=0
    for t in iptables ip6tables; do
        _net_ipt_available "$t" || continue
        # 已存在就跳过，重复安装不叠加规则
        if "$t" -C INPUT -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null; then
            ok=1
        elif "$t" -I INPUT 1 -p "$proto" --dport "$port" -m comment --comment "$tag" -j ACCEPT 2>/dev/null; then
            ok=1
            changed=1
        fi
    done
    if ((changed)); then
        _net_ipt_save
    fi
    ((ok)) || return 1
    return 0
}

_net_ipt_deny() {
    local port="$1" proto="$2" tag="${3:-}" t c changed=0
    for t in iptables ip6tables; do
        _net_ipt_available "$t" || continue
        while IFS= read -r c; do
            [[ -n "$c" ]] || continue
            # 删除前先 -C 确认，只删自己 comment 的规则
            "$t" -C INPUT -p "$proto" --dport "$port" -m comment --comment "$c" -j ACCEPT 2>/dev/null || continue
            if "$t" -D INPUT -p "$proto" --dport "$port" -m comment --comment "$c" -j ACCEPT 2>/dev/null; then
                changed=1
            fi
        done < <(_net_ipt_tags "$t" "$port" "$proto" "$tag")
    done
    if ((changed)); then
        _net_ipt_save
    fi
    return 0
}

# ===========================================================================
# 防火墙：firewalld / ufw 后端
# ===========================================================================

_net_firewalld_allow() {
    local port="$1" proto="$2"
    _net_firewalld_active || return 1
    firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1 || return 1
    if ! firewall-cmd --add-port="$port/$proto" >/dev/null 2>&1; then
        # 运行时区可能已存在/失效，reload 让 permanent 生效
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    # 复核：permanent 写了不等于运行区放行
    if ! firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1; then
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1
}

_net_firewalld_deny() {
    local port="$1" proto="$2"
    _net_firewalld_active || return 0
    firewall-cmd --query-port="$port/$proto" >/dev/null 2>&1 \
        && firewall-cmd --remove-port="$port/$proto" >/dev/null 2>&1
    firewall-cmd --permanent --query-port="$port/$proto" >/dev/null 2>&1 \
        && firewall-cmd --permanent --remove-port="$port/$proto" >/dev/null 2>&1
    return 0
}

_net_ufw_allow() {
    local port="$1" proto="$2" tag="$3"
    command -v ufw >/dev/null 2>&1 || return 1
    if ufw allow "$port/$proto" comment "$tag" >/dev/null 2>&1; then
        return 0
    fi
    # 老版本 ufw 不认 comment：退化成纯端口规则（后续 deny 会按端口兜底）
    ufw allow "$port/$proto" >/dev/null 2>&1
}

_net_ufw_deny() {
    local port="$1" proto="$2" tag="${3:-}" line c
    command -v ufw >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        c="$(printf '%s' "$line" | sed -n "s/.*comment '\([^']*\)'.*/\1/p")"
        if [[ -z "$c" ]]; then
            c="$(printf '%s' "$line" | sed -n "s/.*'\(oneclick-[^']*\)'.*/\1/p")"
        fi
        if [[ -z "$c" ]]; then
            c="$(printf '%s' "$line" | tr ' ' '\n' | grep -m1 '^oneclick-')"
        fi
        [[ -n "$c" ]] || continue
        [[ "$c" == oneclick-* ]] || continue
        if [[ -n "$tag" && "$c" != "$tag" ]]; then
            continue
        fi
        ufw --force delete allow "$port/$proto" comment "$c" >/dev/null 2>&1 \
            || oc_warn "未能删除 ufw 规则：${port}/${proto}（comment ${c}）"
    done < <(ufw show added 2>/dev/null | grep -F "allow $port/$proto")
    return 0
}

# ===========================================================================
# 防火墙：对外 API
# ===========================================================================

# net_fw_allow <port> <tcp|udp> [comment]
net_fw_allow() {
    local port proto tag backend rc=0
    port="$(_net_port_num "${1:-}")" || { oc_err "net_fw_allow: 端口非法：${1:-<空>}"; return 1; }
    proto="${2:-tcp}"
    tag="${3:-}"
    case "$proto" in
        tcp|udp) ;;
        *) oc_err "net_fw_allow: 协议应为 tcp|udp：$proto"; return 1 ;;
    esac
    if [[ -z "$tag" ]]; then
        # 默认 oneclick-<调用者>，只保留安全字符（iptables comment 上限 256）
        tag="oneclick-${FUNCNAME[1]:-user}"
        tag="${tag//[^A-Za-z0-9_.-]/-}"
        tag="${tag:0:64}"
    fi
    backend="$(net_fw_backend)"
    case "$backend" in
        iptables)
            _net_ipt_allow "$port" "$proto" "$tag" || rc=1
            ;;
        firewalld)
            _net_firewalld_allow "$port" "$proto" || rc=1
            ;;
        ufw)
            _net_ufw_allow "$port" "$proto" "$tag" || rc=1
            ;;
        nft)
            _net_nft_allow "$port" "$proto" "$tag" || rc=1
            # 独立的 inet oneclick 表不能覆盖 firewalld/ufw 自己的 DROP 链，
            # 所以活跃的管理器必须同步放行，否则装了也连不上。
            if _net_firewalld_active; then
                _net_firewalld_allow "$port" "$proto" || rc=1
            fi
            if _net_ufw_active; then
                _net_ufw_allow "$port" "$proto" "$tag" || rc=1
            fi
            ;;
        *)
            oc_warn "未检测到可用防火墙，跳过放行 ${port}/${proto}；请在云安全组放行"
            return 0
            ;;
    esac
    if ((rc == 0)); then
        oc_ok "已放行 ${port}/${proto}（${backend}）"
    else
        oc_err "放行 ${port}/${proto} 失败（${backend}）"
    fi
    _net_fw_persist
    return "$rc"
}

# net_fw_deny <port> <tcp|udp> [comment]：撤销放行，只删 oneclick-* 规则
net_fw_deny() {
    local port proto tag any=0 rc=0
    port="$(_net_port_num "${1:-}")" || { oc_err "net_fw_deny: 端口非法：${1:-<空>}"; return 1; }
    proto="${2:-tcp}"
    tag="${3:-}"
    case "$proto" in
        tcp|udp) ;;
        *) oc_err "net_fw_deny: 协议应为 tcp|udp：$proto"; return 1 ;;
    esac
    # 后端可能在安装后被换掉（比如后来装了 nftables），所以所有存在的后端都尝试一遍；
    # 每个删除路径都只匹配 oneclick- comment 或精确端口，不会误删别人的规则。
    if command -v nft >/dev/null 2>&1 && nft list table inet oneclick >/dev/null 2>&1; then
        _net_nft_deny "$port" "$proto" "$tag" || rc=1
        any=1
    fi
    if _net_firewalld_active; then
        _net_firewalld_deny "$port" "$proto" || rc=1
        any=1
    fi
    if command -v ufw >/dev/null 2>&1; then
        _net_ufw_deny "$port" "$proto" "$tag" || rc=1
        any=1
    fi
    if command -v iptables >/dev/null 2>&1; then
        _net_ipt_deny "$port" "$proto" "$tag" || rc=1
        any=1
    fi
    if ((any == 0)); then
        oc_warn "未检测到防火墙，无需撤销 ${port}/${proto}"
        return 0
    fi
    if ((rc == 0)); then
        oc_ok "已撤销 ${port}/${proto} 的放行规则"
    fi
    _net_fw_persist
    return "$rc"
}

# net_fw_status：打印后端 + 各管理器里属于 oneclick 的规则数量
net_fw_status() {
    local backend n
    backend="$(net_fw_backend)"
    oc_kv "防火墙后端" "$backend"
    if command -v nft >/dev/null 2>&1 && nft list table inet oneclick >/dev/null 2>&1; then
        n="$(nft -a list table inet oneclick 2>/dev/null | grep -c 'comment "oneclick-' || true)"
        oc_kv "nft(inet oneclick) 规则" "${n:-0}"
    fi
    if _net_ipt_available iptables; then
        n="$(iptables -S INPUT 2>/dev/null | grep -cE 'comment "?oneclick-' || true)"
        oc_kv "iptables(oneclick-) 规则" "${n:-0}"
    fi
    if _net_firewalld_active; then
        oc_kv "firewalld 放行端口" "$(firewall-cmd --list-ports 2>/dev/null || true)"
    fi
    if command -v ufw >/dev/null 2>&1 && _net_ufw_active; then
        n="$(ufw show added 2>/dev/null | grep -cE "comment 'oneclick-" || true)"
        oc_kv "ufw(oneclick-) 规则" "${n:-0}"
    fi
    return 0
}

# ===========================================================================
# UDP 端口跳跃：PREROUTING DNAT 到本机目标端口，comment oneclick-hop-<key>
# ===========================================================================

_net_hop_key() {
    local k="$1"
    [[ "$k" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || return 1
    printf '%s' "$k"
}

_net_hop_ipt_rules() {
    local cmd="$1" tag="$2"
    "$cmd" -t nat -S PREROUTING 2>/dev/null | awk -v tag="$tag" '
        {
            c = ""; p = ""; d = ""; to = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-p") p = $(i + 1)
                else if ($i == "--dport") d = $(i + 1)
                else if ($i == "--to-destination") to = $(i + 1)
                else if ($i == "--comment") { c = $(i + 1); gsub(/"/, "", c) }
            }
            if (c == tag && p == "udp" && d != "" && to != "") print d, to
        }'
}

_net_hop_ipt_add() {
    local start="$1" end="$2" target="$3" tag="$4" t added=0 verified=0
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -t nat -S PREROUTING >/dev/null 2>&1 || continue
        # 已存在就不再加，避免重复叠加
        if ! "$t" -t nat -C PREROUTING -p udp --dport "$start:$end" -m comment --comment "$tag" \
                -j DNAT --to-destination ":$target" 2>/dev/null; then
            if "$t" -t nat -A PREROUTING -p udp --dport "$start:$end" -m comment --comment "$tag" \
                    -j DNAT --to-destination ":$target" 2>/dev/null; then
                added=1
            fi
        fi
        if "$t" -t nat -C PREROUTING -p udp --dport "$start:$end" -m comment --comment "$tag" \
                -j DNAT --to-destination ":$target" 2>/dev/null; then
            verified=1
        fi
    done
    if ((added)); then
        _net_ipt_save
    fi
    ((verified))
}

_net_hop_ipt_del() {
    local tag="$1" t d to changed=0
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        while read -r d to; do
            [[ -n "$d" && -n "$to" ]] || continue
            if "$t" -t nat -D PREROUTING -p udp --dport "$d" -m comment --comment "$tag" \
                    -j DNAT --to-destination "$to" 2>/dev/null; then
                changed=1
            fi
        done < <(_net_hop_ipt_rules "$t" "$tag")
    done
    if ((changed)); then
        _net_ipt_save
    fi
    return 0
}

_net_hop_ipt_show() {
    local tag="$1" t d to
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        while read -r d to; do
            [[ -n "$d" && -n "$to" ]] || continue
            printf '  %s: UDP %s → 本机%s\n' "$t" "$d" "$to"
        done < <(_net_hop_ipt_rules "$t" "$tag")
    done
}

_net_hop_nft_add() {
    local start="$1" end="$2" target="$3" tag="$4"
    _net_nft_prerouting_ready || return 1
    _net_nft_has_rule prerouting udp "$start-$end" "$tag" && return 0
    # redirect to :port 等价于"改端口 + 落到本机"，正是本地端口跳跃需要的
    nft add rule inet oneclick prerouting udp dport "$start-$end" redirect to ":$target" comment "\"$tag\"" 2>/dev/null || return 1
    _net_nft_persist
    return 0
}

_net_hop_nft_del() {
    local tag="$1"
    local -a hs=()
    nft list chain inet oneclick prerouting >/dev/null 2>&1 || return 0
    mapfile -t hs < <(_net_nft_handles_for_tag prerouting "$tag")
    [[ ${#hs[@]} -eq 0 ]] && return 0
    _net_nft_del_handles prerouting "${hs[@]}"
    _net_nft_persist
    return 0
}

_net_hop_nft_show() {
    local tag="$1"
    nft -a list chain inet oneclick prerouting 2>/dev/null | awk -v tag="\"$tag\"" '
        index($0, "comment " tag) { gsub(/^[ \t]+/, ""); print "  nft: " $0 }'
}

# 汇总两种后端里该 tag 的规则（判残留 / 展示用）
_net_hop_all() {
    local tag="$1"
    _net_hop_ipt_show "$tag"
    _net_hop_nft_show "$tag"
}

# net_nat_hop_add <key> <port_start> <port_end> <target_port>
net_nat_hop_add() {
    local key start end target tag
    key="$(_net_hop_key "${1:-}")" || { oc_err "net_nat_hop_add: key 非法（仅限字母数字_-）"; return 1; }
    start="$(_net_port_num "${2:-}")" || { oc_err "net_nat_hop_add: 起始端口非法"; return 1; }
    end="$(_net_port_num "${3:-}")" || { oc_err "net_nat_hop_add: 结束端口非法"; return 1; }
    target="$(_net_port_num "${4:-}")" || { oc_err "net_nat_hop_add: 目标端口非法"; return 1; }
    if ((start > end)); then
        oc_err "net_nat_hop_add: 端口范围非法（$start > $end）"
        return 1
    fi
    tag="oneclick-hop-$key"
    # nat 表与 input 防火墙后端无关：优先 iptables（兼容性最好），失败再试 nft。
    # 老内核没有 inet 族 nat 链，所以不能只依赖 nft。
    local ok=0
    if command -v iptables >/dev/null 2>&1 && iptables -t nat -S PREROUTING >/dev/null 2>&1; then
        if _net_hop_ipt_add "$start" "$end" "$target" "$tag"; then
            ok=1
        fi
    fi
    if ((ok == 0)); then
        if _net_hop_nft_add "$start" "$end" "$target" "$tag"; then
            ok=1
        fi
    fi
    if ((ok == 0)); then
        oc_err "net_nat_hop_add: iptables 与 nftables 均不可用，无法配置端口跳跃"
        return 1
    fi
    oc_ok "端口跳跃：UDP ${start}-${end} → ${target}（${tag}）"
    _net_fw_persist
    return 0
}

# net_nat_hop_del <key>：按 comment 精确删除，绝不碰别人的规则
net_nat_hop_del() {
    local key tag left
    key="$(_net_hop_key "${1:-}")" || { oc_err "net_nat_hop_del: key 非法（仅限字母数字_-）"; return 1; }
    tag="oneclick-hop-$key"
    _net_hop_ipt_del "$tag"
    _net_hop_nft_del "$tag"
    left="$(_net_hop_all "$tag")"
    if [[ -n "$left" ]]; then
        oc_warn "仍有端口跳跃规则残留（${tag}），请手动检查："
        printf '%s\n' "$left"
        return 1
    fi
    oc_ok "端口跳跃规则已清理（${tag}）"
    _net_fw_persist
    return 0
}

# net_nat_hop_show <key>
net_nat_hop_show() {
    local key tag out
    key="$(_net_hop_key "${1:-}")" || { oc_err "net_nat_hop_show: key 非法（仅限字母数字_-）"; return 1; }
    tag="oneclick-hop-$key"
    out="$(_net_hop_all "$tag")"
    if [[ -z "$out" ]]; then
        oc_info "无端口跳跃规则（${tag}）"
        return 0
    fi
    oc_title "端口跳跃 ${tag}"
    printf '%s\n' "$out"
    return 0
}
