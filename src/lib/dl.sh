#!/usr/bin/env bash
# lib/dl.sh —— 统一下载器（镜像前缀 + SHA256 + 重试 + 原子替换）

# 是否 GitHub 直连域名（只有这些走镜像）
_dl_is_gh() {
    case "$1" in
        *github.com*|*githubusercontent.com*|*githubassets.com*) return 0 ;;
        *) return 1 ;;
    esac
}

dl_mirror_url() {
    local url="$1" prefix=""
    prefix="${OC_GH_PROXY:-}"
    if [[ -z "$prefix" ]]; then
        prefix="$(db_get settings gh_proxy "")"
    fi
    [[ -z "$prefix" ]] && { printf '%s' "$url"; return 0; }
    _dl_is_gh "$url" || { printf '%s' "$url"; return 0; }
    printf '%s/%s' "${prefix%/}" "$url"
}

# dl_fetch <url> <out> [sha256]
dl_fetch() {
    local url="$1" out="$2" sha="${3:-}"
    local -a urls=("$url")
    local m tmp src attempt ok=0
    m="$(dl_mirror_url "$url")"
    [[ "$m" != "$url" ]] && urls+=("$m")
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    tmp="${out}.part.$$"
    for src in "${urls[@]}"; do
        for attempt in 1 2 3; do
            # no-cache：get.hy2.sh 同款，防止镜像/CDN 缓存返回旧版本二进制
            if curl -fL -H 'Cache-Control: no-cache' --connect-timeout 10 --max-time 900 --retry 1 -o "$tmp" "$src" >/dev/null 2>&1; then
                ok=1; break 2
            fi
            rm -f "$tmp"; sleep 1
        done
    done
    if ((ok == 0)); then
        rm -f "$tmp"
        oc_err "下载失败：$url"
        return 1
    fi
    if [[ -n "$sha" ]]; then
        local got
        got="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
        if [[ "${got,,}" != "${sha,,}" ]]; then
            rm -f "$tmp"
            oc_err "SHA256 校验失败：$(basename "$out")"
            return 1
        fi
    fi
    mv -f "$tmp" "$out"
}

# dl_latest_tag <owner/repo> -> 输出 Release tag 原样（通常带 v，失败输出空）
# 需要不带 v 的纯版本号用 dl_latest_ver
dl_latest_tag() {
    local repo="$1" api tag prefix
    api="https://api.github.com/repos/$repo/releases/latest"
    prefix="${OC_GH_PROXY:-$(db_get settings gh_proxy "")}"
    tag="$(curl -fsSL --connect-timeout 10 --max-time 30 "$api" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    if [[ -z "$tag" && -n "$prefix" ]]; then
        tag="$(curl -fsSL --connect-timeout 10 --max-time 30 "${prefix%/}/$api" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null)"
    fi
    printf '%s' "$tag"
}

# dl_latest_ver <owner/repo> -> 输出去 v 的版本号（失败输出空）
dl_latest_ver() {
    local t
    t="$(dl_latest_tag "$1")"
    printf '%s' "${t#v}"
}

# dl_hy2_latest_tag -> hysteria 官方 update API 的最新 tag（app/vX.Y.Z）
# GitHub API 有匿名限流（60 次/小时），官方 api.hy2.io 没有限流且离 GitHub
# 更近——get.hy2.sh 就是用它查版本的。作为 dl_latest_tag 失败时的备用源。
dl_hy2_latest_tag() {
    local out
    out="$(curl -fsS --connect-timeout 10 --max-time 30 \
        "https://api.hy2.io/v1/update?cver=installscript&plat=linux&arch=${OC_ARCH:-amd64}&chan=release&side=server" 2>/dev/null \
        | jq -r '.lver // empty' 2>/dev/null)"
    printf '%s' "$out"
}

