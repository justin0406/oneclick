# OneClick 测试清单（Debian 13）

> 用法：按顺序执行，每条把「实际输出」贴回给我。失败不要自己修，先停在该步骤回传日志。
> 一键收集日志：`bash -c 'oneclick --status; systemctl list-units "oneclick-*" --no-pager; journalctl -u "oneclick-*" -n 200 --no-pager -o cat' > /root/oneclick-test.log 2>&1`

## 0. 环境准备（测试前）

```bash
cat /etc/os-release | head -3        # 期望：Debian GNU/Linux 13 (trixie)
uname -m                             # 期望：x86_64（或 aarch64）
ss -lntup | head -20                 # 记录现有 443/80 是否被占
systemctl --version | head -1        # 记录 systemd 版本
```

**记录基线**：`ss -lntup` 与 `nft list ruleset`（或 `iptables-save`）各存一份，测试完对比"是否只增删了 oneclick- 规则"。

**端口前提**：VLESS-Reality 需要 443 独占；AnyTLS / Hysteria2 需要高位 TCP / UDP 端口；ACME 模式还需要 80 空闲。首次安装会下载 xray / hysteria / snell-server / ssserver / sing-box，合计约 60~90 MB，慢的话在菜单「系统工具 → 6 镜像前缀」里配 gh_proxy。

## 1. 安装脚本本体

```bash
mkdir -p /root/oneclick && cd /root/oneclick
# 把 dist/oneclick.sh 传上来（scp 或 cat > oneclick.sh 粘贴），然后：
bash -n oneclick.sh && echo SYNTAX_OK
install -m 755 oneclick.sh /usr/local/bin/oneclick
oneclick --version                          # 期望：oneclick 0.1.0
oneclick --help                             # 期望：用法正常，无报错
```

**预期**：首次 `oneclick` 自动装 curl/jq/openssl/unzip 等基础依赖，然后进菜单；首屏显示系统、公网 IP、已装协议"无"。

## 2. 单协议冒烟（每个协议独立做一轮）

通用步骤（以 anytls 为例）：
```bash
oneclick --install anytls --port 8443 --cert-mode self --yes
systemctl status oneclick-anytls --no-pager    # 期望：active (running)
journalctl -u oneclick-anytls -n 30 --no-pager -o cat   # 期望：无报错
ss -lntup | grep 8443                    # 期望：有监听
oneclick --link anytls                         # 期望：anytls://... 一条
oneclick --link anytls --format clash          # 期望：YAML 片段
oneclick --status                              # 期望：AnyTLS 8443 运行中
```

逐协议检查点：

| 协议 | 安装命令 | 关键验证 |
|---|---|---|
| AnyTLS | `oneclick --install anytls --port 8443 --cert-mode self --yes` | 服务端为 **sing-box 1.14.4**（`sing-box version`）；证书文件存在且 key 600；`ls -l /etc/oneclick/certs/*/`；客户端（Surge/Loon）能连 |
| Hysteria2 | `oneclick --install hysteria2 --port 8443 --cert-mode self --yes` | UDP 监听 `ss -lnup`；客户端能连；无 obfs 时链接无 obfs 参数 |
| Snell v6 | `oneclick --install snell --port 12345 --yes` | `snell-server --version` 为 6.0.0；PSK 长度 20；Surge/Snell 客户端导入（mihomo 仅支持 v5 及以下） |
| SS-Rust | `oneclick --install ss_rust --port 8388 --yes` | `ssserver -h` 可执行；`ss -lnup` 有 UDP；ShadowTLS 默认**关**（开时监听第二个端口）；客户端能连 |
| VLESS-Reality | `oneclick --install vless_reality --port 443 --yes` | 443 监听；`xray x25519` 密钥已入 db；客户端能连且未被墙探测 |

## 3. 重启与自启

```bash
reboot
# 起来后：
oneclick --status                          # 期望：全部「运行中」
```

## 4. 幂等与冲突

