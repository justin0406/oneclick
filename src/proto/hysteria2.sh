# ============================================================
# proto/hysteria2.sh —— Hysteria2（apernet/hysteria v2 官方二进制）
# 对外：proto_hysteria2_meta/install/uninstall/status/link/regen/clash/surge/singbox
# 内部辅助函数：见下方定义（私有前缀 ocp）
# 说明：本文件是 build.sh 拼接的单文件片段，不写 shebang、不 source、不 set -e
# ============================================================

# ---------- 内部辅助 ----------

ocp_hy2_dir() {
    oc_proto_dir hysteria2
}

ocp_hy2_cfg() {
    printf '%s/config.yaml' "$(oc_proto_dir hysteria2)"
}

ocp_hy2_default_port() {
    local port
    port="$(db_get hysteria2 port "")"
    printf '%s' "${port:-$(net_port_random)}"
}

ocp_hy2_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    (( n >= 1 && n <= 65535 ))
}

# 端口段校验，合法则归一化为 "start-end"
ocp_hy2_hop_ok() {
    local start="${1:-}" end="${2:-}"
    ocp_hy2_port_ok "$start" || return 1
    ocp_hy2_port_ok "$end" || return 1
    start=$((10#$start))
    end=$((10#$end))
    (( start < end )) || return 1
    printf '%s-%s' "$start" "$end"
}

# 上游资产架构别名：amd64/arm64/arm(armv7l)/386
ocp_hy2_arch() {
    case "${OC_ARCH:-}" in
        amd64|arm64) printf '%s' "$OC_ARCH" ;;
        armv7l) printf 'arm' ;;
        i386) printf '386' ;;
        *) return 1 ;;
    esac
}

# 下载结果必须是有效二进制（镜像/代理常返回 HTML 错误页）——复用 dl.sh 的统一结构校验
ocp_hy2_check_elf() {
    _dl_check_elf "${1:-}"
}

ocp_hy2_yaml_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# 取 latest 失败时让用户手输版本标签（GitHub API 可能限流）
ocp_hy2_fetch_bin() {
    local out="${1:-}" arch asset tag url
    arch="$(ocp_hy2_arch)" || return 1
    asset="hysteria-linux-${arch}"
    tag="$(dl_latest_tag apernet/hysteria)"
    if [[ -z "$tag" ]]; then
        oc_warn "直接从 GitHub 获取最新版失败（网络或 API 受限）"
        tag="$(oc_ask "请手动输入 Hysteria 版本标签（例如 app/v2.13.0）" "app/v2.13.0")"
        [[ -n "$tag" ]] || return 1
    fi
    url="https://github.com/apernet/hysteria/releases/download/${tag}/${asset}"
    # 整个 release 共用一份 hashes.txt，按资产 basename 匹配
    dl_verify_fetch "$url" "$out" hashlist "$asset"
}

