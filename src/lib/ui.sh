#!/usr/bin/env bash
# lib/ui.sh —— 颜色、日志、交互、菜单

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'
    C_C=$'\033[36m'; C_M=$'\033[35m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_M=""; C_BOLD=""; C_DIM=""; C_N=""
fi

oc_info() { printf '%b[*]%b %s\n' "$C_C" "$C_N" "$*"; }
oc_ok()   { printf '%b[✓]%b %s\n' "$C_G" "$C_N" "$*"; }
oc_warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*" >&2; }
oc_err()  { printf '%b[✗]%b %s\n' "$C_R" "$C_N" "$*" >&2; }
oc_die()  { oc_err "$1"; exit "${2:-1}"; }

oc_hr() { printf '%b%s%b\n' "$C_DIM" "────────────────────────────────────────────────────────" "$C_N"; }

oc_title() {
    printf '\n%b%s%b\n' "$C_BOLD$C_C" "== $* ==" "$C_N"
}

# 终端显示宽度：CJK 一个字符占 2 列，printf 的 %-Ns 按字节补齐会对不齐。
# GNU wc -L 能给出显示宽度（coreutils），没有该选项时退回字符数。
oc_display_width() {
    local s="$1" w
    # 注意补换行：macOS 的 BSD wc -L 对无结尾换行的输入返回 0
    if w="$(printf '%s\n' "$s" | wc -L 2>/dev/null)"; then
        w="${w//[[:space:]]/}"
        if [[ "$w" =~ ^[0-9]+$ ]]; then
            printf '%s' "$w"
            return 0
        fi
    fi
    printf '%s' "${#s}"
}

oc_kv() {
    local label="$1" val="$2" w pad
    w="$(oc_display_width "$label")"
    pad=$((24 - w))
    ((pad < 1)) && pad=1
    printf '  %b%s%b%*s%s\n' "$C_DIM" "$label" "$C_N" "$pad" "" "$val"
}

# ---------- 版式 ----------

# 终端宽度：优先 tput，其次 COLUMNS，最后 80
oc_term_cols() {
    local c=""
    [[ -t 1 ]] && c="$(tput cols 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9]+$ ]] || c="${COLUMNS:-80}"
    [[ "$c" =~ ^[0-9]+$ ]] || c=80
    printf '%s' "$c"
}

# 面板总宽：留 2 列边距，限制 48~74，窄屏自动收窄
oc_panel_width() {
    local w
    w=$(( $(oc_term_cols) - 2 ))
    ((w > 74)) && w=74
    ((w < 48)) && w=48
    printf '%s' "$w"
}

oc_repeat() {
    local ch="$1" n="$2" i out=""
    for ((i = 0; i < n; i++)); do out+="$ch"; done
    printf '%s' "$out"
}

oc_truncate() {
    local s="$1" max="$2"
    while [[ -n "$s" ]] && (( $(oc_display_width "$s") > max )); do
        s="${s%?}"
    done
    printf '%s' "$s"
}

oc_clear() {
    if [[ -t 1 && "${OC_NO_CLEAR:-0}" != "1" ]]; then
        printf '\033[H\033[2J'
    else
        printf '\n'
    fi
}

# 标题框：左标题加粗、右标题暗色，按显示宽度对齐
oc_panel() {
    local left="$1" right="${2:-}" w iw lw rw pad bar
    w="$(oc_panel_width)"; iw=$((w - 4))
    rw="$(oc_display_width "$right")"
    lw="$(oc_display_width "$left")"
    if ((lw + rw + 1 > iw)); then
        right="$(oc_truncate "$right" $((iw - lw - 1)))"
        rw="$(oc_display_width "$right")"
    fi
    pad=$((iw - lw - rw)); ((pad < 1)) && pad=1
    bar="$(oc_repeat '─' "$((w - 2))")"
    printf '%b╭%s╮%b\n' "$C_DIM" "$bar" "$C_N"
    printf '%b│%b %b%s%b%*s%b%s%b %b│%b\n' \
        "$C_DIM" "$C_N" "$C_BOLD$C_C" "$left" "$C_N" "$pad" "" \
        "$C_DIM" "$right" "$C_N" "$C_DIM" "$C_N"
    printf '%b╰%s╯%b\n' "$C_DIM" "$bar" "$C_N"
}

# 系统状态：负载 / 内存 / 运行时长（Linux 读 /proc，macOS 走 uptime/sysctl）
oc_stat_load() {
    local l=""
    [[ -r /proc/loadavg ]] && read -r l _ < /proc/loadavg
    [[ -z "$l" ]] && l="$(uptime 2>/dev/null | sed -n 's/.*load averages*: *\([0-9.]*\).*/\1/p')"
    printf '%s' "$l"
}

