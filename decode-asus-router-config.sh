#!/usr/bin/env bash
#
# Decodes the .cfg file resulting from backing up the configuration of an
# Asus router. Bash port of Decode-AsusRouterConfig.ps1.
#
# Usage:
#   ./decode-asus-router-config.sh <file> [-d output-destination-path] [--skip-header-check]
#
# Examples:
#   ./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG'
#   ./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG' -d './Decoded'
#   ./decode-asus-router-config.sh './Settings_RT-AX86U Pro.CFG' --skip-header-check
#
# Output defaults to ./output/ (relative to the current directory) unless -d is given.

set -euo pipefail
export LC_ALL=C

GREEN=$'\033[0;32m'
NC=$'\033[0m'

usage() {
  echo "Usage: $0 <config-file> [-d output-destination-path] [--skip-header-check]" >&2
}

FILE=""
OUTDIR=""
SKIP_HEADER=0

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
    --skip-header-check)
      SKIP_HEADER=1
      shift
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

if [[ -z "$FILE" ]]; then
  echo " Provide the ASUS router config file name." >&2
  usage
  exit 1
fi

if [[ ! -f "$FILE" ]]; then
  echo " Provide the ASUS router config file name." >&2
  exit 1
fi

# Resolve to a full path (works on both macOS/BSD and Linux)
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

# Cross-platform file size (BSD stat vs GNU stat)
SIZE=$(stat -f%z "$FILE" 2>/dev/null || stat -c%s "$FILE")

if (( SIZE < 10 )); then
  echo " File size is too small." >&2
  exit 1
fi

# Determine output directory (defaults to ./output)
OUTDIR="${OUTDIR:-./output}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

BASENAME="$(basename "$FILE")"
NAME_NO_EXT="${BASENAME%.*}"
OUTPUT_FILE="$OUTDIR/${NAME_NO_EXT}_Decoded.txt"

# Decode: read the file as a stream of byte values and run the XOR-ish
# unshift algorithm in awk (byte 0 in the file marks the start; byte 7 is
# the random seed; bytes >252 in the stream encode a literal NUL, which we
# emit directly as a newline; everything else is unshifted by 0xFF+rand).
DECODE_STATUS=0
od -An -v -tu1 "$FILE" | awk -v size="$SIZE" -v skip="$SKIP_HEADER" '
BEGIN { idx = 0 }
{
  for (j = 1; j <= NF; j++) {
    b[idx] = $j
    idx++
  }
}
END {
  if (skip != 1) {
    if (b[0] != 72 || b[1] != 68 || b[2] != 82 || b[3] != 50) {
      exit 2
    }
  }

  datalen = b[4] + b[5] * 256 + b[6] * 65536
  if (datalen != (size - 8)) {
    exit 3
  }

  rnd = b[7]
  for (i = 8; i < idx; i++) {
    cur = b[i]
    if (cur > 252) {
      if (i > 8 && b[i - 1] != 0) {
        printf "\n"
      }
    } else {
      B = 255 + rnd - cur
      if (B > 255) B = 255
      if (B <= 127) {
        printf "%c", B
      } else {
        printf "%c", 63  # ASCII "?" - mirrors PowerShell -Encoding ascii lossy mapping
      }
    }
  }
}
' > "$OUTPUT_FILE" || DECODE_STATUS=$?

if [[ $DECODE_STATUS -eq 2 ]]; then
  echo "File header check failed." >&2
  rm -f "$OUTPUT_FILE"
  exit 1
elif [[ $DECODE_STATUS -eq 3 ]]; then
  echo " Data length check failed." >&2
  rm -f "$OUTPUT_FILE"
  exit 0
elif [[ $DECODE_STATUS -ne 0 ]]; then
  echo " Failed to decode configuration file." >&2
  rm -f "$OUTPUT_FILE"
  exit 1
fi

echo " ->Decoded configuration file has been saved to:"
echo "   ${GREEN}${OUTPUT_FILE}${NC}"

# Export dhcp_staticlist, if present
DHCP_LINE="$(grep -m1 '^dhcp_staticlist=' "$OUTPUT_FILE" || true)"
if [[ -n "$DHCP_LINE" ]]; then
  echo " Found DHCP client list"
  DHCP_CONTENT="${DHCP_LINE#dhcp_staticlist=}"
  HEADER="        MAC       |      IP       |   HostName "
  DHCP_FORMATTED="$(printf '%s' "$DHCP_CONTENT" | tr '<' '\n' | sed 's/>>/ | /g; s/>/ | /g')"
  DHCP_FILE="$OUTDIR/${NAME_NO_EXT}_DHCP.txt"
  printf '%s%s\n' "$HEADER" "$DHCP_FORMATTED" > "$DHCP_FILE"
  echo " ->DHCP client list has been saved to:"
  echo "   ${GREEN}${DHCP_FILE}${NC}"
fi

# Retrieve admin username & password, and any configured SSID and password
printf ' ->Attempting to identify:\n    HTTP (admin) username & password\n    PPPOE credentials\n    SSIDs (Wi-Fi names)\n    WPA PSKs (Wi-Fi passwords)\n'

CRED_LINES="$(grep -E '_wpa_psk=.+|wl.*_ssid=.+|http_passwd=.+|http_username=.+|pppoe_passwd=.+|pppoe_username=.+' "$OUTPUT_FILE" || true)"

# For WiFi entries, only keep matched SSID/WPA PSK pairs - skip orphaned SSIDs or PSKs
PAIRED_CRED_LINES="$(printf '%s\n' "$CRED_LINES" | awk '
{
  if ($0 ~ /^wl[^_]+_ssid=/) {
    pos = index($0, "_ssid=")
    prefix = substr($0, 1, pos - 1)
    ssid[prefix] = $0
  } else if ($0 ~ /^wl[^_]+_wpa_psk=/) {
    pos = index($0, "_wpa_psk=")
    prefix = substr($0, 1, pos - 1)
    psk[prefix] = $0
  } else if (length($0) > 0) {
    other[++oc] = $0
  }
}
END {
  for (i = 1; i <= oc; i++) print other[i]
  for (k in ssid) {
    if (k in psk) {
      print ssid[k]
      print psk[k]
    }
  }
}
')"

SEP="$(printf '=%.0s' {1..60})"
echo "${GREEN}${SEP}${NC}"
if [[ -n "$PAIRED_CRED_LINES" ]]; then
  printf '%s\n' "$PAIRED_CRED_LINES"
fi
echo "${GREEN}${SEP}${NC}"

if [[ -n "$PAIRED_CRED_LINES" ]]; then
  CRED_FILE="$OUTDIR/${NAME_NO_EXT}_Credentials.txt"
  printf '%s\n' "$PAIRED_CRED_LINES" > "$CRED_FILE"
  echo " ->Credentials have been saved to:"
  echo "   ${GREEN}${CRED_FILE}${NC}"
fi
