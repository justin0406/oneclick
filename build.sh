#!/usr/bin/env bash
# build.sh —— 把 src/ 拼成单文件 dist/oneclick.sh，并做静态校验
set -uo pipefail
cd "$(dirname "$0")" || exit 1

SRC="src"
OUT="dist/oneclick.sh"

FILES=(
    00-header.sh
    lib/os.sh
    lib/ui.sh
    lib/store.sh
    lib/dl.sh
    lib/net.sh
    lib/cert.sh
    lib/svc.sh
    lib/share.sh
    lib/upgrade.sh
    proto/vless_reality.sh
    proto/hysteria2.sh
    proto/snell.sh
    proto/ss_rust.sh
    proto/anytls.sh
    99-menu.sh
)

fail=0
for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC/$f" ]]; then
        echo "✗ 缺少源文件：$SRC/$f"
        fail=1
    fi
done
(( fail )) && exit 1

mkdir -p dist
: > "$OUT"

for f in "${FILES[@]}"; do
    # 首文件保留 shebang 必须在第 1 行，不能在前面插标记注释
    if [[ "$f" != "00-header.sh" ]]; then
        printf '# ===== %s =====\n' "$SRC/$f" >> "$OUT"
    fi
    if [[ "$f" == "00-header.sh" ]]; then
        cat "$SRC/$f" >> "$OUT"
    else
        sed '1{/^#!/d;}' "$SRC/$f" >> "$OUT"
    fi
    printf '\n' >> "$OUT"
done

chmod 755 "$OUT"

echo "== 1/4 语法检查 =="
if ! bash -n "$OUT"; then
    echo "✗ bash -n 失败"
    exit 1
fi
echo "✓ bash -n 通过"

echo "== 2/4 shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -e SC1091,SC2034,SC2155 "$OUT"; then
        echo "✓ shellcheck 通过"
    else
        echo "✗ shellcheck 有问题"
        exit 1
    fi
else
    echo "- 未安装 shellcheck，跳过"
fi

echo "== 3/4 未定义函数扫描 =="
# perl 缺失时这项检查会静默失效（旧版本只打印 perl: not found 然后照样 ✓），
# 直接当成构建失败，避免"假绿"。
if ! command -v perl >/dev/null 2>&1; then
    echo "✗ 未安装 perl：未定义函数扫描无法执行（apt install perl）"
    exit 1
fi
defined="$(grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' "$OUT" \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | sort -u)"
# 只扫描"命令位"（行首/管道/&&/||/子shell/控制关键字之后）的 token，
# 避免把 jq 字段字面量（cert_mode、cert_path 之类）误判成函数名
called="$(perl -ne '
    while (/(?:^|[;&|({]|\$\(|&&|\|\|)\s*(?:(?:if|then|elif|else|do|while|until|!)\s+)?((?:oc|ocp|proto|db|dl|os|net|cert|svc|share)_[A-Za-z0-9_]+)/g) {
        print "$1\n";
    }
' "$OUT" | sort -u)"
# 不再用 <(...) 进程替换：没有 /dev/fd 的环境（busybox、部分容器）会静默拿到空集合并通过
scan_tmp="$(mktemp -d)" || exit 1
printf '%s\n' $called > "$scan_tmp/called"
printf '%s\n' $defined > "$scan_tmp/defined"
undefined="$(comm -23 "$scan_tmp/called" "$scan_tmp/defined")"
rm -rf "$scan_tmp"
if [[ -n "$undefined" ]]; then
    echo "✗ 发现未定义函数："
    printf '  %s\n' $undefined
    exit 1
fi
echo "✓ 未定义函数：0"

# 重复定义
dups="$(grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' "$OUT" \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | sort | uniq -d)"
if [[ -n "$dups" ]]; then
    echo "✗ 函数重复定义："
    printf '  %s\n' $dups
    exit 1
fi
echo "✓ 重复定义：0"

echo "== 4/4 产物 =="
lines=$(wc -l < "$OUT" | tr -d ' ')
size=$(wc -c < "$OUT" | tr -d ' ')
sha=$( (sha256sum "$OUT" 2>/dev/null || shasum -a 256 "$OUT") | awk "{print \$1}" )
echo "✓ $OUT"
echo "  行数: $lines  字节: $size"
echo "  sha256: $sha"
if [[ "$lines" -lt 1200 ]]; then
    echo "! 注意：产物行数偏少（$lines），可能有模块未实现"
fi
