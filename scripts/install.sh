#!/bin/sh
# Minimal, BusyBox-friendly installer for OpenWrt targets.
# Downloads this repo from GitHub, copies generic assets (static, cgi-bin)
# and fleet-specific files under GRIMALDI/, then renders the WAN status page.
set -eu
export PATH=/sbin:/usr/sbin:/bin:/usr/bin

# Debug utilities
LOG_ENABLED=0
enable_debug(){
  [ "$LOG_ENABLED" -eq 1 ] && return 0
  LOG_ENABLED=1
  # By default don't globally redirect stdout/stderr (that hides SSH output).
  # If you want a logfile, set DEBUG_LOGFILE=1 in the env before calling the script.
  if [ "${DEBUG_LOGFILE:-0}" = "1" ]; then
    exec > /tmp/mwan3_install.log 2>&1
  fi
  set -x
}
dbg(){ if [ "${DEBUG:-0}" = "1" ]; then echo "[DEBUG] $*" >&2; fi }
# Enable early if coming from env
[ "${DEBUG:-0}" = "1" ] && enable_debug || true
# If the caller explicitly requested a debug logfile, enable debug early so
# the logfile capture happens even when DEBUG isn't otherwise set.
[ "${DEBUG_LOGFILE:-0}" = "1" ] && enable_debug || true

# Default to the public deploy-only repo
REPO="${REPO:-peppechiapparo/mwan3status-deploy}"   # owner/repo (override with --repo or env REPO)
BRANCH="${BRANCH:-main}"
FLEET="${FLEET:-GRIMALDI}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --fleet)  FLEET="$2"; shift 2;;
  --tar-file) TAR_FILE_OVERRIDE="$2"; shift 2;;
    --debug)  DEBUG=1; shift 1;;
    --help|-h)
      echo "Usage: install.sh [--repo owner/repo] [--branch main] [--fleet GRIMALDI]";
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# If requested via flag, turn on debug now
[ "${DEBUG:-0}" = "1" ] && enable_debug || true

