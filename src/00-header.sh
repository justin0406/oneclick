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