oc_stat_mem() {
    local total avail pct=""
    if [[ -r /proc/meminfo ]]; then
        total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
        avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
        if [[ "$total" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] && ((total > 0)); then
            pct=$(((total - avail) * 100 / total))
        fi
    fi
    printf '%s' "$pct"
}

oc_stat_uptime() {
    local s="" d h m
    if [[ -r /proc/uptime ]]; then
        read -r s _ < /proc/uptime
        s="${s%%.*}"
    fi
    if [[ -z "$s" ]]; then
        # 注意避开 usec 里的 "sec = "（贪婪匹配会取到 usec）
        s="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*[{ ]sec = \([0-9]*\).*/\1/p')"
        [[ -n "$s" ]] && s=$(( $(date +%s) - s ))
    fi
    [[ "$s" =~ ^[0-9]+$ ]] || return 0
    d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if ((d > 0)); then printf '%dd %dh' "$d" "$h"
    elif ((h > 0)); then printf '%dh %dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# 单行状态：IP   负载 x   内存 x%   运行 x
oc_sysline() {
    local ip="$1" load mem up first=1 seg label val
    load="$(oc_stat_load)"; mem="$(oc_stat_mem)"; up="$(oc_stat_uptime)"
    printf '  '
    if [[ -n "$ip" ]]; then
        printf '%s' "$ip"; first=0
    fi
    for seg in "负载:$load" "内存:${mem:+$mem%}" "运行:$up"; do
        label="${seg%%:*}"; val="${seg#*:}"
        [[ -z "$val" ]] && continue
        [[ "$first" == "1" ]] || printf '    '
        printf '%b%s%b %s' "$C_DIM" "$label" "$C_N" "$val"
        first=0
    done
    [[ "$first" == "1" ]] && printf '%b无系统信息%b' "$C_DIM" "$C_N"
    printf '\n'
}

oc_dot_symbol() {
    case "$1" in
        运行中)        printf '%b●%b' "$C_G" "$C_N" ;;
        已停止)        printf '%b●%b' "$C_Y" "$C_N" ;;
        failed|未知)   printf '%b●%b' "$C_R" "$C_N" ;;
        *)             printf '%b○%b' "$C_DIM" "$C_N" ;;
    esac
}

# 节点点阵：参数为 "状态|名称:端口"，按面板宽度自动换行
oc_dots() {
    local w iw line_w=0 first=1 it st tx item_w
    w="$(oc_panel_width)"; iw=$((w - 2))
    if (($# == 0)); then
        printf '  %b无节点%b\n' "$C_DIM" "$C_N"
        return 0
    fi
    printf '  '
    for it in "$@"; do
        st="${it%%|*}"; tx="${it#*|}"
        item_w=$((3 + $(oc_display_width "$tx")))
        if ((!first && line_w + 3 + item_w > iw)); then
            printf '\n  '; line_w=0; first=1
        fi
        [[ "$first" == "1" ]] || printf '   '
        oc_dot_symbol "$st"
        printf ' %s' "$tx"
        if [[ "$first" == "1" ]]; then
            line_w=$((line_w + item_w))
        else
            line_w=$((line_w + item_w + 3))
        fi
        first=0
    done
    printf '\n'
}

# 确认：OC_YES=1 时直接按默认值返回
oc_confirm() {
    local prompt="$1" def="${2:-y}" ans
    if [[ "$OC_YES" == "1" ]]; then
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
            *) oc_warn "请输入 y 或 n" ;;
        esac
    done
}

# 提问：stdout 输出答案（空则默认值）
oc_ask() {
    local prompt="$1" def="${2:-}" ans
    if [[ "$OC_YES" == "1" && -n "$def" ]]; then
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

# 提问并把答案写进指定变量：不经 $(...) 子壳，提示和 read 都在当前 shell 里跑。
# oc_ask "$(...)" 在部分终端/重定向下会丢掉提示，只剩一个看不见的等待。
# oc_ask_into <变量名> <提示> [默认值]
oc_ask_into() {
    local __var="$1" prompt="$2" def="${3:-}" ans
    if [[ "$OC_YES" == "1" && -n "$def" ]]; then
        printf -v "$__var" '%s' "$def"
        return 0
    fi
    if [[ -n "$def" ]]; then
        printf '%b%s%b [%s]: ' "$C_Y" "$prompt" "$C_N" "$def" >&2
    else
        printf '%b%s%b: ' "$C_Y" "$prompt" "$C_N" >&2
    fi
    read -r ans || ans=""
    printf -v "$__var" '%s' "${ans:-$def}"
}

# 不回显提问
oc_ask_secret() {
    local prompt="$1" ans
    printf '%b%s%b: ' "$C_Y" "$prompt" "$C_N" >&2
    read -rs ans || ans=""
    printf '\n' >&2
    printf '%s' "$ans"
}

# 菜单：stdout 输出编号（0 = 返回）
oc_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local i sel nw
    nw=1
    ((${#items[@]} + 1 >= 10)) && nw=2
    printf '\n  %b%s%b\n' "$C_BOLD" "$title" "$C_N" >&2
    for i in "${!items[@]}"; do
        printf '  %b%*d%b  %s\n' "$C_C" "$nw" "$((i + 1))" "$C_N" "${items[$i]}" >&2
    done
    printf '  %b%*d%b  %b%s%b\n' "$C_C" "$nw" 0 "$C_N" "$C_DIM" "${OC_MENU_ZERO_LABEL:-返回}" "$C_N" >&2
    while true; do
        printf '%b请选择 [0-%d]: %b' "$C_Y" "${#items[@]}" "$C_N" >&2
        if ! read -r sel; then return 1; fi
        sel="${sel//[[:space:]]/}"
        if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 0 && sel <= ${#items[@]})); then
            printf '%s' "$sel"
            return 0
        fi
        oc_warn "输入无效，请重新选择"
    done
}

oc_pause() {
    [[ "$OC_YES" == "1" ]] && return 0
    printf '%b按回车继续...%b' "$C_DIM" "$C_N"
    read -r _ || true
}
