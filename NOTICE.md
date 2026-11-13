# NOTICE

This repository (`oneclick`, containing the **OneClick** installer) is a merged,
single-file reimplementation of several community one-click proxy installers.
It was written for personal / internal use, not as a redistributable product.

## Upstream sources

The design and default parameters were derived from the following projects.
No source code from them is vendored in this repository: the upstream scripts
were used as reference only, and every runtime component is downloaded from
its own official release page.

| Component | Upstream | Used for |
|---|---|---|
| Hysteria2 | [Misaka-blog/hysteria-install](https://github.com/Misaka-blog/hysteria-install) | official install flow, self-signed cert + port hopping |
| Snell v6 | 翠花 Snell.sh (`git.io/Snell.sh`) | systemd unit, PSK / mode / version handling |
| SS-Rust | [xOS/Shadowsocks-Rust](https://github.com/xOS/Shadowsocks-Rust) + [shadowsocks/shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) | SS2022 config, ShadowTLS v3 |
| Menu layering | [jinqians](https://menu.jinqians.com) | common library / channel layering idea |
| Multi-protocol + subscription | [mozisen/surge](https://github.com/mozisen/surge) | protocol registry, Clash / Surge / sing-box subscription shapes |

At the time of writing (November 2026) **none of the upstream repositories
declared a license**. No source code from them is vendored here — they were
read as reference for install flows and default parameters, and everything in
`src/` is a reimplementation.

Consequently the license split is:

- **This repository's own code** (everything under `src/`, `build.sh`,
  `tests/`, `README*`, `NOTICE.md`): MIT, see [LICENSE](LICENSE).
- **Upstream projects**: no license granted by them, so no code is copied from
  them. If you are an upstream author and want attribution changed or content
  removed, open an issue.

If you redistribute this repository, keep `NOTICE.md` alongside it so the
upstream attribution travels with the code.

## Runtime components

`xray-core`, `hysteria`, `snell-server`, `ssserver` (shadowsocks-rust),
`shadow-tls` and `sing-box` are **not** included in this repository. The
installer downloads them from their official GitHub / vendor release URLs at
install time and leaves them under their respective licenses:

- Xray-core — MPL-2.0
- Hysteria — MIT
- shadowsocks-rust — MIT
- shadow-tls — MIT
- sing-box — GPL-3.0-or-later (only used as the AnyTLS server)
- Snell — proprietary, distributed by Surge (dl.nssurge.com)

## Disclaimer

This software is provided "as is", without warranty of any kind. It installs
system services, issues TLS certificates and configures proxy kernels on the
host it runs on, and it can interrupt existing services that occupy the same
ports. It does not modify firewall rules (the only exception is Hysteria2 port
hopping, where hysteria itself manages the redirect rules for its own port
range). Use it only on machines you own or administer, and only where running
a proxy is lawful.