# dl_asset_digest <owner/repo> <tag> <asset-name># dl_asset_digest <owner/repo> <tag> <asset-name> -> 输出该资产的 sha256（小写十六进制）
#
# GitHub 的 release API 为每个资产提供 digest 字段（形如 "sha256:<hex>"），
# 这样任意版本都能动态取到官方哈希，不必在代码里维护"版本 → 哈希"静态表。
# tag 传 latest 时先解析成真实 tag。取不到（老资产无 digest / API 限流）输出空。
dl_asset_digest() {
    local repo="$1" tag="$2" asset="$3" api prefix json
    [[ "$tag" == "latest" ]] && tag="$(dl_latest_tag "$repo")"
    [[ -n "$tag" ]] || return 0
    api="https://api.github.com/repos/$repo/releases/tags/$tag"
    prefix="${OC_GH_PROXY:-$(db_get settings gh_proxy "")}"
    json="$(curl -fsSL --connect-timeout 10 --max-time 30 "$api" 2>/dev/null)"
    if [[ -z "$json" && -n "$prefix" ]]; then
        json="$(curl -fsSL --connect-timeout 10 --max-time 30 "${prefix%/}/$api" 2>/dev/null)"
    fi
    [[ -n "$json" ]] || return 0
    printf '%s' "$json" | jq -r --arg a "$asset" '
        (.assets[]? | select(.name == $a) | .digest // empty)
        | sub("^sha256:"; "")
    ' 2>/dev/null | head -n1
}

# dl_gh <owner/repo> <tag|latest> <asset> <out> —— 便捷封装，不做校验。
# 注意：安装内核不要用它，改用 dl_verify_fetch（会校验上游 sidecar 或静态哈希表）。
dl_gh() {
    local repo="$1" tag="$2" asset="$3" out="$4"
    if [[ "$tag" == "latest" ]]; then
        tag="$(dl_latest_tag "$repo")"
        [[ -z "$tag" ]] && { oc_err "无法获取 $repo 最新版本号（网络或 API 限流）"; return 1; }
    fi
    dl_fetch "https://github.com/$repo/releases/download/$tag/$asset" "$out"
}

# dl_unzip <zip> <destdir>
dl_unzip() {
    local zip="$1" dest="$2"
    mkdir -p "$dest"
    if ! command -v unzip >/dev/null 2>&1; then
        os_pkg_install unzip || return 1
    fi
    unzip -o -q "$zip" -d "$dest"
}

# 解压 tar.*：dl_untar <tar> <destdir>
dl_untar() {
    local tar="$1" dest="$2"
    mkdir -p "$dest"
    tar -xf "$tar" -C "$dest"
}

# ===========================================================================
# 上游校验文件（sidecar）解析
# ===========================================================================
#
# 各上游发布的校验文件格式互不相同，统一在这里归一化成纯 sha256 十六进制串：
#   Xray     <asset>.dgst  ->  "SHA2-256= <hex>"
#   Hysteria "hashes.txt"  ->  "<hex>  build/<asset>"
#   ss-rust  <asset>.sha256->  "<hex>  <asset>"
# 取不到校验文件时输出空串（调用方据此决定是否降级为结构校验）。

# _dl_sha_from_dgst <file> —— 从 Xray 的 .dgst 里取 SHA2-256
_dl_sha_from_dgst() {
    sed -n 's/^SHA2-256=[[:space:]]*\([0-9a-fA-F]\{64\}\).*/\1/p' "$1" 2>/dev/null | head -n1
}

# _dl_sha_from_hashlist <file> <asset-basename> —— 从 "hex  path" 清单里取该资产的哈希
_dl_sha_from_hashlist() {
    local f="$1" base="$2" h p
    while read -r h p; do
        [[ "$h" =~ ^[0-9a-fA-F]{64}$ ]] || continue
        # 清单里的路径可能带 build/ 前缀，按 basename 比对
        [[ "${p##*/}" == "$base" ]] || continue
        printf '%s' "$h"
        return 0
    done < "$f"
    return 1
}

# dl_sidecar_sha <asset-url> <asset-name> <style> <workdir>
#   style: dgst | hashlist | plain
#   成功输出小写 sha256；取不到或解析失败输出空串（不视为错误）
dl_sidecar_sha() {
    local url="$1" asset="$2" style="$3" dir="$4"
    local tmp sha="" try
    tmp="$dir/.sidecar.$$"
    case "$style" in
        dgst)
            if dl_fetch "$url.dgst" "$tmp" >/dev/null 2>&1; then
                sha="$(_dl_sha_from_dgst "$tmp")"
            fi
            ;;
        hashlist)
            # hysteria 的清单是整个 release 共用一个 hashes.txt
            if dl_fetch "${url%/*}/hashes.txt" "$tmp" >/dev/null 2>&1; then
                sha="$(_dl_sha_from_hashlist "$tmp" "$asset")"
            fi
            ;;
        plain)
            if dl_fetch "$url.sha256" "$tmp" >/dev/null 2>&1; then
                sha="$(_dl_sha_from_hashlist "$tmp" "$asset")"
                # 有些项目只写裸哈希一行
                [[ -z "$sha" ]] && sha="$(sed -n 's/^\([0-9a-fA-F]\{64\}\)$/\1/p' "$tmp" | head -n1)"
            fi
            ;;
    esac
    rm -f -- "$tmp" 2>/dev/null || true
    printf '%s' "${sha,,}"
}

