#!/usr/bin/env bash
# 99-menu.sh —— 菜单装配 + CLI 入口 + main

# ---------- 协议小工具 ----------

oc_key_valid() {
    local k
    for k in "${OC_PROTOS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
    return 1
}

oc_title_of() { printf '%s' "${OC_PROTO_TITLE[$1]:-$1}"; }

# 动态调度 proto 函数
oc_call() {
    local k="$1" suf="$2"; shift 2
    "proto_${k}_${suf}" "$@"
}

# 从 meta 输出取字段
oc_meta_field() {
    local k="$1" f="$2"
    oc_call "$k" meta 2>/dev/null | awk -F= -v f="$f" '$1==f{sub(/^[^=]*=/, ""); print; exit}'
}

oc_status_line() {
    local k="$1" st
    if ! db_is_installed "$k"; then
        printf '未安装'
        return 0
    fi
    st="$(oc_call "$k" status 2>/dev/null | head -1)"
    printf '%s' "${st:-未知}"
}

# ---------- 首屏 ----------

oc_banner() {
    local ip
    ip="$(db_setting ip)"
    printf '\n%b%s%b  %bv%s%b\n' "$C_BOLD$C_C" "OneClick 一键代理" "$C_N" "$C_DIM" "$OC_VERSION" "$C_N"
    oc_kv "系统" "$OC_OS_ID $OC_OS_VER / $OC_ARCH"
    oc_kv "公网 IP" "${ip:-未检测}"
    local k line="" n=0
    for k in "${OC_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        n=$((n + 1))
        line+="$(oc_title_of "$k"):$(db_get "$k" port "-")($(oc_status_line "$k" | grep -oE '运行中|已停止|failed|未知' || echo '?'))  "
    done
    if ((n > 0)); then
        oc_kv "已装协议" "$line"
    else
        oc_kv "已装协议" "无"
    fi
    oc_hr
}

# ---------- 1. 安装 ----------

menu_install() {
    local -a items=() keys=()
    local k label installed port cert
    for k in "${OC_PROTOS[@]}"; do
        port="$(oc_meta_field "$k" port)"
        cert="$(oc_meta_field "$k" cert)"
        if db_is_installed "$k"; then installed=" [已安装]"; else installed=""; fi
        label="$(oc_title_of "$k")  — $(oc_meta_field "$k" desc)"
        if [[ "$cert" == "yes" ]]; then
            label+="  （需证书）"
        fi
        items+=("$label$installed")
        keys+=("$k")
    done
    local sel
    sel="$(oc_menu "安装协议" "${items[@]}")" || return 0
    [[ "$sel" == "0" ]] && return 0
    k="${keys[$((sel - 1))]}"
    if db_is_installed "$k"; then
        oc_warn "$(oc_title_of "$k") 已安装"
        oc_confirm "重新安装（覆盖配置）？" n || return 0
    fi
    oc_call "$k" install
    oc_pause
}

# ---------- 2. 节点管理 ----------

menu_manage() {
    local -a items=() keys=()
    local k
    for k in "${OC_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        items+=("$(oc_title_of "$k")  $(oc_status_line "$k")")
        keys+=("$k")
    done
    if [[ ${#keys[@]} -eq 0 ]]; then
        oc_warn "还没有安装任何协议，先去菜单 1 安装"
        oc_pause
        return 0
    fi
    local sel
    sel="$(oc_menu "节点管理" "${items[@]}")" || return 0
    [[ "$sel" == "0" ]] && return 0
    k="${keys[$((sel - 1))]}"
    local unit
    unit="$(oc_unit_name "$k")"

    while true; do
        local c
        c="$(oc_menu "$(oc_title_of "$k") 管理" \
            "状态与日志" \
            "启动" "停止" "重启" \
            "改端口" "换凭据" "重生成配置" \
            "查看链接" "二维码" "删除")" || return 0
        case "$c" in
            0) return 0 ;;
            1) oc_title "$(oc_title_of "$k") 状态"
               oc_call "$k" status
               echo
               svc_logs "$unit" 20
               oc_pause ;;
            2) svc_start "$unit" && oc_ok "已启动" || oc_err "启动失败"
               sleep 1; oc_call "$k" status; oc_pause ;;
            3) svc_stop "$unit" && oc_ok "已停止"; oc_pause ;;
            4) svc_restart "$unit" && oc_ok "已重启" || oc_err "重启失败"
               sleep 1; oc_call "$k" status; oc_pause ;;
            5) _menu_change_port "$k"; oc_pause ;;
            6) _menu_change_pw "$k"; oc_pause ;;
            7) oc_call "$k" regen && oc_ok "配置已重生成并重启" || oc_err "重生成失败"; oc_pause ;;
            8) oc_call "$k" link; oc_pause ;;
            9) oc_call "$k" link | head -1 | while read -r l; do share_qr "$l"; done; oc_pause ;;
            10) _menu_delete "$k" && return 0 ;;
        esac
    done
}

