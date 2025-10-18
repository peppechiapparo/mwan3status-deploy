#!/bin/sh
set -eu
echo "Content-Type: text/plain"
echo
# Restituisce l'intero blocco Active ipv4 user rules (il filtro avviene lato client)
mwan3 status 2>/dev/null | awk '
  /^Active ipv4 user rules:/ { c=1; next }
  c && /^Active ipv6 user rules:/ { exit }
  c { print }
'

