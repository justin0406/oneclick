# ============================================================
# proto/ss_rust.sh —— Shadowsocks-Rust（SS2022 优先）+ 可选 ShadowTLS v3
# 对外：proto_ss_rust_meta / install / uninstall / status / link / regen / clash / surge / singbox
# 内部辅助：ocp_ssrust_*（本文件私有；build.sh 拼接时不允许与之重名）
#
# 选型：用 shadowsocks-rust 官方 release（ssserver），SS2022 优先。
#   SS2022 的密码是"密钥"而不是口令：必须是 base64，解码后 16 字节（aes-128）或
#   32 字节（aes-256 / chacha20-poly1305）。用 openssl rand -base64 生成，
#   菜单里"换凭据"写进来的普通随机串会不兼容——regen 会检测并自动重生。
#
# ShadowTLS v3：可选，安装时询问（默认关）。它借用真实站点的证书完成握手，
#   服务端不需要自己的证书，所以本文件不调用 cert_ensure（证书体系与本协议无关）。
#   客户端连接顺序是 shadow-tls → ssserver，故 unit 起来也是先后端后入口。
#
# 卸载必须 svc_remove：上游 ss-rust.sh 的已知 bug 是只 disable 不删 unit，
#   残留单元会让下次安装的 svc_start 对着旧 ExecStart "假成功"，配置改了也不生效。
# ============================================================

# 下载版本；OC_SSRUST_VER 为空表示取 GitHub 最新，取不到再用下面的已知版本兜底
OC_SSRUST_VER="${OC_SSRUST_VER:-}"
# ShadowTLS 版本；同样为空表示取最新，失败用兜底版本
OC_SSRUST_STLS_VER="${OC_SSRUST_STLS_VER:-}"
OC_SSRUST_FALLBACK_VER="1.25.0"
OC_SSRUST_STLS_FALLBACK_VER="0.2.25"

# 默认方法与兼容退路：默认 SS2022（抗重放、无 IV 复用风险）；老客户端不支持时可选 AEAD
OC_SSRUST_METHOD="${OC_SSRUST_METHOD:-2022-blake3-aes-128-gcm}"
# ShadowTLS 伪装 SNI：需可直连、支持 TLS1.3 的真实 HTTPS 站点。
# 服务端 fallback 必须与客户端 SNI 指向同一站点（见写配置处），否则已认证客户端
# 会被转发到 SNI 不匹配的站点并立刻断开（已在 Debian 13 VPS 上复现）。
OC_SSRUST_STLS_SNI="${OC_SSRUST_STLS_SNI:-cloudflare.com}"

# ---------- 内部辅助 ----------

ocp_ssrust_name() {
    printf '%s' "${OC_PROTO_TITLE[ss_rust]:-SS-Rust}"
}

ocp_ssrust_dir() {
    oc_proto_dir ss_rust
}

ocp_ssrust_cfg() {
    printf '%s/config.json' "$(ocp_ssrust_dir)"
}

ocp_ssrust_stls_cfg() {
    printf '%s/shadowtls.json' "$(ocp_ssrust_dir)"
}

ocp_ssrust_bin() {
    printf '%s/ssserver' "$OC_BIN_DIR"
}

ocp_ssrust_stls_bin() {
    printf '%s/shadow-tls' "$OC_BIN_DIR"
}

ocp_ssrust_unit() {
    oc_unit_name ss_rust
}

ocp_ssrust_stls_unit() {
    printf '%s' "$(oc_unit_name ss_rust)-shadowtls"
}

ocp_ssrust_default_port() {
    local port
    port="$(db_get ss_rust port "")"
    printf '%s' "${port:-$(net_port_random)}"
}

ocp_ssrust_port_ok() {
    local p="${1:-}" n
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
    n=$((10#$p))
    ((n >= 1 && n <= 65535))
}

# OC_ARCH -> shadowsocks-rust release 的 target 段。
# 一律选 musl 静态版：官方 gnu 版在 Ubuntu 24.04 上构建，要求 GLIBC_2.38+，
# 在 Debian 12 / Ubuntu 22.04 等 glibc 较旧的目标机上会直接报 "GLIBC_2.38 not found"。
ocp_ssrust_arch() {
    case "${OC_ARCH:-}" in
        amd64)  printf 'x86_64-unknown-linux-musl' ;;
        arm64)  printf 'aarch64-unknown-linux-musl' ;;
        armv7l) printf 'armv7-unknown-linux-musleabihf' ;;
        i386)   printf 'i686-unknown-linux-musl' ;;
        *)      oc_err "SS-Rust 不支持当前架构：${OC_ARCH:-未知}" ;;
    esac
}

# OC_ARCH -> shadow-tls release 的 target 段（musl 静态单文件；无 i386 构建）
ocp_ssrust_stls_arch() {
    case "${OC_ARCH:-}" in
        amd64)  printf 'x86_64-unknown-linux-musl' ;;
        arm64)  printf 'aarch64-unknown-linux-musl' ;;
        armv7l) printf 'armv7-unknown-linux-musleabihf' ;;
        i386)   oc_err "ShadowTLS 未提供 i386 构建；可用 --no-shadowtls 的安装方式跳过（i386 请选择不启用）" ;;
        *)      oc_err "ShadowTLS 不支持当前架构：${OC_ARCH:-未知}" ;;
    esac
}

# .tar.xz 解压需要 xz；os_dep_install 的 base 里没有它，这里按发行版补装。
# GNU tar 会自动识别 xz 压缩，但前提是系统里存在 xz 可执行文件。
ocp_ssrust_ensure_xz() {
    command -v xz >/dev/null 2>&1 && return 0
    oc_info "安装 xz（解开 .tar.xz 需要）..."
    case "$(os_family)" in
        debian) os_pkg_install xz-utils || return 1 ;;
        rhel)   os_pkg_install xz || return 1 ;;
        *)
            oc_err "系统缺少 xz，且未识别的发行版，请手动安装 xz 后重试"
            return 1
            ;;
    esac
    command -v xz >/dev/null 2>&1
}

