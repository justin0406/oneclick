# lib/share.sh —— 分享链接与订阅产物（Clash / Surge / Loon / sing-box / URI / 二维码）
#
# 约定：
#   - 所有内容生成逻辑只往 stdout 打内容，提示一律走 oc_info/oc_warn（stderr），
#     这样 share_render_sub 里 `... >/dev/null` 之后 stdout 还能干净地只留路径。
#   - 片段渲染全部委托给各协议实现的 link/clash/surge/singbox 渲染函数，
#     这里不关心任何协议细节；某协议片段生成失败（如拿不到公网 IP）就跳过并警告，
#     不能让一条坏节点把整份订阅带崩。

# 拼协议函数名。不要用字面量前缀紧接 ${...} 的写法：build.sh 的未定义函数扫描
# 会把前缀后直接跟变量的地方当成一个不存在的函数名，导出误报。
_share_fn() {
    local p="proto"
    printf '%s_%s_%s' "$p" "$1" "$2"
}

# oc_loon_name <key> —— Loon 节点名：Loon 的节点名不宜带空格（策略组列表是逗号分隔的裸名），
# 把标题里的空格换成连字符，片段行与策略组引用都用这个函数，保证两边一致。
oc_loon_name() {
    local n="${OC_PROTO_TITLE[$1]:-$1}"
    printf '%s' "${n// /-}"
}

# _share_write <kind> <outfile|stdout|""> <content>
# 落盘时用 umask 077 创建，保证订阅里带 uuid/私钥的文件从出生就是 600。
_share_write() {
    local kind="$1" target="$2" body="$3" dir
    if [[ -z "$target" || "$target" == "stdout" ]]; then
        printf '%s\n' "$body"
        return 0
    fi
    dir="$(dirname -- "$target")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            oc_err "创建目录失败：$dir"
            return 1
        }
    fi
    if ! ( umask 077; printf '%s\n' "$body" > "$target" ); then
        oc_err "写入失败：$target"
        return 1
    fi
    chmod 600 "$target" 2>/dev/null || true
    oc_info "$kind 订阅已写入：$target" >&2
    printf '%s\n' "$target"
}

# share_render_uri <key> —— 只输出该协议的分享 URI
share_render_uri() {
    local key="${1:-}" fn
    if [[ -z "$key" ]]; then
        oc_err "用法：share_render_uri <key>"
        return 1
    fi
    if ! db_is_installed "$key"; then
        oc_err "协议未安装：$key"
        return 1
    fi
    fn="$(_share_fn "$key" link)"
    "$fn"
}

# share_render_clash [outfile|stdout] —— 只输出节点片段（可直接粘到已有 proxies: 下）
share_render_clash() {
    local out="${1:-stdout}" key fn frag body
    local -a frags=()
    for key in "${OC_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" clash)"
        if ! frag="$("$fn")"; then
            oc_warn "跳过 $key：Clash 片段生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        frags+=("$frag")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        oc_err "没有可用的已安装协议，无法生成 Clash 订阅"
        return 1
    fi
    body="$(for frag in "${frags[@]}"; do printf '%s\n' "$frag"; done)"
    _share_write "Clash" "$out" "$body"
}

# share_render_surge [outfile|stdout] —— 只输出节点行（可直接粘到已有 [Proxy] 段）
share_render_surge() {
    local out="${1:-stdout}" key fn frag body
    local -a frags=()
    for key in "${OC_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        # Surge 没有 VLESS 策略类型（手册 policies/ 下无 vless 页），REALITY 节点只输出到
        # Clash / sing-box；这里跳过而不是写一行 Surge 解析不了的配置。
        [[ "$key" == "vless_reality" ]] && continue
        fn="$(_share_fn "$key" surge)"
        if ! frag="$("$fn")"; then
            oc_warn "跳过 $key：Surge 节点生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        frags+=("$frag")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        oc_err "没有可用的已安装协议，无法生成 Surge 订阅"
        return 1
    fi
    body="$(for frag in "${frags[@]}"; do printf '%s\n' "$frag"; done)"
    _share_write "Surge" "$out" "$body"
}

