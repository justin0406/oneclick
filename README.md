**English** | [简体中文](README.zh-CN.md)

# OneClick

**One-click multi-protocol proxy installer** — one script, one entry point, one certificate and state layer.

It puts five server implementations behind a single CLI: VLESS-Reality, Hysteria2, Snell v6,
SS-Rust and AnyTLS. Install, change ports, rotate certificates, generate client configs,
back up and restore, or uninstall — all from one menu. No panel required.

- Single-file release: `dist/oneclick.sh`, ~5,900 lines, run it right after download
- Debian 13 / Ubuntu 22.04+ first, CentOS Stream / RHEL 9 compatible
- x86_64 / aarch64 / armv7l (sing-box, used by AnyTLS, has no i386 build)

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/justin0406/oneclick/main/dist/oneclick.sh -o oneclick.sh
sudo bash oneclick.sh
```

The first run installs itself to `/usr/local/bin/oneclick` (short alias `oc`) and opens the menu.
From then on:

```bash
sudo oc
```

Or skip the menu entirely:

```bash
sudo oc --install hysteria2 --cert-mode self --yes
sudo oc --install vless_reality --yes
sudo oc --status
sudo oc --link snell --format surge
```

## Supported protocols

| Protocol | Server | Port | Certificate | Notes |
|---|---|---|---|---|
| VLESS-Reality | xray-core | 443 by default (or random) | not needed | REALITY + x25519, strongest against active probing; good default |
| Hysteria2 | hysteria | random high UDP | self-signed / ACME / existing | QUIC, good on lossy links; salamander obfuscation and port hopping optional |
| Snell v5 / v6 | snell-server 5.0.1 / 6.0.0 | random high | not needed | single port, PSK auth, native Surge support; v5 is QUIC (TCP+UDP) and the only option on armv7l |
| SS-Rust | ssserver | random high TCP + UDP | only for ShadowTLS | SS2022 by default; ShadowTLS v3 (strict) available as an opt-in disguise, off by default. Client must support v3 (e.g. mihomo / Clash Meta) |
| AnyTLS | sing-box | random high TCP | **required**: self-signed / ACME / existing | low-fingerprint TLS proxy; works with Surge, Loon and sing-box clients |

Ports are picked at random in `20000-60000` on install (verified free for both TCP and UDP), and keep
their value on reinstall. VLESS-Reality is the exception: it asks whether to use 443 (Y, best for
camouflage) and only falls back to a random high port on N. Pass `--port` to override.

SS-Rust always installs with SS2022 (`2022-blake3-aes-128-gcm`) and never asks — there is no
server-side signal for client capability. For clients without SS2022, pass
`--method chacha20-ietf-poly1305` (or `aes-256-gcm`).

> **Why AnyTLS runs on sing-box instead of anytls-go:** the anytls-go server generates its TLS
> certificate in-process — a one-hour RSA key with no SAN — so it can never use a certificate the
> script issues. The sing-box `anytls` inbound accepts `certificate_path` / `key_path`, which is the
> only way to keep AnyTLS on the same certificate workflow as everything else.

## Design principles

**Protocols are plugins.** Every protocol implements the same nine functions
(`meta / install / uninstall / status / link / regen / clash / surge / singbox`). The menu, subscription
and status layers only walk a registry; they never know which protocol they are dealing with.
Adding a protocol means adding one file and registering one key.

**You own the certificates.** Every TLS protocol supports three paths: `existing` (paste a certificate
you already have), `acme` (acme.sh HTTP-01), or `self` (EC P-256 with SAN). A missing certificate never
silently becomes a random throwaway one — installation stops at the certificate step and asks, using a
numbered menu rather than requiring you to type a mode name.

**Certificates are shared by domain.** A certificate is stored once under `certs/<domain>/` and every
protocol using that domain points at the same files — the second TLS protocol reuses the first one's
certificate instead of requesting another, which also avoids Let's Encrypt's rate limit (5 per domain
per week). acme.sh is told to `systemctl restart` every registered consumer on renewal, so a renewed
certificate actually reaches the running services; without that hook a renewed cert sits on disk while
the service keeps serving the expired one.

ACME requires a domain **you own that already resolves to this machine** — there is no default, and the
script checks resolution and port 80 before calling acme.sh, then prints acme.sh's real output on
failure instead of a generic message.

**Nothing outside its own scope is touched.** No firewall changes — the script never writes
iptables / nftables / firewalld / ufw rules, so your firewall policy stays yours. No `chmod -R 777`,
no edits to the system SSH configuration, no sysctl tuning. Only exception: if you enable Hysteria2
port hopping, hysteria itself installs and cleans up the redirect rules for its `listen` port range.

**Downloads are verifiable.** All binaries go through one download layer: three retries, an optional
mirror prefix (`OC_GH_PROXY`), SHA-256 verification against the upstream checksum when the project
publishes one (Xray `.dgst`, Hysteria2 `hashes.txt`, shadowsocks-rust `.sha256`), and rollback on
failure so no half-written file is left behind. Projects that ship no checksum file (sing-box,
shadow-tls, Snell) are verified structurally only — the download must be a valid zip/gzip/xz archive
or ELF binary — so a hostile mirror could still substitute an asset for those. Prefer running without `OC_GH_PROXY` if you cannot
trust your mirror.

**It updates itself.** On every run the script fetches `dist/oneclick.sh` from this repository, compares
the embedded `OC_VERSION`, atomically replaces itself and re-executes the new version immediately
when one exists. The check is silent on failure (offline, mirror down, bad response) and never blocks
the menu. Because the downloaded script runs as root, the self-update **only follows the official URL**
by default — `OC_GH_PROXY` is not applied to it. Set `OC_UPDATE_MIRROR=1` if you really want the mirror
for updates too, `OC_NO_UPDATE=1` to skip the check, or `OC_UPDATE_URL` to point at your own copy.
No menu item, no cron.

**Uninstall means uninstall.** Services are stopped, disabled, their units removed, and
`daemon-reload` is run. Kernel binaries are **kept by default** on a single-protocol uninstall —
they may be shared with a panel or another script, and deleting them silently breaks that service
(anything still referenced by a non-OneClick unit is always kept). Choose to delete them in the
prompt, or use `oneclick --purge` to remove everything it ever created — that one requires typing
`PURGE` to confirm.

**Kernels upgrade in place, safely.** `oneclick --upgrade <key|all>` (or *Node management → kernel
versions*) replaces a kernel binary without touching your config, port or credentials. Every upgrade
backs up the old binary, verifies the download against the GitHub release digest, checks that the new
version still accepts your existing config (where the kernel offers a check subcommand), then
restarts — **only if the service was running before the upgrade** (a service you stopped on purpose
stays stopped) — and confirms it is alive. Any failure restores the backup and restarts the old
version — the backup is kept until the new one is proven running, because for kernels without a
config check (Hysteria2, ssserver) a failed start is the only signal that something broke.

Snell is the exception: `dl.nssurge.com` publishes no version index, so `--upgrade snell` needs an
explicit `--kernel-version X.Y.Z` instead of discovering the latest. Hysteria2 falls back to the
official `api.hy2.io` update API when the GitHub API is rate-limited. The Hysteria2 systemd unit
carries the same sandbox as the official installer (`NoNewPrivileges`, bounded capabilities) — it
needs `CAP_NET_ADMIN` for port hopping.

**Snell v5 vs v6.** Pick with `--snell-version 5|6` (or answer the prompt). v6 is plain TCP with
`mode`; v5 is a **QUIC** proxy that needs both TCP and UDP inbound open, and is the only version with
an armv7l build. The two use different config keys (`mode` vs `obfs`), so the config is rewritten on
switch, and client output follows the installed version. Note that sing-box's snell outbound supports
v4/v6 but **not v5** — `--format singbox` fails with an explanation rather than emitting a config that
will not start; use Surge/Clash for v5.

**Single user by design.** No multi-user accounts, traffic accounting, expiry dates or Telegram bot —
those belong in a panel. This script's job is to install and operate one machine's proxies well.

## Layout

```
/etc/oneclick/
├── db.json                # single state store (jq atomic writes + flock)
├── certs/<name>/          # cert.pem / key.pem (0600)
├── sub/                   # oneclick-clash.yaml / -surge.conf / -singbox.json / -uri.txt
└── <protocol key>/        # per-protocol config (0600)