# 端口协商（TCP 与 UDP 都要，协议本身 tcp_and_udp）：
# OC_ARG_PORT > 状态库/meta 默认 > 交互；占用时报错并给候选端口。
# 重装且端口等于旧端口时跳过检查：那是我们自己的监听，稍后会 stop。
ocp_ssrust_ask_port() {
    local def old port alt proto
    def="$(ocp_ssrust_default_port)"
    old="$(db_get ss_rust port "")"
    port="${OC_ARG_PORT:-}"
    if [[ -z "$port" ]]; then
        port="$(oc_ask "SS-Rust 监听端口（TCP+UDP）" "$def")"
    fi
    port="${port//[[:space:]]/}"
    ocp_ssrust_port_ok "$port" || {
        oc_err "端口不合法：${port:-空}（应为 1-65535 的整数）"
        return 1
    }
    if [[ "$port" != "$old" ]]; then
        for proto in tcp udp; do
            if net_port_in_use "$port" "$proto"; then
                alt="$(net_port_pick "${def:-20000}" "$proto" || true)"
                oc_err "端口 $port/$proto 已被占用；可改用空闲端口，例如 --port ${alt:-20000}"
                return 1
            fi
        done
    fi
    printf '%s' "$port"
}

# ShadowTLS 入口端口：随机高位，重装沿用旧值；必须与 SS 端口不同
ocp_ssrust_ask_stls_port() {
    local ss_port="$1" old port alt
    local def
    old="$(db_get ss_rust stls_port "")"
    def="$old"
    if [[ -z "$def" ]]; then
        def="$(net_port_random)"
        while [[ "$def" == "$ss_port" ]]; do def="$(net_port_random)"; done
    fi
    port="$(oc_ask "ShadowTLS 监听端口（TCP）" "$def")"
    port="${port//[[:space:]]/}"
    ocp_ssrust_port_ok "$port" || {
        oc_err "端口不合法：${port:-空}"
        return 1
    }
    if [[ "$port" == "$ss_port" ]]; then
        oc_err "ShadowTLS 端口不能与 SS-Rust 端口相同（都写 $ss_port）"
        return 1
    fi
    if [[ "$port" != "$old" ]] && net_port_in_use "$port" tcp; then
        alt="$(net_port_pick "${def:-20000}" tcp || true)"
        oc_err "端口 $port/tcp 已被占用；可改用空闲端口，例如 ${alt:-20000}"
        return 1
    fi
    printf '%s' "$port"
}

# 伪装 SNI：OC_ARG_SNI > 状态库 > cloudflare.com；只做基本域名校验，
# 真正的可用性取决于该站点是否支持 TLS1.3（shadow-tls v3 需要）
ocp_ssrust_ask_sni() {
    local def sni
    def="${OC_ARG_SNI:-$(db_get ss_rust stls_sni "$OC_SSRUST_STLS_SNI")}"
    sni="$(oc_ask "ShadowTLS 伪装 SNI（可直连的真实 HTTPS 站点）" "$def")"
    sni="$(printf '%s' "$sni" | tr -d '[:space:]')"
    [[ "$sni" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || {
        oc_err "SNI 不合法：${sni:-空}"
        return 1
    }
    [[ "$sni" == *.* ]] || {
        oc_err "SNI 不合法（需要含点的域名）：$sni"
        return 1
    }
    printf '%s' "$sni"
}

# SS2022 的密码是密钥：必须能 base64 解码且长度正好 16/32 字节。
# 其它 AEAD/流密码没有形状要求，非空即可。
ocp_ssrust_pw_ok() {
    local method="$1" pw="${2:-}" n
    case "$method" in
        2022-blake3-aes-128-gcm)
            n="$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
            [[ "$n" == "16" ]]
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            n="$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
            [[ "$n" == "32" ]]
            ;;
        2022-*)
            # 未来新增的 2022 方法不做形状判断，交给 ssserver 启动校验兜底
            [[ -n "$pw" ]]
            ;;
        *)
            [[ -n "$pw" ]]
            ;;
    esac
}

ocp_ssrust_pw_gen() {
    local method="$1" pw=""
    case "$method" in
        2022-blake3-aes-128-gcm)
            pw="$(openssl rand -base64 16 2>/dev/null)"
            ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
            pw="$(openssl rand -base64 32 2>/dev/null)"
            ;;
        *)
            pw="$(os_random_token 24)"
            ;;
    esac
    pw="$(printf '%s' "$pw" | tr -d '\r\n')"
    printf '%s' "$pw"
}

# 方法选择：不交互。优先级 --method > 已装方法（密码兼容则沿用）> OC_SSRUST_METHOD > 默认 SS2022。
# 客户端是否支持 SS2022 在服务端无法探测（没有任何握手特征可查），所以默认选更新的
# SS2022，老客户端用 --method chacha20-ietf-poly1305 显式指定。
ocp_ssrust_pick_method() {
    local old_method old_pw method
    method="${OC_ARG_METHOD:-}"
    if [[ -z "$method" ]]; then
        old_method="$(db_get ss_rust method "")"
        old_pw="$(db_get ss_rust password "")"
        if [[ -n "$old_method" ]] && ocp_ssrust_pw_ok "$old_method" "$old_pw"; then
            printf '%s' "$old_method"
            return 0
        fi
        method="$OC_SSRUST_METHOD"
    fi
    case "$method" in
        2022-*|aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|chacha20-poly1305|aes-128-ctr|aes-192-ctr|aes-256-ctr|aes-128-cfb|aes-192-cfb|aes-256-cfb|xchacha20-ietf-poly1305|plain)
            ;;
        *)
            oc_err "不支持的加密方式：$method（可用：2022-blake3-aes-128-gcm / chacha20-ietf-poly1305 等）"
            return 1
            ;;
    esac
    printf '%s' "$method"
}

