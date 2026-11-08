#!/usr/bin/env bash
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
