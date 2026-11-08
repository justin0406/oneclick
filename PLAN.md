# 综合一键代理脚本 · 融合方案

> 输入：5 个上游脚本，共 39,229 行（已全部精读，逐脚本拆解见 `research/group1~3-*.md`）
> 产出目标：一个 `代理一键脚本`，单入口菜单统一管理全部协议，单文件可 `bash <(curl ...)` 运行

---

## 一、先看清 5 个脚本的真实关系

| 维度 | hysteria.sh（Misaka） | snell.sh（翠花） | ss-rust.sh（翠花） | menu.jinqians | vless-server.sh（surge） |
|---|---|---|---|---|---|
| 行数 | 594 | 3,165 | 1,927 | 2,103 | **31,440** |
| 抽象层级 | 单协议安装器 | 单协议安装器 | 单协议安装器 | **多协议分发菜单 + 共用库** | **全协议平台** |
| 协议 | Hysteria2 | Snell v2/v3/v4/v5/v6 | SS-Rust + ShadowTLS v3 | Snell 全集（SS/ShadowTLS 只做分发） | 20 key / 15 协议：VLESS-Reality/XHTTP/WS、Vision、VMess-WS、Trojan、SOCKS5、SS2022、SS-legacy、HY2、TUIC、AnyTLS、Naive、Snell v4/v5/v6 + ShadowTLS 组合 |
| 内核 | 官方 hysteria | 官方 dl.nssurge.com | shadowsocks-rust + shadow-tls | 各子脚本 | Xray + Sing-box + 独立进程（snell/anytls/naive/caddy） |
| 证书 | acme.sh HTTP-01 + 必应自签 + 自定义 | 无 | 无 | 无 | acme.sh HTTP-01/**DNS-01(CF/阿里/DNSPod/手动)** + REALITY + 自签 |
| 客户端输出 | hy2 URI + clash-meta.yaml | Surge 单行 | ss:// + 二维码 + Surge 行 | 无 | 链接 + JOIN + **nginx 静态订阅** `/sub/<uuid>/{,clash,surge,v2ray}` |
| 多用户/流量/到期 | 无 | 无 | 无 | 无 | **有**（Xray statsquery / Sing-box grpc / Snell nftables 计数）+ TG bot |
| 系统适配 | Debian/Ubuntu/CentOS/RHEL/Fedora | **Alpine/CentOS/Debian/Ubuntu + OpenRC + glibc shim + 自更新（CN→Gitee）** | Debian/Ubuntu/CentOS | Debian/RHEL/Alpine + Docker 版 | Debian/Ubuntu/CentOS/Alpine × x86_64/aarch64/armv7l |
| 防火墙 | 无 | 无（提示手动） | 无 | **四后端库**（firewalld/ufw/iptables/ip6tables/nftables + 持久化 + 端口占用查询） | 不自动开（提示安全组） |
| 端口跳跃 | **有**（iptables DNAT） | — | — | — | 有（hy2 hop_start/end，iptables REDIRECT） |
| 多版本共存 | — | 有（v2~v6 逐版装/切） | — | **通道模型**（版本化二进制 + 软链 + 每实例 unit + 配置内标记） | 有（Xray/Sing-box stable+prerelease、snell v4/v5/v6） |
| 更新机制 | 无（每次现拉外部安装脚本，无校验） | 有（自更新 + Gitee 兜底） | 有（GitHub API 查版本） | 启动即 `bash <(curl)` 自安装 | 有（自更新 + 备份 + 回退） |

**结论 1：不是"5 个平级脚本的合并"，而是"1 个平台 + 1 个架构样板 + 3 个能力插件"。**
surge 已是功能超集，jinqians 是唯一有共用库分层思想的架构参考，snell 有最好的系统适配/下载事务，ss-rust 有 ShadowTLS 与输出格式，hysteria 有证书与端口跳跃。

**结论 2：直接拼接会立刻踩三类冲突。**
- 代码层：3 套颜色函数、3 套包管理器识别、4 套端口检测、2 套 systemd 管理、5 套菜单循环；
- 路径层：`/etc/snell`、`/etc/ss-rust`、`/etc/shadowtls`、`/etc/hysteria`、`/etc/vless-reality` 各自为政，unit 名互不相干；
- 行为层：hysteria 用 `iptables -t nat -F PREROUTING` 清空整表（会打掉 Docker 转发）、`chmod -R 777 /root`；ss-rust 有三重权限冲突（`User=root` + `DynamicUser=true` + config `user:"nobody"`）；两处 `[[ !"$status" == "running" ]]` 语法错永假。

**结论 3：5 个脚本均无 LICENSE 声明。** 融合产物建议定位"个人自用 / 内部 fork"，保留原作者署名（Misaka、翠花、jinqians、Zyx0rx）与来源链接；不公开分发、不商用。

---

## 二、三条路线（选一条）

### 路线 A：surge 基座 + 补丁（1 个文件，~1.3 MB）
把 vless-server.sh 当唯一主干，往 10 个接入点里塞另外 4 个脚本的独有能力（hy2 必应自签证书、Snell 逐版本管理、ss-rust ShadowTLS 参数、防火墙自动放行）。
- ✅ 功能立刻最全，代码已在跑，风险最低
- ❌ 31k 行 monolith / 678 函数，无模块边界；新协议要改 10 处；后续任何修改都是"外科手术"
- 工期：2~3 天

### 路线 B：新框架 + 协议驱动（推荐）
新写统一框架（~1,800 行），协议按固定契约接入；源码分模块，`build.sh` 合并为单文件产物。
- ✅ 可维护、可 shellcheck、可按需裁剪；后续加协议只写 1 个文件
- ❌ 工作量最大；需自建测试
- 工期：P0 3~5 天 + P1 3 天 + P2 3 天

### 路线 C：薄封装总入口（过渡方案）
写一个总菜单，下载并 `exec` 上游 5 个脚本。
- ✅ 1~2 小时，风险最低
- ❌ 不算融合，界面不统一，仍受 GitHub 直连影响，端口/路径冲突无治理
- 适合：只想先有个统一入口

> **推荐：路线 B，但协议实现从 surge 抽（它已跑通全部协议），框架层重写（借 jinqians 分层 + snell 系统适配）。**
> 理由：你的目标是"综合脚本"而不是"又一个 3 万行 fork"；三个单协议脚本真正的价值是**方法论**（证书、端口跳跃、多版本、ShadowTLS 参数），不是代码量。

---

## 三、路线 B 的工程规格

### 3.1 产物与源码结构
```
proxy-suite/
├─ build.sh                # 合并 src/ → dist/px.sh，构建期 bash -n + 未定义函数扫描
├─ src/
│  ├─ 00-header.sh         # 常量、版本、目录规范
│  ├─ lib/os.sh            # 系统识别、包管理器抽象、依赖安装
│  ├─ lib/ui.sh            # 颜色/日志/菜单框架/二维码/表格
│  ├─ lib/dl.sh            # 统一下载器（镜像前缀 + SHA256 + 重试 + 回滚）
│  ├─ lib/net.sh           # IP 探测、端口占用、防火墙四后端、BBR/TFO、端口跳跃
│  ├─ lib/cert.sh          # acme.sh HTTP-01/DNS-01、自签、REALITY 密钥、续期
│  ├─ lib/svc.sh           # systemd 单后端（start/stop/enable/status/log）
│  ├─ lib/store.sh         # db.json + jq + flock；端口登记表
│  ├─ lib/share.sh         # URI / Clash / Surge / Sing-box 片段 + 订阅文件生成
│  ├─ proto/*.sh           # 每协议一文件，实现 6 个固定函数
│  └─ 99-menu.sh           # 一级/二级菜单装配
└─ dist/px.sh              # 最终单文件产物（目标 P0 ≈ 3,000~3,500 行）
```
> 为什么不学 jinqians 的"纯拼接"：它的发布物已出现断引用（`snell_download_url_for` 等全仓无定义）和 ~500 行有实现无调用的死代码，`bash -n` 抓不到未定义符号。所以 build.sh 必须加**未定义函数扫描**（提取所有 `xxx(` 调用与 `xxx()` 定义做差集）。

### 3.2 统一目录与命名（前缀 `px`）
| 项 | 规范 |
|---|---|
| 根配置 | `/etc/px/`（600），`/etc/px/db.json` 全局状态 |
| 协议配置 | `/etc/px/<proto>/`（如 `/etc/px/hy2/config.yaml`） |
| 证书 | `/etc/px/certs/{<domain>,hy2,tuic}/` |
| 订阅产物 | `/etc/px/sub/<uuid>/{,clash,surge,singbox}` |
| 二进制 | `/usr/local/bin/{xray,snell-server,ssserver,shadow-tls,anytls-server,hysteria}`（P0 不引入 sing-box），重版本号共存 + 软链 |
| systemd | `px-vless-reality.service`、`px-hysteria2.service`、`px-snell.service`、`px-ss-rust.service`、`px-anytls.service`（每协议单实例，unit = px-<key 下划线换连字符>） |
| 日志 | journald 为主，`/var/log/px/*.log` 兜底 |
| 端口登记 | `/etc/px/ports.tsv`（协议/端口/单位/创建时间），安装前查 `ss -ltnp` 与登记表双检 |

**旧安装物处理**：启动时探测 `/etc/{snell,ss-rust,shadowtls,hysteria,vless-reality}`，命中则提示"发现旧脚本安装，建议先卸载或本脚本仅并存（不改其文件）"，P0 只做**检测 + 端口避让**，不做接管迁移。

**五协议的端口/证书协调（P0 必须先定死）**

| 协议 | 端口策略 | 证书 | 备注 |
|---|---|---|---|
| VLESS-Reality | **443（主协议，独占）** | 不需要证书，用 REALITY dest + 自生成 x25519 密钥 | 与 AnyTLS 的 TLS 端口互斥；443 被占则安装时提示 |
| AnyTLS | 高位端口（默认 8443 段） | **脚本自主签发**：已有证书 / ACME / 自签三选一 | 服务端用 **sing-box**（anytls-go 不支持自定义证书）；客户端 Surge/Loon/sing-box/mihomo 均支持 |
| Hysteria2 | UDP 单端口或端口跳跃段 | 自签（必应）或 acme | 跳跃规则带自有 comment，只增删自己 |
| Snell v6 | TCP 高位端口 | 无 | PSK 20 位、长度 16~255；obfs 默认关 |
| SS-Rust | TCP+UDP 端口 | 无（开 ShadowTLS 才需 TLS 证书） | ShadowTLS 为安装时开关，默认关 |

### 3.3 菜单树（一级 7 项）
```
1) 安装协议        VLESS-Reality / Hysteria2 / Snell v6 / SS-Rust（ShadowTLS 可选开关）/ AnyTLS
                   （后续批次：VLESS-WS / VMess-WS / Vision / SS2022 / TUIC / Naive / SOCKS5）
2) 节点管理        状态 / 启停 / 改端口·密码 / 分享链接 / 二维码 / 删除
3) 证书管理        ACME HTTP-01 / DNS-01(CF·阿里·DNSPod) / 自签 / REALITY 密钥 / 续期状态
4) 订阅服务        开关 / 端口 / 路径 / 格式（base64·clash·surge·sing-box）/ 重新生成
5) 系统工具        依赖安装 / 防火墙放行 / BBR+TFO / 端口占用查询 / 镜像源设置 / IP 变更检测
6) 备份与恢复      全量备份、导出、恢复、卸载（含 daemon-reload + unit 清理）
7) 更新            脚本自更新、内核多版本管理（Xray/Sing-box/snell/…）
0) 退出
（多用户/流量/到期/TG 通知：已明确不做，不入菜单）
```
非交互 CLI（surge 缺这块，必须补）：
`px.sh --install <proto> --port N --domain D --yes`、`--list`、`--status [--json]`、`--link <proto> [--format uri|clash|surge]`、`--uninstall <proto>`、`--check-ip`、`--sync-traffic`。

### 3.4 证书能力（lib/cert.sh，AnyTLS / Reality / 未来 TLS 协议共用）
```bash
cert_ensure <domain|sni> [mode=existing|acme|self]   # 交互式三选一，返回 CERT_PATH/KEY_PATH/SNI
cert_acme   <domain>      # acme.sh HTTP-01；80 被占时自动降级 webroot 或提示切 DNS-01
cert_self   <sni>         # openssl EC prime256v1 + SAN + 36500d + key 600（强制重签，避免旧 SAN 不匹配）
cert_detect <crt>         # 从已有证书反查 SAN/CN 作为默认 SNI
cert_reuse  <domain>      # 同域名且剩余 >30 天则复用，否则重签（acme 自带续期）
reality_keypair           # x25519 私钥/公钥对，写入 db，客户端链接用
```
**规则**：证书缺失时**不静默生成**（surge 的正确做法）；安装 AnyTLS 必须走完证书步骤才允许写配置。

### 3.5 协议接入契约（新增协议只改 1 个文件 + 1 行注册）
```bash
proto_meta()      # → 名称、内核、依赖、默认端口、是否支持多用户
proto_install()   # 采集参数 → 生成配置 → 建 unit → 起服务 → 登记 db/端口 → 防火墙放行
proto_uninstall() # 停服务、删 unit、daemon-reload、清配置（可保留证书）
proto_link()      # → URI / Clash / Surge / Sing-box 片段
proto_status()    # → 运行态、端口、版本、流量（可选）
proto_regen()     # 改端口/密码/证书后重生成配置并热重启
```

### 3.6 复用来源映射（谁的东西用在哪）
| 能力 | 取自 | 处理方式 |
|---|---|---|
| 系统识别 / 包管理器 / 下载校验 | jinqians `lib/common.sh` | 重写并补 `apk`、补 SHA256 强制 |
| 防火墙四后端 + 持久化 + 端口占用 | jinqians `lib/firewall.sh` | **原样移植**，但在安装流程前置阻断占用端口 |
| 通道/多版本共存模型 | jinqians `lib/channels.sh` + snell 版本化二进制 | 泛化为所有协议通用 |
| systemd/OpenRC 双后端 | snell `initServiceMgr` | 重写为 `svc.sh` 统一接口 |
| 下载-备份-替换-失败回滚事务；配置写入保留自定义键 | snell `installSnellArchive` / `writeConfig` | 提炼进 `lib/dl.sh` + `lib/store.sh` |
| ACME / 必应自签 / 自签 | hysteria `inst_cert` + surge DNS-01 四家 | 合并为 `lib/cert.sh` |
| 端口跳跃 | hysteria iptables DNAT | 改造成带自有 comment 的规则（只增删自己的），兼容 nft |
| 15 协议实现细节 | surge（已跑通） | 按契约重写/摘取，单协议脚本作对照补强 |
| AnyTLS | surge（`configure_anytls_certificate`/`gen_anytls_link`） | 服务端 **sing-box 1.14.4**（`type: anytls` inbound，支持 certificate_path/key_path；anytls-go 服务端不能用自定义证书）；**证书三模式**：已有 / ACME / 自签（EC prime256v1 + SAN + 36500 天 + key 600）；链接 `anytls://password@ip:port?sni=..`（自签才带 insecure=1）+ Surge/Loon 原生节点行 |
| Snell v6 | surge + snell.sh | **官方正式版 6.0.0 已发布**（实测 `dl.nssurge.com/snell/snell-server-v6.0.0-linux-amd64.zip` 返回 200；snell.sh 内置的 6.0.0rc2 已过时），PSK 需 20 位且长度 16~255 |
| ShadowTLS v3 参数与 dispatch | ss-rust | 移入 `proto/ss-rust.sh` |
| 分享链接 / 订阅 | surge `gen_*_link` + ss-rust `ss://`+二维码 + hysteria clash 模板 | 重写为 `lib/share.sh`，修掉 surge 的缺口（Clash 缺 Snell/naive/socks、Surge.conf 缺 VLESS 全家桶） |
| 多用户/流量/到期/TG bot | surge | **不采用**（已定：脚本保持单用户轻量） |

**P0 内核依赖**：`xray`（VLESS-Reality）+ `hysteria`（HY2 官方二进制）+ `snell-server-v6` + `ss-rust`（+ `shadow-tls`）+ **`sing-box`（仅 AnyTLS 用）**。原计划 AnyTLS 走 anytls-go 以免引入 sing-box，但 anytls-go 服务端不支持自定义证书（见决策记录），为满足"脚本自主签发证书"改用 sing-box 的 anytls inbound。

### 3.7 质量与安全基线（针对上游踩过的坑）
1. 禁止 `chmod -R 777`、禁止清空整张 iptables 表；配置/凭据文件 600。
2. 所有下载走 `dl.sh`：镜像前缀可配（`PX_GH_PROXY`，应对 GitHub 直连 403）、SHA256 校验、失败回滚。
3. systemd：`Restart=on-failure`、`LimitNOFILE=32767`、`After=network-online.target`。
4. 卸载必须 `daemon-reload` + 删 unit + 删备份二进制（snell/ss-rust 都漏了）。
5. 安装幂等：已装检测、端口冲突检测、重复执行不叠加防火墙规则。
6. 不在菜单启动时联网（snell 每次进菜单查版本）；版本检查走手动或后台异步。
7. CI/构建期：`bash -n` + shellcheck + 未定义函数扫描 + 各模块单独 `source` 冒烟。

### 3.8 分期与验收
| 阶段 | 内容 | 规模 | 工期 |
|---|---|---|---|
| **P0** | 框架 7 个 lib + 5 协议（VLESS-Reality、Hysteria2、Snell v6、SS-Rust+ShadowTLS 可选、AnyTLS）+ 证书 + 分享/二维码 + 卸载/备份 + 端口治理 | ~2,500 行 | 3~4 天 |
| P1 | 其余协议（VLESS-WS/VMess-WS/Vision/SS2022/TUIC/Naive/SOCKS5）+ 内建订阅 HTTP + 内核多版本管理 | +1,200 行 | 2~3 天 |
| P2（可选） | Docker 版、分流/CF Tunnel/Realm | +800 行 | 2 天 |

**P0 验收**：Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 / Rocky 9（CentOS 兼容）——全新机一键装 5 协议；重启后自启；v2rayN、Clash Verge、Surge 三端导入链接成功；卸载无残留；同协议重复安装幂等；无防火墙/端口残留。测试由你在测试 VPS 执行（我交付 `TEST.md` 逐条命令 + 回传日志，我据此修）。

---

## 四、风险（按影响排序）
1. **本机无法直接验证**：目标是 Linux，测试链路为「我写 → 你在测试 VPS 跑 `TEST.md` → 回传日志 → 我修」。往返轮次是主要时间变量，建议一台干净 Debian 12 或 Ubuntu 24.04，允许重装/快照。
2. **上游无 LICENSE**：仅自用/内部 fork，保留署名与来源，不公开分发。
3. **GitHub 直连**：国内 VPS 拉内核会超时/403，镜像前缀与"内核自托管"必须内置，不能事后补。
4. **443 唯一性**：VLESS-Reality 与 AnyTLS 的 TLS 端口互斥，必须明确"主协议（Reality 占 443）"概念并做互斥提示。
5. **单文件 3,000+ 行**：靠 build 期校验与分区规范维持可维护性；不追求 1 万行级"全家桶"。
6. **工期**：P0 约 3~4 个工作日（不含 VPS 测试往返）；后续每加一个协议约 150~300 行。

---

## 五、决策记录（已定，2026-11-08）
| 项 | 决定 | 影响 |
|---|---|---|
| 路线 | **B 新框架 + 协议驱动** | 产物单文件，源码分模块 + build.sh 校验 |
| 首版协议 | **P0 五个**：VLESS-Reality、Hysteria2、Snell **v6**、SS-Rust（ShadowTLS 可选）、**AnyTLS**（替换原 Trojan 方案） | 覆盖主流客户端 + 抗探测组合 |
| 系统 | **Debian/Ubuntu 优先，CentOS 兼容**；不做 Alpine | 系统层只做 apt/dnf/yum + systemd，砍掉 OpenRC/glibc shim，省 1~2 天 |
| 多用户体系 | **不做，永远不做** | 砍掉 lib/user.sh、用户菜单、P2 移植，省 2~3 天 |
| 测试 | **用户提供测试 VPS 自跑** | 交付 `TEST.md`（逐条命令 + 预期输出 + 日志回传模板）；我按日志修 |
| AnyTLS 客户端 | **Surge、Loon 均支持**（另有 sing-box/mihomo） | 链接按 `URI` + `Surge/Loon 节点行` 双格式输出，不标"客户端受限" |
| AnyTLS 证书 | **脚本自主签发，不是只复用** | 安装流程内置三选一（已有/ACME/自签）；证书缺失不静默生成 |
| AnyTLS 服务端 | **sing-box**（非 anytls-go） | anytls-go 服务端 TLS 为进程内临时证书、无证书参数，无法支持自主签发；sing-box anytls inbound 支持 certificate_path/key_path，唯一能同时满足"AnyTLS + 自主证书"的实现 |

**范围变更后的净效果**：P0 约 2,600 行，总工期 3.5~4.5 天（不含你在 VPS 上跑测试的往返时间）。
