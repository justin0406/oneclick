#!/usr/bin/env bats
# 纯函数回归测试：不联网、不碰系统，秒级跑完。
# 每个测试都对应一处曾经出过问题（或极易出问题）的逻辑。

load helpers

setup() { setup_lib; }

# ---------- 版本比较 ----------

# oc_version_gt: 分段比较，0.2.10 > 0.2.9（不是字符串比较）
@test "version_gt_numeric_segments" {
    run oc_version_gt "0.2.10" "0.2.9"
    [ "$status" -eq 0 ]
}

# oc_version_gt: 相等返回假
@test "version_gt_equal_is_false" {
    run oc_version_gt "0.2.9" "0.2.9"
    [ "$status" -ne 0 ]
}

# oc_version_gt: 旧版本返回假
@test "version_gt_older_is_false" {
    run oc_version_gt "0.2.8" "0.2.9"
    [ "$status" -ne 0 ]
}

# oc_version_gt: 缺段按 0 处理
@test "version_gt_missing_segment_as_zero" {
    run oc_version_gt "0.3" "0.2.9"
    [ "$status" -eq 0 ]
}

# ---------- 公网 IP 校验 ----------

# _net_is_ipv4: 合法地址
@test "ipv4_accepts_valid" {
    run _net_is_ipv4 "203.0.113.9"
    [ "$status" -eq 0 ]
}

# _net_is_ipv4: 越界八位组被拒
@test "ipv4_rejects_octet_over_255" {
    run _net_is_ipv4 "256.1.1.1"
    [ "$status" -ne 0 ]
}

# _net_is_ipv4: 非 IP 被拒
@test "ipv4_rejects_non_ip" {
    run _net_is_ipv4 "not.an.ip.addr"
    [ "$status" -ne 0 ]
}

# _net_is_ipv4: 前导零按十进制解释，不判越界
@test "ipv4_leading_zeros_decimal" {
    run _net_is_ipv4 "010.001.001.001"
    [ "$status" -eq 0 ]
}

# ---------- 端口校验 ----------

# _net_port_num: 规范化前导零
@test "port_num_normalizes_leading_zeros" {
    run _net_port_num "08080"
    [ "$status" -eq 0 ]
    [ "$output" = "8080" ]
}

# _net_port_num: 0 与 65536 越界
@test "port_num_rejects_zero_and_65536" {
    run _net_port_num "0"
    [ "$status" -ne 0 ]
    run _net_port_num "65536"
    [ "$status" -ne 0 ]
}

# _net_port_num: 非数字被拒
@test "port_num_rejects_nondigit" {
    run _net_port_num "80a"
    [ "$status" -ne 0 ]
}

# ---------- SS2022 密码形状 ----------

# ocp_ssrust_pw_ok: aes-128 要求解码后 16 字节
@test "ss2022_aes128_needs_16_bytes" {
    local k16 k32
    k16="$(printf '%016d' 0 | base64)"
    k32="$(printf '%032d' 0 | base64)"
    run ocp_ssrust_pw_ok "2022-blake3-aes-128-gcm" "$k16"
    [ "$status" -eq 0 ]
    # 32 字节密钥不能用于 aes-128
    run ocp_ssrust_pw_ok "2022-blake3-aes-128-gcm" "$k32"
    [ "$status" -ne 0 ]
}

# ocp_ssrust_pw_ok: aes-256 要求 32 字节
@test "ss2022_aes256_needs_32_bytes" {
    local k32
    k32="$(printf '%032d' 0 | base64)"
    run ocp_ssrust_pw_ok "2022-blake3-aes-256-gcm" "$k32"
    [ "$status" -eq 0 ]
}

# ocp_ssrust_pw_ok: 菜单换来的普通随机串对 SS2022 不合法（触发 regen 自动重生）
@test "ss2022_rejects_plain_token" {
    run ocp_ssrust_pw_ok "2022-blake3-aes-128-gcm" "AbCdEfGh12345678"
    [ "$status" -ne 0 ]
}

# ocp_ssrust_pw_ok: 传统 AEAD 方法只要求非空
@test "legacy_cipher_any_nonempty" {
    run ocp_ssrust_pw_ok "chacha20-ietf-poly1305" "anypassword"
    [ "$status" -eq 0 ]
    run ocp_ssrust_pw_ok "chacha20-ietf-poly1305" ""
    [ "$status" -ne 0 ]
}

