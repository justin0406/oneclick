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
    # 先把 SAN/CN 全读进变量再判断。原先在 while 里直接 return，
    # 会让上游 _cert_sans 的 sed 管道提前收到 SIGPIPE，在某些环境下
    # 往 stderr 写 "couldn't flush stdout"，污染调用方的 $() 捕获。
    local names
    names="$(_cert_sans "$crt"; _cert_cn "$crt")"
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
    done <<< "$names"
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

# 证书是否为自签（issuer == subject，且自签名验证通过）。
# 用于防止 ACME 模式误复用之前生成的自签证书——自签证书有效期可以很长、
# 域名也匹配，光看"配对+域名+有效期"会把它当成正式证书。
_cert_is_selfsigned() {
    local crt="$1" subj iss
    [[ -s "$crt" ]] || return 1
    subj="$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
    iss="$(openssl x509 -in "$crt" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
    [[ -n "$subj" && "$subj" == "$iss" ]]
}

# cert_reuse <domain> <outdir> [require_ca]：stdout 0=可复用 1=需重签
# 第二个参数 require_ca=1 时，自签证书不算可复用（ACME 模式必须用这个）。
cert_reuse() {
    local domain="$1" outdir="$2" require_ca="${3:-0}" crt key
    crt="$outdir/cert.pem"
    key="$outdir/key.pem"
    if ! _cert_pair_ok "$crt" "$key"; then
        printf '1'
        return 0
    fi
    if [[ "$require_ca" == "1" ]] && _cert_is_selfsigned "$crt"; then
        # 自签证书不能冒充 ACME 签发的证书
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

# HTTP-01 前置检查：域名必须解析到本机，且 80 端口没被别的进程占着。
# 返回 0 表示可以继续申请；返回 1 并说明原因。
_cert_acme_precheck() {
    local domain="$1" myip resolved
    # 1. 域名解析
    if command -v dig >/dev/null 2>&1; then
        resolved="$(dig +short "$domain" A 2>/dev/null | tail -n1)"
    elif command -v getent >/dev/null 2>&1; then
        resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')"
    fi
    myip="$(net_primary_ip)"
    if [[ -n "$resolved" && -n "$myip" && "$resolved" != "$myip" ]]; then
        oc_err "域名解析与本机公网 IP 不一致，HTTP-01 必然失败："
        oc_kv "  $domain 解析到" "$resolved"
        oc_kv "  本机公网 IP" "$myip"
        oc_info "请把 $domain 的 A 记录指向 $myip 后重试"
        return 1
    fi
    # 2. 80 端口占用（standalone 需要独占）
    if net_port_in_use 80 tcp; then
        oc_err "80 端口已被占用，acme.sh 的 standalone 模式需要独占 80："
        ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ {print "    " $0}' >&2 || true
        oc_info "先停掉占用 80 的服务，或改用 --cert-mode self"
        return 1
    fi
    return 0
}

# 登记"某个服务使用某域名证书"，供 acme.sh 续期时统一重载。
# 存储在 db.settings.cert_users.<domain> 里，逗号分隔的 systemd unit 名。
cert_register_user() {
    local domain="$1" unit="$2"
    local cur new
    cur="$(db_get settings "cert_users_${domain}" "")"
    case ",$cur," in
        *",$unit,"*) return 0 ;;   # 已登记
    esac
    if [[ -z "$cur" ]]; then
        new="$unit"
    else
        new="$cur,$unit"
    fi
    db_set settings "cert_users_${domain}" "$new"
}