_menu_change_port() {
    local k="$1" old new
    old="$(db_get "$k" port "")"
    new="$(oc_ask "新端口（当前 $old，回车不改）" "")"
    [[ -z "$new" || "$new" == "$old" ]] && return 0
    [[ "$new" =~ ^[0-9]+$ ]] || { oc_err "端口必须是数字"; return 1; }
    local proto="tcp"
    [[ "$(oc_meta_field "$k" udp)" == "yes" ]] && proto="udp"
    net_port_in_use "$new" "$proto" && { oc_err "端口 $new 已被占用"; return 1; }
    db_set "$k" port "$new"
    # 防火墙：先放行新端口，重生成成功后再撤旧端口
    net_fw_allow "$new" "$proto" "oneclick-$k" >/dev/null 2>&1
    if oc_call "$k" regen; then
        net_fw_deny "$old" "$proto" "oneclick-$k" >/dev/null 2>&1
        oc_ok "端口已改为 $new"
    else
        db_set "$k" port "$old"
        oc_err "重生成失败，端口回滚为 $old"
    fi
}

_menu_change_pw() {
    local k="$1" field new
    case "$k" in
        snell) field="psk" ;;
        vless_reality) field="uuid" ;;
        *) field="password" ;;
    esac
    new="$(oc_ask "新凭据（回车自动生成）" "")"
    [[ -z "$new" ]] && new="$(os_random_token 20)"
    db_set "$k" "$field" "$new"
    if oc_call "$k" regen; then
        oc_ok "凭据已更新"
        oc_kv "新凭据" "$new"
    else
        oc_err "重生成失败，请检查日志"
    fi
}

_menu_delete() {
    local k="$1"
    oc_confirm "确认删除 $(oc_title_of "$k")（配置与防火墙规则一并清理）？" n || return 1
    oc_call "$k" uninstall
    return 0
}

# ---------- 3. 证书 ----------

menu_cert() {
    while true; do
        local c
        c="$(oc_menu "证书管理" \
            "查看证书状态" \
            "ACME 申请（HTTP-01，需域名解析到本机）" \
            "生成自签证书" \
            "生成 REALITY x25519 密钥对")" || return 0
        case "$c" in
            0) return 0 ;;
            1) cert_status; oc_pause ;;
            2) local d
               d="$(oc_ask "域名" "")"
               [[ -z "$d" ]] && { oc_err "域名不能为空"; oc_pause; continue; }
               os_dep_install base acme || { oc_pause; continue; }
               if cert_acme "$d" "$OC_CERT_DIR/$d"; then
                   oc_ok "证书就绪：$OC_CERT_DIR/$d"
               else
                   oc_err "ACME 失败（80 端口被占或验证不通过）"
               fi
               oc_pause ;;
            3) local s out
               s="$(oc_ask "SNI/域名（自签用，可填 bing.com）" "bing.com")"
               out="$OC_CERT_DIR/self-$s"
               if cert_self "$s" "$out"; then
                   oc_ok "自签证书：$out"
               else
                   oc_err "自签失败"
               fi
               oc_pause ;;
            4) reality_keypair "$OC_CERT_DIR/reality.json" && oc_ok "已写入 $OC_CERT_DIR/reality.json" || oc_err "生成失败"
               oc_pause ;;
        esac
    done
}

# ---------- 4. 订阅 ----------

