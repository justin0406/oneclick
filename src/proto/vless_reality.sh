# proto/vless_reality.sh —— VLESS + REALITY（Xray-core 官方内核）
# REALITY 不落地证书：借用目标站真实 TLS 握手，不需要证书库参与；
# 私钥只存在于 /etc/oneclick/db.json 与 config.json，两者都是 600，不允许只留在内存。

# 交互读取：ui.sh 的 oc_ask 把提示符也写进 stdout，$(oc_ask ...) 捕获后不可用，
# 所以这里提示走 stderr，答案走 stdout（等 ui.sh 修好后可直接换回 oc_ask）。
ocp_vless_reality_ask() {
    local prompt="$1" def="${2:-}" ans
    if [[ "$OC_YES" == "1" && -n "$def" ]]; then
        printf '%s' "$def"
        return 0
    fi
    if [[ -n "$def" ]]; then
        printf '%s [%s]: ' "$prompt" "$def" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    read -r ans || ans=""
    printf '%s' "${ans:-$def}"
}

# 输出两行：私钥、公钥。优先走 cert.sh 的 reality_keypair，失败再自己解析 xray x25519。
ocp_vless_reality_keys() {
    local tmp priv="" pub="" raw
    tmp="$(mktemp "${TMPDIR:-/tmp}/oneclick-x25519.XXXXXX")" || {
        oc_err "创建临时文件失败"
        return 1
    }
    if reality_keypair "$tmp" 2>/dev/null; then
        priv="$(jq -r '.privateKey // empty' "$tmp" 2>/dev/null)"
        pub="$(jq -r '.publicKey // empty' "$tmp" 2>/dev/null)"
    fi
    rm -f "$tmp"
    if [[ -z "$priv" || -z "$pub" ]]; then
        raw="$("$OC_BIN_DIR/xray" x25519 2>/dev/null)"
        # 两代输出格式：PrivateKey/Password（旧）、Private key/Public key（新）
        priv="$(printf '%s\n' "$raw" | awk -F': *' '/^[[:space:]]*[Pp]rivate ?[Kk]ey:/ {print $2; exit}')"
        pub="$(printf '%s\n' "$raw" | awk -F': *' '/^[[:space:]]*([Pp]ublic ?[Kk]ey|[Pp]assword)([[:space:]]*\([^)]*\))?:/ {print $2; exit}')"
    fi
    priv="$(printf '%s' "$priv" | tr -d '[:space:]')"
    pub="$(printf '%s' "$pub" | tr -d '[:space:]')"
    if [[ -z "$priv" || -z "$pub" ]]; then
        oc_err "REALITY 密钥解析失败（xray x25519 输出格式未知）"
        return 1
    fi
    printf '%s\n%s\n' "$priv" "$pub"
}

# 端口协商：OC_ARG_PORT > 交互（默认随机高位端口）；占用时提示换端口。
ocp_vless_reality_port() {
    local port="${OC_ARG_PORT:-}" alt def
    # 契约顺序：OC_ARG_PORT -> meta 的 port -> 交互；meta 未装时随机取高位端口
    def="$(proto_vless_reality_meta | sed -n 's/^port=//p')"
    [[ -z "$def" ]] && def="$(net_port_random)"
    if [[ -z "$port" ]]; then
        port="$(ocp_vless_reality_ask "REALITY 监听端口" "$def")"
    fi
    port="$(printf '%s' "$port" | tr -d '[:space:]')"
    [[ "$port" =~ ^[0-9]+$ ]] || oc_die "端口必须是数字：$port"
    ((port >= 1 && port <= 65535)) || oc_die "端口超出范围：$port"
    if net_port_in_use "$port" tcp; then
        if [[ -n "$OC_ARG_PORT" ]]; then
            alt="$(net_port_pick "$port" tcp)"
            oc_die "端口 $port 已被占用（--port 指定）；可换空闲端口，例如 --port ${alt:-$def}"
        fi
        oc_warn "端口 $port 已被占用；VLESS-Reality 需要一个独占端口"
        alt="$(net_port_pick "$port" tcp)"
        [[ -z "$alt" || "$alt" == "$port" ]] && oc_die "找不到可用端口，已取消安装"
        if ! oc_confirm "改用空闲端口 $alt ？" y; then
            oc_die "已取消安装"
        fi
        port="$alt"
        oc_info "改用端口：$port"
    fi
    printf '%s' "$port"
}