# 写服务端 YAML（/etc/oneclick/hysteria2/config.yaml，600）；内容无变化时不重写
ocp_hy2_write_config() {
    local port="$1" pw="$2" cert="$3" key="$4" obfs="$5" obfs_pw="$6" hop="${7:-}"
    local dir cfg tmp epw eopw listen
    dir="$(ocp_hy2_dir)"
    cfg="$(ocp_hy2_cfg)"
    epw="$(ocp_hy2_yaml_escape "$pw")"
    mkdir -p "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    listen="$port"
    [[ -n "$hop" ]] && listen="${port},${hop}"
    {
        cat <<EOF
listen: :${listen}

auth:
  type: password
  password: "${epw}"

tls:
  cert: ${cert}
  key: ${key}
EOF
        if [[ "$obfs" == "salamander" ]]; then
            eopw="$(ocp_hy2_yaml_escape "$obfs_pw")"
            cat <<EOF

obfs:
  type: salamander
  salamander:
    password: "${eopw}"
EOF
        fi
        cat <<EOF

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        chmod 600 "$cfg" 2>/dev/null || true
        return 0
    fi
    mv -f -- "$tmp" "$cfg" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$cfg" 2>/dev/null || true
}

ocp_hy2_write_unit() {
    svc_create "$(oc_unit_name hysteria2)" \
        "${OC_BIN_DIR}/hysteria server -c $(ocp_hy2_cfg)" \
        "OneClick Hysteria2"
}

# 清理 hysteria 端口跳跃留下的 nft 表（table ip/ip6 hysteria_<hash>）。
# hysteria 退出时会尝试自清，但 systemctl stop 后实测 IPv6 表仍残留。
# 只删名字以 hysteria_ 开头的表，不碰用户自己的规则。
ocp_hy2_clean_hop_rules() {
    command -v nft >/dev/null 2>&1 || return 0
    local fam t
    for fam in ip ip6; do
        # nft list tables 输出形如 "table ip6 hysteria_e7aaa587"
        while read -r t; do
            [[ -n "$t" ]] || continue
            nft delete table "$fam" "$t" 2>/dev/null \
                && oc_info "已清理端口跳跃转发规则：table $fam $t"
        done < <(nft list tables 2>/dev/null | awk -v f="$fam" '$1=="table" && $2==f && $3 ~ /^hysteria_/ {print $3}')
    done
    return 0
}

# 对外 IP：优先 db 里缓存的 settings.ip，避免每次外联探测。
# 探测失败返回空串，由调用方报错——绝不能兜底成 0.0.0.0 静默产出坏节点。
ocp_hy2_ip() {
    local ip
    # 双栈输出时由外层设置 OC_IP_OVERRIDE 指定本次渲染用的地址
    if [[ -n "${OC_IP_OVERRIDE:-}" ]]; then
        printf '%s' "$OC_IP_OVERRIDE"
        return 0
    fi
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "$ip"
}

# 主机名片段：取不到 IP 返回 1（调用方据此报错，不产出坏节点）；
# IPv6 必须加方括号才能拼进 URI/Surge/Loon 行。
ocp_hy2_host() {
    local ip
    ip="$(ocp_hy2_ip)"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '%s' "$ip"
}

# 自签证书才跳过校验；acme/existing 为真实证书
ocp_hy2_insecure() {
    if [[ "$(db_get hysteria2 tls_mode self)" == "self" ]]; then
        printf '1'
    else
        printf '0'
    fi
}

ocp_hy2_name() {
    printf '%s' "${OC_PROTO_TITLE[hysteria2]:-Hysteria2}"
}

# ---------- SPEC §10 契约函数 ----------

proto_hysteria2_meta() {
    printf 'title=%s\n' "$(ocp_hy2_name)"
    printf 'desc=UDP/QUIC 高丢包抗性协议，支持 salamander 混淆与端口跳跃\n'
    printf 'port=%s\n' "$(db_get hysteria2 port "")"
    printf 'udp=yes\n'
    printf 'cert=yes\n'
}

proto_hysteria2_install() {
    local unit port defport mode sni_hint crt_file key_file sni pw obfs obfs_pw
    local hop pubip tmpbin arch

    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect

    # 1. 判重：以 installed 登记为准，只有残留配置视为上次未完成
    if db_has hysteria2; then
        if ! db_is_installed hysteria2; then
            oc_warn "检测到上次未完成的 Hysteria2 安装（配置残留），本次将覆盖"
        elif [[ "${OC_YES:-0}" == "1" ]]; then
            oc_die "Hysteria2 已安装；非交互模式不覆盖，请先卸载后重装"
        elif ! oc_confirm "Hysteria2 已安装，是否重新安装（覆盖配置）？" n; then
            oc_info "已取消"
            return 0
        fi
    fi

    # 2. 端口（UDP，先判占用再下载，避免白下几十 MB）
    defport="$(ocp_hy2_default_port)"
    port="${OC_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(oc_ask "Hysteria2 监听端口（UDP）" "$defport")"
    fi
    ocp_hy2_port_ok "$port" || oc_die "端口无效：${port:-空}（需 1-65535）"
    port=$((10#$port))
    if net_port_in_use "$port" udp; then
        oc_die "UDP 端口 ${port} 已被占用；建议改用空闲端口：$(net_port_pick "$defport" udp)"
    fi

    # 3. 依赖与二进制
    arch="$(ocp_hy2_arch)" || oc_die "Hysteria2 不支持当前架构：${OC_ARCH:-未知}（支持 amd64/arm64/armv7l/i386）"
    os_dep_install base || oc_die "基础依赖安装失败，无法继续"

    oc_info "下载 Hysteria2 官方二进制（apernet/hysteria，linux-${arch}）..."
    tmpbin="$(mktemp)" || oc_die "无法创建临时文件"
    if ! ocp_hy2_fetch_bin "$tmpbin"; then
        rm -f -- "$tmpbin"
        oc_die "Hysteria2 下载失败；请检查网络或在菜单「系统工具」里设置 GitHub 镜像后重试"
    fi
    if ! ocp_hy2_check_elf "$tmpbin"; then
        rm -f -- "$tmpbin"
        oc_die "下载内容不是有效 ELF 二进制（可能是镜像返回了错误页），请更换镜像重试"
    fi
    cp -f -- "$tmpbin" "${OC_BIN_DIR}/hysteria" || {
        rm -f -- "$tmpbin"
        oc_die "写入 ${OC_BIN_DIR}/hysteria 失败"
    }
    chmod 755 "${OC_BIN_DIR}/hysteria"
    rm -f -- "$tmpbin"
    oc_ok "二进制已安装：${OC_BIN_DIR}/hysteria"

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

    obfs="off"
    obfs_pw=""
    if oc_confirm "是否启用 salamander 混淆（obfs，抗主动探测，推荐）？" n; then
        obfs="salamander"
        obfs_pw="$(os_random_token 16)"
        if [[ ${#obfs_pw} -lt 16 ]]; then
            obfs_pw="$(os_random_hex 16)"
        fi
    fi

    hop=""
    if oc_confirm "是否启用端口跳跃（UDP 端口段，由 hysteria 自身安排转发，停止时自动清理）？" n; then
        local hs he
        # 端口段避开主端口：落在 20000-30000 内就改用 40000-50000
        hs=20000; he=30000
        if ((port >= hs && port <= he)); then hs=40000; he=50000; fi
        hs="$(oc_ask "端口段起始" "$hs")"
        he="$(oc_ask "端口段结束" "$he")"
        hop="$(ocp_hy2_hop_ok "$hs" "$he" || true)"
        if [[ -z "$hop" ]]; then
            oc_warn "端口段无效（需 1-65535 且起始 < 结束），已跳过端口跳跃"
        fi
    fi

    # 6. 写配置
    ocp_hy2_write_config "$port" "$pw" "$crt_file" "$key_file" "$obfs" "$obfs_pw" "$hop" ||
        oc_die "写入配置失败：$(ocp_hy2_cfg)"
    oc_ok "配置已写入：$(ocp_hy2_cfg)"

    # 7. 服务
    unit="$(oc_unit_name hysteria2)"
    ocp_hy2_write_unit
    svc_enable "$unit"
    # 重装必须先 stop，否则 svc_start 空操作、继续跑旧配置
    svc_stop "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "Hysteria2 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "服务未能启动；请检查证书路径、UDP ${port} 是否被占用后重试"
    fi
    oc_ok "服务已启动：${unit}"

    [[ -n "$hop" ]] && oc_ok "端口跳跃已启用：UDP ${hop}（转发规则由 hysteria 管理）"

    # 9. 落库
    db_set hysteria2 port "$port"
    db_set hysteria2 password "$pw"
    db_set hysteria2 sni "$sni"
    db_set hysteria2 tls_mode "$mode"
    db_set hysteria2 tls_cert "$crt_file"
    db_set hysteria2 tls_key "$key_file"
    db_set hysteria2 obfs "$obfs"
    db_set hysteria2 obfs_password "$obfs_pw"
    db_set hysteria2 hop "$hop"
    db_set hysteria2 created "$(os_now)"
    db_mark_installed hysteria2
    pubip="$(net_primary_ip)"
    [[ -n "$pubip" ]] && db_setting ip "$pubip"

    # 10. 收尾
    oc_ok "Hysteria2 安装完成"
    if [[ "${OC_YES:-0}" == "1" ]]; then
        proto_hysteria2_link
        return 0
    fi
    oc_hr
    oc_kv "协议" "Hysteria2（QUIC/UDP）"
    oc_kv "端口(UDP)" "${port}"
    oc_kv "密码" "${pw}"
    oc_kv "SNI" "${sni}"
    oc_kv "证书方式" "${mode}"
    if [[ "$obfs" == "salamander" ]]; then
        oc_kv "混淆" "salamander（已启用）"
        oc_kv "混淆密码" "${obfs_pw}"
    else
        oc_kv "混淆" "未启用"
    fi
    if [[ -n "$hop" ]]; then
        oc_kv "端口跳跃" "UDP ${hop}"
    else
        oc_kv "端口跳跃" "未启用"
    fi
    oc_kv "服务状态" "$(proto_hysteria2_status | head -1)"
    oc_hr
    share_print_info hysteria2
}

proto_hysteria2_uninstall() {
    local unit port dir
    oc_require_root
    unit="$(oc_unit_name hysteria2)"
    if ! db_is_installed hysteria2 && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        oc_warn "Hysteria2 未安装"
        return 0
    fi
    oc_confirm "确认卸载 Hysteria2（停止服务并删除配置）？" y || {
        oc_info "已取消"
        return 0
    }
    port="$(db_get hysteria2 port "")"
    svc_remove "$unit"
    # 端口跳跃的转发规则本应由 hysteria 退出时自清，实测 stop 后仍会残留
    # （常见于 IPv6 表），这里按表名兜底清理，避免规则越积越多。
    ocp_hy2_clean_hop_rules
    dir="$(ocp_hy2_dir)"
    if [[ -n "$dir" && "$dir" == "${OC_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
    fi
    if svc_bin_referenced "${OC_BIN_DIR}/hysteria"; then
        oc_warn "检测到其他 systemd 服务仍在引用 ${OC_BIN_DIR}/hysteria，保留不删"
    elif oc_confirm "同时删除二进制 ${OC_BIN_DIR}/hysteria？" n; then
        rm -f -- "${OC_BIN_DIR}/hysteria"
    fi
    db_unmark_installed hysteria2
    db_del hysteria2
    oc_ok "Hysteria2 已卸载（证书保留在 ${OC_CERT_DIR}，可复用）"
}

# 升级 hysteria 内核。hysteria 没有配置自检命令，唯一的不兼容信号就是
# "换完起不来"，所以备份必须留到重启确认存活之后。
proto_hysteria2_upgrade() {
    local bin cfg unit asset tag digest tmp cur newver bak now
    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect
    if ! db_is_installed hysteria2; then
        oc_err "Hysteria2 未安装；请用 --install hysteria2"
        return 1
    fi
    bin="${OC_BIN_DIR}/hysteria"
    cfg="$(ocp_hy2_cfg)"
    unit="$(oc_unit_name hysteria2)"
    asset="hysteria-linux-$(ocp_hy2_arch)" || { oc_err "当前架构 ${OC_ARCH} 无 Hysteria2 构建"; return 1; }

    cur="$(oc_bin_version "$bin" || true)"
    tag="$(dl_latest_tag apernet/hysteria)"
    [[ -n "$tag" ]] || { oc_err "取不到 Hysteria 最新版本号（网络或 API 限流）"; return 1; }
    newver="${tag##*/}"; newver="${newver#v}"
    if [[ -n "$cur" && "$cur" == "$newver" ]]; then
        oc_ok "hysteria 已是最新：$cur"
        return 0
    fi
    oc_info "hysteria：${cur:-未知} → ${newver}"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-hy-up.XXXXXX")" || return 1
    digest="$(dl_asset_digest apernet/hysteria "$tag" "$asset")"
    if [[ -n "$digest" ]]; then
        dl_verify_fetch "https://github.com/apernet/hysteria/releases/download/$tag/$asset" \
            "$tmp/hysteria" none "$asset" || { rm -rf "$tmp"; return 1; }
        dl_verify_sha "$tmp/hysteria" "$digest" || { rm -rf "$tmp"; return 1; }
    else
        dl_verify_fetch "https://github.com/apernet/hysteria/releases/download/$tag/$asset" \
            "$tmp/hysteria" hashlist "$asset" || { rm -rf "$tmp"; return 1; }
    fi

    bak="$(oc_upgrade_begin "$bin")" || { rm -rf "$tmp"; return 1; }
    if ! oc_upgrade_install "$tmp/hysteria" "$bin"; then
        rm -rf "$tmp"; oc_upgrade_rollback "$bak" "$bin"; return 1
    fi
    rm -rf "$tmp"

    if ! oc_upgrade_restart "$unit"; then
        oc_err "新版本 hysteria 启动失败（配置可能不兼容），正在回滚："
        svc_logs "$unit" 20 >&2
        oc_upgrade_rollback "$bak" "$bin" && svc_restart "$unit"
        oc_err "已回滚到 ${cur:-旧版本}"
        return 1
    fi

    oc_upgrade_commit "$bak"
    now="$(oc_bin_version "$bin" || true)"
    _oc_upgrade_report "hysteria" "$cur" "$now"
    oc_ok "Hysteria2 内核已升级并重启"
}

proto_hysteria2_status() {
    local unit port pid
    unit="$(oc_unit_name hysteria2)"
    if ! db_is_installed hysteria2 && [[ ! -f "$(svc_unit_path "$unit")" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get hysteria2 port '-')"
    if svc_is_active "$unit"; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "${port:-0}"
        return 0
    fi
    if [[ "$(svc_status "$unit")" == "failed" ]]; then
        printf '已停止（failed）\n'
    else
        printf '已停止\n'
    fi
}

proto_hysteria2_link() {
    local pw port sni mode obfs obfs_pw hop host q
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    mode="$(db_get hysteria2 tls_mode self)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    host="$(ocp_hy2_host)" || return 1
    q="sni=${sni}"
    if [[ "$mode" == "self" ]]; then
        q+="&insecure=1"
    fi
    if [[ "$obfs" == "salamander" && -n "$obfs_pw" ]]; then
        q+="&obfs=salamander&obfs-password=${obfs_pw}"
    fi
    # 端口跳跃按官方 URI 规范写进端口组件（:port,start-end），不是 mport 查询参数：
    # https://v2.hysteria.network/docs/developers/URI-Scheme/
    local portpart="$port"
    [[ -n "$hop" ]] && portpart="${port},${hop}"
    printf 'hysteria2://%s@%s:%s/?%s#%s\n' "$pw" "$host" "$portpart" "$q" "$(ocp_hy2_name)"
}

proto_hysteria2_regen() {
    local unit port pw sni crt_file key_file obfs obfs_pw hop
    oc_require_root
    if ! db_is_installed hysteria2; then
        oc_die "Hysteria2 未安装，无法重生成配置"
    fi
    port="$(db_get hysteria2 port "")"
    pw="$(db_get hysteria2 password "")"
    sni="$(db_get hysteria2 sni bing.com)"
    crt_file="$(db_get hysteria2 tls_cert "")"
    key_file="$(db_get hysteria2 tls_key "")"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"

    ocp_hy2_port_ok "$port" || oc_die "数据库中的端口无效：${port:-空}"
    [[ -n "$pw" ]] || oc_die "数据库中的密码为空，请重新安装"
    if [[ -z "$crt_file" || -z "$key_file" || ! -f "$crt_file" || ! -f "$key_file" ]]; then
        oc_die "数据库记录的证书不存在（cert=${crt_file:-空} key=${key_file:-空}），请重新安装以重新签发"
    fi
    [[ "$obfs" == "salamander" ]] || obfs="off"

    ocp_hy2_write_config "$port" "$pw" "$crt_file" "$key_file" "$obfs" "$obfs_pw" "$hop" ||
        oc_die "写入配置失败：$(ocp_hy2_cfg)"
    ocp_hy2_write_unit
    unit="$(oc_unit_name hysteria2)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "配置重生成后启动失败"
    fi

    oc_ok "配置已重生成并重启：$(ocp_hy2_cfg)"
}

proto_hysteria2_clash() {
    local pw port sni obfs obfs_pw hop ip
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    ip="$(ocp_hy2_ip)"
    # _ip 返回空串时退出码仍是 0，必须显式判空
    [[ -n "$ip" ]] || return 1

    printf '  - name: "%s"\n' "$(ocp_hy2_name)"
    printf '    type: hysteria2\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    password: "%s"\n' "$pw"
    printf '    sni: "%s"\n' "$sni"
    if [[ "$(ocp_hy2_insecure)" == "1" ]]; then
        printf '    skip-cert-verify: true\n'
    fi
    if [[ "$obfs" == "salamander" && -n "$obfs_pw" ]]; then
        printf '    obfs: salamander\n'
        printf '    obfs-password: "%s"\n' "$obfs_pw"
    fi
    if [[ -n "$hop" ]]; then
        printf '    ports: %s\n' "$hop"
    fi
}

proto_hysteria2_surge() {
    local pw port sni hop line host
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    hop="$(db_get hysteria2 hop "")"
    host="$(ocp_hy2_host)" || return 1
    line="$(ocp_hy2_name) = hysteria2, ${host}, ${port}, password=${pw}, sni=${sni}"
    # Surge 手册 policies/hysteria2.html：port-hopping 用分号分隔，设置后忽略主端口
    if [[ -n "$hop" ]]; then
        line+=", port-hopping=${hop}"
    fi
    if [[ "$(ocp_hy2_insecure)" == "1" ]]; then
        line+=", skip-cert-verify=true"
    fi
    printf '%s\n' "$line"
}

proto_hysteria2_singbox() {
    local pw port sni obfs obfs_pw hop hop_ports ins host name
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    hop="$(db_get hysteria2 hop "")"
    ins="$(ocp_hy2_insecure)"
    host="$(ocp_hy2_host)" || return 1
    # tag 与 Clash/Surge/Loon 侧节点名保持一致，selector 里更好认
    name="$(ocp_hy2_name)"
    hop_ports=""
    if [[ -n "$hop" ]]; then
        hop_ports="${hop/-/:}"
    fi

    jq -n \
        --argjson port "$port" --arg server "$host" --arg pw "$pw" --arg tag "$name" \
        --arg sni "$sni" --argjson insecure "$ins" \
        --arg obfs "$obfs" --arg obfs_pw "$obfs_pw" --arg hop_ports "$hop_ports" '
        {
            type: "hysteria2",
            tag: $tag,
            server: $server,
            server_port: $port,
            password: $pw
        }
        + (if $obfs == "salamander" and $obfs_pw != "" then
              {obfs: {type: "salamander", password: $obfs_pw}}
           else {} end)
        + (if $hop_ports != "" then {server_ports: [$hop_ports]} else {} end)
        + {tls: ({enabled: true, server_name: $sni}
                 + (if $insecure == 1 then {insecure: true} else {} end))}
    '
}

# Loon 片段：Hysteria2 在 Loon 里类型名是大写 Hysteria2，SNI 参数叫 tls-name，
# 端口跳跃用 server-ports（Loon 的 hop 参数，见 Sub-Store 的 loon producer）。
proto_hysteria2_loon() {
    local pw port sni hop obfs obfs_pw line host
    pw="$(db_get hysteria2 password "")"
    port="$(db_get hysteria2 port "")"
    [[ -n "$pw" && -n "$port" ]] || return 1
    sni="$(db_get hysteria2 sni bing.com)"
    hop="$(db_get hysteria2 hop "")"
    obfs="$(db_get hysteria2 obfs off)"
    obfs_pw="$(db_get hysteria2 obfs_password "")"
    host="$(ocp_hy2_host)" || return 1
    line="$(oc_loon_name hysteria2) = Hysteria2,${host},${port},\"${pw}\""
    [[ -n "$hop" ]] && line+=",server-ports=\"${hop}\""
    line+=",sni=${sni}"
    [[ "$(ocp_hy2_insecure)" == "1" ]] && line+=",skip-cert-verify=true"
    [[ "$obfs" == "salamander" && -n "$obfs_pw" ]] && line+=",salamander-password=${obfs_pw}"
    line+=",udp=true"
    printf '%s\n' "$line"
}
