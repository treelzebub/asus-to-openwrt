#!/usr/bin/env bash
#
# Converts an Asus router *_Decoded.cfg (nvram key=value dump, produced by
# decode-asus-router-config.sh or Decode-AsusRouterConfig.ps1) into UCI
# config snippets for OpenWrt: DHCP (pool range, DNS, static leases),
# port forwarding (firewall redirects), device-level network blocking
# (firewall rules by MAC, i.e. Asus "Parental Controls"/"Network Access
# Control"), and WAN proto/credentials.
#
# Deliberately NOT converted (see README caveats):
#   - LAN/WAN interface device bindings (option device/ifname) - these are
#     specific to the Asus router's internal switch/port naming and have no
#     relation to the target OpenWrt device's hardware.
#   - Wireless radio bindings (radio0/radio1) - same reason; SSID/PSK are
#     trivial to re-enter by hand and weren't the point of this script.
#   - QoS/bandwidth limiter, AiProtection, AiCloud, USB/Samba, URL/keyword
#     filtering - no direct OpenWrt/UCI equivalent.
#   - Time-scheduled device blocking - flagged as a TODO comment with the
#     raw nvram value, not auto-decoded (format not reliably verified).
#
# Usage:
#   ./convert-to-openwrt.sh <decoded.cfg> [-d output-destination-path]
#
# Output defaults to ./output/ (relative to the current directory) unless -d is given.

set -euo pipefail
export LC_ALL=C

GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

usage() {
  echo "Usage: $0 <decoded.cfg> [-d output-destination-path]" >&2
}

