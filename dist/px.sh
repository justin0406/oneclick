#!/usr/bin/env bash
# =============================================================================
# PX —— 综合一键代理脚本（P0）
# 融合自：hysteria-install(hy2) / Snell.sh / Shadowsocks-Rust / jinqians menu / surge
# 定位：单用户轻量自用，Debian/Ubuntu 优先，CentOS 兼容
# 授权：各上游未声明 LICENSE，本脚本按"自用 fork"处理，保留上游署名与来源说明
# =============================================================================

umask 077

PX_VERSION="0.1.0"
PX_ROOT="${PX_ROOT:-/etc/px}"
PX_DB="${PX_DB:-$PX_ROOT/db.json}"
PX_CERT_DIR="$PX_ROOT/certs"
PX_SUB_DIR="$PX_ROOT/sub"
PX_LOG_DIR="${PX_LOG_DIR:-/var/log/px}"
PX_BIN_DIR="${PX_BIN_DIR:-/usr/local/bin}"
PX_ENTRY="$PX_BIN_DIR/px"
PX_UNIT_DIR="${PX_UNIT_DIR:-/etc/systemd/system}"

PX_OS_ID=""
PX_OS_VER=""
PX_ARCH=""
PX_YES="${PX_YES:-0}"
PX_GH_PROXY="${PX_GH_PROXY:-}"

PX_ARG_PORT=""
PX_ARG_DOMAIN=""
PX_ARG_SNI=""
PX_ARG_CERT_MODE=""
PX_ARG_FORMAT=""
PX_CLI_ACTION=""
PX_CLI_KEY=""

# 协议注册表：key 用下划线（函数名可用），展示名与 unit 用连字符
PX_PROTOS=(vless_reality hysteria2 snell ss_rust anytls)

declare -gA PX_PROTO_TITLE=(
    [vless_reality]="VLESS-Reality"
    [hysteria2]="Hysteria2"
    [snell]="Snell v6"
    [ss_rust]="SS-Rust"
    [anytls]="AnyTLS"
)
declare -gA PX_PROTO_ORDER=(
    [vless_reality]=10
    [hysteria2]=20
    [snell]=30
    [ss_rust]=40
    [anytls]=50
)

# 协议 key -> unit 名：vless_reality -> px-vless-reality
px_unit_name() { printf 'px-%s' "${1//_/-}"; }
# 协议 key -> 配置目录：/etc/px/vless_reality
px_proto_dir() { printf '%s/%s' "$PX_ROOT" "$1"; }

# ===== src/lib/os.sh =====
# lib/os.sh —— 系统识别、包管理、随机数、通用小工具

os_detect() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        PX_OS_ID="${ID:-unknown}"
        PX_OS_VER="${VERSION_ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        PX_OS_ID="centos"; PX_OS_VER="unknown"
    else
        PX_OS_ID="unknown"; PX_OS_VER="unknown"
    fi
    case "$(uname -m)" in
        x86_64|amd64)   PX_ARCH="amd64" ;;
        aarch64|arm64)  PX_ARCH="arm64" ;;
        armv7l|armv7*)  PX_ARCH="armv7l" ;;
        i386|i686)      PX_ARCH="i386" ;;
        *)              PX_ARCH="$(uname -m)" ;;
    esac
}

os_family() {
    case "$PX_OS_ID" in
        debian|ubuntu|armbian|raspbian|linuxmint|pop) printf 'debian' ;;
        centos|rhel|rocky|almalinux|fedora|ol)        printf 'rhel' ;;
        *)                                            printf 'unknown' ;;
    esac
}

os_pkg_has() {
    case "$(os_family)" in
        debian) dpkg -s "$1" >/dev/null 2>&1 ;;
        rhel)   rpm -q "$1" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

os_pkg_install() {
    local -a pkgs=() need=() p
    for p in "$@"; do
        os_pkg_has "$p" && continue
        need+=("$p")
    done
    [[ ${#need[@]} -eq 0 ]] && return 0
    px_info "安装系统依赖：${need[*]}"
    case "$(os_family)" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || px_warn "apt-get update 失败，继续尝试安装"
            if ! apt-get install -y -qq "${need[@]}" >/dev/null 2>&1; then
                px_err "依赖安装失败：${need[*]}"
                return 1
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q "${need[@]}" >/dev/null 2>&1 || { px_err "dnf 安装失败"; return 1; }
            else
                yum install -y -q "${need[@]}" >/dev/null 2>&1 || { px_err "yum 安装失败"; return 1; }
            fi
            ;;
        *)
            px_err "不支持的发行版：$PX_OS_ID，请手动安装：${need[*]}"
            return 1
            ;;
    esac
    return 0
}

# os_dep_install <feature...>；feature: base qr cert acme
os_dep_install() {
    local -a want=() f
    for f in "$@"; do
        case "$f" in
            base) want+=(curl tar jq openssl ca-certificates unzip iproute2) ;;
            qr)   want+=(qrencode) ;;
            cert) want+=(openssl) ;;
            acme) want+=(socat cron) ;;
            *)    px_warn "未知依赖项：$f" ;;
        esac
    done
    [ ${#want[@]} -eq 0 ] && return 0
    os_pkg_install "${want[@]}"
}

os_service_reload() { systemctl daemon-reload >/dev/null 2>&1 || true; }

os_random_token() {
    local len="${1:-16}" out=""
    out="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom 2>/dev/null | head -c "$len" || true)"
    # tr 在某些环境被 SIGPIPE 提前终止，兜底用 openssl
    if [[ ${#out} -lt $len ]]; then
        out="$(openssl rand -base64 $((len * 2)) 2>/dev/null | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c "$len" || true)"
    fi
    printf '%s' "$out"
}

os_random_hex() {
    openssl rand -hex "${1:-16}" 2>/dev/null || od -An -tx1 -N "${1:-16}" /dev/urandom | tr -d ' \n'
}

os_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

os_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

px_require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || px_die "请用 root 运行（sudo -i 后重试）"
}

px_require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || px_die "缺少命令：$c"
    done
}

# ===== src/lib/ui.sh =====
# lib/ui.sh —— 颜色、日志、交互、菜单

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
    C_C=$'\033[36m'; C_M=$'\033[35m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_BOLD=""; C_DIM=""; C_N=""
fi

px_info() { printf '%b[*]%b %s\n' "$C_C" "$C_N" "$*"; }
px_ok()   { printf '%b[✓]%b %s\n' "$C_G" "$C_N" "$*"; }
px_warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*" >&2; }
px_err()  { printf '%b[✗]%b %s\n' "$C_R" "$C_N" "$*" >&2; }
px_die()  { px_err "$1"; exit "${2:-1}"; }

px_hr() { printf '%b%s%b\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_N"; }

px_title() {
    printf '\n%b%s%b\n' "$C_BOLD$C_C" "== $* ==" "$C_N"
}

px_kv() {
    printf '  %b%-24s%b %s\n' "$C_DIM" "$1" "$C_N" "$2"
}

# 确认：PX_YES=1 时直接按默认值返回
px_confirm() {
    local prompt="$1" def="${2:-y}" ans
    if [[ "$PX_YES" == "1" ]]; then
        [[ "$def" == "y" ]] && return 0 || return 1
    fi
    local hint="[Y/n]"
    [[ "$def" == "n" ]] && hint="[y/N]"
    while true; do
        printf '%b%s%b %s ' "$C_Y" "$prompt" "$C_N" "$hint" >&2
        if ! read -r ans; then return 1; fi
        ans="${ans//[[:space:]]/}"
        ans="${ans:-$def}"
        case "${ans,,}" in
            y|yes|是) return 0 ;;
            n|no|否)  return 1 ;;
            *) px_warn "请输入 y 或 n" ;;
        esac
    done
}

# 提问：stdout 输出答案（空则默认值）
px_ask() {
    local prompt="$1" def="${2:-}" ans
    if [[ "$PX_YES" == "1" && -n "$def" ]]; then
        printf '%s' "$def"
        return 0
    fi
    if [[ -n "$def" ]]; then
        printf '%b%s%b [%s]: ' "$C_Y" "$prompt" "$C_N" "$def" >&2
    else
        printf '%b%s%b: ' "$C_Y" "$prompt" "$C_N" >&2
    fi
    read -r ans || ans=""
    printf '%s' "${ans:-$def}"
}

# 不回显提问
px_ask_secret() {
    local prompt="$1" ans
    printf '%b%s%b: ' "$C_Y" "$prompt" "$C_N" >&2
    read -rs ans || ans=""
    printf '\n' >&2
    printf '%s' "$ans"
}

# 菜单：stdout 输出编号（0 = 返回）
px_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local i sel
    printf '\n%b%s%b\n' "$C_BOLD" "$title" "$C_N" >&2
    for i in "${!items[@]}"; do
        printf '  %b%2d%b) %s\n' "$C_C" "$((i + 1))" "$C_N" "${items[$i]}" >&2
    done
    printf '  %b%2d%b) %s\n' "$C_C" 0 "$C_N" "返回" >&2
    while true; do
        printf '%b请选择 [0-%d]: %b' "$C_Y" "${#items[@]}" "$C_N" >&2
        if ! read -r sel; then return 1; fi
        sel="${sel//[[:space:]]/}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 0 && sel <= ${#items[@]})); then
            printf '%s' "$sel"
            return 0
        fi
        px_warn "输入无效，请重新选择"
    done
}

px_pause() {
    [[ "$PX_YES" == "1" ]] && return 0
    printf '%b按回车继续...%b' "$C_DIM" "$C_N"
    read -r _ || true
}

# ===== src/lib/store.sh =====
# lib/store.sh —— 状态库 /etc/px/db.json（jq + flock，原子写）

db_init() {
    # 派生目录随 PX_ROOT 重算，便于测试时改根目录
    PX_CERT_DIR="$PX_ROOT/certs"
    PX_SUB_DIR="$PX_ROOT/sub"
    mkdir -p "$PX_ROOT" "$PX_CERT_DIR" "$PX_SUB_DIR" "$PX_LOG_DIR"
    chmod 700 "$PX_ROOT"
    if [[ ! -f "$PX_DB" ]]; then
        printf '{"installed":[],"settings":{}}\n' > "$PX_DB"
    fi
    chmod 600 "$PX_DB"
}

# 内部：原子应用一个 jq 过滤器。$1=过滤器，其余为 jq 参数（--arg 等）
_db_apply() {
    local filter="$1"; shift
    db_init
    local lockfd="" tmp
    if command -v flock >/dev/null 2>&1; then
        exec {lockfd}>"$PX_ROOT/.db.lock"
        flock "$lockfd"
    fi
    tmp="$(mktemp "$PX_ROOT/.db.XXXXXX")" || { _db_unlock "$lockfd"; return 1; }
    if jq "$@" "$filter" "$PX_DB" > "$tmp" 2>/dev/null; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$PX_DB"
        _db_unlock "$lockfd"
        return 0
    fi
    rm -f "$tmp"
    _db_unlock "$lockfd"
    px_err "状态库写入失败（db.json 格式异常？）"
    return 1
}

_db_unlock() {
    local fd="$1"
    [[ -n "$fd" ]] || return 0
    flock -u "$fd" 2>/dev/null || true
    exec {fd}>&- 2>/dev/null || true
}

db_get() {
    local sec="$1" key="$2" def="${3:-}" out
    [[ -f "$PX_DB" ]] || { printf '%s' "$def"; return 0; }
    out="$(jq -r --arg s "$sec" --arg k "$key" \
        'if .[$s][$k] == null then empty else (.[$s][$k] | tostring) end' "$PX_DB" 2>/dev/null)"
    printf '%s\n' "${out:-$def}"
}

db_set() {
    _db_apply '.[$s][$k] = $v' --arg s "$1" --arg k "$2" --arg v "$3"
}

db_setn() {
    _db_apply '.[$s][$k] = $v' --arg s "$1" --arg k "$2" --argjson v "$3"
}

db_del() {
    local sec="$1" key="${2:-}"
    if [[ -n "$key" ]]; then
        _db_apply 'del(.[$s][$k])' --arg s "$sec" --arg k "$key"
    else
        _db_apply 'del(.[$s])' --arg s "$sec"
    fi
}

db_has() {
    local sec="$1" key="${2:-}"
    [[ -f "$PX_DB" ]] || return 1
    if [[ -n "$key" ]]; then
        [[ "$(jq -r --arg s "$sec" --arg k "$key" '.[$s][$k] != null' "$PX_DB" 2>/dev/null)" == "true" ]]
    else
        jq -e --arg s "$sec" 'has($s)' "$PX_DB" >/dev/null 2>&1
    fi
}

db_section_json() {
    local sec="$1"
    [[ -f "$PX_DB" ]] || { printf '{}'; return 0; }
    jq -c --arg s "$sec" '.[$s] // {}' "$PX_DB" 2>/dev/null || printf '{}'
}

db_is_installed() {
    [[ -f "$PX_DB" ]] || return 1
    [[ "$(jq -r --arg k "$1" '(.installed // []) | index($k) != null' "$PX_DB" 2>/dev/null)" == "true" ]]
}

db_mark_installed() {
    _db_apply '.installed = (((.installed // []) + [$k]) | unique)' --arg k "$1"
}

db_unmark_installed() {
    _db_apply '.installed = ((.installed // []) - [$k])' --arg k "$1"
}

# settings：db_setting <key> [value]；无 value 为读取
db_setting() {
    local key="$1" val="${2:-}"
    if [[ $# -ge 2 ]]; then
        _db_apply '.settings = ((.settings // {}) | .[$k] = $v)' --arg k "$key" --arg v "$val"
    else
        db_get settings "$key" ""
    fi
}

# ===== src/lib/dl.sh =====
# lib/dl.sh —— 统一下载器（镜像前缀 + SHA256 + 重试 + 原子替换）

# 是否 GitHub 直连域名（只有这些走镜像）
_dl_is_gh() {
    case "$1" in
        *github.com*|*githubusercontent.com*|*githubassets.com*) return 0 ;;
        *) return 1 ;;
    esac
}

dl_mirror_url() {
    local url="$1" prefix=""
    prefix="${PX_GH_PROXY:-}"
    if [[ -z "$prefix" ]]; then
        prefix="$(db_get settings gh_proxy "")"
    fi
    [[ -z "$prefix" ]] && { printf '%s' "$url"; return 0; }
    _dl_is_gh "$url" || { printf '%s' "$url"; return 0; }
    printf '%s/%s' "${prefix%/}" "$url"
}

# dl_fetch <url> <out> [sha256]
dl_fetch() {
    local url="$1" out="$2" sha="${3:-}"
    local -a urls=("$url")
    local m tmp src attempt ok=0
    m="$(dl_mirror_url "$url")"
    [[ "$m" != "$url" ]] && urls+=("$m")
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    tmp="${out}.part.$$"
    for src in "${urls[@]}"; do
        for attempt in 1 2 3; do
            if curl -fL --connect-timeout 10 --max-time 900 --retry 1 -o "$tmp" "$src" >/dev/null 2>&1; then
                ok=1; break 2
            fi
            rm -f "$tmp"; sleep 1
        done
    done
    if ((ok == 0)); then
        rm -f "$tmp"
        px_err "下载失败：$url"
        return 1
    fi
    if [[ -n "$sha" ]]; then
        local got
        got="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
        if [[ "${got,,}" != "${sha,,}" ]]; then
            rm -f "$tmp"
            px_err "SHA256 校验失败：$(basename "$out")"
            return 1
        fi
    fi
    mv -f "$tmp" "$out"
}

# dl_latest_tag <owner/repo> -> 输出 Release tag 原样（通常带 v，失败输出空）
# 需要不带 v 的纯版本号用 dl_latest_ver
dl_latest_tag() {
    local repo="$1" api tag prefix
    api="https://api.github.com/repos/$repo/releases/latest"
    prefix="${PX_GH_PROXY:-$(db_get settings gh_proxy "")}"
    tag="$(curl -fsSL --connect-timeout 10 --max-time 30 "$api" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    if [[ -z "$tag" && -n "$prefix" ]]; then
        tag="$(curl -fsSL --connect-timeout 10 --max-time 30 "${prefix%/}/$api" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null)"
    fi
    printf '%s' "$tag"
}

# dl_latest_ver <owner/repo> -> 输出去 v 的版本号（失败输出空）
dl_latest_ver() {
    local t
    t="$(dl_latest_tag "$1")"
    printf '%s' "${t#v}"
}

# dl_gh <owner/repo> <tag|latest> <asset> <out>
dl_gh() {
    local repo="$1" tag="$2" asset="$3" out="$4"
    if [[ "$tag" == "latest" ]]; then
        tag="$(dl_latest_tag "$repo")"
        [[ -z "$tag" ]] && { px_err "无法获取 $repo 最新版本号（网络或 API 限流）"; return 1; }
    fi
    dl_fetch "https://github.com/$repo/releases/download/$tag/$asset" "$out"
}

# 解压 zip：dl_unzip <zip> <destdir>
dl_unzip() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"
    if ! command -v unzip >/dev/null 2>&1; then
        os_pkg_install unzip || return 1
    fi
    unzip -o -q "$zip" -d "$dest"
}

# 解压 tar.*：dl_untar <tar> <destdir>
dl_untar() {
    local tar="$1" dest="$2"
    mkdir -p "$dest"
    tar -xf "$tar" -C "$dest"
}

# ===== src/lib/net.sh =====
# lib/net.sh —— 公网 IP / 端口占用 / 防火墙四后端 / BBR+TFO / UDP 端口跳跃
#
# 防火墙纪律（SPEC §6）：只增删本脚本自己的规则，绝不清表、绝不碰别人的规则。
#   * nft      —— 独立 table `inet px`，每条规则带 comment "px-*"
#   * iptables —— `-m comment --comment "px-*"`，删除前先 -C 确认存在
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
        px_warn "缺少 curl，无法探测公网 IP"
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
# 防火墙：nft 后端（独立 table inet px）
# ===========================================================================

_net_nft_ready() {
    command -v nft >/dev/null 2>&1 || return 1
    if ! nft list table inet px >/dev/null 2>&1; then
        nft add table inet px 2>/dev/null || return 1
    fi
    if ! nft list chain inet px input >/dev/null 2>&1; then
        nft add chain inet px input '{ type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || return 1
    fi
    return 0
}

# nat prerouting 链：inet 族的 nat 链需要较新内核，老内核（如 RHEL8）会失败，
# 由调用方回退到 iptables nat，不在这里硬失败。
_net_nft_prerouting_ready() {
    _net_nft_ready || return 1
    if ! nft list chain inet px prerouting >/dev/null 2>&1; then
        nft add chain inet px prerouting '{ type nat hook prerouting priority -100 ; policy accept ; }' 2>/dev/null || return 1
    fi
    return 0
}

_net_nft_list() {
    nft -a list chain inet px "$1" 2>/dev/null
}

# 规则里是否已存在同 proto/port/tag 的规则（避免重复叠加）
_net_nft_has_rule() {
    local chain="$1" proto="$2" port="$3" tag="$4"
    _net_nft_list "$chain" | awk -v proto="$proto" -v port="$port" -v tag="\"$tag\"" '
        index($0, proto " dport " port " ") && index($0, "comment " tag) { f = 1 }
        END { exit !f }'
}

# 把规则文本"proto dport <port>"里命中的 px- 规则 handle 打出来
_net_nft_handles_for_port() {
    local chain="$1" proto="$2" port="$3" tag="${4:-}"
    _net_nft_list "$chain" | awk -v proto="$proto" -v port="$port" -v tag="$tag" '
        {
            if ($0 !~ /# handle [0-9]+$/) next
            if (index($0, "comment \"px-") == 0) next
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
        nft delete rule inet px "$chain" handle "$h" 2>/dev/null || true
    done
}

# 让 table inet px 在重启后自动恢复：dump 到 /etc/px，再挂一个 oneshot unit。
# （nft 规则不写盘重启即丢；不能去改系统的 /etc/nftables.conf，避免动别人的规则。）
_net_nft_persist() {
    local dump="$PX_ROOT/nft-px.nft" unit="px-firewall" unitfile
    command -v nft >/dev/null 2>&1 || return 0
    nft list table inet px >/dev/null 2>&1 || return 0
    mkdir -p "$PX_ROOT" 2>/dev/null || return 0
    nft list table inet px > "$dump" 2>/dev/null || return 0
    chmod 600 "$dump" 2>/dev/null || true
    [[ -d /run/systemd/system ]] || return 0
    unitfile="$PX_UNIT_DIR/$unit.service"
    [[ -f "$unitfile" ]] && return 0
    cat > "$unitfile" <<EOF
[Unit]
Description=PX firewall restore (nftables table inet px)
ConditionPathExists=$dump
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=-$(command -v nft) delete table inet px
ExecStart=$(command -v nft) -f $dump
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unitfile" 2>/dev/null || true
    os_service_reload
    svc_enable "$unit" || px_warn "px-firewall 自启注册失败（重启后需重新放行端口）"
    return 0
}

_net_nft_allow() {
    local port="$1" proto="$2" tag="$3"
    _net_nft_ready || return 1
    _net_nft_has_rule input "$proto" "$port" "$tag" && return 0
    nft add rule inet px input "$proto" dport "$port" accept comment "\"$tag\"" 2>/dev/null || return 1
    _net_nft_persist
    return 0
}

_net_nft_deny() {
    local port="$1" proto="$2" tag="${3:-}"
    nft list chain inet px input >/dev/null 2>&1 || return 0
    local -a hs=()
    mapfile -t hs < <(_net_nft_handles_for_port input "$proto" "$port" "$tag")
    [[ ${#hs[@]} -eq 0 ]] && return 0
    _net_nft_del_handles input "${hs[@]}"
    _net_nft_persist
    return 0
}

# ===========================================================================
# 防火墙：iptables / ip6tables 后端（只动带 px- comment 的规则）
# ===========================================================================

_net_ipt_available() {
    command -v "$1" >/dev/null 2>&1 || return 1
    "$1" -S INPUT >/dev/null 2>&1
}

# 列出 INPUT 里命中 port/proto 且 comment 为 px-* 的 tag
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
            if (c !~ /^px-/) next
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
            c="$(printf '%s' "$line" | sed -n "s/.*'\(px-[^']*\)'.*/\1/p")"
        fi
        if [[ -z "$c" ]]; then
            c="$(printf '%s' "$line" | tr ' ' '\n' | grep -m1 '^px-')"
        fi
        [[ -n "$c" ]] || continue
        [[ "$c" == px-* ]] || continue
        if [[ -n "$tag" && "$c" != "$tag" ]]; then
            continue
        fi
        ufw --force delete allow "$port/$proto" comment "$c" >/dev/null 2>&1 \
            || px_warn "未能删除 ufw 规则：${port}/${proto}（comment ${c}）"
    done < <(ufw show added 2>/dev/null | grep -F "allow $port/$proto")
    return 0
}

# ===========================================================================
# 防火墙：对外 API
# ===========================================================================

# net_fw_allow <port> <tcp|udp> [comment]
net_fw_allow() {
    local port proto tag backend rc=0
    port="$(_net_port_num "${1:-}")" || { px_err "net_fw_allow: 端口非法：${1:-<空>}"; return 1; }
    proto="${2:-tcp}"
    tag="${3:-}"
    case "$proto" in
        tcp|udp) ;;
        *) px_err "net_fw_allow: 协议应为 tcp|udp：$proto"; return 1 ;;
    esac
    if [[ -z "$tag" ]]; then
        # 默认 px-<调用者>，只保留安全字符（iptables comment 上限 256）
        tag="px-${FUNCNAME[1]:-user}"
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
            # 独立的 inet px 表不能覆盖 firewalld/ufw 自己的 DROP 链，
            # 所以活跃的管理器必须同步放行，否则装了也连不上。
            if _net_firewalld_active; then
                _net_firewalld_allow "$port" "$proto" || rc=1
            fi
            if _net_ufw_active; then
                _net_ufw_allow "$port" "$proto" "$tag" || rc=1
            fi
            ;;
        *)
            px_warn "未检测到可用防火墙，跳过放行 ${port}/${proto}；请在云安全组放行"
            return 0
            ;;
    esac
    if ((rc == 0)); then
        px_ok "已放行 ${port}/${proto}（${backend}）"
    else
        px_err "放行 ${port}/${proto} 失败（${backend}）"
    fi
    return "$rc"
}

# net_fw_deny <port> <tcp|udp> [comment]：撤销放行，只删 px-* 规则
net_fw_deny() {
    local port proto tag any=0 rc=0
    port="$(_net_port_num "${1:-}")" || { px_err "net_fw_deny: 端口非法：${1:-<空>}"; return 1; }
    proto="${2:-tcp}"
    tag="${3:-}"
    case "$proto" in
        tcp|udp) ;;
        *) px_err "net_fw_deny: 协议应为 tcp|udp：$proto"; return 1 ;;
    esac
    # 后端可能在安装后被换掉（比如后来装了 nftables），所以所有存在的后端都尝试一遍；
    # 每个删除路径都只匹配 px- comment 或精确端口，不会误删别人的规则。
    if command -v nft >/dev/null 2>&1 && nft list table inet px >/dev/null 2>&1; then
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
        px_warn "未检测到防火墙，无需撤销 ${port}/${proto}"
        return 0
    fi
    if ((rc == 0)); then
        px_ok "已撤销 ${port}/${proto} 的放行规则"
    fi
    return "$rc"
}

