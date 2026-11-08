#!/usr/bin/env bash
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
