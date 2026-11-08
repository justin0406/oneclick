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
    prefix="${PX_GH_PROXY:-}"
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
            if curl -fL --connect-timeout 10 --max-time 900 --retry 1 -o "$tmp" "$src" >/dev/null 2>&1; then
                ok=1; break 2
            fi
            rm -f "$tmp"; sleep 1
        done
    done
    if ((ok == 0)); then
        rm -f "$tmp"
        px_err "下载失败：$url"
        return 1
    fi
    if [[ -n "$sha" ]]; then
        local got
        got="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')"
        if [[ "${got,,}" != "${sha,,}" ]]; then
            rm -f "$tmp"
            px_err "SHA256 校验失败：$(basename "$out")"
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
    prefix="${PX_GH_PROXY:-$(db_get settings gh_proxy "")}"
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

# dl_gh <owner/repo> <tag|latest> <asset> <out>
dl_gh() {
    local repo="$1" tag="$2" asset="$3" out="$4"
    if [[ "$tag" == "latest" ]]; then
        tag="$(dl_latest_tag "$repo")"
        [[ -z "$tag" ]] && { px_err "无法获取 $repo 最新版本号（网络或 API 限流）"; return 1; }
    fi
    dl_fetch "https://github.com/$repo/releases/download/$tag/$asset" "$out"
}

# 解压 zip：dl_unzip <zip> <destdir>
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
