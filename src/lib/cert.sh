# lib/cert.sh —— 证书：复用已有 / ACME(HTTP-01) / 自签（EC P-256）
#
# 约定（SPEC §8）：证书固定放 /etc/oneclick/certs/<name>/cert.pem + key.pem，
# 目录 700、私钥 600。证书缺失时绝不静默生成——必须显式走 cert_ensure。
# 三种来源都先写临时文件再原子替换，任何一步失败都不留半成品。

# ===========================================================================
# 内部工具
# ===========================================================================

# acme.sh 的安装位置随安装方式而变，按"用户目录 -> root -> PATH"查找
_cert_acme_bin() {
    local c
    for c in "$HOME/.acme.sh/acme.sh" /root/.acme.sh/acme.sh /usr/local/bin/acme.sh; do
        if [[ -x "$c" ]]; then
            printf '%s' "$c"
            return 0
        fi
    done
    c="$(command -v acme.sh 2>/dev/null || true)"
    [[ -n "$c" ]] || return 1
    printf '%s' "$c"
}

# 目录名只保留安全字符；通配符 *.example.com 归档到 example.com
_cert_dir_name() {
    local n="$1"
    n="${n#\*.}"
    n="${n//[^A-Za-z0-9._-]/_}"
    n="${n#.}"
    [[ -n "$n" ]] || n="default"
    printf '%s' "$n"
}