# ---------- SIP002 userinfo 编码 ----------

# ocp_ssrust_b64url: 去掉 padding 且 +/ 转成 -_
@test "b64url_strips_padding_and_swaps_chars" {
    # base64("...?") 里容易出现 + 和 /
    local out
    out="$(ocp_ssrust_b64url "$(printf '\xff\xfe\xfd\xfc')")"
    [[ "$out" != *"="* ]]
    [[ "$out" != *"+"* ]]
    [[ "$out" != *"/"* ]]
}

# ocp_ssrust_b64url: 可逆
@test "b64url_roundtrip" {
    local raw="2022-blake3-aes-128-gcm:abc+def/ghi="
    local enc dec
    enc="$(ocp_ssrust_b64url "$raw")"
    # 补回 padding 后解码
    while (( ${#enc} % 4 != 0 )); do enc+="="; done
    dec="$(printf '%s' "${enc//-/+}" | tr '_' '/' | base64 -d 2>/dev/null)"
    [ "$dec" = "$raw" ]
}

# ---------- 证书目录名 ----------

# _cert_dir_name: 通配符 *.example.com 归到 example.com
@test "cert_dir_name_strips_wildcard" {
    run _cert_dir_name "*.example.com"
    [ "$output" = "example.com" ]
}

# _cert_dir_name: 非法字符替换为下划线
@test "cert_dir_name_sanitizes" {
    run _cert_dir_name "a b/c*d.com"
    [[ "$output" != *" "* ]]
    [[ "$output" != *"/"* ]]
    [[ "$output" != *"*"* ]]
}

# _cert_dir_name: 空值退回 default
@test "cert_dir_name_empty_default" {
    run _cert_dir_name ""
    [ "$output" = "default" ]
}

# ---------- 证书域名覆盖 ----------

# _cert_covers: 精确匹配
@test "cert_covers_exact" {
    # 用真实生成的证书测（openssl 本地签，不联网）
    local dir="${BATS_TEST_TMPDIR}/c"
    cert_self "example.com" "$dir" >/dev/null 2>&1 || skip "openssl 不可用"
    run _cert_covers "$dir/cert.pem" "example.com"
    [ "$status" -eq 0 ]
}

# _cert_covers: 其它域名不匹配
@test "cert_covers_rejects_other_domain" {
    local dir="${BATS_TEST_TMPDIR}/c2"
    cert_self "example.com" "$dir" >/dev/null 2>&1 || skip "openssl 不可用"
    run _cert_covers "$dir/cert.pem" "evil.com"
    [ "$status" -ne 0 ]
}

# ---------- 下载校验层 ----------

# _dl_sha_from_dgst: 解析 Xray .dgst 的 SHA2-256 行
@test "dgst_parses_sha2_256" {
    local f="${BATS_TEST_TMPDIR}/x.dgst"
    cat > "$f" <<'EOF'
MD5= 17349769d85d6d0c5043b25c30da9673
SHA1= 4b9d50003e0ba1b67b375bfd0a51019c50a26f57
SHA2-256= b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82
SHA2-512= 9eb4e818
EOF
    run _dl_sha_from_dgst "$f"
    [ "$output" = "b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82" ]
}

# _dl_sha_from_hashlist: 按 basename 匹配（清单带 build/ 前缀）
@test "hashlist_matches_basename" {
    local f="${BATS_TEST_TMPDIR}/h.txt"
    cat > "$f" <<'EOF'
afaa6367db3a4fb718b85a9c6366be9ea3e1c4ef1dbb82402624b9215640d98f  build/hysteria-android-386
907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691  build/hysteria-linux-amd64
EOF
    run _dl_sha_from_hashlist "$f" "hysteria-linux-amd64"
    [ "$output" = "907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691" ]
}

# _dl_sha_from_hashlist: 找不到该资产返回非零
@test "hashlist_missing_asset_fails" {
    local f="${BATS_TEST_TMPDIR}/h2.txt"
    printf '%s  build/other\n' "$(printf '%064d' 0)" > "$f"
    run _dl_sha_from_hashlist "$f" "not-there"
    [ "$status" -ne 0 ]
}

# dl_verify_sha: 哈希不符返回非零并给出期望/实际
@test "verify_sha_mismatch_fails" {
    local f="${BATS_TEST_TMPDIR}/blob"
    printf 'hello' > "$f"
    run dl_verify_sha "$f" "$(printf '%064d' 0)"
    [ "$status" -ne 0 ]
    [[ "$output" == *"校验失败"* ]]
}

# dl_verify_sha: 空期望值直接通过（该上游无校验文件时的降级）
@test "verify_sha_empty_expectation_passes" {
    local f="${BATS_TEST_TMPDIR}/blob2"
    printf 'hello' > "$f"
    run dl_verify_sha "$f" ""
    [ "$status" -eq 0 ]
}

# dl_verify_sha: 哈希正确时通过
@test "verify_sha_correct_passes" {
    local f="${BATS_TEST_TMPDIR}/blob3" h
    printf 'hello' > "$f"
    h="$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | awk '{print $1}')"
    run dl_verify_sha "$f" "$h"
    [ "$status" -eq 0 ]
}

# _dl_check_archive: 接受 zip/gzip/xz/ELF 魔数
@test "check_archive_accepts_known_magics" {
    local d="${BATS_TEST_TMPDIR}/magic"
    mkdir -p "$d"
    printf 'PK\x03\x04rest' > "$d/zip"
    printf '\x1f\x8brest' > "$d/gz"
    printf '\xfd7zXZ\x00rest' > "$d/xz"
    printf '\x7fELFrest' > "$d/elf"
    for f in zip gz xz elf; do
        run _dl_check_archive "$d/$f"
        [ "$status" -eq 0 ]
    done
}

# _dl_check_archive: 拒绝 HTML 错误页（镜像常见返回）
@test "check_archive_rejects_html" {
    local f="${BATS_TEST_TMPDIR}/html"
    printf '<!DOCTYPE html><html><body>404</body></html>' > "$f"
    run _dl_check_archive "$f"
    [ "$status" -ne 0 ]
}

# ---------- 静态哈希表完整性 ----------

# sing-box 静态哈希表覆盖所有支持的架构
@test "singbox_sha_table_complete" {
    # 表里缺项会静默降级成结构校验，这里确保 amd64/arm64/armv7 都在。
    # 键里含 "."，用 printf 拼出键名后以字面量下标查询（避免算术求值）。
    local key
    for key in \
        "sing-box-${OC_SINGBOX_VER}-linux-amd64.tar.gz" \
        "sing-box-${OC_SINGBOX_VER}-linux-arm64.tar.gz" \
        "sing-box-${OC_SINGBOX_VER}-linux-armv7.tar.gz"; do
        [[ -n "${OC_SINGBOX_SHA256["$key"]:-}" ]] || { echo "缺 $key"; return 1; }
    done
}

# snell 静态哈希表覆盖所有支持的架构
@test "snell_sha_table_complete" {
    local key
    for key in \
        "snell-server-v${OC_SNELL_VER}-linux-amd64.zip" \
        "snell-server-v${OC_SNELL_VER}-linux-aarch64.zip" \
        "snell-server-v${OC_SNELL_VER}-linux-i386.zip"; do
        [[ -n "${OC_SNELL_SHA256["$key"]:-}" ]] || { echo "缺 $key"; return 1; }
    done
}

# ---------- 节点渲染：IP 取不到时绝不能产出坏节点 ----------

# IP 探测失败时 hy2/anytls 所有渲染函数返回非零且无输出
@test "ip_failure_renders_no_bad_nodes" {
    write_db '{"installed":["hysteria2","anytls"],"settings":{},
      "hysteria2":{"password":"p","port":"23456","sni":"bing.com","tls_mode":"self","obfs":"off"},
      "anytls":{"password":"p","port":"23457","sni":"bing.com","tls_mode":"self"}}'
    local fn
    for fn in proto_hysteria2_link proto_hysteria2_clash proto_hysteria2_surge \
              proto_hysteria2_loon proto_hysteria2_singbox \
              proto_anytls_link proto_anytls_clash proto_anytls_surge \
              proto_anytls_loon proto_anytls_singbox; do
        run "$fn"
        [ "$status" -ne 0 ] || { echo "$fn 应当失败"; return 1; }
        [ -z "$output" ] || { echo "$fn 不应输出：$output"; return 1; }
    done
}

# IPv6 地址在 link/surge/loon 中加方括号
@test "ipv6_bracketed_in_links" {
    write_db '{"installed":["hysteria2"],"settings":{},
      "hysteria2":{"password":"p","port":"23456","sni":"bing.com","tls_mode":"self","obfs":"off"}}'
    net_primary_ip() { printf '2001:db8::1'; }
    run proto_hysteria2_link
    [ "$status" -eq 0 ]
    [[ "$output" == *"[2001:db8::1]:23456"* ]]
}

# singbox tag 与其它客户端节点名一致
@test "singbox_tag_matches_node_name" {
    write_db '{"installed":["hysteria2"],"settings":{},
      "hysteria2":{"password":"p","port":"23456","sni":"bing.com","tls_mode":"self","obfs":"off"}}'
    net_primary_ip() { printf '1.2.3.4'; }
    run proto_hysteria2_singbox
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r .tag)" = "Hysteria2" ]
}

