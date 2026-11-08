# PX 实施契约（P0 权威文档 v1）

> 本文件是并行开发的**唯一同步基准**。任何函数名、变量名、文件路径、返回约定以本文件为准。
> 与 PLAN.md 冲突时，以本文件为准（PLAN 是设计意图，SPEC 是编码契约）。

## 0. 全局约束

- 目标平台：**Debian 12/13、Ubuntu 22.04/24.04 优先**；CentOS/RHEL 8+ 尽力兼容（apt + dnf/yum 两条包管理路径）。
- **不做** Alpine/OpenRC、不做多用户/流量/到期/TG。
- Bash ≥ 4.1（Debian 10+ 自带 5.x）。**不用** bash5-only 特性（`${var@Q}` 等）。
- 不写 `set -e`（交互脚本 + 菜单会误退）。局部命令用 `if !`。
- 所有可变全局以 `PX_` 开头；所有公共函数以模块前缀开头：`os_ ui_ db_ dl_ net_ cert_ svc_ share_`，协议内部私有函数以 `pxp_<key>_` 开头。
- 统一用 4 空格缩进，`[[ ]]` 不写 `[ ]`，字符串比较 `==`。
- 所有新增/覆盖的配置文件 `chmod 600`；脚本开头 `umask 077`。
- **禁止**：`chmod -R 777`、`iptables -F`、`iptables -t nat -F`、`rm -rf /`、`eval` 用户输入。
- 输出中文（用户母语），标识符英文。

## 1. 目录与常量（src/00-header.sh 定义）

```bash
PX_VERSION="0.1.0"
PX_ROOT="/etc/px"
PX_DB="$PX_ROOT/db.json"
PX_CERT_DIR="$PX_ROOT/certs"
PX_SUB_DIR="$PX_ROOT/sub"
PX_LOG_DIR="/var/log/px"
PX_BIN_DIR="/usr/local/bin"
PX_ENTRY="$PX_BIN_DIR/px"
PX_UNIT_DIR="/etc/systemd/system"
PX_OS_ID / PX_OS_VER / PX_ARCH      # os_detect 后写入
PX_YES="${PX_YES:-0}"              # 1 = 非交互，全部默认值/自动确认
PX_ARG_PORT / PX_ARG_DOMAIN / PX_ARG_SNI / PX_ARG_CERT_MODE   # CLI 透传
```