# 输出 "serverName dest"（空格分隔）。dest 缺省补 :443。
ocp_vless_reality_dest() {
    local def="${OC_ARG_SNI:-www.microsoft.com}" input sni dest
    oc_warn "提示：dest 必须是未过 CDN 的真实站点，套了 CDN 会破坏 REALITY 的 TLS 指纹"
    input="$(ocp_vless_reality_ask "REALITY 伪装域名（回车用默认，真实域名不能过 CDN）" "$def")"
    input="$(printf '%s' "$input" | tr -d '[:space:]')"
    [[ -z "$input" ]] && input="$def"
    if [[ "$input" == *:* ]]; then
        sni="${input%%:*}"
        dest="$input"
    else
        sni="$input"
        dest="$input:443"
    fi
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || oc_die "域名格式不合法：$sni"
    [[ "$sni" == *.* ]] || oc_die "域名格式不合法（需要含点）：$sni"
    printf '%s %s\n' "$sni" "$dest"
}

# 写 inbounds[0] + 基本 direct/block 出站；600；先写临时文件再 mv。
# 第 7 个参数可指定目标文件（regen 用它先写 staging 验证，验不过就不动在线配置）。
ocp_vless_reality_cfg_write() {
    local port="$1" uuid="$2" priv="$3" sni="$4" sid="$5" dest="$6" out="${7:-}"
    local dir cfg tmp
    dir="$(oc_proto_dir vless_reality)"
    cfg="${out:-$dir/config.json}"
    mkdir -p "$dir"
    [[ -n "$out" ]] && mkdir -p "$(dirname -- "$out")"
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg priv "$priv" \
        --arg sni "$sni" \
        --arg sid "$sid" \
        --arg dest "$dest" \
        --arg bind "$(oc_listen_host)" \
        '{
            log: {loglevel: "warning"},
            inbounds: [{
                listen: $bind,
                port: $port,
                protocol: "vless",
                settings: {
                    clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
                    decryption: "none"
                },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        dest: $dest,
                        xver: 0,
                        serverNames: [$sni],
                        privateKey: $priv,
                        shortIds: [$sid]
                    }
                },
                sniffing: {enabled: true, destOverride: ["http", "tls"]}
            }],
            outbounds: [
                {protocol: "freedom", tag: "direct"},
                {protocol: "blackhole", tag: "block"}
            ]
        }' > "$tmp"; then
        rm -f "$tmp"
        oc_err "生成 Xray 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp"
    if ! mv -f "$tmp" "$cfg"; then
        rm -f "$tmp"
        oc_err "写入 Xray 配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg"
    printf '%s' "$cfg"
}

# 服务器地址：db.settings.ip 优先，其次实时探测（IPv6 原样返回，由调用方决定是否加方括号）
ocp_vless_reality_ip() {
    local ip
    ip="$(db_get settings ip "")"
    [[ -z "$ip" ]] && ip="$(net_primary_ip)"
    printf '%s' "$ip"
}

proto_vless_reality_meta() {
    local port
    port="$(db_get vless_reality port "")"
    printf 'title=%s\n' "${OC_PROTO_TITLE[vless_reality]:-VLESS-Reality}"
    printf 'desc=%s\n' "Xray-core REALITY 抗封锁强，无需证书，建议独占端口"
    printf 'port=%s\n' "$port"
    printf 'udp=no\n'
    printf 'cert=no\n'
}

