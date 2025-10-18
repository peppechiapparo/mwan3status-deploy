#!/usr/bin/env bash
# Orchestrates install.sh on multiple routers listed in a CSV.
# CSV format: first column must be hostname or ip; lines starting with # are ignored.
set -eu

CSV="${CSV:-GRIMALDI/grimaldi_list_hostname.csv}"
REPO="${REPO:-peppechiapparo/mwan3status-deploy}"
BRANCH="${BRANCH:-main}"
FLEET="${FLEET:-GRIMALDI}"
PAR="${PARALLEL:-4}"
SSH_OPTS="${SSH_OPTS:- -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INCOMPLETE="${INCOMPLETE:-$BASE_DIR/incompleted_deploy.txt}"
PING_THRESHOLD_MS="${PING_THRESHOLD_MS:-900}"
STANDBY="${STANDBY:-$BASE_DIR/grimaldi_standby.csv}"
REMAINING="${REMAINING:-$BASE_DIR/grimaldi_remaining.csv}"
ERROR_CSV="${ERROR_CSV:-$BASE_DIR/grimaldi_error.csv}"
# Auto-generate/refresh list settings
AUTO_GEN="${AUTO_GEN:-0}"              # 1 to enable stale-file regeneration; always runs if CSV missing
CSV_MAX_AGE_MIN="${CSV_MAX_AGE_MIN:-60}" # consider CSV stale if older than N minutes
FORCE_REFRESH="0"
: > "$STANDBY" 2>/dev/null || true
: > "$REMAINING" 2>/dev/null || true
: > "$ERROR_CSV" 2>/dev/null || true

while [ $# -gt 0 ]; do
  case "$1" in
    --csv) CSV="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --fleet) FLEET="$2"; shift 2;;
    --parallel) PAR="$2"; shift 2;;
    --refresh-list) FORCE_REFRESH="1"; AUTO_GEN="1"; shift 1;;
    --help|-h)
      echo "Usage: install_all.sh [--csv path] [--repo owner/repo] [--branch main] [--fleet GRIMALDI] [--parallel 4] [--refresh-list]";
      echo "Env (optional): AUTO_GEN=1 CSV_MAX_AGE_MIN=60 ORG=... NETWORK=... TOKEN=... ZTNET_URL=http://...";
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/scripts/install.sh"

# Optionally generate/refresh the fleet CSV from ztnet before deploy
maybe_generate_list() {
  local gen_script="$BASE_DIR/scripts/generate_grimaldi_list.sh"
  [ -x "$gen_script" ] || return 0

  local need=0
  # Always generate if forced
  [ "$FORCE_REFRESH" = "1" ] && need=1

  # Generate if CSV missing/empty
  if [ "$need" -eq 0 ]; then
    [ ! -s "$CSV" ] && need=1
  fi

  # Generate if AUTO_GEN enabled and file is stale
  if [ "$need" -eq 0 ] && [ "$AUTO_GEN" = "1" ] && [ -f "$CSV" ]; then
    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$CSV" 2>/dev/null || echo 0)
    age=$(( (now - mtime) / 60 ))
    if [ "$age" -ge "$CSV_MAX_AGE_MIN" ]; then
      need=1
    fi
  fi

  if [ "$need" -eq 1 ]; then
    local ORG_E NET_E TOK_E URL_E
    ORG_E="${ORG:-}"
    NET_E="${NETWORK:-${GRIMALDI:-}}"
    TOK_E="${TOKEN:-${ZTNET_TOKEN:-}}"
    URL_E="${ZTNET_URL:-http://10.1.33.12:3000}"
    if [ -n "$ORG_E" ] && [ -n "$NET_E" ] && [ -n "$TOK_E" ]; then
      echo "[pre] Generating fleet CSV via ztnet API (ORG=$ORG_E NET=$NET_E) -> $CSV" >&2
      ORG="$ORG_E" NETWORK="$NET_E" TOKEN="$TOK_E" "$gen_script" --url "$URL_E" --out "$CSV" || {
        echo "[pre] Generation failed; proceeding with existing CSV if present: $CSV" >&2
      }
    else
      echo "[pre] CSV generation requested but missing ORG/NETWORK/TOKEN environment; skipping." >&2
    fi
  fi
}