# net_fw_status：打印后端 + 各管理器里属于 px 的规则数量
net_fw_status() {
    local backend n
    backend="$(net_fw_backend)"
    px_kv "防火墙后端" "$backend"
    if command -v nft >/dev/null 2>&1 && nft list table inet px >/dev/null 2>&1; then
        n="$(nft -a list table inet px 2>/dev/null | grep -c 'comment "px-' || true)"
        px_kv "nft(inet px) 规则" "${n:-0}"
    fi
    if _net_ipt_available iptables; then
        n="$(iptables -S INPUT 2>/dev/null | grep -cE 'comment "?px-' || true)"
        px_kv "iptables(px-) 规则" "${n:-0}"
    fi
    if _net_firewalld_active; then
        px_kv "firewalld 放行端口" "$(firewall-cmd --list-ports 2>/dev/null || true)"
    fi
    if command -v ufw >/dev/null 2>&1 && _net_ufw_active; then
        n="$(ufw show added 2>/dev/null | grep -cE "comment 'px-" || true)"
        px_kv "ufw(px-) 规则" "${n:-0}"
    fi
    return 0
}

# ===========================================================================
# BBR / TCP Fast Open：只改两个 sysctl 键，落在 99-px-bbr.conf（TFO 也写这里）
# ===========================================================================

_net_sysctl_conf() { printf '/etc/sysctl.d/99-px-bbr.conf'; }

# 只替换目标 key 那一行，保留文件里其它 PX 调优项（TFO 与 BBR 共用一个文件）
_net_sysctl_write() {
    local key="$1" val="$2" conf tmp
    conf="$(_net_sysctl_conf)"
    mkdir -p /etc/sysctl.d 2>/dev/null || return 1
    tmp="$(mktemp '/etc/sysctl.d/.99-px-bbr.XXXXXX')" || return 1
    if [[ -f "$conf" ]]; then
        awk -v k="$key" '
            {
                line = $0
                gsub(/[[:space:]]/, "", line)
                if (index(line, k "=") != 1) print
            }' "$conf" > "$tmp" || true
    else
        printf '# PX 网络调优：BBR / TCP Fast Open（由 px 生成，可直接删除）\n' > "$tmp"
    fi
    printf '%s = %s\n' "$key" "$val" >> "$tmp"
    chmod 644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$conf"; then
        rm -f "$tmp"
        return 1
    fi
    return 0
}

_net_sysctl_apply() {
    local key="$1" val="$2"
    _net_sysctl_write "$key" "$val" || return 1
    command -v sysctl >/dev/null 2>&1 || return 1
    sysctl --system >/dev/null 2>&1 \
        || sysctl -p "$(_net_sysctl_conf)" >/dev/null 2>&1 \
        || true
    # 部分容器不读 /etc/sysctl.d：直接下发一次兜底，最终以实际值判定
    if [[ "$(sysctl -n "$key" 2>/dev/null)" != "$val" ]]; then
        sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
    fi
    return 0
}

_net_bbr_supported() {
    local avail
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if [[ " $avail " == *' bbr '* ]]; then
        return 0
    fi
    # 模块未加载时先尝试加载再复核
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
    fi
    avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    [[ " $avail " == *' bbr '* ]]
}

# net_bbr_status：打印当前 cc/qdisc，cc=bbr 时返回 0
net_bbr_status() {
    local cc qdisc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    px_kv "拥塞控制算法" "${cc:-未知}"
    px_kv "默认队列规则" "${qdisc:-未知}"
    [[ "$cc" == 'bbr' ]]
}

net_bbr_enable() {
    if net_bbr_status >/dev/null 2>&1; then
        px_ok "BBR 已启用，无需重复配置"
        return 0
    fi
    if ! _net_bbr_supported; then
        px_err "当前内核不支持 BBR（需 4.9+ 且未禁用 tcp_bbr）"
        return 1
    fi
    # 先设 qdisc 再切 cc，切换过程不断流
    _net_sysctl_apply net.core.default_qdisc fq || return 1
    _net_sysctl_apply net.ipv4.tcp_congestion_control bbr || return 1
    if net_bbr_status >/dev/null 2>&1; then
        px_ok "BBR 已启用（写入 $(_net_sysctl_conf)）"
        return 0
    fi
    px_err "BBR 未生效：容器/虚拟化可能限制 sysctl，请检查"
    return 1
}

# net_tfo_status：tcp_fastopen=3（客户端 + 服务端）返回 0
net_tfo_status() {
    local v
    v="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true)"
    px_kv "TCP Fast Open" "${v:-未知}（3 = 客户端+服务端）"
    [[ "$v" == '3' ]]
}

net_tfo_enable() {
    if net_tfo_status >/dev/null 2>&1; then
        px_ok "TCP Fast Open 已启用（值=3），无需重复配置"
        return 0
    fi
    _net_sysctl_apply net.ipv4.tcp_fastopen 3 || return 1
    if net_tfo_status >/dev/null 2>&1; then
        px_ok "TCP Fast Open 已启用（写入 $(_net_sysctl_conf)）"
        return 0
    fi
    px_err "TCP Fast Open 未生效（部分内核/容器限制）"
    return 1
}

# ===========================================================================
# UDP 端口跳跃：PREROUTING DNAT 到本机目标端口，comment px-hop-<key>
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
    nft add rule inet px prerouting udp dport "$start-$end" redirect to ":$target" comment "\"$tag\"" 2>/dev/null || return 1
    _net_nft_persist
    return 0
}

_net_hop_nft_del() {
    local tag="$1"
    local -a hs=()
    nft list chain inet px prerouting >/dev/null 2>&1 || return 0
    mapfile -t hs < <(_net_nft_handles_for_tag prerouting "$tag")
    [[ ${#hs[@]} -eq 0 ]] && return 0
    _net_nft_del_handles prerouting "${hs[@]}"
    _net_nft_persist
    return 0
}

_net_hop_nft_show() {
    local tag="$1"
    nft -a list chain inet px prerouting 2>/dev/null | awk -v tag="\"$tag\"" '
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
    key="$(_net_hop_key "${1:-}")" || { px_err "net_nat_hop_add: key 非法（仅限字母数字_-）"; return 1; }
    start="$(_net_port_num "${2:-}")" || { px_err "net_nat_hop_add: 起始端口非法"; return 1; }
    end="$(_net_port_num "${3:-}")" || { px_err "net_nat_hop_add: 结束端口非法"; return 1; }
    target="$(_net_port_num "${4:-}")" || { px_err "net_nat_hop_add: 目标端口非法"; return 1; }
    if ((start > end)); then
        px_err "net_nat_hop_add: 端口范围非法（$start > $end）"
        return 1
    fi
    tag="px-hop-$key"
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
        px_err "net_nat_hop_add: iptables 与 nftables 均不可用，无法配置端口跳跃"
        return 1
    fi
    px_ok "端口跳跃：UDP ${start}-${end} → ${target}（${tag}）"
    return 0
}

# net_nat_hop_del <key>：按 comment 精确删除，绝不碰别人的规则
net_nat_hop_del() {
    local key tag left
    key="$(_net_hop_key "${1:-}")" || { px_err "net_nat_hop_del: key 非法（仅限字母数字_-）"; return 1; }
    tag="px-hop-$key"
    _net_hop_ipt_del "$tag"
    _net_hop_nft_del "$tag"
    left="$(_net_hop_all "$tag")"
    if [[ -n "$left" ]]; then
        px_warn "仍有端口跳跃规则残留（${tag}），请手动检查："
        printf '%s\n' "$left"
        return 1
    fi
    px_ok "端口跳跃规则已清理（${tag}）"
    return 0
}

# net_nat_hop_show <key>
net_nat_hop_show() {
    local key tag out
    key="$(_net_hop_key "${1:-}")" || { px_err "net_nat_hop_show: key 非法（仅限字母数字_-）"; return 1; }
    tag="px-hop-$key"
    out="$(_net_hop_all "$tag")"
    if [[ -z "$out" ]]; then
        px_info "无端口跳跃规则（${tag}）"
        return 0
    fi
    px_title "端口跳跃 ${tag}"
    printf '%s\n' "$out"
    return 0
}

# ===== src/lib/cert.sh =====
# lib/cert.sh —— 证书：复用已有 / ACME(HTTP-01) / 自签（EC P-256）
#
# 约定（SPEC §8）：证书固定放 /etc/px/certs/<name>/cert.pem + key.pem，
# 目录 700、私钥 600。证书缺失时绝不静默生成——必须显式走 cert_ensure。
# 三种来源都先写临时文件再原子替换，任何一步失败都不留半成品。

# ===========================================================================
# 内部工具
# ===========================================================================

# acme.sh 的安装位置随安装方式而变，按"用户目录 -> root -> PATH"查找
_cert_acme_bin() {
    local c
    for c in "$HOME/.acme.sh/acme.sh" /root/.acme.sh/acme.sh /usr/local/bin/acme.sh; do
        if [[ -x "$c" ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    c="$(command -v acme.sh 2>/dev/null || true)"
    [[ -n "$c" ]] || return 1
    printf '%s' "$c"
}

# 目录名只保留安全字符；通配符 *.example.com 归档到 example.com
_cert_dir_name() {
    local n="$1"
    n="${n#\*.}"
    n="${n//[^A-Za-z0-9._-]/_}"
    n="${n#.}"
    [[ -n "$n" ]] || n="default"
    printf '%s' "$n"
}

_cert_valid_domain() {
    local d="${1:-}"
    [[ -n "$d" && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

_cert_mkdir_secure() {
    mkdir -p "$1" 2>/dev/null || return 1
    chmod 700 "$1" 2>/dev/null || true
    return 0
}

# 证书与私钥必须成对：都能解析，且公钥一致
_cert_pair_ok() {
    local crt="$1" key="$2" a b
    [[ -s "$crt" && -s "$key" ]] || return 1
    openssl x509 -in "$crt" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    a="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)" || return 1
    b="$(openssl pkey -in "$key" -pubout 2>/dev/null)" || return 1
    [[ -n "$a" && "$a" == "$b" ]]
}

# SAN 里的全部 DNS 名（优先 -ext，老版本退回 -text 解析）
_cert_sans() {
    local crt="$1" out
    out="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        out="$(openssl x509 -in "$crt" -noout -text 2>/dev/null || true)"
    fi
    printf '%s\n' "$out" | tr ',' '\n' \
        | sed -n 's/.*[Dd][Nn][Ss]:[[:space:]]*//p' \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$' || true
}

_cert_cn() {
    local crt="$1"
    openssl x509 -in "$crt" -noout -subject 2>/dev/null \
        | sed -n 's/.*[Cc][Nn][[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' \
        | head -n1 | sed 's/[[:space:]]*$//'
}

# 证书是否覆盖该域名（精确匹配或单级通配）
_cert_covers() {
    local crt="$1" d="$2" n suffix label
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ "$n" == "$d" ]]; then
            return 0
        fi
        if [[ "$n" == '*.'* ]]; then
            suffix="${n#\*}"
            label="${d%"$suffix"}"
            if [[ "$d" == *"$suffix" && "$d" != "$suffix" && -n "$label" && "$label" != *.* ]]; then
                return 0
            fi
        fi
    done < <(_cert_sans "$crt"; _cert_cn "$crt")
    return 1
}

# 老版本 openssl 没有 -addext，走临时配置文件补 SAN
_cert_sign_self() {
    local sni="$1" key="$2" crt="$3" cfg rc=0
    if openssl req -new -x509 -key "$key" -out "$crt" -days 36500 -sha256 \
            -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1; then
        return 0
    fi
    cfg="$(mktemp)" || return 1
    cat > "$cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = $sni

[v3]
subjectAltName = DNS:$sni
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
EOF
    openssl req -new -x509 -key "$key" -out "$crt" -days 36500 -sha256 -config "$cfg" >/dev/null 2>&1 || rc=1
    rm -f "$cfg"
    return "$rc"
}

_cert_write_json() {
    local outfile="$1" priv="$2" pub="$3" tmp
    tmp="${outfile}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg a "$priv" --arg b "$pub" '{privateKey: $a, publicKey: $b}' > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 1; }
    else
        printf '{"privateKey":"%s","publicKey":"%s"}\n' "$priv" "$pub" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$outfile" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_cert_write_priv_json() {
    local outfile="$1" priv="$2" tmp
    tmp="${outfile}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg a "$priv" '{privateKey: $a}' > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 1; }
    else
        printf '{"privateKey":"%s"}\n' "$priv" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$outfile" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# ===========================================================================
# 证书识别
# ===========================================================================

# cert_detect <crt>：stdout 主域名（SAN 第一个，退化到 CN）
cert_detect() {
    local crt="$1" d
    [[ -f "$crt" ]] || return 1
    d="$(_cert_sans "$crt" | head -n1)"
    if [[ -z "$d" ]]; then
        d="$(_cert_cn "$crt")"
    fi
    [[ -n "$d" ]] || return 1
    printf '%s' "$d"
}

# cert_reuse <domain> <outdir>：stdout 0=可复用 1=需重签
cert_reuse() {
    local domain="$1" outdir="$2" crt key
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    if ! _cert_pair_ok "$crt" "$key"; then
        printf '1'
        return 0
    fi
    # 证书必须覆盖调用方要用的域名，否则复用会直接导致握手失败
    if [[ -n "$domain" ]] && ! _cert_covers "$crt" "$domain"; then
        printf '1'
        return 0
    fi
    if openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
        printf '0'
    else
        printf '1'
    fi
    return 0
}

# ===========================================================================
# 三种签发/复用方式
# ===========================================================================

# cert_self <sni> <outdir>：EC prime256v1 + SAN，36500 天；始终重签（SPEC）
cert_self() {
    local sni="$1" outdir="$2" crt key kt ct
    if [[ -z "$sni" || -z "$outdir" ]]; then
        px_err "cert_self: 用法 cert_self <sni> <outdir>"
        return 1
    fi
    if ! _cert_valid_domain "$sni"; then
        px_err "cert_self: SNI 必须是域名（收到：$sni）"
        return 1
    fi
    _cert_mkdir_secure "$outdir" || { px_err "cert_self: 无法创建目录 $outdir"; return 1; }
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    kt="$outdir/key.pem.tmp.$$"
    ct="$outdir/cert.pem.tmp.$$"
    if ! openssl ecparam -genkey -name prime256v1 -out "$kt" 2>/dev/null; then
        px_err "cert_self: 生成 EC P-256 私钥失败（openssl 不可用？）"
        rm -f "$kt"
        return 1
    fi
    chmod 600 "$kt" 2>/dev/null || true
    if ! _cert_sign_self "$sni" "$kt" "$ct" || ! _cert_pair_ok "$ct" "$kt"; then
        px_err "cert_self: 自签证书生成失败（openssl 版本过旧？）"
        rm -f "$kt" "$ct"
        return 1
    fi
    chmod 644 "$ct" 2>/dev/null || true
    # 强制重签：先落私钥再落证书，最后再验一次成对；失败就都删掉，不留半成品
    if ! mv -f "$kt" "$key" 2>/dev/null; then
        px_err "cert_self: 写入私钥失败：$key"
        rm -f "$kt" "$ct"
        return 1
    fi
    if ! mv -f "$ct" "$crt" 2>/dev/null; then
        px_err "cert_self: 写入证书失败：$crt"
        rm -f "$key"
        return 1
    fi
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    if ! _cert_pair_ok "$crt" "$key"; then
        px_err "cert_self: 落盘后校验失败，已清理"
        rm -f "$crt" "$key"
        return 1
    fi
    px_ok "自签证书已生成：$crt（SNI=$sni，36500 天）"
    return 0
}

# cert_acme <domain> <outdir>：acme.sh + HTTP-01（--standalone --httpport 80）
cert_acme() {
    local domain="$1" outdir="$2" acme crt key email issued=1
    if [[ -z "$domain" || -z "$outdir" ]]; then
        px_err "cert_acme: 用法 cert_acme <domain> <outdir>"
        return 1
    fi
    if ! _cert_valid_domain "$domain"; then
        px_err "cert_acme: ACME 需要真实域名（收到：$domain）"
        return 1
    fi
    _cert_mkdir_secure "$outdir" || { px_err "cert_acme: 无法创建目录 $outdir"; return 1; }
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    # 剩余 >30 天直接复用（域名已校验覆盖），别浪费 Let's Encrypt 的签发限额
    if [[ "$(cert_reuse "$domain" "$outdir")" == "0" ]]; then
        px_ok "已有可用证书（域名匹配且剩余 >30 天），直接复用：$crt"
        return 0
    fi
    if ! acme="$(_cert_acme_bin)"; then
        if ! command -v curl >/dev/null 2>&1; then
            px_err "cert_acme: 缺少 curl，无法安装 acme.sh"
            return 1
        fi
        px_info "安装 acme.sh（socat + cron 用于 HTTP-01 与自动续期）..."
        # Debian 包名 cron，RHEL 是 cronie；哪个能装就用哪个
        os_pkg_install socat cron >/dev/null 2>&1 \
            || os_pkg_install socat cronie >/dev/null 2>&1 \
            || px_warn "socat/cron 安装失败，ACME 可能不可用"
        email="admin@$domain"
        if ! curl -fsSL --connect-timeout 10 --max-time 120 https://get.acme.sh 2>/dev/null \
                | sh -s "email=$email" >/dev/null 2>&1; then
            px_err "cert_acme: acme.sh 安装失败（get.acme.sh 不可达）"
            return 1
        fi
        acme="$(_cert_acme_bin)" || { px_err "cert_acme: 安装后仍未找到 acme.sh"; return 1; }
    fi
    # 默认 CA 是 ZeroSSL，需要 EAB；脚本化一律用 Let's Encrypt
    "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if net_port_in_use 80 tcp; then
        px_warn "80 端口已被占用，HTTP-01 校验很可能失败"
    fi
    px_info "申请证书：$domain（HTTP-01，需 80 端口可被公网访问）..."
    if "$acme" --issue -d "$domain" --standalone --httpport 80 -k ec-256 >/dev/null 2>&1; then
        issued=0
    else
        # acme.sh 对"域名未变化"会跳过 issue（返回非 0），此时仓库里可能已有证书，
        # 继续尝试 install-cert，避免把可复用的证书误判为失败。
        px_warn "acme.sh issue 未返回成功，尝试直接安装仓库中已有证书"
    fi
    if ! "$acme" --install-cert -d "$domain" --ecc \
            --key-file "$key" \
            --fullchain-file "$crt" >/dev/null 2>&1; then
        if ((issued != 0)); then
            px_err "ACME 申请失败：HTTP-01 校验未通过"
            px_info "常见原因：80 端口被占用 / 云安全组未放行 80 / 域名未解析到本机"
            px_info "P0 未内置 DNS API：可手动切 DNS-01 签发，或用 --cert-mode self 自签"
        else
            px_err "cert_acme: 证书安装到 $outdir 失败"
        fi
        return 1
    fi
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    if ! _cert_pair_ok "$crt" "$key"; then
        px_err "cert_acme: 安装后证书/私钥校验失败"
        return 1
    fi
    px_ok "ACME 证书已就绪：$crt（续期由 acme.sh cron 负责）"
    return 0
}

# ===========================================================================
# cert_ensure：三种模式的统一入口（设置全局 CERT_PATH/KEY_PATH/SNI）
# ===========================================================================

_cert_ensure_existing() {
    local hint="$1" dir="$2" crt key d
    crt="$dir/cert.pem"
    key="$dir/key.pem"
    if [[ ! -f "$crt" || ! -f "$key" ]]; then
        px_err "cert_ensure: 未找到已有证书 $crt"
        px_info "请把 cert.pem + key.pem 放进 $dir，或改用 acme/self 模式"
        return 1
    fi
    if ! _cert_pair_ok "$crt" "$key"; then
        px_err "cert_ensure: 已有证书与私钥不匹配或已损坏：$dir"
        return 1
    fi
    d="$(cert_detect "$crt" 2>/dev/null || true)"
    CERT_PATH="$crt"
    KEY_PATH="$key"
    SNI="${d:-$hint}"
    # 复用是用户明确选择，临期只提醒不阻断
    if ! openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
        px_warn "复用的证书将在 30 天内到期，请提前更新：$crt"
    fi
    return 0
}

_cert_ensure_self() {
    local hint="$1" dir="$2" sni
    sni="$hint"
    if ! _cert_valid_domain "$sni"; then
        if [[ "${PX_YES:-0}" == "1" ]]; then
            px_warn "SNI 不是合法域名（${sni}），自签改用默认伪装域名 www.bing.com"
            sni="www.bing.com"
        else
            sni="$(px_ask "自签证书的伪装 SNI（域名）" "www.bing.com")"
        fi
    fi
    if ! _cert_valid_domain "$sni"; then
        px_err "cert_ensure: 自签 SNI 非法（${sni}）"
        return 1
    fi
    cert_self "$sni" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$sni"
    return 0
}

_cert_ensure_acme() {
    local domain="$1" dir="$2"
    if ! _cert_valid_domain "$domain"; then
        px_err "cert_ensure: ACME 模式需要真实域名（收到：$domain）"
        return 1
    fi
    cert_acme "$domain" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$domain"
    return 0
}

# cert_ensure <sni-hint> [mode]；mode=existing|acme|self，省略则交互
cert_ensure() {
    local hint="${1:-}" mode="${2:-}" name dir
    CERT_PATH=""
    KEY_PATH=""
    SNI=""
    if [[ -z "$hint" ]]; then
        hint="${PX_ARG_SNI:-${PX_ARG_DOMAIN:-}}"
    fi
    if [[ -z "$mode" ]]; then
        mode="${PX_ARG_CERT_MODE:-}"
    fi
    if [[ -z "$hint" ]]; then
        hint="$(px_ask "证书域名 / SNI（同时用于证书目录名）" "www.bing.com")"
    fi
    if [[ -z "$hint" ]]; then
        px_err "cert_ensure: 必须提供域名或 SNI"
        return 1
    fi
    case "$mode" in
        '') ;;
        existing|acme|self) ;;
        *) px_err "cert_ensure: mode 只能是 existing|acme|self（收到：$mode）"; return 1 ;;
    esac
    name="$(_cert_dir_name "$hint")"
    dir="$PX_CERT_DIR/$name"
    if [[ -z "$mode" ]]; then
        # PX_YES 时 px_ask 返回默认值：已有证书默认复用，否则默认自签（免 ACME 依赖）
        local def="self"
        if [[ -f "$dir/cert.pem" && -f "$dir/key.pem" ]]; then
            def="existing"
        fi
        mode="$(px_ask "证书方案 existing=复用已有 / acme=ACME 申请 / self=自签" "$def")"
        case "$mode" in
            existing|acme|self) ;;
            *) px_err "cert_ensure: 无效的证书方案（${mode}）"; return 1 ;;
        esac
    fi
    case "$mode" in
        existing) _cert_ensure_existing "$hint" "$dir" || return 1 ;;
        acme)     _cert_ensure_acme "$hint" "$dir" || return 1 ;;
        self)     _cert_ensure_self "$hint" "$dir" || return 1 ;;
    esac
    # 最终统一校验：半成品一律拒绝，并清空全局变量避免调用方误用
    if ! _cert_pair_ok "$CERT_PATH" "$KEY_PATH"; then
        px_err "cert_ensure: 证书/私钥校验失败：$CERT_PATH"
        CERT_PATH=""
        KEY_PATH=""
        SNI=""
        return 1
    fi
    chmod 600 "$KEY_PATH" 2>/dev/null || true
    chmod 644 "$CERT_PATH" 2>/dev/null || true
    px_ok "证书就绪：SNI=${SNI}（$CERT_PATH）"
    return 0
}

# ===========================================================================
# 状态 / REALITY 密钥 / 指纹
# ===========================================================================

# cert_status：打印各证书剩余天数
cert_status() {
    local base="${PX_CERT_DIR:-/etc/px/certs}" d crt name end epoch now days n=0
    if [[ ! -d "$base" ]]; then
        px_info "暂无证书目录（$base）"
        return 0
    fi
    px_title "证书状态"
    for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        crt="$d/cert.pem"
        [[ -f "$crt" ]] || continue
        name="$(basename "$d")"
        n=$((n + 1))
        end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
        if [[ -z "$end" ]]; then
            px_kv "$name" "无法解析证书"
            continue
        fi
        epoch="$(date -d "$end" +%s 2>/dev/null || true)"
        if [[ -n "$epoch" ]]; then
            now="$(date +%s)"
            days=$(( (epoch - now) / 86400 ))
            if ((days < 0)); then
                px_kv "$name" "已过期（$end）"
            else
                px_kv "$name" "剩余 ${days} 天（$end）"
            fi
        elif openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
            # 没有 GNU date 的环境退化成区间提示
            if openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
                px_kv "$name" "有效（>30 天，至 $end）"
            else
                px_kv "$name" "有效（<30 天，至 $end）"
            fi
        else
            px_kv "$name" "已过期（$end）"
        fi
    done
    if ((n == 0)); then
        px_info "暂无证书"
    fi
    return 0
}