_cert_valid_domain() {
    local d="${1:-}"
    [[ -n "$d" && ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

_cert_mkdir_secure() {
    mkdir -p "$1" 2>/dev/null || return 1
    chmod 700 "$1" 2>/dev/null || true
    return 0
}

# 证书与私钥必须成对：都能解析，且公钥一致
_cert_pair_ok() {
    local crt="$1" key="$2" a b
    [[ -s "$crt" && -s "$key" ]] || return 1
    openssl x509 -in "$crt" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
    a="$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)" || return 1
    b="$(openssl pkey -in "$key" -pubout 2>/dev/null)" || return 1
    [[ -n "$a" && "$a" == "$b" ]]
}

# SAN 里的全部 DNS 名（优先 -ext，老版本退回 -text 解析）
_cert_sans() {
    local crt="$1" out
    out="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        out="$(openssl x509 -in "$crt" -noout -text 2>/dev/null || true)"
    fi
    printf '%s\n' "$out" | tr ',' '\n' \
        | sed -n 's/.*[Dd][Nn][Ss]:[[:space:]]*//p' \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$' || true
}

_cert_cn() {
    local crt="$1"
    openssl x509 -in "$crt" -noout -subject 2>/dev/null \
        | sed -n 's/.*[Cc][Nn][[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' \
        | head -n1 | sed 's/[[:space:]]*$//'
}

# 证书是否覆盖该域名（精确匹配或单级通配）
_cert_covers() {
    local crt="$1" d="$2" n suffix label
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ "$n" == "$d" ]]; then
            return 0
        fi
        if [[ "$n" == '*.'* ]]; then
            suffix="${n#\*}"
            label="${d%"$suffix"}"
            if [[ "$d" == *"$suffix" && "$d" != "$suffix" && -n "$label" && "$label" != *.* ]]; then
                return 0
            fi
        fi
    done < <(_cert_sans "$crt"; _cert_cn "$crt")
    return 1
}

# 老版本 openssl 没有 -addext，走临时配置文件补 SAN
_cert_sign_self() {
    local sni="$1" key="$2" crt="$3" cfg rc=0
    if openssl req -new -x509 -key "$key" -out "$crt" -days 36500 -sha256 \
            -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1; then
        return 0
    fi
    cfg="$(mktemp)" || return 1
    cat > "$cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = $sni

[v3]
subjectAltName = DNS:$sni
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
EOF
    openssl req -new -x509 -key "$key" -out "$crt" -days 36500 -sha256 -config "$cfg" >/dev/null 2>&1 || rc=1
    rm -f "$cfg"
    return "$rc"
}

_cert_write_json() {
    local outfile="$1" priv="$2" pub="$3" tmp
    tmp="${outfile}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg a "$priv" --arg b "$pub" '{privateKey: $a, publicKey: $b}' > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 1; }
    else
        printf '{"privateKey":"%s","publicKey":"%s"}\n' "$priv" "$pub" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$outfile" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_cert_write_priv_json() {
    local outfile="$1" priv="$2" tmp
    tmp="${outfile}.tmp.$$"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg a "$priv" '{privateKey: $a}' > "$tmp" 2>/dev/null \
            || { rm -f "$tmp"; return 1; }
    else
        printf '{"privateKey":"%s"}\n' "$priv" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$outfile" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# ===========================================================================
# 证书识别
# ===========================================================================

# cert_detect <crt>：stdout 主域名（SAN 第一个，退化到 CN）
cert_detect() {
    local crt="$1" d
    [[ -f "$crt" ]] || return 1
    d="$(_cert_sans "$crt" | head -n1)"
    if [[ -z "$d" ]]; then
        d="$(_cert_cn "$crt")"
    fi
    [[ -n "$d" ]] || return 1
    printf '%s' "$d"
}

# cert_reuse <domain> <outdir>：stdout 0=可复用 1=需重签
cert_reuse() {
    local domain="$1" outdir="$2" crt key
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    if ! _cert_pair_ok "$crt" "$key"; then
        printf '1'
        return 0
    fi
    # 证书必须覆盖调用方要用的域名，否则复用会直接导致握手失败
    if [[ -n "$domain" ]] && ! _cert_covers "$crt" "$domain"; then
        printf '1'
        return 0
    fi
    if openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
        printf '0'
    else
        printf '1'
    fi
    return 0
}

# ===========================================================================
# 三种签发/复用方式
# ===========================================================================

# cert_self <sni> <outdir>：EC prime256v1 + SAN，36500 天；始终重签（SPEC）
cert_self() {
    local sni="$1" outdir="$2" crt key kt ct
    if [[ -z "$sni" || -z "$outdir" ]]; then
        oc_err "cert_self: 用法 cert_self <sni> <outdir>"
        return 1
    fi
    if ! _cert_valid_domain "$sni"; then
        oc_err "cert_self: SNI 必须是域名（收到：$sni）"
        return 1
    fi
    _cert_mkdir_secure "$outdir" || { oc_err "cert_self: 无法创建目录 $outdir"; return 1; }
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    kt="$outdir/key.pem.tmp.$$"
    ct="$outdir/cert.pem.tmp.$$"
    if ! openssl ecparam -genkey -name prime256v1 -out "$kt" 2>/dev/null; then
        oc_err "cert_self: 生成 EC P-256 私钥失败（openssl 不可用？）"
        rm -f "$kt"
        return 1
    fi
    chmod 600 "$kt" 2>/dev/null || true
    if ! _cert_sign_self "$sni" "$kt" "$ct" || ! _cert_pair_ok "$ct" "$kt"; then
        oc_err "cert_self: 自签证书生成失败（openssl 版本过旧？）"
        rm -f "$kt" "$ct"
        return 1
    fi
    chmod 644 "$ct" 2>/dev/null || true
    # 强制重签：先落私钥再落证书，最后再验一次成对；失败就都删掉，不留半成品
    if ! mv -f "$kt" "$key" 2>/dev/null; then
        oc_err "cert_self: 写入私钥失败：$key"
        rm -f "$kt" "$ct"
        return 1
    fi
    if ! mv -f "$ct" "$crt" 2>/dev/null; then
        oc_err "cert_self: 写入证书失败：$crt"
        rm -f "$key"
        return 1
    fi
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    if ! _cert_pair_ok "$crt" "$key"; then
        oc_err "cert_self: 落盘后校验失败，已清理"
        rm -f "$crt" "$key"
        return 1
    fi
    oc_ok "自签证书已生成：$crt（SNI=$sni，36500 天）"
    return 0
}

# cert_acme <domain> <outdir>：acme.sh + HTTP-01（--standalone --httpport 80）
cert_acme() {
    local domain="$1" outdir="$2" acme crt key email issued=1 plog
    if [[ -z "$domain" || -z "$outdir" ]]; then
        oc_err "cert_acme: 用法 cert_acme <domain> <outdir>"
        return 1
    fi
    if ! _cert_valid_domain "$domain"; then
        oc_err "cert_acme: ACME 需要真实域名（收到：$domain）"
        return 1
    fi
    _cert_mkdir_secure "$outdir" || { oc_err "cert_acme: 无法创建目录 $outdir"; return 1; }
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    # 剩余 >30 天直接复用（域名已校验覆盖），别浪费 Let's Encrypt 的签发限额
    if [[ "$(cert_reuse "$domain" "$outdir")" == "0" ]]; then
        oc_ok "已有可用证书（域名匹配且剩余 >30 天），直接复用：$crt"
        return 0
    fi
    if ! acme="$(_cert_acme_bin)"; then
        if ! command -v curl >/dev/null 2>&1; then
            oc_err "cert_acme: 缺少 curl，无法安装 acme.sh"
            return 1
        fi
        oc_info "安装 acme.sh（socat + cron 用于 HTTP-01 与自动续期）..."
        # Debian 包名 cron，RHEL 是 cronie；哪个能装就用哪个
        os_pkg_install socat cron >/dev/null 2>&1 \
            || os_pkg_install socat cronie >/dev/null 2>&1 \
            || oc_warn "socat/cron 安装失败，ACME 可能不可用"
        email="admin@$domain"
        # 安装脚本本身要从 GitHub 拉 master.tar.gz，偶发失败很常见：重试一次并保留日志
        plog="$(mktemp)" || plog="/tmp/oneclick-acme-install.$$.log"
        local try rc=1
        for try in 1 2; do
            if curl -fsSL --connect-timeout 10 --max-time 120 https://get.acme.sh 2>/dev/null \
                    | sh -s "email=$email" >"$plog" 2>&1; then
                rc=0
                break
            fi
            oc_warn "acme.sh 安装失败（第 ${try} 次），10 秒后重试"
            ((try < 2)) && sleep 10
        done
        if ((rc != 0)); then
            oc_err "cert_acme: acme.sh 安装失败（get.acme.sh 或 GitHub 下载不可达），最后几行日志："
            tail -5 "$plog" >&2
            rm -f -- "$plog"
            return 1
        fi
        rm -f -- "$plog"
        acme="$(_cert_acme_bin)" || { oc_err "cert_acme: 安装后仍未找到 acme.sh"; return 1; }
        # 记账：卸载时据此清掉续期任务与 ~/.acme.sh，避免残留
        db_setting acme_installed 1 >/dev/null 2>&1 || true
    fi
    # 默认 CA 是 ZeroSSL，需要 EAB；脚本化一律用 Let's Encrypt
    "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    if net_port_in_use 80 tcp; then
        oc_warn "80 端口已被占用，HTTP-01 校验很可能失败"
    fi
    oc_info "申请证书：$domain（HTTP-01，需 80 端口可被公网访问）..."
    if "$acme" --issue -d "$domain" --standalone --httpport 80 -k ec-256 >/dev/null 2>&1; then
        issued=0
    else
        # acme.sh 对"域名未变化"会跳过 issue（返回非 0），此时仓库里可能已有证书，
        # 继续尝试 install-cert，避免把可复用的证书误判为失败。
        oc_warn "acme.sh issue 未返回成功，尝试直接安装仓库中已有证书"
    fi
    if ! "$acme" --install-cert -d "$domain" --ecc \
            --key-file "$key" \
            --fullchain-file "$crt" >/dev/null 2>&1; then
        if ((issued != 0)); then
            oc_err "ACME 申请失败：HTTP-01 校验未通过"
            oc_info "常见原因：80 端口被占用 / 云安全组未放行 80 / 域名未解析到本机"
            oc_info "P0 未内置 DNS API：可手动切 DNS-01 签发，或用 --cert-mode self 自签"
        else
            oc_err "cert_acme: 证书安装到 $outdir 失败"
        fi
        return 1
    fi
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$crt" 2>/dev/null || true
    if ! _cert_pair_ok "$crt" "$key"; then
        oc_err "cert_acme: 安装后证书/私钥校验失败"
        return 1
    fi
    oc_ok "ACME 证书已就绪：$crt（续期由 acme.sh cron 负责）"
    return 0
}

# ===========================================================================
# cert_ensure：三种模式的统一入口（设置全局 CERT_PATH/KEY_PATH/SNI）
# ===========================================================================

_cert_ensure_existing() {
    local hint="$1" dir="$2" crt key d
    crt="$dir/cert.pem"
    key="$dir/key.pem"
    if [[ ! -f "$crt" || ! -f "$key" ]]; then
        oc_err "cert_ensure: 未找到已有证书 $crt"
        oc_info "请把 cert.pem + key.pem 放进 $dir，或改用 acme/self 模式"
        return 1
    fi
    if ! _cert_pair_ok "$crt" "$key"; then
        oc_err "cert_ensure: 已有证书与私钥不匹配或已损坏：$dir"
        return 1
    fi
    d="$(cert_detect "$crt" 2>/dev/null || true)"
    CERT_PATH="$crt"
    KEY_PATH="$key"
    SNI="${d:-$hint}"
    # 复用是用户明确选择，临期只提醒不阻断
    if ! openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
        oc_warn "复用的证书将在 30 天内到期，请提前更新：$crt"
    fi
    return 0
}

_cert_ensure_self() {
    local hint="$1" dir="$2" sni
    sni="$hint"
    if ! _cert_valid_domain "$sni"; then
        if [[ "${OC_YES:-0}" == "1" ]]; then
            oc_warn "SNI 不是合法域名（${sni}），自签改用默认伪装域名 www.bing.com"
            sni="www.bing.com"
        else
            sni="$(oc_ask "自签证书的伪装 SNI（域名）" "www.bing.com")"
        fi
    fi
    if ! _cert_valid_domain "$sni"; then
        oc_err "cert_ensure: 自签 SNI 非法（${sni}）"
        return 1
    fi
    cert_self "$sni" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$sni"
    return 0
}

_cert_ensure_acme() {
    local domain="$1" dir="$2"
    if ! _cert_valid_domain "$domain"; then
        oc_err "cert_ensure: ACME 模式需要真实域名（收到：$domain）"
        return 1
    fi
    cert_acme "$domain" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$domain"
    return 0
}

# cert_ensure <sni-hint> [mode]；mode=existing|acme|self，省略则交互
cert_ensure() {
    local hint="${1:-}" mode="${2:-}" name dir
    CERT_PATH=""
    KEY_PATH=""
    SNI=""
    if [[ -z "$hint" ]]; then
        hint="${OC_ARG_SNI:-${OC_ARG_DOMAIN:-}}"
    fi
    if [[ -z "$mode" ]]; then
        mode="${OC_ARG_CERT_MODE:-}"
    fi
    if [[ -z "$hint" ]]; then
        hint="$(oc_ask "证书域名 / SNI（同时用于证书目录名）" "www.bing.com")"
    fi
    if [[ -z "$hint" ]]; then
        oc_err "cert_ensure: 必须提供域名或 SNI"
        return 1
    fi
    case "$mode" in
        '') ;;
        existing|acme|self) ;;
        *) oc_err "cert_ensure: mode 只能是 existing|acme|self（收到：$mode）"; return 1 ;;
    esac
    name="$(_cert_dir_name "$hint")"
    dir="$OC_CERT_DIR/$name"
    if [[ -z "$mode" ]]; then
        # OC_YES 时 oc_ask 返回默认值：已有证书默认复用，否则默认自签（免 ACME 依赖）
        local def="self"
        if [[ -f "$dir/cert.pem" && -f "$dir/key.pem" ]]; then
            def="existing"
        fi
        mode="$(oc_ask "证书方案 existing=复用已有 / acme=ACME 申请 / self=自签" "$def")"
        case "$mode" in
            existing|acme|self) ;;
            *) oc_err "cert_ensure: 无效的证书方案（${mode}）"; return 1 ;;
        esac
    fi
    case "$mode" in
        existing) _cert_ensure_existing "$hint" "$dir" || return 1 ;;
        acme)     _cert_ensure_acme "$hint" "$dir" || return 1 ;;
        self)     _cert_ensure_self "$hint" "$dir" || return 1 ;;
    esac
    # 最终统一校验：半成品一律拒绝，并清空全局变量避免调用方误用
    if ! _cert_pair_ok "$CERT_PATH" "$KEY_PATH"; then
        oc_err "cert_ensure: 证书/私钥校验失败：$CERT_PATH"
        CERT_PATH=""
        KEY_PATH=""
        SNI=""
        return 1
    fi
    chmod 600 "$KEY_PATH" 2>/dev/null || true
    chmod 644 "$CERT_PATH" 2>/dev/null || true
    oc_ok "证书就绪：SNI=${SNI}（$CERT_PATH）"
    return 0
}