# Run pre-generation step
maybe_generate_list

# run the remote installer and verify version/helper
run_on_host() {
  host="$1"
  echo "[${host}] starting deploy" >&2
  ssh $SSH_OPTS "root@${host}" "RAW_URL='${RAW_URL}' REPO='${REPO}' BRANCH='${BRANCH}' FLEET='${FLEET}' EXPECTED_VERSION='${EXPECTED_VERSION:-1.5}' sh -s" <<'REMOTE'
set -eu
installer_ok=0
HOST_TO_RESOLVE="raw.githubusercontent.com"
TS_BACKUP="$(date -u +%Y%m%dT%H%M%SZ)"

# Create backups of important artifacts before attempting changes
if [ -d /www/data_usage ]; then
  tar -czf /tmp/data_usage.bak.${TS_BACKUP}.tar.gz -C /www data_usage >/dev/null 2>&1 || true
fi
if [ -f /opt/updateMwan3StatusPage.sh ]; then
  cp -a /opt/updateMwan3StatusPage.sh /opt/updateMwan3StatusPage.sh.bak.${TS_BACKUP} >/dev/null 2>&1 || true
fi
if [ -f /etc/config/uhttpd ]; then
  cp -a /etc/config/uhttpd /tmp/uhttpd.bak.${TS_BACKUP} >/dev/null 2>&1 || true
fi

# Check whether the host can resolve raw.githubusercontent.com before attempting remote download
resolvable=0
if command -v nslookup >/dev/null 2>&1; then
  if nslookup "$HOST_TO_RESOLVE" >/dev/null 2>&1; then resolvable=1; fi
elif command -v getent >/dev/null 2>&1; then
  if getent hosts "$HOST_TO_RESOLVE" >/dev/null 2>&1; then resolvable=1; fi
else
  if command -v curl >/dev/null 2>&1; then
    if curl -sSI --max-time 5 "https://${HOST_TO_RESOLVE}/" >/dev/null 2>&1; then resolvable=1; fi
  fi
fi

if [ "$resolvable" -eq 1 ]; then
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$RAW_URL" | sh -s -- --repo "$REPO" --branch "$BRANCH" --fleet "$FLEET"; then
      installer_ok=1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -qO- "$RAW_URL" 2>/dev/null | sh -s -- --repo "$REPO" --branch "$BRANCH" --fleet "$FLEET"; then
      installer_ok=1
    fi
  else
    echo "neither curl nor wget available on target" >&2
  fi
else
  echo "[target] DNS resolution failed for $HOST_TO_RESOLVE; skipping remote download and falling back to controller scp" >&2
fi

# ensure uhttpd contexts and restart (installer should handle most of this)
/sbin/uci -q delete uhttpd.mwan3 2>/dev/null || true
/sbin/uci -q delete uhttpd.data_usage 2>/dev/null || true
/sbin/uci -q add uhttpd uhttpd >/dev/null 2>&1 || true
sec=$(/sbin/uci -q show uhttpd 2>/dev/null | sed -n "s/^uhttpd\.\([^=]*\)=uhttpd/\1/p" | tail -n1)
/sbin/uci -q rename uhttpd.$sec=data_usage 2>/dev/null || true
/sbin/uci -q set uhttpd.data_usage.home=/www/data_usage 2>/dev/null || true
/sbin/uci -q delete uhttpd.data_usage.listen_http 2>/dev/null || true
/sbin/uci -q add_list uhttpd.data_usage.listen_http=0.0.0.0:5500 2>/dev/null || true
/sbin/uci -q set uhttpd.data_usage.index_page=index.html 2>/dev/null || true
/sbin/uci -q set uhttpd.data_usage.cgi_prefix=/cgi-bin 2>/dev/null || true
/sbin/uci commit uhttpd >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd reload >/dev/null 2>&1 || true

# helper to parse version
get_remote_version() {
  if [ -f /www/data_usage/version.json ]; then
    v=$(cat /www/data_usage/version.json 2>/dev/null | sed -n 's/.*"version"\s*:\s*"\([^"]\+\)".*/\1/p' | head -n1 || true)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  if [ -f /www/data_usage/index.html ]; then
    v=$(sed -n 's/.*<!--\s*webapp-version:\s*\([^ ]\+\)\s*-->.*/\1/p' /www/data_usage/index.html | head -n1 || true)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  return 1
}

webapp_ok=0
remote_version=''
# portable capture
remote_version=$(get_remote_version 2>/dev/null || true) || remote_version=''
if [ -n "$remote_version" ]; then
  if [ "$remote_version" = "$EXPECTED_VERSION" ]; then
    webapp_ok=1
  else
    webapp_ok=0
  fi
fi

helper_ok=0
[ -f /opt/updateMwan3StatusPage.sh ] && helper_ok=1 || helper_ok=0

# Additional verification checks
uhttpd_ok=0
cgi_ok=0
static_ok=0
scripts_ok=0

# Check uhttpd settings: data_usage exists and correct listen/index/cgi_prefix
if /sbin/uci -q show uhttpd >/dev/null 2>&1; then
  if /sbin/uci -q get uhttpd.data_usage.home 2>/dev/null | grep -q '/www/data_usage'; then
    listen_ok=$( /sbin/uci -q get uhttpd.data_usage.listen_http 2>/dev/null || true )
    idx_ok=$( /sbin/uci -q get uhttpd.data_usage.index_page 2>/dev/null || true )
    cgi_pref=$( /sbin/uci -q get uhttpd.data_usage.cgi_prefix 2>/dev/null || true )
    if echo "$listen_ok" | grep -q '0.0.0.0:5500' && [ "$idx_ok" = "index.html" ] && [ "$cgi_pref" = "/cgi-bin" ]; then
      uhttpd_ok=1
    fi
  fi
fi

# Check CGI presence under /www/data_usage/cgi-bin and quick HTTP check
if [ -d /www/data_usage/cgi-bin ]; then
  # look for at least one expected script
  if [ -f /www/data_usage/cgi-bin/mwan3_json.sh ] || [ -f /www/data_usage/cgi-bin/ifbytes.sh ]; then
    # local curl to CGI
    ccode=$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5500/cgi-bin/mwan3_json.sh || true)
    if [ "$ccode" = "200" ]; then cgi_ok=1; fi
    scripts_ok=1
  fi