proto_vless_reality_install() {
    local key="vless_reality"
    local dir unit bin cfg port uuid sid sni dest priv pub ip
    local ver="" asset tmp kp

    oc_require_root
    os_detect

    if db_has "$key"; then
        if ! db_is_installed "$key"; then
            oc_warn "检测到上次未完成的 VLESS-Reality 安装（配置残留），本次将覆盖"
        elif [[ "$OC_YES" == "1" ]]; then
            oc_die "VLESS-Reality 已安装（--yes 模式不覆盖；请先 --uninstall）"
        elif ! oc_confirm "VLESS-Reality 已安装，是否重新安装（覆盖配置）？" n; then
            oc_info "已取消安装"
            return 0
        fi
    fi

    oc_title "安装 VLESS-Reality"
    os_dep_install base || oc_die "系统依赖安装失败"

    # 端口先判，避免下载完才发现被占用
    port="$(ocp_vless_reality_port)" || return 1

    bin="$OC_BIN_DIR/xray"
    if [[ -x "$bin" ]] && "$bin" version >/dev/null 2>&1; then
        ver="$("$bin" version 2>/dev/null | head -n1 | awk '{print $2}')"
        oc_ok "复用已安装 xray：$("$bin" version 2>/dev/null | head -n1)"
    else
        case "$OC_ARCH" in
            amd64)  asset="Xray-linux-64.zip" ;;
            arm64)  asset="Xray-linux-arm64-v8a.zip" ;;
            armv7l) asset="Xray-linux-arm32-v7a.zip" ;;
            i386)   asset="Xray-linux-32.zip" ;;
            *)      oc_die "Xray 官方未提供该架构的预编译包：$OC_ARCH" ;;
        esac
        ver="$(dl_latest_tag XTLS/Xray-core)"
        [[ -z "$ver" ]] && oc_die "获取 Xray-core 版本失败（网络或 GitHub API 限流），可先在设置里配 gh_proxy"
        oc_info "下载 Xray-core $ver（$asset）..."
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-xray.XXXXXX")" || oc_die "创建临时目录失败"
        if ! dl_gh XTLS/Xray-core "$ver" "$asset" "$tmp/xray.zip"; then
            rm -rf "$tmp"
            oc_die "Xray-core 下载失败"
        fi
        if ! dl_unzip "$tmp/xray.zip" "$tmp/unzip"; then
            rm -rf "$tmp"
            oc_die "Xray-core 解压失败"
        fi
        if [[ ! -f "$tmp/unzip/xray" ]]; then
            rm -rf "$tmp"
            oc_die "压缩包内未找到 xray 可执行文件"
        fi
        if ! cp -f "$tmp/unzip/xray" "$bin" || ! chmod 755 "$bin"; then
            rm -rf "$tmp"
            oc_die "安装 xray 到 $bin 失败"
        fi
        rm -rf "$tmp"
        if ! "$bin" version >/dev/null 2>&1; then
            oc_die "xray 无法执行（CPU 架构不匹配？）"
        fi
        oc_ok "xray 已安装：$("$bin" version 2>/dev/null | head -n1)"
    fi

    uuid="$(os_uuid)"
    sid="$(os_random_hex 4)"
    sid="${sid:0:8}"
    [[ -n "$sid" ]] || oc_die "生成 shortId 失败"

    kp="$(ocp_vless_reality_keys)" || oc_die "REALITY 密钥对生成失败"
    priv="$(printf '%s\n' "$kp" | sed -n '1p')"
    pub="$(printf '%s\n' "$kp" | sed -n '2p')"
    [[ -n "$priv" && -n "$pub" ]] || oc_die "REALITY 密钥为空"

    # 私钥第一时间落库，避免安装中断后私钥只剩内存/半截文件
    db_set "$key" private_key "$priv"
    db_set "$key" public_key "$pub"
    db_set "$key" uuid "$uuid"
    db_set "$key" short_id "$sid"

    read -r sni dest <<< "$(ocp_vless_reality_dest)"
    [[ -n "$sni" && -n "$dest" ]] || oc_die "REALITY dest 获取失败"

    dir="$(oc_proto_dir "$key")"
    if ! cfg="$(ocp_vless_reality_cfg_write "$port" "$uuid" "$priv" "$sni" "$sid" "$dest")"; then
        oc_die "写入配置失败（目录：$dir）"
    fi
    oc_ok "配置已写入：$cfg"

    if ! "$bin" run -test -c "$cfg" >/dev/null 2>&1; then
        oc_err "Xray 配置自检失败，输出如下："
        "$bin" run -test -c "$cfg" 2>&1 | tail -n 20 >&2
        oc_die "已中止（配置保留在 $cfg 供排查）"
    fi

    unit="$(oc_unit_name "$key")"
    svc_create "$unit" "$bin run -c $cfg" "OneClick VLESS-Reality (Xray-core)"
    svc_enable "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "VLESS-Reality 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "安装中止（配置保留在 $cfg）"
    fi
    oc_ok "服务已启动：$unit"

    # 先按 comment 删旧规则再放行，重装/重跑不会叠加

    db_set "$key" port "$port"
    db_set "$key" server_name "$sni"
    db_set "$key" dest "$dest"
    db_set "$key" flow "xtls-rprx-vision"
    db_set "$key" version "$ver"
    db_set "$key" created "$(os_now)"
    db_mark_installed "$key"
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    oc_hr
    oc_ok "VLESS-Reality 安装完成"
    oc_kv "服务单元" "$unit"
    oc_kv "配置文件" "$cfg"
    oc_kv "监听端口" "$port"
    oc_kv "UUID" "$uuid"
    oc_kv "SNI / dest" "$sni / $dest"
    oc_kv "ShortId" "$sid"
    oc_kv "公钥 (pbk)" "$pub"
    oc_kv "状态" "$(proto_vless_reality_status)"
    printf '\n'
    # 拿不到公网 IP 不该让整个安装报失败，装好后 oneclick --link 还能再取
    share_print_info vless_reality || oc_warn "暂时取不到公网 IP，稍后用 oneclick --link vless_reality 查看配置信息"
    oc_warn "REALITY 需要客户端直连该端口，套 CDN 或前置反代会失效"
}

