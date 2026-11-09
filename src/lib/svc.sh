#!/usr/bin/env bash
# lib/svc.sh —— systemd 单后端封装

svc_unit_path() { printf '%s/%s.service' "$OC_UNIT_DIR" "$1"; }

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

# 二进制是否仍被"非 OneClick"的 systemd 单元引用（例如 x-ui 也用 /usr/local/bin/xray，
# 用户原有 snell-server.service 也用 /usr/local/bin/snell-server）。卸载时用它决定删不删。
svc_bin_referenced() {
    local bin="$1" f
    [[ -n "$bin" && -e "$bin" ]] || return 1
    for f in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
        [[ -f "$f" ]] || continue
        case "$(basename -- "$f")" in oneclick-*) continue ;; esac
        grep -qF -- "$bin" "$f" 2>/dev/null && return 0
    done
    return 1
}