fi

# Check static asset
[ -f /www/data_usage/static/Telespazio.png ] && static_ok=1 || static_ok=0

echo "__RESULT__ INSTALLER=$installer_ok UCI=1 WEBAPP=$webapp_ok VERSION=${remote_version:-unknown} HELPER=$helper_ok UHTTPD=$uhttpd_ok CGI=$cgi_ok STATIC=$static_ok SCRIPTS=$scripts_ok"

if [ "$webapp_ok" -eq 1 ] && [ "$helper_ok" -eq 1 ] && [ "$uhttpd_ok" -eq 1 ] && [ "$cgi_ok" -eq 1 ] && [ "$static_ok" -eq 1 ] && [ "$scripts_ok" -eq 1 ]; then
  exit 0
else
  echo "--- VERIFICATION FAILED: dumping diagnostics and attempting rollback ---"
  echo "--- UHTTPD UCI ---"
  /sbin/uci show uhttpd || true
  echo "--- LISTENERS ---"
  ( ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null ) || true
  echo "--- /www/data_usage listing ---"
  ls -la /www/data_usage || true
  echo "--- /opt listing ---"
  ls -la /opt || true
  echo "--- LAST LOGS (logread) ---"
  logread | tail -n 80 || true

  # Attempt rollback from backups created earlier
  echo "--- attempting rollback from backups (if present) ---"
  if [ -f /tmp/data_usage.bak.${TS_BACKUP}.tar.gz ]; then
    rm -rf /www/data_usage || true
    tar -xzf /tmp/data_usage.bak.${TS_BACKUP}.tar.gz -C /www || true
  fi
  if [ -f /opt/updateMwan3StatusPage.sh.bak.${TS_BACKUP} ]; then
    mv -f /opt/updateMwan3StatusPage.sh.bak.${TS_BACKUP} /opt/updateMwan3StatusPage.sh || true
  fi
  if [ -f /tmp/uhttpd.bak.${TS_BACKUP} ]; then
    cp -f /tmp/uhttpd.bak.${TS_BACKUP} /etc/config/uhttpd || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || /etc/init.d/uhttpd reload >/dev/null 2>&1 || true
  fi

  exit 2