menu_sub() {
    while true; do
        local c
        c="$(oc_menu "订阅与分享" \
            "生成全部格式（uri/clash/surge/loon）" \
            "仅生成 URI 列表" \
            "仅生成 Clash" \
            "仅生成 Surge" \
            "仅生成 Loon" \
            "仅生成 sing-box" \
            "查看订阅目录")" || return 0
        case "$c" in
            0) return 0 ;;
            1) for _f in uri clash surge loon; do share_render_sub "$_f" >/dev/null || true; done
               oc_ok "已生成到 $OC_SUB_DIR"; ls -l "$OC_SUB_DIR" 2>/dev/null; oc_pause ;;
            2) share_render_uri >/dev/null && oc_ok "URI 列表已生成" ;;
            3) share_render_clash >/dev/null && oc_ok "Clash 节点已生成" ;;
            4) share_render_surge >/dev/null && oc_ok "Surge 节点已生成" ;;
            5) share_render_loon >/dev/null && oc_ok "Loon 节点已生成" ;;
            6) share_render_singbox >/dev/null && oc_ok "sing-box 配置已生成" ;;
            7) ls -l "$OC_SUB_DIR" 2>/dev/null || oc_warn "目录为空" ;;
        esac
        [[ "$c" != "1" && "$c" != "7" ]] && oc_pause
    done
}

# ---------- 5. 系统工具 ----------

menu_system() {
    while true; do
        local c
        c="$(oc_menu "系统工具" \
            "补装缺失的基础依赖" \
            "防火墙：放行已装协议端口" \
            "查询端口占用" \
            "设置 GitHub 镜像前缀" \
            "重新检测公网 IP" \
            "本机信息")" || return 0
        case "$c" in
            0) return 0 ;;
            1) os_dep_install base && oc_ok "依赖就绪（只装缺失项）"; oc_pause ;;
            2) _sys_open_ports; oc_pause ;;
            3) local p
               p="$(oc_ask "端口号" "")"
               [[ -n "$p" ]] && { net_port_in_use "$p" tcp && oc_warn "TCP $p 已占用" || oc_ok "TCP $p 空闲"
                                   net_port_in_use "$p" udp && oc_warn "UDP $p 已占用" || oc_ok "UDP $p 空闲"; }
               oc_pause ;;
            4) local m
               m="$(oc_ask "镜像前缀（如 https://gh-proxy.net，留空则直连）" "$(db_setting gh_proxy)")"
               db_setting gh_proxy "$m" && oc_ok "已保存：${m:-直连}"; oc_pause ;;
            5) local ip
               ip="$(net_primary_ip)"
               if [[ -n "$ip" ]]; then
                   db_setting ip "$ip"
                   oc_ok "公网 IP：$ip"
               else
                   oc_warn "检测失败（可手动 db 设置）"
               fi
               oc_pause ;;
            6) oc_kv "脚本版本" "$OC_VERSION"
               oc_kv "系统" "$OC_OS_ID $OC_OS_VER"
               oc_kv "架构" "$OC_ARCH"
               oc_kv "防火墙后端" "$(net_fw_backend)"
               oc_kv "内核目录" "$OC_BIN_DIR"
               oc_kv "公网 IP" "$(db_setting ip)"
               oc_pause ;;
        esac
    done
}

_sys_open_ports() {
    local k port
    for k in "${OC_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        port="$(db_get "$k" port "")"
        [[ -z "$port" ]] && continue
        # 传输方式按协议实际监听决定：HY2 仅 UDP，SS-Rust 两者都要，其余 TCP
        case "$k" in
            hysteria2)
                net_fw_allow "$port" udp "oneclick-$k" && oc_ok "放行 $(oc_title_of "$k") udp/$port" ;;
            ss_rust)
                net_fw_allow "$port" tcp "oneclick-$k" && oc_ok "放行 $(oc_title_of "$k") tcp/$port"
                net_fw_allow "$port" udp "oneclick-$k" && oc_ok "放行 $(oc_title_of "$k") udp/$port" ;;
            *)
                net_fw_allow "$port" tcp "oneclick-$k" && oc_ok "放行 $(oc_title_of "$k") tcp/$port" ;;
        esac
    done
}

# ---------- 6. 备份 / 恢复 / 卸载 ----------

menu_backup() {
    while true; do
        local c
        c="$(oc_menu "备份与恢复" \
            "全量备份（/etc/oneclick → tar.gz）" \
            "从备份恢复" \
            "卸载单个协议" \
            "卸载全部协议" \
            "彻底卸载（协议+内核+配置+残留）")" || return 0
        case "$c" in
            0) return 0 ;;
            1) _bk_backup; oc_pause ;;
            2) _bk_restore; oc_pause ;;
            3) menu_manage ;;
            4) _bk_uninstall_all; oc_pause ;;
            5) _bk_purge; oc_pause ;;
        esac
    done
}

