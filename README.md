# asus-to-openwrt-converter

Decode an Asus router's `.CFG` backup file and convert the useful bits — DHCP
static leases, port forwarding, device-level blocking, WAN settings — into
UCI config snippets for OpenWrt.

Two scripts, meant to be run in sequence:

```
Settings_XXXXX.CFG  --[decode-asus-router-config.sh]-->  Settings_XXXXX_Decoded.txt  --[convert-to-openwrt.sh]-->  OpenWrt UCI snippets
```

Pure `bash` + standard Unix tools (`awk`, `od`, `grep`, `sed`) — no
PowerShell, no runtime dependencies to install.

## Requirements

- `bash`
- `awk`, `od`, `grep`, `sed` (present by default on macOS and Linux)

## Usage

### 1. Decode the `.CFG` backup

```
./decode-asus-router-config.sh <config-file> [-d output-destination-path] [--skip-header-check]
```

```
./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG'
./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG' -d './decoded'
./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG' --skip-header-check
```

Output defaults to `./output/` (relative to your current directory) unless
`-d` is given. Produces:

- `<name>_Decoded.txt` — the full decoded nvram key=value dump
- `<name>_Credentials.txt` — admin login, PPPoE credentials, paired
  SSID/WPA-PSK values (if found)
- `<name>_DHCP.txt` — formatted DHCP static-lease table (if found)

`--skip-header-check` skips validation of the file's 4-byte header tag, which
varies by model (see [Compatibility](#compatibility)); use it if you get a
header-check failure on an otherwise-valid file.

### 2. Convert the decoded dump to OpenWrt UCI config

```
./convert-to-openwrt.sh <decoded.txt> [-d output-destination-path]
```

```
./convert-to-openwrt.sh ./output/Settings_RT-AX86U_Decoded.txt
./convert-to-openwrt.sh ./output/Settings_RT-AX86U_Decoded.txt -d './openwrt-config'
```

Output defaults to `./output/` unless `-d` is given. Produces:

- `<name>_OpenWrt_DHCP.conf` — DHCP pool range, DNS, static leases (`config host`)
- `<name>_OpenWrt_Firewall.conf` — port forwards (`config redirect`) and
  device-level internet blocking (`config rule`, by MAC)
- `<name>_OpenWrt_WAN.conf` — WAN proto and, if applicable, static
  IP/gateway/DNS or PPPoE credentials

**None of these are meant to be applied with a blind `uci import`.** Review
each file and merge the relevant `config`/`option` blocks into your existing
`/etc/config/dhcp`, `/etc/config/firewall`, and `/etc/config/network` by hand.

## What gets converted, and what doesn't

Converted, because it's hardware-independent and safe to carry over as-is:

- DHCP pool range, DNS server, static (MAC → IP) leases
- Port forwarding rules (`vts_rulelist`) — assumes your OpenWrt firewall
  zones are named `lan`/`wan`, which is the default on virtually all
  installs (zone names are logical, not tied to hardware, unlike interface
  device names)
- Permanent device blocking (Asus Parental Controls / Network Access
  Control) by MAC address
- WAN proto (`dhcp`/`static`/`pppoe`) and, only when actually meaningful,
  the associated static IP fields or PPPoE credentials

**Not** converted, deliberately:

- **LAN/WAN interface device bindings** (`option device`/`ifname`) — these
  are specific to the Asus router's internal switch/port naming and have no
  relation to your OpenWrt device's actual hardware. The WAN config file
  omits these entirely; you must merge its options into your existing
  `network.wan` interface without touching `option device`.
- **Wireless radio bindings** (`radio0`/`radio1`) — OpenWrt numbers radios by
  PCI/platform path, which varies per device and doesn't correspond to
  Asus's 2.4/5GHz band numbering. SSID/password are trivial to re-enter by
  hand, so this wasn't a priority.
- **QoS/bandwidth limiter, AiProtection, AiCloud, USB/Samba, URL/keyword
  filtering** — no direct OpenWrt/UCI equivalent.
- **Time-scheduled device blocking** — Asus stores this as a bitmask-style
  schedule string (`MULTIFILTER_MACFILTER_DAYTIME`) whose exact format
  wasn't reliably verified against real data, so it's left as a `# TODO`
  comment with the raw value rather than guessed at. Only *permanent*
  blocks are auto-converted.

The permanent-vs-scheduled distinction is inferred from
`MULTIFILTER_ENABLE` (`2` = permanent block, `1` = time-scheduled) based on
observed data — verify this against your own router's Parental Controls UI
before relying on it, since it isn't officially documented.

## Compatibility

### Asus routers

Tested against real data from RT-ACRH13, RT-BE88U, RT-AX86U Pro, RT-AC86U,
and AX58U — spanning both Broadcom and Qualcomm-based hardware and roughly a
decade of firmware generations. The underlying `.CFG` container format and
nvram key namespace (`dhcp_*`, `lan_*`, `wan_*`, `wl*_*`, `vts_rulelist`,
`MULTIFILTER_*`) appear stable across the Asuswrt/Asuswrt-Merlin firmware
lineage on standalone RT-series routers generally, not just these five.

**A header tag mismatch is expected on some models, not a sign of a bad
file.** The `.CFG` file's 8-byte header is `[4-byte tag][3-byte body
size][1-byte randkey]`. The 4-byte tag is sometimes the literal string
`HDR2`, but on some models/firmware it's a model-name stamp instead (e.g.
`N55U`, `AC55U`) — confirmed against real RT-ACRH13 data, whose tag was
`AC55`, the truncated form of `AC55U`. The byte offsets for size/randkey are
fixed regardless of the tag, so if `decode-asus-router-config.sh` fails
header validation, `--skip-header-check` is almost always safe to use.

**Known incompatible:** Asus's DSL-integrated modem/routers (e.g.
DSL-AC52U) export a differently-named file (`romfile.cfg`) using a
different container format, which this script doesn't handle — [a
separate tool](https://github.com/pawitp/asus-romfile-tools) exists for
that. Very old, pre-Asuswrt-unification hardware (roughly pre-2013) is
untested and unverified either way.

### OpenWrt

UCI's `config`/`option`/`list` syntax has been stable across essentially
the entire modern OpenWrt release history, so the generated snippets
aren't tied to a specific version. The one thing worth calling out:
OpenWrt switched its default firewall backend from fw3 (iptables) to fw4
(nftables) in 22.03, but fw4 was deliberately built to consume the same
UCI firewall schema as fw3 for common configs — so the `config
redirect`/`config rule` sections here work unmodified whether you're on
an older fw3-based release (≤21.02) or a current fw4-based one (22.03+).
DHCP config targets dnsmasq, which is unchanged across all these releases.

## Credits

Decode logic is a `bash` port of [Decode-AsusRouterConfig.ps1](https://github.com/VladDBA/Asus-Router-Config-Decoder)
by Vlad Drumea (VladDBA), which itself was based on
[this bash script](https://github.com/billchaison/asus-router-decoder) by
billchaison. The OpenWrt UCI conversion is new.

## License

MIT — see [LICENSE](LICENSE).