# share_render_loon [outfile|stdout] —— 只输出节点行（可直接粘到已有 [Proxy] 段）
# Loon 没有 Snell 支持（官方文档协议清单与订阅 URI 列表都不含 snell），这里跳过该节点。
share_render_loon() {
    local out="${1:-stdout}" key fn frag body
    local -a frags=()
    for key in "${OC_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        [[ "$key" == "snell" ]] && continue
        fn="$(_share_fn "$key" loon)"
        if ! frag="$("$fn")"; then
            oc_warn "跳过 $key：Loon 节点生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        frags+=("$frag")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        oc_err "没有可用的已安装协议，无法生成 Loon 订阅"
        return 1
    fi
    body="$(for frag in "${frags[@]}"; do printf '%s\n' "$frag"; done)"
    _share_write "Loon" "$out" "$body"
}

# share_render_singbox [outfile|stdout] —— 完整 sing-box 配置（首个出站是 selector）
# 默认不生成；仅在 --sub --format singbox / 菜单「仅生成 sing-box」时显式调用。
share_render_singbox() {
    local out="${1:-stdout}" key fn frag tag tags_json merged body
    local -a frags=() tags=()
    for key in "${OC_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" singbox)"
        if ! frag="$("$fn")"; then
            oc_warn "跳过 $key：sing-box 片段生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        # 片段必须是 JSON 对象，否则拼进去整份配置就废了
        if ! printf '%s' "$frag" | jq -e 'type == "object"' >/dev/null 2>&1; then
            oc_warn "跳过 $key：sing-box 片段不是合法 JSON 对象"
            continue
        fi
        tag="$(printf '%s' "$frag" | jq -r '.tag // empty' 2>/dev/null)"
        if [[ -z "$tag" ]]; then
            tag="${OC_PROTO_TITLE[$key]:-$key}"
            frag="$(printf '%s' "$frag" | jq -c --arg t "$tag" '.tag = $t')" || {
                oc_warn "跳过 $key：无法补 tag"
                continue
            }
        fi
        frags+=("$frag")
        tags+=("$tag")
    done
    if [[ ${#frags[@]} -eq 0 ]]; then
        oc_err "没有可用的已安装协议，无法生成 sing-box 订阅"
        return 1
    fi
    tags_json="$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s -c .)"
    merged="$(jq -c -n --argjson tags "$tags_json" \
        '{outbounds: [{type: "selector", tag: "proxy", outbounds: $tags}]}')"
    if [[ -z "$merged" ]]; then
        oc_err "生成 sing-box 骨架失败（jq 出错）"
        return 1
    fi
    for frag in "${frags[@]}"; do
        if ! merged="$(printf '%s' "$merged" | jq -c --argjson o "$frag" '.outbounds += [$o]')"; then
            oc_err "拼接 sing-box outbound 失败"
            return 1
        fi
    done
    body="$(printf '%s' "$merged" | jq .)" || body="$merged"
    _share_write "sing-box" "$out" "$body"
}

# share_render_uri_list [outfile|stdout] —— 一行一个 URI（订阅 uri 格式用）
share_render_uri_list() {
    local out="${1:-stdout}" key fn uri body=""
    for key in "${OC_PROTOS[@]}"; do
        db_is_installed "$key" || continue
        fn="$(_share_fn "$key" link)"
        if ! uri="$("$fn")"; then
            oc_warn "跳过 $key：URI 生成失败（缺公网 IP 或状态库字段不全）"
            continue
        fi
        body+="$uri"$'\n'
    done
    if [[ -z "$body" ]]; then
        oc_err "没有可用的已安装协议，无法生成 URI 列表"
        return 1
    fi
    _share_write "URI 列表" "$out" "${body%$'\n'}"
}

# share_render_sub <format> —— 生成 /etc/oneclick/sub/oneclick-<format>.<ext>，stdout 只打印路径
share_render_sub() {
    local format="${1:-}" path dir ext
    case "$format" in
        clash)   ext="yaml" ;;
        surge)   ext="conf" ;;
        loon)    ext="conf" ;;
        singbox) ext="json" ;;
        uri)     ext="txt" ;;
        *)
            oc_err "未知订阅格式：${format:-<空>}（可选 clash|surge|loon|singbox|uri）"
            return 1
            ;;
    esac
    dir="$OC_SUB_DIR"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            oc_err "创建订阅目录失败：$dir"
            return 1
        }
    fi
    path="$dir/oneclick-$format.$ext"
    case "$format" in
        clash)   share_render_clash "$path" >/dev/null || return 1 ;;
        surge)   share_render_surge "$path" >/dev/null || return 1 ;;
        loon)    share_render_loon "$path" >/dev/null || return 1 ;;
        singbox) share_render_singbox "$path" >/dev/null || return 1 ;;
        uri)     share_render_uri_list "$path" >/dev/null || return 1 ;;
    esac
    chmod 600 "$path" 2>/dev/null || true
    printf '%s\n' "$path"
}

