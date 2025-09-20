#!/bin/sh
set -eu
echo "Content-Type: application/json"
echo
VER="unknown"
if [ -f /www/mwan3/version.json ]; then
  # prefer JSON file
  VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /www/mwan3/version.json 2>/dev/null || true)
fi
if [ "$VER" = "" ]; then
  if [ -f /www/mwan3/VERSION.txt ]; then
    VER=$(sed -n '1p' /www/mwan3/VERSION.txt 2>/dev/null || true)
  fi
fi
UP="0"
if [ -f /proc/uptime ]; then
  UP=$(awk '{print int($1)}' /proc/uptime || echo 0)
fi
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat <<EOF
{
  "status": "ok",
  "version": "${VER}",
  "uptime_seconds": ${UP},
  "timestamp": "${TS}"
}
EOF