fi
REMOTE

  rc=$?
  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  echo "[${host}] initial remote installer failed (rc=${rc}), attempting scp fallback" >&2

  # Prepare local artifact paths and tarball URL
  OWNER=$(printf '%s' "$REPO" | cut -d/ -f1)
  NAME=$(printf '%s' "$REPO" | cut -d/ -f2)
  TAR_URL="https://codeload.github.com/${OWNER}/${NAME}/tar.gz/${BRANCH}"
  ARTIFACT_DIR="$BASE_DIR/artifacts"
  mkdir -p "$ARTIFACT_DIR" 2>/dev/null || true
  LOCAL_TAR="$ARTIFACT_DIR/${NAME}-${BRANCH}.tar.gz"

  # Download tarball on controller if not present
  if [ ! -s "$LOCAL_TAR" ]; then
    echo "[controller] downloading $TAR_URL -> $LOCAL_TAR" >&2
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$LOCAL_TAR" "$TAR_URL" || true
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$LOCAL_TAR" "$TAR_URL" || true
    fi
  fi
  if [ ! -s "$LOCAL_TAR" ]; then
    echo "[controller] failed to download tarball; cannot perform scp fallback" >&2
    return $rc
  fi

  # Copy tarball and installer script to target
  echo "[${host}] scp tarball and installer to target" >&2
  scp $SSH_OPTS -q "$LOCAL_TAR" "root@${host}:/tmp/repo.tar.gz" || { echo "[${host}] scp tar failed" >&2; return 2; }
  scp $SSH_OPTS -q "$BASE_DIR/scripts/install.sh" "root@${host}:/tmp/install.sh" || { echo "[${host}] scp install.sh failed" >&2; return 2; }

  # Run installer on target using local tarball
  echo "[${host}] running installer from local tarball on target" >&2
  ssh -n $SSH_OPTS "root@${host}" "DEBUG_LOGFILE=1 sh -x /tmp/install.sh --tar-file /tmp/repo.tar.gz --repo '$REPO' --branch '$BRANCH' --fleet '$FLEET'"
  rc2=$?
  return $rc2
}