# reality_keypair <outfile>：写 {"privateKey":"...","publicKey":"..."}，600
# 返回 0=成功；2=只有私钥（缺 xray，公钥无法用 openssl 导出）；1=失败
reality_keypair() {
    local outfile="$1" xray out priv pub tmpdir privraw
    if [[ -z "$outfile" ]]; then
        px_err "reality_keypair: 用法 reality_keypair <outfile>"
        return 1
    fi
    xray=""
    if [[ -x /usr/local/bin/xray ]]; then
        xray="/usr/local/bin/xray"
    elif command -v xray >/dev/null 2>&1; then
        xray="$(command -v xray)"
    fi
    if [[ -n "$xray" ]]; then
        out="$("$xray" x25519 2>/dev/null || true)"
        priv="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]rivate[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
        pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
        if [[ -z "$pub" ]]; then
            # 新版 xray 把 public key 标成 Password
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[[:space:]]*:[[:space:]]*//p' | head -n1)"
        fi
        if [[ -n "$priv" && -z "$pub" ]]; then
            out="$("$xray" x25519 -i "$priv" 2>/dev/null || true)"
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
            if [[ -z "$pub" ]]; then
                pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[[:space:]]*:[[:space:]]*//p' | head -n1)"
            fi
        fi
        if [[ -n "$priv" && -n "$pub" ]]; then
            _cert_write_json "$outfile" "$priv" "$pub" || { px_err "reality_keypair: 写入 $outfile 失败"; return 1; }
            px_ok "REALITY 密钥对已写入：$outfile"
            return 0
        fi
        px_warn "xray x25519 输出无法解析，改用 openssl 生成私钥"
    fi
    command -v openssl >/dev/null 2>&1 || { px_err "reality_keypair: 缺少 openssl 且未安装 xray"; return 1; }
    tmpdir="$(mktemp -d 2>/dev/null)" || return 1
    if ! openssl genpkey -algorithm X25519 -out "$tmpdir/k.pem" 2>/dev/null; then
        rm -rf "$tmpdir"
        px_err "reality_keypair: openssl 无法生成 X25519 私钥（版本过旧？）"
        return 1
    fi
    # X25519 私钥在 PKCS#8 DER 里就是最后 32 字节；xray 用的是 base64url 无填充
    privraw="$(openssl pkey -in "$tmpdir/k.pem" -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null | tr -d '\n=' | tr '+/' '-_')"
    rm -rf "$tmpdir"
    if [[ -z "$privraw" ]]; then
        px_err "reality_keypair: 私钥编码失败"
        return 1
    fi
    _cert_write_priv_json "$outfile" "$privraw" || { px_err "reality_keypair: 写入 $outfile 失败"; return 1; }
    px_warn "当前没有 xray，仅生成了私钥；安装 xray 后可用 xray x25519 -i <私钥> 导出公钥"
    return 2
}

# cert_fingerprint <crt>：stdout SHA256 pin（小写、冒号分隔）
cert_fingerprint() {
    local crt="$1" fp
    if [[ -z "$crt" || ! -f "$crt" ]]; then
        px_err "cert_fingerprint: 证书不存在：${crt:-<空>}"
        return 1
    fi
    fp="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
    if [[ -z "$fp" ]] || [[ "$fp" == "SHA256"* ]]; then
        px_err "cert_fingerprint: 无法计算 SHA256 指纹（openssl 过旧？）"
        return 1
    fi
    fp="$(printf '%s' "$fp" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
    printf '%s\n' "$fp"
    return 0
}

# ===== src/lib/svc.sh =====
# lib/svc.sh —— systemd 单后端封装

svc_unit_path() { printf '%s/%s.service' "$PX_UNIT_DIR" "$1"; }

# svc_create <unit> <ExecStart> <Description> [额外 Service 行...]
svc_create() {
    local unit="$1" exec="$2" desc="$3"; shift 3
    local path extra
    path="$(svc_unit_path "$unit")"
    extra="$*"
    cat > "$path" <<EOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$exec
Restart=on-failure
RestartSec=3
LimitNOFILE=32767
${extra}

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$path"
    os_service_reload
}

# 原样写 unit（高级用）
svc_write() {
    local unit="$1" content="$2"
    printf '%s\n' "$content" > "$(svc_unit_path "$unit")"
    chmod 644 "$(svc_unit_path "$unit")"
    os_service_reload
}

svc_start()   { systemctl start "$1" >/dev/null 2>&1; }
svc_stop()    { systemctl stop "$1" >/dev/null 2>&1; }
svc_restart() { systemctl restart "$1" >/dev/null 2>&1; }
svc_enable()  { systemctl enable "$1" >/dev/null 2>&1; }
svc_disable() { systemctl disable "$1" >/dev/null 2>&1; }

svc_is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

svc_status() {
    local unit="$1"
    if [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        printf 'not-found'; return 0
    fi
    local s
    s="$(systemctl is-active "$unit" 2>/dev/null || true)"
    printf '%s' "${s:-inactive}"
}

# 停止 + 禁用 + 删 unit + 清理失败状态
svc_remove() {
    local unit="$1"
    svc_stop "$unit"
    svc_disable "$unit"
    rm -f "$(svc_unit_path "$unit")"
    os_service_reload
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}

svc_logs() {
    local unit="$1" lines="${2:-30}"
    journalctl -u "$unit" -n "$lines" --no-pager -o cat 2>/dev/null || true
}

# ===== src/lib/share.sh =====
# lib/share.sh —— 分享链接与订阅产物（Clash / Surge / sing-box / URI / 二维码）
#
# 约定：
#   - 所有内容生成逻辑只往 stdout 打内容，提示一律走 px_info/px_warn（stderr），
#     这样 share_render_sub 里 `... >/dev/null` 之后 stdout 还能干净地只留路径。
#   - 片段渲染全部委托给各协议实现的 link/clash/surge/singbox 渲染函数，
#     这里不关心任何协议细节；某协议片段生成失败（如拿不到公网 IP）就跳过并警告，
#     不能让一条坏节点把整份订阅带崩。

# 拼协议函数名。不要用字面量前缀紧接 ${...} 的写法：build.sh 的未定义函数扫描
# 会把前缀后直接跟变量的地方当成一个不存在的函数名，导出误报。
_share_fn() {
    local p="proto"
    printf '%s_%s_%s' "$p" "$1" "$2"
}

# _share_write <kind> <outfile|stdout|""> <content>
# 落盘时用 umask 077 创建，保证订阅里带 uuid/私钥的文件从出生就是 600。
_share_write() {
    local kind="$1" target="$2" body="$3" dir
    if [[ -z "$target" || "$target" == "stdout" ]]; then
        printf '%s\n' "$body"
        return 0
    fi
    dir="$(dirname -- "$target")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            px_err "创建目录失败：$dir"
            return 1
        }
    fi
    if ! ( umask 077; printf '%s\n' "$body" > "$target" ); then
        px_err "写入失败：$target"
        return 1
    fi
    chmod 600 "$target" 2>/dev/null || true
    px_info "$kind 订阅已写入：$target" >&2
    printf '%s\n' "$target"
}

# share_render_uri <key> —— 只输出该协议的分享 URI
share_render_uri() {
    local key="${1:-}" fn
    if [[ -z "$key" ]]; then
        px_err "用法：share_render_uri <key>"
        return 1
    fi
    if ! db_is_installed "$key"; then
        px_err "协议未安装：$key"
        return 1
    fi
    fn="$(_share_fn "$key" link)"
    "$fn"
}

# share_render_clash [outfile|stdout] —— 完整可导入的 Clash 配置
share_render_clash() {
    local out="${1:-stdout}" key fn frag name body
    local -a frags=() names=()
    for key in "${PX_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" clash)"
        if ! frag="$("$fn")"; then
            px_warn "跳过 $key：Clash 片段生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        frags+=("$frag")
        # 片段里的 name 就是协议标题，代理组按同一套名字引用，避免两处名字漂移
        names+=("${PX_PROTO_TITLE[$key]:-$key}")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        px_err "没有可用的已安装协议，无法生成 Clash 订阅"
        return 1
    fi
    body="$(
        printf 'mixed-port: 7897\n'
        printf 'allow-lan: false\n'
        printf 'mode: rule\n'
        printf 'log-level: info\n'
        printf 'proxies:\n'
        for frag in "${frags[@]}"; do printf '%s\n' "$frag"; done
        printf 'proxy-groups:\n'
        printf '  - name: PROXY\n'
        printf '    type: select\n'
        printf '    proxies:\n'
        for name in "${names[@]}"; do printf '      - "%s"\n' "$name"; done
        printf 'rules:\n'
        printf '  - GEOIP,CN,DIRECT\n'
        printf '  - MATCH,PROXY\n'
    )"
    _share_write "Clash" "$out" "$body"
}

# share_render_surge [outfile|stdout] —— 完整可导入的 Surge conf
share_render_surge() {
    local out="${1:-stdout}" key fn frag name joined body
    local -a frags=() names=()
    for key in "${PX_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" surge)"
        if ! frag="$("$fn")"; then
            px_warn "跳过 $key：Surge 节点生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        frags+=("$frag")
        names+=("${PX_PROTO_TITLE[$key]:-$key}")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        px_err "没有可用的已安装协议，无法生成 Surge 订阅"
        return 1
    fi
    joined="$(printf '%s, ' "${names[@]}")"
    joined="${joined%, }"
    body="$(
        printf '[General]\n'
        printf 'loglevel = notify\n'
        printf '\n'
        printf '[Proxy]\n'
        for frag in "${frags[@]}"; do printf '%s\n' "$frag"; done
        printf '\n'
        printf '[Proxy Group]\n'
        printf 'PROXY = select, %s\n' "$joined"
        printf '\n'
        printf '[Rule]\n'
        printf 'GEOIP,CN,DIRECT\n'
        printf 'FINAL,PROXY,dns-failed\n'
    )"
    _share_write "Surge" "$out" "$body"
}

# share_render_singbox [outfile|stdout] —— 完整 sing-box 配置（首个出站是 selector）
share_render_singbox() {
    local out="${1:-stdout}" key fn frag tag tags_json merged body
    local -a frags=() tags=()
    for key in "${PX_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" singbox)"
        if ! frag="$("$fn")"; then
            px_warn "跳过 $key：sing-box 片段生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        # 片段必须是 JSON 对象，否则拼进去整份配置就废了
        if ! printf '%s' "$frag" | jq -e 'type == "object"' >/dev/null 2>&1; then
            px_warn "跳过 $key：sing-box 片段不是合法 JSON 对象"
            continue
        fi
        tag="$(printf '%s' "$frag" | jq -r '.tag // empty' 2>/dev/null)"
        if [[ -z "$tag" ]]; then
            tag="${PX_PROTO_TITLE[$key]:-$key}"
            frag="$(printf '%s' "$frag" | jq -c --arg t "$tag" '.tag = $t')" || {
                px_warn "跳过 $key：无法补 tag"
                continue
            }
        fi
        frags+=("$frag")
        tags+=("$tag")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        px_err "没有可用的已安装协议，无法生成 sing-box 订阅"
        return 1
    fi
    tags_json="$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s -c .)"
    merged="$(jq -c -n --argjson tags "$tags_json" \
        '{outbounds: [{type: "selector", tag: "proxy", outbounds: $tags}]}')"
    if [[ -z "$merged" ]]; then
        px_err "生成 sing-box 骨架失败（jq 出错）"
        return 1
    fi
    for frag in "${frags[@]}"; do
        if ! merged="$(printf '%s' "$merged" | jq -c --argjson o "$frag" '.outbounds += [$o]')"; then
            px_err "拼接 sing-box outbound 失败"
            return 1
        fi
    done
    body="$(printf '%s' "$merged" | jq .)" || body="$merged"
    _share_write "sing-box" "$out" "$body"
}

# share_render_uri_list [outfile|stdout] —— 一行一个 URI（订阅 uri 格式用）
share_render_uri_list() {
    local out="${1:-stdout}" key fn uri body=""
    for key in "${PX_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" link)"
        if ! uri="$("$fn")"; then
            px_warn "跳过 $key：URI 生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        body+="$uri"$'\n'
    done
    if [[ -z "$body" ]]; then
        px_err "没有可用的已安装协议，无法生成 URI 列表"
        return 1
    fi
    _share_write "URI 列表" "$out" "${body%$'\n'}"
}

# share_render_sub <format> —— 生成 /etc/px/sub/px-<format>.<ext>，stdout 只打印路径
share_render_sub() {
    local format="${1:-}" path dir ext
    case "$format" in
        clash)   ext="yaml" ;;
        surge)   ext="conf" ;;
        singbox) ext="json" ;;
        uri)     ext="txt" ;;
        *)
            px_err "未知订阅格式：${format:-<空>}（可选 clash|surge|singbox|uri）"
            return 1
            ;;
    esac
    dir="$PX_SUB_DIR"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            px_err "创建订阅目录失败：$dir"
            return 1
        }
    fi
    path="$dir/px-$format.$ext"
    case "$format" in
        clash)   share_render_clash "$path" >/dev/null || return 1 ;;
        surge)   share_render_surge "$path" >/dev/null || return 1 ;;
        singbox) share_render_singbox "$path" >/dev/null || return 1 ;;
        uri)     share_render_uri_list "$path" >/dev/null || return 1 ;;
    esac
    chmod 600 "$path" 2>/dev/null || true
    printf '%s\n' "$path"
}

# share_qr <text> —— 终端二维码；没有 qrencode 就原样打印文本
share_qr() {
    local text="${1:-}"
    if [[ -z "$text" ]]; then
        px_err "用法：share_qr <text>"
        return 1
    fi
    if command -v qrencode >/dev/null 2>&1; then
        # ANSIUTF8 用半个字高的块字符，终端里比 ASCII 二维码窄一半
        qrencode -t ANSIUTF8 "$text" || {
            px_err "qrencode 执行失败，下面给出原始文本"
            printf '%s\n' "$text"
            return 1
        }
    else
        px_warn "未安装 qrencode（px 系统工具里可装），下面直接给出原始文本："
        printf '%s\n' "$text"
    fi
}

# share_print_links <key> —— URI + 三种订阅片段 + 二维码
share_print_links() {
    local key="${1:-}" fn uri out
    if [[ -z "$key" ]]; then
        px_err "用法：share_print_links <key>"
        return 1
    fi
    if ! db_is_installed "$key"; then
        px_err "协议未安装：$key"
        return 1
    fi
    px_title "分享：${PX_PROTO_TITLE[$key]:-$key}"

    fn="$(_share_fn "$key" link)"
    if ! uri="$("$fn")"; then
        px_err "分享链接生成失败"
        return 1
    fi
    px_info "URI 链接："
    printf '%s\n' "$uri"
    printf '\n'

    fn="$(_share_fn "$key" clash)"
    px_info "Clash 片段（proxies: 下的一项）："
    if ! out="$("$fn")"; then
        px_warn "Clash 片段生成失败"
    else
        printf '%s\n' "$out"
    fi
    printf '\n'

    fn="$(_share_fn "$key" surge)"
    px_info "Surge 节点行："
    if ! out="$("$fn")"; then
        px_warn "Surge 节点生成失败"
    else
        printf '%s\n' "$out"
    fi
    printf '\n'

    fn="$(_share_fn "$key" singbox)"
    px_info "sing-box outbound："
    if out="$("$fn")"; then
        printf '%s' "$out" | jq . 2>/dev/null || printf '%s\n' "$out"
    else
        px_warn "sing-box 片段生成失败"
    fi
    printf '\n'

    px_info "扫码导入（v2rayN / NekoBox / Shadowrocket）："
    share_qr "$uri"
}

# ===== src/proto/vless_reality.sh =====
# proto/vless_reality.sh —— VLESS + REALITY（Xray-core 官方内核）
# REALITY 不落地证书：借用目标站真实 TLS 握手，不需要证书库参与；
# 私钥只存在于 /etc/px/db.json 与 config.json，两者都是 600，不允许只留在内存。

# 交互读取：ui.sh 的 px_ask 把提示符也写进 stdout，$(px_ask ...) 捕获后不可用，
# 所以这里提示走 stderr，答案走 stdout（等 ui.sh 修好后可直接换回 px_ask）。
pxp_vless_reality_ask() {
    local prompt="$1" def="${2:-}" ans
    if [[ "$PX_YES" == "1" && -n "$def" ]]; then
        printf '%s' "$def"
        return 0
    fi
    if [[ -n "$def" ]]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r ans || ans=""
    printf '%s' "${ans:-$def}"
}

# 输出两行：私钥、公钥。优先走 cert.sh 的 reality_keypair，失败再自己解析 xray x25519。
pxp_vless_reality_keys() {
    local tmp priv="" pub="" raw
    tmp="$(mktemp "${TMPDIR:-/tmp}/px-x25519.XXXXXX")" || {
        px_err "创建临时文件失败"
        return 1
    }
    if reality_keypair "$tmp" 2>/dev/null; then
        priv="$(jq -r '.privateKey // empty' "$tmp" 2>/dev/null)"
        pub="$(jq -r '.publicKey // empty' "$tmp" 2>/dev/null)"
    fi
    rm -f "$tmp"
    if [[ -z "$priv" || -z "$pub" ]]; then
        raw="$("$PX_BIN_DIR/xray" x25519 2>/dev/null)"
        # 两代输出格式：PrivateKey/Password（旧）、Private key/Public key（新）
        priv="$(printf '%s\n' "$raw" | awk -F': *' '/^[[:space:]]*[Pp]rivate ?[Kk]ey:/ {print $2; exit}')"
        pub="$(printf '%s\n' "$raw" | awk -F': *' '/^[[:space:]]*([Pp]ublic ?[Kk]ey|[Pp]assword)([[:space:]]*\([^)]*\))?:/ {print $2; exit}')"
    fi
    priv="$(printf '%s' "$priv" | tr -d '[:space:]')"
    pub="$(printf '%s' "$pub" | tr -d '[:space:]')"
    if [[ -z "$priv" || -z "$pub" ]]; then
        px_err "REALITY 密钥解析失败（xray x25519 输出格式未知）"
        return 1
    fi
    printf '%s\n%s\n' "$priv" "$pub"
}

# 端口协商：PX_ARG_PORT > 交互（默认 443）；占用时提示换端口，443 建议独占。
pxp_vless_reality_port() {
    local port="${PX_ARG_PORT:-}" alt def
    # 契约顺序：PX_ARG_PORT -> meta 的 port -> 交互；meta 未装时给 443
    def="$(proto_vless_reality_meta | sed -n 's/^port=//p')"
    [[ -z "$def" ]] && def="443"
    if [[ -z "$port" ]]; then
        port="$(pxp_vless_reality_ask "REALITY 监听端口" "$def")"
    fi
    port="$(printf '%s' "$port" | tr -d '[:space:]')"
    [[ "$port" =~ ^[0-9]+$ ]] || px_die "端口必须是数字：$port"
    ((port >= 1 && port <= 65535)) || px_die "端口超出范围：$port"
    if net_port_in_use "$port" tcp; then
        if [[ -n "$PX_ARG_PORT" ]]; then
            alt="$(net_port_pick 443 tcp)"
            px_die "端口 $port 已被占用（--port 指定）；可换空闲端口，例如 --port ${alt:-8443}"
        fi
        px_warn "端口 $port 已被占用；443 被占时 VLESS-Reality 建议换端口独占 443"
        alt="$(net_port_pick 443 tcp)"
        [[ -z "$alt" || "$alt" == "$port" ]] && px_die "找不到可用端口，已取消安装"
        if ! px_confirm "改用空闲端口 $alt ？" y; then
            px_die "已取消安装"
        fi
        port="$alt"
        px_info "改用端口：$port"
    fi
    printf '%s' "$port"
}

# 输出 "serverName dest"（空格分隔）。dest 缺省补 :443。
pxp_vless_reality_dest() {
    local def="${PX_ARG_SNI:-www.microsoft.com}" input sni dest
    px_warn "提示：dest 必须是未过 CDN 的真实站点，套了 CDN 会破坏 REALITY 的 TLS 指纹"
    input="$(pxp_vless_reality_ask "REALITY 伪装域名（回车用默认，真实域名不能过 CDN）" "$def")"
    input="$(printf '%s' "$input" | tr -d '[:space:]')"
    [[ -z "$input" ]] && input="$def"
    if [[ "$input" == *:* ]]; then
        sni="${input%%:*}"
        dest="$input"
    else
        sni="$input"
        dest="$input:443"
    fi
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || px_die "域名格式不合法：$sni"
    [[ "$sni" == *.* ]] || px_die "域名格式不合法（需要含点）：$sni"
    printf '%s %s\n' "$sni" "$dest"
}

# 写 inbounds[0] + 基本 direct/block 出站；600；先写临时文件再 mv。
# 第 7 个参数可指定目标文件（regen 用它先写 staging 验证，验不过就不动在线配置）。
pxp_vless_reality_cfg_write() {
    local port="$1" uuid="$2" priv="$3" sni="$4" sid="$5" dest="$6" out="${7:-}"
    local dir cfg tmp
    dir="$(px_proto_dir vless_reality)"
    cfg="${out:-$dir/config.json}"
    mkdir -p "$dir"
    [[ -n "$out" ]] && mkdir -p "$(dirname -- "$out")"
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg priv "$priv" \
        --arg sni "$sni" \
        --arg sid "$sid" \
        --arg dest "$dest" \
        '{
            log: {loglevel: "warning"},
            inbounds: [{
                listen: "0.0.0.0",
                port: $port,
                protocol: "vless",
                settings: {
                    clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
                    decryption: "none"
                },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        dest: $dest,
                        xver: 0,
                        serverNames: [$sni],
                        privateKey: $priv,
                        shortIds: [$sid]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http", "tls"]}
            }],
            outbounds: [
                {protocol: "freedom", tag: "direct"},
                {protocol: "blackhole", tag: "block"}
            ],
            routing: {rules: [{type: "field", ip: ["geoip:private"], outboundTag: "block"}]}
        }' > "$tmp"; then
        rm -f "$tmp"
        px_err "生成 Xray 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp"
    if ! mv -f "$tmp" "$cfg"; then
        rm -f "$tmp"
        px_err "写入 Xray 配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg"
    printf '%s' "$cfg"
}

# 服务器地址：db.settings.ip 优先，其次实时探测（IPv6 原样返回，由调用方决定是否加方括号）
pxp_vless_reality_ip() {
    local ip
    ip="$(db_get settings ip "")"
    [[ -z "$ip" ]] && ip="$(net_primary_ip)"
    printf '%s' "$ip"
}

pxp_vless_reality_fw_comment() { printf 'px-vless-reality'; }

proto_vless_reality_meta() {
    local port
    port="$(db_get vless_reality port "")"
    [[ -z "$port" ]] && port="443"
    printf 'title=%s\n' "${PX_PROTO_TITLE[vless_reality]:-VLESS-Reality}"
    printf 'desc=%s\n' "Xray-core REALITY 抗封锁强，无需证书，建议独占 443"
    printf 'port=%s\n' "$port"
    printf 'udp=no\n'
    printf 'cert=no\n'
}