# ===========================================================================
# 状态 / REALITY 密钥 / 指纹
# ===========================================================================

# cert_status：打印各证书剩余天数
cert_status() {
    local base="${OC_CERT_DIR:-/etc/oneclick/certs}" d crt name end epoch now days n=0
    if [[ ! -d "$base" ]]; then
        oc_info "暂无证书目录（$base）"
        return 0
    fi
    oc_title "证书状态"
    for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        crt="$d/cert.pem"
        [[ -f "$crt" ]] || continue
        name="$(basename "$d")"
        n=$((n + 1))
        end="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
        if [[ -z "$end" ]]; then
            oc_kv "$name" "无法解析证书"
            continue
        fi
        epoch="$(date -d "$end" +%s 2>/dev/null || true)"
        if [[ -n "$epoch" ]]; then
            now="$(date +%s)"
            days=$(( (epoch - now) / 86400 ))
            if ((days < 0)); then
                oc_kv "$name" "已过期（$end）"
            else
                oc_kv "$name" "剩余 ${days} 天（$end）"
            fi
        elif openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
            # 没有 GNU date 的环境退化成区间提示
            if openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
                oc_kv "$name" "有效（>30 天，至 $end）"
            else
                oc_kv "$name" "有效（<30 天，至 $end）"
            fi
        else
            oc_kv "$name" "已过期（$end）"
        fi
    done
    if ((n == 0)); then
        oc_info "暂无证书"
    fi
    return 0
}