_bk_backup() {
    local f
    f="/root/oneclick-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar -czf "$f" -C / etc/oneclick 2>/dev/null; then
        chmod 600 "$f"
        oc_ok "备份完成：$f"
        oc_kv "大小" "$(du -h "$f" | awk '{print $1}')"
    else
        oc_err "备份失败"
    fi
}

_bk_restore() {
    local f
    f="$(oc_ask "备份文件路径" "")"
    [[ -f "$f" ]] || { oc_err "文件不存在"; return 1; }
    oc_confirm "恢复会覆盖 /etc/oneclick，继续？" n || return 0
    tar -xzf "$f" -C / || { oc_err "解压失败"; return 1; }
    db_init
    oc_ok "已恢复，建议到节点管理里逐个重生成并重启"
}

_bk_uninstall_all() {
    oc_confirm "确认卸载全部协议（不删除脚本本体）？" n || return 0
    local k
    for k in "${OC_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        OC_YES=1 oc_call "$k" uninstall
    done
    oc_ok "全部协议已卸载"
}

# 彻底卸载：协议、unit、防火墙快照、私有内核、配置、脚本入口、acme 残留。
# 只删本脚本自己创建的东西；用户原有的服务与二进制（如 snell-server.service）不碰。
_bk_purge() {
    oc_confirm "彻底卸载：删除全部协议、/etc/oneclick、私有内核与脚本入口，确认？" n || return 0
    local k t ch line bin_root_abs
    for k in "${OC_PROTOS[@]}"; do
        if db_has "$k" || db_is_installed "$k"; then
            OC_YES=1 oc_call "$k" uninstall >/dev/null 2>&1 || true
        fi
    done
    # 防火墙：先删 oneclick-* 规则，再停掉持久化单
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        for ch in INPUT FORWARD; do
            "$t" -S "$ch" 2>/dev/null | grep -F 'oneclick-' | while IFS= read -r line; do
                read -r -a __a <<< "$line"
                [[ "${__a[0]:-}" == "-A" ]] || continue
                "$t" -D "${__a[@]:1}" >/dev/null 2>&1 || true
            done
        done
        "$t" -t nat -S PREROUTING 2>/dev/null | grep -F 'oneclick-hop' | while IFS= read -r line; do
            read -r -a __a <<< "$line"
            [[ "${__a[0]:-}" == "-A" ]] || continue
            "$t" -t nat -D "${__a[@]:1}" >/dev/null 2>&1 || true
        done
    done
    command -v nft >/dev/null 2>&1 && nft delete table inet oneclick >/dev/null 2>&1 || true
    svc_remove "$OC_FW_UNIT"
    rm -f -- "$OC_FW_FILE"
    # 旧版本留下的 BBR/TFO 调优文件（新版本不再写 sysctl）
    rm -f -- /etc/sysctl.d/99-oneclick-bbr.conf
    # acme.sh：只有本脚本装过才清续期任务与目录
    if [[ "$(db_setting acme_installed 0)" == "1" && -d "$HOME/.acme.sh" ]]; then
        if crontab -l 2>/dev/null | grep -qF "$HOME/.acme.sh/acme.sh"; then
            crontab -l 2>/dev/null | grep -vF "$HOME/.acme.sh/acme.sh" | crontab - 2>/dev/null || true
            [[ -z "$(crontab -l 2>/dev/null)" ]] && crontab -r 2>/dev/null || true
        fi
        rm -rf -- "$HOME/.acme.sh"
        oc_info "已清理 acme.sh 与续期任务"
    fi
    rm -rf -- "$OC_ROOT" /var/log/oneclick
    bin_root_abs="$OC_BIN_ROOT"
    [[ -n "$bin_root_abs" && "$bin_root_abs" != "/" ]] && rm -rf -- "$bin_root_abs"
    rm -f -- "$OC_ENTRY" "$OC_ENTRY_DIR/oc"
    oc_ok "已彻底卸载（内核、配置、unit、防火墙快照、脚本入口均已清理）"
}

# ---------- 7. 更新 ----------

menu_update() {
    while true; do
        local c
        c="$(oc_menu "更新与版本" \
            "脚本自更新（需 OC_UPDATE_URL）" \
            "查看已装内核版本" \
            "查看本机已装协议")" || return 0
        case "$c" in
            0) return 0 ;;
            1) _up_self; oc_pause ;;
            2) _up_kernels; oc_pause ;;
            3) _up_installed; oc_pause ;;
        esac
    done
}

