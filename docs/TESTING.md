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

**记录基线**：`ss -lntup` 与 `nft list ruleset`（或 `iptables-save`）各存一份；本脚本不改防火墙，测试完这两份应与基线**完全一致**（唯一例外是 hy2 端口跳跃，见 10.7）。

**端口前提**：VLESS-Reality 需要 443 独占；AnyTLS / Hysteria2 需要高位 TCP / UDP 端口；ACME 模式还需要 80 空闲。首次安装会下载 xray / hysteria / snell-server / ssserver / sing-box，合计约 60~90 MB，慢的话在菜单「系统工具 → 3 镜像前缀」里配 gh_proxy。

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
oneclick   # 菜单 5（只有 5 项：依赖 / 端口 / 镜像 / 重测 IP / 本机信息）
# 5.1 菜单里不应再有"防火墙放行"项；装完协议后防火墙基线也不应变
diff <(nft list ruleset 2>/dev/null) /tmp/nft.baseline 2>/dev/null || iptables-save | diff - /tmp/ipt.baseline
# 脚本不调内核参数：不应存在 OneClick 写的 sysctl 文件（老版本升级上来的话顺手删掉）
ls /etc/sysctl.d/99-oneclick-bbr.conf 2>/dev/null && echo "旧残留，建议删除" || echo SYSCTL_CLEAN
# 补装依赖只装缺失项：已装齐时应当 0 次 apt 安装（看输出里没有"安装系统依赖"）
oneclick   # 菜单 5 → 1
```

## 6. 订阅与分享

```bash
oneclick   # 菜单 4 → 1（全部格式）
ls -l /etc/oneclick/sub/
cat /etc/oneclick/sub/oneclick-clash.yaml     # 期望：只有 - name: 节点项，没有 proxies:/rules 骨架
cat /etc/oneclick/sub/oneclick-surge.conf     # 期望：只有节点行，没有 [General]/[Proxy Group]/[Rule]
ls /etc/oneclick/sub/oneclick-singbox.json 2>/dev/null && echo "应在显式请求后才生成"
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

- Clash/Mihomo：把 `oneclick-clash.yaml` 的节点项粘到已有配置的 `proxies:` 下（Snell v6 需 mihomo 不支持，属预期）
- Surge：把 `oneclick-surge.conf` 的节点行粘到 `[Proxy]` 段，Snell v6 / AnyTLS / Hysteria2 均走原生语法
- Loon：把 `oneclick-loon.conf` 的节点行粘到 `[Proxy]` 段
- sing-box 默认不生成；需要时 `oneclick --sub --format singbox` 或菜单「仅生成 sing-box」

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

# 10.3 内核只装私有目录，不碰 /usr/local/bin：本机原有 snell-server.service 不受影响
ls -l /opt/oneclick/bin/snell-server /usr/local/bin/snell-server
systemctl is-active snell-server      # 期望：仍 active，且指向用户自己的二进制

# 10.4 重装复用私有目录里的二进制（不重新下载）
oneclick --uninstall snell --yes && oneclick --install snell --port 12345 --yes   # 期望：复用已安装的 snell-server

# 10.5 重装后重启机器，五个 unit 全部自启
systemctl is-enabled oneclick-vless-reality oneclick-hysteria2 oneclick-snell oneclick-ss-rust oneclick-anytls

# 10.6 订阅产物必须是 600，且四种格式齐全
stat -c '%a %n' /etc/oneclick/sub/* && oneclick --sub

# 10.7 端口跳跃：装 hy2 时启用 20000-20100；转发规则由 hysteria 自己创建/清理（脚本不写规则）
nft list ruleset 2>/dev/null | grep -i "hysteria_" || iptables -t nat -S | grep -i hysteria
# 页面里能看到 hysteria_<hash> 的 table（或 iptables 的 REDIRECT 规则）；卸载/停止 hy2 后应全部消失

# 10.8 ShadowTLS 真实连通（需要客户端支持 v3 strict，例如 mihomo）
# 服务端只需确认配置里 fallback 与 dispatch 指向同一个伪装域名
jq -c '.server.tls_addr' /etc/oneclick/ss_rust/shadowtls.json

# 10.9 重启后：不应存在 oneclick-firewall 单元，hy2 跳跃规则由 hysteria 自建
systemctl status oneclick-firewall 2>&1 | head -1   # 期望：Unit oneclick-firewall.service could not be found
reboot
nft list ruleset 2>/dev/null | grep -ci "hysteria_" || iptables -t nat -S | grep -ci hysteria   # 期望 ≥1（开了跳跃时）

# 10.10 Loon
cat /etc/oneclick/sub/oneclick-loon.conf
# 期望：4 个节点（VLESS-Reality / Hysteria2 / SS-Rust / AnyTLS），不含 Snell（Loon 不支持 Snell）。
# 类型名按官方现行文档大写：VLESS / Shadowsocks / Hysteria2 / AnyTLS；
# Hysteria2 与 AnyTLS 的 SNI 参数用 sni=；SS 行带 shadow-tls-password="..." 与 udp-port=<SS 端口>。
# Loon 里导入：配置 -> 添加配置 -> 从文件/URL 导入
# 文件里只有节点行（没有 [General]/[Proxy Group]/[Rule]），粘到现有配置的 [Proxy] 段即可
oneclick --link anytls --format loon   # 单个节点行，便于手工粘贴

# 版本门槛（官方频道 LoonNews 公告）：REALITY >= 3.3.0，AnyTLS >= 3.3.9，
# Hysteria2 端口跳跃 >= 3.4.0；老版本会忽略对应节点。
# 注意 server-ports 的分隔符官方两处材料不一致（文档写 "20000:20100"，官方模板写 "443,8443-8450"）；
# 本脚本沿用后者（连字符），若某版本不识别，改成冒号形式再试。

# 10.11 客户端导入兼容性
cat /etc/oneclick/sub/oneclick-surge.conf   # 不应出现 vless 行（Surge 不支持 VLESS）
# Hysteria2 行应带 port-hopping=<端口段>；SS-Rust 行走 ShadowTLS + udp-port=<SS 端口>
# AnyTLS 需 Surge iOS 5.17.0+ / Mac 6.4.3+；Snell v6 需 Surge（mihomo 只到 v5）
curl -sS -o /tmp/x "https://manual.nssurge.com/policies/snell.html" && echo "Surge snell version 1-6"

# 10.12 ACME 真实域名（DNS A 已指向本机、80 端口空闲且安全组已放行）
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
- 脚本完全不改防火墙：不写 iptables / nftables / firewalld / ufw 规则，也不创建开机重放单元；
  端口是否可达由你自己的防火墙策略决定。唯一例外是 hy2 端口跳跃，规则由 hysteria 自己按
  `listen: :8443,20000-20100` 创建并在进程退出时清理
- `oneclick --purge` 会清掉脚本创建的一切（协议、unit、`/etc/oneclick`、`/opt/oneclick`、入口软链、
  acme 续期任务），必须先手动输入 `PURGE` 才执行
