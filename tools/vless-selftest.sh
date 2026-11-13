#!/usr/bin/env bash
# tools/vless-selftest.sh —— 在本机用 xray 自己当客户端，环回验证 VLESS-Reality 链路。
#
# 目的：把"服务端配置有问题"和"客户端填错了"一刀切开。
#   环回通  -> 服务端 100% 正常，问题在客户端（flow / pbk / sid / sni 四项之一）
#   环回不通 -> 服务端或本机网络有问题，看脚本打出的 xray 日志
#
# 用法：
#   sudo bash tools/vless-selftest.sh
#   sudo bash tools/vless-selftest.sh https://www.google.com/generate_204
#
# 环境变量：OC_DB（默认 /etc/oneclick/db.json）、OC_BIN（默认 /opt/oneclick/bin/xray）
set -uo pipefail

DB="${OC_DB:-/etc/oneclick/db.json}"
BIN="${OC_BIN:-/opt/oneclick/bin/xray}"
SOCKS_PORT="${SOCKS_PORT:-11080}"
TARGET="${1:-https://www.gstatic.com/generate_204}"

die() { printf '[✗] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[✓] %s\n' "$*"; }
info() { printf '[*] %s\n' "$*"; }

[[ -f "$DB" ]] || die "找不到状态库：$DB（用 OC_DB=... 指定）"
if [[ ! -x "$BIN" ]]; then
    BIN="$(command -v xray 2>/dev/null || true)"
fi
[[ -n "$BIN" && -x "$BIN" ]] || die "找不到 xray 可执行文件（用 OC_BIN=/path/to/xray 指定）"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v jq   >/dev/null 2>&1 || die "缺少 jq"

field() { jq -r --arg k "$1" '.vless_reality[$k] // empty' "$DB" 2>/dev/null; }
port="$(field port)"
uuid="$(field uuid)"
sni="$(field server_name)"
sid="$(field short_id)"
pub="$(field public_key)"

[[ -n "$port" && -n "$uuid" && -n "$sni" && -n "$sid" && -n "$pub" ]] || \
    die "db.json 里 vless_reality 字段不全（需要 port/uuid/server_name/short_id/public_key）"

info "服务端参数（客户端必须逐字一致）"
printf '    uuid=%s\n    sni =%s\n    pbk =%s\n    sid =%s\n    port=%s\n' "$uuid" "$sni" "$pub" "$sid" "$port"

tmp="$(mktemp -d)" || die "临时目录创建失败"
pid=""
cleanup() {
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

jq -n \
    --argjson socks "$SOCKS_PORT" \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg sni "$sni" \
    --arg pbk "$pub" \
    --arg sid "$sid" \
    '{
        log: {loglevel: "info"},
        inbounds: [{
            listen: "127.0.0.1",
            port: $socks,
            protocol: "socks",
            settings: {auth: "noauth", udp: false}
        }],
        outbounds: [{
            protocol: "vless",
            settings: {vnext: [{
                address: "127.0.0.1",
                port: $port,
                users: [{id: $uuid, encryption: "none", flow: "xtls-rprx-vision"}]
            }]},
            streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                    serverName: $sni,
                    fingerprint: "chrome",
                    publicKey: $pbk,
                    shortId: $sid
                }
            }
        }]
    }' > "$tmp/client.json" || die "生成客户端配置失败"

info "启动环回客户端（socks5 127.0.0.1:$SOCKS_PORT -> 127.0.0.1:$port）"
"$BIN" run -c "$tmp/client.json" > "$tmp/xray.log" 2>&1 &
pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -q ":$SOCKS_PORT " && break
    fi
    sleep 0.3
done
if ! kill -0 "$pid" 2>/dev/null; then
    printf '[✗] xray 客户端没能启动，日志：\n'
    tail -20 "$tmp/xray.log"
    exit 1
fi

info "通过代理请求 $TARGET"
code="$(curl -sS -o /dev/null -m 20 -w '%{http_code}' \
    --socks5-hostname "127.0.0.1:$SOCKS_PORT" "$TARGET" 2>"$tmp/curl.err")"
rc=$?

echo
if [[ "$code" == "204" || "$code" == "200" ]]; then
    ok "环回成功（HTTP $code）—— 服务端、REALITY、flow 全部正常"
    echo
    echo "结论：问题在客户端或客户端到服务器的链路。按下面四项逐一核对客户端节点："
    echo "  1) pbk（public-key）与上面打印的 pbk 完全一致"
    echo "  2) sid（short-id）完全一致；空 sid 与 8 位 sid 是不同的匹配规则"
    echo "  3) sni 与 serverNames 一致（就是上面打印的 sni）"
    echo "  4) flow=xtls-rprx-vision 必须带上——服务器端强制了 vision，漏掉就是 TCP 通、TLS 断"
    exit 0
fi

printf '[✗] 环回失败（curl rc=%s，HTTP %s）\n' "$rc" "$code"
echo "--- curl 错误 ---"; tail -3 "$tmp/curl.err"
echo "--- xray 客户端日志（最后 25 行）---"; tail -25 "$tmp/xray.log"
echo
echo "进一步排查："
echo "  · 日志里若出现 'REALITY: processed invalid connection' / 'invalid user'，是 uuid/flow 不匹配"
echo "  · 出现 'failed to dial' / 'i/o timeout' 指向 dest，则服务端连不上 dest 站点"
echo "  · 端口在监听但本地都连不上，检查 ss -lntp | grep :$port 和防火墙"
exit 1
