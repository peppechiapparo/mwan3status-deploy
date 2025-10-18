#!/bin/sh
set -eu

# Parse query string ?if=IF1,IF2,...
qs="${QUERY_STRING:-}"
ifs_list="${qs#*if=}"
ifs_list="${ifs_list%%&*}"

# Split by comma in POSIX sh
OLDIFS="$IFS"
IFS=,; set -- $ifs_list; IFS="$OLDIFS"

printf "Content-Type: application/json\r\n\r\n"
printf '{"ts":%s,"if":[' "$(date +%s)"
first=1
for name in "$@"; do
  [ -n "$name" ] || continue
  name=$(echo "$name" | tr -d ' ')

  # Map logical interface to OS device via ubus (BusyBox-compatible parsing)
  json=$(ubus call network.interface."$name" status 2>/dev/null || true)
  dev=""
  if [ -n "$json" ]; then
    # Allow optional spaces after colon (BusyBox JSON pretty print)
    dev=$(printf '%s\n' "$json" | sed -n 's/.*"l3_device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$dev" ] || dev=$(printf '%s\n' "$json" | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi
  [ -n "$dev" ] || dev="$name"
  dev=${dev%@*}

  rx_path="/sys/class/net/$dev/statistics/rx_bytes"
  tx_path="/sys/class/net/$dev/statistics/tx_bytes"
  rx=0; tx=0
  if [ -r "$rx_path" ] && [ -r "$tx_path" ]; then
    rx=$(cat "$rx_path" 2>/dev/null || echo 0)
    tx=$(cat "$tx_path" 2>/dev/null || echo 0)
  else
    # Fallback: parse /proc/net/dev for the interface row
    line=$(grep -E "^[[:space:]]*$dev:" /proc/net/dev 2>/dev/null || true)
    if [ -n "$line" ]; then
      # Split after ':' then split fields by spaces
      data=${line#*:}
      # Collapse multiple spaces
      data=$(echo "$data" | tr -s ' ')
      set -- $data
      # According to /proc/net/dev: $1=rx_bytes ... $9=tx_bytes
      rx=${1:-0}
      tx=${9:-0}
    fi
  fi

  if [ $first -eq 0 ]; then printf ','; else first=0; fi
  printf '{"name":"%s","rx":%s,"tx":%s}' "$name" "$rx" "$tx"
done
printf ']}'

