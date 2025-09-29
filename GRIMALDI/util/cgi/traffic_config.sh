#!/bin/sh
# Output JSON with bundle caps per subnet from /opt/traffic_monitor/config
set -eu
echo "Content-Type: application/json"
echo
CFG="/opt/traffic_monitor/config"
if [ ! -r "$CFG" ]; then
  echo '{"subnets":[],"limits":{},"current_month":""}'
  exit 0
fi

# Read subnets list and month if present
subs=$(sed -n 's/^subnets=//p' "$CFG" | tr -d '\r')
month=$(sed -n 's/^current_month=//p' "$CFG" | tr -d '\r')

printf '{"subnets":['
first=1
IFS=, ; for s in $subs; do
  [ -n "$s" ] || continue
  if [ $first -eq 0 ]; then printf ','; else first=0; fi
  printf '"%s"' "$s"
done
unset IFS
printf '],"limits":{'
first=1
while IFS= read -r line; do
  case "$line" in
    *=*) key="${line%%=*}"; val="${line#*=}" ;;
    *) continue ;;
  esac
  # Only accept subnet=number
  echo "$key" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]+' || continue
  echo "$val" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || continue
  if [ $first -eq 0 ]; then printf ','; else first=0; fi
  printf '"%s":%s' "$key" "$val"
done < "$CFG"
printf '},"current_month":"%s"}' "$month"