# ---------- REALITY 密钥：函数 stdout 必须只有两行纯密钥 ----------
# 曾经 reality_keypair 成功时把 "[✓] ...已写入" 打到 stdout，
# 调用方 $() 捕获后把这行日志当成了私钥写进 config.json（xray 报 invalid privateKey）。

@test "reality_keypair_stdout_is_not_polluted" {
    local dir="${BATS_TEST_TMPDIR}/rk"
    mkdir -p "$dir"
    local out
    out="$(reality_keypair "$dir/k.json" 2>/dev/null)" || skip "无法生成 REALITY 密钥"
    # stdout 必须为空：所有提示都走 stderr
    [ -z "$out" ] || { echo "stdout 被污染：[$out]"; return 1; }
}

@test "reality_keypair_writes_parseable_json" {
    local dir="${BATS_TEST_TMPDIR}/rk2"
    mkdir -p "$dir"
    reality_keypair "$dir/k.json" >/dev/null 2>&1 || skip "无法生成 REALITY 密钥"
    [ -f "$dir/k.json" ] || { echo "未写出文件"; return 1; }
    local priv pub
    priv="$(jq -r '.privateKey // empty' "$dir/k.json")"
    pub="$(jq -r '.publicKey // empty' "$dir/k.json")"
    # 密钥是 base64url，不含空格/冒号/中文；日志文本会包含这些
    [[ "$priv" =~ ^[A-Za-z0-9_-]{40,}$ ]] || { echo "privateKey 形状异常：[$priv]"; return 1; }
    [[ "$pub"  =~ ^[A-Za-z0-9_-]{40,}$ ]] || { echo "publicKey 形状异常：[$pub]"; return 1; }
}

