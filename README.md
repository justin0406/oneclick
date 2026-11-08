# PX —— 综合一键代理脚本（P0）

把 5 个上游单协议脚本融合成一个脚本：**一个入口、一套状态库、一套证书体系、一套订阅/卸载**。
自用定位，单用户，**不做多用户 / 流量统计 / 到期 / Telegram**。

- 运行环境：Debian 13 / Ubuntu 22.04+ 优先，CentOS Stream / RHEL 9 兼容（systemd）
- 架构：x86_64 / aarch64 / armv7l（AnyTLS 的 sing-box 无 i386）
- 产物：`dist/px.sh` 单文件（约 6000 行），无二次下载依赖

## 两条命令开始

```bash
# 上传 dist/px.sh 后
bash px.sh          # 首次运行会自动装成 /usr/local/bin/px，然后进菜单
px                  # 以后直接用
```

常用非交互命令：

```bash
px --install hysteria2 --port 8443 --cert-mode self --yes
px --install vless_reality --port 443 --yes
px --install anytls --port 8443 --cert-mode self --yes
px --install snell --port 12345 --yes
px --install ss_rust --port 8388 --yes          # 默认不开 ShadowTLS

px --status                      # 表格
px --status --format json        # 机器可读
px --link hysteria2              # URI
px --link snell --format surge   # 单协议客户端片段
px --uninstall snell --yes
```

## 协议与依赖

| 协议 | 内核 | 端口 | 证书 | 备注 |
|---|---|---|---|---|
| VLESS-Reality | xray-core | 443 独占 | 不需要（REALITY + x25519） | 抗主动探测最强，建议主协议 |
| Hysteria2 | hysteria 官方 | UDP 高位（可端口跳跃） | 自签 / ACME / 已有 | salamander 混淆可选，默认关 |
| Snell v6 | snell-server-v6 | TCP 高位 | 不需要 | PSK 20 位；obfs 在 v6 已由 mode 取代 |
| SS-Rust | ssserver（+ shadow-tls） | TCP+UDP | 仅开 ShadowTLS 时需要 | SS2022 优先；ShadowTLS 默认关 |
| AnyTLS | sing-box 1.14.4 | TCP 高位 | **必须**自签 / ACME / 已有 | 见下方「为什么 AnyTLS 用 sing-box」 |

## 目录与状态

```
/etc/px/
├── db.json              # 唯一状态库（jq 原子写 + flock）
├── certs/<name>/        # cert.pem + key.pem（600）
├── sub/                 # px-clash.yaml / px-surge.conf / px-singbox.json / px-uri.txt
└── <协议 key>/          # 各协议配置（600）
/usr/local/bin/px        # 入口
/usr/local/bin/{xray,hysteria,snell-server,ssserver,sing-box}
/etc/systemd/system/px-<协议>.service
```

## 关键设计决策

1. **协议驱动**：每个协议实现同一套 9 个函数（`meta/install/uninstall/status/link/regen/clash/surge/singbox`），菜单与订阅层不认协议，只遍历注册表。加协议 = 加一个文件 + 注册 key。
2. **证书自主签发**：`existing` / `acme`（acme.sh HTTP-01）/ `self`（EC P-256 + SAN + 100 年）三选一，证书缺失**绝不静默生成**；装 AnyTLS 必须先过证书步骤。
3. **不做破坏性系统操作**：不 `chmod -R 777`、不清空 iptables 整表；防火墙只增删带 `px-*` comment 的规则，nft 用独立 `inet px` 表。
4. **下载统一走 `dl_*`**：3 次重试 + 可选镜像前缀（`PX_GH_PROXY`/菜单里配 gh_proxy）+ SHA256（有则校验）+ 原子替换。
5. **卸载干净**：`svc_remove` 一律 stop + disable + 删 unit + daemon-reload（修掉上游只 disable 不删 unit 的 bug）。
6. **为什么 AnyTLS 用 sing-box**：参考实现 anytls-go 的服务端**不接受用户证书**（`cmd/server/main.go` 只有 `-l/-p/-padding-scheme`，TLS 是进程内 `util.GenerateKeyPair` 生成的 1 小时临时 RSA，无 SAN）。要满足「AnyTLS 证书也由脚本自主签发」，只能改用支持 `certificate_path/key_path` 的 sing-box anytls inbound。代价是多一个 ~30 MB 二进制；链接在自签时自动带 `insecure=1` / `skip-cert-verify=true`，ACME/已有证书时不带。

## 构建

```bash
./build.sh
```

按 15 个模块拼成 `dist/px.sh`，并做 4 项校验：`bash -n`、`shellcheck -S warning`、未定义函数扫描（只扫命令位，避免 jq 字段误报）、重复函数定义。改代码只改 `src/`，不要改 `dist/`。

```
src/00-header.sh      常量、协议注册表
src/lib/{os,ui,store,dl,net,cert,svc,share}.sh
src/proto/{vless_reality,hysteria2,snell,ss_rust,anytls}.sh
src/99-menu.sh        菜单 + CLI + main
```

## 测试

Debian 13 上的逐条测试清单见 [TEST.md](TEST.md)（安装、5 协议冒烟、reboot 自启、幂等与端口冲突、订阅、备份恢复、卸载残留、日志回传模板）。

## 上游与署名

融合自：Misaka-blog/hysteria-install（HY2）、翠花 Snell.sh、xOS/Shadowsocks-Rust、jinqians 一键菜单（分层思路）、mozisen/surge（多协议与订阅）。五个上游均未声明 LICENSE，本脚本按**自用 fork** 处理，保留上游署名与来源说明，不用于分发售卖。上游清单、各运行时组件的许可证与本仓库的授权边界见 [NOTICE.md](NOTICE.md)。