proto_vless_reality_install() {
    local key="vless_reality"
    local dir unit bin cfg port uuid sid sni dest priv pub ip
    local ver="" asset tmp kp

    px_require_root
    os_detect

    if db_has "$key"; then
        if [[ "$PX_YES" == "1" ]]; then
            px_die "VLESS-Reality 已安装（--yes 模式不覆盖；请先 --uninstall）"
        fi
        if ! px_confirm "VLESS-Reality 已安装，是否重新安装（覆盖配置）？" n; then
            px_info "已取消安装"
            return 0
        fi
    fi

    px_title "安装 VLESS-Reality"
    os_dep_install base || px_die "系统依赖安装失败"

    bin="$PX_BIN_DIR/xray"
    if [[ -x "$bin" ]] && "$bin" version >/dev/null 2>&1; then
        ver="$("$bin" version 2>/dev/null | head -n1 | awk '{print $2}')"
        px_ok "复用已安装 xray：$("$bin" version 2>/dev/null | head -n1)"
    else
        case "$PX_ARCH" in
            amd64)  asset="Xray-linux-64.zip" ;;
            arm64)  asset="Xray-linux-arm64-v8a.zip" ;;
            armv7l) asset="Xray-linux-arm32-v7a.zip" ;;
            i386)   asset="Xray-linux-32.zip" ;;
            *)      px_die "Xray 官方未提供该架构的预编译包：$PX_ARCH" ;;
        esac
        ver="$(dl_latest_tag XTLS/Xray-core)"
        [[ -z "$ver" ]] && px_die "获取 Xray-core 版本失败（网络或 GitHub API 限流），可先在设置里配 gh_proxy"
        px_info "下载 Xray-core $ver（$asset）..."
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/px-xray.XXXXXX")" || px_die "创建临时目录失败"
        if ! dl_gh XTLS/Xray-core "$ver" "$asset" "$tmp/xray.zip"; then
            rm -rf "$tmp"
            px_die "Xray-core 下载失败"
        fi
        if ! dl_unzip "$tmp/xray.zip" "$tmp/unzip"; then
            rm -rf "$tmp"
            px_die "Xray-core 解压失败"
        fi
        if [[ ! -f "$tmp/unzip/xray" ]]; then
            rm -rf "$tmp"
            px_die "压缩包内未找到 xray 可执行文件"
        fi
        if ! cp -f "$tmp/unzip/xray" "$bin" || ! chmod 755 "$bin"; then
            rm -rf "$tmp"
            px_die "安装 xray 到 $bin 失败"
        fi
        rm -rf "$tmp"
        if ! "$bin" version >/dev/null 2>&1; then
            px_die "xray 无法执行（CPU 架构不匹配？）"
        fi
        px_ok "xray 已安装：$("$bin" version 2>/dev/null | head -n1)"
    fi

    port="$(pxp_vless_reality_port)" || return 1
    uuid="$(os_uuid)"
    sid="$(os_random_hex 4)"
    sid="${sid:0:8}"
    [[ -n "$sid" ]] || px_die "生成 shortId 失败"

    kp="$(pxp_vless_reality_keys)" || px_die "REALITY 密钥对生成失败"
    priv="$(printf '%s\n' "$kp" | sed -n '1p')"
    pub="$(printf '%s\n' "$kp" | sed -n '2p')"
    [[ -n "$priv" && -n "$pub" ]] || px_die "REALITY 密钥为空"

    # 私钥第一时间落库，避免安装中断后私钥只剩内存/半截文件
    db_set "$key" private_key "$priv"
    db_set "$key" public_key "$pub"
    db_set "$key" uuid "$uuid"
    db_set "$key" short_id "$sid"

    read -r sni dest <<< "$(pxp_vless_reality_dest)"
    [[ -n "$sni" && -n "$dest" ]] || px_die "REALITY dest 获取失败"

    dir="$(px_proto_dir "$key")"
    if ! cfg="$(pxp_vless_reality_cfg_write "$port" "$uuid" "$priv" "$sni" "$sid" "$dest")"; then
        px_die "写入配置失败（目录：$dir）"
    fi
    px_ok "配置已写入：$cfg"

    if ! "$bin" run -test -c "$cfg" >/dev/null 2>&1; then
        px_err "Xray 配置自检失败，输出如下："
        "$bin" run -test -c "$cfg" 2>&1 | tail -n 20 >&2
        px_die "已中止（配置保留在 $cfg 供排查）"
    fi

    unit="$(px_unit_name "$key")"
    svc_create "$unit" "$bin run -c $cfg" "PX VLESS-Reality (Xray-core)"
    svc_enable "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "VLESS-Reality 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "安装中止（配置保留在 $cfg）"
    fi
    px_ok "服务已启动：$unit"

    # 先按 comment 删旧规则再放行，重装/重跑不会叠加
    net_fw_deny "$port" tcp "$(pxp_vless_reality_fw_comment)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_vless_reality_fw_comment)" || px_warn "防火墙放行失败，请手动放行 $port/tcp"

    db_set "$key" port "$port"
    db_set "$key" server_name "$sni"
    db_set "$key" dest "$dest"
    db_set "$key" flow "xtls-rprx-vision"
    db_set "$key" version "$ver"
    db_set "$key" created "$(os_now)"
    db_mark_installed "$key"
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    px_hr
    px_ok "VLESS-Reality 安装完成"
    px_kv "服务单元" "$unit"
    px_kv "配置文件" "$cfg"
    px_kv "监听端口" "$port"
    px_kv "UUID" "$uuid"
    px_kv "SNI / dest" "$sni / $dest"
    px_kv "ShortId" "$sid"
    px_kv "公钥 (pbk)" "$pub"
    px_kv "状态" "$(proto_vless_reality_status)"
    printf '\n'
    px_info "分享链接（可导入 v2rayN / NekoBox / Shadowrocket）："
    # 拿不到公网 IP 不该让整个安装报失败，装好后 px --link 还能再取
    proto_vless_reality_link || px_warn "暂时取不到公网 IP，稍后用 px --link vless_reality 查看链接"
    px_warn "REALITY 依赖真实 443 直连，套 CDN 或前置反代会失效"
}

proto_vless_reality_uninstall() {
    local key="vless_reality" unit dir bin port
    px_require_root
    if ! db_has "$key"; then
        px_warn "VLESS-Reality 未安装"
        return 0
    fi
    if [[ "$PX_YES" != "1" ]] && ! px_confirm "确认卸载 VLESS-Reality？" n; then
        px_info "已取消"
        return 0
    fi

    unit="$(px_unit_name "$key")"
    dir="$(px_proto_dir "$key")"
    port="$(db_get "$key" port "443")"

    svc_remove "$unit"
    px_ok "已停止并移除服务：$unit"

    bin="$PX_BIN_DIR/xray"
    if [[ "$PX_YES" != "1" ]] && px_confirm "同时删除 xray 二进制 $bin ？" n; then
        rm -f "$bin"
        px_ok "已删除 $bin"
    fi

    if [[ -d "$dir" ]]; then
        rm -rf "${dir:?}"
        px_ok "已删除配置目录：$dir"
    fi

    net_fw_deny "$port" tcp "$(pxp_vless_reality_fw_comment)" || px_warn "撤销防火墙规则失败，请手动检查 $port/tcp"
    db_del "$key"
    db_unmark_installed "$key"
    px_ok "VLESS-Reality 已卸载"
}

proto_vless_reality_status() {
    local key="vless_reality" unit port st pid
    if ! db_has "$key"; then
        printf '未安装\n'
        return 0
    fi
    unit="$(px_unit_name "$key")"
    port="$(db_get "$key" port "?")"
    st="$(svc_status "$unit")"
    case "$st" in
        active)
            pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
            printf '运行中 pid=%s port=%s\n' "${pid:-?}" "$port"
            ;;
        not-found) printf '已停止（unit 缺失）\n' ;;
        *)         printf '已停止\n' ;;
    esac
}

proto_vless_reality_link() {
    local key="vless_reality" uuid ip port sni sid pub name
    if ! db_has "$key"; then
        px_err "VLESS-Reality 未安装"
        return 1
    fi
    uuid="$(db_get "$key" uuid "")"
    port="$(db_get "$key" port "443")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    if [[ -z "$uuid" || -z "$sid" || -z "$pub" ]]; then
        px_err "状态库缺少 uuid / short_id / public_key，请重新安装"
        return 1
    fi
    ip="$(pxp_vless_reality_ip)"
    [[ -z "$ip" ]] && {
        px_err "无法获取服务器公网 IP（可执行 px --check-ip 后重试）"
        return 1
    }
    [[ "$ip" == *:* ]] && ip="[$ip]"
    name="${PX_PROTO_TITLE[$key]:-VLESS-Reality}"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$name"
}

proto_vless_reality_regen() {
    local key="vless_reality" port uuid priv pub sni sid dest cfg unit bin
    px_require_root
    if ! db_has "$key"; then
        px_die "VLESS-Reality 未安装，无法重生成配置"
    fi
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    priv="$(db_get "$key" private_key "")"
    pub="$(db_get "$key" public_key "")"
    sni="$(db_get "$key" server_name "")"
    sid="$(db_get "$key" short_id "")"
    dest="$(db_get "$key" dest "")"

    local missing=""
    [[ -z "$port" ]] && missing+=" port"
    [[ -z "$uuid" ]] && missing+=" uuid"
    [[ -z "$priv" ]] && missing+=" private_key"
    [[ -z "$pub" ]] && missing+=" public_key"
    [[ -z "$sni" ]] && missing+=" server_name"
    [[ -z "$sid" ]] && missing+=" short_id"
    [[ -z "$dest" ]] && missing+=" dest"
    [[ -n "$missing" ]] && px_die "状态库缺少字段：${missing# }（请重新安装）"

    bin="$PX_BIN_DIR/xray"
    [[ -x "$bin" ]] || px_die "缺少 $bin，请重新安装"

    local dir staging
    dir="$(px_proto_dir "$key")"
    cfg="$dir/config.json"
    staging="${cfg}.new"
    # 先写 staging 再自检：校验不过时在线配置原封不动，服务继续用旧配置跑
    if ! pxp_vless_reality_cfg_write "$port" "$uuid" "$priv" "$sni" "$sid" "$dest" "$staging" >/dev/null; then
        rm -f "$staging"
        px_die "写入配置失败"
    fi
    if ! "$bin" run -test -c "$staging" >/dev/null 2>&1; then
        "$bin" run -test -c "$staging" 2>&1 | tail -n 20 >&2
        rm -f "$staging"
        px_die "新配置自检失败，已保留旧配置（请检查状态库字段）"
    fi
    mv -f "$staging" "$cfg" || px_die "替换配置失败：$cfg"
    chmod 600 "$cfg" 2>/dev/null || true

    unit="$(px_unit_name "$key")"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "重启失败，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "配置已重写但服务未起来，请检查日志"
    fi
    net_fw_deny "$port" tcp "$(pxp_vless_reality_fw_comment)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_vless_reality_fw_comment)" >/dev/null 2>&1 || true
    px_ok "配置已重写并重启：$cfg"
    proto_vless_reality_status
}

proto_vless_reality_clash() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        px_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(pxp_vless_reality_ip)"
    port="$(db_get "$key" port "443")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${PX_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    printf '  - name: "%s"\n' "$name"
    printf '    type: vless\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    uuid: %s\n' "$uuid"
    printf '    network: tcp\n'
    printf '    tls: true\n'
    printf '    udp: true\n'
    printf '    flow: xtls-rprx-vision\n'
    printf '    servername: %s\n' "$sni"
    printf '    reality-opts:\n'
    printf '      public-key: %s\n' "$pub"
    printf '      short-id: %s\n' "$sid"
    printf '    client-fingerprint: chrome\n'
}

proto_vless_reality_surge() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        px_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(pxp_vless_reality_ip)"
    port="$(db_get "$key" port "443")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${PX_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    # Surge 的 VLESS 行：username 即 uuid；REALITY 用 reality=true + public-key/short-id
    printf '%s = vless, %s, %s, username=%s, tls=true, sni=%s, reality=true, public-key=%s, short-id=%s, flow=xtls-rprx-vision, skip-cert-verify=true\n' \
        "$name" "$ip" "$port" "$uuid" "$sni" "$pub" "$sid"
}

proto_vless_reality_singbox() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        px_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(pxp_vless_reality_ip)"
    port="$(db_get "$key" port "443")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${PX_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    jq -c -n \
        --arg tag "$name" \
        --arg server "$ip" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg pbk "$pub" \
        --arg sid "$sid" \
        '{
            type: "vless",
            tag: $tag,
            server: $server,
            server_port: $port,
            uuid: $uuid,
            flow: "xtls-rprx-vision",
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {enabled: true, public_key: $pbk, short_id: $sid},
                utls: {enabled: true, fingerprint: "chrome"}
            }
        }'
}

# ===== src/proto/hysteria2.sh =====
# ============================================================
# proto/hysteria2.sh —— Hysteria2（apernet/hysteria v2 官方二进制）
# 对外：proto_hysteria2_meta/install/uninstall/status/link/regen/clash/surge/singbox
# 内部辅助函数：见下方定义（私有前缀 pxp）
# 说明：本文件是 build.sh 拼接的单文件片段，不写 shebang、不 source、不 set -e
# ============================================================

# ---------- 内部辅助 ----------

pxp_hy2_dir() {
    px_proto_dir hysteria2
}

pxp_hy2_cfg() {
    printf '%s/config.yaml' "$(px_proto_dir hysteria2)"
}

pxp_hy2_default_port() {
    local port
    port="$(db_get hysteria2 port "")"
    printf '%s' "${port:-8443}"
}

pxp_hy2_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    (( n >= 1 && n <= 65535 ))
}

# 端口段校验，合法则归一化为 "start-end"
pxp_hy2_hop_ok() {
    local start="${1:-}" end="${2:-}"
    pxp_hy2_port_ok "$start" || return 1
    pxp_hy2_port_ok "$end" || return 1
    start=$((10#$start))
    end=$((10#$end))
    (( start < end )) || return 1
    printf '%s-%s' "$start" "$end"
}

# 上游资产架构别名：amd64/arm64/arm(armv7l)/386
pxp_hy2_arch() {
    case "${PX_ARCH:-}" in
        amd64|arm64) printf '%s' "$PX_ARCH" ;;
        armv7l) printf 'arm' ;;
        i386) printf '386' ;;
        *) return 1 ;;
    esac
}

# 下载结果必须是 ELF（镜像/代理常返回 HTML 错误页）
pxp_hy2_check_elf() {
    local f="${1:-}" magic
    [[ -f "$f" ]] || return 1
    magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]]
}

pxp_hy2_yaml_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# 取 latest 失败时让用户手输版本标签（dl_gh 的 latest 依赖 GitHub API）
pxp_hy2_fetch_bin() {
    local out="${1:-}" arch asset tag
    arch="$(pxp_hy2_arch)" || return 1
    asset="hysteria-linux-${arch}"
    if dl_gh apernet/hysteria latest "$asset" "$out"; then
        return 0
    fi
    px_warn "直接从 GitHub 获取最新版失败（网络或 API 受限）"
    tag="$(px_ask "请手动输入 Hysteria 版本标签（例如 app/v2.13.0）" "app/v2.13.0")"
    [[ -n "$tag" ]] || return 1
    dl_fetch "https://github.com/apernet/hysteria/releases/download/${tag}/${asset}" "$out"
}

# 写服务端 YAML（/etc/px/hysteria2/config.yaml，600）；内容无变化时不重写
pxp_hy2_write_config() {
    local port="$1" pw="$2" cert="$3" key="$4" obfs="$5" obfs_pw="$6"
    local dir cfg tmp epw eopw
    dir="$(pxp_hy2_dir)"
    cfg="$(pxp_hy2_cfg)"
    epw="$(pxp_hy2_yaml_escape "$pw")"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    {
        cat <<EOF
listen: :${port}

auth:
  type: password
  password: "${epw}"

tls:
  cert: ${cert}
  key: ${key}
EOF
        if [[ "$obfs" == "salamander" ]]; then
            eopw="$(pxp_hy2_yaml_escape "$obfs_pw")"
            cat <<EOF

obfs:
  type: salamander
  salamander:
    password: "${eopw}"
EOF
        fi
        cat <<EOF

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        chmod 600 "$cfg" 2>/dev/null || true
        return 0
    fi
    mv -f -- "$tmp" "$cfg" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$cfg" 2>/dev/null || true
}

pxp_hy2_write_unit() {
    svc_create "$(px_unit_name hysteria2)" \
        "${PX_BIN_DIR}/hysteria server -c $(pxp_hy2_cfg)" \
        "PX Hysteria2"
}

# 对外 IP：优先 db 里缓存的 settings.ip，避免每次外联探测
pxp_hy2_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "${ip:-0.0.0.0}"
}

# 自签证书才跳过校验；acme/existing 为真实证书
pxp_hy2_insecure() {
    if [[ "$(db_get hysteria2 tls_mode self)" == "self" ]]; then
        printf '1'
    else
        printf '0'
    fi
}

pxp_hy2_name() {
    printf '%s' "${PX_PROTO_TITLE[hysteria2]:-Hysteria2}"
}

# ---------- SPEC §10 契约函数 ----------

proto_hysteria2_meta() {
    printf 'title=%s\n' "$(pxp_hy2_name)"
    printf 'desc=UDP/QUIC 高丢包抗性协议，支持 salamander 混淆与端口跳跃\n'
    printf 'port=%s\n' "$(pxp_hy2_default_port)"
    printf 'udp=yes\n'
    printf 'cert=yes\n'
}