@test "vless_keys_output_has_exactly_two_lines" {
    # 没有 xray 时 reality_keypair 只回退到"只有私钥"分支，公钥拿不到，
    # ocp_vless_reality_keys 必然失败——本机无 xray 就跳过。
    command -v xray >/dev/null 2>&1 || [[ -x "${OC_BIN_DIR}/xray" ]] || skip "本机无 xray，跳过"
    local kp rc
    kp="$(ocp_vless_reality_keys 2>/dev/null)" && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then skip "REALITY 密钥生成失败（rc=$rc）"; fi
    [ "$(printf '%s\n' "$kp" | wc -l | tr -d ' ')" -eq 2 ] || {
        echo "应为两行，实际：[$kp]"; return 1; }
    # 两行都必须是纯密钥，不能含提示文本
    [[ "$kp" != *"✓"* ]] || { echo "混入了日志文本：[$kp]"; return 1; }
}

# ---------- regen staging 文件名：xray 按扩展名判格式 ----------
# 曾经用 config.json.new，xray 报 "Failed to get format"，导致 --regen 永远失败。

@test "vless_regen_staging_keeps_json_extension" {
    # 直接断言源码里的 staging 命名约定：必须以 .json 结尾
    local src="${BATS_TEST_DIRNAME}/../src/proto/vless_reality.sh"
    grep -q 'staging="$dir/config.staging.json"' "$src" || {
        echo "staging 文件名不是 .json 结尾，xray 会拒绝自检"; return 1; }
    # 反向断言：不应再出现 .new 结尾
    if grep -q 'staging="\${cfg}.new"' "$src"; then
        echo "仍在用 config.json.new"; return 1
    fi
}