# 首次从任意路径运行时，把自身装成 oneclick 命令，方便以后直接输入 oneclick
oc_self_install() {
    local src="${BASH_SOURCE[0]:-}"
    [[ -n "$src" && -f "$src" ]] || return 0
    [[ "$src" == "$OC_ENTRY" ]] && return 0
    command -v install >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$OC_ENTRY")" 2>/dev/null || return 0
    if install -m 755 "$src" "$OC_ENTRY" 2>/dev/null; then
        ln -sf oneclick "$(dirname "$OC_ENTRY")/oc" 2>/dev/null || true
        oc_ok "已安装命令：$OC_ENTRY（简写 oc）"
    fi
}

_up_self() {
    if [[ -z "${OC_UPDATE_URL:-}" ]]; then
        oc_warn "未设置 OC_UPDATE_URL，跳过自更新"
        oc_info "手动：curl -fsSL <你的发布地址> -o $OC_ENTRY && chmod +x $OC_ENTRY"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    if dl_fetch "$OC_UPDATE_URL" "$tmp"; then
        bash -n "$tmp" || { rm -f "$tmp"; oc_err "下载内容不是合法脚本"; return 1; }
        install -m 755 "$tmp" "$OC_ENTRY" && oc_ok "已更新到最新版本"
        rm -f "$tmp"
        oc_info "重新执行 oneclick 生效"
    else
        oc_err "下载失败"
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
    for k in "${OC_PROTOS[@]}"; do
        db_is_installed "$k" || continue
        oc_kv "$(oc_title_of "$k")" "$(db_get "$k" port "-") / $(oc_status_line "$k")"
    done
}

# ---------- 主菜单 ----------

main_menu() {
    while true; do
        oc_banner
        local c
        OC_MENU_ZERO_LABEL="退出"
        c="$(oc_menu "主菜单" \
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
        unset OC_MENU_ZERO_LABEL
    done
}

# ---------- CLI ----------

cli_list() {
    local k
    printf '%-16s %-8s %-7s %s\n' "KEY" "端口" "状态" "说明"
    for k in "${OC_PROTOS[@]}"; do
        printf '%-16s %-8s %-7s %s\n' "$k" "$(db_get "$k" port '-')" \
            "$(db_is_installed "$k" && oc_status_line "$k" || echo 未安装)" \
            "$(oc_meta_field "$k" desc)"
    done
}

cli_status() {
    local k
    if [[ "$OC_ARG_FORMAT" == "json" ]]; then
        local out='{"version":"'"$OC_VERSION"'","os":"'"$OC_OS_ID"'","arch":"'"$OC_ARCH"'","protos":{'
        local first=1 inst
        for k in "${OC_PROTOS[@]}"; do
            [[ "$first" == "1" ]] || out+=','
            first=0
            if db_is_installed "$k"; then inst="true"; else inst="false"; fi
            out+="\"$k\":{\"installed\":$inst,\"port\":\"$(db_get "$k" port '')\",\"status\":\"$(oc_status_line "$k")\",\"unit\":\"$(oc_unit_name "$k")\"}"
        done
        out+='}}'
        printf '%s\n' "$out" | jq .
        return 0
    fi
    printf '%-16s %-8s %s\n' "协议" "端口" "状态"
    for k in "${OC_PROTOS[@]}"; do
        printf '%-16s %-8s %s\n' "$(oc_title_of "$k")" "$(db_get "$k" port '-')" "$(oc_status_line "$k")"
    done
}

cli_link() {
    local k="$OC_CLI_KEY"
    [[ -z "$k" ]] && oc_die "--link 需要协议 key"
    db_is_installed "$k" || oc_die "$(oc_title_of "$k") 未安装"
    case "${OC_ARG_FORMAT:-uri}" in
        uri|"") oc_call "$k" link ;;
        clash)  oc_call "$k" clash ;;
        surge)  oc_call "$k" surge ;;
        loon)   oc_call "$k" loon ;;
        singbox|sing-box) oc_call "$k" singbox ;;
        qr) oc_call "$k" link | head -1 | while read -r l; do share_qr "$l"; done ;;
        *) oc_die "未知格式：$OC_ARG_FORMAT（uri|clash|surge|loon|singbox|qr）" ;;
    esac
}