proto_vless_reality_uninstall() {
    local key="vless_reality" unit dir bin port
    oc_require_root
    if ! db_has "$key"; then
        oc_warn "VLESS-Reality 未安装"
        return 0
    fi
    if [[ "$OC_YES" != "1" ]] && ! oc_confirm "确认卸载 VLESS-Reality？" n; then
        oc_info "已取消"
        return 0
    fi

    unit="$(oc_unit_name "$key")"
    dir="$(oc_proto_dir "$key")"
    port="$(db_get "$key" port "")"

    svc_remove "$unit"
    oc_ok "已停止并移除服务：$unit"

    bin="$OC_BIN_DIR/xray"
    if svc_bin_referenced "$bin"; then
        oc_warn "检测到其他 systemd 服务仍在引用 $bin（如 x-ui），保留不删"
    elif [[ "$OC_YES" != "1" ]] && oc_confirm "同时删除 xray 二进制 $bin ？" n; then
        rm -f "$bin"
        oc_ok "已删除 $bin"
    fi

    if [[ -d "$dir" ]]; then
        rm -rf "${dir:?}"
        oc_ok "已删除配置目录：$dir"
    fi

    db_del "$key"
    db_unmark_installed "$key"
    oc_ok "VLESS-Reality 已卸载"
}

proto_vless_reality_status() {
    local key="vless_reality" unit port st pid
    if ! db_has "$key"; then
        printf '未安装\n'
        return 0
    fi
    unit="$(oc_unit_name "$key")"
    port="$(db_get "$key" port "?")"
    st="$(svc_status "$unit")"
    case "$st" in
        active)
            pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null)"
            printf '运行中 pid=%s port=%s\n' "${pid:-?}" "$port"
            ;;
        not-found) printf '已停止（unit 缺失）\n' ;;
        *)         printf '已停止\n' ;;
    esac
}

proto_vless_reality_link() {
    local key="vless_reality" uuid ip port sni sid pub name
    if ! db_has "$key"; then
        oc_err "VLESS-Reality 未安装"
        return 1
    fi
    uuid="$(db_get "$key" uuid "")"
    port="$(db_get "$key" port "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    if [[ -z "$uuid" || -z "$sid" || -z "$pub" ]]; then
        oc_err "状态库缺少 uuid / short_id / public_key，请重新安装"
        return 1
    fi
    ip="$(ocp_vless_reality_ip)"
    [[ -z "$ip" ]] && {
        oc_err "无法获取服务器公网 IP（可执行 oneclick --check-ip 后重试）"
        return 1
    }
    [[ "$ip" == *:* ]] && ip="[$ip]"
    name="${OC_PROTO_TITLE[$key]:-VLESS-Reality}"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ip" "$port" "$sni" "$pub" "$sid" "$name"
}

