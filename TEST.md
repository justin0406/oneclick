# PX 测试清单（Debian 13）

> 用法：按顺序执行，每条把「实际输出」贴回给我。失败不要自己修，先停在该步骤回传日志。
> 一键收集日志：`bash -c 'px --status; systemctl list-units "px-*" --no-pager; journalctl -u "px-*" -n 200 --no-pager -o cat' > /root/px-test.log 2>&1`

## 0. 环境准备（测试前）

```bash
cat /etc/os-release | head -3        # 期望：Debian GNU/Linux 13 (trixie)
uname -m                             # 期望：x86_64（或 aarch64）
ss -lntup | head -20                 # 记录现有 443/80 是否被占
systemctl --version | head -1        # 记录 systemd 版本
```

**记录基线**：`ss -lntup` 与 `nft list ruleset`（或 `iptables-save`）各存一份，测试完对比"是否只增删了 px- 规则"。

**端口前提**：VLESS-Reality 需要 443 独占；AnyTLS / Hysteria2 需要高位 TCP / UDP 端口；ACME 模式还需要 80 空闲。首次安装会下载 xray / hysteria / snell-server / ssserver / sing-box，合计约 60~90 MB，慢的话在菜单「系统工具 → 6 镜像前缀」里配 gh_proxy。

## 1. 安装脚本本体

```bash
mkdir -p /root/px && cd /root/px
# 把 dist/px.sh 传上来（scp 或 cat > px.sh 粘贴），然后：
bash -n px.sh && echo SYNTAX_OK
install -m 755 px.sh /usr/local/bin/px
px --version                          # 期望：px 0.1.0
px --help                             # 期望：用法正常，无报错
```

**预期**：首次 `px` 自动装 curl/jq/openssl/unzip 等基础依赖，然后进菜单；首屏显示系统、公网 IP、已装协议"无"。

## 2. 单协议冒烟（每个协议独立做一轮）

通用步骤（以 anytls 为例）：
```bash
px --install anytls --port 8443 --cert-mode self --yes
systemctl status px-anytls --no-pager    # 期望：active (running)
journalctl -u px-anytls -n 30 --no-pager -o cat   # 期望：无报错
ss -lntup | grep 8443                    # 期望：有监听
px --link anytls                         # 期望：anytls://... 一条
px --link anytls --format clash          # 期望：YAML 片段
px --status                              # 期望：AnyTLS 8443 运行中
```

逐协议检查点：

| 协议 | 安装命令 | 关键验证 |
|---|---|---|
| AnyTLS | `px --install anytls --port 8443 --cert-mode self --yes` | 服务端为 **sing-box 1.14.4**（`sing-box version`）；证书文件存在且 key 600；`ls -l /etc/px/certs/*/`；客户端（Surge/Loon）能连 |
| Hysteria2 | `px --install hysteria2 --port 8443 --cert-mode self --yes` | UDP 监听 `ss -lnup`；客户端能连；无 obfs 时链接无 obfs 参数 |
| Snell v6 | `px --install snell --port 12345 --yes` | `snell-server --version` 为 6.0.0；PSK 长度 20；Surge/Snell 客户端导入（mihomo 仅支持 v5 及以下） |
| SS-Rust | `px --install ss_rust --port 8388 --yes` | `ssserver -h` 可执行；`ss -lnup` 有 UDP；ShadowTLS 默认**关**（开时监听第二个端口）；客户端能连 |
| VLESS-Reality | `px --install vless_reality --port 443 --yes` | 443 监听；`xray x25519` 密钥已入 db；客户端能连且未被墙探测 |

## 3. 重启与自启

```bash
reboot
# 起来后：
px --status                          # 期望：全部「运行中」
```

## 4. 幂等与冲突

```bash
px --install anytls --yes            # 期望：拒绝「已安装」
px --install snell --port 443 --yes  # 期望：端口占用被前置拦截
px --uninstall anytls --yes
px --uninstall anytls --yes          # 期望：第二次提示「未安装」，不报错
ss -lntup | grep 8443 || echo CLEAN  # 期望：CLEAN（端口释放）
ls /etc/systemd/system/px-anytls.service 2>/dev/null || echo UNIT_CLEAN  # 期望：UNIT_CLEAN
```

## 5. 系统工具

```bash
px   # 菜单 5
# 5.3 BBR：期望 sysctl 显示 bbr、fq
 sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
# 5.4 TFO：期望 3
 sysctl net.ipv4.tcp_fastopen
# 5.2 防火墙放行：期望只多出 px- 开头的规则
 nft list ruleset 2>/dev/null | grep -i px || iptables-save | grep px
```

## 6. 订阅与分享

```bash
px   # 菜单 4 → 1（全部格式）
ls -l /etc/px/sub/
cat /etc/px/sub/px-clash.yaml     # 期望：proxies/proxy-groups/rules 完整，能直接导入 Clash
cat /etc/px/sub/px-surge.conf     # 期望：[Proxy]/[Proxy Group]/[Rule] 完整
```

## 7. 备份与恢复

```bash
px   # 菜单 6 → 1，记录备份路径
px   # 菜单 6 → 2，输入备份路径恢复
px --status                        # 期望：恢复后协议仍在（可能需要逐个 regen）
```

## 8. 卸载全部 + 残留检查

```bash
px   # 菜单 6 → 4
px --status                        # 期望：全部未安装
systemctl list-units 'px-*' --no-pager   # 期望：无
ls /etc/systemd/system/px-*.service 2>/dev/null || echo UNIT_CLEAN
nft list ruleset 2>/dev/null | grep -c px || iptables-save | grep -c px   # 期望：0
```

## 9. 订阅可用性（客户端侧）

- Clash/Mihomo：直接导入 `/etc/px/sub/px-clash.yaml`（Snell v6 会因 mihomo 不支持被跳过，属预期）
- Surge：导入 `px-surge.conf`，Snell v6 / AnyTLS / Hysteria2 均走 Surge 原生节点行
- sing-box 客户端：导入 `px-singbox.json`

## 回传模板（每步失败时填）

```
步骤：4.2 px --install snell --port 443 --yes
期望：端口冲突前置拦截
实际：（粘贴完整终端输出）
日志：systemctl status px-snell --no-pager; journalctl -u px-snell -n 50 --no-pager -o cat
系统：Debian 13 / x86_64 / 仅本脚本
```