cli_run() {
    case "$OC_CLI_ACTION" in
        install)   db_is_installed "$OC_CLI_KEY" && oc_die "$(oc_title_of "$OC_CLI_KEY") 已安装"
                   oc_call "$OC_CLI_KEY" install ;;
        uninstall) db_is_installed "$OC_CLI_KEY" || oc_die "$(oc_title_of "$OC_CLI_KEY") 未安装"
                   oc_call "$OC_CLI_KEY" uninstall ;;
        regen)     oc_call "$OC_CLI_KEY" regen ;;
        link)      cli_link ;;
        status)    cli_status ;;
        list)      cli_list ;;
        cert-status) cert_status ;;
        sub)       local f; local -a fs=(uri clash surge loon)
                   [[ -n "${OC_ARG_FORMAT:-}" ]] && fs=("$OC_ARG_FORMAT")
                   for f in "${fs[@]}"; do share_render_sub "$f" || exit 1; done ;;
        purge)     _bk_purge ;;
        check-ip)  local ip; ip="$(net_primary_ip)"; [[ -n "$ip" ]] && { db_setting ip "$ip"; printf '%s\n' "$ip"; } || oc_die "检测失败" ;;
        help|"")   oc_usage ;;
        version)   printf 'oneclick %s\n' "$OC_VERSION" ;;
        *)         oc_die "未知动作：$OC_CLI_ACTION" ;;
    esac
}

oc_usage() {
    cat <<'EOF'
OneClick 一键多协议代理安装器

用法：
  oneclick                                    交互菜单
  oneclick --install <key> [--port N] [--domain D] [--sni S] [--cert-mode M] [--yes]
  oneclick --uninstall <key> [--yes]
  oneclick --regen <key>
  oneclick --link <key> [--format uri|clash|surge|loon|singbox|qr]
  oneclick --status [--format json]
  oneclick --list
  oneclick --sub [--format uri|clash|surge|loon|singbox]
                                               生成节点片段（默认不含 sing-box）
  oneclick --cert-status
  oneclick --purge                             彻底卸载（协议+内核+配置+残留）
  oneclick --check-ip
  oneclick --version | --help

协议 key：vless_reality  hysteria2  snell  ss_rust  anytls
EOF
}

oc_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install|--uninstall|--regen|--link)
                [[ -n "${2:-}" ]] || oc_die "$1 需要协议 key"
                OC_CLI_ACTION="${1#--}"
                OC_CLI_KEY="$2"; shift 2 ;;
            --status|--list|--cert-status|--check-ip|--sub|--purge|--version|--help)
                OC_CLI_ACTION="${1#--}"; shift ;;
            --port)   [[ -n "${2:-}" ]] || oc_die "--port 需要端口"; OC_ARG_PORT="$2"; shift 2 ;;
            --domain) [[ -n "${2:-}" ]] || oc_die "--domain 需要域名"; OC_ARG_DOMAIN="$2"; shift 2 ;;
            --sni)    [[ -n "${2:-}" ]] || oc_die "--sni 需要值"; OC_ARG_SNI="$2"; shift 2 ;;
            --cert-mode) [[ -n "${2:-}" ]] || oc_die "--cert-mode 需要值"; OC_ARG_CERT_MODE="$2"; shift 2 ;;
            --format) [[ -n "${2:-}" ]] || oc_die "--format 需要值"; OC_ARG_FORMAT="$2"; shift 2 ;;
            -y|--yes) OC_YES=1; shift ;;
            *) oc_die "未知参数：$1（--help 查看用法）" ;;
        esac
    done
    if [[ -n "$OC_CLI_KEY" ]]; then
        oc_key_valid "$OC_CLI_KEY" || oc_die "未知协议 key：$OC_CLI_KEY（可用：${OC_PROTOS[*]}）"
    fi
}

main() {
    # 先解析参数：--help/--version 不需要 root，也不该触发系统探测与依赖安装
    oc_parse_args "$@"
    case "$OC_CLI_ACTION" in
        help) oc_usage; return 0 ;;
        version) printf 'oneclick %s\n' "$OC_VERSION"; return 0 ;;
    esac
    oc_require_root
    os_detect
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v jq >/dev/null 2>&1; then
        os_dep_install base || oc_die "基础依赖安装失败，无法继续"
    fi
    db_init
    if [[ -n "$OC_CLI_ACTION" ]]; then
        cli_run
        return $?
    fi
    oc_self_install
    main_menu
}

main "$@"