# share_qr <text> —— 终端二维码；没有 qrencode 就原样打印文本
share_qr() {
    local text="${1:-}"
    if [[ -z "$text" ]]; then
        oc_err "用法：share_qr <text>"
        return 1
    fi
    if command -v qrencode >/dev/null 2>&1; then
        # ANSIUTF8 用半个字高的块字符，终端里比 ASCII 二维码窄一半
        qrencode -t ANSIUTF8 "$text" || {
            oc_err "qrencode 执行失败，下面给出原始文本"
            printf '%s\n' "$text"
            return 1
        }
    else
        oc_warn "未安装 qrencode（apt install qrencode 后才出二维码），下面直接给出原始文本："
        printf '%s\n' "$text"
    fi
}

# share_print_info <key> [formats] —— 客户端写法。
# formats 为空格分隔列表（uri surge loon），默认三种全给；菜单里只看客户端行时传 "surge loon"。
share_print_info() {
    local key="${1:-}" f fn out formats
    if [[ -z "$key" ]]; then
        oc_err "用法：share_print_info <key> [formats]"
        return 1
    fi
    if [[ $# -gt 1 ]]; then
        shift
        formats="$*"
    else
        formats="uri surge loon"
    fi
    db_is_installed "$key" || return 1
    oc_title "配置信息：${OC_PROTO_TITLE[$key]:-$key}"

    for f in $formats; do
        case "$f" in
            uri)
                oc_info "URI："
                fn="$(_share_fn "$key" link)"
                if out="$("$fn" 2>/dev/null)" && [[ -n "$out" ]]; then
                    printf '  %s\n' "$out"
                else
                    oc_warn "生成失败"
                fi
                ;;
            surge)
                oc_info "Surge："
                case "$key" in
                    vless_reality) printf '  不支持（Surge 没有 VLESS 策略类型）\n' ;;
                    *)
                        fn="$(_share_fn "$key" surge)"
                        if out="$("$fn" 2>/dev/null)" && [[ -n "$out" ]]; then
                            printf '  %s\n' "$out"
                        else
                            oc_warn "生成失败"
                        fi
                        ;;
                esac
                ;;
            loon)
                oc_info "Loon："
                case "$key" in
                    snell) printf '  不支持（Loon 没有 Snell 协议）\n' ;;
                    *)
                        fn="$(_share_fn "$key" loon)"
                        if out="$("$fn" 2>/dev/null)" && [[ -n "$out" ]]; then
                            printf '  %s\n' "$out"
                        else
                            oc_warn "生成失败"
                        fi
                        ;;
                esac
                ;;
            *)
                oc_warn "未知格式：$f（可选 uri|surge|loon）"
                ;;
        esac
    done
}

