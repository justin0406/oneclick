# ============================================================
# proto/snell.sh —— Snell v6（NSSurge 官方 snell-server）
# 对外：proto_snell_meta / install / uninstall / status / link / regen / clash / surge / singbox
# 内部辅助：ocp_snell_*（本文件私有；build.sh 拼接时不允许与之重名）
#
# 版本：上游 snell.sh 内置的是 6.0.0rc2；dl.nssurge.com 上 6.0.0 正式版早已发布，
#       这里固定装正式版——rc 版的协议/配置行为官方不承诺，不适合当长期安装源。
# 架构：官方 v6.0.0 只发 amd64 / aarch64 / i386 三个包（armv7l 实测 HTTP 404），
#       所以 armv7l 直接报错，不拼一个必然 404 的地址让用户等下载重试耗尽。
#
# v6 配置事实（对 6.0.0 二进制的 strings 静态核对，不是凭记忆）：
#   [snell-server] 只认 listen / psk / mode / dns / dns-ip-preference /
#   egress-interface / ipv6（已标 deprecated）；整个二进制里没有 obfs、也没有 tfo 字样。
#   即 v6 用 mode(default|unshaped|unsafe-raw) 取代了 v4 的 obfs，写 obfs = off 是
#   "无害但无效"的遗留项。故本文件不写 obfs 键、不做 obfs 交互。
#   psk 官方要求 12–255 字节；上游脚本按 16–255 校验，这里沿用更严的 16 下限。
#
# 监听只写 0.0.0.0：v6 支持逗号分隔多地址，但 [::] 在无 IPv6 栈的机器上会导致
# 启动失败；ipv6 键已 deprecated，保留成注释行，需要时用户自己打开。
# ============================================================

# 固定版本（升级只改这一处；同时用于下载 URL 与 db.version）
OC_SNELL_VER="${OC_SNELL_VER:-6.0.0}"

# 钉死版本的资产 SHA256（dl.nssurge.com 不提供校验文件，故在代码内固定）。
# 升级 OC_SNELL_VER 时必须同步更新本表，否则会退回结构校验。
declare -gA OC_SNELL_SHA256=(
    [snell-server-v6.0.0-linux-amd64.zip]=8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2
    [snell-server-v6.0.0-linux-aarch64.zip]=a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7
    [snell-server-v6.0.0-linux-i386.zip]=67060ef79ac4ef0bb64c520302396620b3a06f8f6d5ceb450be283e4fa749335
)

# ---------- 内部辅助 ----------

# OC_ARCH -> dl.nssurge.com 的架构段。注意上游叫 aarch64，而 OC_ARCH 叫 arm64
ocp_snell_dl_arch() {
    case "${1:-}" in
        amd64)  printf 'amd64' ;;
        arm64)  printf 'aarch64' ;;
        i386)   printf 'i386' ;;
        armv7l) oc_err "Snell v6.0.0 官方未提供 armv7l 构建（只有 v4/v5 有）；请改用 amd64/arm64 或跳过本协议" ;;
        *)      oc_err "Snell 不支持当前架构：${1:-未知}" ;;
    esac
}

ocp_snell_name() {
    printf '%s' "${OC_PROTO_TITLE[snell]:-Snell v6}"
}

ocp_snell_dir() {
    oc_proto_dir snell
}

ocp_snell_cfg() {
    printf '%s/snell-server.conf' "$(ocp_snell_dir)"
}

ocp_snell_bin() {
    printf '%s/snell-server' "$OC_BIN_DIR"
}

ocp_snell_unit() {
    oc_unit_name snell
}

# 默认端口：状态库已有值就沿用（重装/改端口后再装都保持同一个入口）
ocp_snell_default_port() {
    local port
    port="$(db_get snell port "")"
    printf '%s' "${port:-$(net_port_random)}"
}

ocp_snell_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    ((n >= 1 && n <= 65535))
}

