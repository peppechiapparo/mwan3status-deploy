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
  exec > /tmp/mwan3_install.log 2>&1
  set -x
}
dbg(){ if [ "${DEBUG:-0}" = "1" ]; then echo "[DEBUG] $*" >&2; fi }
# Enable early if coming from env
[ "${DEBUG:-0}" = "1" ] && enable_debug || true

# Default to the public deploy-only repo
REPO="${REPO:-peppechiapparo/mwan3status-deploy}"   # owner/repo (override with --repo or env REPO)
BRANCH="${BRANCH:-main}"
FLEET="${FLEET:-GRIMALDI}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)   REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --fleet)  FLEET="$2"; shift 2;;
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

# Try wget tarball first; fallback to curl
TAR_URL="https://codeload.github.com/$OWNER/$NAME/tar.gz/$BRANCH"
TAR_FILE="$TMP/repo.tar.gz"
if ! wget -q -O "$TAR_FILE" "$TAR_URL" 2>/dev/null; then
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TAR_FILE" "$TAR_URL"
  else
    echo "Neither wget nor curl available to fetch $TAR_URL" >&2
    exit 1
  fi
fi

tar -xzf "$TAR_FILE" -C "$TMP"
SRC_BASE="$TMP/$NAME-$BRANCH"

# Prepare destinations
mkdir -p /www/static /www/cgi-bin /www/mwan3/static /opt/static \
         "/opt/util/$FLEET_LC" /www/mwan3

# 1) Generic assets (available to all fleets)
if [ -d "$SRC_BASE/static" ]; then
  cp -f "$SRC_BASE/static"/* /www/static/ 2>/dev/null || true
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

# Logo if present
if [ -f "$SRC_BASE/static/Telespazio.png" ]; then
  mkdir -p /www/mwan3/static
  cp -f "$SRC_BASE/static/Telespazio.png" /opt/static/ 2>/dev/null || true
  cp -f "$SRC_BASE/static/Telespazio.png" /www/mwan3/static/ 2>/dev/null || true
fi


# Ensure uhttpd instance for WAN status is configured and reloaded (idempotent, solo UCI)
ensure_uhttpd_mwan3() {
  # 1) Crea la sezione se non esiste
  if ! /sbin/uci -q get uhttpd.mwan3 >/dev/null 2>&1; then
    sec=$(/sbin/uci -q add uhttpd uhttpd 2>/dev/null || echo "")
    [ -n "$sec" ] && /sbin/uci -q rename uhttpd.$sec=mwan3 2>/dev/null || true
    /sbin/uci -q set uhttpd.mwan3=uhttpd 2>/dev/null || true
  fi
  # 2) Opzioni
  /sbin/uci -q set uhttpd.mwan3.home=/www 2>/dev/null || true
  /sbin/uci -q delete uhttpd.mwan3.listen_http 2>/dev/null || true
  /sbin/uci -q add_list uhttpd.mwan3.listen_http=0.0.0.0:9000 2>/dev/null || true
  /sbin/uci -q set uhttpd.mwan3.redirect_https=0 2>/dev/null || true
  /sbin/uci -q set uhttpd.mwan3.index_page=mwan3/index.html 2>/dev/null || true
  # 3) Commit e restart
  /sbin/uci -q commit uhttpd 2>/dev/null || true
  /etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/uhttpd reload 2>/dev/null || true
}

ensure_uhttpd_mwan3

# Render/update page
if [ -x /opt/updateMwan3StatusPage.sh ]; then
  /opt/updateMwan3StatusPage.sh || true
fi

echo "Deployment completed for fleet $FLEET from $REPO@$BRANCH"
exit 0
