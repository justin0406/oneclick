#!/usr/bin/env bash
# tests/helpers.bash —— 把 dist/oneclick.sh 加载成可 source 的函数库
#
# dist 末尾有 main "$@"，直接 source 会执行它（要求 root、探测系统）。
# 这里剥掉那一行，只留函数定义，让测试能在任何机器上跑纯函数。
#
# 注意：被测代码需要 bash 4+（关联数组）。bats-core 默认用它自己的
# /usr/bin/env bash，在 macOS 上那是 3.2——运行测试请确保 PATH 里
# 的 bash 是 4+，例如：
#   PATH=/opt/homebrew/bin:$PATH bats tests/
# CI（Ubuntu）自带 bash 5，无需额外处理。

setup_lib() {
    LIB="${BATS_TEST_TMPDIR}/lib.sh"
    local src="${BATS_TEST_DIRNAME}/../dist/oneclick.sh"
    [[ -f "$src" ]] || {
        echo "缺少 $src，请先运行 ./build.sh" >&2
        return 1
    }
    # 剥掉末尾的 main "$@"（会要求 root），以及开头的 bash 版本守卫
    # （守卫是给最终用户的运行期提示；测试里由 bats 自己保证解释器版本）
    awk 'BEGIN{del=0} {lines[NR]=$0} END{
        for (i=NR; i>=1; i--) if (lines[i] ~ /^main "\$@"$/) { del=i; break }
        skip=0
        for (i=1; i<=NR; i++) {
            if (lines[i] ~ /^if \(\( BASH_VERSINFO\[0\] < 4 \)\); then$/) { skip=1 }
            if (skip) { if (lines[i] ~ /^fi$/) { skip=0 }; continue }
            if (i != del) print lines[i]
        }
    }' "$src" > "$LIB"

    # 被测代码用 declare -gA（全局关联数组）。测试里 source 发生在函数内，
    # 若把 -gA 改成 -A 会变成函数局部变量，setup 返回后就没了。
    # 所以这里保留 -gA（测试统一要求 bash 4+，见文件头说明）。
    export OC_ROOT="${BATS_TEST_TMPDIR}/root"
    export OC_DB="$OC_ROOT/db.json"
    export OC_CERT_DIR="$OC_ROOT/certs"
    export OC_SUB_DIR="$OC_ROOT/sub"
    export OC_BIN_DIR="$OC_ROOT/bin"
    mkdir -p "$OC_ROOT"
    # shellcheck disable=SC1090
    source "$LIB"
    # 默认让 IP 探测"失败"，单个测试需要时自己覆盖
    net_primary_ip() { return 0; }
    db_setting() { [[ $# -ge 2 ]] && return 0; printf ''; }
}

# 写一个最小的 db.json
write_db() {
    printf '%s\n' "$1" > "$OC_DB"
}