# iterate CSV and spawn workers with basic fan-out control
i=0
fail=0
# Normalize potential CRLF to LF on the fly and iterate robustly
# Also add a per-line progress echo to diagnose early loop exits
while IFS=, read -r name target rest; do
  # strip CRs and surrounding spaces
  name=$(printf '%s' "$name" | tr -d '\r' | sed 's/^\s*//; s/\s*$//')
  target=$(printf '%s' "$target" | tr -d '\r' | sed 's/^\s*//; s/\s*$//')
  rest=$(printf '%s' "$rest" | tr -d '\r')
  [ -z "$name" ] && continue
  case "$name" in \#*|'') continue;; esac
  echo "[LOOP] row: name=$name target=$target" >&2
  # above normalization already trimmed; proceed
  # If CSV contains two columns (name,ip), prefer ip as target for network operations
  if [ -n "$target" ]; then
    host="$target"
  else
    host="$name"
  fi

  # ping gate (robust): unreachable -> remaining, high latency -> standby
  if command -v ping >/dev/null 2>&1; then
    pingout="$(ping -c 3 -w 5 "$host" 2>/dev/null || true)"

    # Quick check: any packets received? Look for 'received' number in ping summary.
    received=$(printf '%s' "$pingout" | awk -F',' '/packet loss/ {gsub(/^[ \t]*/,"",$2); print $2; exit}' | sed -n 's/.* \([0-9]\+\) received.*/\1/p' || true)
    # If we didn't get a 'received' parse above, also try a simpler approach
    if [ -z "$received" ]; then
      received=$(printf '%s' "$pingout" | sed -n 's/.*, \([0-9]\+\) received,.*/\1/p' || true)
    fi

    # If zero received or we couldn't see any received packets, treat as unreachable
    if [ -z "$received" ] || [ "$received" -eq 0 ] 2>/dev/null; then
      echo "[${name}] SKIPPED (no ping response) - added to remaining" >&2
      printf '%s,%s\n' "${name}" "${host}" >> "${REMAINING}" || true
      continue
    fi

    # Try multiple strategies to extract avg RTT: awk for 'rtt' or 'round-trip' first, sed fallback.
    avg=""
    avg=$(printf '%s' "$pingout" | awk -F'/' '/rtt|round-trip/ {print $5; exit}') || true
    if [ -z "$avg" ]; then
      avg=$(printf '%s' "$pingout" | sed -n 's/.*= *\([0-9.,]*\)\/\([0-9.,]*\)\/\([0-9.,]*\).*/\2/p' || true)
    fi
    # normalize comma decimals to dots in locales that use commas
    avg=$(printf '%s' "$avg" | tr ',' '.' )

    if [ -z "$avg" ]; then
      # no avg extracted; but we already have some received packets — be conservative and proceed with deploy
      avg_ms=0
    else
      avg_ms=$(printf '%s' "$avg" | awk '{printf "%d", $0}')
    fi

    if [ "$avg_ms" -ge "$PING_THRESHOLD_MS" ]; then
      echo "[${name}] SKIPPED (high ping ${avg_ms} ms >= ${PING_THRESHOLD_MS} ms) - added to standby" >&2
      printf '%s,%s\n' "${name}" "${host}" >> "${STANDBY}" || true
      continue
    fi
  fi

  i=$((i+1))
  (
    if run_on_host "$host"; then
      echo "[${name}] OK (WEBAPP version matched and helper present)" >&2
      # Post-install: ensure default UI config exists and generator runs on target
      # 1) Copy generator if present locally
      GEN_LOCAL="$BASE_DIR/GRIMALDI/util/conf/generate_config.sh"
      if [ -f "$GEN_LOCAL" ]; then
        scp $SSH_OPTS -q "$GEN_LOCAL" "root@${host}:/opt/util/grimaldi/conf/generate_config.sh" 2>/dev/null || true
        ssh $SSH_OPTS "root@${host}" 'chmod +x /opt/util/grimaldi/conf/generate_config.sh 2>/dev/null || true' || true
      fi
      # 2) Create default config if missing
      ssh $SSH_OPTS "root@${host}" 'mkdir -p /opt/conf && [ -f /opt/conf/data_usage.conf ] || cat > /opt/conf/data_usage.conf << '\''EOF'\''
hide:
  flows: true
  rules: true
  fleetone: false
  connected_users: false
  interfaces: false
  usage: false
auto:
  fleetone_if_missing: true
  connected_if_empty: true
EOF' 2>/dev/null || true
      # 3) Run generator to emit static JSON
      ssh $SSH_OPTS "root@${host}" '/opt/util/grimaldi/conf/generate_config.sh >/dev/null 2>&1 || true' || true
    else
      echo "[${name}] FAILED (webapp/version/helper mismatch)" >&2
      printf '%s,%s\n' "${name}" "${host}" >> "${INCOMPLETE}" || true
      fail=1
    fi
  ) </dev/null &

  if [ $((i % PAR)) -eq 0 ]; then
    wait || true
  fi
done < <(sed 's/\r$//' "$CSV")

wait || true
exit ${fail:-0}
