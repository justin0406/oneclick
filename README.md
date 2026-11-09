**English** | [简体中文](README.zh-CN.md)

# OneClick

**One-click multi-protocol proxy installer** — one script, one entry point, one certificate and state layer.

It puts five server implementations behind a single CLI: VLESS-Reality, Hysteria2, Snell v6,
SS-Rust and AnyTLS. Install, change ports, rotate certificates, generate client configs,
back up and restore, or uninstall — all from one menu. No panel required.

- Single-file release: `dist/oneclick.sh`, ~6,000 lines, run it right after download
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
sudo oc --install hysteria2 --port 8443 --cert-mode self --yes
sudo oc --install vless_reality --port 443 --yes
sudo oc --status
sudo oc --link snell --format surge
```

## Supported protocols

| Protocol | Server | Port | Certificate | Notes |
|---|---|---|---|---|
| VLESS-Reality | xray-core | 443, exclusive | not needed | REALITY + x25519, strongest against active probing; good default |
| Hysteria2 | hysteria | high UDP | self-signed / ACME / existing | QUIC, good on lossy links; salamander obfuscation and port hopping optional |
| Snell v6 | snell-server 6.0.0 | high TCP | not needed | single port, PSK auth, native Surge support |
| SS-Rust | ssserver | TCP + UDP | only for ShadowTLS | SS2022 by default; ShadowTLS v3 (strict) available as an opt-in disguise, off by default. Client must support v3 (e.g. mihomo / Clash Meta) |
| AnyTLS | sing-box | high TCP | **required**: self-signed / ACME / existing | low-fingerprint TLS proxy; works with Surge, Loon and sing-box clients |

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
silently becomes a random throwaway one — installation stops at the certificate step and asks.

**Nothing outside its own scope is touched.** No firewall changes — the script never writes
iptables / nftables / firewalld / ufw rules, so your firewall policy stays yours. No `chmod -R 777`,
no edits to the system SSH configuration, no sysctl tuning. Only exception: if you enable Hysteria2
port hopping, hysteria itself installs and cleans up the redirect rules for its `listen` port range.

**Downloads are verifiable.** All binaries go through one download layer: three retries, an optional
mirror prefix (`OC_GH_PROXY`), SHA-256 verification when a digest is available, and rollback on failure

**It updates itself.** On every run the script fetches `dist/oneclick.sh` from this repository, compares
the embedded `OC_VERSION`, atomically replaces itself and re-executes the new version immediately
when one exists. The check is silent on failure (offline, mirror down, bad response) and never blocks
the menu. Set
`OC_NO_UPDATE=1` to skip it, or `OC_UPDATE_URL` to point at your own mirror. No menu item, no cron.
so no half-written file is left behind.

**Uninstall means uninstall.** Services are stopped, disabled, their units removed, and
`daemon-reload` is run. Configs and certificates are kept only if you explicitly say so.
`oneclick --purge` removes everything it ever created and requires typing `PURGE` to confirm.

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

## Subscriptions

`oc --sub` renders node-only snippets for the installed protocols, so you can paste them into
an existing config instead of replacing it.

- `sub/oneclick-clash.yaml` — Clash / mihomo proxy entries (paste under `proxies:`; mihomo supports Snell v1–v5 only, use Surge for v6)
- `sub/oneclick-surge.conf` — Surge node lines (paste under `[Proxy]`; VLESS-Reality is omitted: Surge has no VLESS policy type)
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
None of the upstream projects declared a license, so this repository grants no redistribution rights;
runtime components (Xray, Hysteria, sing-box, …) remain under their own licenses.
See [NOTICE.md](NOTICE.md) for details.