# ---------- hysteria 端口跳跃的 nft 表清理 ----------
# systemctl stop 后 hysteria 自清不完整，IPv6 表会残留。

@test "hy2_clean_hop_rules_exists_and_is_scoped" {
    declare -F ocp_hy2_clean_hop_rules >/dev/null || {
        echo "缺少 ocp_hy2_clean_hop_rules"; return 1; }
    # 必须只在表名以 hysteria_ 开头时删除，不能碰用户自己的规则
    local body
    body="$(declare -f ocp_hy2_clean_hop_rules)"
    [[ "$body" == *'hysteria_'* ]] || { echo "未按 hysteria_ 前缀过滤"; return 1; }
    [[ "$body" == *'nft delete table'* ]] || { echo "未调用 nft delete"; return 1; }
}

@test "uninstall_paths_clean_hop_rules" {
    local src="${BATS_TEST_DIRNAME}/../src"
    grep -q 'ocp_hy2_clean_hop_rules' "$src/proto/hysteria2.sh" || {
        echo "卸载路径未清理 nft 规则"; return 1; }
    grep -q 'ocp_hy2_clean_hop_rules' "$src/99-menu.sh" || {
        echo "purge 路径未兜底清理 nft 规则"; return 1; }
}

# ---------- Loon VLESS 行必须用合法的 tls-profile ----------
# 合法值以 Loon 官方示例注释为准：global/default/safari-ios18/safari-ios-26/
# chrome/chrome147。我们输出 chrome147（带版本号的具体指纹）。
# 注意：曾误判"chrome 非法"并把 Loon 连不上归因于此，实际根因是重装未重启服务。

@test "loon_vless_uses_valid_tls_profile" {
    write_db '{"installed":["vless_reality"],"settings":{"ip":"1.2.3.4"},
      "vless_reality":{"port":"443","uuid":"11111111-2222-3333-4444-555555555555",
      "server_name":"www.microsoft.com","short_id":"5ae06551",
      "public_key":"qxnmPvI1Ku9BIZhNhZZS14F-jfrdz_URYf80AoruNEA"}}'
    run proto_vless_reality_loon
    [ "$status" -eq 0 ] || { echo "生成失败"; return 1; }
    local tp
    tp="$(printf '%s' "$output" | grep -oE 'tls-profile=[^,]+')"
    # 合法值以 Loon 官方示例注释为准：
    # global / default / safari-ios18 / safari-ios-26 / chrome / chrome147
    case "$tp" in
        tls-profile=global|tls-profile=default|tls-profile=safari-ios18|\
        tls-profile=safari-ios-26|tls-profile=chrome|tls-profile=chrome147) ;;
        *) echo "tls-profile 非法：[$tp]"; return 1 ;;
    esac
}

@test "loon_vless_has_reality_required_params" {
    write_db '{"installed":["vless_reality"],"settings":{"ip":"1.2.3.4"},
      "vless_reality":{"port":"443","uuid":"11111111-2222-3333-4444-555555555555",
      "server_name":"www.microsoft.com","short_id":"5ae06551",
      "public_key":"qxnmPvI1Ku9BIZhNhZZS14F-jfrdz_URYf80AoruNEA"}}'
    run proto_vless_reality_loon
    [ "$status" -eq 0 ]
    # REALITY over TCP 的必需项，缺任何一个都连不上
    [[ "$output" == *"transport=tcp"* ]]        || { echo "缺 transport=tcp"; return 1; }
    [[ "$output" == *"over-tls=true"* ]]        || { echo "缺 over-tls=true"; return 1; }
    [[ "$output" == *"flow=xtls-rprx-vision"* ]] || { echo "缺 flow"; return 1; }
    [[ "$output" == *"public-key="* ]]          || { echo "缺 public-key"; return 1; }
    [[ "$output" == *"short-id="* ]]            || { echo "缺 short-id"; return 1; }
    [[ "$output" == *"sni="* ]]                 || { echo "缺 sni"; return 1; }
}