# 注销某个服务在所有域名下的证书使用登记。
# 重装/卸载时调用，否则服务换了域名或卸载后，旧域名下仍留着它的记录，
# reloadcmd 会去重启一个已经不存在（或已换证书）的 unit。
cert_unregister_user() {
    local unit="$1" name cur new
    [[ -n "$unit" ]] || return 0
    # 遍历 db 里的登记键，而不是证书目录：证书目录可能已被删除
    # （例如换域名后旧目录清掉），但登记记录还在，必须一并清理。
    local -a keys=()
    if [[ -f "$OC_DB" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && keys+=("$name")
        done < <(jq -r '.settings // {} | keys[] | select(startswith("cert_users_"))' "$OC_DB" 2>/dev/null)
    fi
    for name in "${keys[@]}"; do
        name="${name#cert_users_}"
        cur="$(db_get settings "cert_users_${name}" "")"
        [[ -n "$cur" ]] || continue
        case ",$cur," in
            *",$unit,"*) ;;
            *) continue ;;
        esac
        # 从列表里摘掉这个 unit
        new=""
        local u
        for u in ${cur//,/ }; do
            [[ "$u" == "$unit" ]] && continue
            new+="${new:+,}$u"
        done
        if [[ -z "$new" ]]; then
            db_del settings "cert_users_${name}" >/dev/null 2>&1 || true
        else
            db_set settings "cert_users_${name}" "$new" >/dev/null 2>&1 || true
        fi
    done
}

# 生成 acme.sh 的 reloadcmd：重启所有登记在案的 unit。# 生成 acme.sh 的 reloadcmd：重启所有登记在案的 unit。
# 用 restart 而非 reload：这些内核多数没有真正的 reload 语义，
# restart 是唯一能确保读到新证书的方式。
cert_reload_cmd() {
    local domain="$1" users u cmd=""
    users="$(db_get settings "cert_users_${domain}" "")"
    if [[ -z "$users" ]]; then
        # 没有登记使用者时给一个无害命令，避免 acme.sh 报参数为空
        printf 'true'
        return 0
    fi
    for u in ${users//,/ }; do
        [[ -n "$u" ]] || continue
        cmd+="systemctl restart $u 2>/dev/null || true; "
    done
    printf '%s' "${cmd%; }"
}

# cert_acme <domain> <outdir>：acme.sh + HTTP-01（--standalone --httpport 80）# cert_acme <domain> <outdir>：acme.sh + HTTP-01（--standalone --httpport 80）
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
    # require_ca=1：自签证书不算可复用，否则用户以为拿到 Let's Encrypt
    # 实际还是之前那张自签证书。
    if [[ "$(cert_reuse "$domain" "$outdir" 1)" == "0" ]]; then
        oc_ok "已有 CA 签发的可用证书（域名匹配且剩余 >30 天），直接复用：$crt"
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
    # 申请前先做前置检查：域名是否解析到本机、80 端口是否可用。
    # 这两条是 HTTP-01 失败的绝大多数原因，提前查能给出确定结论，
    # 而不是等 acme.sh 跑完再猜。
    _cert_acme_precheck "$domain" || return 1

    # 保留 acme.sh 的真实输出：失败时它是唯一能说明原因的线索，
    # 之前直接丢进 /dev/null，用户只看到一句笼统提示。
    local acme_log; acme_log="$(mktemp)" || acme_log="/tmp/oneclick-acme.$$.log"
    if "$acme" --issue -d "$domain" --standalone --httpport 80 -k ec-256 >"$acme_log" 2>&1; then
        issued=0
    else
        # acme.sh 对"域名未变化"会跳过 issue（返回非 0），此时仓库里可能已有证书，
        # 继续尝试 install-cert，避免把可复用的证书误判为失败。
        oc_warn "acme.sh issue 未成功，尝试安装仓库中已有证书"
    fi
    # reloadcmd：续期后重启所有使用这张证书的服务。
    # 这是 acme.sh 官方推荐的续期落地方式——没有它，证书虽续期成功，
    # 服务仍在用旧证书，到期就断（官方 README 明确警告这一点）。
    local reloadcmd
    reloadcmd="$(cert_reload_cmd "$domain")"
    if ! "$acme" --install-cert -d "$domain" --ecc \
            --key-file "$key" \
            --fullchain-file "$crt" \
            --reloadcmd "$reloadcmd" >/dev/null 2>&1; then
        if ((issued != 0)); then
            oc_err "ACME 申请失败。acme.sh 输出（末尾 15 行）："
            tail -n 15 "$acme_log" 2>/dev/null | sed 's/^/    /' >&2
            printf '\n' >&2
            oc_info "常见原因：80 端口被云安全组挡住 / 域名未解析到本机 / 域名不属于你"
            oc_info "确认解析：dig +short $domain（应等于本机公网 IP）"
            oc_info "或改用自签：--cert-mode self"
        else
            oc_err "cert_acme: 证书安装到 $outdir 失败"
            tail -n 5 "$acme_log" 2>/dev/null | sed 's/^/    /' >&2
        fi
        rm -f -- "$acme_log"
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
            sni="$(oc_ask "自签证书的伪装 SNI（随便一个知名域名即可）" "www.bing.com")"
        fi
    fi
    if ! _cert_valid_domain "$sni"; then
        oc_err "cert_ensure: 自签 SNI 非法（${sni}）"
        return 1
    fi
    # 目录以 hint 为准（共用逻辑按 hint 归档）；hint 为空时才按最终 SNI 落盘。
    [[ -z "$hint" ]] && dir="$OC_CERT_DIR/$(_cert_dir_name "$sni")"
    cert_self "$sni" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$sni"
    return 0
}

_cert_ensure_acme() {
    local domain="$1" dir="$2"
    # ACME 的域名必须是调用方真正拥有、且已解析到本机的域名。
    # 调用方传进来的 hint 往往是占位值（bing.com 之类），拿它去申请
    # HTTP-01 必然失败——那是别人的域名，80 端口校验不可能通过。
    # 所以这里要求显式提供域名，不接受占位默认值。
    if [[ -z "$domain" ]]; then
        if [[ "$OC_YES" == "1" ]]; then
            oc_err "ACME 模式需要 --domain 指定你的域名（非交互模式下没有默认值）"
            return 1
        fi
        oc_warn "ACME 需要你自己拥有、且已解析到本机的域名（不能填 bing.com 这类公共域名）"
        domain="$(oc_ask "你的域名（必须已解析到本机，且 80 端口可从公网访问）" "")"
    fi
    if [[ -z "$domain" ]]; then
        oc_err "ACME 模式必须提供域名"
        return 1
    fi
    if ! _cert_valid_domain "$domain"; then
        oc_err "域名格式不合法：$domain"
        return 1
    fi
    cert_acme "$domain" "$dir" || return 1
    CERT_PATH="$dir/cert.pem"
    KEY_PATH="$dir/key.pem"
    SNI="$domain"
    return 0
}

# 列出已有可用证书，让用户选一个复用。无可用证书时输出空。
# 输出的是证书的域名（即目录名），供 cert_ensure 当作 hint。
_cert_pick_existing() {
    local base="$OC_CERT_DIR" d crt key name
    local -a names=()
    [[ -d "$base" ]] || return 0
    for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        crt="$d/cert.pem"; key="$d/key.pem"
        [[ -f "$crt" && -f "$key" ]] || continue
        _cert_pair_ok "$crt" "$key" || continue
        openssl x509 -in "$crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1 || continue
        names+=("$(basename "$d")")
    done
    if [[ ${#names[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "$OC_YES" == "1" ]]; then
        printf '%s' "${names[0]}"
        return 0
    fi
    # 只有一张证书时默认用它，不再多问
    if [[ ${#names[@]} -eq 1 ]]; then
        printf '%s' "${names[0]}"
        return 0
    fi
    local -a labels=()
    for name in "${names[@]}"; do
        labels+=("$name（$(openssl x509 -in "$base/$name/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)）")
    done
    local sel
    oc_info "已有可用证书，可直接复用：" >&2
    sel="$(oc_menu "选择证书" "${labels[@]}")" || return 1
    [[ "$sel" == "0" ]] && return 0
    printf '%s' "${names[$((sel - 1))]}"
}

# 交互式选择证书方式：用编号菜单而不是让人背英文单词。# 交互式选择证书方式：用编号菜单而不是让人背英文单词。
# 默认项排在最前并在标签里标出，回车即选它。
_cert_choose_mode() {
    local def="${1:-self}"
    local -a labels=() keys=()
    local k label sel i default_idx=1
    # 固定顺序，默认项提前
    local -a order=(self acme existing)
    for k in "${order[@]}"; do
        case "$k" in
            self)     label="自签证书（无需域名，浏览器会提示不受信任）" ;;
            acme)     label="Let's Encrypt 正式证书（需自有域名解析到本机 + 80 端口放行）" ;;
            existing) label="使用已有证书（需先把 cert.pem/key.pem 放进证书目录）" ;;
        esac
        [[ "$k" == "$def" ]] && label+="  ← 默认"
        labels+=("$label")
        keys+=("$k")
    done
    for i in "${!keys[@]}"; do
        [[ "${keys[$i]}" == "$def" ]] && default_idx=$((i + 1))
    done
    printf '\n' >&2
    for i in "${!labels[@]}"; do
        printf '  %b%d%b  %s\n' "$C_C" "$((i + 1))" "$C_N" "${labels[$i]}" >&2
    done
    while true; do
        printf '%b请选择证书方式 [1-%d，回车=%d]: %b' "$C_Y" "${#keys[@]}" "$default_idx" "$C_N" >&2
        if ! read -r sel; then return 1; fi
        sel="${sel//[[:space:]]/}"
        [[ -z "$sel" ]] && sel="$default_idx"
        if [[ "$sel" =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#keys[@]})); then
            printf '%s' "${keys[$((sel - 1))]}"
            return 0
        fi
        oc_warn "输入无效，请重新选择"
    done
}

# cert_ensure <sni-hint> [mode]；mode=existing|acme|self，省略则交互
cert_ensure() {
    local hint="${1:-}" mode="${2:-}" name dir
    CERT_PATH=""
    KEY_PATH=""
    SNI=""
    CERT_MODE=""
    if [[ -z "$hint" ]]; then
        hint="${OC_ARG_SNI:-${OC_ARG_DOMAIN:-}}"
    fi
    if [[ -z "$mode" ]]; then
        mode="${OC_ARG_CERT_MODE:-}"
    fi
    case "$mode" in
        ''|existing|acme|self) ;;
        *) oc_err "cert_ensure: mode 只能是 existing|acme|self（收到：$mode）"; return 1 ;;
    esac

    # ---- 证书共用（优先于一切交互）----
    # 上游主流做法：证书按域名归档在固定目录，同一域名的第二个协议直接
    # 指向同一份文件，不重复申请（避免撞 Let's Encrypt 每周 5 次的限额）。
    # 顺序上必须先于"选证书方式"：否则第二个协议还要再选一遍方式，
    # 共用就形同虚设。
    local shared_crt="" shared_key="" shared_dir=""
    if [[ -n "$hint" ]]; then
        shared_dir="$OC_CERT_DIR/$(_cert_dir_name "$hint")"
        shared_crt="$shared_dir/cert.pem"
        shared_key="$shared_dir/key.pem"
    elif [[ -z "$mode" || "$mode" != "acme" ]]; then
        # 没指定域名时，若已有证书则列出来让用户直接选（最常见的路径：
        # 装第二个协议，想沿用第一张证书）
        local pick
        pick="$(_cert_pick_existing)" || return 1
        if [[ -n "$pick" ]]; then
            hint="$pick"
            shared_dir="$OC_CERT_DIR/$(_cert_dir_name "$hint")"
            shared_crt="$shared_dir/cert.pem"
            shared_key="$shared_dir/key.pem"
        fi
    fi
    if [[ -n "$shared_crt" && -f "$shared_crt" && -f "$shared_key" ]] &&
       _cert_pair_ok "$shared_crt" "$shared_key"; then
        # ACME 模式只认 CA 签发的证书，自签的不算复用
        if [[ "$mode" != "acme" ]] || ! _cert_is_selfsigned "$shared_crt"; then
            if _cert_covers "$shared_crt" "$hint" &&
               openssl x509 -in "$shared_crt" -noout -checkend $((30 * 86400)) >/dev/null 2>&1; then
                CERT_PATH="$shared_crt"
                KEY_PATH="$shared_key"
                SNI="$(cert_detect "$shared_crt" 2>/dev/null || printf '%s' "$hint")"
                CERT_MODE="existing"
                oc_ok "复用已有证书（$hint）：$shared_crt"
                return 0
            fi
        fi
    fi

    # 没有可复用的证书：这时才问方式
    if [[ -z "$mode" ]]; then
        local def="self"
        if [[ "$OC_YES" == "1" ]]; then
            mode="$def"
        else
            mode="$(_cert_choose_mode "$def")" || return 1
        fi
    fi
    name="$(_cert_dir_name "${hint:-pending}")"
    dir="$OC_CERT_DIR/$name"
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
    # 导出最终采用的方式：调用方交互时 mode 是在本函数内部选定的，
    # 不导出的话调用方那边的变量还是空（显示成"证书方式："）。
    CERT_MODE="$mode"
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
    # 本脚本把内核装在私有目录，这里必须优先看它；
    # 以前只看 /usr/local/bin 和 PATH，装完 xray 也会被判成"没有 xray"。
    if [[ -n "${OC_BIN_DIR:-}" && -x "$OC_BIN_DIR/xray" ]]; then
        xray="$OC_BIN_DIR/xray"
    elif [[ -x /usr/local/bin/xray ]]; then
        xray="/usr/local/bin/xray"
    elif command -v xray >/dev/null 2>&1; then
        xray="$(command -v xray)"
    fi
    if [[ -n "$xray" ]]; then
        out="$("$xray" x25519 2>/dev/null || true)"
        priv="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]rivate[[:space:]]*[Kk]ey[[:space:]]*:[[:space:]]*//p' | head -n1)"
        pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[^:]*:[[:space:]]*//p' | head -n1)"
        if [[ -z "$pub" ]]; then
            # 新版 xray 的格式是 "Password (PublicKey): xxx"，
            # 旧正则要求 Password 后面紧跟冒号，26.x 起再也匹配不上。
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[^:]*:[[:space:]]*//p' | head -n1)"
        fi
        if [[ -n "$priv" && -z "$pub" ]]; then
            out="$("$xray" x25519 -i "$priv" 2>/dev/null || true)"
            pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]ublic[[:space:]]*[Kk]ey[^:]*:[[:space:]]*//p' | head -n1)"
            if [[ -z "$pub" ]]; then
                pub="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*[Pp]assword[^:]*:[[:space:]]*//p' | head -n1)"
            fi
        fi
        if [[ -n "$priv" && -n "$pub" ]]; then
            _cert_write_json "$outfile" "$priv" "$pub" || { oc_err "reality_keypair: 写入 $outfile 失败"; return 1; }
            # 本函数的 stdout 会被调用方用 $() 捕获（ocp_vless_reality_keys），
            # 提示必须走 stderr，否则这行文字会被当成密钥内容。
            oc_ok "REALITY 密钥对已写入：$outfile" >&2
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
