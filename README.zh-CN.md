[English](README.md) | **简体中文**

# OneClick

**一键多协议代理安装器** — 一个脚本、一个入口、一套证书与状态管理。

把 VLESS-Reality、Hysteria2、Snell v6、SS-Rust、AnyTLS 五种服务端收进同一个命令行工具：
安装、改端口、换证书、生成订阅、备份恢复、卸载，都在一个菜单里完成，不依赖任何面板。

- 单文件发行：`dist/oneclick.sh`，约 6000 行，下载后即可运行
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
| Snell v6 | snell-server 6.0.0 | 随机高位 TCP | 不需要 | 单端口、PSK 认证，Surge 生态原生支持 |
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

**协议插件化。** 每个协议实现同一组 9 个函数（`meta / install / uninstall / status / link / regen / clash / surge / singbox`），
菜单、订阅、状态层只遍历注册表，不认识具体协议。新增协议 = 新增一个文件 + 注册一个 key。

**证书自主签发。** 每个需要 TLS 的协议都支持三条路径：`existing`（粘贴已有证书）、`acme`（acme.sh HTTP-01）、
`self`（EC P-256 + SAN 自签）。证书缺失时绝不静默生成随机证书，安装流程会停在证书步骤等你选择。

**不碰不属于自己的东西。** 完全不改防火墙：不写 iptables / nftables / firewalld / ufw 规则，
端口可达性由你自己的防火墙策略决定；也不 `chmod -R 777`、不改系统 SSH 配置、不调 sysctl。
唯一例外：启用 Hysteria2 端口跳跃时，由 hysteria 自己按其 `listen` 端口段安装并清理转发规则。

**下载可验证。** 所有二进制走统一下载层：3 次重试、可选镜像前缀（`OC_GH_PROXY`）、有 SHA256 则校验、
失败自动回滚，不留下半截文件。

**自动更新。** 每次运行都会从本仓库读取 `dist/oneclick.sh`，比较内嵌的 `OC_VERSION`，
有新版本就原子替换自身并立即重启为新版本。任何失败（断网、镜像不可用、内容异常）都静默跳过，绝不阻塞菜单。
可用 `OC_NO_UPDATE=1` 关闭，或 `OC_UPDATE_URL` 指向自己的镜像。没有菜单项，也不写 cron。

**卸载即卸载。** 停止服务、取消开机自启、删除 unit 并 `daemon-reload`，配置与证书单独确认是否保留。
`oneclick --purge` 会清掉脚本创建的一切，且必须手动输入 `PURGE` 才执行。

**单用户。** 不做多用户、流量统计、到期时间、Telegram 机器人 —— 这些交给面板，本脚本只负责把单机代理装好、管好。

## 目录结构

```
/etc/oneclick/
├── db.json                # 唯一状态库（jq 原子写 + flock）
├── certs/<name>/          # cert.pem / key.pem（600）
├── sub/                   # oneclick-clash.yaml / -surge.conf / -singbox.json / -uri.txt
└── <协议 key>/            # 各协议配置（600）

/usr/local/bin/oneclick    # 只放入口（oc 为简写），彻底卸载时删除
/opt/oneclick/bin/{xray,hysteria,snell-server,ssserver,shadow-tls,sing-box}   # 私有内核目录
/etc/systemd/system/oneclick-<协议>.service
```

**监听双栈。** 机器有 IPv6 栈时，SS-Rust、ShadowTLS、VLESS-Reality、AnyTLS 绑 `::`（Linux 默认双栈，
IPv4 仍可连）；没有 IPv6 栈时自动退回 `0.0.0.0`。Hysteria2 默认双栈；Snell 仍只监听 IPv4。

## 订阅

菜单「配置信息」只列出已安装的协议，选中后直接显示它的 Surge / Loon 写法。
需要落文件时用 `oc --sub`，只生成节点片段，方便粘进你已有的配置，而不是替换整份配置：

- `sub/oneclick-clash.yaml` — Clash / mihomo 节点项（粘到 `proxies:` 下；mihomo 仅支持 Snell v1–v5，v6 请用 Surge）
- `sub/oneclick-surge.conf` — Surge 节点行（粘到 `[Proxy]` 段；不含 VLESS-Reality：Surge 没有 VLESS 策略类型）
- `sub/oneclick-loon.conf` — Loon 节点行（粘到 `[Proxy]` 段；不含 Snell：Loon 不支持 Snell）
- `sub/oneclick-uri.txt` — 通用 URI 列表，可生成二维码
- sing-box 默认不生成，需要时用 `oneclick --sub --format singbox`

## 构建与测试

```bash
./build.sh
```

按 15 个模块拼成 `dist/oneclick.sh`，并执行四项校验：`bash -n`、`shellcheck -S warning`、
未定义函数扫描（只扫命令位，避免 jq 字段误报）、重复函数定义。改代码只改 `src/`，不要改 `dist/`。

```
src/00-header.sh            常量、协议注册表
src/lib/{os,ui,store,dl,net,cert,svc,share}.sh
src/proto/{vless_reality,hysteria2,snell,ss_rust,anytls}.sh
src/99-menu.sh              菜单、CLI、main
```

每个版本都会先在干净的 Debian 13（trixie）上跑完整验证再推送。

## 致谢

设计参考了 [Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install)、
翠花 Snell.sh、[xOS/Shadowsocks-Rust](https://github.com/xOS/Shadowsocks-Rust)、
[jinqians 一键菜单](https://menu.jinqians.com)、[mozisen/surge](https://github.com/mozisen/surge)。
上游均未声明许可证，本仓库不授予再分发权；运行时组件（Xray、Hysteria、sing-box 等）各自遵循其原始许可。
详见 [NOTICE.md](NOTICE.md)。