proto_hysteria2_install() {
    local unit port defport mode sni_hint crt_file key_file sni pw obfs obfs_pw
    local hop hop_start hop_end pubip tmpbin arch

    px_require_root
    [[ -n "${PX_ARCH:-}" ]] || os_detect

    # 1. 判重
    if db_has hysteria2; then
        if [[ "${PX_YES:-0}" == "1" ]]; then
            px_die "Hysteria2 已安装；非交互模式不覆盖，请先卸载后重装"
        fi
        px_confirm "Hysteria2 已安装，是否重新安装（覆盖配置）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    # 2. 依赖与二进制
    arch="$(pxp_hy2_arch)" || px_die "Hysteria2 不支持当前架构：${PX_ARCH:-未知}（支持 amd64/arm64/armv7l/i386）"
    os_dep_install base || px_die "基础依赖安装失败，无法继续"

    px_info "下载 Hysteria2 官方二进制（apernet/hysteria，linux-${arch}）..."
    tmpbin="$(mktemp)" || px_die "无法创建临时文件"
    if ! pxp_hy2_fetch_bin "$tmpbin"; then
        rm -f -- "$tmpbin"
        px_die "Hysteria2 下载失败；请检查网络或在菜单「系统工具」里设置 GitHub 镜像后重试"
    fi
    if ! pxp_hy2_check_elf "$tmpbin"; then
        rm -f -- "$tmpbin"
        px_die "下载内容不是有效 ELF 二进制（可能是镜像返回了错误页），请更换镜像重试"
    fi
    cp -f -- "$tmpbin" "${PX_BIN_DIR}/hysteria" || {
        rm -f -- "$tmpbin"
        px_die "写入 ${PX_BIN_DIR}/hysteria 失败"
    }
    chmod 755 "${PX_BIN_DIR}/hysteria"
    rm -f -- "$tmpbin"
    px_ok "二进制已安装：${PX_BIN_DIR}/hysteria"

    # 3. 端口（UDP）
    defport="$(pxp_hy2_default_port)"
    port="${PX_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(px_ask "Hysteria2 监听端口（UDP）" "$defport")"
    fi
    pxp_hy2_port_ok "$port" || px_die "端口无效：${port:-空}（需 1-65535）"
    port=$((10#$port))
    if net_port_in_use "$port" udp; then
        px_die "UDP 端口 ${port} 已被占用；建议改用空闲端口：$(net_port_pick 8443 udp)"
    fi

    # 4. 证书（先拿证书，失败不写半截配置）
    mode="${PX_ARG_CERT_MODE:-}"
    if [[ -z "$mode" ]]; then
        mode="$(px_ask "证书方式（self=自签 / acme=域名申请 / existing=已有证书）" self)"
    fi
    case "$mode" in
        self|acme|existing) ;;
        *) px_die "无效的证书方式：${mode}（可选 self/acme/existing）" ;;
    esac
    sni_hint="${PX_ARG_SNI:-${PX_ARG_DOMAIN:-bing.com}}"
    px_info "准备证书（方式：${mode}，SNI 提示：${sni_hint}）..."
    if ! cert_ensure "$sni_hint" "$mode"; then
        px_die "证书准备失败，安装已中止（未写入任何配置）"
    fi
    crt_file="${CERT_PATH:-}"
    key_file="${KEY_PATH:-}"
    sni="${SNI:-$sni_hint}"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        px_die "证书文件缺失（cert=${crt_file:-空} key=${key_file:-空}），安装已中止"
    fi
    px_ok "证书就绪：${crt_file}（SNI=${sni}）"

    # 5. 凭据
    pw="$(os_random_token 16)"
    if [[ ${#pw} -lt 16 ]]; then
        pw="$(os_random_hex 16)"
    fi
    [[ -n "$pw" ]] || px_die "随机密码生成失败"

    obfs="off"
    obfs_pw=""
    if px_confirm "是否启用 salamander 混淆（obfs，抗主动探测，推荐）？" n; then
        obfs="salamander"
        obfs_pw="$(os_random_token 16)"
        if [[ ${#obfs_pw} -lt 16 ]]; then
            obfs_pw="$(os_random_hex 16)"
        fi
    fi

    hop=""
    if px_confirm "是否启用端口跳跃（UDP 端口段 DNAT 到主端口，可缓解 QoS 封锁）？" n; then
        local hs he
        hs="$(px_ask "端口段起始" 20000)"
        he="$(px_ask "端口段结束" 30000)"
        hop="$(pxp_hy2_hop_ok "$hs" "$he" || true)"
        if [[ -z "$hop" ]]; then
            px_warn "端口段无效（需 1-65535 且起始 < 结束），已跳过端口跳跃"
        fi
    fi

    # 6. 写配置
    pxp_hy2_write_config "$port" "$pw" "$crt_file" "$key_file" "$obfs" "$obfs_pw" ||
        px_die "写入配置失败：$(pxp_hy2_cfg)"
    px_ok "配置已写入：$(pxp_hy2_cfg)"

    # 7. 服务
    unit="$(px_unit_name hysteria2)"
    pxp_hy2_write_unit
    svc_enable "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "Hysteria2 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "服务未能启动；请检查证书路径、UDP ${port} 是否被占用后重试"
    fi
    px_ok "服务已启动：${unit}"

    # 8. 防火墙与端口跳跃（先撤后加，保证重复执行不叠加规则）
    net_fw_deny "$port" udp "px-hysteria2" >/dev/null 2>&1 || true
    net_fw_allow "$port" udp "px-hysteria2" >/dev/null 2>&1 || px_warn "防火墙放行 UDP ${port} 失败，请手动检查"
    net_nat_hop_del hy2 >/dev/null 2>&1 || true
    if [[ -n "$hop" ]]; then
        hop_start="${hop%%-*}"
        hop_end="${hop##*-}"
        if net_nat_hop_add hy2 "$hop_start" "$hop_end" "$port" >/dev/null 2>&1; then
            px_ok "端口跳跃已启用：UDP ${hop} → ${port}"
        else
            px_warn "端口跳跃规则添加失败，已回退为单端口模式"
            hop=""
        fi
    fi

    # 9. 落库
    db_set hysteria2 port "$port"
    db_set hysteria2 password "$pw"
    db_set hysteria2 sni "$sni"
    db_set hysteria2 tls_mode "$mode"
    db_set hysteria2 tls_cert "$crt_file"
    db_set hysteria2 tls_key "$key_file"
    db_set hysteria2 obfs "$obfs"
    db_set hysteria2 obfs_password "$obfs_pw"
    db_set hysteria2 hop "$hop"
    db_set hysteria2 created "$(os_now)"
    db_mark_installed hysteria2
    pubip="$(net_primary_ip)"
    [[ -n "$pubip" ]] && db_setting ip "$pubip"

    # 10. 收尾
    px_ok "Hysteria2 安装完成"
    if [[ "${PX_YES:-0}" == "1" ]]; then
        proto_hysteria2_link
        return 0
    fi
    px_hr
    px_kv "协议" "Hysteria2（QUIC/UDP）"
    px_kv "端口(UDP)" "${port}"
    px_kv "密码" "${pw}"
    px_kv "SNI" "${sni}"
    px_kv "证书方式" "${mode}"
    if [[ "$obfs" == "salamander" ]]; then
        px_kv "混淆" "salamander（已启用）"
        px_kv "混淆密码" "${obfs_pw}"
    else
        px_kv "混淆" "未启用"
    fi
    if [[ -n "$hop" ]]; then
        px_kv "端口跳跃" "UDP ${hop}"
    else
        px_kv "端口跳跃" "未启用"
    fi
    px_kv "服务状态" "$(proto_hysteria2_status | head -1)"
    px_hr
    px_info "分享链接（URI，可直接导入客户端）："
    proto_hysteria2_link
}

proto_hysteria2_uninstall() {
    local unit port dir
    px_require_root
    unit="$(px_unit_name hysteria2)"
    if ! db_is_installed hysteria2 && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        px_warn "Hysteria2 未安装"
        return 0
    fi
    px_confirm "确认卸载 Hysteria2（停止服务、删除配置与防火墙规则）？" y || {
        px_info "已取消"
        return 0
    }
    port="$(db_get hysteria2 port "")"
    svc_remove "$unit"
    if [[ -n "$port" ]]; then
        net_fw_deny "$port" udp "px-hysteria2" >/dev/null 2>&1 || px_warn "撤销防火墙规则失败，请手动检查"
    fi
    net_nat_hop_del hy2 >/dev/null 2>&1 || true
    dir="$(pxp_hy2_dir)"
    if [[ -n "$dir" && "$dir" == "${PX_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
    fi
    if px_confirm "同时删除二进制 ${PX_BIN_DIR}/hysteria？" n; then
        rm -f -- "${PX_BIN_DIR}/hysteria"
    fi
    db_unmark_installed hysteria2
    db_del hysteria2
    px_ok "Hysteria2 已卸载（证书保留在 ${PX_CERT_DIR}，可复用）"
}

proto_hysteria2_status() {
    local unit port pid
    unit="$(px_unit_name hysteria2)"
    if ! db_is_installed hysteria2 && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get hysteria2 port '-')"
    if svc_is_active "$unit"; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "${port:-0}"
        return 0
    fi
    if [[ "$(svc_status "$unit")" == "failed" ]]; then
        printf '已停止（failed）\n'
    else
        printf '已停止\n'
    fi
}

proto_hysteria2_link() {
    local pw port sni mode obfs obfs_pw hop ip host q
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    mode="$(db_get hysteria2 tls_mode self)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    ip="$(pxp_hy2_ip)"
    host="$ip"
    [[ "$ip" == *:* ]] && host="[${ip}]"
    q="sni=${sni}"
    if [[ "$mode" == "self" ]]; then
        q+="&insecure=1"
    fi
    if [[ "$obfs" == "salamander" && -n "$obfs_pw" ]]; then
        q+="&obfs=salamander&obfs-password=${obfs_pw}"
    fi
    if [[ -n "$hop" ]]; then
        q+="&mport=${hop}"
    fi
    printf 'hysteria2://%s@%s:%s/?%s#%s\n' "$pw" "$host" "$port" "$q" "$(pxp_hy2_name)"
}

proto_hysteria2_regen() {
    local unit port pw sni crt_file key_file obfs obfs_pw hop hop_start hop_end
    px_require_root
    if ! db_is_installed hysteria2; then
        px_die "Hysteria2 未安装，无法重生成配置"
    fi
    port="$(db_get hysteria2 port "")"
    pw="$(db_get hysteria2 password "")"
    sni="$(db_get hysteria2 sni bing.com)"
    crt_file="$(db_get hysteria2 tls_cert "")"
    key_file="$(db_get hysteria2 tls_key "")"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"

    pxp_hy2_port_ok "$port" || px_die "数据库中的端口无效：${port:-空}"
    [[ -n "$pw" ]] || px_die "数据库中的密码为空，请重新安装"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        px_die "数据库记录的证书不存在（cert=${crt_file:-空} key=${key_file:-空}），请重新安装以重新签发"
    fi
    [[ "$obfs" == "salamander" ]] || obfs="off"

    pxp_hy2_write_config "$port" "$pw" "$crt_file" "$key_file" "$obfs" "$obfs_pw" ||
        px_die "写入配置失败：$(pxp_hy2_cfg)"
    pxp_hy2_write_unit
    unit="$(px_unit_name hysteria2)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "配置重生成后启动失败"
    fi

    # 端口可能变了：端口跳跃的 DNAT 目标要跟着更新
    net_nat_hop_del hy2 >/dev/null 2>&1 || true
    if [[ -n "$hop" ]]; then
        hop_start="${hop%%-*}"
        hop_end="${hop##*-}"
        net_nat_hop_add hy2 "$hop_start" "$hop_end" "$port" >/dev/null 2>&1 ||
            px_warn "端口跳跃规则刷新失败，请重新执行安装以修复"
    fi
    px_ok "配置已重生成并重启：$(pxp_hy2_cfg)"
}

proto_hysteria2_clash() {
    local pw port sni obfs obfs_pw hop ip
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    ip="$(pxp_hy2_ip)"

    printf '  - name: "%s"\n' "$(pxp_hy2_name)"
    printf '    type: hysteria2\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    password: "%s"\n' "$pw"
    printf '    sni: "%s"\n' "$sni"
    if [[ "$(pxp_hy2_insecure)" == "1" ]]; then
        printf '    skip-cert-verify: true\n'
    fi
    if [[ "$obfs" == "salamander" && -n "$obfs_pw" ]]; then
        printf '    obfs: salamander\n'
        printf '    obfs-password: "%s"\n' "$obfs_pw"
    fi
    if [[ -n "$hop" ]]; then
        printf '    ports: %s\n' "$hop"
    fi
}

proto_hysteria2_surge() {
    local pw port sni line
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    line="$(pxp_hy2_name) = hysteria2, $(pxp_hy2_ip), ${port}, password=${pw}, sni=${sni}"
    if [[ "$(pxp_hy2_insecure)" == "1" ]]; then
        line+=", skip-cert-verify=true"
    fi
    printf '%s\n' "$line"
}

proto_hysteria2_singbox() {
    local pw port sni obfs obfs_pw hop hop_ports ins
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    ins="$(pxp_hy2_insecure)"
    hop_ports=""
    if [[ -n "$hop" ]]; then
        hop_ports="${hop/-/:}"
    fi

    jq -n \
        --argjson port "$port" --arg server "$(pxp_hy2_ip)" --arg pw "$pw" \
        --arg sni "$sni" --argjson insecure "$ins" \
        --arg obfs "$obfs" --arg obfs_pw "$obfs_pw" --arg hop_ports "$hop_ports" '
        {
            type: "hysteria2",
            tag: "px-hysteria2",
            server: $server,
            server_port: $port,
            password: $pw
        }
        + (if $obfs == "salamander" and $obfs_pw != "" then
              {obfs: {type: "salamander", password: $obfs_pw}}
           else {} end)
        + (if $hop_ports != "" then {server_ports: [$hop_ports]} else {} end)
        + {tls: ({enabled: true, server_name: $sni}
                 + (if $insecure == 1 then {insecure: true} else {} end))}
    '
}

# ===== src/proto/snell.sh =====
# ============================================================
# proto/snell.sh —— Snell v6（NSSurge 官方 snell-server）
# 对外：proto_snell_meta / install / uninstall / status / link / regen / clash / surge / singbox
# 内部辅助：pxp_snell_*（本文件私有；build.sh 拼接时不允许与之重名）
#
# 版本：上游 snell.sh 内置的是 6.0.0rc2；dl.nssurge.com 上 6.0.0 正式版早已发布，
#       这里固定装正式版——rc 版的协议/配置行为官方不承诺，不适合当长期安装源。
# 架构：官方 v6.0.0 只发 amd64 / aarch64 / i386 三个包（armv7l 实测 HTTP 404），
#       所以 armv7l 直接报错，不拼一个必然 404 的地址让用户等下载重试耗尽。
#
# v6 配置事实（对 6.0.0 二进制的 strings 静态核对，不是凭记忆）：
#   [snell-server] 只认 listen / psk / mode / dns / dns-ip-preference /
#   egress-interface / ipv6（已标 deprecated）；整个二进制里没有 obfs、也没有 tfo 字样。
#   即 v6 用 mode(default|unshaped|unsafe-raw) 取代了 v4 的 obfs，写 obfs = off 是
#   "无害但无效"的遗留项。故本文件不写 obfs 键、不做 obfs 交互。
#   psk 官方要求 12–255 字节；上游脚本按 16–255 校验，这里沿用更严的 16 下限。
#
# 监听只写 0.0.0.0：v6 支持逗号分隔多地址，但 [::] 在无 IPv6 栈的机器上会导致
# 启动失败；ipv6 键已 deprecated，保留成注释行，需要时用户自己打开。
# ============================================================

# 固定版本（升级只改这一处；同时用于下载 URL 与 db.version）
PX_SNELL_VER="${PX_SNELL_VER:-6.0.0}"

# 默认端口：Snell 上游习惯 2345，保持一致，客户端模板不用改
PX_SNELL_DEFAULT_PORT="${PX_SNELL_DEFAULT_PORT:-2345}"

# ---------- 内部辅助 ----------

# PX_ARCH -> dl.nssurge.com 的架构段。注意上游叫 aarch64，而 PX_ARCH 叫 arm64
pxp_snell_dl_arch() {
    case "${1:-}" in
        amd64)  printf 'amd64' ;;
        arm64)  printf 'aarch64' ;;
        i386)   printf 'i386' ;;
        armv7l) px_err "Snell v6.0.0 官方未提供 armv7l 构建（只有 v4/v5 有）；请改用 amd64/arm64 或跳过本协议" ;;
        *)      px_err "Snell 不支持当前架构：${1:-未知}" ;;
    esac
}

pxp_snell_name() {
    printf '%s' "${PX_PROTO_TITLE[snell]:-Snell v6}"
}

pxp_snell_dir() {
    px_proto_dir snell
}

pxp_snell_cfg() {
    printf '%s/snell-server.conf' "$(pxp_snell_dir)"
}

pxp_snell_bin() {
    printf '%s/snell-server' "$PX_BIN_DIR"
}

pxp_snell_unit() {
    px_unit_name snell
}

# 防火墙规则 tag：与 99-menu.sh 的 "px-$key" 完全一致，
# 这样菜单改端口时放的规则和本文件撤销的规则能对上，不会各留一份。
pxp_snell_tag() {
    printf 'px-snell'
}

# 默认端口：状态库已有值就沿用（重装/改端口后再装都保持同一个入口）
pxp_snell_default_port() {
    local port
    port="$(db_get snell port "")"
    printf '%s' "${port:-$PX_SNELL_DEFAULT_PORT}"
}

pxp_snell_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    ((n >= 1 && n <= 65535))
}

# 端口协商：PX_ARG_PORT > 状态库/meta 默认 > 交互；占用时报错并给候选端口。
# 重装且端口等于旧端口时跳过占用检查：那个监听是我们自己，稍后会被 stop 掉。
pxp_snell_ask_port() {
    local def old port alt
    def="$(pxp_snell_default_port)"
    old="$(db_get snell port "")"
    port="${PX_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(px_ask "Snell 监听端口（TCP）" "$def")"
    fi
    port="${port//[[:space:]]/}"
    pxp_snell_port_ok "$port" || {
        px_err "端口不合法：${port:-空}（应为 1-65535 的整数）"
        return 1
    }
    if [[ "$port" != "$old" ]] && net_port_in_use "$port" tcp; then
        alt="$(net_port_pick "$PX_SNELL_DEFAULT_PORT" tcp || true)"
        px_err "端口 $port/tcp 已被占用；可改用空闲端口，例如 --port ${alt:-8443}"
        return 1
    fi
    printf '%s' "$port"
}

# PSK：重装沿用状态库旧值（客户端不用重新导入），只有坏值才重新生成
pxp_snell_psk() {
    local psk
    psk="$(db_get snell psk "")"
    if [[ "$psk" =~ ^[^[:space:]]{16,255}$ ]]; then
        printf '%s' "$psk"
        return 0
    fi
    psk="$(os_random_token 20)"
    [[ ${#psk} -ge 16 ]] || return 1
    printf '%s' "$psk"
}

# 写配置：600；先写临时文件再原子替换，中断不会留下半截配置
pxp_snell_write_config() {
    local port="$1" psk="$2" dir cfg tmp
    dir="$(pxp_snell_dir)"
    cfg="$(pxp_snell_cfg)"
    mkdir -p "$dir" || {
        px_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    {
        printf '# PX 生成；改动后执行 px --regen snell 让服务重载\n'
        printf '[snell-server]\n'
        printf 'listen = 0.0.0.0:%s\n' "$port"
        printf 'psk = %s\n' "$psk"
        printf 'mode = default\n'
        printf 'dns-ip-preference = default\n'
        printf '# ipv6 = false\n'
    } > "$tmp" || {
        rm -f -- "$tmp"
        px_err "写入配置失败：$cfg"
        return 1
    }
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        px_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 从已有配置里读监听端口（重装/改端口时用来撤掉旧端口规则，避免规则越积越多）
pxp_snell_cfg_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$cfg" | head -n1
}

pxp_snell_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "$ip"
}

# 主机名片段：IPv6 必须加方括号才能拼进 URI/Surge 行
pxp_snell_host() {
    local ip
    ip="$(pxp_snell_ip)"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '%s' "$ip"
}

# ---------- SPEC §10 契约函数 ----------

proto_snell_meta() {
    printf 'title=%s\n' "$(pxp_snell_name)"
    printf 'desc=Snell v6 单端口 TCP，抗主动探测强；v6 用 mode 取代 obfs\n'
    printf 'port=%s\n' "$(pxp_snell_default_port)"
    printf 'udp=no\n'
    printf 'cert=no\n'
}

proto_snell_install() {
    local unit bin cfg port psk ver arch asset url tmp cur old_port ip

    px_require_root
    [[ -n "${PX_ARCH:-}" ]] || os_detect

    # 1. 判重：状态库里有记录就要求确认（PX_YES=1 直接失败，避免脚本化误覆盖）
    if db_has snell; then
        if [[ "${PX_YES:-0}" == "1" ]]; then
            px_die "Snell v6 已安装；非交互模式不覆盖，请先卸载（px --uninstall snell --yes）"
        fi
        px_confirm "Snell v6 已安装，是否重新安装（覆盖配置）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    px_title "安装 Snell v6"

    # 2. 依赖：Snell 是 zip 包，base 里的 unzip 已够用（dl_unzip 还会兜底安装）
    os_dep_install base || px_die "基础依赖安装失败，无法继续"

    arch="$(pxp_snell_dl_arch "${PX_ARCH:-}")" || return 1
    bin="$(pxp_snell_bin)"
    ver=""
    # 已装同主版本的二进制就复用，省一次 10MB 下载；主版本不是 6（比如上游脚本装的 v4）必须覆盖，
    # 否则配置里的 mode 会被老版本当成未知键，链接声称 v6 实际却是 v4。
    if [[ -x "$bin" ]]; then
        cur="$("$bin" --version 2>/dev/null | head -n1 || true)"
        cur="$(printf '%s' "$cur" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
        if [[ "${cur%%.*}" == "6" ]]; then
            ver="$cur"
            px_ok "复用已安装的 snell-server ${cur}：$bin"
        elif [[ -n "$cur" ]]; then
            px_warn "已有 snell-server ${cur} 不是 v6，将覆盖为 v${PX_SNELL_VER}"
        fi
    fi
    if [[ -z "$ver" ]]; then
        asset="snell-server-v${PX_SNELL_VER}-linux-${arch}.zip"
        url="https://dl.nssurge.com/snell/${asset}"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/px-snell.XXXXXX")" || px_die "创建临时目录失败"
        px_info "下载 Snell v${PX_SNELL_VER}（linux-${arch}）..."
        if ! dl_fetch "$url" "$tmp/snell.zip"; then
            rm -rf -- "$tmp"
            px_die "Snell 下载失败（dl.nssurge.com 可能限流或不可达）；可稍后重试或手动放到 $bin"
        fi
        if ! dl_unzip "$tmp/snell.zip" "$tmp/x"; then
            rm -rf -- "$tmp"
            px_die "Snell 压缩包解压失败"
        fi
        if [[ ! -f "$tmp/x/snell-server" ]]; then
            rm -rf -- "$tmp"
            px_die "压缩包内未找到 snell-server"
        fi
        if ! install -m 755 "$tmp/x/snell-server" "$bin"; then
            rm -rf -- "$tmp"
            px_die "安装 snell-server 到 $bin 失败"
        fi
        rm -rf -- "$tmp"
        if ! "$bin" --version >/dev/null 2>&1; then
            # 这里不直接判死：静态 Go 二进制正常都能跑，真跑不起来时下面的启动校验
            # 会带着 journalctl 日志报错，比这里一句话更好排查。
            px_warn "snell-server 版本自检失败（继续，启动阶段会暴露真实原因）"
        fi
        ver="$PX_SNELL_VER"
        px_ok "snell-server v${ver} 已安装：$bin"
    fi

    # 3. 上次安装中断可能留下 unit 而状态库没有记录：先清掉，
    #    否则下面的端口占用检查会把自己上一次的监听当成别人的端口。
    unit="$(pxp_snell_unit)"
    if ! db_has snell && [[ "$(svc_status "$unit")" != "not-found" ]]; then
        px_warn "发现上次安装残留的 systemd 单元 $unit，先清理"
        svc_remove "$unit"
    fi

    # 4. 端口与凭据
    port="$(pxp_snell_ask_port)" || return 1
    psk="$(pxp_snell_psk)" || px_die "生成 PSK 失败（os_random_token / openssl 不可用？）"
    [[ -n "$psk" ]] || px_die "PSK 为空，已中止"

    # 5. 配置（600）。先记下旧配置端口，成功后撤旧端口规则
    cfg="$(pxp_snell_cfg)"
    old_port="$(pxp_snell_cfg_port "$cfg")"
    pxp_snell_write_config "$port" "$psk" || px_die "写入 Snell 配置失败"
    px_ok "配置已写入：$cfg"

    # 6. systemd：重装时先 stop。svc_start 对已运行的服务是空操作，
    #    不先停就会"启动成功"但仍在跑旧配置。
    svc_create "$unit" "$bin -c $cfg" "PX Snell v6 (snell-server)"
    svc_enable "$unit"
    svc_stop "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "Snell 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "安装中止（配置保留在 $cfg，修正后可用 px --regen snell 重试）"
    fi
    px_ok "服务已启动：$unit"

    # 7. 防火墙：Snell 只有 TCP。先按 tag 撤旧规则再放行，重跑不叠加
    net_fw_deny "$port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 ||
        px_warn "防火墙放行 TCP/${port} 失败，请手动检查"
    if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
        net_fw_deny "$old_port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 || true
    fi

    # 8. 状态库：所有字段一次写全，最后才 mark_installed（失败时不会留下"已安装"假象）
    db_set snell port "$port"
    db_set snell psk "$psk"
    db_set snell mode "default"
    db_set snell version "$ver"
    db_set snell created "$(os_now)"
    db_mark_installed snell
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    # 9. 收尾
    px_hr
    px_ok "Snell v6 安装完成"
    px_kv "服务单元" "$unit"
    px_kv "配置文件" "$cfg"
    px_kv "监听端口" "${port}/tcp"
    px_kv "PSK" "$psk"
    px_kv "协议版本" "6（mode=default）"
    px_kv "服务状态" "$(proto_snell_status | head -n1)"
    px_hr
    px_info "分享链接（Surge / sing-box ≥1.14 直接支持 v6；mihomo 目前只到 v5）："
    proto_snell_link || px_warn "暂时取不到公网 IP，稍后可用 px --link snell 查看"
}

proto_snell_uninstall() {
    local unit dir bin port cfg
    px_require_root
    unit="$(pxp_snell_unit)"

    # 状态库没了但 unit 还在（恢复备份/手工删库）也允许卸载，否则残留服务永远清不掉
    if ! db_has snell && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        px_warn "Snell v6 未安装"
        return 0
    fi
    if [[ "${PX_YES:-0}" != "1" ]]; then
        px_confirm "确认卸载 Snell v6（停止服务、删除配置与防火墙规则）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    dir="$(pxp_snell_dir)"
    bin="$(pxp_snell_bin)"
    cfg="$(pxp_snell_cfg)"
    port="$(db_get snell port "")"
    [[ -z "$port" ]] && port="$(pxp_snell_cfg_port "$cfg")"

    svc_remove "$unit"
    px_ok "已停止并移除服务：$unit"
    if [[ -n "$port" ]]; then
        net_fw_deny "$port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 ||
            px_warn "撤销 TCP/${port} 放行失败，请手动检查"
    fi
    # snell-server 只服务本协议，默认一并删除（PX_YES=1 也按默认 yes 删，避免留孤儿可执行文件）
    if px_confirm "同时删除 snell-server 二进制 $bin ？" y; then
        rm -f -- "$bin" && px_ok "已删除 $bin"
    fi
    if [[ -n "$dir" && "$dir" == "${PX_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
        px_ok "已删除配置目录：$dir"
    fi
    db_del snell
    db_unmark_installed snell
    px_ok "Snell v6 已卸载"
}

proto_snell_status() {
    local unit port pid st
    unit="$(pxp_snell_unit)"
    if ! db_has snell && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get snell port '-')"
    st="$(svc_status "$unit")"
    # SPEC 要求状态行只有这三种形态（菜单用 grep 提取"运行中/已停止"），
    # 所以不在这一行附带重建提示，避免上层解析出歧义。
    if [[ "$st" == "active" ]]; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
    else
        printf '已停止\n'
    fi
}

proto_snell_link() {
    local port psk host name
    if ! db_has snell; then
        px_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    [[ -n "$port" && -n "$psk" ]] || {
        px_err "状态库缺少 port/psk，请重新安装"
        return 1
    }
    host="$(pxp_snell_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_snell_name)"
    # 官方没有标准化 URI。这里沿用本项目 gen_snell_link 的形状：PSK 直接放在 userinfo
    # （不做 base64），v6 额外带 mode；片段里的空格编码成 %20，客户端不会截断。
    printf 'snell://%s@%s:%s?version=6&mode=default#%s\n' \
        "$psk" "$host" "$port" "${name// /%20}"
}

proto_snell_regen() {
    local unit bin cfg port psk old_port
    px_require_root
    if ! db_has snell; then
        px_err "Snell v6 未安装，无法重生成配置"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    pxp_snell_port_ok "$port" || {
        px_err "状态库里的端口不合法：${port:-空}（请重新安装）"
        return 1
    }
    [[ "$psk" =~ ^[^[:space:]]{16,255}$ ]] || {
        px_err "状态库里的 PSK 不合法（需 16-255 字节且不含空白），请重新安装或先换凭据"
        return 1
    }
    bin="$(pxp_snell_bin)"
    [[ -x "$bin" ]] || {
        px_err "缺少 $bin，请重新安装"
        return 1
    }

    cfg="$(pxp_snell_cfg)"
    old_port="$(pxp_snell_cfg_port "$cfg")"
    pxp_snell_write_config "$port" "$psk" || {
        px_err "写入配置失败：$cfg"
        return 1
    }

    # 单元文件可能被手工删掉（或从备份恢复的状态库）：regen 顺手重建，
    # 这样菜单里的"改端口/换凭据"在任何情况下都能生效。
    unit="$(pxp_snell_unit)"
    svc_create "$unit" "$bin -c $cfg" "PX Snell v6 (snell-server)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30 >&2
        return 1
    fi

    # 防火墙补齐（菜单改端口只按 meta 放行了一个协议，这里统一对齐）
    net_fw_deny "$port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 || true
    if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
        net_fw_deny "$old_port" tcp "$(pxp_snell_tag)" >/dev/null 2>&1 || true
    fi

    px_ok "配置已重生成并重启：$cfg"
    proto_snell_status | head -n1
    return 0
}

proto_snell_clash() {
    local port psk host name
    if ! db_has snell; then
        px_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(pxp_snell_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_snell_name)"
    # mihomo 只实现到 Snell v1–v5，v6 会被内核拒绝；照实写出 v6 并留一行说明，
    # 等内核支持后删掉注释即可用。现在要用 v6 请走 Surge 或 sing-box。
    printf '  # mihomo 目前仅支持 Snell v1-v5；v6 请用 Surge 或 sing-box >= 1.14\n'
    printf '  - name: "%s"\n' "$name"
    printf '    type: snell\n'
    printf '    server: "%s"\n' "$host"
    printf '    port: %s\n' "$port"
    printf '    psk: "%s"\n' "$psk"
    printf '    version: 6\n'
    printf '    udp: true\n'
}

proto_snell_surge() {
    local port psk host name
    if ! db_has snell; then
        px_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(pxp_snell_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_snell_name)"
    # 形状对齐 vless-server.sh 的 gen_snell_surge_line：v6 必须带 mode，
    # reuse/ecn 是 Surge 侧优化项，对端不支持会自动忽略。
    printf '%s = snell, %s, %s, psk=%s, version=6, mode=default, reuse=true, tfo=true, ecn=true\n' \
        "$name" "$host" "$port" "$psk"
}

proto_snell_singbox() {
    local port psk host name
    if ! db_has snell; then
        px_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(pxp_snell_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_snell_name)"
    # sing-box 自 1.14.0 起支持 Snell v6（outbound/snell：version + mode），
    # 所以这里给合法对象，不需要像 mihomo 那样退回失败。
    jq -c -n \
        --argjson port "$port" \
        --arg server "$host" \
        --arg psk "$psk" \
        --arg tag "$name" \
        '{
            type: "snell",
            tag: $tag,
            server: $server,
            server_port: $port,
            version: 6,
            psk: $psk,
            mode: "default"
        }'
}

# ===== src/proto/ss_rust.sh =====
# ============================================================
# proto/ss_rust.sh —— Shadowsocks-Rust（SS2022 优先）+ 可选 ShadowTLS v3
# 对外：proto_ss_rust_meta / install / uninstall / status / link / regen / clash / surge / singbox
# 内部辅助：pxp_ssrust_*（本文件私有；build.sh 拼接时不允许与之重名）
#
# 选型：用 shadowsocks-rust 官方 release（ssserver），SS2022 优先。
#   SS2022 的密码是"密钥"而不是口令：必须是 base64，解码后 16 字节（aes-128）或
#   32 字节（aes-256 / chacha20-poly1305）。用 openssl rand -base64 生成，
#   菜单里"换凭据"写进来的普通随机串会不兼容——regen 会检测并自动重生。
#
# ShadowTLS v3：可选，安装时询问（默认关）。它借用真实站点的证书完成握手，
#   服务端不需要自己的证书，所以本文件不调用 cert_ensure（证书体系与本协议无关）。
#   客户端连接顺序是 shadow-tls → ssserver，故 unit 起来也是先后端后入口。
#
# 卸载必须 svc_remove：上游 ss-rust.sh 的已知 bug 是只 disable 不删 unit，
#   残留单元会让下次安装的 svc_start 对着旧 ExecStart "假成功"，配置改了也不生效。
# ============================================================

# 下载版本；PX_SSRUST_VER 为空表示取 GitHub 最新，取不到再用下面的已知版本兜底
PX_SSRUST_VER="${PX_SSRUST_VER:-}"
PX_SSRUST_FALLBACK_VER="1.25.0"
PX_SSRUST_STLS_FALLBACK_VER="0.2.25"

# 默认端口：SS-Rust 上游习惯 2525；ShadowTLS 入口用 8443
PX_SSRUST_DEFAULT_PORT="${PX_SSRUST_DEFAULT_PORT:-2525}"
PX_SSRUST_STLS_DEFAULT_PORT="${PX_SSRUST_STLS_DEFAULT_PORT:-8443}"

# 默认方法与兼容退路：默认 SS2022（抗重放、无 IV 复用风险）；老客户端不支持时可选 AEAD
PX_SSRUST_METHOD="${PX_SSRUST_METHOD:-2022-blake3-aes-128-gcm}"
PX_SSRUST_METHOD_COMPAT="chacha20-ietf-poly1305"
# ShadowTLS 伪装 SNI：需可直连的真实 HTTPS 站点
PX_SSRUST_STLS_SNI="${PX_SSRUST_STLS_SNI:-cloudflare.com}"
# ShadowTLS 的 fallback：未通过验证的握手会被转发到这里，看起来就是正常访问
PX_SSRUST_STLS_FALLBACK="cloud.tencent.com:443"

# ---------- 内部辅助 ----------

pxp_ssrust_name() {
    printf '%s' "${PX_PROTO_TITLE[ss_rust]:-SS-Rust}"
}

pxp_ssrust_dir() {
    px_proto_dir ss_rust
}

pxp_ssrust_cfg() {
    printf '%s/config.json' "$(pxp_ssrust_dir)"
}

pxp_ssrust_stls_cfg() {
    printf '%s/shadowtls.json' "$(pxp_ssrust_dir)"
}

pxp_ssrust_bin() {
    printf '%s/ssserver' "$PX_BIN_DIR"
}

pxp_ssrust_stls_bin() {
    printf '%s/shadow-tls' "$PX_BIN_DIR"
}

pxp_ssrust_unit() {
    px_unit_name ss_rust
}

pxp_ssrust_stls_unit() {
    printf '%s' "$(px_unit_name ss_rust)-shadowtls"
}

# 防火墙 tag 与 99-menu.sh 的 "px-$key" 对齐；ShadowTLS 入口另用一个 tag，
# 这样卸载/改端口时能分别精确撤销，不会误删直连端口的规则。
pxp_ssrust_tag() {
    printf 'px-ss_rust'
}

pxp_ssrust_stls_tag() {
    printf 'px-ss_rust-shadowtls'
}

pxp_ssrust_default_port() {
    local port
    port="$(db_get ss_rust port "")"
    printf '%s' "${port:-$PX_SSRUST_DEFAULT_PORT}"
}

pxp_ssrust_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    ((n >= 1 && n <= 65535))
}

# PX_ARCH -> shadowsocks-rust release 的 target 段（glibc 版 tar.xz）
pxp_ssrust_arch() {
    case "${1:-${PX_ARCH:-}}" in
        amd64)  printf 'x86_64-unknown-linux-gnu' ;;
        arm64)  printf 'aarch64-unknown-linux-gnu' ;;
        armv7l) printf 'armv7-unknown-linux-gnueabihf' ;;
        i386)   printf 'i686-unknown-linux-musl' ;;
        *)      px_err "SS-Rust 不支持当前架构：${1:-${PX_ARCH:-未知}}" ;;
    esac
}