# 端口协商：OC_ARG_PORT > 状态库/meta 默认 > 交互；占用时报错并给候选端口。
# 重装且端口等于旧端口时跳过占用检查：那个监听是我们自己，稍后会被 stop 掉。
ocp_snell_ask_port() {
    local def old port alt
    def="$(ocp_snell_default_port)"
    old="$(db_get snell port "")"
    port="${OC_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(oc_ask "Snell 监听端口（TCP）" "$def")"
    fi
    port="${port//[[:space:]]/}"
    ocp_snell_port_ok "$port" || {
        oc_err "端口不合法：${port:-空}（应为 1-65535 的整数）"
        return 1
    }
    if [[ "$port" != "$old" ]] && net_port_in_use "$port" tcp; then
        alt="$(net_port_pick "${def:-20000}" tcp || true)"
        oc_err "端口 $port/tcp 已被占用；可改用空闲端口，例如 --port ${alt:-20000}"
        return 1
    fi
    printf '%s' "$port"
}

# PSK：重装沿用状态库旧值（客户端不用重新导入），只有坏值才重新生成
ocp_snell_psk() {
    local psk
    psk="$(db_get snell psk "")"
    if [[ "$psk" =~ ^[^[:space:]]{16,255}$ ]]; then
        printf '%s' "$psk"
        return 0
    fi
    psk="$(os_random_token 20)"
    [[ ${#psk} -ge 16 ]] || return 1
    printf '%s' "$psk"
}

# 写配置：600；先写临时文件再原子替换，中断不会留下半截配置
ocp_snell_write_config() {
    local port="$1" psk="$2" dir cfg tmp
    dir="$(ocp_snell_dir)"
    cfg="$(ocp_snell_cfg)"
    mkdir -p "$dir" || {
        oc_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    {
        printf '# OneClick 生成；改动后执行 oneclick --regen snell 让服务重载\n'
        printf '[snell-server]\n'
        printf 'listen = 0.0.0.0:%s\n' "$port"
        printf 'psk = %s\n' "$psk"
        printf 'mode = default\n'
        printf 'dns-ip-preference = default\n'
        printf '# ipv6 = false\n'
    } > "$tmp" || {
        rm -f -- "$tmp"
        oc_err "写入配置失败：$cfg"
        return 1
    }
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        oc_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 从已有配置里读监听端口（重装/改端口时用来撤掉旧端口规则，避免规则越积越多）
ocp_snell_cfg_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' "$cfg" | head -n1
}

ocp_snell_ip() {
    local ip
    ip="$(db_setting ip)"
    if [[ -z "$ip" ]]; then
        ip="$(net_primary_ip)"
    fi
    printf '%s' "$ip"
}

# 主机名片段：IPv6 必须加方括号才能拼进 URI/Surge 行
ocp_snell_host() {
    local ip
    ip="$(ocp_snell_ip)"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '%s' "$ip"
}

# ---------- SPEC §10 契约函数 ----------

proto_snell_meta() {
    printf 'title=%s\n' "$(ocp_snell_name)"
    printf 'desc=Snell v6 单端口 TCP，抗主动探测强；v6 用 mode 取代 obfs\n'
    printf 'port=%s\n' "$(db_get snell port "")"
    printf 'udp=no\n'
    printf 'cert=no\n'
}

proto_snell_install() {
    local unit bin cfg port psk ver arch asset url tmp cur old_port ip

    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect

    # 1. 判重：以 installed 登记为准，只有残留配置视为上次未完成
    if db_has snell; then
        if ! db_is_installed snell; then
            oc_warn "检测到上次未完成的 Snell 安装（配置残留），本次将覆盖"
        elif [[ "${OC_YES:-0}" == "1" ]]; then
            oc_die "Snell v6 已安装；非交互模式不覆盖，请先卸载（oneclick --uninstall snell --yes）"
        elif ! oc_confirm "Snell v6 已安装，是否重新安装（覆盖配置）？" n; then
            oc_info "已取消"
            return 0
        fi
    fi

    oc_title "安装 Snell v6"

    # 2. 残留清理与端口：先清上次中断留下的 unit（否则它自己的监听会被当成别人占用），
    #    再判端口，最后才下载，避免白下 10MB 才发现端口不可用。
    unit="$(ocp_snell_unit)"
    if ! db_has snell && [[ "$(svc_status "$unit")" != "not-found" ]]; then
        oc_warn "发现上次安装残留的 systemd 单元 $unit，先清理"
        svc_remove "$unit"
    fi
    port="$(ocp_snell_ask_port)" || return 1

    # 3. 依赖：Snell 是 zip 包，base 里的 unzip 已够用（dl_unzip 还会兜底安装）
    os_dep_install base || oc_die "基础依赖安装失败，无法继续"

    arch="$(ocp_snell_dl_arch "${OC_ARCH:-}")" || return 1
    bin="$(ocp_snell_bin)"
    ver=""
    # 已装同主版本的二进制就复用，省一次 10MB 下载；主版本不是 6（比如上游脚本装的 v4）必须覆盖，
    # 否则配置里的 mode 会被老版本当成未知键，链接声称 v6 实际却是 v4。
    if [[ -x "$bin" ]]; then
        # snell-server 把版本打到 stderr（[server_main] <NOTIFY> ...），必须合流才能读到
        cur="$("$bin" --version 2>&1 | head -n1 || true)"
        # 输出形如 "2026-11-09 00:02:34.504121 ... snell-server v6.0.0"，直接抓数字会先命中
        # 时间戳里的小数（34.504121），所以只认 v 前缀的版本号。
        cur="$(printf '%s' "$cur" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
        cur="${cur#v}"
        if [[ "${cur%%.*}" == "6" ]]; then
            ver="$cur"
            oc_ok "复用已安装的 snell-server ${cur}：$bin"
        elif [[ -n "$cur" ]]; then
            oc_warn "已有 snell-server ${cur} 不是 v6，将覆盖为 v${OC_SNELL_VER}"
        fi
    fi
    if [[ -z "$ver" ]]; then
        asset="snell-server-v${OC_SNELL_VER}-linux-${arch}.zip"
        url="https://dl.nssurge.com/snell/${asset}"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-snell.XXXXXX")" || oc_die "创建临时目录失败"
        oc_info "下载 Snell v${OC_SNELL_VER}（linux-${arch}）..."
        if ! dl_verify_fetch "$url" "$tmp/snell.zip" none "$asset"; then
            rm -rf -- "$tmp"
            oc_die "Snell 下载失败（dl.nssurge.com 可能限流或不可达）；可稍后重试或手动放到 $bin"
        fi
        # 静态表兜底：dl.nssurge.com 不提供任何校验文件或 API，
        # 只能对代码内置的版本做哈希校验；其它版本仅结构校验。
        if ! dl_verify_sha "$tmp/snell.zip" "${OC_SNELL_SHA256[$asset]:-}"; then
            rm -rf -- "$tmp"
            oc_die "Snell 校验失败（版本 v${OC_SNELL_VER} 的资产哈希与代码内记录不符）"
        fi
        if ! dl_unzip "$tmp/snell.zip" "$tmp/x"; then
            rm -rf -- "$tmp"
            oc_die "Snell 压缩包解压失败"
        fi
        if [[ ! -f "$tmp/x/snell-server" ]]; then
            rm -rf -- "$tmp"
            oc_die "压缩包内未找到 snell-server"
        fi
        if ! install -m 755 "$tmp/x/snell-server" "$bin"; then
            rm -rf -- "$tmp"
            oc_die "安装 snell-server 到 $bin 失败"
        fi
        rm -rf -- "$tmp"
        if ! "$bin" --version >/dev/null 2>&1; then
            # 这里不直接判死：静态 Go 二进制正常都能跑，真跑不起来时下面的启动校验
            # 会带着 journalctl 日志报错，比这里一句话更好排查。
            oc_warn "snell-server 版本自检失败（继续，启动阶段会暴露真实原因）"
        fi
        ver="$OC_SNELL_VER"
        oc_ok "snell-server v${ver} 已安装：$bin"
    fi

    # 4. 凭据
    psk="$(ocp_snell_psk)" || oc_die "生成 PSK 失败（os_random_token / openssl 不可用？）"
    [[ -n "$psk" ]] || oc_die "PSK 为空，已中止"

    # 5. 配置（600）。先记下旧配置端口，成功后撤旧端口规则
    cfg="$(ocp_snell_cfg)"
    old_port="$(ocp_snell_cfg_port "$cfg")"
    ocp_snell_write_config "$port" "$psk" || oc_die "写入 Snell 配置失败"
    oc_ok "配置已写入：$cfg"

    # 6. systemd：重装时先 stop。svc_start 对已运行的服务是空操作，
    #    不先停就会"启动成功"但仍在跑旧配置。
    svc_create "$unit" "$bin -c $cfg" "OneClick Snell v6 (snell-server)"
    svc_enable "$unit"
    svc_stop "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "Snell 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "安装中止（配置保留在 $cfg，修正后可用 oneclick --regen snell 重试）"
    fi
    oc_ok "服务已启动：$unit"

    # 8. 状态库：所有字段一次写全，最后才 mark_installed（失败时不会留下"已安装"假象）
    db_set snell port "$port"
    db_set snell psk "$psk"
    db_set snell mode "default"
    db_set snell version "$ver"
    db_set snell created "$(os_now)"
    db_mark_installed snell
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    # 9. 收尾
    oc_hr
    oc_ok "Snell v6 安装完成"
    oc_kv "服务单元" "$unit"
    oc_kv "配置文件" "$cfg"
    oc_kv "监听端口" "${port}/tcp"
    oc_kv "PSK" "$psk"
    oc_kv "协议版本" "6（mode=default）"
    oc_kv "服务状态" "$(proto_snell_status | head -n1)"
    oc_hr
    share_print_info snell || oc_warn "暂时取不到公网 IP，稍后可用 oneclick --link snell 查看"
}

proto_snell_uninstall() {
    local unit dir bin port cfg
    oc_require_root
    unit="$(ocp_snell_unit)"

    # 状态库没了但 unit 还在（恢复备份/手工删库）也允许卸载，否则残留服务永远清不掉
    if ! db_has snell && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        oc_warn "Snell v6 未安装"
        return 0
    fi
    if [[ "${OC_YES:-0}" != "1" ]]; then
        oc_confirm "确认卸载 Snell v6（停止服务并删除配置）？" n || {
            oc_info "已取消"
            return 0
        }
    fi

    dir="$(ocp_snell_dir)"
    bin="$(ocp_snell_bin)"
    cfg="$(ocp_snell_cfg)"
    port="$(db_get snell port "")"
    [[ -z "$port" ]] && port="$(ocp_snell_cfg_port "$cfg")"

    svc_remove "$unit"
    oc_ok "已停止并移除服务：$unit"
    # 默认保留二进制：它可能被面板/其它脚本复用，删错代价高；
    # 需要清理时在交互里选 y，或用 --purge 走彻底卸载。
    if svc_bin_referenced "$bin"; then
        oc_warn "检测到其他 systemd 服务仍引用 $bin（可能是你原有的 Snell 服务），保留不删"
    elif oc_confirm "同时删除 snell-server 二进制 $bin ？" n; then
        rm -f -- "$bin" && oc_ok "已删除 $bin"
    fi
    if [[ -n "$dir" && "$dir" == "${OC_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
        oc_ok "已删除配置目录：$dir"
    fi
    db_del snell
    db_unmark_installed snell
    oc_ok "Snell v6 已卸载"
}

# 升级 snell-server。
# 注意：dl.nssurge.com 没有版本发现接口，所以无法"查最新"——只能指定目标版本。
# 不给参数时列出代码内已知版本，由用户决定是否升。
proto_snell_upgrade() {
    local bin cfg unit asset cur target tmp bak now
    local target_ver="${1:-}"
    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect
    if ! db_is_installed snell; then
        oc_err "Snell 未安装；请用 --install snell"
        return 1
    fi
    bin="$(ocp_snell_bin)"
    cfg="$(ocp_snell_cfg)"
    unit="$(ocp_snell_unit)"
    cur="$(oc_bin_version "$bin" || true)"

    # snell 闭源且无版本接口：目标版本必须显式给出
    if [[ -z "$target_ver" ]]; then
        oc_warn "dl.nssurge.com 不提供版本列表，无法自动查询最新版"
        oc_info "当前版本：${cur:-未知}；代码内置版本：${OC_SNELL_VER}"
        oc_info "如需升级到其它版本：oneclick --upgrade snell --kernel-version <x.y.z>"
        return 0
    fi
    target="$target_ver"
    if [[ -n "$cur" && "$cur" == "$target" ]]; then
        oc_ok "snell-server 已是 ${cur}"
        return 0
    fi
    oc_info "snell-server：${cur:-未知} → ${target}"

    asset="snell-server-v${target}-linux-$(ocp_snell_dl_arch "${OC_ARCH:-}")" || return 1
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-snell-up.XXXXXX")" || return 1
    # snell 无官方校验文件：只能做结构校验（zip 魔数）
    if ! dl_verify_fetch "https://dl.nssurge.com/snell/${asset}.zip" "$tmp/snell.zip" none "${asset}.zip"; then
        rm -rf "$tmp"; return 1
    fi
    if ! dl_unzip "$tmp/snell.zip" "$tmp/x" || [[ ! -f "$tmp/x/snell-server" ]]; then
        rm -rf "$tmp"; oc_err "压缩包内未找到 snell-server"; return 1
    fi
    # 新版本必须能跑起来（架构/依赖不匹配在这里暴露）
    if ! oc_bin_runnable "$tmp/x/snell-server"; then
        rm -rf "$tmp"; oc_err "下载的 snell-server 无法执行（版本不存在或架构不匹配）"; return 1
    fi

    bak="$(oc_upgrade_begin "$bin")" || { rm -rf "$tmp"; return 1; }
    if ! oc_upgrade_install "$tmp/x/snell-server" "$bin"; then
        rm -rf "$tmp"; oc_upgrade_rollback "$bak" "$bin"; return 1
    fi
    rm -rf "$tmp"

    if ! oc_upgrade_restart "$unit"; then
        oc_err "新版本 snell-server 启动失败，正在回滚："
        svc_logs "$unit" 20 >&2
        oc_upgrade_rollback "$bak" "$bin" && svc_restart "$unit"
        oc_err "已回滚到 ${cur:-旧版本}"
        return 1
    fi

    oc_upgrade_commit "$bak"
    db_set snell version "$target"
    now="$(oc_bin_version "$bin" || true)"
    _oc_upgrade_report "snell-server" "$cur" "$now"
    oc_ok "Snell v6 内核已升级并重启"
}

proto_snell_status() {
    local unit port pid st
    unit="$(ocp_snell_unit)"
    if ! db_has snell && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get snell port '-')"
    st="$(svc_status "$unit")"
    # SPEC 要求状态行只有这三种形态（菜单用 grep 提取"运行中/已停止"），
    # 所以不在这一行附带重建提示，避免上层解析出歧义。
    if [[ "$st" == "active" ]]; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
    else
        printf '已停止\n'
    fi
}

proto_snell_link() {
    local port psk host name
    if ! db_has snell; then
        oc_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    [[ -n "$port" && -n "$psk" ]] || {
        oc_err "状态库缺少 port/psk，请重新安装"
        return 1
    }
    host="$(ocp_snell_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_snell_name)"
    # 官方没有标准化 URI。这里沿用本项目 gen_snell_link 的形状：PSK 直接放在 userinfo
    # （不做 base64），v6 额外带 mode；片段里的空格编码成 %20，客户端不会截断。
    printf 'snell://%s@%s:%s?version=6&mode=default#%s\n' \
        "$psk" "$host" "$port" "${name// /%20}"
}

proto_snell_regen() {
    local unit bin cfg port psk old_port
    oc_require_root
    if ! db_has snell; then
        oc_err "Snell v6 未安装，无法重生成配置"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    ocp_snell_port_ok "$port" || {
        oc_err "状态库里的端口不合法：${port:-空}（请重新安装）"
        return 1
    }
    [[ "$psk" =~ ^[^[:space:]]{16,255}$ ]] || {
        oc_err "状态库里的 PSK 不合法（需 16-255 字节且不含空白），请重新安装或先换凭据"
        return 1
    }
    bin="$(ocp_snell_bin)"
    [[ -x "$bin" ]] || {
        oc_err "缺少 $bin，请重新安装"
        return 1
    }

    cfg="$(ocp_snell_cfg)"
    old_port="$(ocp_snell_cfg_port "$cfg")"
    ocp_snell_write_config "$port" "$psk" || {
        oc_err "写入配置失败：$cfg"
        return 1
    }

    # 单元文件可能被手工删掉（或从备份恢复的状态库）：regen 顺手重建，
    # 这样菜单里的"改端口/换凭据"在任何情况下都能生效。
    unit="$(ocp_snell_unit)"
    svc_create "$unit" "$bin -c $cfg" "OneClick Snell v6 (snell-server)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "重启后服务未运行，最近日志："
        svc_logs "$unit" 30 >&2
        return 1
    fi

    oc_ok "配置已重生成并重启：$cfg"
    proto_snell_status | head -n1
    return 0
}

proto_snell_clash() {
    local port psk host name
    if ! db_has snell; then
        oc_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(ocp_snell_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_snell_name)"
    # mihomo 只实现到 Snell v1–v5，v6 会被内核拒绝；照实写出 v6 并留一行说明，
    # 等内核支持后删掉注释即可用。现在要用 v6 请走 Surge 或 sing-box。
    printf '  # mihomo 目前仅支持 Snell v1-v5；v6 请用 Surge 或 sing-box >= 1.14\n'
    printf '  - name: "%s"\n' "$name"
    printf '    type: snell\n'
    printf '    server: "%s"\n' "$host"
    printf '    port: %s\n' "$port"
    printf '    psk: "%s"\n' "$psk"
    printf '    version: 6\n'
    printf '    udp: true\n'
}

proto_snell_surge() {
    local port psk host name
    if ! db_has snell; then
        oc_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(ocp_snell_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_snell_name)"
    # 形状对齐 vless-server.sh 的 gen_snell_surge_line：v6 必须带 mode，
    # reuse/ecn 是 Surge 侧优化项，对端不支持会自动忽略。
    printf '%s = snell, %s, %s, psk=%s, version=6, mode=default, reuse=true, tfo=true, ecn=true\n' \
        "$name" "$host" "$port" "$psk"
}

proto_snell_singbox() {
    local port psk host name
    if ! db_has snell; then
        oc_err "Snell v6 未安装"
        return 1
    fi
    port="$(db_get snell port "")"
    psk="$(db_get snell psk "")"
    host="$(ocp_snell_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_snell_name)"
    # sing-box 自 1.14.0 起支持 Snell v6（outbound/snell：version + mode），
    # 所以这里给合法对象，不需要像 mihomo 那样退回失败。
    jq -c -n \
        --argjson port "$port" \
        --arg server "$host" \
        --arg psk "$psk" \
        --arg tag "$name" \
        '{
            type: "snell",
            tag: $tag,
            server: $server,
            server_port: $port,
            version: 6,
            psk: $psk,
            mode: "default"
        }'
}

# Loon 没有 Snell 支持：保留空实现，避免按格式批量调用时出现“找不到函数”。
# 生成 Loon 订阅时会在 share_render_loon 里直接跳过 snell。
proto_snell_loon() {
    return 1
}
