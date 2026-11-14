[English](README.md) | **简体中文**

# OneClick

**一键多协议代理安装器** — 一个脚本、一个入口、一套证书与状态管理。

把 VLESS-Reality、Hysteria2、Snell、SS-Rust、AnyTLS 五种服务端收进同一个命令行工具：
安装、改端口、换凭据、升级内核、生成客户端配置、备份恢复、卸载，都在一个菜单里完成，不依赖任何面板。

- 单文件发行：`dist/oneclick.sh`，约 7200 行，下载后即可运行
- Debian 13 / Ubuntu 22.04+ 优先，CentOS Stream / RHEL 9 兼容
- x86_64 / aarch64 / armv7l（AnyTLS 的 sing-box 不提供 i386）

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/justin0406/oneclick/main/dist/oneclick.sh -o oneclick.sh
sudo bash oneclick.sh
```

首次运行会把自身安装为 `/usr/local/bin/oneclick`（简写 `oc`），随后进入菜单。之后直接：

```bash
sudo oc
```

也可以完全不进菜单：

```bash
sudo oc --install hysteria2 --cert-mode self --yes
sudo oc --install vless_reality --yes
sudo oc --status
sudo oc --link snell --format surge
```

## 支持的协议

| 协议 | 服务端 | 端口 | 证书 | 说明 |
|---|---|---|---|---|
| VLESS-Reality | xray-core | 默认 443（可选随机） | 不需要 | REALITY + x25519，抗主动探测最强，建议作为主协议 |
| Hysteria2 | hysteria | 随机高位 UDP | 自签 / ACME / 已有 | QUIC，高丢包网络表现好，支持 salamander 混淆与端口跳跃 |
| Snell v5 / v6 | snell-server 5.0.1 / 6.0.0 | 随机高位 | 不需要 | 单端口、PSK 认证，Surge 生态原生支持；v5 是 QUIC（TCP+UDP），且是 armv7l 上的唯一选择 |
| SS-Rust | ssserver | 随机高位 TCP + UDP | 仅 ShadowTLS 需要 | 默认 SS2022；ShadowTLS v3（strict）伪装可选、默认关闭，客户端需支持 v3（如 mihomo / Clash Meta） |
| AnyTLS | sing-box | 随机高位 TCP | **必须**自签 / ACME / 已有 | 低特征 TLS 代理，Surge、Loon、sing-box 客户端均可使用 |

端口默认在 `20000-60000` 内随机选取（TCP 与 UDP 都确认空闲），重装保持原值；
VLESS-Reality 例外：安装时询问是否用 443（Y，伪装最优），选 N 才用随机高位端口；
可用 `--port` 指定；REALITY 仍建议使用独占端口。

SS-Rust 固定使用 SS2022（`2022-blake3-aes-128-gcm`），安装时不再询问——服务端没有任何
信号能判断客户端能力。老客户端请加 `--method chacha20-ietf-poly1305`（或 `aes-256-gcm`）。

> AnyTLS 用 sing-box 而非 anytls-go：后者服务端的 TLS 是进程内生成的 1 小时临时证书（无 SAN），
> 无法使用脚本签发的证书；sing-box 的 anytls inbound 支持 `certificate_path` / `key_path`。

## 设计原则

**协议插件化。** 每个协议实现同一组 10 个函数（`meta / install / uninstall / status / link / regen / upgrade / clash / surge / singbox`），
菜单、订阅、状态层只遍历注册表，不认识具体协议。新增协议 = 新增一个文件 + 注册一个 key。

**证书自主签发。** 每个需要 TLS 的协议都支持三条路径：`existing`（粘贴已有证书）、`acme`（acme.sh HTTP-01）、
`self`（EC P-256 + SAN 自签）。证书缺失时绝不静默生成随机证书，安装流程会停在证书步骤等你选择——
用编号菜单选择，不需要背英文单词。

**证书按域名共用。** 证书在 `certs/<域名>/` 下只存一份，使用同一域名的协议都指向同一组文件——
第二个 TLS 协议直接复用第一张证书，不再重复申请，也避开了 Let's Encrypt 的重复证书限额
（同一张证书一周内申请超过 5 次会被拒绝）。
acme.sh 续期时会 `systemctl restart` 所有登记过的服务，续期后的证书能真正落到运行中的服务上；
没有这个钩子，证书续期成功但服务还在用旧证书，到期就断。

ACME 需要一个**你自己拥有、且已解析到本机**的域名——没有默认值。脚本在调用 acme.sh 之前
会先检查域名解析和 80 端口，失败时展示 acme.sh 的真实输出，而不是一句笼统提示。

**不碰不属于自己的东西。** 完全不改防火墙：不写 iptables / nftables / firewalld / ufw 规则，
端口可达性由你自己的防火墙策略决定；也不 `chmod -R 777`、不改系统 SSH 配置、不调 sysctl。
唯一例外：启用 Hysteria2 端口跳跃时，由 hysteria 自己按其 `listen` 端口段安装并清理转发规则。

**下载可验证。** 所有二进制走统一下载层：3 次重试、可选镜像前缀（`OC_GH_PROXY`）、
`Cache-Control: no-cache`（防止缓存镜像返回旧版本二进制）、失败自动回滚不留下半截文件。
校验按优先级依次尝试：GitHub release API 的逐资产 `digest`（任意版本都可用）→
上游发布的校验文件（Xray `.dgst`、Hysteria2 `hashes.txt`、shadowsocks-rust `.sha256`）→
代码内记录的 Snell / sing-box 钉死版本 SHA-256 表 → 结构校验（下载内容必须是合法的
zip/gzip/xz 压缩包或 ELF 二进制，能挡镜像错误页但挡不住恶意替换）。
不信任镜像时建议不要设置 `OC_GH_PROXY`。

**自动更新。** 每次运行都会从本仓库读取 `dist/oneclick.sh`，比较内嵌的 `OC_VERSION`，
有新版本就原子替换自身并立即重启为新版本。任何失败（断网、镜像不可用、内容异常）都静默跳过，绝不阻塞菜单。
下载的脚本会以 root 执行，所以自更新**默认只走官方直连**——不套用 `OC_GH_PROXY`。
确实要让更新走镜像时设 `OC_UPDATE_MIRROR=1`，用 `OC_NO_UPDATE=1` 关闭检查，
或用 `OC_UPDATE_URL` 指向自己的副本。没有菜单项，也不写 cron。

**卸载即卸载。** 停止服务、取消开机自启、删除 unit 并 `daemon-reload`。
卸载单个协议时内核二进制**默认保留**——它们可能被面板或其他脚本共用，悄悄删掉会让别人的服务起不来
（仍被非 OneClick 单元引用的二进制一定保留）。想在交互里选择删除，或者用 `oneclick --purge`
清掉脚本创建的一切——那个必须手动输入 `PURGE` 才执行。

**内核原地安全升级。** `oneclick --upgrade <key|all>`（或菜单*节点管理 → 内核版本*）只替换内核二进制，
不碰配置、端口和凭据。每次升级都会：备份旧二进制、按 GitHub release digest 校验下载、
用新版本校验现有配置（内核提供 check 子命令时）、然后重启——**只重启升级前就在运行的服务**
（你手动停掉的服务不会被升级拉起，新二进制在下次启动时生效）——并确认服务存活。
任何一步失败都会还原备份并重启旧版本——备份保留到新版本确认跑起来为止，
因为没有配置自检的内核（Hysteria2、ssserver）只能靠启动失败来发现不兼容。

Snell 是例外：`dl.nssurge.com` 不提供版本索引，`--upgrade snell` 需要
显式指定 `--kernel-version X.Y.Z`，无法自动查最新。Hysteria2 在 GitHub API 限流时
退回官方 `api.hy2.io` 更新接口；其 systemd unit 采用官方安装器同款沙箱
（`NoNewPrivileges` + 受限能力集）——端口跳跃需要 `CAP_NET_ADMIN`。

**Snell v5 与 v6。** 用 `--snell-version 5|6` 选择（或回答安装时的提问）。v6 是纯 TCP + `mode`；
v5 是 **QUIC** 代理，需要 TCP 和 UDP 入站都放行，且是唯一提供 armv7l 构建的版本。
两者配置键不同（`mode` vs `obfs`），切换时会重写配置，客户端输出跟随已装版本。
注意 sing-box 的 snell outbound 支持 v4/v6 但**不支持 v5**——`--format singbox` 会直接报错说明，
而不是生成一份起不来的配置；v5 请用 Surge / Clash。

**单用户。** 不做多用户、流量统计、到期时间、Telegram 机器人 —— 这些交给面板，本脚本只负责把单机代理装好、管好。

## 目录结构

```
/etc/oneclick/
├── db.json                # 唯一状态库（jq 原子写 + flock）
├── certs/<域名>/          # cert.pem / key.pem（600），按域名共用
├── sub/                   # oneclick-clash.yaml / -surge.conf / -singbox.json / -uri.txt
└── <协议 key>/            # 各协议配置（600）