# PX_ARCH -> shadow-tls release 的 target 段（musl 静态单文件；无 i386 构建）
pxp_ssrust_stls_arch() {
    case "${1:-${PX_ARCH:-}}" in
        amd64)  printf 'x86_64-unknown-linux-musl' ;;
        arm64)  printf 'aarch64-unknown-linux-musl' ;;
        armv7l) printf 'armv7-unknown-linux-musleabihf' ;;
        i386)   px_err "ShadowTLS 未提供 i386 构建；可用 --no-shadowtls 的安装方式跳过（i386 请选择不启用）" ;;
        *)      px_err "ShadowTLS 不支持当前架构：${1:-${PX_ARCH:-未知}}" ;;
    esac
}

# .tar.xz 解压需要 xz；os_dep_install 的 base 里没有它，这里按发行版补装。
# GNU tar 会自动识别 xz 压缩，但前提是系统里存在 xz 可执行文件。
pxp_ssrust_ensure_xz() {
    command -v xz >/dev/null 2>&1 && return 0
    px_info "安装 xz（解开 .tar.xz 需要）..."
    case "$(os_family)" in
        debian) os_pkg_install xz-utils || return 1 ;;
        rhel)   os_pkg_install xz || return 1 ;;
        *)
            px_err "系统缺少 xz，且未识别的发行版，请手动安装 xz 后重试"
            return 1
            ;;
    esac
    command -v xz >/dev/null 2>&1
}

# 端口协商（TCP 与 UDP 都要，协议本身 tcp_and_udp）：
# PX_ARG_PORT > 状态库/meta 默认 > 交互；占用时报错并给候选端口。
# 重装且端口等于旧端口时跳过检查：那是我们自己的监听，稍后会 stop。
pxp_ssrust_ask_port() {
    local def old port alt proto
    def="$(pxp_ssrust_default_port)"
    old="$(db_get ss_rust port "")"
    port="${PX_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(px_ask "SS-Rust 监听端口（TCP+UDP）" "$def")"
    fi
    port="${port//[[:space:]]/}"
    pxp_ssrust_port_ok "$port" || {
        px_err "端口不合法：${port:-空}（应为 1-65535 的整数）"
        return 1
    }
    if [[ "$port" != "$old" ]]; then
        for proto in tcp udp; do
            if net_port_in_use "$port" "$proto"; then
                alt="$(net_port_pick "$PX_SSRUST_DEFAULT_PORT" "$proto" || true)"
                px_err "端口 $port/$proto 已被占用；可改用空闲端口，例如 --port ${alt:-8443}"
                return 1
            fi
        done
    fi
    printf '%s' "$port"
}

# ShadowTLS 入口端口：默认 8443，重装沿用旧值；必须与 SS 端口不同
pxp_ssrust_ask_stls_port() {
    local ss_port="$1" old port alt
    old="$(db_get ss_rust stls_port "")"
    port="$(px_ask "ShadowTLS 监听端口（TCP）" "${old:-$PX_SSRUST_STLS_DEFAULT_PORT}")"
    port="${port//[[:space:]]/}"
    pxp_ssrust_port_ok "$port" || {
        px_err "端口不合法：${port:-空}"
        return 1
    }
    if [[ "$port" == "$ss_port" ]]; then
        px_err "ShadowTLS 端口不能与 SS-Rust 端口相同（都写 $ss_port）"
        return 1
    fi
    if [[ "$port" != "$old" ]] && net_port_in_use "$port" tcp; then
        alt="$(net_port_pick "$PX_SSRUST_STLS_DEFAULT_PORT" tcp || true)"
        px_err "端口 $port/tcp 已被占用；可改用空闲端口，例如 ${alt:-9443}"
        return 1
    fi
    printf '%s' "$port"
}

# 伪装 SNI：PX_ARG_SNI > 状态库 > cloudflare.com；只做基本域名校验，
# 真正的可用性取决于该站点是否支持 TLS1.3（shadow-tls v3 需要）
pxp_ssrust_ask_sni() {
    local def sni
    def="${PX_ARG_SNI:-$(db_get ss_rust stls_sni "$PX_SSRUST_STLS_SNI")}"
    sni="$(px_ask "ShadowTLS 伪装 SNI（可直连的真实 HTTPS 站点）" "$def")"
    sni="$(printf '%s' "$sni" | tr -d '[:space:]')"
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
        px_err "SNI 不合法：${sni:-空}"
        return 1
    }
    [[ "$sni" == *.* ]] || {
        px_err "SNI 不合法（需要含点的域名）：$sni"
        return 1
    }
    printf '%s' "$sni"
}

# SS2022 的密码是密钥：必须能 base64 解码且长度正好 16/32 字节。
# 其它 AEAD/流密码没有形状要求，非空即可。
pxp_ssrust_pw_ok() {
    local method="$1" pw="${2:-}" n
    case "$method" in
        2022-blake3-aes-128-gcm)
            n="$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
            [[ "$n" == "16" ]]
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            n="$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
            [[ "$n" == "32" ]]
            ;;
        2022-*)
            # 未来新增的 2022 方法不做形状判断，交给 ssserver 启动校验兜底
            [[ -n "$pw" ]]
            ;;
        *)
            [[ -n "$pw" ]]
            ;;
    esac
}

pxp_ssrust_pw_gen() {
    local method="$1" pw=""
    case "$method" in
        2022-blake3-aes-128-gcm)
            pw="$(openssl rand -base64 16 2>/dev/null)"
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            pw="$(openssl rand -base64 32 2>/dev/null)"
            ;;
        *)
            pw="$(os_random_token 24)"
            ;;
    esac
    pw="$(printf '%s' "$pw" | tr -d '\r\n')"
    printf '%s' "$pw"
}

# 方法选择：重装时状态库里的方法仍与密码兼容就沿用（客户端不用改）；
# 否则默认 SS2022，并给老客户端留一条 AEAD 退路。
pxp_ssrust_pick_method() {
    local old_method old_pw method
    old_method="$(db_get ss_rust method "")"
    old_pw="$(db_get ss_rust password "")"
    if [[ -n "$old_method" ]] && pxp_ssrust_pw_ok "$old_method" "$old_pw"; then
        printf '%s' "$old_method"
        return 0
    fi
    method="$PX_SSRUST_METHOD"
    if px_confirm "改用兼容模式 ${PX_SSRUST_METHOD_COMPAT}（老客户端不支持 SS2022 时选是）？" n; then
        method="$PX_SSRUST_METHOD_COMPAT"
    fi
    printf '%s' "$method"
}

# 写主配置：600；先临时文件再原子替换，避免中断留下半截 JSON
pxp_ssrust_write_config() {
    local port="$1" password="$2" method="$3" timeout="${4:-300}" mode="${5:-tcp_and_udp}"
    local dir cfg tmp
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    dir="$(pxp_ssrust_dir)"
    cfg="$(pxp_ssrust_cfg)"
    mkdir -p "$dir" || {
        px_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg method "$method" \
        --arg mode "$mode" \
        --argjson timeout "$timeout" \
        '{
            server: "0.0.0.0",
            server_port: $port,
            password: $password,
            method: $method,
            mode: $mode,
            timeout: $timeout
        }' > "$tmp"; then
        rm -f -- "$tmp"
        px_err "生成 SS-Rust 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        px_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 写 ShadowTLS 配置：JSON 里带密码，600；密码不进 argv，ps 里看不到。
# 结构照上游：v3 客户端先与 dispatch 里的 SNI 握手，未认证流量走 fallback。
pxp_ssrust_write_stls_config() {
    local stls_port="$1" ss_port="$2" sni="$3" password="$4"
    local dir cfg tmp
    dir="$(pxp_ssrust_dir)"
    cfg="$(pxp_ssrust_stls_cfg)"
    mkdir -p "$dir" || {
        px_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson stls_port "$stls_port" \
        --arg ss_addr "127.0.0.1:${ss_port}" \
        --arg sni "${sni}:443" \
        --arg fallback "$PX_SSRUST_STLS_FALLBACK" \
        --arg password "$password" \
        '{
            v3: true,
            strict: true,
            fastopen: false,
            disable_nodelay: false,
            server: {
                listen: ("0.0.0.0:" + ($stls_port | tostring)),
                server_addr: $ss_addr,
                tls_addr: {
                    wildcard_sni: "authed",
                    dispatch: { ($sni): $sni },
                    fallback: $fallback
                },
                password: $password
            }
        }' > "$tmp"; then
        rm -f -- "$tmp"
        px_err "生成 ShadowTLS 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        px_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 从已有配置读端口：重装/改端口时用来撤旧端口规则，避免规则越积越多
pxp_ssrust_cfg_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    jq -r '.server_port // empty' "$cfg" 2>/dev/null
}

pxp_ssrust_cfg_stls_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    jq -r '.server.listen // empty' "$cfg" 2>/dev/null |
        sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1
}

pxp_ssrust_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "$ip"
}

# IPv6 必须加方括号才能拼进 URI/Surge 行
pxp_ssrust_host() {
    local ip
    ip="$(pxp_ssrust_ip)"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '%s' "$ip"
}

# SIP002 userinfo：base64url(method:password) 且去掉 padding。
# SS2022 密钥里会出现 + 和 /，URL-safe 编码才能安全放进 URI。
pxp_ssrust_b64url() {
    printf '%s' "$1" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='
}

# 下载并安装 ssserver。<ver> 由调用方给出（含 v 的 tag 名由本函数自己拼）。
# 不用 dl_gh：它拿 dl_latest_tag 去掉 v 的版本号去拼 /download/<ver>/，会 404。
pxp_ssrust_fetch_ss() {
    local ver="$1" arch bin asset url tmp
    arch="$(pxp_ssrust_arch)" || return 1
    bin="$(pxp_ssrust_bin)"
    asset="shadowsocks-v${ver}.${arch}.tar.xz"
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/${asset}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/px-ssrust.XXXXXX")" || {
        px_err "创建临时目录失败"
        return 1
    }
    px_info "下载 Shadowsocks-Rust v${ver}（${arch}）..."
    if ! dl_fetch "$url" "$tmp/ss.tar.xz"; then
        rm -rf -- "$tmp"
        px_err "Shadowsocks-Rust 下载失败（GitHub 可能不可达）"
        return 1
    fi
    if ! dl_untar "$tmp/ss.tar.xz" "$tmp/x"; then
        rm -rf -- "$tmp"
        px_err "Shadowsocks-Rust 解压失败（xz 不可用？）"
        return 1
    fi
    if [[ ! -f "$tmp/x/ssserver" ]]; then
        rm -rf -- "$tmp"
        px_err "压缩包内未找到 ssserver"
        return 1
    fi
    if ! install -m 755 "$tmp/x/ssserver" "$bin"; then
        rm -rf -- "$tmp"
        px_err "安装 ssserver 到 $bin 失败"
        return 1
    fi
    rm -rf -- "$tmp"
    # 软校验：真跑不起来时下面的启动校验会带着 journalctl 日志报错，这里只提示
    if [[ -z "$("$bin" -h 2>&1 | head -n1 || true)" ]]; then
        px_warn "ssserver 已落盘但自检无输出（架构是否匹配？），继续依赖启动校验"
    fi
}

# 下载并安装 shadow-tls（release 里是单个静态可执行文件，无压缩）
pxp_ssrust_fetch_stls() {
    local ver="$1" tar_arch bin asset url tmp
    tar_arch="$(pxp_ssrust_stls_arch)" || return 1
    bin="$(pxp_ssrust_stls_bin)"
    asset="shadow-tls-${tar_arch}"
    url="https://github.com/ihciah/shadow-tls/releases/download/v${ver}/${asset}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/px-stls.XXXXXX")" || {
        px_err "创建临时目录失败"
        return 1
    }
    px_info "下载 ShadowTLS v${ver}（${tar_arch}）..."
    if ! dl_fetch "$url" "$tmp/shadow-tls"; then
        rm -rf -- "$tmp"
        px_err "ShadowTLS 下载失败（GitHub 可能不可达）"
        return 1
    fi
    if ! install -m 755 "$tmp/shadow-tls" "$bin"; then
        rm -rf -- "$tmp"
        px_err "安装 shadow-tls 到 $bin 失败"
        return 1
    fi
    rm -rf -- "$tmp"
}

# ---------- SPEC §10 契约函数 ----------

proto_ss_rust_meta() {
    printf 'title=%s\n' "$(pxp_ssrust_name)"
    printf 'desc=Shadowsocks-Rust（SS2022 优先，TCP+UDP；可选 ShadowTLS v3 伪装）\n'
    printf 'port=%s\n' "$(pxp_ssrust_default_port)"
    printf 'udp=yes\n'
    printf 'cert=no\n'
}