FILE=""
OUTDIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      if [[ $# -lt 2 ]]; then
        echo " -d requires an output-destination-path argument." >&2
        exit 1
      fi
      OUTDIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$FILE" ]]; then
        FILE="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  echo " Provide the path to a *_Decoded.cfg file." >&2
  usage
  exit 1
fi

OUTDIR="${OUTDIR:-./output}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

DHCP_OUT="$OUTDIR/openwrt-dhcp"
FW_OUT="$OUTDIR/openwrt-firewall"
WAN_OUT="$OUTDIR/openwrt-network"

awk -v dhcp_out="$DHCP_OUT" -v fw_out="$FW_OUT" -v wan_out="$WAN_OUT" '
function ip2int(ip,    o, n) {
  n = split(ip, o, ".")
  if (n != 4) return -1
  return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
}

# 8-bit bitwise AND without relying on non-POSIX awk bitwise extensions
function band8(a, b,    r, bit, i) {
  r = 0
  bit = 1
  for (i = 0; i < 8; i++) {
    if ((a % 2) == 1 && (b % 2) == 1) r += bit
    a = int(a / 2)
    b = int(b / 2)
    bit *= 2
  }
  return r
}

function network_addr(ip, mask,    oi, om, i, net) {
  split(ip, oi, ".")
  split(mask, om, ".")
  net = ""
  for (i = 1; i <= 4; i++) {
    net = net (i > 1 ? "." : "") band8(oi[i] + 0, om[i] + 0)
  }
  return net
}

function proto_name(p) {
  if (p == "TCP") return "tcp"
  if (p == "UDP") return "udp"
  if (p == "BOTH") return "tcp udp"
  return tolower(p)
}

function port_range(p) {
  gsub(/:/, "-", p)
  return p
}

# Quotes a value for safe embedding as a UCI option value. UCI has no
# in-quote escape for the quote character itself, so switch to double
# quotes when the value contains a single quote. We do not need the
# reverse case since we always default to single quotes otherwise.
function uciq(s) {
  if (index(s, "\047") > 0) {
    if (index(s, "\"") == 0) return "\"" s "\""
    gsub(/\047/, "", s)  # value has both quote types - strip single quotes as a last resort
  }
  return "\047" s "\047"
}

# UCI dhcp "config host" option name is used by dnsmasq as an actual
# hostname, so it must be sanitized to valid hostname characters -
# unlike other option name/label fields, which are purely descriptive.
function sanitize_host(s,    r) {
  r = s
  gsub(/[^A-Za-z0-9_-]/, "-", r)
  gsub(/-+/, "-", r)
  gsub(/^-+|-+$/, "", r)
  return r
}

{
  line = $0
  eq = index(line, "=")
  if (eq == 0) next
  key = substr(line, 1, eq - 1)
  val = substr(line, eq + 1)
  kv[key] = val
}

END {
  # ---------- DHCP (pool range, DNS, static leases) ----------
  print "# Generated from Asus nvram dump - review before using." > dhcp_out
  print "# Assumes your OpenWrt LAN interface is named \"lan\" (the default)." >> dhcp_out
  print "" >> dhcp_out

  lan_ip = kv["lan_ipaddr"]
  lan_mask = kv["lan_netmask"]
  dstart = kv["dhcp_start"]
  dend = kv["dhcp_end"]
  lease = kv["dhcp_lease"]

  dhcp_pool_done = 0
  if (lan_ip != "" && lan_mask != "" && dstart != "" && dend != "") {
    net = network_addr(lan_ip, lan_mask)
    net_int = ip2int(net)
    start_int = ip2int(dstart)
    end_int = ip2int(dend)
    if (net_int >= 0 && start_int >= 0 && end_int >= start_int) {
      start_off = start_int - net_int
      limit = end_int - start_int + 1
      print "config dhcp \047lan\047" >> dhcp_out
      print "\toption interface \047lan\047" >> dhcp_out
      print "\toption start " uciq(start_off) >> dhcp_out
      print "\toption limit " uciq(limit) >> dhcp_out
      if (lease != "") {
        # dnsmasq accepts a bare number as seconds; "86400s" is not a
        # documented unit suffix (only m/h/d/w/infinite are).
        print "\toption leasetime " uciq(lease) >> dhcp_out
      }
      dns1 = kv["dhcp_dns1_x"]
      dns2 = kv["dhcp_dns2_x"]
      if (dns1 != "") {
        optline = "6," dns1
        if (dns2 != "") optline = optline "," dns2
        print "\tlist dhcp_option " uciq(optline) >> dhcp_out
      }
      print "" >> dhcp_out
      dhcp_pool_done = 1
    }
  }
  if (!dhcp_pool_done) {
    print "# No DHCP pool range emitted - lan_ipaddr/lan_netmask/dhcp_start/dhcp_end" >> dhcp_out
    print "# were not all present in the source file." >> dhcp_out
    print "" >> dhcp_out
  }

  static_n = 0
  raw = kv["dhcp_staticlist"]
  if (raw != "") {
    n = split(raw, records, "<")
    for (i = 1; i <= n; i++) {
      if (records[i] == "") continue
      m = split(records[i], f, ">")
      mac = f[1]
      ip = f[2]
      host = (m >= 3 ? f[3] : "")
      if (mac == "" || ip == "") continue
      static_n++
      if (host == "") {
        host = "static-" ip
        gsub(/\./, "-", host)
      }
      host = sanitize_host(host)
      print "config host" >> dhcp_out
      print "\toption name " uciq(host) >> dhcp_out
      print "\toption mac " uciq(mac) >> dhcp_out
      print "\toption ip " uciq(f[2]) >> dhcp_out
      print "" >> dhcp_out
    }
  }

  # ---------- Firewall: port forwarding ----------
  print "# Generated from Asus nvram dump - review before using." > fw_out
  print "# Assumes your OpenWrt firewall zones are named \"lan\" and \"wan\" (the default)." >> fw_out
  print "" >> fw_out

  fw_n = 0
  raw = kv["vts_rulelist"]
  if (raw != "") {
    n = split(raw, records, "<")
    for (i = 1; i <= n; i++) {
      if (records[i] == "") continue
      m = split(records[i], f, ">")
      if (m < 5) continue
      name = f[1]
      extport = f[2]
      localip = f[3]
      localport = f[4]
      proto = f[5]
      if (extport == "" || localip == "" || proto == "") continue
      fw_n++
      if (localport == "") localport = extport
      print "config redirect" >> fw_out
      print "\toption name " uciq(name) >> fw_out
      print "\toption src \047wan\047" >> fw_out
      print "\toption src_dport " uciq(port_range(extport)) >> fw_out
      print "\toption dest \047lan\047" >> fw_out
      print "\toption dest_ip " uciq(localip) >> fw_out
      print "\toption dest_port " uciq(port_range(localport)) >> fw_out
      print "\toption proto " uciq(proto_name(proto)) >> fw_out
      print "" >> fw_out
    }
  }

  # ---------- Firewall: device-level blocking (Asus Parental Controls / Network Access Control) ----------
  block_n = 0
  todo_n = 0
  mac_raw = kv["MULTIFILTER_MAC"]
  if (mac_raw != "") {
    name_n = split(kv["MULTIFILTER_DEVICENAME"], names, ">")
    enable_n = split(kv["MULTIFILTER_ENABLE"], enables, ">")
    mac_n = split(mac_raw, macs, ">")

    daytime_raw = kv["MULTIFILTER_MACFILTER_DAYTIME"]
    daytime_stripped = daytime_raw
    gsub(/[<>]/, "", daytime_stripped)
    has_schedule = (length(daytime_stripped) > 0)

    print "" >> fw_out
    print "# Device blocking derived from Asus MULTIFILTER_* (Parental Controls / Network" >> fw_out
    print "# Access Control). ENABLE=2 is treated as a permanent block; ENABLE=1 (time-" >> fw_out
    print "# scheduled) is NOT auto-converted since the schedule string format wasn\047t" >> fw_out
    print "# reliably verified - configure those manually with start_time/stop_time/" >> fw_out
    print "# weekdays. Verify this ENABLE-value interpretation against your router\047s" >> fw_out
    print "# Parental Controls UI before relying on it." >> fw_out
    print "" >> fw_out

    for (i = 1; i <= mac_n; i++) {
      mac = macs[i]
      if (mac == "") continue
      dname = (i <= name_n ? names[i] : ("device-" i))
      if (dname == "") dname = "device-" i
      enable = (i <= enable_n ? enables[i] : "")

      if (enable == "2") {
        block_n++
        print "config rule" >> fw_out
        print "\toption name " uciq("Block " dname) >> fw_out
        print "\toption src \047lan\047" >> fw_out
        print "\toption src_mac " uciq(mac) >> fw_out
        print "\toption dest \047wan\047" >> fw_out
        print "\toption target \047REJECT\047" >> fw_out
        print "" >> fw_out
      } else if (enable == "1") {
        todo_n++
        print "# TODO: time-scheduled block for \047" dname "\047 (" mac ") - not auto-converted." >> fw_out
        if (has_schedule) {
          print "#   raw MULTIFILTER_MACFILTER_DAYTIME: " daytime_raw >> fw_out
        }
        print "" >> fw_out
      }
      # enable == "0" or empty -> disabled, skip silently
    }
  }

  # ---------- WAN (proto + conditional static/pppoe fields; no device binding) ----------
  print "# Generated from Asus nvram dump - review before using." > wan_out
  print "# Merge these options into your EXISTING network.wan interface." >> wan_out
  print "# Do NOT add \047option device\047/\047option ifname\047 from this file - keep" >> wan_out
  print "# whatever your OpenWrt device already uses for its WAN port." >> wan_out
  print "" >> wan_out

  wan_proto = kv["wan_proto"]
  if (wan_proto != "") {
    print "config interface \047wan\047" >> wan_out
    print "\toption proto " uciq(wan_proto) >> wan_out
    if (wan_proto == "static") {
      if (kv["wan_ipaddr"] != "") print "\toption ipaddr " uciq(kv["wan_ipaddr"]) >> wan_out
      if (kv["wan_netmask"] != "") print "\toption netmask " uciq(kv["wan_netmask"]) >> wan_out
      if (kv["wan_gateway"] != "") print "\toption gateway " uciq(kv["wan_gateway"]) >> wan_out
      dns1 = kv["wan_dns1_x"]
      dns2 = kv["wan_dns2_x"]
      if (dns1 != "") {
        dnsval = dns1
        if (dns2 != "") dnsval = dnsval " " dns2
        print "\toption dns " uciq(dnsval) >> wan_out
      }
    } else if (wan_proto == "pppoe") {
      if (kv["wan_pppoe_username"] != "") print "\toption username " uciq(kv["wan_pppoe_username"]) >> wan_out
      if (kv["wan_pppoe_passwd"] != "") print "\toption password " uciq(kv["wan_pppoe_passwd"]) >> wan_out
    } else {
      print "\t# proto is \047" wan_proto "\047 (e.g. dhcp) - no further fields needed;" >> wan_out
      print "\t# any wan_ipaddr/wan_gateway in the source file are stale DHCP-leased" >> wan_out
      print "\t# values, not settings, and were intentionally not copied." >> wan_out
    }
    print "" >> wan_out
  } else {
    print "# No wan_proto found in the source file." >> wan_out
  }

  printf "DHCP_POOL=%d\n", dhcp_pool_done > "/dev/stderr"
  printf "STATIC_LEASES=%d\n", static_n > "/dev/stderr"
  printf "PORT_FORWARDS=%d\n", fw_n > "/dev/stderr"
  printf "DEVICE_BLOCKS=%d\n", block_n > "/dev/stderr"
  printf "DEVICE_BLOCKS_TODO=%d\n", todo_n > "/dev/stderr"
  printf "WAN_PROTO=%s\n", wan_proto > "/dev/stderr"
}
' "$FILE" 2> "$OUTDIR/.convert_stats.$$" || { rm -f "$OUTDIR/.convert_stats.$$"; exit 1; }

# shellcheck disable=SC1090
STATS="$OUTDIR/.convert_stats.$$"
DHCP_POOL=$(awk -F= '$1=="DHCP_POOL"{print $2}' "$STATS")
STATIC_LEASES=$(awk -F= '$1=="STATIC_LEASES"{print $2}' "$STATS")
PORT_FORWARDS=$(awk -F= '$1=="PORT_FORWARDS"{print $2}' "$STATS")
DEVICE_BLOCKS=$(awk -F= '$1=="DEVICE_BLOCKS"{print $2}' "$STATS")
DEVICE_BLOCKS_TODO=$(awk -F= '$1=="DEVICE_BLOCKS_TODO"{print $2}' "$STATS")
WAN_PROTO=$(awk -F= '$1=="WAN_PROTO"{print $2}' "$STATS")
rm -f "$STATS"

echo " ->DHCP config (pool range: $([ "$DHCP_POOL" = "1" ] && echo yes || echo no), $STATIC_LEASES static lease(s)) saved to:"
echo "   ${GREEN}${DHCP_OUT}${NC}"
echo " ->Firewall config ($PORT_FORWARDS port forward(s), $DEVICE_BLOCKS device block(s)) saved to:"
echo "   ${GREEN}${FW_OUT}${NC}"
if [[ "${DEVICE_BLOCKS_TODO:-0}" -gt 0 ]]; then
  echo "   ${YELLOW}$DEVICE_BLOCKS_TODO time-scheduled block(s) need manual configuration - see TODO comments.${NC}"
fi
echo " ->WAN config (proto: ${WAN_PROTO:-none}) saved to:"
echo "   ${GREEN}${WAN_OUT}${NC}"
echo ""
echo "${YELLOW}Review all three files before use. None of these are meant to be applied"
echo "with a blind 'uci import' - merge the relevant config/option blocks into your"
echo "existing /etc/config/dhcp, /etc/config/firewall, and /etc/config/network.${NC}"