# ---------- SS2022 的 userinfo 必须明文百分号编码（SIP022） ----------
# SIP002 允许 base64url，但 SIP022 对 AEAD-2022 明确规定 MUST NOT 编码。

@test "ss2022_userinfo_is_percent_encoded_not_base64" {
    write_db '{"installed":["ss_rust"],"settings":{"ip":"1.2.3.4"},
      "ss_rust":{"port":"8388","method":"2022-blake3-aes-128-gcm","password":"9510kK0JBiy5gDiiCLy7eg=="}}'
    run proto_ss_rust_link
    [ "$status" -eq 0 ] || { echo "生成失败"; return 1; }
    # 明文 method 前缀，不是 base64 串
    [[ "$output" == ss://2022-blake3-aes-128-gcm:* ]] || {
        echo "SS2022 被 base64 编码了：$output"; return 1; }
    # == 必须转义为 %3D%3D
    [[ "$output" == *"%3D%3D"* ]] || { echo "= 未转义"; return 1; }
}

@test "legacy_ss_cipher_still_base64url" {
    write_db '{"installed":["ss_rust"],"settings":{"ip":"1.2.3.4"},
      "ss_rust":{"port":"8388","method":"chacha20-ietf-poly1305","password":"mypass"}}'
    run proto_ss_rust_link
    [ "$status" -eq 0 ]
    # 传统 AEAD 沿用 base64url：不应出现明文 method
    [[ "$output" != *"chacha20-ietf-poly1305:"* ]] || {
        echo "传统加密方式不该用明文 userinfo"; return 1; }
}

@test "ss_pct_escapes_reserved_chars" {
    run ocp_ssrust_pct "a=b+c/d"
    [ "$output" = "a%3Db%2Bc%2Fd" ]
}

# ---------- Hysteria2 端口跳跃按官方 URI 规范写进端口组件 ----------
# 官方 URI-Scheme 文档：不是 mport 查询参数，而是 :port,start-end

@test "hy2_uri_puts_port_hopping_in_port_component" {
    write_db '{"installed":["hysteria2"],"settings":{"ip":"1.2.3.4"},
      "hysteria2":{"port":"41856","password":"pw","sni":"bing.com",
      "tls_mode":"self","obfs":"off","hop":"20000-30000"}}'
    run proto_hysteria2_link
    [ "$status" -eq 0 ] || { echo "生成失败"; return 1; }
    [[ "$output" == *":41856,20000-30000/"* ]] || {
        echo "端口跳跃未写进端口组件：$output"; return 1; }
    [[ "$output" != *mport* ]] || { echo "仍在用 mport"; return 1; }
}

# ---------- Surge 现已支持 VLESS（iOS 6.0.0+ / Mac 6.12.0+） ----------
# 官方手册 policies/vless.html：username / reality-public-key / reality-short-id

@test "surge_vless_uses_official_param_names" {
    write_db '{"installed":["vless_reality"],"settings":{"ip":"1.2.3.4"},
      "vless_reality":{"port":"443","uuid":"11111111-2222-3333-4444-555555555555",
      "server_name":"www.microsoft.com","short_id":"5ae06551",
      "public_key":"qxnmPvI1Ku9BIZhNhZZS14F-jfrdz_URYf80AoruNEA"}}'
    run proto_vless_reality_surge
    [ "$status" -eq 0 ] || { echo "生成失败"; return 1; }
    [[ "$output" == *"username=11111111-2222-3333-4444-555555555555"* ]] || { echo "缺 username"; return 1; }
    [[ "$output" == *"reality-public-key="* ]] || { echo "缺 reality-public-key"; return 1; }
    [[ "$output" == *"reality-short-id="* ]] || { echo "缺 reality-short-id"; return 1; }
    # 手册说明 reality-public-key 隐含 TLS，不应再写 tls=true
    [[ "$output" != *"tls=true"* ]] || { echo "REALITY 不该加 tls=true"; return 1; }
}

# ---------- 内核升级：版本解析与备份回滚 ----------