# 写主配置：600；先临时文件再原子替换，避免中断留下半截 JSON
ocp_ssrust_write_config() {
    local port="$1" password="$2" method="$3" timeout="${4:-300}" mode="${5:-tcp_and_udp}"
    local dir cfg tmp
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=300
    dir="$(ocp_ssrust_dir)"
    cfg="$(ocp_ssrust_cfg)"
    mkdir -p "$dir" || {
        oc_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg method "$method" \
        --arg mode "$mode" \
        --argjson timeout "$timeout" \
        --arg bind "$(oc_listen_host)" \
        '{
            server: $bind,
            server_port: $port,
            password: $password,
            method: $method,
            mode: $mode,
            timeout: $timeout
        }' > "$tmp"; then
        rm -f -- "$tmp"
        oc_err "生成 SS-Rust 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        oc_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 写 ShadowTLS 配置：JSON 里带密码，600；密码不进 argv，ps 里看不到。
# 结构照上游：v3 客户端先与 dispatch 里的 SNI 握手，未认证流量走 fallback。
ocp_ssrust_write_stls_config() {
    local stls_port="$1" ss_port="$2" sni="$3" password="$4"
    local dir cfg tmp
    dir="$(ocp_ssrust_dir)"
    cfg="$(ocp_ssrust_stls_cfg)"
    mkdir -p "$dir" || {
        oc_err "创建目录失败：$dir"
        return 1
    }
    chmod 700 "$dir" 2>/dev/null || true
    tmp="${cfg}.tmp.$$"
    if ! jq -n \
        --argjson stls_port "$stls_port" \
        --arg ss_addr "127.0.0.1:${ss_port}" \
        --arg sni "${sni}:443" \
        --arg password "$password" \
        --arg bind "$(oc_listen_addr "$stls_port")" \
        '{
            v3: true,
            strict: true,
            fastopen: false,
            disable_nodelay: false,
            server: {
                listen: $bind,
                server_addr: $ss_addr,
                tls_addr: {
                    wildcard_sni: "authed",
                    dispatch: { ($sni): $sni },
                    fallback: $sni
                },
                password: $password
            }
        }' > "$tmp"; then
        rm -f -- "$tmp"
        oc_err "生成 ShadowTLS 配置失败（jq 出错）"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f -- "$tmp" "$cfg"; then
        rm -f -- "$tmp"
        oc_err "替换配置失败：$cfg"
        return 1
    fi
    chmod 600 "$cfg" 2>/dev/null || true
}

# 从已有配置读端口：重装/改端口时用来撤旧端口规则，避免规则越积越多
ocp_ssrust_cfg_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    jq -r '.server_port // empty' "$cfg" 2>/dev/null
}

ocp_ssrust_cfg_stls_port() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    jq -r '.server.listen // empty' "$cfg" 2>/dev/null |
        sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -n1
}

ocp_ssrust_ip() {
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

# IPv6 必须加方括号才能拼进 URI/Surge 行
ocp_ssrust_host() {
    local ip
    ip="$(ocp_ssrust_ip)"
    [[ -z "$ip" ]] && return 1
    [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '%s' "$ip"
}

# SIP002 userinfo：base64url(method:password) 且去掉 padding。
# SS2022 密钥里会出现 + 和 /，URL-safe 编码才能安全放进 URI。
ocp_ssrust_b64url() {
    printf '%s' "$1" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='
}

# SIP002 userinfo，按加密方式选择编码（SIP022 有强制要求）：
#   - SS2022（2022-*）：userinfo MUST NOT 用 Base64URL，必须明文且 method/password
#     各自百分号编码。否则严格实现的客户端（mihomo/sing-box/Shadowrocket）解析失败。
#   - 传统 AEAD/stream：Base64URL 推荐但不强制，沿用 base64url 保持向后兼容。
ocp_ssrust_userinfo() {
    local method="$1" password="$2"
    case "$method" in
        2022-*)
            # 百分号编码：除 unreserved 字符外全部转义
            printf '%s:%s' \
                "$(ocp_ssrust_pct "$method")" \
                "$(ocp_ssrust_pct "$password")"
            ;;
        *)
            ocp_ssrust_b64url "${method}:${password}"
            ;;
    esac
}

# RFC3986 百分号编码（保留 unreserved：A-Z a-z 0-9 - . _ ~）
ocp_ssrust_pct() {
    local s="$1" out="" c i
    LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

# 下载并安装 ssserver。<ver> 由调用方给出（含 v 的 tag 名由本函数自己拼）。
# 不用 dl_gh：它拿 dl_latest_tag 去掉 v 的版本号去拼 /download/<ver>/，会 404。
ocp_ssrust_fetch_ss() {
    local ver="$1" arch bin asset url tmp
    arch="$(ocp_ssrust_arch)" || return 1
    bin="$(ocp_ssrust_bin)"
    asset="shadowsocks-v${ver}.${arch}.tar.xz"
    url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${ver}/${asset}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-ssrust.XXXXXX")" || {
        oc_err "创建临时目录失败"
        return 1
    }
    oc_info "下载 Shadowsocks-Rust v${ver}（${arch}）..."
    # 每个资产都有同名 .sha256（内容 "<hex>  <asset>"）
    if ! dl_verify_fetch "$url" "$tmp/ss.tar.xz" plain "$asset"; then
        rm -rf -- "$tmp"
        oc_err "Shadowsocks-Rust 下载或校验失败（GitHub 可能不可达）"
        return 1
    fi
    if ! dl_untar "$tmp/ss.tar.xz" "$tmp/x"; then
        rm -rf -- "$tmp"
        oc_err "Shadowsocks-Rust 解压失败（xz 不可用？）"
        return 1
    fi
    if [[ ! -f "$tmp/x/ssserver" ]]; then
        rm -rf -- "$tmp"
        oc_err "压缩包内未找到 ssserver"
        return 1
    fi
    if ! install -m 755 "$tmp/x/ssserver" "$bin"; then
        rm -rf -- "$tmp"
        oc_err "安装 ssserver 到 $bin 失败"
        return 1
    fi
    rm -rf -- "$tmp"
    # 硬校验：能执行才算装好。-h 会把 "GLIBC_x.y not found" 打到 stderr，
    # 只看有无输出会误判，这里必须看退出码。
    if ! "$bin" -V >/dev/null 2>&1 && ! "$bin" -h >/dev/null 2>&1; then
        oc_err "ssserver 无法执行（架构不匹配或依赖缺失）：$bin"
        "$bin" -V 2>&1 | head -n3 >&2 || true
        return 1
    fi
}

# 下载并安装 shadow-tls（release 里是单个静态可执行文件，无压缩）
ocp_ssrust_fetch_stls() {
    local ver="$1" tar_arch bin asset url tmp
    tar_arch="$(ocp_ssrust_stls_arch)" || return 1
    bin="$(ocp_ssrust_stls_bin)"
    asset="shadow-tls-${tar_arch}"
    url="https://github.com/ihciah/shadow-tls/releases/download/v${ver}/${asset}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-stls.XXXXXX")" || {
        oc_err "创建临时目录失败"
        return 1
    }
    oc_info "下载 ShadowTLS v${ver}（${tar_arch}）..."
    # shadow-tls 的 release 不提供校验文件，只能做结构校验（ELF 魔数）
    if ! dl_verify_fetch "$url" "$tmp/shadow-tls" none "$asset"; then
        rm -rf -- "$tmp"
        oc_err "ShadowTLS 下载失败（GitHub 可能不可达，或镜像返回了错误页）"
        return 1
    fi
    if ! install -m 755 "$tmp/shadow-tls" "$bin"; then
        rm -rf -- "$tmp"
        oc_err "安装 shadow-tls 到 $bin 失败"
        return 1
    fi
    rm -rf -- "$tmp"
    if ! "$bin" -V >/dev/null 2>&1 && ! "$bin" --version >/dev/null 2>&1; then
        oc_warn "shadow-tls 已落盘但无法执行（架构或依赖问题）：$bin"
    fi
}