# reality_keypair <outfile>：写 {"privateKey":"...","publicKey":"..."}，600
# 返回 0=成功；2=只有私钥（缺 xray，公钥无法用 openssl 导出）；1=失败
reality_keypair() {
    local outfile="$1" xray out priv pub tmpdir privraw
    if [[ -z "$outfile" ]]; then
        oc_err "reality_keypair: 用法 reality_keypair <outfile>"
        return 1
    fi
    xray=""
    if [[ -x /usr/local/bin/xray ]]; then
        xray="/usr/local/bin/xray"
    elif command -v xray >/dev/null 2>&1; then
        xray="$(command -v xray)"
    fi
    if [[ -n "$xray" ]]; then
        out="$("$xray" x25519 2>/dev/null || true)"
        priv="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]rivate[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
        pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
        if [[ -z "$pub" ]]; then
            # 新版 xray 把 public key 标成 Password
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[[:space:]]*:[[:space:]]*//p' | head -n1)"
        fi
        if [[ -n "$priv" && -z "$pub" ]]; then
            out="$("$xray" x25519 -i "$priv" 2>/dev/null || true)"
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
            if [[ -z "$pub" ]]; then
                pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[[:space:]]*:[[:space:]]*//p' | head -n1)"
            fi
        fi
        if [[ -n "$priv" && -n "$pub" ]]; then
            _cert_write_json "$outfile" "$priv" "$pub" || { oc_err "reality_keypair: 写入 $outfile 失败"; return 1; }
            oc_ok "REALITY 密钥对已写入：$outfile"
            return 0
        fi
        oc_warn "xray x25519 输出无法解析，改用 openssl 生成私钥"
    fi
    command -v openssl >/dev/null 2>&1 || { oc_err "reality_keypair: 缺少 openssl 且未安装 xray"; return 1; }
    tmpdir="$(mktemp -d 2>/dev/null)" || return 1
    if ! openssl genpkey -algorithm X25519 -out "$tmpdir/k.pem" 2>/dev/null; then
        rm -rf "$tmpdir"
        oc_err "reality_keypair: openssl 无法生成 X25519 私钥（版本过旧？）"
        return 1
    fi
    # X25519 私钥在 PKCS#8 DER 里就是最后 32 字节；xray 用的是 base64url 无填充
    privraw="$(openssl pkey -in "$tmpdir/k.pem" -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null | tr -d '\n=' | tr '+/' '-_')"
    rm -rf "$tmpdir"
    if [[ -z "$privraw" ]]; then
        oc_err "reality_keypair: 私钥编码失败"
        return 1
    fi
    _cert_write_priv_json "$outfile" "$privraw" || { oc_err "reality_keypair: 写入 $outfile 失败"; return 1; }
    oc_warn "当前没有 xray，仅生成了私钥；安装 xray 后可用 xray x25519 -i <私钥> 导出公钥"
    return 2
}

# cert_fingerprint <crt>：stdout SHA256 pin（小写、冒号分隔）
cert_fingerprint() {
    local crt="$1" fp
    if [[ -z "$crt" || ! -f "$crt" ]]; then
        oc_err "cert_fingerprint: 证书不存在：${crt:-<空>}"
        return 1
    fi
    fp="$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
    if [[ -z "$fp" ]] || [[ "$fp" == "SHA256"* ]]; then
        oc_err "cert_fingerprint: 无法计算 SHA256 指纹（openssl 过旧？）"
        return 1
    fi
    fp="$(printf '%s' "$fp" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
    printf '%s\n' "$fp"
    return 0
}