@test "oc_bin_version_parses_varied_outputs" {
    local d="${BATS_TEST_TMPDIR}/vbins"
    mkdir -p "$d"
    # 模拟各内核的版本输出格式
    printf '#!/bin/sh\n[ "$1" = version ] && echo "Xray 26.11.9 (Xray, Penetrates Everything.)"\n' > "$d/a"
    printf '#!/bin/sh\necho "Version:\tv2.13.0"\n' > "$d/b"
    printf '#!/bin/sh\necho "shadowsocks 1.25.0"\n' > "$d/c"
    # 带时间戳小数（snell 的真实格式），不能误抓 04.311250
    printf '#!/bin/sh\necho "2026-11-13 02:16:04.311250 [server_main] <NOTIFY> snell-server v6.0.0"\n' > "$d/e"
    chmod +x "$d"/*
    [ "$(oc_bin_version "$d/a")" = "26.11.9" ] || { echo "a: $(oc_bin_version "$d/a")"; return 1; }
    [ "$(oc_bin_version "$d/b")" = "2.13.0" ]  || { echo "b: $(oc_bin_version "$d/b")"; return 1; }
    [ "$(oc_bin_version "$d/c")" = "1.25.0" ]  || { echo "c: $(oc_bin_version "$d/c")"; return 1; }
    [ "$(oc_bin_version "$d/e")" = "6.0.0" ]   || { echo "e: $(oc_bin_version "$d/e")"; return 1; }
}

@test "oc_bin_version_ignores_error_text_from_unsupported_flag" {
    # ssserver version 会报 "unexpected argument"，不能因此停止尝试 -V
    local d="${BATS_TEST_TMPDIR}/vbin2"
    mkdir -p "$d"
    cat > "$d/x" <<'EOS'
#!/bin/sh
case "$1" in
  version) echo "error: unexpected argument 'version' found" >&2; exit 2 ;;
  -V)      echo "shadowsocks 1.25.0" ;;
esac
EOS
    chmod +x "$d/x"
    [ "$(oc_bin_version "$d/x")" = "1.25.0" ] || { echo "got: $(oc_bin_version "$d/x")"; return 1; }
}

@test "upgrade_begin_backup_and_rollback" {
    local d="${BATS_TEST_TMPDIR}/up"
    mkdir -p "$d"
    printf 'OLD' > "$d/bin"; chmod 755 "$d/bin"
    local bak
    bak="$(oc_upgrade_begin "$d/bin")" || { echo "备份失败"; return 1; }
    [ -f "$bak" ] || { echo "备份文件不存在"; return 1; }
    # 覆盖为新内容
    printf 'NEW' > "$d/bin"
    # 回滚
    oc_upgrade_rollback "$bak" "$d/bin" || { echo "回滚失败"; return 1; }
    [ "$(cat "$d/bin")" = "OLD" ] || { echo "回滚后内容不对：$(cat "$d/bin")"; return 1; }
    [ ! -f "$bak" ] || { echo "回滚后备份未清理"; return 1; }
}

@test "upgrade_commit_removes_backup" {
    local d="${BATS_TEST_TMPDIR}/up2"
    mkdir -p "$d"
    printf 'OLD' > "$d/bin"; chmod 755 "$d/bin"
    local bak
    bak="$(oc_upgrade_begin "$d/bin")"
    oc_upgrade_commit "$bak"
    [ ! -f "$bak" ] || { echo "commit 后备份未删"; return 1; }
}

@test "upgrade_begin_fails_on_missing_target" {
    run oc_upgrade_begin "/nonexistent/bin"
    [ "$status" -ne 0 ]
}

# ---------- 每个已装协议都必须提供 upgrade 函数 ----------

@test "every_protocol_has_upgrade_function" {
    local k
    for k in "${OC_PROTOS[@]}"; do
        declare -F "proto_${k}_upgrade" >/dev/null || {
            echo "缺少 proto_${k}_upgrade"; return 1; }
    done
}

# ---------- GitHub API digest 取代静态哈希表 ----------

@test "dl_asset_digest_exists" {
    declare -F dl_asset_digest >/dev/null || { echo "缺少 dl_asset_digest"; return 1; }
    # 必须只取 sha256: 前缀后的十六进制，且按资产名精确匹配
    local body; body="$(declare -f dl_asset_digest)"
    [[ "$body" == *'sha256:'* ]] || { echo "未处理 sha256: 前缀"; return 1; }
    [[ "$body" == *'select(.name == $a)'* ]] || { echo "未按资产名精确匹配"; return 1; }
}