/usr/local/bin/oneclick    # 只放入口（oc 为简写），彻底卸载时删除
/opt/oneclick/bin/{xray,hysteria,snell-server,ssserver,shadow-tls,sing-box}   # 私有内核目录
/etc/systemd/system/oneclick-<协议>.service
```

**双栈输出。** 机器同时有公网 IPv4 和 IPv6 时，每种格式各输出**两份完整节点**——每个地址一份，
客户端可以任选地址族；单栈机器只输出一份。节点名保持相同，靠地址区分。
sing-box 输出中第二份的 tag 会加 `-v6` 后缀，因为那里的 tag 是唯一键。

注意这是"报告地址"，不验证入站流量是否可达——上游挡 IPv6 入站时，IPv6 节点照样输出但连不上。
运营商 IPv6 可用性不确定时请自行测试可达性。

**监听双栈。** 机器有 IPv6 栈时，SS-Rust、ShadowTLS、VLESS-Reality、AnyTLS 绑 `::`（Linux 默认双栈，
IPv4 仍可连）；没有 IPv6 栈时自动退回 `0.0.0.0`。Hysteria2 默认双栈；Snell v6 只监听 IPv4。

## 订阅

菜单「配置信息」只列出已安装的协议，选中后直接显示它的客户端写法。
需要落文件时用 `oc --sub`，只生成节点片段，方便粘进你已有的配置，而不是替换整份配置：

- `sub/oneclick-clash.yaml` — Clash / mihomo 节点项（粘到 `proxies:` 下；mihomo 仅支持 Snell v1–v5，v6 请用 Surge）
- `sub/oneclick-surge.conf` — Surge 节点行（粘到 `[Proxy]` 段；五种协议都支持——Surge 的 VLESS 策略类型需要 iOS 6.0.0+ / Mac 6.12.0+）
- `sub/oneclick-loon.conf` — Loon 节点行（粘到 `[Proxy]` 段；不含 Snell：Loon 不支持 Snell）
- `sub/oneclick-uri.txt` — 通用 URI 列表，可生成二维码
- sing-box 默认不生成，需要时用 `oneclick --sub --format singbox`

## 命令参考

```
oneclick                                        交互菜单
oneclick --install <key> [--port N] [--domain D] [--sni S] [--cert-mode M] [--yes]
oneclick --install ss_rust [--method chacha20-ietf-poly1305]   老客户端兼容加密方式
oneclick --install snell --snell-version 5|6    选择 Snell 大版本
oneclick --uninstall <key> [--yes]
oneclick --regen <key>                          从状态库重写配置
oneclick --upgrade <key|all> [--kernel-version X.Y.Z]
                                                升级内核（备份 / 自检 / 失败回滚）
