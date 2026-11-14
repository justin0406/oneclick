#!/usr/bin/env bash
# =============================================================================
# OneClick —— 一键多协议代理安装器
# 支持：VLESS-Reality / Hysteria2 / Snell v6 / SS-Rust(+ShadowTLS v3) / AnyTLS
# 仓库：https://github.com/justin0406/oneclick
# 说明：单用户设计。融合自 hysteria-install / Snell.sh / Shadowsocks-Rust /
#       jinqians menu / surge，署名与授权边界见 NOTICE.md。
# =============================================================================

umask 077

# 本脚本用到了 bash 4+ 的特性（declare -gA 关联数组、${var,,} 大小写转换），
# 在 bash 3.2（macOS 自带）上会以难懂的 unbound variable 崩掉，这里提前给明确提示。
if (( BASH_VERSINFO[0] < 4 )); then
    printf '[✗] 需要 bash 4.0 或更高版本（当前 %s）。\n' "${BASH_VERSION:-未知}" >&2
    printf '    Debian/Ubuntu 上请用 bash 运行本脚本；CentOS 7 需先安装 bash5。\n' >&2
    exit 1
fi

OC_VERSION="0.9.1"
OC_ROOT="${OC_ROOT:-/etc/oneclick}"
OC_DB="${OC_DB:-$OC_ROOT/db.json}"
OC_CERT_DIR="$OC_ROOT/certs"
OC_SUB_DIR="$OC_ROOT/sub"
# 内核放私有目录，不碰 /usr/local/bin；/usr/local/bin 只放一个入口（卸载时删除）
OC_BIN_ROOT="${OC_BIN_ROOT:-/opt/oneclick}"
OC_BIN_DIR="${OC_BIN_DIR:-$OC_BIN_ROOT/bin}"
OC_ENTRY_DIR="${OC_ENTRY_DIR:-/usr/local/bin}"
OC_ENTRY="$OC_ENTRY_DIR/oneclick"
OC_UNIT_DIR="${OC_UNIT_DIR:-/etc/systemd/system}"

OC_OS_ID=""
OC_OS_VER=""
OC_ARCH=""
OC_YES="${OC_YES:-0}"
OC_GH_PROXY="${OC_GH_PROXY:-}"
# 默认端口不再写死：新装协议从该区间随机挑空闲高位端口
OC_PORT_MIN="${OC_PORT_MIN:-20000}"
OC_PORT_MAX="${OC_PORT_MAX:-60000}"
# 自动更新：每次运行读取该地址的 OC_VERSION，比本地新则自动替换自身
OC_UPDATE_URL="${OC_UPDATE_URL:-https://raw.githubusercontent.com/justin0406/oneclick/main/dist/oneclick.sh}"
OC_NO_UPDATE="${OC_NO_UPDATE:-0}"

OC_ARG_PORT=""
OC_ARG_DOMAIN=""
OC_ARG_SNI=""
OC_ARG_METHOD=""
OC_ARG_CERT_MODE=""
OC_ARG_FORMAT=""
OC_ARG_VERSION=""
OC_ARG_SNELL_MAJOR=""
OC_CLI_ACTION=""
OC_CLI_KEY=""
# 原始参数（自动更新后 exec 自身时复用）
OC_ARGV=()

# 协议注册表：key 用下划线（函数名可用），展示名与 unit 用连字符
OC_PROTOS=(vless_reality hysteria2 snell ss_rust anytls)

declare -gA OC_PROTO_TITLE=(
    [vless_reality]="VLESS-Reality"
    [hysteria2]="Hysteria2"
    [snell]="Snell"
    [ss_rust]="SS-Rust"
    [anytls]="AnyTLS"
)
declare -gA OC_PROTO_ORDER=(
    [vless_reality]=10
    [hysteria2]=20
    [snell]=30
    [ss_rust]=40
    [anytls]=50
)

# 协议 key -> unit 名：vless_reality -> oneclick-vless-reality
oc_unit_name() { printf 'oneclick-%s' "${1//_/-}"; }
# 协议 key -> 配置目录：/etc/oneclick/vless_reality
oc_proto_dir() { printf '%s/%s' "$OC_ROOT" "$1"; }
