#!/bin/sh
# CGI: robust JSON endpoint for connected users
set -eu
IFS=$' \t\n'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo

# locate chilli_query and awk
CHILLI_BIN="$(command -v chilli_query 2>/dev/null || echo /usr/sbin/chilli_query)"
AWK_BIN="$(command -v awk 2>/dev/null || echo /usr/bin/awk)"

if [ ! -x "$CHILLI_BIN" ]; then
  printf '{"error":"chilli_query not found"}\n'
  exit 1
fi

# Produce JSON directly from awk to avoid fragile table parsing in shell
# awk will emit array of objects
"$CHILLI_BIN" list | "$AWK_BIN" '
function hms(sec){ h=int(sec/3600); m=int((sec%3600)/60); s=sec%60; return sprintf("%02d:%02d:%02d",h,m,s) }
function mib(b){ return sprintf("%.1f", b/1048576) }
BEGIN{ printf("["); first=1 }
$3=="pass" && $5==1 {
  split($7,t,"/"); split($9,rx,"/"); split($10,tx,"/"); limitB = ($11+0)>0 ? $11 : 0
  mac=$1; ip=$2; user=$6; uptime=hms(t[1]); limt=hms(t[2]); rxm=mib(rx[1]); txm=mib(tx[1]); limmb=(limitB? mib(limitB) : "∞")
  # compute data in MB as rx + tx (numeric addition)
  data_mb = sprintf("%.1f", (rx[1]+0)/1048576 + (tx[1]+0)/1048576)
  # escape backslashes and double quotes in fields
  gsub(/\\/,"\\\\",mac); gsub(/"/,"\\\"",mac)
  gsub(/\\/,"\\\\",ip);  gsub(/"/,"\\\"",ip)
  gsub(/\\/,"\\\\",user);gsub(/"/,"\\\"",user)
  if(!first) printf(","); first=0
  printf("{\"mac\":\"%s\",\"ip\":\"%s\",\"user\":\"%s\",\"uptime\":\"%s\",\"lim_t\":\"%s\",\"rx_mb\":\"%s\",\"tx_mb\":\"%s\",\"lim_mb\":\"%s\",\"data_mb\":\"%s\"}", mac, ip, user, uptime, limt, rxm, txm, limmb, data_mb)
}
END{ print "]" }
'
