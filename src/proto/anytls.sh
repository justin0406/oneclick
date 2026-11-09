# ============================================================
# proto/anytls.sh —— AnyTLS（服务端用 sing-box 的 anytls inbound 承载自签/ACME 证书）
# 对外：proto_anytls_meta/install/uninstall/status/link/regen/clash/surge/singbox
# 内部辅助函数：见下方定义（私有前缀 ocp）
# 说明：上游 anytls-go 的 anytls-server 不支持外部证书（进程内临时自签），
#       故服务端改用 sing-box 的 anytls inbound，以满足「证书必须由本脚本自主签发」。
#       本文件是 build.sh 拼接的单文件片段，不写 shebang、不 source、不 set -e
# ============================================================

# sing-box 版本钉死（升级只改这一处；已装同版本时复用二进制，不重复下载）
OC_SINGBOX_VER="${OC_SINGBOX_VER:-1.14.4}"

# ---------- 内部辅助 ----------

ocp_anytls_dir() {
    oc_proto_dir anytls
}

ocp_anytls_cfg() {
    printf '%s/config.json' "$(oc_proto_dir anytls)"
}

ocp_anytls_bin() {
    printf '%s/sing-box' "${OC_BIN_DIR}"
}

ocp_anytls_default_port() {
    local port
    port="$(db_get anytls port "")"
    printf '%s' "${port:-8443}"
}

ocp_anytls_name() {
    printf '%s' "${OC_PROTO_TITLE[anytls]:-AnyTLS}"
}

ocp_anytls_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    (( n >= 1 && n <= 65535 ))
}

# sing-box 资产架构别名：amd64/arm64/armv7（无 i386）
ocp_anytls_arch() {
    case "${OC_ARCH:-}" in
        amd64|arm64) printf '%s' "$OC_ARCH" ;;
        armv7l) printf 'armv7' ;;
        *) return 1 ;;
    esac
}