case "$REPO" in */*) ;; *) echo "REPO must be owner/repo" >&2; exit 1;; esac

OWNER=$(printf '%s' "$REPO" | cut -d/ -f1)
NAME=$(printf '%s' "$REPO" | cut -d/ -f2)
FLEET_LC=$(printf '%s' "$FLEET" | tr 'A-Z' 'a-z')

TMP="/tmp/mwan3deploy.$$"
mkdir -p "$TMP"

# If the caller provided a local tar file (useful when the device cannot reach GitHub/DNS),
# prefer it over network download. Accept via --tar-file or env TAR_FILE_OVERRIDE.
TAR_FILE_OVERRIDE="${TAR_FILE_OVERRIDE:-}"
if [ -n "${TAR_FILE_OVERRIDE}" ]; then
  if [ -s "${TAR_FILE_OVERRIDE}" ]; then
    TAR_FILE="${TAR_FILE_OVERRIDE}"
  else
    echo "Provided tar file ${TAR_FILE_OVERRIDE} does not exist or is empty" >&2
    exit 1
  fi
fi

# Try curl first (OpenWrt 24.10's wget may be restricted), fallback to wget
TAR_URL="https://codeload.github.com/$OWNER/$NAME/tar.gz/$BRANCH"
# Default TAR_FILE path in TMP, but don't overwrite if TAR_FILE was provided via --tar-file / env
[ -z "${TAR_FILE:-}" ] && TAR_FILE="$TMP/repo.tar.gz"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "$TAR_FILE" "$TAR_URL" || true
fi
if [ ! -s "$TAR_FILE" ]; then
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$TAR_FILE" "$TAR_URL" 2>/dev/null || true
  fi
fi
if [ ! -s "$TAR_FILE" ]; then
  echo "Neither curl nor wget could fetch $TAR_URL" >&2
  exit 1
fi

tar -xzf "$TAR_FILE" -C "$TMP"
SRC_BASE="$TMP/$NAME-$BRANCH"

# Prepare destinations
# The webapp now lives under /www/data_usage (not /www/mwan3). Keep /www/cgi-bin for CGI scripts.
mkdir -p /www/data_usage/static /www/cgi-bin /opt/static \
         "/opt/util/$FLEET_LC" /www/data_usage

# 1) Generic assets (available to all fleets)
if [ -d "$SRC_BASE/static" ]; then
  # Install static assets into the data_usage webroot
  mkdir -p /www/data_usage/static 2>/dev/null || true
  cp -f "$SRC_BASE/static"/* /www/data_usage/static/ 2>/dev/null || true
fi
if [ -d "$SRC_BASE/cgi-bin" ]; then
  cp -f "$SRC_BASE/cgi-bin"/*.sh /www/cgi-bin/ 2>/dev/null || true
  chmod +x /www/cgi-bin/*.sh 2>/dev/null || true
fi

# 2) Fleet-specific (e.g., GRIMALDI)
if [ -f "$SRC_BASE/$FLEET/updateMwan3StatusPage.sh" ]; then
  cp -f "$SRC_BASE/$FLEET/updateMwan3StatusPage.sh" /opt/updateMwan3StatusPage.sh
  chmod +x /opt/updateMwan3StatusPage.sh
fi
if [ -d "$SRC_BASE/$FLEET/util" ]; then
  cp -rf "$SRC_BASE/$FLEET/util/." "/opt/util/$FLEET_LC/"
fi

# Copy fleet CGI to production
if [ -d "/opt/util/$FLEET_LC/cgi" ]; then
  cp -f "/opt/util/$FLEET_LC/cgi"/*.sh /www/cgi-bin/ 2>/dev/null || true
  chmod +x /www/cgi-bin/*.sh 2>/dev/null || true
fi

# Ensure lowercase util path exists and copy template for helper compatibility
if [ -d "/opt/util/$FLEET_LC/www" ]; then
  mkdir -p /opt/util/${FLEET_LC}/www
  cp -af /opt/util/${FLEET_LC}/www/. /opt/util/${FLEET_LC}/www/ 2>/dev/null || true
fi
if [ -f "/opt/util/$FLEET_LC/www/index.template.html" ]; then
  mkdir -p /www/data_usage
  cp -f "/opt/util/$FLEET_LC/www/index.template.html" /www/data_usage/ 2>/dev/null || true
fi

# Logo if present
# Logo: place into the data_usage static dir (and keep a copy under /opt/static for compatibility)
if [ -f "$SRC_BASE/static/Telespazio.png" ]; then
  mkdir -p /www/data_usage/static 2>/dev/null || true
  cp -f "$SRC_BASE/static/Telespazio.png" /opt/static/ 2>/dev/null || true
  cp -f "$SRC_BASE/static/Telespazio.png" /www/data_usage/static/ 2>/dev/null || true
fi

# Favicon if present
if [ -f "$SRC_BASE/static/favicon.png" ]; then
  mkdir -p /www/data_usage/static 2>/dev/null || true
  cp -f "$SRC_BASE/static/favicon.png" /opt/static/ 2>/dev/null || true
  cp -f "$SRC_BASE/static/favicon.png" /www/data_usage/static/ 2>/dev/null || true
fi

# Copy optional chart assets if present
# Copy optional chart assets into data_usage static dir if present
if [ -f "$SRC_BASE/static/chart.umd.min.js" ]; then
  mkdir -p /www/data_usage/static 2>/dev/null || true
  cp -f "$SRC_BASE/static/chart.umd.min.js" /www/data_usage/static/ 2>/dev/null || true
fi
if [ -f "$SRC_BASE/static/chart.umd.js.map" ]; then
  mkdir -p /www/data_usage/static 2>/dev/null || true
  cp -f "$SRC_BASE/static/chart.umd.js.map" /www/data_usage/static/ 2>/dev/null || true
fi

# Ensure fleet data_usage dir exists and copy data.json if present
mkdir -p "/opt/util/$FLEET_LC/data_usage" 2>/dev/null || true
if [ -f "$SRC_BASE/data_usage/data.json" ]; then
  cp -f "$SRC_BASE/data_usage/data.json" "/opt/util/$FLEET_LC/data_usage/data.json" 2>/dev/null || true
fi

# If the repository includes copies of data.json or call_log.json, install them
# into the data_usage webroot so templates that request /data_usage/data.json will succeed.
if [ -f "$SRC_BASE/data_usage/data.json" ]; then
  mkdir -p /www/data_usage 2>/dev/null || true
  cp -f "$SRC_BASE/data_usage/data.json" /www/data_usage/data.json 2>/dev/null || true
  chmod 644 /www/data_usage/data.json 2>/dev/null || true
fi
if [ -f "$SRC_BASE/data_usage/call_log.json" ]; then
  mkdir -p /www/data_usage 2>/dev/null || true
  cp -f "$SRC_BASE/data_usage/call_log.json" /www/data_usage/call_log.json 2>/dev/null || true
  chmod 644 /www/data_usage/call_log.json 2>/dev/null || true
fi

# Ensure the webapp has a safe (empty) data.json so pages don't error when the
# cron job that normally generates data hasn't populated files yet (e.g. no
# Starlink modem present). Create a /www/data_usage placeholder idempotently.
mkdir -p /www/data_usage 2>/dev/null || true
if [ ! -s /www/data_usage/data.json ]; then
  printf '%s' '{"labels":[],"values":[],"total":0}' > /www/data_usage/data.json 2>/dev/null || true
  chmod 644 /www/data_usage/data.json 2>/dev/null || true
fi


## Ensure uhttpd instances for WAN status and data_usage are configured deterministically
ensure_uhttpd_sections() {
  # Remove any listen_http entries on the target ports from other sections to avoid duplicate binds
  # Use a pipe->while read loop for BusyBox/ash robustness (avoids quoting/escape issues when pasted)
  /sbin/uci show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^=]*\)=uhttpd.*$/\1/p' | uniq | while IFS= read -r s; do
    [ -z "$s" ] && continue
    # Skip if section is not present
    cur=$(/sbin/uci -q get uhttpd."$s".listen_http 2>/dev/null || true)
    case "$cur" in
      *5500* )
        if [ "$s" != "mwan3" ]; then /sbin/uci -q delete uhttpd."$s".listen_http 2>/dev/null || true; fi
        ;;
      *9000* )
        if [ "$s" != "data_usage" ]; then /sbin/uci -q delete uhttpd."$s".listen_http 2>/dev/null || true; fi
        ;;
    esac
  done

  # Remove legacy 'mwan3' section entirely to avoid stale index_page/home entries
  /sbin/uci -q delete uhttpd.mwan3 2>/dev/null || true
  # Remove any existing listen_http entries on non-wanted ports to avoid duplicate binds
  /sbin/uci -q show uhttpd 2>/dev/null | sed -n 's/^uhttpd\.\([^=]*\)=uhttpd.*$/\1/p' | uniq | while IFS= read -r s; do
    [ -z "$s" ] && continue
    # remove listen entries that bind to 8000 or other unexpected ports
    cur=$(/sbin/uci -q get uhttpd."$s".listen_http 2>/dev/null || true)
    case "$cur" in
      *:8000* ) /sbin/uci -q delete uhttpd."$s".listen_http 2>/dev/null || true ;;
    esac
  done

  # Recreate/ensure a single 'data_usage' section with the desired values
  /sbin/uci -q delete uhttpd.data_usage 2>/dev/null || true
  sec2=$(/sbin/uci -q add uhttpd uhttpd 2>/dev/null || echo "")
  if [ -n "$sec2" ]; then
    /sbin/uci -q rename uhttpd.$sec2=data_usage 2>/dev/null || true
  fi
  /sbin/uci -q set uhttpd.data_usage=uhttpd 2>/dev/null || true
  /sbin/uci -q set uhttpd.data_usage.home=/www/data_usage 2>/dev/null || true
  /sbin/uci -q delete uhttpd.data_usage.listen_http 2>/dev/null || true
  /sbin/uci -q add_list uhttpd.data_usage.listen_http=0.0.0.0:5500 2>/dev/null || true
  /sbin/uci -q set uhttpd.data_usage.index_page=index.html 2>/dev/null || true
  # ensure CGI prefix is present and correct; uhttpd expects cgi_prefix (default /cgi-bin) if needed
  /sbin/uci -q set uhttpd.data_usage.cgi_prefix=/cgi-bin 2>/dev/null || true

  # Commit and restart, then verify binds
  /sbin/uci -q commit uhttpd 2>/dev/null || true
  /etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/uhttpd reload 2>/dev/null || true

  # Wait a moment and check for listeners on the desired ports
  sleep 1
  if command -v ss >/dev/null 2>&1; then
    /bin/sh -c "ss -ltn | grep -E ':(5500|9000)\b' >/dev/null 2>&1"
    ok=$?
  else
    /bin/sh -c "netstat -ltn | grep -E ':(5500|9000)\b' >/dev/null 2>&1"
    ok=$?
  fi
  if [ "$ok" -ne 0 ]; then
    echo "WARNING: uhttpd does not appear to be listening on 5500/9000 after restart" >&2
  fi
}

ensure_uhttpd_sections

# Render/update page
if [ -x /opt/updateMwan3StatusPage.sh ]; then
  /opt/updateMwan3StatusPage.sh || true
fi

echo "Deployment completed for fleet $FLEET from $REPO@$BRANCH"
exit 0