proto_ss_rust_install() {
    local unit stl_unit bin stbin dir cfg stcfg ver stver
    local port method password timeout mode stls stls_port stls_pw stls_sni
    local old_port old_stls_port ip

    px_require_root
    [[ -n "${PX_ARCH:-}" ]] || os_detect

    # 1. 判重：有记录就要求确认；PX_YES=1 直接失败，避免脚本化误覆盖
    if db_has ss_rust; then
        if [[ "${PX_YES:-0}" == "1" ]]; then
            px_die "SS-Rust 已安装；非交互模式不覆盖，请先卸载（px --uninstall ss_rust --yes）"
        fi
        px_confirm "SS-Rust 已安装，是否重新安装（覆盖配置）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    px_title "安装 SS-Rust"

    unit="$(pxp_ssrust_unit)"
    stl_unit="$(pxp_ssrust_stls_unit)"

    # 2. 上次中断可能留下 unit 而状态库没记录：先清掉，
    #    否则下面端口占用检查会把自己上次的监听当成别人的端口
    if ! db_has ss_rust; then
        if [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
            px_warn "发现残留的 systemd 单元 $stl_unit，先清理"
            svc_remove "$stl_unit"
        fi
        if [[ "$(svc_status "$unit")" != "not-found" ]]; then
            px_warn "发现残留的 systemd 单元 $unit，先清理"
            svc_remove "$unit"
        fi
    fi

    # 3. 依赖：.tar.xz 需要 xz，base 里没有，先补
    os_dep_install base || px_die "基础依赖安装失败，无法继续"
    pxp_ssrust_ensure_xz || px_die "缺少 xz，无法解开 .tar.xz；请手动安装 xz 后重试"
    # 架构先判（ss 与 shadow-tls 的支持面不同，早判早报错）
    pxp_ssrust_arch >/dev/null || return 1

    # 4. 二进制：GitHub 版本取不到就用已知版本兜底并提示；下载失败但本机已有
    #    可执行的 ssserver 才允许沿用（避免悄悄用上不支持的旧版本）
    bin="$(pxp_ssrust_bin)"
    ver="${PX_SSRUST_VER:-}"
    if [[ -z "$ver" ]]; then
        ver="$(dl_latest_tag shadowsocks/shadowsocks-rust)"
    fi
    if [[ -z "$ver" ]]; then
        ver="$PX_SSRUST_FALLBACK_VER"
        px_warn "取不到最新版本号（GitHub API 限流？），回退到已知版本 v${ver}"
    fi
    if pxp_ssrust_fetch_ss "$ver"; then
        px_ok "ssserver 已安装：$bin（v${ver}）"
    elif [[ -x "$bin" ]]; then
        px_warn "下载失败，沿用本机已有的 ssserver（版本按状态库记录）"
        ver="$(db_get ss_rust version "$ver")"
    else
        px_die "Shadowsocks-Rust 下载失败，且本机没有可用的 $bin"
    fi

    # 5. 端口与凭据
    port="$(pxp_ssrust_ask_port)" || return 1
    method="$(pxp_ssrust_pick_method)" || return 1
    password="$(db_get ss_rust password "")"
    if ! pxp_ssrust_pw_ok "$method" "$password"; then
        password="$(pxp_ssrust_pw_gen "$method")"
    fi
    if ! pxp_ssrust_pw_ok "$method" "$password"; then
        px_die "生成 method=${method} 需要的密码失败（openssl 不可用？）"
    fi
    timeout="$(db_get ss_rust timeout "300")"
    mode="tcp_and_udp"
    px_ok "加密方式：${method}；密码已就绪"

    # 6. ShadowTLS（默认关）。重装时沿用上一次的选择，避免升级时把入口悄悄关掉
    stls="no"
    if [[ "$(db_get ss_rust shadowtls "no")" == "yes" ]]; then
        if [[ "${PX_YES:-0}" == "1" ]] ||
            px_confirm "保持 ShadowTLS v3 伪装（沿用现有端口/SNI/密码）？" y; then
            stls="yes"
        fi
    elif px_confirm "同时部署 ShadowTLS v3 伪装（额外 TCP 入口，客户端需支持）？" n; then
        stls="yes"
    fi

    if [[ "$stls" == "yes" ]]; then
        pxp_ssrust_stls_arch >/dev/null || return 1
        stls_port="$(pxp_ssrust_ask_stls_port "$port")" || return 1
        stls_sni="$(pxp_ssrust_ask_sni)" || return 1
        stls_pw="$(db_get ss_rust stls_password "")"
        if [[ ! "$stls_pw" =~ ^[^[:space:]]{8,64}$ ]]; then
            stls_pw="$(os_random_token 16)"
        fi
        [[ -n "$stls_pw" ]] || px_die "生成 ShadowTLS 密码失败"
        stbin="$(pxp_ssrust_stls_bin)"
        if [[ -x "$stbin" ]]; then
            px_ok "复用已安装的 shadow-tls：$stbin"
        else
            stver="${PX_SSRUST_STLS_VER:-}"
            [[ -z "$stver" ]] && stver="$(dl_latest_tag ihciah/shadow-tls)"
            if [[ -z "$stver" ]]; then
                stver="$PX_SSRUST_STLS_FALLBACK_VER"
                px_warn "取不到 ShadowTLS 最新版本号，回退到已知版本 v${stver}"
            fi
            pxp_ssrust_fetch_stls "$stver" ||
                px_die "ShadowTLS 下载失败；可先重装并选择不启用 ShadowTLS，或手动放到 $stbin"
            px_ok "shadow-tls 已安装：$stbin（v${stver}）"
        fi
    fi

    # 7. 写配置（600）。先记下旧配置端口，成功后撤旧端口规则
    dir="$(pxp_ssrust_dir)"
    cfg="$(pxp_ssrust_cfg)"
    stcfg="$(pxp_ssrust_stls_cfg)"
    mkdir -p "$dir" || px_die "创建目录失败：$dir"
    old_port="$(pxp_ssrust_cfg_port "$cfg")"
    old_stls_port="$(pxp_ssrust_cfg_stls_port "$stcfg")"
    pxp_ssrust_write_config "$port" "$password" "$method" "$timeout" "$mode" ||
        px_die "写入 SS-Rust 配置失败"
    px_ok "配置已写入：$cfg"
    if [[ "$stls" == "yes" ]]; then
        pxp_ssrust_write_stls_config "$stls_port" "$port" "$stls_sni" "$stls_pw" ||
            px_die "写入 ShadowTLS 配置失败"
        px_ok "配置已写入：$stcfg"
    fi

    # 8. 服务：先后端 ssserver，再入口 shadow-tls（入口把流量转给 127.0.0.1:ss_port）。
    #    重装时先 stop：svc_start 对已运行的服务是空操作，不停就会继续跑旧配置。
    svc_create "$unit" "$bin -c $cfg" "PX SS-Rust (Shadowsocks-Rust)"
    svc_enable "$unit"
    svc_stop "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "SS-Rust 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        px_die "安装中止（配置保留在 $cfg，修正后可用 px --regen ss_rust 重试）"
    fi
    px_ok "服务已启动：$unit"

    if [[ "$stls" == "yes" ]]; then
        svc_create "$stl_unit" "$stbin config --config $stcfg" "PX SS-Rust ShadowTLS" \
            "Environment=MONOIO_FORCE_LEGACY_DRIVER=1"
        svc_enable "$stl_unit"
        svc_stop "$stl_unit"
        svc_start "$stl_unit"
        sleep 1
        if ! svc_is_active "$stl_unit"; then
            px_err "ShadowTLS 启动失败，最近日志："
            svc_logs "$stl_unit" 30 >&2
            # 回滚入口单元，否则它会被 Restart=on-failure 反复拉起刷日志；
            # SS 本体保留，直连链接仍然可用
            svc_remove "$stl_unit"
            px_die "ShadowTLS 已回滚（SS-Rust 本体仍在运行）；可重装并在提问时选择不启用"
        fi
        px_ok "服务已启动：$stl_unit"
    elif [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
        # 重装时选择关掉 ShadowTLS：清掉旧单元，别让它继续占端口
        svc_remove "$stl_unit"
        px_ok "已移除旧的 ShadowTLS 服务：$stl_unit"
    fi

    # 9. 防火墙：SS 的 TCP 与 UDP 都要（UDP 中继），ShadowTLS 入口只 TCP。
    #    先按 tag 撤旧规则再放行，重跑不叠加。
    net_fw_deny "$port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 ||
        px_warn "防火墙放行 TCP/${port} 失败，请手动检查"
    net_fw_deny "$port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 ||
        px_warn "防火墙放行 UDP/${port} 失败，请手动检查（UDP 中继不可用）"
    if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
        net_fw_deny "$old_port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
        net_fw_deny "$old_port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    fi
    if [[ "$stls" == "yes" ]]; then
        net_fw_deny "$stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
        net_fw_allow "$stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 ||
            px_warn "防火墙放行 TCP/${stls_port} 失败，请手动检查"
    fi
    if [[ -n "$old_stls_port" && "$old_stls_port" != "$stls_port" ]]; then
        net_fw_deny "$old_stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
    fi

    # 10. 状态库：字段一次写全，最后才 mark_installed
    db_set ss_rust port "$port"
    db_set ss_rust method "$method"
    db_set ss_rust password "$password"
    db_set ss_rust mode "$mode"
    db_set ss_rust timeout "$timeout"
    db_set ss_rust version "$ver"
    db_set ss_rust shadowtls "$stls"
    db_set ss_rust created "$(os_now)"
    if [[ "$stls" == "yes" ]]; then
        db_set ss_rust stls_port "$stls_port"
        db_set ss_rust stls_password "$stls_pw"
        db_set ss_rust stls_sni "$stls_sni"
        db_set ss_rust stls_version "3"
    else
        db_del ss_rust stls_port
        db_del ss_rust stls_password
        db_del ss_rust stls_sni
        db_del ss_rust stls_version
    fi
    db_mark_installed ss_rust
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    # 11. 收尾
    px_hr
    px_ok "SS-Rust 安装完成"
    if [[ "$stls" == "yes" ]]; then
        px_kv "服务单元" "${unit}、${stl_unit}"
    else
        px_kv "服务单元" "$unit"
    fi
    px_kv "配置文件" "$cfg"
    px_kv "加密方式" "$method"
    px_kv "密码" "$password"
    px_kv "监听端口" "${port}/tcp+udp"
    px_kv "ShadowTLS" "$([[ "$stls" == "yes" ]] && printf 'v3（入口 %s/tcp，SNI %s）' "$stls_port" "$stls_sni" || printf '未启用')"
    px_kv "服务状态" "$(proto_ss_rust_status | head -n1)"
    px_hr
    px_info "分享链接（SS2022 需较新客户端；ShadowTLS 见 plugin 参数）："
    proto_ss_rust_link || px_warn "暂时取不到公网 IP，稍后可用 px --link ss_rust 查看"
}

proto_ss_rust_uninstall() {
    local unit stl_unit dir port stls_port
    px_require_root
    unit="$(pxp_ssrust_unit)"
    stl_unit="$(pxp_ssrust_stls_unit)"

    # 状态库没了但 unit 还在（恢复备份/手工删库）也允许卸载，否则残留服务永远清不掉
    if ! db_has ss_rust &&
        [[ "$(svc_status "$unit")" == "not-found" ]] &&
        [[ "$(svc_status "$stl_unit")" == "not-found" ]]; then
        px_warn "SS-Rust 未安装"
        return 0
    fi
    if [[ "${PX_YES:-0}" != "1" ]]; then
        px_confirm "确认卸载 SS-Rust（停止服务、删除配置与防火墙规则）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    port="$(db_get ss_rust port "")"
    [[ -z "$port" ]] && port="$(pxp_ssrust_cfg_port "$(pxp_ssrust_cfg)")"
    stls_port="$(db_get ss_rust stls_port "")"
    [[ -z "$stls_port" ]] && stls_port="$(pxp_ssrust_cfg_stls_port "$(pxp_ssrust_stls_cfg)")"

    # 上游 ss-rust.sh 的已知 bug：卸载只 disable 不删 unit。两个单元都必须 svc_remove，
    # 否则下次安装的 svc_start 会对着旧 ExecStart 直接"成功"，改了配置也不生效。
    svc_remove "$stl_unit"
    svc_remove "$unit"
    px_ok "已停止并移除服务：${unit} ${stl_unit}"
    if [[ -n "$port" ]]; then
        net_fw_deny "$port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
        net_fw_deny "$port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 ||
            px_warn "撤销 UDP/${port} 放行失败，请手动检查"
    fi
    if [[ -n "$stls_port" ]]; then
        net_fw_deny "$stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
    fi
    # 两个二进制都只服务本协议，默认删除（PX_YES=1 按默认 yes 删，避免留孤儿）
    if px_confirm "同时删除 ssserver 与 shadow-tls 二进制？" y; then
        rm -f -- "$(pxp_ssrust_bin)" && px_ok "已删除 $(pxp_ssrust_bin)"
        rm -f -- "$(pxp_ssrust_stls_bin)" && px_ok "已删除 $(pxp_ssrust_stls_bin)"
    fi
    dir="$(pxp_ssrust_dir)"
    if [[ -n "$dir" && "$dir" == "${PX_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
        px_ok "已删除配置目录：$dir"
    fi
    db_del ss_rust
    db_unmark_installed ss_rust
    px_ok "SS-Rust 已卸载"
}

proto_ss_rust_status() {
    local unit port pid st
    unit="$(pxp_ssrust_unit)"
    if ! db_has ss_rust && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get ss_rust port '-')"
    st="$(svc_status "$unit")"
    # SPEC 要求状态行只有这三种形态（菜单用 grep 提取"运行中/已停止"），
    # 所以不在这一行附带 ShadowTLS 入口/重建提示，避免上层解析出歧义。
    if [[ "$st" == "active" ]]; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
    else
        printf '已停止\n'
    fi
}

proto_ss_rust_link() {
    local port method password host name userinfo stls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        px_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$PX_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    [[ -n "$port" && -n "$password" ]] || {
        px_err "状态库缺少 port/password，请重新安装"
        return 1
    }
    host="$(pxp_ssrust_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_ssrust_name)"
    userinfo="$(pxp_ssrust_b64url "${method}:${password}")"
    stls="$(db_get ss_rust shadowtls "no")"
    if [[ "$stls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            # SIP002 的 plugin 参数：分号原样写，客户端自己解析 shadow-tls 参数
            printf 'ss://%s@%s:%s?plugin=shadow-tls;host=%s;password=%s#%s\n' \
                "$userinfo" "$host" "$stls_port" "$stls_sni" "$stls_pw" "$name"
            # 公网 SS 端口本身也开着（UDP 中继要靠它），再给一条直连兜底
            printf 'ss://%s@%s:%s#%s-direct\n' \
                "$userinfo" "$host" "$port" "${name// /-}"
            return 0
        fi
    fi
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "${name// /-}"
}

proto_ss_rust_regen() {
    local unit stl_unit bin stbin dir cfg stcfg
    local port method password timeout mode shadowtls
    local stls_port stls_pw stls_sni old_port old_stls_port
    px_require_root
    if ! db_has ss_rust; then
        px_err "SS-Rust 未安装，无法重生成配置"
        return 1
    fi

    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$PX_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    timeout="$(db_get ss_rust timeout "300")"
    mode="$(db_get ss_rust mode "tcp_and_udp")"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    stls_port="$(db_get ss_rust stls_port "")"
    stls_pw="$(db_get ss_rust stls_password "")"
    stls_sni="$(db_get ss_rust stls_sni "")"

    pxp_ssrust_port_ok "$port" || {
        px_err "状态库里的端口不合法：${port:-空}（请重新安装）"
        return 1
    }
    [[ -n "$password" ]] || {
        px_err "状态库里的密码为空，请重新安装或先换凭据"
        return 1
    }

    # 菜单「换凭据」对 SS-Rust 写的是 os_random_token 20 的普通串，而 SS2022 要求
    # base64 且解码后 16/32 字节。这里检测到不兼容就自动生成新密钥并写回状态库，
    # 否则 ssserver 会直接起不来（菜单那边只提示"请检查日志"）。
    if ! pxp_ssrust_pw_ok "$method" "$password"; then
        password="$(pxp_ssrust_pw_gen "$method")"
        if ! pxp_ssrust_pw_ok "$method" "$password"; then
            px_err "method=${method} 的密码生成失败（openssl 不可用？）"
            return 1
        fi
        db_set ss_rust password "$password"
        px_warn "原密码与 method=${method} 不兼容，已自动生成新密码：${password}（请同步更新客户端）"
    fi

    bin="$(pxp_ssrust_bin)"
    [[ -x "$bin" ]] || {
        px_err "缺少 $bin，请重新安装"
        return 1
    }

    dir="$(pxp_ssrust_dir)"
    cfg="$(pxp_ssrust_cfg)"
    stcfg="$(pxp_ssrust_stls_cfg)"
    mkdir -p "$dir" || {
        px_err "创建目录失败：$dir"
        return 1
    }
    old_port="$(pxp_ssrust_cfg_port "$cfg")"
    old_stls_port="$(pxp_ssrust_cfg_stls_port "$stcfg")"
    pxp_ssrust_write_config "$port" "$password" "$method" "$timeout" "$mode" || {
        px_err "写入 SS-Rust 配置失败"
        return 1
    }

    unit="$(pxp_ssrust_unit)"
    stl_unit="$(pxp_ssrust_stls_unit)"

    if [[ "$shadowtls" == "yes" ]]; then
        stbin="$(pxp_ssrust_stls_bin)"
        [[ -x "$stbin" ]] || {
            px_err "ShadowTLS 已启用但缺少 $stbin，请重新安装"
            return 1
        }
        pxp_ssrust_port_ok "$stls_port" || {
            px_err "状态库里的 ShadowTLS 端口不合法：${stls_port:-空}"
            return 1
        }
        [[ -n "$stls_pw" && -n "$stls_sni" ]] || {
            px_err "状态库缺少 ShadowTLS 密码/SNI，请重新安装"
            return 1
        }
        pxp_ssrust_write_stls_config "$stls_port" "$port" "$stls_sni" "$stls_pw" || {
            px_err "写入 ShadowTLS 配置失败"
            return 1
        }
    fi

    # 单元文件可能被删（恢复备份/手工清理）：regen 顺手重建，
    # 这样菜单里的"改端口/换凭据"在任何情况下都能生效。
    svc_create "$unit" "$bin -c $cfg" "PX SS-Rust (Shadowsocks-Rust)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "重启后 SS-Rust 未运行，最近日志："
        svc_logs "$unit" 30 >&2
        return 1
    fi

    if [[ "$shadowtls" == "yes" ]]; then
        svc_create "$stl_unit" "$stbin config --config $stcfg" "PX SS-Rust ShadowTLS" \
            "Environment=MONOIO_FORCE_LEGACY_DRIVER=1"
        svc_enable "$stl_unit"
        svc_restart "$stl_unit"
        sleep 1
        if ! svc_is_active "$stl_unit"; then
            px_err "重启后 ShadowTLS 未运行，最近日志："
            svc_logs "$stl_unit" 30 >&2
            return 1
        fi
    elif [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
        # 状态库里已关掉 ShadowTLS，但旧单元还在：清掉，别让它继续占端口
        svc_remove "$stl_unit"
        px_ok "已移除旧的 ShadowTLS 服务：$stl_unit"
    fi

    # 防火墙补齐：菜单改端口时只放行了一个协议，这里把 tcp/udp/入口都对一遍
    net_fw_deny "$port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    net_fw_deny "$port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    net_fw_allow "$port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
        net_fw_deny "$old_port" tcp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
        net_fw_deny "$old_port" udp "$(pxp_ssrust_tag)" >/dev/null 2>&1 || true
    fi
    if [[ "$shadowtls" == "yes" ]]; then
        net_fw_deny "$stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
        net_fw_allow "$stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
    fi
    if [[ -n "$old_stls_port" && "$old_stls_port" != "$stls_port" ]]; then
        net_fw_deny "$old_stls_port" tcp "$(pxp_ssrust_stls_tag)" >/dev/null 2>&1 || true
    fi

    px_ok "配置已重生成并重启：$cfg"
    proto_ss_rust_status | head -n1
    return 0
}

proto_ss_rust_clash() {
    local port method password host name shadowtls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        px_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$PX_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(pxp_ssrust_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            printf '  - name: "%s"\n' "$name"
            printf '    type: ss\n'
            printf '    server: "%s"\n' "$host"
            printf '    port: %s\n' "$stls_port"
            printf '    cipher: %s\n' "$method"
            printf '    password: "%s"\n' "$password"
            printf '    udp: true\n'
            printf '    plugin: shadow-tls\n'
            printf '    plugin-opts:\n'
            printf '      host: %s\n' "$stls_sni"
            printf '      password: "%s"\n' "$stls_pw"
            printf '      version: 3\n'
            return 0
        fi
    fi
    printf '  - name: "%s"\n' "$name"
    printf '    type: ss\n'
    printf '    server: "%s"\n' "$host"
    printf '    port: %s\n' "$port"
    printf '    cipher: %s\n' "$method"
    printf '    password: "%s"\n' "$password"
    printf '    udp: true\n'
}

proto_ss_rust_surge() {
    local port method password host name shadowtls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        px_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$PX_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(pxp_ssrust_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            # Surge 侧顺序沿用上游 ss-rust.sh：入口端口 + shadow-tls-* 参数 + udp-port 指回 SS
            printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, tfo=false, udp-relay=true, ecn=true, shadow-tls-password=%s, shadow-tls-sni=%s, shadow-tls-version=3, udp-port=%s\n' \
                "$name" "$host" "$stls_port" "$method" "$password" \
                "$stls_pw" "$stls_sni" "$port"
            return 0
        fi
    fi
    printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, tfo=false, udp-relay=true, ecn=true\n' \
        "$name" "$host" "$port" "$method" "$password"
}

proto_ss_rust_singbox() {
    local port method password host name shadowtls
    if ! db_has ss_rust; then
        px_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$PX_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(pxp_ssrust_host)" || {
        px_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(pxp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        # sing-box 的 ShadowTLS 要 shadowtls + shadowsocks 两段 outbound（detour 串联），
        # 单个片段表达不了。这里给出直连 SS 出站（SS 端口本身 tcp+udp 都开放），
        # 并把需要手写的两段提示到 stderr——不影响片段本身是合法 JSON。
        px_warn "sing-box 的 ShadowTLS 需 shadowtls + shadowsocks 两段 outbound（detour 串联），单片段无法表达；本片段为直连 SS 出站，要伪装请用 Clash/Surge 或手写两段"
    fi
    jq -c -n \
        --argjson port "$port" \
        --arg server "$host" \
        --arg method "$method" \
        --arg password "$password" \
        --arg tag "$name" \
        '{
            type: "shadowsocks",
            tag: $tag,
            server: $server,
            server_port: $port,
            method: $method,
            password: $password
        }'
}

# ===== src/proto/anytls.sh =====
# ============================================================
# proto/anytls.sh —— AnyTLS（服务端用 sing-box 的 anytls inbound 承载自签/ACME 证书）
# 对外：proto_anytls_meta/install/uninstall/status/link/regen/clash/surge/singbox
# 内部辅助函数：见下方定义（私有前缀 pxp）
# 说明：上游 anytls-go 的 anytls-server 不支持外部证书（进程内临时自签），
#       故服务端改用 sing-box 的 anytls inbound，以满足「证书必须由本脚本自主签发」。
#       本文件是 build.sh 拼接的单文件片段，不写 shebang、不 source、不 set -e
# ============================================================

# sing-box 版本钉死（升级只改这一处；已装同版本时复用二进制，不重复下载）
PX_SINGBOX_VER="${PX_SINGBOX_VER:-1.14.4}"

# ---------- 内部辅助 ----------

pxp_anytls_dir() {
    px_proto_dir anytls
}

pxp_anytls_cfg() {
    printf '%s/config.json' "$(px_proto_dir anytls)"
}

pxp_anytls_bin() {
    printf '%s/sing-box' "${PX_BIN_DIR}"
}

pxp_anytls_default_port() {
    local port
    port="$(db_get anytls port "")"
    printf '%s' "${port:-8443}"
}

pxp_anytls_name() {
    printf '%s' "${PX_PROTO_TITLE[anytls]:-AnyTLS}"
}

pxp_anytls_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    (( n >= 1 && n <= 65535 ))
}

# sing-box 资产架构别名：amd64/arm64/armv7（无 i386）
pxp_anytls_arch() {
    case "${PX_ARCH:-}" in
        amd64|arm64) printf '%s' "$PX_ARCH" ;;
        armv7l) printf 'armv7' ;;
        *) return 1 ;;
    esac
}

# 读已装 sing-box 的版本号（首行 "sing-box version x.y.z" 的第 3 列）
pxp_anytls_sb_version() {
    local bin v
    bin="$(pxp_anytls_bin)"
    [[ -x "$bin" ]] || return 1
    v="$("$bin" version 2>/dev/null | awk 'NR==1{print $3}')"
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

# 下载钉死版本的 sing-box 官方 tar.gz 并装到 PX_BIN_DIR
pxp_anytls_fetch_singbox() {
    local ver="${PX_SINGBOX_VER}" arch asset tmpdir bin
    arch="$(pxp_anytls_arch)" || return 1
    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    tmpdir="$(mktemp -d)" || return 1
    if ! dl_gh SagerNet/sing-box "v${ver}" "$asset" "$tmpdir/sing-box.tar.gz"; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    if ! dl_untar "$tmpdir/sing-box.tar.gz" "$tmpdir/x"; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    bin="$tmpdir/x/sing-box-${ver}-linux-${arch}/sing-box"
    if [[ ! -f "$bin" ]]; then
        bin="$(find "$tmpdir/x" -type f -name sing-box 2>/dev/null | head -1)"
    fi
    if [[ -z "$bin" || ! -f "$bin" ]]; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    cp -f -- "$bin" "$(pxp_anytls_bin)" || { rm -rf -- "$tmpdir"; return 1; }
    chmod 755 "$(pxp_anytls_bin)"
    rm -rf -- "$tmpdir"
}

pxp_anytls_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# 写 sing-box 配置（/etc/px/anytls/config.json，600）；内容无变化时不重写
pxp_anytls_write_config() {
    local port="$1" pw="$2" sni="$3" cert="$4" key="$5"
    local dir cfg tmp
    dir="$(pxp_anytls_dir)"
    cfg="$(pxp_anytls_cfg)"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg pw "$pw" \
        --arg sni "$sni" \
        --arg cert "$cert" \
        --arg key "$key" '
        {
            log: {level: "warn", timestamp: true},
            inbounds: [{
                type: "anytls",
                tag: "px-anytls",
                listen: "::",
                listen_port: $port,
                users: [{name: "px", password: $pw}],
                tls: {
                    enabled: true,
                    server_name: $sni,
                    certificate_path: $cert,
                    key_path: $key
                }
            }],
            outbounds: [{type: "direct", tag: "direct"}]
        }
    ' > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        chmod 600 "$cfg" 2>/dev/null || true
        return 0
    fi
    mv -f -- "$tmp" "$cfg" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$cfg" 2>/dev/null || true
}

pxp_anytls_write_unit() {
    svc_create "$(px_unit_name anytls)" \
        "$(pxp_anytls_bin) run -c $(pxp_anytls_cfg)" \
        "PX AnyTLS"
}

# 启动前用 sing-box 自带 check 校验配置，避免带着坏配置起服务
pxp_anytls_check_config() {
    local out
    if ! out="$("$(pxp_anytls_bin)" check -c "$(pxp_anytls_cfg)" 2>&1)"; then
        px_err "sing-box 配置校验失败："
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# 对外 IP：优先 db 里缓存的 settings.ip，避免每次外联探测
pxp_anytls_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "${ip:-0.0.0.0}"
}

# 自签证书才跳过校验；acme/existing 为真实证书
pxp_anytls_insecure() {
    if [[ "$(db_get anytls tls_mode self)" == "self" ]]; then
        printf '1'
    else
        printf '0'
    fi
}

# ---------- SPEC §10 契约函数 ----------

proto_anytls_meta() {
    printf 'title=%s\n' "$(pxp_anytls_name)"
    printf 'desc=低特征 TLS 代理（sing-box 实现），支持自签/ACME 证书\n'
    printf 'port=%s\n' "$(pxp_anytls_default_port)"
    printf 'udp=no\n'
    printf 'cert=yes\n'
}

proto_anytls_install() {
    local unit port mode sni_hint crt_file key_file sni pw have arch

    px_require_root
    [[ -n "${PX_ARCH:-}" ]] || os_detect

    # 1. 判重
    if db_is_installed anytls || db_has anytls; then
        if [[ "${PX_YES:-0}" == "1" ]]; then
            px_die "AnyTLS 已安装；非交互模式不覆盖，请先卸载后重装"
        fi
        px_confirm "AnyTLS 已安装，是否重新安装（覆盖配置）？" n || {
            px_info "已取消"
            return 0
        }
    fi

    # 2. 依赖与二进制（sing-box 复用，版本不一致才重下）
    case "${PX_ARCH:-}" in
        amd64|arm64|armv7l) ;;
        i386) px_die "AnyTLS 不支持 i386（sing-box 未提供 linux-386 构建）" ;;
        *) px_die "AnyTLS 不支持当前架构：${PX_ARCH:-未知}（支持 amd64/arm64/armv7l）" ;;
    esac
    arch="$(pxp_anytls_arch)"
    os_dep_install base || px_die "基础依赖安装失败，无法继续"

    have="$(pxp_anytls_sb_version || true)"
    if [[ "$have" == "$PX_SINGBOX_VER" ]]; then
        px_ok "复用已安装的 sing-box ${have}：$(pxp_anytls_bin)"
    else
        px_info "下载 sing-box ${PX_SINGBOX_VER}（SagerNet/sing-box，linux-${arch}）..."
        if ! pxp_anytls_fetch_singbox; then
            px_die "sing-box 下载失败；请检查网络或设置 GitHub 镜像后重试（也可手动放二进制到 $(pxp_anytls_bin)）"
        fi
        have="$(pxp_anytls_sb_version || true)"
        [[ -n "$have" ]] || px_die "sing-box 已落盘但无法执行（架构不匹配或缺少依赖），请检查 $(pxp_anytls_bin)"
        px_ok "sing-box 已安装：$(pxp_anytls_bin)（${have}）"
    fi

    # 3. 端口（TCP）
    port="${PX_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(px_ask "AnyTLS 监听端口" "$(pxp_anytls_default_port)")"
    fi
    pxp_anytls_port_ok "$port" || px_die "端口无效：${port:-空}（需 1-65535）"
    port=$((10#$port))
    if net_port_in_use "$port" tcp; then
        px_die "TCP 端口 ${port} 已被占用；建议改用空闲端口：$(net_port_pick 8443 tcp)"
    fi

    # 4. 证书（先拿证书，失败不写半截配置）
    mode="${PX_ARG_CERT_MODE:-}"
    if [[ -z "$mode" ]]; then
        mode="$(px_ask "证书方式（self=自签 / acme=域名申请 / existing=已有证书）" self)"
    fi
    case "$mode" in
        self|acme|existing) ;;
        *) px_die "无效的证书方式：${mode}（可选 self/acme/existing）" ;;
    esac
    sni_hint="${PX_ARG_SNI:-${PX_ARG_DOMAIN:-bing.com}}"
    px_info "准备证书（方式：${mode}，SNI 提示：${sni_hint}）..."
    if ! cert_ensure "$sni_hint" "$mode"; then
        px_die "证书准备失败，安装已中止（未写入任何配置）"
    fi
    crt_file="${CERT_PATH:-}"
    key_file="${KEY_PATH:-}"
    sni="${SNI:-$sni_hint}"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        px_die "证书文件缺失（cert=${crt_file:-空} key=${key_file:-空}），安装已中止"
    fi
    px_ok "证书就绪：${crt_file}（SNI=${sni}）"

    # 5. 凭据
    pw="$(os_random_token 16)"
    if [[ ${#pw} -lt 16 ]]; then
        pw="$(os_random_hex 16)"
    fi
    [[ -n "$pw" ]] || px_die "随机密码生成失败"

    # 6. 写配置并校验
    pxp_anytls_write_config "$port" "$pw" "$sni" "$crt_file" "$key_file" ||
        px_die "写入配置失败：$(pxp_anytls_cfg)"
    pxp_anytls_check_config || px_die "配置校验未通过，安装已中止：$(pxp_anytls_cfg)"
    px_ok "配置已写入：$(pxp_anytls_cfg)"

    # 7. 服务
    unit="$(px_unit_name anytls)"
    pxp_anytls_write_unit
    svc_enable "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "AnyTLS 启动失败，最近日志："
        svc_logs "$unit" 30
        px_die "服务未能启动；请检查证书路径、TCP ${port} 是否被占用后重试"
    fi
    px_ok "服务已启动：${unit}"

    # 8. 防火墙
    net_fw_deny "$port" tcp "px-anytls" >/dev/null 2>&1 || true
    net_fw_allow "$port" tcp "px-anytls" >/dev/null 2>&1 || px_warn "防火墙放行 TCP ${port} 失败，请手动检查"

    # 9. 落库（sing-box 二进制共享，卸载时保留）
    db_set anytls port "$port"
    db_set anytls password "$pw"
    db_set anytls sni "$sni"
    db_set anytls tls_mode "$mode"
    db_set anytls tls_cert "$crt_file"
    db_set anytls tls_key "$key_file"
    db_set anytls singbox_ver "$PX_SINGBOX_VER"
    db_set anytls created "$(os_now)"
    db_mark_installed anytls
    local pubip
    pubip="$(net_primary_ip)"
    [[ -n "$pubip" ]] && db_setting ip "$pubip"

    # 10. 收尾
    px_ok "AnyTLS 安装完成"
    if [[ "${PX_YES:-0}" == "1" ]]; then
        proto_anytls_link
        return 0
    fi
    px_hr
    px_kv "协议" "AnyTLS（sing-box ${PX_SINGBOX_VER}）"
    px_kv "端口(TCP)" "${port}"
    px_kv "密码" "${pw}"
    px_kv "SNI" "${sni}"
    px_kv "证书方式" "${mode}"
    px_kv "证书" "${crt_file}"
    px_kv "服务状态" "$(proto_anytls_status | head -1)"
    px_hr
    px_info "分享链接（URI，可直接导入客户端）："
    proto_anytls_link
}

proto_anytls_uninstall() {
    local unit port dir
    px_require_root
    unit="$(px_unit_name anytls)"
    if ! db_is_installed anytls && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        px_warn "AnyTLS 未安装"
        return 0
    fi
    px_confirm "确认卸载 AnyTLS（停止服务、删除配置与防火墙规则）？" y || {
        px_info "已取消"
        return 0
    }
    port="$(db_get anytls port "")"
    svc_remove "$unit"
    if [[ -n "$port" ]]; then
        net_fw_deny "$port" tcp "px-anytls" >/dev/null 2>&1 || px_warn "撤销防火墙规则失败，请手动检查"
    fi
    dir="$(pxp_anytls_dir)"
    if [[ -n "$dir" && "$dir" == "${PX_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
    fi
    db_unmark_installed anytls
    db_del anytls
    px_ok "AnyTLS 已卸载（sing-box 二进制与证书保留，其它协议可复用）"
}

proto_anytls_status() {
    local unit port pid
    unit="$(px_unit_name anytls)"
    if ! db_is_installed anytls && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get anytls port '-')"
    if svc_is_active "$unit"; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
        return 0
    fi
    if [[ "$(svc_status "$unit")" == "failed" ]]; then
        printf '已停止（failed）\n'
    else
        printf '已停止\n'
    fi
}

proto_anytls_link() {
    local pw port sni ip host q
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ip="$(pxp_anytls_ip)"
    host="$ip"
    [[ "$ip" == *:* ]] && host="[${ip}]"
    q="sni=${sni}"
    if [[ "$(pxp_anytls_insecure)" == "1" ]]; then
        q+="&insecure=1"
    fi
    printf 'anytls://%s@%s:%s?%s#%s\n' "$pw" "$host" "$port" "$q" "$(pxp_anytls_name)"
}

proto_anytls_regen() {
    local unit port pw sni crt_file key_file
    px_require_root
    if ! db_is_installed anytls; then
        px_die "AnyTLS 未安装，无法重生成配置"
    fi
    port="$(db_get anytls port "")"
    pw="$(db_get anytls password "")"
    sni="$(db_get anytls sni bing.com)"
    crt_file="$(db_get anytls tls_cert "")"
    key_file="$(db_get anytls tls_key "")"

    pxp_anytls_port_ok "$port" || px_die "数据库中的端口无效：${port:-空}"
    [[ -n "$pw" ]] || px_die "数据库中的密码为空，请重新安装"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        px_die "数据库记录的证书不存在（cert=${crt_file:-空} key=${key_file:-空}），请重新安装以重新签发"
    fi

    pxp_anytls_write_config "$port" "$pw" "$sni" "$crt_file" "$key_file" ||
        px_die "写入配置失败：$(pxp_anytls_cfg)"
    pxp_anytls_check_config || px_die "配置校验未通过：$(pxp_anytls_cfg)"
    pxp_anytls_write_unit
    unit="$(px_unit_name anytls)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        px_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30
        px_die "配置重生成后启动失败"
    fi
    px_ok "配置已重生成并重启：$(pxp_anytls_cfg)"
}

proto_anytls_clash() {
    local pw port sni ip
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ip="$(pxp_anytls_ip)"

    printf '  - name: "%s"\n' "$(pxp_anytls_name)"
    printf '    type: anytls\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    password: "%s"\n' "$pw"
    printf '    sni: "%s"\n' "$sni"
    if [[ "$(pxp_anytls_insecure)" == "1" ]]; then
        printf '    skip-cert-verify: true\n'
    fi
    printf '    udp: true\n'
}

proto_anytls_surge() {
    local pw port sni line
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    line="$(pxp_anytls_name) = anytls, $(pxp_anytls_ip), ${port}, password=${pw}, sni=${sni}"
    if [[ "$(pxp_anytls_insecure)" == "1" ]]; then
        line+=", skip-cert-verify=true"
    fi
    printf '%s\n' "$line"
}

proto_anytls_singbox() {
    local pw port sni ins
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ins="$(pxp_anytls_insecure)"

    jq -n \
        --argjson port "$port" --arg server "$(pxp_anytls_ip)" \
        --arg pw "$pw" --arg sni "$sni" --argjson insecure "$ins" '
        {
            type: "anytls",
            tag: "px-anytls",
            server: $server,
            server_port: $port,
            password: $pw,
            tls: ({enabled: true, server_name: $sni}
                  + (if $insecure == 1 then {insecure: true} else {} end)
                  + {utls: {enabled: true, fingerprint: "chrome"}})
        }
    '
}

# ===== src/99-menu.sh =====
# 99-menu.sh —— 菜单装配 + CLI 入口 + main

# ---------- 协议小工具 ----------

px_key_valid() {
    local k
    for k in "${PX_PROTOS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
    return 1
}

px_title_of() { printf '%s' "${PX_PROTO_TITLE[$1]:-$1}"; }

# 动态调度 proto 函数
px_call() {
    local k="$1" suf="$2"; shift 2
    "proto_${k}_${suf}" "$@"
}

# 从 meta 输出取字段
px_meta_field() {
    local k="$1" f="$2"
    px_call "$k" meta 2>/dev/null | awk -F= -v f="$f" '$1==f{sub(/^[^=]*=/, ""); print; exit}'
}

px_status_line() {
    local k="$1" st
    if ! db_is_installed "$k"; then
        printf '未安装'
        return 0
    fi
    st="$(px_call "$k" status 2>/dev/null | head -1)"
    printf '%s' "${st:-未知}"
}

# ---------- 首屏 ----------

px_banner() {
    local ip
    ip="$(db_setting ip)"
    printf '\n%b%s%b  %bv%s%b\n' "$C_BOLD$C_C" "PX 综合代理脚本" "$C_N" "$C_DIM" "$PX_VERSION" "$C_N"
    px_kv "系统" "$PX_OS_ID $PX_OS_VER / $PX_ARCH"
    px_kv "公网 IP" "${ip:-未检测}"
    local k line="" n=0
    for k in "${PX_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        n=$((n + 1))
        line+="$(px_title_of "$k"):$(db_get "$k" port "-")($(px_status_line "$k" | grep -oE '运行中|已停止|failed|未知' || echo '?'))  "
    done
    if ((n > 0)); then
        px_kv "已装协议" "$line"
    else
        px_kv "已装协议" "无"
    fi
    px_hr
}

# ---------- 1. 安装 ----------

menu_install() {
    local -a items=() keys=()
    local k label installed port cert
    for k in "${PX_PROTOS[@]}"; do
        port="$(px_meta_field "$k" port)"
        cert="$(px_meta_field "$k" cert)"
        if db_is_installed "$k"; then installed=" [已安装]"; else installed=""; fi
        label="$(px_title_of "$k")  — $(px_meta_field "$k" desc)"
        if [[ "$cert" == "yes" ]]; then
            label+="  （需证书）"
        fi
        items+=("$label$installed")
        keys+=("$k")
    done
    local sel
    sel="$(px_menu "安装协议" "${items[@]}")" || return 0
    [[ "$sel" == "0" ]] && return 0
    k="${keys[$((sel - 1))]}"
    if db_is_installed "$k"; then
        px_warn "$(px_title_of "$k") 已安装"
        px_confirm "重新安装（覆盖配置）？" n || return 0
    fi
    px_call "$k" install
    px_pause
}

# ---------- 2. 节点管理 ----------

menu_manage() {
    local -a items=() keys=()
    local k
    for k in "${PX_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        items+=("$(px_title_of "$k")  $(px_status_line "$k")")
        keys+=("$k")
    done
    if [[ ${#keys[@]} -eq 0 ]]; then
        px_warn "还没有安装任何协议，先去菜单 1 安装"
        px_pause
        return 0
    fi
    local sel
    sel="$(px_menu "节点管理" "${items[@]}")" || return 0
    [[ "$sel" == "0" ]] && return 0
    k="${keys[$((sel - 1))]}"
    local unit
    unit="$(px_unit_name "$k")"

    while true; do
        local c
        c="$(px_menu "$(px_title_of "$k") 管理" \
            "状态与日志" \
            "启动" "停止" "重启" \
            "改端口" "换凭据" "重生成配置" \
            "查看链接" "二维码" "删除")" || return 0
        case "$c" in
            0) return 0 ;;
            1) px_title "$(px_title_of "$k") 状态"
               px_call "$k" status
               echo
               svc_logs "$unit" 20
               px_pause ;;
            2) svc_start "$unit" && px_ok "已启动" || px_err "启动失败"
               sleep 1; px_call "$k" status; px_pause ;;
            3) svc_stop "$unit" && px_ok "已停止"; px_pause ;;
            4) svc_restart "$unit" && px_ok "已重启" || px_err "重启失败"
               sleep 1; px_call "$k" status; px_pause ;;
            5) _menu_change_port "$k"; px_pause ;;
            6) _menu_change_pw "$k"; px_pause ;;
            7) px_call "$k" regen && px_ok "配置已重生成并重启" || px_err "重生成失败"; px_pause ;;
            8) px_call "$k" link; px_pause ;;
            9) px_call "$k" link | head -1 | while read -r l; do share_qr "$l"; done; px_pause ;;
            10) _menu_delete "$k" && return 0 ;;
        esac
    done
}