oneclick --upgrade snell --kernel-version X.Y.Z snell 无版本接口，需显式指定
oneclick --upgrade snell --snell-version 5|6    切换 Snell 大版本
oneclick --link <key> [--format uri|clash|surge|loon|singbox|qr]
oneclick --status [--format json]
oneclick --list
oneclick --sub [--format uri|clash|surge|loon|singbox]
                                                节点片段（sing-box 需显式指定）
oneclick --cert-status
oneclick --purge                                彻底卸载（输入 PURGE 确认）
oneclick --version | --help
```

协议 key：`vless_reality hysteria2 snell ss_rust anytls`。双栈主机上所有格式都会按地址各输出一份节点（见下文「目录结构」）。

## 构建与测试

```bash
./build.sh
```

按 16 个模块拼成 `dist/oneclick.sh`，并执行四项校验：`bash -n`、`shellcheck -S warning`、
未定义函数扫描（只扫命令位，避免 jq 字段误报）、重复函数定义。改代码只改 `src/`，不要改 `dist/`。

CI（`.github/workflows/build.yml`）在每次推送时执行同样的构建与单元测试、`--version` / `--help`
冒烟测试，检查 `dist/oneclick.sh` 与 `src/` 产物一致，并检查改动 `README.md` 时
`README.zh-CN.md` 是否同步更新——两份文档必须一起走。

运行时需要 **bash 4.0+**（用到 `declare -gA`、`${var,,}`）；macOS 自带的 bash 3.2 会直接退出并给出明确提示。
所有受支持的 Linux 发行版都自带 bash 4 以上。

Bash 单元测试在 `tests/` 下，用 [bats-core](https://github.com/bats-core/bats-core) 运行：

```bash
bats tests/
```

```
src/00-header.sh            常量、协议注册表
src/lib/{os,ui,store,dl,net,cert,svc,share,upgrade}.sh
src/proto/{vless_reality,hysteria2,snell,ss_rust,anytls}.sh
src/99-menu.sh              菜单、CLI、main
```

每个版本都会先在干净的 Debian 13（trixie）VPS 上跑完整验证再推送。

## 致谢

设计参考了 [Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install)、
翠花 Snell.sh、[xOS/Shadowsocks-Rust](https://github.com/xOS/Shadowsocks-Rust)、
[jinqians 一键菜单](https://menu.jinqians.com)、[mozisen/surge](https://github.com/mozisen/surge)，
以及官方 [get.hy2.sh](https://github.com/apernet/hysteria) 安装脚本——
Hysteria2 的 unit 沙箱、升级重启语义与版本查询接口来自它。
没有复制上游代码（它们均未声明许可证，只作设计参考），本仓库的代码是重写的。

本仓库自身代码采用 **MIT** 许可，见 [LICENSE](LICENSE)；
运行时组件（Xray、Hysteria、sing-box 等）各自遵循其原始许可。详见 [NOTICE.md](NOTICE.md)。