协议注册表（也放 00-header.sh，必须在 src/proto/*.sh 之前定义）：
```bash
PX_PROTOS=(vless_reality hysteria2 snell ss_rust anytls)
declare -A PX_PROTO_TITLE=(
  [vless_reality]="VLESS-Reality" [hysteria2]="Hysteria2" [snell]="Snell v6"
  [ss_rust]="SS-Rust" [anytls]="AnyTLS"
)
declare -A PX_PROTO_ORDER=([vless_reality]=10 [hysteria2]=20 [snell]=30 [ss_rust]=40 [anytls]=50)
```

命名派生（统一函数，别自己拼）：
```bash
px_unit_name <key>     # vless_reality -> px-vless-reality
px_proto_dir <key>     # -> /etc/px/vless_reality
```
> key 一律下划线，unit / 目录里的显示用连字符（目录也用下划线，保持一致）。

## 2. lib/ui.sh —— 输出与交互

```bash
px_info <msg>            # [*] 青色
px_ok   <msg>            # [✓] 绿色
px_warn <msg>            # [!] 黄色
px_err  <msg>            # [✗] 红色（stderr）
px_die  <msg> [code=1]   # 红字后 exit
px_hr                    # 分隔线
px_title <msg>           # 带框标题

px_confirm <prompt> [default=y|n]        # 返回 0/1；PX_YES=1 时直接按 default
px_ask <prompt> <default>                # stdout 输出用户输入（空则 default）
px_ask_secret <prompt>                   # 不回显输入
px_menu <title> <item1> <item2> ...      # 打印编号菜单并读取选择，stdout 输出编号(1..N)
px_pause                                 # "按回车继续"；PX_YES 时直接返回
px_kv <k> <v>                            # 对齐的 key: value 一行
```

## 3. lib/store.sh —— 状态库

状态文件 `/etc/px/db.json`，结构为**扁平的按协议对象**，只允许一层 key：
```json
{
  "installed": ["hysteria2","snell"],
  "settings": {"gh_proxy":"","ip":"1.2.3.4","ip_updated":"2026-11-08T12:00:00Z"},
  "hysteria2": {"port":"8443","tls_mode":"self","tls_cert":"/etc/px/certs/...","tls_key":"...","sni":"bing.com","hop":"20000-30000","created":"..."},
  "snell": {"port":"12345","psk":"...","version":"6.0.0"}
}
```

```bash
db_init                                  # 建 PX_ROOT、db.json 若缺；umask 600
db_get   <section> <key> [default]       # stdout；不存在输出 default
db_set   <section> <key> <value>         # 字符串
db_setn  <section> <key> <number>        # 数字
db_del   <section> <key>
db_has   <section> [key]                 # 有 section（或 section.key）返回 0
db_section_json <section>                # 输出该 section 的 json（不存在输出 {}）
db_mark_installed <key> / db_unmark_installed <key> / db_is_installed <key>
db_setting <key> [value]                 # 读/写 settings.*
db_lock / db_unlock                      # flock 包装；所有写操作内部自动加锁
```
实现要求：全部用 `jq` 原子写（写临时文件再 `mv`），写前 `flock`，写后仍是 600。

## 4. lib/os.sh —— 系统

```bash
os_detect                                # 写 PX_OS_ID/PX_OS_VER/PX_ARCH（amd64|arm64|armv7l|i386）
os_pkg_install <pkg...>                  # apt/dnf/yum 自动；已装则跳过
os_pkg_has <pkg>
os_dep_install <features...>             # features: base curl jq openssl qrencode unzip tar socat acme
os_service_reload                        # systemctl daemon-reload
os_random_token <len>                    # 字母数字（无易混字符 0O1lI）
os_random_hex <bytes>
os_uuid
os_now                                   # ISO8601 UTC
px_require_root
px_require_cmd <cmd...>
```

## 5. lib/dl.sh —— 下载

```bash
dl_fetch <url> <out> [sha256]            # 3 次重试；先直连再镜像；sha256 不符则删文件失败
dl_gh <owner/repo> <tag|latest> <asset> <out>   # GitHub Release 下载，自动走镜像
dl_latest_tag <owner/repo>               # stdout 版本号（去 v 前缀）；失败输出空
dl_unzip <zip> <destdir>
dl_untar <tar> <destdir>
dl_mirror_url <url>                      # 按 settings.gh_proxy 加前缀
```
镜像前缀优先级：`PX_GH_PROXY` 环境变量 > `db_setting gh_proxy` > 空（直连）。

## 6. lib/net.sh —— 网络/防火墙/加速

```bash
net_primary_ip                           # 公网 IPv4（多源兜底），失败输出空
net_port_in_use <port> <tcp|udp>         # 0=占用
net_port_pick <start_hint> <tcp|udp>     # 从 hint 起找空闲端口，stdout
net_fw_allow <port> <tcp|udp> [comment]  # comment 默认 px-<caller>
net_fw_deny  <port> <tcp|udp> [comment]
net_fw_backend                           # nft|iptables|firewalld|ufw|none
net_fw_status                            # 打印后端与规则数量
net_bbr_status / net_bbr_enable
net_tfo_status / net_tfo_enable
net_nat_hop_add <key> <port_start> <port_end> <target_port>   # UDP DNAT 端口跳跃
net_nat_hop_del <key>                                         # 只删自己 comment 的规则
net_nat_hop_show <key>
```
防火墙硬规则：只增删 `comment px-*` 的规则；删除用 `-m comment --comment` 精确匹配；nft 用 table `inet px`。

## 7. lib/svc.sh —— systemd

```bash
svc_create <unitname> <execstart> <description> [extra_unit_lines...]
svc_start/stop/restart <unitname>
svc_enable/disable <unitname>
svc_remove <unitname>                    # stop + disable + rm unit + daemon-reload
svc_status <unitname>                    # active|inactive|failed|not-found
svc_is_active <unitname>
svc_logs <unitname> [lines=30]
svc_write <unitname> <content>           # 原样写 unit（高级用）
```
unit 模板：`After=network-online.target`、`Wants=network-online.target`、`Restart=on-failure`、`RestartSec=3`、`LimitNOFILE=32767`、`User=root`。

## 8. lib/cert.sh —— 证书

```bash
cert_ensure <sni-hint> [mode]            # 设置全局 CERT_PATH/KEY_PATH/SNI；mode=existing|acme|self 可省（交互）
cert_detect <crt>                        # stdout 主域名（SAN 第一个 / CN）
cert_self <sni> <outdir>                 # EC prime256v1 + SAN + 36500d + key 600；强制重签
cert_acme <domain> <outdir>              # acme.sh --issue -d；HTTP-01 失败提示切 DNS-01
cert_reuse <domain> <outdir>             # 剩余 >30 天复用，stdout 0=复用 1=需重签
cert_status                              # 打印各证书到期天数
reality_keypair <outfile>                # 写 JSON {"privateKey":"","publicKey":""}（xray x25519）
cert_fingerprint <crt>                   # SHA256 pin（订阅/客户端用）
```
规则：证书目录 `/etc/px/certs/<name>/`，文件固定 `cert.pem` + `key.pem`。缺失时**绝不静默生成**，必须走 cert_ensure。

> **实现注记（2026-11-09 核实）**：AnyTLS 的参考服务端 anytls-go **不吃用户证书**——`cmd/server/main.go` 只有 `-l/-p/-padding-scheme` 三个 flag，TLS 由 `util.GenerateKeyPair` 进程内生成临时 RSA（CN 空、1 小时、无 SAN）。因此 AnyTLS 服务端改用 **sing-box**（`type: anytls` inbound，支持 certificate_path/key_path），版本钉 `PX_SINGBOX_VER=1.14.4`。这样"脚本自主签发证书"对 AnyTLS 才真正成立；客户端链接在自签时带 `insecure=1`/`skip-cert-verify=true`，ACME/已有证书时不带。

## 9. lib/share.sh —— 分享与订阅

```bash
share_uri_epoch                          # 不用
share_render_uri  <key>                  # 调 proto_<key>_link
share_render_clash [outfile|stdout]      # 遍历已装协议，调 proto_<key>_clash
share_render_surge [outfile|stdout]      # 同上 proto_<key>_surge
share_render_singbox [outfile|stdout]    # 同上 proto_<key>_singbox
share_render_sub <format>                # 生成 /etc/px/sub/px-<format>.<ext>，返回路径
share_qr <text>                          # 终端二维码（qrencode 缺失则打印文本）
share_print_links <key>                  # 打印 URI + 三种订阅片段 + 二维码
```
订阅产物命名：`/etc/px/sub/px-clash.yaml`、`px-surge.conf`、`px-singbox.json`、`px-uri.txt`。

## 10. 协议契约（src/proto/<key>.sh 必须实现的 9 个函数）

函数名严格为 `proto_<key>_<suffix>`，key 见 §1。

| 函数 | 职责 |
|---|---|
| `proto_<key>_meta` | 打印 5 行 `k=v`：`title=` `desc=` `port=` `udp=yes|no` `cert=yes|no` |
| `proto_<key>_install` | 完整安装（依赖→参数→配置→unit→启动→防火墙→db） |
| `proto_<key>_uninstall` | 停止→删 unit→删二进制（可选）→删配置→撤防火墙→db 清理 |
| `proto_<key>_status` | 打印单行状态：`运行中 pid=.. port=..` / `已停止` / `未安装` |
| `proto_<key>_link` | 打印分享链接（URI 为主，多条用换行） |
| `proto_<key>_regen` | 从 db 重写配置 + 重启（改端口/密码后调用） |
| `proto_<key>_clash` | 打印 Clash `proxies:` 下的一个列表项（yaml） |
| `proto_<key>_surge` | 打印 Surge conf 的一行节点 |
| `proto_<key>_singbox` | 打印 sing-box outbound 的 JSON 对象 |

安装函数必须遵守：
1. 先 `db_has <key>` 判重（已装则提示"重新安装/取消"，PX_YES 时直接失败退出）。
2. 端口来自 `PX_ARG_PORT` → `proto_<key>_meta` 的 port → 交互询问；装前 `net_port_in_use` 检查，占用则报错并建议 `net_port_pick`。
3. 需要证书的：先 `cert_ensure`，失败则中止，**不得写半截配置**。
4. 下载全部走 `dl_*`，二进制落 `/usr/local/bin/`，`chmod 755`。
5. 配置写 `proto_dir` 下，600；写前 `mkdir -p`。
6. `svc_create` + `svc_enable --now` 等价操作（enable 后 start），起来后 `sleep 1` 校验 `svc_is_active`，失败则打印 `svc_logs` 并 `px_die`。
7. 成功后 `db_set <key> ...` 各字段 + `db_mark_installed`，最后 `db_setting ip "$(net_primary_ip)"`。
8. 全部幂等：重复执行不叠加防火墙规则（先 deny 再 allow 或查 comment 存在）。

## 11. 单文件装配顺序（build.sh）

```
00-header.sh
lib/os.sh  lib/ui.sh  lib/store.sh  lib/dl.sh
lib/net.sh lib/cert.sh lib/svc.sh lib/share.sh
proto/vless_reality.sh proto/hysteria2.sh proto/snell.sh proto/ss_rust.sh proto/anytls.sh
99-menu.sh     # 含 main()，最后一行 main "$@"
```
每段前加 `# ===== src/<path> =====` 注释便于定位。

build.sh 校验：
1. `bash -n dist/px.sh`
2. `shellcheck -S warning`（存在才跑）
3. **未定义函数扫描**：取 `\b(px|proto|db|dl|os|net|cert|svc|share)_[a-z0-9_]+` 所有 token，减去定义集合，有残留即失败。
4. 重复函数定义检测。
5. 产物 `chmod 755`，打印行数与 sha256。

## 12. CLI（99-menu.sh 的 main）

```
px                      # 菜单
px --install <key> [--port N] [--domain D] [--sni S] [--cert-mode M] [--yes]
px --uninstall <key> [--yes]
px --regen <key>
px --link <key> [--format uri|clash|surge|singbox|qr]
px --status [--json]
px --list
px --cert-status
px --check-ip
px --version | --help
```
参数解析后置 `PX_YES=1` 供各函数读取；未知参数 `px_die`。

## 13. 编码纪律（子代理必读）

- 只用本文件和已存在 lib 里的函数；**缺函数就在报告里提出**，不要自己在 proto 文件里重造 `log()`、`download()`、`systemctl` 包装。
- 协议私有函数一律 `pxp_<key>_` 前缀，不得污染公共命名空间。
- 每个文件末尾不留 `main` 调用；唯一入口是 99-menu.sh。
- 写完后自检：`bash -n src/<file>.sh`、函数清单与契约逐条对齐。
- 注释写"为什么"，不写"是什么"；不写大段 ASCII 艺术字。
- **db 字段名禁用公共前缀**：`px_ proto_ db_ dl_ os_ net_ cert_ svc_ share_ pxp_` 开头的字段名会被 build.sh 的未定义函数扫描当成函数调用。TLS 相关字段统一用 `tls_mode` / `tls_cert` / `tls_key` / `tls_sni`，不使用 `cert_*`。
- 注释里也不要写 `proto_${key}_install`、`cert_ensure` 这类完整调用名（扫描按命令位判断，注释中的裸 token 一般不会命中，但别在注释里写"命令形式"的片段）。