```bash
oneclick --install anytls --yes            # 期望：拒绝「已安装」
oneclick --install snell --port 443 --yes  # 期望：端口占用被前置拦截
oneclick --uninstall anytls --yes
oneclick --uninstall anytls --yes          # 期望：第二次提示「未安装」，不报错
ss -lntup | grep 8443 || echo CLEAN  # 期望：CLEAN（端口释放）
ls /etc/systemd/system/oneclick-anytls.service 2>/dev/null || echo UNIT_CLEAN  # 期望：UNIT_CLEAN
```

## 5. 系统工具

```bash
oneclick   # 菜单 5
# 5.3 BBR：期望 sysctl 显示 bbr、fq
 sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
# 5.4 TFO：期望 3
 sysctl net.ipv4.tcp_fastopen
# 5.2 防火墙放行：期望只多出 oneclick- 开头的规则
 nft list ruleset 2>/dev/null | grep -i oneclick || iptables-save | grep oneclick
```

## 6. 订阅与分享

```bash
oneclick   # 菜单 4 → 1（全部格式）
ls -l /etc/oneclick/sub/
cat /etc/oneclick/sub/oneclick-clash.yaml     # 期望：proxies/proxy-groups/rules 完整，能直接导入 Clash
cat /etc/oneclick/sub/oneclick-surge.conf     # 期望：[Proxy]/[Proxy Group]/[Rule] 完整
```

## 7. 备份与恢复

```bash
oneclick   # 菜单 6 → 1，记录备份路径
oneclick   # 菜单 6 → 2，输入备份路径恢复
oneclick --status                        # 期望：恢复后协议仍在（可能需要逐个 regen）
```

## 8. 卸载全部 + 残留检查

```bash
oneclick   # 菜单 6 → 4
oneclick --status                        # 期望：全部未安装
systemctl list-units 'oneclick-*' --no-pager   # 期望：无
ls /etc/systemd/system/oneclick-*.service 2>/dev/null || echo UNIT_CLEAN
nft list ruleset 2>/dev/null | grep -c oneclick || iptables-save | grep -c oneclick   # 期望：0
```

## 9. 订阅可用性（客户端侧）

- Clash/Mihomo：直接导入 `/etc/oneclick/sub/oneclick-clash.yaml`（Snell v6 会因 mihomo 不支持被跳过，属预期）
- Surge：导入 `oneclick-surge.conf`，Snell v6 / AnyTLS / Hysteria2 均走 Surge 原生节点行
- sing-box 客户端：导入 `oneclick-singbox.json`

## 回传模板（每步失败时填）

```
步骤：4.2 oneclick --install snell --port 443 --yes
期望：端口冲突前置拦截
实际：（粘贴完整终端输出）
日志：systemctl status oneclick-snell --no-pager; journalctl -u oneclick-snell -n 50 --no-pager -o cat
系统：Debian 13 / x86_64 / 仅本脚本
```

## 10. VPS 回归要点（2026-11-09 实测新增）

在真实 Debian 13 / x86_64 上跑完整流程后，额外覆盖这几条：