# dl_verify_fetch <url> <out> <style> <asset-name>
#   下载资产并尝试用上游 sidecar 校验；拿不到 sidecar 时只做结构校验。
#   style: dgst | hashlist | plain（有上游校验文件）| none（该上游不发布校验文件）
dl_verify_fetch() {
    local url="$1" out="$2" style="$3" asset="$4" dir sha
    dir="$(dirname -- "$out")"
    mkdir -p "$dir" 2>/dev/null || true
    if ! dl_fetch "$url" "$out"; then
        return 1
    fi
    if [[ "$style" == "none" ]]; then
        # 压缩包与裸二进制都要能过：按魔数判断，挡掉镜像返回的 HTML 错误页
        if ! _dl_check_archive "$out"; then
            oc_err "下载内容不是有效的压缩包/二进制（可能是镜像返回了错误页）：$(basename "$out")"
            rm -f -- "$out"
            return 1
        fi
        return 0
    fi
    sha="$(dl_sidecar_sha "$url" "$asset" "$style" "$dir")"
    if [[ -z "$sha" ]]; then
        oc_warn "取不到上游校验文件，仅做结构校验：$(basename "$out")"
        if ! _dl_check_archive "$out"; then
            oc_err "下载内容不是有效的压缩包/二进制：$(basename "$out")"
            rm -f -- "$out"
            return 1
        fi
        return 0
    fi
    if ! dl_verify_sha "$out" "$sha"; then
        rm -f -- "$out"
        return 1
    fi
    oc_ok "SHA256 校验通过：$(basename "$out")"
}

# dl_verify_sha <file> <expected-hex>；expected 为空表示无期望值，直接通过（调用方已做结构校验）
dl_verify_sha() {
    local f="$1" hex="$2" got
    [[ -n "$hex" ]] || return 0
    got="$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f" 2>/dev/null) | awk '{print $1}')"
    if [[ "${got,,}" != "${hex,,}" ]]; then
        oc_err "SHA256 校验失败：$(basename "$f")"
        oc_err "  期望 ${hex,,}"
        oc_err "  实际 ${got,,}"
        return 1
    fi
    return 0
}

# _dl_check_elf <file> —— 只适用于裸二进制资产
_dl_check_elf() {
    local f="$1" magic
    [[ -f "$f" && -s "$f" ]] || return 1
    magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]]
}

# _dl_check_archive <file> —— 压缩包资产的结构校验：按魔数确认是 zip / gzip / xz，
# 挡住镜像返回的 HTML 错误页。裸 ELF 也放行（部分上游直接发未压缩二进制）。
_dl_check_archive() {
    local f="$1" magic
    [[ -f "$f" && -s "$f" ]] || return 1
    magic="$(od -An -tx1 -N6 "$f" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        504b0304*)          return 0 ;;  # zip: PK\x03\x04
        1f8b*)              return 0 ;;  # gzip
        fd377a585a00)       return 0 ;;  # xz
        7f454c46*)          return 0 ;;  # ELF（未压缩二进制）
        *)                  return 1 ;;
    esac
}
