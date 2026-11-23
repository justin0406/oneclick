#!/usr/bin/env bash
# build.sh —— 把 src/ 拼成单文件 dist/oneclick.sh，并做静态校验
#
# 产物写入策略：先拼到同目录临时文件，四项检查全部通过后才 mv 覆盖
# dist/oneclick.sh。任何一步失败都保留上一版产物，不会留下半截脚本。
#
# 选项：
#   --strict    未安装 shellcheck 时视为失败（CI 用；本地缺工具时默认跳过）
set -uo pipefail
cd "$(dirname "$0")" || exit 1

STRICT=0
for a in "$@"; do
    case "$a" in
        --strict) STRICT=1 ;;
        *) echo "✗ 未知参数：$a（可用：--strict）"; exit 1 ;;
    esac
done

SRC="src"
OUT="dist/oneclick.sh"
TMP_OUT=""

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
# 拼到临时文件，检查全过再原子替换；中途 exit 不会破坏 dist/oneclick.sh
TMP_OUT="$(mktemp "dist/.oneclick.build.XXXXXX")" || { echo "✗ 无法创建临时文件"; exit 1; }
cleanup_tmp() { [[ -n "$TMP_OUT" && -f "$TMP_OUT" ]] && rm -f -- "$TMP_OUT"; }
trap cleanup_tmp EXIT INT TERM

for f in "${FILES[@]}"; do
    # 首文件保留 shebang 必须在第 1 行，不能在前面插标记注释
    if [[ "$f" != "00-header.sh" ]]; then
        printf '# ===== %s =====\n' "$SRC/$f" >> "$TMP_OUT"
    fi
    if [[ "$f" == "00-header.sh" ]]; then
        cat "$SRC/$f" >> "$TMP_OUT"
    else
        sed '1{/^#!/d;}' "$SRC/$f" >> "$TMP_OUT"
    fi
    printf '\n' >> "$TMP_OUT"
done

chmod 755 "$TMP_OUT"

echo "== 1/4 语法检查 =="
if ! bash -n "$TMP_OUT"; then
    echo "✗ bash -n 失败"
    exit 1
fi
echo "✓ bash -n 通过"

echo "== 2/4 shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -e SC1091,SC2034,SC2155 "$TMP_OUT"; then
        echo "✓ shellcheck 通过"
    else
        echo "✗ shellcheck 有问题"
        exit 1
    fi
elif (( STRICT )); then
    echo "✗ 未安装 shellcheck（--strict 要求必须执行）"
    exit 1
else
    echo "- 未安装 shellcheck，跳过（CI 用 --strict）"
fi

echo "== 3/4 未定义函数扫描 =="
# perl 缺失时这项检查会静默失效（旧版本只打印 perl: not found 然后照样 ✓），
# 直接当成构建失败，避免"假绿"。
if ! command -v perl >/dev/null 2>&1; then
    echo "✗ 未安装 perl：未定义函数扫描无法执行（apt install perl）"
    exit 1
fi
defined="$(grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' "$TMP_OUT" \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | sort -u)"
# 只扫描"命令位"（行首/管道/&&/||/子shell/控制关键字之后）的 token，
# 避免把 jq 字段字面量（cert_mode、cert_path 之类）误判成函数名
called="$(perl -ne '
    # 前缀清单 = 公共前缀 + 实际存在的私有前缀（_menu/_bk/_cert/_cli/_db/_dl/_net/
    # _oc/_os/_share/_up）。(?:_)? 让 _net_port_num 这类下划线私有函数也参与扫描，
    # 它们之间有真实互调，漏扫会让未定义函数检查出现假绿。
    while (/(?:^|[;&|({]|\$\(|&&|\|\|)\s*(?:(?:if|then|elif|else|do|while|until|!)\s+)?((?:_)?(?:oc|ocp|proto|db|dl|os|net|cert|svc|share|menu|bk|cli|up)_[A-Za-z0-9_]+)/g) {
        print "$1\n";
    }
' "$TMP_OUT" | sort -u)"
# 不再用 <(...) 进程替换：没有 /dev/fd 的环境（busybox、部分容器）会静默拿到空集合并通过
scan_tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$scan_tmp"; cleanup_tmp' EXIT INT TERM
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
dups="$(grep -oE '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)' "$TMP_OUT" \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | sort | uniq -d)"
if [[ -n "$dups" ]]; then
    echo "✗ 函数重复定义："
    printf '  %s\n' $dups
    exit 1
fi
echo "✓ 重复定义：0"

echo "== 4/4 产物 =="
lines=$(wc -l < "$TMP_OUT" | tr -d ' ')
size=$(wc -c < "$TMP_OUT" | tr -d ' ')
sha=$( (sha256sum "$TMP_OUT" 2>/dev/null || shasum -a 256 "$TMP_OUT") | awk "{print \$1}" )
# 模块哨兵：dist 必须包含每个源文件的拼接标记，缺一个说明整段模块丢了。
# 行数下限拦不住"丢一整个中等模块"（阈值永远追不上代码量），哨兵是精确校验；
# 00-header.sh 无拼接标记，用它的协议注册表代替。
missing=""
for f in "${FILES[@]}"; do
    if [[ "$f" == "00-header.sh" ]]; then
        grep -q '^OC_PROTOS=(' "$TMP_OUT" || missing+=" $f"
    else
        grep -q "# ===== $SRC/$f =====" "$TMP_OUT" || missing+=" $f"
    fi
done
if [[ -n "$missing" ]]; then
    echo "✗ 缺少模块哨兵：$missing"
    exit 1
fi
echo "✓ 模块哨兵：${#FILES[@]}/${#FILES[@]}"

# 全部检查通过，此刻才原子替换正式产物
if ! mv -f -- "$TMP_OUT" "$OUT"; then
    echo "✗ 替换 $OUT 失败"
    exit 1
fi
TMP_OUT=""
chmod 755 "$OUT"
echo "✓ $OUT"
echo "  行数: $lines  字节: $size"
echo "  sha256: $sha"
