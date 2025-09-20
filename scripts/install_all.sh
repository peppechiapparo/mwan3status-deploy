#!/bin/sh
# Orchestrates install.sh on multiple routers listed in a CSV.
# CSV format: first column must be hostname or ip; lines starting with # are ignored.
set -eu

CSV="${CSV:-GRIMALDI/grimaldi_list_hostname.csv}"
# Default to the public deploy-only repo
REPO="${REPO:-peppechiapparo/mwan3status-deploy}"
BRANCH="${BRANCH:-main}"
FLEET="${FLEET:-GRIMALDI}"
PAR="${PARALLEL:-4}"

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)    CSV="$2"; shift 2;;
    --repo)   REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --fleet)  FLEET="$2"; shift 2;;
    --parallel) PAR="$2"; shift 2;;
    --help|-h)
      echo "Usage: install_all.sh [--csv path] [--repo owner/repo] [--branch main] [--fleet GRIMALDI] [--parallel 4]";
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/scripts/install.sh"

i=0
fail=0
cat "$CSV" | while IFS=, read -r host rest; do
  # sanitize and skip comments/empty
  host=$(printf '%s' "$host" | sed 's/^\s*//; s/\s*$//')
  [ -z "$host" ] && continue
  case "$host" in \#*) continue;; esac

  i=$((i+1))
  (
    echo "[${host}] starting deploy" >&2
    # Run installer, then fallback UCI if missing, then HTTP check on 9000
    REMOTE_CMD='
set -eu
installer_ok=0
if wget -qO- '"$RAW_URL"' 2>/dev/null | sh -s -- --repo '"$REPO"' --branch '"$BRANCH"' --fleet '"$FLEET"'; then
  installer_ok=1
fi
if ! /sbin/uci -q show uhttpd.mwan3 >/dev/null 2>&1; then
  /sbin/uci set uhttpd.mwan3=uhttpd || true
  /sbin/uci set uhttpd.mwan3.home=/www || true
  /sbin/uci delete uhttpd.mwan3.listen_http >/dev/null 2>&1 || true
  /sbin/uci add_list uhttpd.mwan3.listen_http=0.0.0.0:9000 || true
  /sbin/uci set uhttpd.mwan3.redirect_https=0 || true
  /sbin/uci set uhttpd.mwan3.index_page=mwan3/index.html || true
  /sbin/uci commit uhttpd || true
  /etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
fi
uci_ok=0; /sbin/uci -q show uhttpd.mwan3 >/dev/null 2>&1 && uci_ok=1
http_ok=0; (wget -qO- http://127.0.0.1:9000/ >/dev/null 2>&1 || curl -sSf http://127.0.0.1:9000/ >/dev/null 2>&1) && http_ok=1
echo "__RESULT__ INSTALLER=$installer_ok UCI=$uci_ok HTTP=$http_ok"
if [ "$http_ok" -eq 1 ]; then exit 0; else exit 2; fi
'
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "root@${host}" "$REMOTE_CMD" 2>&1)
    rc=$?
    echo "[${host}] $out" >&2
    if [ $rc -eq 0 ]; then
      echo "[${host}] OK (HTTP 9000 reachable)" >&2
    else
      echo "[${host}] FAILED (HTTP 9000 not reachable)" >&2
      exit 1
    fi
  ) &
  # fan-out control
  if [ $((i % PAR)) -eq 0 ]; then wait || fail=1; fi
done

wait || fail=1
exit $fail
