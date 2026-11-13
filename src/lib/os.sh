#!/usr/bin/env bash
# lib/os.sh —— 系统识别、包管理、随机数、通用小工具

os_detect() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OC_OS_ID="${ID:-unknown}"
        OC_OS_VER="${VERSION_ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        OC_OS_ID="centos"; OC_OS_VER="unknown"
    else
        OC_OS_ID="unknown"; OC_OS_VER="unknown"
    fi
    case "$(uname -m)" in
        x86_64|amd64)   OC_ARCH="amd64" ;;
        aarch64|arm64)  OC_ARCH="arm64" ;;
        armv7l|armv7*)  OC_ARCH="armv7l" ;;
        i386|i686)      OC_ARCH="i386" ;;
        *)              OC_ARCH="$(uname -m)" ;;
    esac
}

os_family() {
    case "$OC_OS_ID" in
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
    oc_info "安装系统依赖：${need[*]}"
    case "$(os_family)" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 || oc_warn "apt-get update 失败，继续尝试安装"
            if ! apt-get install -y -qq "${need[@]}" >/dev/null 2>&1; then
                oc_err "依赖安装失败：${need[*]}"
                return 1
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y -q "${need[@]}" >/dev/null 2>&1 || { oc_err "dnf 安装失败"; return 1; }
            else
                yum install -y -q "${need[@]}" >/dev/null 2>&1 || { oc_err "yum 安装失败"; return 1; }
            fi
            ;;
        *)
            oc_err "不支持的发行版：$OC_OS_ID，请手动安装：${need[*]}"
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
            *)    oc_warn "未知依赖项：$f" ;;
        esac
    done
    [ ${#want[@]} -eq 0 ] && return 0
    os_pkg_install "${want[@]}"
}

os_service_reload() { systemctl daemon-reload >/dev/null 2>&1 || true; }

# 本脚本只用 systemd 管服务。容器/LXC/WSL 里没有 systemd 时，
# 以前会一路装完 unit、二进制、证书，最后服务起不来；这里提前拒绝。
oc_require_systemd() {
    [[ -d /run/systemd/system ]] && return 0
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
        return 0
    fi
    oc_die "未检测到运行中的 systemd（容器 / LXC / WSL？）。
  本脚本通过 systemd 管理服务，请换到带 systemd 的系统运行。
  若只想清理旧安装，可用 oneclick --purge"
}

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

oc_require_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || oc_die "请用 root 运行（sudo -i 后重试）"
}

oc_require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || oc_die "缺少命令：$c"
    done
}
