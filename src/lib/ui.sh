#!/usr/bin/env bash
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