/usr/local/bin/oneclick    # entry point only (oc is an alias); removed on purge
/opt/oneclick/bin/{xray,hysteria,snell-server,ssserver,shadow-tls,sing-box}   # private kernels
/etc/systemd/system/oneclick-<protocol>.service
```

**Dual-stack output.** When the machine has both a public IPv4 and a public IPv6 address, every
generated format emits **two complete nodes** — one per address — so clients can pick either family.
Single-stack machines get one. Node names stay identical; the address tells them apart. In sing-box
output the tags gain a `-v6` suffix on the second entry, because tag is a unique key there.

Note this reports addresses, it does not verify that inbound traffic reaches them — an upstream that
blocks IPv6 inbound still yields an IPv6 node that will not connect. Check reachability yourself if
your provider's IPv6 is uncertain.

**Dual-stack listeners.** SS-Rust, ShadowTLS, VLESS-Reality and AnyTLS bind `::` (dual-stack, IPv4
still reachable) when the machine has an IPv6 stack, and fall back to `0.0.0.0` when it does not.
Hysteria2 listens on both families by default; Snell v6 binds IPv4 only.

## Subscriptions

The **Config info** menu lists only the protocols you have installed; pick one to see its Surge
and Loon node lines straight away. To write files instead, `oc --sub` renders node-only snippets for the installed protocols, so you can paste them into
an existing config instead of replacing it.

- `sub/oneclick-clash.yaml` — Clash / mihomo proxy entries (paste under `proxies:`; mihomo supports Snell v1–v5 only, use Surge for v6)
- `sub/oneclick-surge.conf` — Surge node lines (paste under `[Proxy]`; all five protocols supported — Surge's VLESS policy type needs iOS 6.0.0+ / Mac 6.12.0+)
- `sub/oneclick-loon.conf` — Loon node lines (paste under `[Proxy]`; Snell is omitted: Loon has no Snell support)
- `sub/oneclick-uri.txt` — plain URI list, also usable for QR codes
- sing-box is not generated by default; use `oneclick --sub --format singbox` if you need it

## Build and test

```bash
./build.sh
```

The build concatenates 15 modules into `dist/oneclick.sh` and runs four checks: `bash -n`,
`shellcheck -S warning`, an undefined-function scan (command positions only, so jq field names are not
misread), and duplicate-definition detection. Edit `src/`, never `dist/`.

CI (`.github/workflows/build.yml`) runs the same build on every push and additionally fails if
`dist/oneclick.sh` differs from what `src/` produces, plus a smoke test of `--version` / `--help`.

Requires **bash 4.0+** at runtime (`declare -gA`, `${var,,}`); bash 3.2 — the macOS default — exits
immediately with a clear message. Every supported Linux target ships bash 4 or newer.

Bash unit tests live in `tests/` and run with [bats-core](https://github.com/bats-core/bats-core):

```bash
bats tests/
```

```
src/00-header.sh            constants, protocol registry
src/lib/{os,ui,store,dl,net,cert,svc,share}.sh
src/proto/{vless_reality,hysteria2,snell,ss_rust,anytls}.sh
src/99-menu.sh              menu, CLI, main
```

Every release is verified end-to-end on a fresh Debian 13 (trixie) VPS before it is pushed.

## Credits

The design borrows from [Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install),
翠花's Snell.sh, [xOS/Shadowsocks-Rust](https://github.com/xOS/Shadowsocks-Rust),
[jinqians' menu](https://menu.jinqians.com) and [mozisen/surge](https://github.com/mozisen/surge).
No upstream code is copied — their repositories declared no license, so they were used as
design reference only, and everything here is a reimplementation.

This repository's own code is **MIT** (see [LICENSE](LICENSE)).
Runtime components (Xray, Hysteria, sing-box, …) remain under their own licenses.
See [NOTICE.md](NOTICE.md) for details.