# ---------- SPEC §10 契约函数 ----------

proto_ss_rust_meta() {
    printf 'title=%s\n' "$(ocp_ssrust_name)"
    printf 'desc=Shadowsocks-Rust（SS2022 优先，TCP+UDP；可选 ShadowTLS v3 伪装）\n'
    printf 'port=%s\n' "$(db_get ss_rust port "")"
    printf 'udp=yes\n'
    printf 'cert=no\n'
}

proto_ss_rust_install() {
    local unit stl_unit bin stbin dir cfg stcfg ver stver
    local port method password timeout mode stls stls_port stls_pw stls_sni
    local old_port old_stls_port ip

    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect

    # 1. 判重：以 installed 登记为准，只有残留配置视为上次未完成
    if db_has ss_rust; then
        if ! db_is_installed ss_rust; then
            oc_warn "检测到上次未完成的 SS-Rust 安装（配置残留），本次将覆盖"
        elif [[ "${OC_YES:-0}" == "1" ]]; then
            oc_die "SS-Rust 已安装；非交互模式不覆盖，请先卸载（oneclick --uninstall ss_rust --yes）"
        elif ! oc_confirm "SS-Rust 已安装，是否重新安装（覆盖配置）？" n; then
            oc_info "已取消"
            return 0
        fi
    fi

    oc_title "安装 SS-Rust"

    unit="$(ocp_ssrust_unit)"
    stl_unit="$(ocp_ssrust_stls_unit)"

    # 2. 上次中断可能留下 unit 而状态库没记录：先清掉，
    #    否则下面端口占用检查会把自己上次的监听当成别人的端口
    if ! db_has ss_rust; then
        if [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
            oc_warn "发现残留的 systemd 单元 $stl_unit，先清理"
            svc_remove "$stl_unit"
        fi
        if [[ "$(svc_status "$unit")" != "not-found" ]]; then
            oc_warn "发现残留的 systemd 单元 $unit，先清理"
            svc_remove "$unit"
        fi
    fi

    # 3. 端口：先判占用（ss 的 tcp 与可选 udp），避免下载完才发现不可用
    port="$(ocp_ssrust_ask_port)" || return 1

    # 4. 依赖：.tar.xz 需要 xz，base 里没有，先补
    os_dep_install base || oc_die "基础依赖安装失败，无法继续"
    ocp_ssrust_ensure_xz || oc_die "缺少 xz，无法解开 .tar.xz；请手动安装 xz 后重试"
    # 架构先判（ss 与 shadow-tls 的支持面不同，早判早报错）
    ocp_ssrust_arch >/dev/null || return 1

    # 4. 二进制：GitHub 版本取不到就用已知版本兜底并提示；下载失败但本机已有
    #    可执行的 ssserver 才允许沿用（避免悄悄用上不支持的旧版本）
    bin="$(ocp_ssrust_bin)"
    ver="${OC_SSRUST_VER:-}"
    if [[ -z "$ver" ]]; then
        ver="$(dl_latest_tag shadowsocks/shadowsocks-rust)"
    fi
    ver="${ver#v}"   # dl_latest_tag 返回原始 tag（v1.25.0），拼 URL 由本函数补 v
    if [[ -z "$ver" ]]; then
        ver="$OC_SSRUST_FALLBACK_VER"
        oc_warn "取不到最新版本号（GitHub API 限流？），回退到已知版本 v${ver}"
    fi
    if ocp_ssrust_fetch_ss "$ver"; then
        oc_ok "ssserver 已安装：$bin（v${ver}）"
    elif [[ -x "$bin" ]]; then
        oc_warn "下载失败，沿用本机已有的 ssserver（版本按状态库记录）"
        ver="$(db_get ss_rust version "$ver")"
    else
        oc_die "Shadowsocks-Rust 下载失败，且本机没有可用的 $bin"
    fi

    # 5. 端口与凭据
    method="$(ocp_ssrust_pick_method)" || return 1
    password="$(db_get ss_rust password "")"
    if ! ocp_ssrust_pw_ok "$method" "$password"; then
        password="$(ocp_ssrust_pw_gen "$method")"
    fi
    if ! ocp_ssrust_pw_ok "$method" "$password"; then
        oc_die "生成 method=${method} 需要的密码失败（openssl 不可用？）"
    fi
    timeout="$(db_get ss_rust timeout "300")"
    mode="tcp_and_udp"
    oc_ok "加密方式：${method}；密码已就绪"

    # 6. ShadowTLS（默认关）。重装时沿用上一次的选择，避免升级时把入口悄悄关掉
    stls="no"
    if [[ "$(db_get ss_rust shadowtls "no")" == "yes" ]]; then
        if [[ "${OC_YES:-0}" == "1" ]] ||
            oc_confirm "保持 ShadowTLS v3 伪装（沿用现有端口/SNI/密码）？" y; then
            stls="yes"
        fi
    elif oc_confirm "同时部署 ShadowTLS v3 伪装（额外 TCP 入口，客户端需支持）？" n; then
        stls="yes"
    fi

    if [[ "$stls" == "yes" ]]; then
        ocp_ssrust_stls_arch >/dev/null || return 1
        stls_port="$(ocp_ssrust_ask_stls_port "$port")" || return 1
        stls_sni="$(ocp_ssrust_ask_sni)" || return 1
        stls_pw="$(db_get ss_rust stls_password "")"
        if [[ ! "$stls_pw" =~ ^[^[:space:]]{8,64}$ ]]; then
            stls_pw="$(os_random_token 16)"
        fi
        [[ -n "$stls_pw" ]] || oc_die "生成 ShadowTLS 密码失败"
        stbin="$(ocp_ssrust_stls_bin)"
        if [[ -x "$stbin" ]]; then
            oc_ok "复用已安装的 shadow-tls：$stbin"
        else
            stver="${OC_SSRUST_STLS_VER:-}"
            [[ -z "$stver" ]] && stver="$(dl_latest_tag ihciah/shadow-tls)"
            stver="${stver#v}"   # 同上：统一去掉 tag 的 v 前缀
            if [[ -z "$stver" ]]; then
                stver="$OC_SSRUST_STLS_FALLBACK_VER"
                oc_warn "取不到 ShadowTLS 最新版本号，回退到已知版本 v${stver}"
            fi
            ocp_ssrust_fetch_stls "$stver" ||
                oc_die "ShadowTLS 下载失败；可先重装并选择不启用 ShadowTLS，或手动放到 $stbin"
            oc_ok "shadow-tls 已安装：$stbin（v${stver}）"
        fi
    fi

    # 7. 写配置（600）。先记下旧配置端口，成功后撤旧端口规则
    dir="$(ocp_ssrust_dir)"
    cfg="$(ocp_ssrust_cfg)"
    stcfg="$(ocp_ssrust_stls_cfg)"
    mkdir -p "$dir" || oc_die "创建目录失败：$dir"
    old_port="$(ocp_ssrust_cfg_port "$cfg")"
    old_stls_port="$(ocp_ssrust_cfg_stls_port "$stcfg")"
    ocp_ssrust_write_config "$port" "$password" "$method" "$timeout" "$mode" ||
        oc_die "写入 SS-Rust 配置失败"
    oc_ok "配置已写入：$cfg"
    if [[ "$stls" == "yes" ]]; then
        ocp_ssrust_write_stls_config "$stls_port" "$port" "$stls_sni" "$stls_pw" ||
            oc_die "写入 ShadowTLS 配置失败"
        oc_ok "配置已写入：$stcfg"
    fi

    # 8. 服务：先后端 ssserver，再入口 shadow-tls（入口把流量转给 127.0.0.1:ss_port）。
    #    重装时先 stop：svc_start 对已运行的服务是空操作，不停就会继续跑旧配置。
    svc_create "$unit" "$bin -c $cfg" "OneClick SS-Rust (Shadowsocks-Rust)"
    svc_enable "$unit"
    svc_stop "$unit"
    svc_start "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "SS-Rust 启动失败，最近日志："
        svc_logs "$unit" 30 >&2
        oc_die "安装中止（配置保留在 $cfg，修正后可用 oneclick --regen ss_rust 重试）"
    fi
    oc_ok "服务已启动：$unit"

    if [[ "$stls" == "yes" ]]; then
        svc_create "$stl_unit" "$stbin config --config $stcfg" "OneClick SS-Rust ShadowTLS" \
            "Environment=MONOIO_FORCE_LEGACY_DRIVER=1"
        svc_enable "$stl_unit"
        svc_stop "$stl_unit"
        svc_start "$stl_unit"
        sleep 1
        if ! svc_is_active "$stl_unit"; then
            oc_err "ShadowTLS 启动失败，最近日志："
            svc_logs "$stl_unit" 30 >&2
            # 回滚入口单元，否则它会被 Restart=on-failure 反复拉起刷日志；
            # SS 本体保留，直连链接仍然可用
            svc_remove "$stl_unit"
            oc_die "ShadowTLS 已回滚（SS-Rust 本体仍在运行）；可重装并在提问时选择不启用"
        fi
        oc_ok "服务已启动：$stl_unit"
    elif [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
        # 重装时选择关掉 ShadowTLS：清掉旧单元，别让它继续占端口
        svc_remove "$stl_unit"
        oc_ok "已移除旧的 ShadowTLS 服务：$stl_unit"
    fi

    # 9. 状态库：字段一次写全，最后才 mark_installed
    db_set ss_rust port "$port"
    db_set ss_rust method "$method"
    db_set ss_rust password "$password"
    db_set ss_rust mode "$mode"
    db_set ss_rust timeout "$timeout"
    db_set ss_rust version "$ver"
    db_set ss_rust shadowtls "$stls"
    db_set ss_rust created "$(os_now)"
    if [[ "$stls" == "yes" ]]; then
        db_set ss_rust stls_port "$stls_port"
        db_set ss_rust stls_password "$stls_pw"
        db_set ss_rust stls_sni "$stls_sni"
        db_set ss_rust stls_version "3"
    else
        db_del ss_rust stls_port
        db_del ss_rust stls_password
        db_del ss_rust stls_sni
        db_del ss_rust stls_version
    fi
    db_mark_installed ss_rust
    ip="$(net_primary_ip)"
    [[ -n "$ip" ]] && db_setting ip "$ip"

    # 11. 收尾
    oc_hr
    oc_ok "SS-Rust 安装完成"
    if [[ "$stls" == "yes" ]]; then
        oc_kv "服务单元" "${unit}、${stl_unit}"
    else
        oc_kv "服务单元" "$unit"
    fi
    oc_kv "配置文件" "$cfg"
    oc_kv "加密方式" "$method"
    oc_kv "密码" "$password"
    oc_kv "监听端口" "${port}/tcp+udp"
    oc_kv "ShadowTLS" "$([[ "$stls" == "yes" ]] && printf 'v3（入口 %s/tcp，SNI %s）' "$stls_port" "$stls_sni" || printf '未启用')"
    oc_kv "服务状态" "$(proto_ss_rust_status | head -n1)"
    oc_hr
    share_print_info ss_rust || oc_warn "暂时取不到公网 IP，稍后可用 oneclick --link ss_rust 查看"
}

proto_ss_rust_uninstall() {
    local unit stl_unit dir port stls_port
    oc_require_root
    unit="$(ocp_ssrust_unit)"
    stl_unit="$(ocp_ssrust_stls_unit)"

    # 状态库没了但 unit 还在（恢复备份/手工删库）也允许卸载，否则残留服务永远清不掉
    if ! db_has ss_rust &&
        [[ "$(svc_status "$unit")" == "not-found" ]] &&
        [[ "$(svc_status "$stl_unit")" == "not-found" ]]; then
        oc_warn "SS-Rust 未安装"
        return 0
    fi
    if [[ "${OC_YES:-0}" != "1" ]]; then
        oc_confirm "确认卸载 SS-Rust（停止服务并删除配置）？" n || {
            oc_info "已取消"
            return 0
        }
    fi

    port="$(db_get ss_rust port "")"
    [[ -z "$port" ]] && port="$(ocp_ssrust_cfg_port "$(ocp_ssrust_cfg)")"
    stls_port="$(db_get ss_rust stls_port "")"
    [[ -z "$stls_port" ]] && stls_port="$(ocp_ssrust_cfg_stls_port "$(ocp_ssrust_stls_cfg)")"

    # 上游 ss-rust.sh 的已知 bug：卸载只 disable 不删 unit。两个单元都必须 svc_remove，
    # 否则下次安装的 svc_start 会对着旧 ExecStart 直接"成功"，改了配置也不生效。
    svc_remove "$stl_unit"
    svc_remove "$unit"
    oc_ok "已停止并移除服务：${unit} ${stl_unit}"
    # 默认保留二进制（可能被面板复用）；需要清理时交互里选 y，或走 --purge。
    if svc_bin_referenced "$(ocp_ssrust_bin)" || svc_bin_referenced "$(ocp_ssrust_stls_bin)"; then
        oc_warn "检测到其他 systemd 服务仍在引用 ssserver/shadow-tls，保留不删"
    elif oc_confirm "同时删除 ssserver 与 shadow-tls 二进制？" n; then
        rm -f -- "$(ocp_ssrust_bin)" && oc_ok "已删除 $(ocp_ssrust_bin)"
        rm -f -- "$(ocp_ssrust_stls_bin)" && oc_ok "已删除 $(ocp_ssrust_stls_bin)"
    fi
    dir="$(ocp_ssrust_dir)"
    if [[ -n "$dir" && "$dir" == "${OC_ROOT}/"* && -d "$dir" ]]; then
        rm -rf -- "$dir"
        oc_ok "已删除配置目录：$dir"
    fi
    db_del ss_rust
    db_unmark_installed ss_rust
    oc_ok "SS-Rust 已卸载"
}

# 升级 SS-Rust 内核。ssserver 与 shadow-tls 各自独立升级：
# ssserver 是本体，shadow-tls 只在启用伪装时存在。
# ssserver 没有配置自检命令，靠重启存活验证；备份留到确认之后。
proto_ss_rust_upgrade() {
    local bin stbin cfg stcfg unit stl_unit tar_arch tag digest tmp cur newver bak now
    local shadowtls
    oc_require_root
    [[ -n "${OC_ARCH:-}" ]] || os_detect
    if ! db_is_installed ss_rust; then
        oc_err "SS-Rust 未安装；请用 --install ss_rust"
        return 1
    fi
    bin="$(ocp_ssrust_bin)"
    stbin="$(ocp_ssrust_stls_bin)"
    cfg="$(ocp_ssrust_cfg)"
    stcfg="$(ocp_ssrust_stls_cfg)"
    unit="$(ocp_ssrust_unit)"
    local was_active=0
    svc_is_active "$unit" && was_active=1
    stl_unit="$(ocp_ssrust_stls_unit)"
    local stl_was_active=0
    shadowtls="$(db_get ss_rust shadowtls "no")"
    tar_arch="$(ocp_ssrust_arch)" || { oc_err "当前架构 ${OC_ARCH} 无 SS-Rust 构建"; return 1; }

    # ---- 1. ssserver ----
    cur="$(oc_bin_version "$bin" || true)"
    tag="$(dl_latest_tag shadowsocks/shadowsocks-rust)"
    [[ -n "$tag" ]] || { oc_err "取不到 shadowsocks-rust 最新版本号"; return 1; }
    newver="${tag#v}"
    if [[ -n "$cur" && "$cur" == "$newver" ]]; then
        oc_ok "ssserver 已是最新：$cur"
    else
        oc_info "ssserver：${cur:-未知} → ${newver}"
        local asset="shadowsocks-v${newver}.${tar_arch}.tar.xz"
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-ss-up.XXXXXX")" || return 1
        digest="$(dl_asset_digest shadowsocks/shadowsocks-rust "$tag" "$asset")"
        if [[ -n "$digest" ]]; then
            dl_verify_fetch "https://github.com/shadowsocks/shadowsocks-rust/releases/download/$tag/$asset" \
                "$tmp/ss.tar.xz" none "$asset" || { rm -rf "$tmp"; return 1; }
            dl_verify_sha "$tmp/ss.tar.xz" "$digest" || { rm -rf "$tmp"; return 1; }
        else
            dl_verify_fetch "https://github.com/shadowsocks/shadowsocks-rust/releases/download/$tag/$asset" \
                "$tmp/ss.tar.xz" plain "$asset" || { rm -rf "$tmp"; return 1; }
        fi
        ocp_ssrust_ensure_xz || { rm -rf "$tmp"; return 1; }
        if ! dl_untar "$tmp/ss.tar.xz" "$tmp/x" || [[ ! -f "$tmp/x/ssserver" ]]; then
            rm -rf "$tmp"; oc_err "压缩包内未找到 ssserver"; return 1
        fi
        bak="$(oc_upgrade_begin "$bin")" || { rm -rf "$tmp"; return 1; }
        if ! oc_upgrade_install "$tmp/x/ssserver" "$bin"; then
            rm -rf "$tmp"; oc_upgrade_rollback "$bak" "$bin"; return 1
        fi
        rm -rf "$tmp"
        if ! oc_upgrade_service_restart "$unit" "$was_active"; then
            oc_err "新版本 ssserver 启动失败，正在回滚："
            svc_logs "$unit" 20 >&2
            oc_upgrade_rollback "$bak" "$bin" && oc_upgrade_service_restart "$unit" "$was_active"
            oc_err "已回滚到 ${cur:-旧版本}"
            return 1
        fi
        oc_upgrade_commit "$bak"
        db_set ss_rust version "$newver"
        now="$(oc_bin_version "$bin" || true)"
        _oc_upgrade_report "ssserver" "$cur" "$now"
    fi

    # ---- 2. shadow-tls（仅启用时）----
    if [[ "$shadowtls" == "yes" && -x "$stbin" ]]; then
        svc_is_active "$stl_unit" && stl_was_active=1
        local stcur sttag stnew stasset sttmp stbak stnow
        stcur="$(oc_bin_version "$stbin" || true)"
        sttag="$(dl_latest_tag ihciah/shadow-tls)"
        if [[ -z "$sttag" ]]; then
            oc_warn "取不到 shadow-tls 最新版本号，跳过其升级"
        else
            stnew="${sttag#v}"
            if [[ -n "$stcur" && "$stcur" == "$stnew" ]]; then
                oc_ok "shadow-tls 已是最新：$stcur"
            else
                oc_info "shadow-tls：${stcur:-未知} → ${stnew}"
                local sarch; sarch="$(ocp_ssrust_stls_arch)" || return 1
                stasset="shadow-tls-${sarch}"
                sttmp="$(mktemp -d "${TMPDIR:-/tmp}/oneclick-stls-up.XXXXXX")" || return 1
                local stdigest; stdigest="$(dl_asset_digest ihciah/shadow-tls "$sttag" "$stasset")"
                dl_verify_fetch "https://github.com/ihciah/shadow-tls/releases/download/$sttag/$stasset" \
                    "$sttmp/shadow-tls" none "$stasset" || { rm -rf "$sttmp"; return 1; }
                if [[ -n "$stdigest" ]]; then
                    dl_verify_sha "$sttmp/shadow-tls" "$stdigest" || { rm -rf "$sttmp"; return 1; }
                fi
                stbak="$(oc_upgrade_begin "$stbin")" || { rm -rf "$sttmp"; return 1; }
                if ! oc_upgrade_install "$sttmp/shadow-tls" "$stbin"; then
                    rm -rf "$sttmp"; oc_upgrade_rollback "$stbak" "$stbin"; return 1
                fi
                rm -rf "$sttmp"
                if ! oc_upgrade_service_restart "$stl_unit" "$stl_was_active"; then
                    oc_err "新版本 shadow-tls 启动失败，正在回滚："
                    svc_logs "$stl_unit" 20 >&2
                    oc_upgrade_rollback "$stbak" "$stbin" && oc_upgrade_service_restart "$stl_unit" "$stl_was_active"
                    oc_err "已回滚到 ${stcur:-旧版本}"
                    return 1
                fi
                oc_upgrade_commit "$stbak"
                stnow="$(oc_bin_version "$stbin" || true)"
                _oc_upgrade_report "shadow-tls" "$stcur" "$stnow"
            fi
        fi
    fi

    oc_ok "SS-Rust 内核升级流程完成"
}

proto_ss_rust_status() {
    local unit port pid st
    unit="$(ocp_ssrust_unit)"
    if ! db_has ss_rust && [[ "$(svc_status "$unit")" == "not-found" ]]; then
        printf '未安装\n'
        return 0
    fi
    port="$(db_get ss_rust port '-')"
    st="$(svc_status "$unit")"
    # SPEC 要求状态行只有这三种形态（菜单用 grep 提取"运行中/已停止"），
    # 所以不在这一行附带 ShadowTLS 入口/重建提示，避免上层解析出歧义。
    if [[ "$st" == "active" ]]; then
        pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        printf '运行中 pid=%s port=%s\n' "${pid:-0}" "$port"
    else
        printf '已停止\n'
    fi
}

proto_ss_rust_link() {
    local port method password host name userinfo stls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    [[ -n "$port" && -n "$password" ]] || {
        oc_err "状态库缺少 port/password，请重新安装"
        return 1
    }
    host="$(ocp_ssrust_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_ssrust_name)"
    userinfo="$(ocp_ssrust_userinfo "$method" "$password")"
    stls="$(db_get ss_rust shadowtls "no")"
    if [[ "$stls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            # SIP002 的 plugin 参数：分号原样写，客户端自己解析 shadow-tls 参数
            printf 'ss://%s@%s:%s?plugin=shadow-tls;host=%s;password=%s#%s\n' \
                "$userinfo" "$host" "$stls_port" "$stls_sni" "$stls_pw" "$name"
            # 公网 SS 端口本身也开着（UDP 中继要靠它），再给一条直连兜底
            printf 'ss://%s@%s:%s#%s-direct\n' \
                "$userinfo" "$host" "$port" "${name// /-}"
            return 0
        fi
    fi
    printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "${name// /-}"
}

proto_ss_rust_regen() {
    local unit stl_unit bin stbin dir cfg stcfg
    local port method password timeout mode shadowtls
    local stls_port stls_pw stls_sni old_port old_stls_port
    oc_require_root
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装，无法重生成配置"
        return 1
    fi

    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    timeout="$(db_get ss_rust timeout "300")"
    mode="$(db_get ss_rust mode "tcp_and_udp")"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    stls_port="$(db_get ss_rust stls_port "")"
    stls_pw="$(db_get ss_rust stls_password "")"
    stls_sni="$(db_get ss_rust stls_sni "")"

    ocp_ssrust_port_ok "$port" || {
        oc_err "状态库里的端口不合法：${port:-空}（请重新安装）"
        return 1
    }
    [[ -n "$password" ]] || {
        oc_err "状态库里的密码为空，请重新安装或先换凭据"
        return 1
    }

    # 菜单「换凭据」对 SS-Rust 写的是 os_random_token 20 的普通串，而 SS2022 要求
    # base64 且解码后 16/32 字节。这里检测到不兼容就自动生成新密钥并写回状态库，
    # 否则 ssserver 会直接起不来（菜单那边只提示"请检查日志"）。
    if ! ocp_ssrust_pw_ok "$method" "$password"; then
        password="$(ocp_ssrust_pw_gen "$method")"
        if ! ocp_ssrust_pw_ok "$method" "$password"; then
            oc_err "method=${method} 的密码生成失败（openssl 不可用？）"
            return 1
        fi
        db_set ss_rust password "$password"
        oc_warn "原密码与 method=${method} 不兼容，已自动生成新密码：${password}（请同步更新客户端）"
    fi

    bin="$(ocp_ssrust_bin)"
    [[ -x "$bin" ]] || {
        oc_err "缺少 $bin，请重新安装"
        return 1
    }

    dir="$(ocp_ssrust_dir)"
    cfg="$(ocp_ssrust_cfg)"
    stcfg="$(ocp_ssrust_stls_cfg)"
    mkdir -p "$dir" || {
        oc_err "创建目录失败：$dir"
        return 1
    }
    old_port="$(ocp_ssrust_cfg_port "$cfg")"
    old_stls_port="$(ocp_ssrust_cfg_stls_port "$stcfg")"
    ocp_ssrust_write_config "$port" "$password" "$method" "$timeout" "$mode" || {
        oc_err "写入 SS-Rust 配置失败"
        return 1
    }

    unit="$(ocp_ssrust_unit)"
    stl_unit="$(ocp_ssrust_stls_unit)"

    if [[ "$shadowtls" == "yes" ]]; then
        stbin="$(ocp_ssrust_stls_bin)"
        [[ -x "$stbin" ]] || {
            oc_err "ShadowTLS 已启用但缺少 $stbin，请重新安装"
            return 1
        }
        ocp_ssrust_port_ok "$stls_port" || {
            oc_err "状态库里的 ShadowTLS 端口不合法：${stls_port:-空}"
            return 1
        }
        [[ -n "$stls_pw" && -n "$stls_sni" ]] || {
            oc_err "状态库缺少 ShadowTLS 密码/SNI，请重新安装"
            return 1
        }
        ocp_ssrust_write_stls_config "$stls_port" "$port" "$stls_sni" "$stls_pw" || {
            oc_err "写入 ShadowTLS 配置失败"
            return 1
        }
    fi

    # 单元文件可能被删（恢复备份/手工清理）：regen 顺手重建，
    # 这样菜单里的"改端口/换凭据"在任何情况下都能生效。
    svc_create "$unit" "$bin -c $cfg" "OneClick SS-Rust (Shadowsocks-Rust)"
    svc_enable "$unit"
    svc_restart "$unit"
    sleep 1
    if ! svc_is_active "$unit"; then
        oc_err "重启后 SS-Rust 未运行，最近日志："
        svc_logs "$unit" 30 >&2
        return 1
    fi

    if [[ "$shadowtls" == "yes" ]]; then
        svc_create "$stl_unit" "$stbin config --config $stcfg" "OneClick SS-Rust ShadowTLS" \
            "Environment=MONOIO_FORCE_LEGACY_DRIVER=1"
        svc_enable "$stl_unit"
        svc_restart "$stl_unit"
        sleep 1
        if ! svc_is_active "$stl_unit"; then
            oc_err "重启后 ShadowTLS 未运行，最近日志："
            svc_logs "$stl_unit" 30 >&2
            return 1
        fi
    elif [[ "$(svc_status "$stl_unit")" != "not-found" ]]; then
        # 状态库里已关掉 ShadowTLS，但旧单元还在：清掉，别让它继续占端口
        svc_remove "$stl_unit"
        oc_ok "已移除旧的 ShadowTLS 服务：$stl_unit"
    fi

    oc_ok "配置已重生成并重启：$cfg"
    proto_ss_rust_status | head -n1
    return 0
}

proto_ss_rust_clash() {
    local port method password host name shadowtls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(ocp_ssrust_ip)"
    [[ -n "$host" ]] || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            printf '  - name: "%s"\n' "$name"
            printf '    type: ss\n'
            printf '    server: "%s"\n' "$host"
            printf '    port: %s\n' "$stls_port"
            printf '    cipher: %s\n' "$method"
            printf '    password: "%s"\n' "$password"
            printf '    udp: true\n'
            printf '    plugin: shadow-tls\n'
            printf '    plugin-opts:\n'
            printf '      host: %s\n' "$stls_sni"
            printf '      password: "%s"\n' "$stls_pw"
            printf '      version: 3\n'
            return 0
        fi
    fi
    printf '  - name: "%s"\n' "$name"
    printf '    type: ss\n'
    printf '    server: "%s"\n' "$host"
    printf '    port: %s\n' "$port"
    printf '    cipher: %s\n' "$method"
    printf '    password: "%s"\n' "$password"
    printf '    udp: true\n'
}

proto_ss_rust_surge() {
    local port method password host name shadowtls stls_port stls_pw stls_sni
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(ocp_ssrust_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            # Surge 侧顺序沿用上游 ss-rust.sh：入口端口 + shadow-tls-* 参数 + udp-port 指回 SS
            printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, tfo=false, udp-relay=true, ecn=true, shadow-tls-password=%s, shadow-tls-sni=%s, shadow-tls-version=3, udp-port=%s\n' \
                "$name" "$host" "$stls_port" "$method" "$password" \
                "$stls_pw" "$stls_sni" "$port"
            return 0
        fi
    fi
    printf '%s = ss, %s, %s, encrypt-method=%s, password=%s, tfo=false, udp-relay=true, ecn=true\n' \
        "$name" "$host" "$port" "$method" "$password"
}

proto_ss_rust_singbox() {
    local port method password host name shadowtls
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(ocp_ssrust_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    name="$(ocp_ssrust_name)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        # sing-box 的 ShadowTLS 要 shadowtls + shadowsocks 两段 outbound（detour 串联），
        # 单个片段表达不了。这里给出直连 SS 出站（SS 端口本身 tcp+udp 都开放），
        # 并把需要手写的两段提示到 stderr——不影响片段本身是合法 JSON。
        oc_warn "sing-box 的 ShadowTLS 需 shadowtls + shadowsocks 两段 outbound（detour 串联），单片段无法表达；本片段为直连 SS 出站，要伪装请用 Clash/Surge 或手写两段"
    fi
    jq -c -n \
        --argjson port "$port" \
        --arg server "$host" \
        --arg method "$method" \
        --arg password "$password" \
        --arg tag "$name" \
        '{
            type: "shadowsocks",
            tag: $tag,
            server: $server,
            server_port: $port,
            method: $method,
            password: $password
        }'
}

# Loon 片段：SS 行是 `名称=shadowsocks,主机,端口,加密方式,"密码"`；开 ShadowTLS 时
# 连 ShadowTLS 入口端口，UDP 用 udp-port 指回 SS 自己的端口（Sub-Store 的 loon producer 同款写法）。
proto_ss_rust_loon() {
    local port method password host name shadowtls stls_port stls_pw stls_sni line
    if ! db_has ss_rust; then
        oc_err "SS-Rust 未安装"
        return 1
    fi
    port="$(db_get ss_rust port "")"
    method="$(db_get ss_rust method "$OC_SSRUST_METHOD")"
    password="$(db_get ss_rust password "")"
    host="$(ocp_ssrust_host)" || {
        oc_err "取不到公网 IP，请检查网络或手动设置 settings.ip"
        return 1
    }
    [[ -n "$port" && -n "$password" ]] || return 1
    name="$(oc_loon_name ss_rust)"
    shadowtls="$(db_get ss_rust shadowtls "no")"
    if [[ "$shadowtls" == "yes" ]]; then
        stls_port="$(db_get ss_rust stls_port "")"
        stls_pw="$(db_get ss_rust stls_password "")"
        stls_sni="$(db_get ss_rust stls_sni "")"
        if [[ -n "$stls_port" && -n "$stls_pw" && -n "$stls_sni" ]]; then
            printf '%s = Shadowsocks,%s,%s,%s,"%s",shadow-tls-password=\"%s\",shadow-tls-sni=%s,shadow-tls-version=3,udp-port=%s,udp=true\n' \
                "$name" "$host" "$stls_port" "$method" "$password" "$stls_pw" "$stls_sni" "$port"
            return 0
        fi
    fi
    printf '%s = Shadowsocks,%s,%s,%s,"%s",udp=true\n' \
        "$name" "$host" "$port" "$method" "$password"
}