_menu_change_port() {
    local k="$1" old new
    old="$(db_get "$k" port "")"
    new="$(px_ask "新端口（当前 $old，回车不改）" "")"
    [[ -z "$new" || "$new" == "$old" ]] && return 0
    [[ "$new" =~ ^[0-9]+$ ]] || { px_err "端口必须是数字"; return 1; }
    local proto="tcp"
    [[ "$(px_meta_field "$k" udp)" == "yes" ]] && proto="udp"
    net_port_in_use "$new" "$proto" && { px_err "端口 $new 已被占用"; return 1; }
    db_set "$k" port "$new"
    # 防火墙：先放行新端口，重生成成功后再撤旧端口
    net_fw_allow "$new" "$proto" "px-$k" >/dev/null 2>&1
    if px_call "$k" regen; then
        net_fw_deny "$old" "$proto" "px-$k" >/dev/null 2>&1
        px_ok "端口已改为 $new"
    else
        db_set "$k" port "$old"
        px_err "重生成失败，端口回滚为 $old"
    fi
}

_menu_change_pw() {
    local k="$1" field new
    case "$k" in
        snell) field="psk" ;;
        vless_reality) field="uuid" ;;
        *) field="password" ;;
    esac
    new="$(px_ask "新凭据（回车自动生成）" "")"
    [[ -z "$new" ]] && new="$(os_random_token 20)"
    db_set "$k" "$field" "$new"
    if px_call "$k" regen; then
        px_ok "凭据已更新"
        px_kv "新凭据" "$new"
    else
        px_err "重生成失败，请检查日志"
    fi
}

_menu_delete() {
    local k="$1"
    px_confirm "确认删除 $(px_title_of "$k")（配置与防火墙规则一并清理）？" n || return 1
    px_call "$k" uninstall
    return 0
}

# ---------- 3. 证书 ----------

menu_cert() {
    while true; do
        local c
        c="$(px_menu "证书管理" \
            "查看证书状态" \
            "ACME 申请（HTTP-01，需域名解析到本机）" \
            "生成自签证书" \
            "生成 REALITY x25519 密钥对")" || return 0
        case "$c" in
            0) return 0 ;;
            1) cert_status; px_pause ;;
            2) local d
               d="$(px_ask "域名" "")"
               [[ -z "$d" ]] && { px_err "域名不能为空"; px_pause; continue; }
               os_dep_install base acme || { px_pause; continue; }
               if cert_acme "$d" "$PX_CERT_DIR/$d"; then
                   px_ok "证书就绪：$PX_CERT_DIR/$d"
               else
                   px_err "ACME 失败（80 端口被占或验证不通过）"
               fi
               px_pause ;;
            3) local s out
               s="$(px_ask "SNI/域名（自签用，可填 bing.com）" "bing.com")"
               out="$PX_CERT_DIR/self-$s"
               if cert_self "$s" "$out"; then
                   px_ok "自签证书：$out"
               else
                   px_err "自签失败"
               fi
               px_pause ;;
            4) reality_keypair "$PX_CERT_DIR/reality.json" && px_ok "已写入 $PX_CERT_DIR/reality.json" || px_err "生成失败"
               px_pause ;;
        esac
    done
}

# ---------- 4. 订阅 ----------

menu_sub() {
    while true; do
        local c
        c="$(px_menu "订阅与分享" \
            "生成全部格式（uri/clash/surge/singbox）" \
            "仅生成 URI 列表" \
            "仅生成 Clash" \
            "仅生成 Surge" \
            "仅生成 sing-box" \
            "查看订阅目录")" || return 0
        case "$c" in
            0) return 0 ;;
            1) share_render_uri >/dev/null; share_render_clash >/dev/null; share_render_surge >/dev/null; share_render_singbox >/dev/null
               px_ok "已生成到 $PX_SUB_DIR"; ls -l "$PX_SUB_DIR" 2>/dev/null; px_pause ;;
            2) share_render_uri >/dev/null && px_ok "URI 列表已生成" ;;
            3) share_render_clash >/dev/null && px_ok "Clash 配置已生成" ;;
            4) share_render_surge >/dev/null && px_ok "Surge 配置已生成" ;;
            5) share_render_singbox >/dev/null && px_ok "sing-box 配置已生成" ;;
            6) ls -l "$PX_SUB_DIR" 2>/dev/null || px_warn "目录为空" ;;
        esac
        [[ "$c" != "1" && "$c" != "6" ]] && px_pause
    done
}

# ---------- 5. 系统工具 ----------

menu_system() {
    while true; do
        local c
        c="$(px_menu "系统工具" \
            "安装基础依赖" \
            "防火墙：放行已装协议端口" \
            "开启 BBR" \
            "开启 TCP Fast Open" \
            "查询端口占用" \
            "设置 GitHub 镜像前缀" \
            "重新检测公网 IP" \
            "本机信息")" || return 0
        case "$c" in
            0) return 0 ;;
            1) os_dep_install base qr acme && px_ok "依赖就绪"; px_pause ;;
            2) _sys_open_ports; px_pause ;;
            3) if net_bbr_enable; then px_ok "BBR 已开启（sysctl 已生效）"; else px_err "BBR 开启失败（内核可能不支持）"; fi; px_pause ;;
            4) if net_tfo_enable; then px_ok "TFO 已开启"; else px_err "TFO 开启失败"; fi; px_pause ;;
            5) local p
               p="$(px_ask "端口号" "")"
               [[ -n "$p" ]] && { net_port_in_use "$p" tcp && px_warn "TCP $p 已占用" || px_ok "TCP $p 空闲"
                                   net_port_in_use "$p" udp && px_warn "UDP $p 已占用" || px_ok "UDP $p 空闲"; }
               px_pause ;;
            6) local m
               m="$(px_ask "镜像前缀（如 https://gh-proxy.net，留空则直连）" "$(db_setting gh_proxy)")"
               db_setting gh_proxy "$m" && px_ok "已保存：${m:-直连}"; px_pause ;;
            7) local ip
               ip="$(net_primary_ip)"
               if [[ -n "$ip" ]]; then
                   db_setting ip "$ip"
                   px_ok "公网 IP：$ip"
               else
                   px_warn "检测失败（可手动 db 设置）"
               fi
               px_pause ;;
            8) px_kv "脚本版本" "$PX_VERSION"
               px_kv "系统" "$PX_OS_ID $PX_OS_VER"
               px_kv "架构" "$PX_ARCH"
               px_kv "防火墙后端" "$(net_fw_backend)"
               px_kv "BBR" "$(net_bbr_status)"
               px_kv "TFO" "$(net_tfo_status)"
               px_kv "公网 IP" "$(db_setting ip)"
               px_pause ;;
        esac
    done
}

_sys_open_ports() {
    local k port
    for k in "${PX_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        port="$(db_get "$k" port "")"
        [[ -z "$port" ]] && continue
        # 传输方式按协议实际监听决定：HY2 仅 UDP，SS-Rust 两者都要，其余 TCP
        case "$k" in
            hysteria2)
                net_fw_allow "$port" udp "px-$k" && px_ok "放行 $(px_title_of "$k") udp/$port" ;;
            ss_rust)
                net_fw_allow "$port" tcp "px-$k" && px_ok "放行 $(px_title_of "$k") tcp/$port"
                net_fw_allow "$port" udp "px-$k" && px_ok "放行 $(px_title_of "$k") udp/$port" ;;
            *)
                net_fw_allow "$port" tcp "px-$k" && px_ok "放行 $(px_title_of "$k") tcp/$port" ;;
        esac
    done
}

# ---------- 6. 备份 / 恢复 / 卸载 ----------

menu_backup() {
    while true; do
        local c
        c="$(px_menu "备份与恢复" \
            "全量备份（/etc/px → tar.gz）" \
            "从备份恢复" \
            "卸载单个协议" \
            "卸载全部协议")" || return 0
        case "$c" in
            0) return 0 ;;
            1) _bk_backup; px_pause ;;
            2) _bk_restore; px_pause ;;
            3) menu_manage ;;
            4) _bk_uninstall_all; px_pause ;;
        esac
    done
}

_bk_backup() {
    local f
    f="/root/px-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar -czf "$f" -C / etc/px 2>/dev/null; then
        chmod 600 "$f"
        px_ok "备份完成：$f"
        px_kv "大小" "$(du -h "$f" | awk '{print $1}')"
    else
        px_err "备份失败"
    fi
}

_bk_restore() {
    local f
    f="$(px_ask "备份文件路径" "")"
    [[ -f "$f" ]] || { px_err "文件不存在"; return 1; }
    px_confirm "恢复会覆盖 /etc/px，继续？" n || return 0
    tar -xzf "$f" -C / || { px_err "解压失败"; return 1; }
    db_init
    px_ok "已恢复，建议到节点管理里逐个重生成并重启"
}

_bk_uninstall_all() {
    px_confirm "确认卸载全部协议（不删除脚本本体）？" n || return 0
    local k
    for k in "${PX_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        PX_YES=1 px_call "$k" uninstall
    done
    px_ok "全部协议已卸载"
}

# ---------- 7. 更新 ----------

menu_update() {
    while true; do
        local c
        c="$(px_menu "更新与版本" \
            "脚本自更新（需 PX_UPDATE_URL）" \
            "查看已装内核版本" \
            "查看本机已装协议")" || return 0
        case "$c" in
            0) return 0 ;;
            1) _up_self; px_pause ;;
            2) _up_kernels; px_pause ;;
            3) _up_installed; px_pause ;;
        esac
    done
}

# 首次从任意路径运行时，把自身装成 px 命令，方便以后直接输入 px
px_self_install() {
    local src="${BASH_SOURCE[0]:-}"
    [[ -n "$src" && -f "$src" ]] || return 0
    [[ "$src" == "$PX_ENTRY" ]] && return 0
    command -v install >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$PX_ENTRY")" 2>/dev/null || return 0
    if install -m 755 "$src" "$PX_ENTRY" 2>/dev/null; then
        px_ok "已安装命令：$PX_ENTRY（以后直接输入 px）"
    fi
}

_up_self() {
    if [[ -z "${PX_UPDATE_URL:-}" ]]; then
        px_warn "未设置 PX_UPDATE_URL，跳过自更新"
        px_info "手动：curl -fsSL <你的发布地址> -o $PX_ENTRY && chmod +x $PX_ENTRY"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    if dl_fetch "$PX_UPDATE_URL" "$tmp"; then
        bash -n "$tmp" || { rm -f "$tmp"; px_err "下载内容不是合法脚本"; return 1; }
        install -m 755 "$tmp" "$PX_ENTRY" && px_ok "已更新到最新版本"
        rm -f "$tmp"
        px_info "重新执行 px 生效"
    else
        px_err "下载失败"
    fi
}

_up_kernels() {
    local -a bins=(xray hysteria snell-server ssserver anytls-server shadow-tls)
    local b v
    for b in "${bins[@]}"; do
        if command -v "$b" >/dev/null 2>&1; then
            v="$("$b" --version 2>/dev/null | head -1 || true)"
            [[ -z "$v" ]] && v="$("$b" version 2>/dev/null | head -1 || true)"
            printf '  %-18s %s\n' "$b" "${v:-已安装}"
        fi
    done
}

_up_installed() {
    local k
    for k in "${PX_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        px_kv "$(px_title_of "$k")" "$(db_get "$k" port "-") / $(px_status_line "$k")"
    done
}

# ---------- 主菜单 ----------

main_menu() {
    while true; do
        px_banner
        local c
        c="$(px_menu "主菜单" \
            "安装协议" \
            "节点管理" \
            "证书管理" \
            "订阅与分享" \
            "系统工具" \
            "备份与恢复" \
            "更新与版本")" || return 0
        case "$c" in
            0) printf '\n%b再见%b\n\n' "$C_DIM" "$C_N"; return 0 ;;
            1) menu_install ;;
            2) menu_manage ;;
            3) menu_cert ;;
            4) menu_sub ;;
            5) menu_system ;;
            6) menu_backup ;;
            7) menu_update ;;
        esac
    done
}

# ---------- CLI ----------

cli_list() {
    local k
    printf '%-16s %-8s %-7s %s\n' "KEY" "端口" "状态" "说明"
    for k in "${PX_PROTOS[@]}"; do
        printf '%-16s %-8s %-7s %s\n' "$k" "$(db_get "$k" port '-')" \
            "$(db_is_installed "$k" && px_status_line "$k" || echo 未安装)" \
            "$(px_meta_field "$k" desc)"
    done
}

cli_status() {
    local k
    if [[ "$PX_ARG_FORMAT" == "json" ]]; then
        local out='{"version":"'"$PX_VERSION"'","os":"'"$PX_OS_ID"'","arch":"'"$PX_ARCH"'","protos":{'
        local first=1 inst
        for k in "${PX_PROTOS[@]}"; do
            [[ "$first" == "1" ]] || out+=','
            first=0
            if db_is_installed "$k"; then inst="true"; else inst="false"; fi
            out+="\"$k\":{\"installed\":$inst,\"port\":\"$(db_get "$k" port '')\",\"status\":\"$(px_status_line "$k")\",\"unit\":\"$(px_unit_name "$k")\"}"
        done
        out+='}}'
        printf '%s\n' "$out" | jq .
        return 0
    fi
    printf '%-16s %-8s %s\n' "协议" "端口" "状态"
    for k in "${PX_PROTOS[@]}"; do
        printf '%-16s %-8s %s\n' "$(px_title_of "$k")" "$(db_get "$k" port '-')" "$(px_status_line "$k")"
    done
}

cli_link() {
    local k="$PX_CLI_KEY"
    [[ -z "$k" ]] && px_die "--link 需要协议 key"
    db_is_installed "$k" || px_die "$(px_title_of "$k") 未安装"
    case "${PX_ARG_FORMAT:-uri}" in
        uri|"") px_call "$k" link ;;
        clash)  px_call "$k" clash ;;
        surge)  px_call "$k" surge ;;
        singbox|sing-box) px_call "$k" singbox ;;
        qr) px_call "$k" link | head -1 | while read -r l; do share_qr "$l"; done ;;
        *) px_die "未知格式：$PX_ARG_FORMAT（uri|clash|surge|singbox|qr）" ;;
    esac
}

cli_run() {
    case "$PX_CLI_ACTION" in
        install)   db_is_installed "$PX_CLI_KEY" && px_die "$(px_title_of "$PX_CLI_KEY") 已安装"
                   px_call "$PX_CLI_KEY" install ;;
        uninstall) db_is_installed "$PX_CLI_KEY" || px_die "$(px_title_of "$PX_CLI_KEY") 未安装"
                   px_call "$PX_CLI_KEY" uninstall ;;
        regen)     px_call "$PX_CLI_KEY" regen ;;
        link)      cli_link ;;
        status)    cli_status ;;
        list)      cli_list ;;
        cert-status) cert_status ;;
        check-ip)  local ip; ip="$(net_primary_ip)"; [[ -n "$ip" ]] && { db_setting ip "$ip"; printf '%s\n' "$ip"; } || px_die "检测失败" ;;
        help|"")   px_usage ;;
        version)   printf 'px %s\n' "$PX_VERSION" ;;
        *)         px_die "未知动作：$PX_CLI_ACTION" ;;
    esac
}

px_usage() {
    cat <<'EOF'
PX 综合代理脚本 P0

用法：
  px                                    交互菜单
  px --install <key> [--port N] [--domain D] [--sni S] [--cert-mode M] [--yes]
  px --uninstall <key> [--yes]
  px --regen <key>
  px --link <key> [--format uri|clash|surge|singbox|qr]
  px --status [--format json]
  px --list
  px --cert-status
  px --check-ip
  px --version | --help

协议 key：vless_reality  hysteria2  snell  ss_rust  anytls
EOF
}

px_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install|--uninstall|--regen|--link)
                [[ -n "${2:-}" ]] || px_die "$1 需要协议 key"
                PX_CLI_ACTION="${1#--}"
                PX_CLI_KEY="$2"; shift 2 ;;
            --status|--list|--cert-status|--check-ip|--version|--help)
                PX_CLI_ACTION="${1#--}"; shift ;;
            --port)   [[ -n "${2:-}" ]] || px_die "--port 需要端口"; PX_ARG_PORT="$2"; shift 2 ;;
            --domain) [[ -n "${2:-}" ]] || px_die "--domain 需要域名"; PX_ARG_DOMAIN="$2"; shift 2 ;;
            --sni)    [[ -n "${2:-}" ]] || px_die "--sni 需要值"; PX_ARG_SNI="$2"; shift 2 ;;
            --cert-mode) [[ -n "${2:-}" ]] || px_die "--cert-mode 需要值"; PX_ARG_CERT_MODE="$2"; shift 2 ;;
            --format) [[ -n "${2:-}" ]] || px_die "--format 需要值"; PX_ARG_FORMAT="$2"; shift 2 ;;
            -y|--yes) PX_YES=1; shift ;;
            *) px_die "未知参数：$1（--help 查看用法）" ;;
        esac
    done
    if [[ -n "$PX_CLI_KEY" ]]; then
        px_key_valid "$PX_CLI_KEY" || px_die "未知协议 key：$PX_CLI_KEY（可用：${PX_PROTOS[*]}）"
    fi
}

main() {
    # --help/--version 不需要 root，也不该触发系统探测与依赖安装
    case "${1:-}" in
        --help|-h) px_usage; return 0 ;;
        --version|-V) printf 'px %s\n' "$PX_VERSION"; return 0 ;;
    esac
    px_require_root
    os_detect
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v jq >/dev/null 2>&1; then
        os_dep_install base || px_die "基础依赖安装失败，无法继续"
    fi
    db_init
    px_parse_args "$@"
    if [[ -n "$PX_CLI_ACTION" ]]; then
        cli_run
        return $?
    fi
    px_self_install
    main_menu
}

main "$@"