```bash
# 10.1 端口冲突必须在下载之前失败（不应看到 "正在下载" 字样）
time oneclick --install snell --port 22 --yes

# 10.2 半成品状态可自愈：删掉 installed 登记但保留配置，再装应提示"上次未完成"并继续
jq 'del(.vless_reality)' /etc/oneclick/db.json > /tmp/db && mv /tmp/db /etc/oneclick/db.json
oneclick --install vless_reality --port 443 --yes

# 10.3 与他人共用的二进制不会被误删：本机已有 snell-server.service 时卸载本脚本的 snell
ls -l /usr/local/bin/snell-server      # 卸载后应仍在，且系统服务照常运行
systemctl is-active snell-server

# 10.4 snell-server 已存在时重装应"复用"下载（不重新下载）
oneclick --uninstall snell --yes && oneclick --install snell --port 12345 --yes   # 期望：复用已安装的 snell-server

# 10.5 重装后重启机器，五个 unit 全部自启
systemctl is-enabled oneclick-vless-reality oneclick-hysteria2 oneclick-snell oneclick-ss-rust oneclick-anytls

# 10.6 订阅产物必须是 600，且四种格式齐全
stat -c '%a %n' /etc/oneclick/sub/* && oneclick --sub

# 10.7 端口跳跃：装 hy2 时启用 20000-20100，规则必须带 oneclick-hop 注释且能计数
iptables -t nat -L PREROUTING -v -n | grep oneclick-hop
# 从另一台机器发一个 UDP 包，上面的 pkts 计数应 +1
printf x | nc -u -w1 <服务器IP> 20050

# 10.8 ShadowTLS 真实连通（需要客户端支持 v3 strict，例如 mihomo）
# 服务端只需确认配置里 fallback 与 dispatch 指向同一个伪装域名
jq -c '.server.tls_addr' /etc/oneclick/ss_rust/shadowtls.json

# 10.9 重启后防火墙规则自动恢复（没装 iptables-persistent 也不丢）
systemctl is-enabled oneclick-firewall     # enabled
cat /etc/oneclick/firewall.sh              # 只含带 oneclick- comment 的规则
reboot
iptables -S | grep -c oneclick             # 条数应与重启前一致
iptables -t nat -S | grep oneclick-hop     # 端口跳跃规则也在

# 10.10 ACME 真实域名（DNS A 已指向本机、80 端口空闲且安全组已放行）
oneclick --install anytls --port 9443 --domain <你的域名> --cert-mode acme --yes
openssl s_client -connect 127.0.0.1:9443 -servername <你的域名> -verify_return_error </dev/null \
  | grep -E 'issuer=|Verify return code'   # 期望 Let's Encrypt + code 0

# 复装应复用未过期证书，不重复占用 Let's Encrypt 签发限额
oneclick --uninstall anytls --yes
oneclick --install anytls --port 9443 --domain <你的域名> --cert-mode acme --yes
# 期望出现：已有可用证书（域名匹配且剩余 >30 天），直接复用
```

ShadowTLS 使用要点（实测踩坑，2026-11-09）：

- 服务端必须 `strict: true`（脚本默认），客户端也必须走 v3 strict；否则客户端发不出正确的
  SessionID，服务端会把它当普通 SNI 代理转发，表现为 TLS 握手挂住。
- 生成的客户端链接里 `plugin=shadow-tls;host=...;password=...` 是 mihomo / Clash Meta 的写法。
  用 `sslocal --plugin` 做本地测试时必须改成 `passwd=`，而且 SIP003 的 plugin-opts 无法打开
  strict（日志会显示 `enabled(lossy)`），所以本地验证建议分成两层：
  `shadow-tls --v3 --strict client ... --listen 127.0.0.1:1090` + `sslocal -s 127.0.0.1:1090`。
- 服务端 `fallback` 必须和客户端 `SNI` 指向同一站点。已认证客户端的握手实际发往 fallback；
  如果 fallback 是另一个域名（上游脚本默认 cloudflare.com 配 cloud.tencent.com），对端会因
  SNI 不匹配直接断开，日志出现 `ServerRandom extract failed, will copy bidirectional`。
  本脚本从 6b049f1 起把 fallback 写成 `<SNI>:443`，与 dispatch 保持一致。

已知行为（非 bug）：

- `--yes` 重装已安装协议会直接失败并提示先 `--uninstall`，这是为了避免脚本化误覆盖
- 自签证书（`--cert-mode self`）每次安装都会重签，客户端需要重新导入 `insecure` 链接
- AnyTLS 卸载保留 sing-box 二进制，VLESS 卸载默认保留 xray（其它面板可能共用）
- 防火墙规则会写成 `/etc/oneclick/firewall.sh` 并由 `oneclick-firewall.service` 在开机时重放；
  只重放带 `oneclick-` comment 的规则，不会覆盖 ufw/firewalld/nft 自己的策略
- 全部协议卸载后，`oneclick-firewall.service` 与 `firewall.sh` 会自动移除
