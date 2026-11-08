#!/usr/bin/env bash
# =============================================================================
# OneClick —— 一键多协议代理安装器
# 支持：VLESS-Reality / Hysteria2 / Snell v6 / SS-Rust(+ShadowTLS v3) / AnyTLS
# 仓库：https://github.com/justin0406/oneclick
# 说明：单用户设计。融合自 hysteria-install / Snell.sh / Shadowsocks-Rust /
#       jinqians menu / surge，署名与授权边界见 NOTICE.md。
# =============================================================================

umask 077

OC_VERSION="0.1.0"
OC_ROOT="${OC_ROOT:-/etc/oneclick}"
OC_DB="${OC_DB:-$OC_ROOT/db.json}"
OC_CERT_DIR="$OC_ROOT/certs"
OC_SUB_DIR="$OC_ROOT/sub"
OC_LOG_DIR="${OC_LOG_DIR:-/var/log/oneclick}"
OC_BIN_DIR="${OC_BIN_DIR:-/usr/local/bin}"
OC_ENTRY="$OC_BIN_DIR/oneclick"
OC_UNIT_DIR="${OC_UNIT_DIR:-/etc/systemd/system}"

OC_OS_ID=""
OC_OS_VER=""
OC_ARCH=""
OC_YES="${OC_YES:-0}"
OC_GH_PROXY="${OC_GH_PROXY:-}"

OC_ARG_PORT=""
OC_ARG_DOMAIN=""
OC_ARG_SNI=""
OC_ARG_CERT_MODE=""
OC_ARG_FORMAT=""
OC_CLI_ACTION=""
OC_CLI_KEY=""

# 协议注册表：key 用下划线（函数名可用），展示名与 unit 用连字符
OC_PROTOS=(vless_reality hysteria2 snell ss_rust anytls)

declare -gA OC_PROTO_TITLE=(
    [vless_reality]="VLESS-Reality"
    [hysteria2]="Hysteria2"
    [snell]="Snell v6"
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
