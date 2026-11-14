#!/usr/bin/env bash
# lib/upgrade.sh —— 内核升级的通用骨架
#
# 设计原则（与安装路径区分开）：
#   - 安装只负责"装到能跑"，升级要负责"换了还能跑，跑不了就退回去"。
#   - 流程：下载到临时位置 → 校验 → 备份旧二进制 → 替换 → 配置自检（若有）
#     → 重启并确认存活 → 失败则还原并重启旧版 → 成功才删备份。
#   - 备份必须留到"重启后确认存活"为止：hysteria / ssserver 没有配置自检命令，
#     唯一能发现不兼容的时刻就是启动失败，那时备份若已删就没法回滚。
#   - 升级不改配置、不换端口/凭据，只换二进制。

# 已装二进制能否正常执行（不同内核参数不同，逐个试）
oc_bin_runnable() {
    local bin="$1"
    [[ -x "$bin" ]] || return 1
    "$bin" version >/dev/null 2>&1 && return 0
    "$bin" --version >/dev/null 2>&1 && return 0
    "$bin" -V >/dev/null 2>&1 && return 0
    "$bin" -h >/dev/null 2>&1 && return 0
    return 1
}

# 从二进制的版本输出里抓第一个形如 x.y.z 的版本号
# （各内核输出格式差异大：hysteria 带 ASCII art，snell 带时间戳）
oc_bin_version() {
    local bin="$1" out=""
    [[ -x "$bin" ]] || return 1
    # 三种参数都试并合并输出：不同内核支持的子命令不同，且不支持的参数会
    # 打印错误文本而不是空（如 ssserver version 报 unexpected argument），
    # 逐次判断"是否为空"会被错误文本骗过去，拿不到真正的版本号。
    out+="$("$bin" version 2>&1 || true)"$'\n'
    out+="$("$bin" --version 2>&1 || true)"$'\n'
    out+="$("$bin" -V 2>&1 || true)"$'\n'
    # 只认 v 前缀或独立的 x.y.z，避开时间戳里的小数（如 34.504121）
    printf '%s' "$out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+' \
        | head -n1 | sed 's/^v//'
}

# 升级会话：备份路径由调用方持有，成功收尾时删除
# 用法：
#   bak="$(oc_upgrade_begin "$target")" || return 1
#   oc_upgrade_install "$newbin" "$target" || { 失败已自动还原; return 1; }
#   oc_upgrade_commit "$bak"          # 确认新版本可用后调用
#   oc_upgrade_rollback "$bak" "$target"

# oc_upgrade_begin <target> -> stdout 输出备份路径
oc_upgrade_begin() {
    local target="$1" bak
    [[ -x "$target" ]] || { oc_err "目标二进制不存在：$target"; return 1; }
    bak="${target}.bak.$$"
    if ! cp -f -- "$target" "$bak" 2>/dev/null; then
        oc_err "备份旧二进制失败：$target"
        return 1
    fi
    printf '%s' "$bak"
}

# oc_upgrade_install <newbin> <target>：替换，失败自动还原
oc_upgrade_install() {
    local newbin="$1" target="$2"
    if ! install -m 755 "$newbin" "$target" 2>/dev/null; then
        oc_err "替换二进制失败：$target"
        return 1
    fi
    return 0
}

# oc_upgrade_commit <bak>：删除备份，升级完成
oc_upgrade_commit() {
    local bak="$1"
    [[ -n "$bak" && -f "$bak" ]] && rm -f -- "$bak"
    return 0
}

# oc_upgrade_rollback <bak> <target>：还原并清理
oc_upgrade_rollback() {
    local bak="$1" target="$2"
    if [[ -n "$bak" && -f "$bak" ]]; then
        if mv -f -- "$bak" "$target" 2>/dev/null; then
            chmod 755 "$target" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

# oc_upgrade_service_restart <unit> <was_active>
# 只在升级前处于运行状态的服务才重启（get.hy2.sh 的 restart_running_services
# 同款语义）：用户手动停掉的服务，升级不该把它拉起来——新二进制在下次
# 手动启动时自然生效。was_active=1 时重启并确认存活，0 时什么都不做。
oc_upgrade_service_restart() {
    local unit="$1" was_active="${2:-1}"
    [[ "$was_active" == "1" ]] || return 0
    svc_restart "$unit"
    sleep 2
    svc_is_active "$unit"
}

# 打印升级前后版本对照
_oc_upgrade_report() {
    local name="$1" old="$2" new="$3"
    oc_kv "$name" "${old:-未知} → ${new:-未知}"
}