# 读已装 sing-box 的版本号（首行 "sing-box version x.y.z" 的第 3 列）
ocp_anytls_sb_version() {
    local bin v
    bin="$(ocp_anytls_bin)"
    [[ -x "$bin" ]] || return 1
    v="$("$bin" version 2>/dev/null | awk 'NR==1{print $3}')"
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

# 下载钉死版本的 sing-box 官方 tar.gz 并装到 OC_BIN_DIR
ocp_anytls_fetch_singbox() {
    local ver="${OC_SINGBOX_VER}" arch asset tmpdir bin
    arch="$(ocp_anytls_arch)" || return 1
    asset="sing-box-${ver}-linux-${arch}.tar.gz"
    tmpdir="$(mktemp -d)" || return 1
    if ! dl_gh SagerNet/sing-box "v${ver}" "$asset" "$tmpdir/sing-box.tar.gz"; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    if ! dl_untar "$tmpdir/sing-box.tar.gz" "$tmpdir/x"; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    bin="$tmpdir/x/sing-box-${ver}-linux-${arch}/sing-box"
    if [[ ! -f "$bin" ]]; then
        bin="$(find "$tmpdir/x" -type f -name sing-box 2>/dev/null | head -1)"
    fi
    if [[ -z "$bin" || ! -f "$bin" ]]; then
        rm -rf -- "$tmpdir"
        return 1
    fi
    cp -f -- "$bin" "$(ocp_anytls_bin)" || { rm -rf -- "$tmpdir"; return 1; }
    chmod 755 "$(ocp_anytls_bin)"
    rm -rf -- "$tmpdir"
}

ocp_anytls_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# 写 sing-box 配置（/etc/oneclick/anytls/config.json，600）；内容无变化时不重写
ocp_anytls_write_config() {
    local port="$1" pw="$2" sni="$3" cert="$4" key="$5"
    local dir cfg tmp
    dir="$(ocp_anytls_dir)"
    cfg="$(ocp_anytls_cfg)"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg pw "$pw" \
        --arg sni "$sni" \
        --arg cert "$cert" \
        --arg key "$key" '
        {
            log: {level: "warn", timestamp: true},
            inbounds: [{
                type: "anytls",
                tag: "oneclick-anytls",
                listen: "::",
                listen_port: $port,
                users: [{name: "oneclick", password: $pw}],
                tls: {
                    enabled: true,
                    server_name: $sni,
                    certificate_path: $cert,
                    key_path: $key
                }
            }],
            outbounds: [{type: "direct", tag: "direct"}]
        }
    ' > "$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        chmod 600 "$cfg" 2>/dev/null || true
        return 0
    fi
    mv -f -- "$tmp" "$cfg" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$cfg" 2>/dev/null || true
}

ocp_anytls_write_unit() {
    svc_create "$(oc_unit_name anytls)" \
        "$(ocp_anytls_bin) run -c $(ocp_anytls_cfg)" \
        "OneClick AnyTLS"
}

# 启动前用 sing-box 自带 check 校验配置，避免带着坏配置起服务
ocp_anytls_check_config() {
    local out
    if ! out="$("$(ocp_anytls_bin)" check -c "$(ocp_anytls_cfg)" 2>&1)"; then
        oc_err "sing-box 配置校验失败："
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# 对外 IP：优先 db 里缓存的 settings.ip，避免每次外联探测
ocp_anytls_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "${ip:-0.0.0.0}"
}

# 自签证书才跳过校验；acme/existing 为真实证书
ocp_anytls_insecure() {
    if [[ "$(db_get anytls tls_mode self)" == "self" ]]; then
        printf '1'
    else
        printf '0'
    fi
}

# ---------- SPEC §10 契约函数 ----------

proto_anytls_meta() {
    printf 'title=%s\n' "$(ocp_anytls_name)"
    printf 'desc=低特征 TLS 代理（sing-box 实现），支持自签/ACME 证书\n'
    printf 'port=%s\n' "$(ocp_anytls_default_port)"
    printf 'udp=no\n'
    printf 'cert=yes\n'
}

proto_anytls_install() {
    local unit port mode sni_hint crt_file key_file sni pw have arch

    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect

    # 1. 判重：以 installed 登记为准，只有残留配置视为上次未完成
    if db_has anytls; then
        if ! db_is_installed anytls; then
            oc_warn "检测到上次未完成的 AnyTLS 安装（配置残留），本次将覆盖"
        elif [[ "${OC_YES:-0}" == "1" ]]; then
            oc_die "AnyTLS 已安装；非交互模式不覆盖，请先卸载后重装"
        elif ! oc_confirm "AnyTLS 已安装，是否重新安装（覆盖配置）？" n; then
            oc_info "已取消"
            return 0
        fi
    fi

    # 2. 端口（TCP，先判占用再下载）
    port="${OC_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(oc_ask "AnyTLS 监听端口" "$(ocp_anytls_default_port)")"
    fi
    ocp_anytls_port_ok "$port" || oc_die "端口无效：${port:-空}（需 1-65535）"
    port=$((10#$port))
    if net_port_in_use "$port" tcp; then
        oc_die "TCP 端口 ${port} 已被占用；建议改用空闲端口：$(net_port_pick 8443 tcp)"
    fi

    # 3. 依赖与二进制（sing-box 复用，版本不一致才重下）
    case "${OC_ARCH:-}" in
        amd64|arm64|armv7l) ;;
        i386) oc_die "AnyTLS 不支持 i386（sing-box 未提供 linux-386 构建）" ;;
        *) oc_die "AnyTLS 不支持当前架构：${OC_ARCH:-未知}（支持 amd64/arm64/armv7l）" ;;
    esac
    arch="$(ocp_anytls_arch)"
    os_dep_install base || oc_die "基础依赖安装失败，无法继续"

    have="$(ocp_anytls_sb_version || true)"
    if [[ "$have" == "$OC_SINGBOX_VER" ]]; then
        oc_ok "复用已安装的 sing-box ${have}：$(ocp_anytls_bin)"
    else
        oc_info "下载 sing-box ${OC_SINGBOX_VER}（SagerNet/sing-box，linux-${arch}）..."
        if ! ocp_anytls_fetch_singbox; then
            oc_die "sing-box 下载失败；请检查网络或设置 GitHub 镜像后重试（也可手动放二进制到 $(ocp_anytls_bin)）"
        fi
        have="$(ocp_anytls_sb_version || true)"
        [[ -n "$have" ]] || oc_die "sing-box 已落盘但无法执行（架构不匹配或缺少依赖），请检查 $(ocp_anytls_bin)"
        oc_ok "sing-box 已安装：$(ocp_anytls_bin)（${have}）"
    fi

    # 4. 证书（先拿证书，失败不写半截配置）
    mode="${OC_ARG_CERT_MODE:-}"
    if [[ -z "$mode" ]]; then
        mode="$(oc_ask "证书方式（self=自签 / acme=域名申请 / existing=已有证书）" self)"
    fi
    case "$mode" in
        self|acme|existing) ;;
        *) oc_die "无效的证书方式：${mode}（可选 self/acme/existing）" ;;
    esac
    sni_hint="${OC_ARG_SNI:-${OC_ARG_DOMAIN:-bing.com}}"
    oc_info "准备证书（方式：${mode}，SNI 提示：${sni_hint}）..."
    if ! cert_ensure "$sni_hint" "$mode"; then
        oc_die "证书准备失败，安装已中止（未写入任何配置）"
    fi
    crt_file="${CERT_PATH:-}"
    key_file="${KEY_PATH:-}"
    sni="${SNI:-$sni_hint}"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        oc_die "证书文件缺失（cert=${crt_file:-空} key=${key_file:-空}），安装已中止"
    fi
    # 5. 凭据
    pw="$(os_random_token 16)"
    if [[ ${#pw} -lt 16 ]]; then
        pw="$(os_random_hex 16)"
    fi
    [[ -n "$pw" ]] || oc_die "随机密码生成失败"

    # 6. 写配置并校验
    ocp_anytls_write_config "$port" "$pw" "$sni" "$crt_file" "$key_file" ||
        oc_die "写入配置失败：$(ocp_anytls_cfg)"
    ocp_anytls_check_config || oc_die "配置校验未通过，安装已中止：$(ocp_anytls_cfg)"
    oc_ok "配置已写入：$(ocp_anytls_cfg)"

    # 7. 服务
    unit="$(oc_unit_name anytls)"
    ocp_anytls_write_unit
    svc_enable "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "AnyTLS 启动失败，最近日志："
        svc_logs "$unit" 30
        oc_die "服务未能启动；请检查证书路径、TCP ${port} 是否被占用后重试"
    fi
    oc_ok "服务已启动：${unit}"

    # 9. 落库（sing-box 二进制共享，卸载时保留）
    db_set anytls port "$port"
    db_set anytls password "$pw"
    db_set anytls sni "$sni"
    db_set anytls tls_mode "$mode"
    db_set anytls tls_cert "$crt_file"
    db_set anytls tls_key "$key_file"
    db_set anytls singbox_ver "$OC_SINGBOX_VER"
    db_set anytls created "$(os_now)"
    db_mark_installed anytls
    local pubip
    pubip="$(net_primary_ip)"
    [[ -n "$pubip" ]] && db_setting ip "$pubip"

    # 10. 收尾
    oc_ok "AnyTLS 安装完成"
    if [[ "${OC_YES:-0}" == "1" ]]; then
        proto_anytls_link
        return 0
    fi
    oc_hr
    oc_kv "协议" "AnyTLS（sing-box ${OC_SINGBOX_VER}）"
    oc_kv "端口(TCP)" "${port}"
    oc_kv "密码" "${pw}"
    oc_kv "SNI" "${sni}"
    oc_kv "证书方式" "${mode}"
    oc_kv "证书" "${crt_file}"
    oc_kv "服务状态" "$(proto_anytls_status | head -1)"
    oc_hr
    oc_info "分享链接（URI，可直接导入客户端）："
    proto_anytls_link
}

proto_anytls_uninstall() {
    local unit port dir
    oc_require_root
    unit="$(oc_unit_name anytls)"
    if ! db_is_installed anytls && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        oc_warn "AnyTLS 未安装"
        return 0
    fi
    oc_confirm "确认卸载 AnyTLS（停止服务、删除配置与防火墙规则）？" y || {
        oc_info "已取消"
        return 0
    }
    port="$(db_get anytls port "")"
    svc_remove "$unit"
    dir="$(ocp_anytls_dir)"
    if [[ -n "$dir" && "$dir" == "${OC_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
    fi
    db_unmark_installed anytls
    db_del anytls
    oc_ok "AnyTLS 已卸载（sing-box 二进制与证书保留，其它协议可复用）"
}

proto_anytls_status() {
    local unit port pid
    unit="$(oc_unit_name anytls)"
    if ! db_is_installed anytls && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get anytls port '-')"
    if svc_is_active "$unit"; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
        return 0
    fi
    if [[ "$(svc_status "$unit")" == "failed" ]]; then
        printf '已停止（failed）\n'
    else
        printf '已停止\n'
    fi
}

proto_anytls_link() {
    local pw port sni ip host q
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ip="$(ocp_anytls_ip)"
    host="$ip"
    [[ "$ip" == *:* ]] && host="[${ip}]"
    q="sni=${sni}"
    if [[ "$(ocp_anytls_insecure)" == "1" ]]; then
        q+="&insecure=1"
    fi
    printf 'anytls://%s@%s:%s?%s#%s\n' "$pw" "$host" "$port" "$q" "$(ocp_anytls_name)"
}

proto_anytls_regen() {
    local unit port pw sni crt_file key_file
    oc_require_root
    if ! db_is_installed anytls; then
        oc_die "AnyTLS 未安装，无法重生成配置"
    fi
    port="$(db_get anytls port "")"
    pw="$(db_get anytls password "")"
    sni="$(db_get anytls sni bing.com)"
    crt_file="$(db_get anytls tls_cert "")"
    key_file="$(db_get anytls tls_key "")"

    ocp_anytls_port_ok "$port" || oc_die "数据库中的端口无效：${port:-空}"
    [[ -n "$pw" ]] || oc_die "数据库中的密码为空，请重新安装"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        oc_die "数据库记录的证书不存在（cert=${crt_file:-空} key=${key_file:-空}），请重新安装以重新签发"
    fi

    ocp_anytls_write_config "$port" "$pw" "$sni" "$crt_file" "$key_file" ||
        oc_die "写入配置失败：$(ocp_anytls_cfg)"
    ocp_anytls_check_config || oc_die "配置校验未通过：$(ocp_anytls_cfg)"
    ocp_anytls_write_unit
    unit="$(oc_unit_name anytls)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30
        oc_die "配置重生成后启动失败"
    fi
    oc_ok "配置已重生成并重启：$(ocp_anytls_cfg)"
}

proto_anytls_clash() {
    local pw port sni ip
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ip="$(ocp_anytls_ip)"

    printf '  - name: "%s"\n' "$(ocp_anytls_name)"
    printf '    type: anytls\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    password: "%s"\n' "$pw"
    printf '    sni: "%s"\n' "$sni"
    if [[ "$(ocp_anytls_insecure)" == "1" ]]; then
        printf '    skip-cert-verify: true\n'
    fi
    printf '    udp: true\n'
}

proto_anytls_surge() {
    local pw port sni line
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    line="$(ocp_anytls_name) = anytls, $(ocp_anytls_ip), ${port}, password=${pw}, sni=${sni}"
    if [[ "$(ocp_anytls_insecure)" == "1" ]]; then
        line+=", skip-cert-verify=true"
    fi
    printf '%s\n' "$line"
}

proto_anytls_singbox() {
    local pw port sni ins
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    ins="$(ocp_anytls_insecure)"

    jq -n \
        --argjson port "$port" --arg server "$(ocp_anytls_ip)" \
        --arg pw "$pw" --arg sni "$sni" --argjson insecure "$ins" '
        {
            type: "anytls",
            tag: "oneclick-anytls",
            server: $server,
            server_port: $port,
            password: $pw,
            tls: ({enabled: true, server_name: $sni}
                  + (if $insecure == 1 then {insecure: true} else {} end)
                  + {utls: {enabled: true, fingerprint: "chrome"}})
        }
    '
}

# Loon 片段：AnyTLS 在 Loon 里类型名是小写 anytls，SNI 参数叫 tls-name。
proto_anytls_loon() {
    local pw port sni line
    pw="$(db_get anytls password "")"
    port="$(db_get anytls port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get anytls sni bing.com)"
    line="$(oc_loon_name anytls) = AnyTLS,$(ocp_anytls_ip),${port},\"${pw}\""
    line+=",sni=${sni}"
    [[ "$(ocp_anytls_insecure)" == "1" ]] && line+=",skip-cert-verify=true"
    line+=",udp=true"
    printf '%s\n' "$line"
}