proto_vless_reality_regen() {
    local key="vless_reality" port uuid priv pub sni sid dest cfg unit bin
    oc_require_root
    if ! db_has "$key"; then
        oc_die "VLESS-Reality 未安装，无法重生成配置"
    fi
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    priv="$(db_get "$key" private_key "")"
    pub="$(db_get "$key" public_key "")"
    sni="$(db_get "$key" server_name "")"
    sid="$(db_get "$key" short_id "")"
    dest="$(db_get "$key" dest "")"

    local missing=""
    [[ -z "$port" ]] && missing+=" port"
    [[ -z "$uuid" ]] && missing+=" uuid"
    [[ -z "$priv" ]] && missing+=" private_key"
    [[ -z "$pub" ]] && missing+=" public_key"
    [[ -z "$sni" ]] && missing+=" server_name"
    [[ -z "$sid" ]] && missing+=" short_id"
    [[ -z "$dest" ]] && missing+=" dest"
    [[ -n "$missing" ]] && oc_die "状态库缺少字段：${missing# }（请重新安装）"

    bin="$OC_BIN_DIR/xray"
    [[ -x "$bin" ]] || oc_die "缺少 $bin，请重新安装"

    local dir staging
    dir="$(oc_proto_dir "$key")"
    cfg="$dir/config.json"
    staging="${cfg}.new"
    # 先写 staging 再自检：校验不过时在线配置原封不动，服务继续用旧配置跑
    if ! ocp_vless_reality_cfg_write "$port" "$uuid" "$priv" "$sni" "$sid" "$dest" "$staging" >/dev/null; then
        rm -f "$staging"
        oc_die "写入配置失败"
    fi
    if ! "$bin" run -test -c "$staging" >/dev/null 2>&1; then
        "$bin" run -test -c "$staging" 2>&1 | tail -n 20 >&2
        rm -f "$staging"
        oc_die "新配置自检失败，已保留旧配置（请检查状态库字段）"
    fi
    mv -f "$staging" "$cfg" || oc_die "替换配置失败：$cfg"
    chmod 600 "$cfg" 2>/dev/null || true

    unit="$(oc_unit_name "$key")"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "重启失败，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "配置已重写但服务未起来，请检查日志"
    fi
    oc_ok "配置已重写并重启：$cfg"
    proto_vless_reality_status
}

proto_vless_reality_clash() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        oc_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(ocp_vless_reality_ip)"
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${OC_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    printf '  - name: "%s"\n' "$name"
    printf '    type: vless\n'
    printf '    server: "%s"\n' "$ip"
    printf '    port: %s\n' "$port"
    printf '    uuid: %s\n' "$uuid"
    printf '    network: tcp\n'
    printf '    tls: true\n'
    printf '    udp: true\n'
    printf '    flow: xtls-rprx-vision\n'
    printf '    servername: %s\n' "$sni"
    printf '    reality-opts:\n'
    printf '      public-key: %s\n' "$pub"
    printf '      short-id: %s\n' "$sid"
    printf '    client-fingerprint: chrome\n'
}

proto_vless_reality_surge() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        oc_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(ocp_vless_reality_ip)"
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${OC_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    # Surge 的 VLESS 行：username 即 uuid；REALITY 用 reality=true + public-key/short-id
    printf '%s = vless, %s, %s, username=%s, tls=true, sni=%s, reality=true, public-key=%s, short-id=%s, flow=xtls-rprx-vision, skip-cert-verify=true\n' \
        "$name" "$ip" "$port" "$uuid" "$sni" "$pub" "$sid"
}

proto_vless_reality_singbox() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        oc_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(ocp_vless_reality_ip)"
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    name="${OC_PROTO_TITLE[$key]:-VLESS-Reality}"
    [[ -z "$ip" ]] && return 1
    jq -c -n \
        --arg tag "$name" \
        --arg server "$ip" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg sni "$sni" \
        --arg pbk "$pub" \
        --arg sid "$sid" \
        '{
            type: "vless",
            tag: $tag,
            server: $server,
            server_port: $port,
            uuid: $uuid,
            flow: "xtls-rprx-vision",
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {enabled: true, public_key: $pbk, short_id: $sid},
                utls: {enabled: true, fingerprint: "chrome"}
            }
        }'
}

# Loon 片段：Loon 用 sni + public-key + short-id 表达 REALITY，
# tls-profile=chrome 对应客户端的 client-fingerprint（见 Sub-Store 的 loon producer）。
proto_vless_reality_loon() {
    local key="vless_reality" ip port uuid sni sid pub name
    if ! db_has "$key"; then
        oc_err "VLESS-Reality 未安装"
        return 1
    fi
    ip="$(ocp_vless_reality_ip)"
    port="$(db_get "$key" port "")"
    uuid="$(db_get "$key" uuid "")"
    sni="$(db_get "$key" server_name "www.microsoft.com")"
    sid="$(db_get "$key" short_id "")"
    pub="$(db_get "$key" public_key "")"
    [[ -n "$ip" && -n "$uuid" && -n "$sid" && -n "$pub" ]] || return 1
    name="$(oc_loon_name "$key")"
    printf '%s = VLESS,%s,%s,"%s",transport=tcp,over-tls=true,tls-profile=chrome,flow=xtls-rprx-vision,sni=%s,public-key="%s",short-id=%s,udp=true\n' \
        "$name" "$ip" "$port" "$uuid" "$sni" "$pub" "$sid"
}
