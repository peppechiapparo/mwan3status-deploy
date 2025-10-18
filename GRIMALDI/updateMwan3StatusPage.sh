#!/bin/sh
set -eu

# Determine script directory to locate static assets and util files
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"


# Determine ACTIVE interface from Current ipv4 policies (single customer)
ACTIVE_IFACE="$(
  mwan3 status 2>/dev/null |
  awk '
    /^Current ipv4 policies:/ { f=1; next }
    f && /^Current ipv6 policies:/ { f=0 }
    f {
      while (match($0, /([A-Za-z0-9_]+) \(([0-9]+)%\)/, m)) {
        name=m[1]; pct=m[2]+0; sum[name]+=pct;
        $0=substr($0, RSTART+RLENGTH)
      }
    }
    END{ best=""; bestv=-1; for(n in sum){ if(sum[n]>bestv){ bestv=sum[n]; best=n } } if(best!="") print best; }
  '
)"

# Fallback: first online interface if none detected
if [ -z "$ACTIVE_IFACE" ]; then
  ACTIVE_IFACE="$(mwan3 status 2>/dev/null | awk '/^ interface [A-Za-z0-9_]+ is online/{sub(/^ interface /,""); sub(/ is online.*/,""); print; exit}')"
fi

IFACE="${ACTIVE_IFACE:-}"


# Rimuovi l'eventuale suffisso di percentuale " (100%)" dall'ACTIVE
IFACE="$(printf '%s' "$IFACE" | sed -E 's/ \([0-9]+%\)//g')"

# Costruisci dinamicamente l'elenco subnet da network+mwan3 e usalo ovunque
prefix_to_mask() {
  # arg: prefix number, outputs dotted mask
  p="$1"; [ -z "$p" ] && return 1
  set -- 0 0 0 0; i=0
  while [ $i -lt 4 ]; do
    b=$(( p>8 ? 8 : (p<0 ? 0 : p) ))
    case $b in
      8) v=255;; 7) v=254;; 6) v=252;; 5) v=248;; 4) v=240;; 3) v=224;; 2) v=192;; 1) v=128;; 0) v=0;;
    esac
    eval m$i=$v
    p=$((p-8)); i=$((i+1))
  done
  printf '%d.%d.%d.%d' "$m0" "$m1" "$m2" "$m3"
}

cidr_to_network() {
  # input: X.Y.Z.W/NN -> print NETWORK/NN using ipcalc.sh
  cidr="$1"; ip="${cidr%/*}"; pfx="${cidr#*/}"
  # pfx may be numeric prefix or dotted netmask
  case "$pfx" in
    *.*) mask="$pfx" ;;
    *)   mask="$(prefix_to_mask "$pfx")" || return 1 ;;
  esac
  eval "$(/bin/ipcalc.sh "$ip" "$mask" | sed -n -e 's/^NETWORK=\(.*\)/NET=\1/p' -e 's/^PREFIX=\(.*\)/PFX=\1/p')"
  [ -n "$NET" ] && [ -n "$PFX" ] && echo "$NET/$PFX"
}

build_src_nets() {
  # 1) Sezioni note (compatibilità con altri modelli)
  for IF in BUSINESS_LAN CORP_LAN CREW_LAN; do
    VALS="$(uci -q get network.$IF.ipaddr 2>/dev/null || true)"
    for token in $VALS; do case "$token" in */*) cidr_to_network "$token" || true ;; esac; done
  done
  # 2) Tutte le interfacce UCI che puntano a device su eth0.X
  for S in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^=]*\)=interface/\1/p"); do
    DEV="$(uci -q get network.$S.device 2>/dev/null || uci -q get network.$S.ifname 2>/dev/null || true)"
    echo "$DEV" | grep -Eq '(^|[[:space:]])eth0(\.|$)' || echo "$DEV" | grep -Eq '(^|[[:space:]])eth0\.' || DEV=""
    [ -z "$DEV" ] && continue
    VALS="$(uci -q get network.$S.ipaddr 2>/dev/null || true)"
    MASK="$(uci -q get network.$S.netmask 2>/dev/null || true)"
    if [ -n "$VALS" ]; then
      for token in $VALS; do
        case "$token" in
          */*) cidr_to_network "$token" || true ;;
          *) if [ -n "$MASK" ]; then cidr_to_network "$token/${MASK}" || true; fi ;;
        esac
      done
    fi
  done
  # Subnet da regole mwan3 (src_ip) — supporta sia rule.NAME sia @rule[index]
  uci -q show mwan3 2>/dev/null \
    | awk -F= '/^mwan3\.(rule\.|@rule\[).*\.src_ip=/{print $2}' \
    | tr ' ' '\n' \
    | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]+' \
    | while read -r c; do cidr_to_network "$c" || true; done \
    | sort -u || true
}

SRC_NETS_LIST="$(build_src_nets | sort -u)"
SRC_NETS_JSON="$(printf '%s\n' $SRC_NETS_LIST | awk 'BEGIN{printf "["} {if(NR>1)printf ","; gsub(/"/,"\\\""); printf "\"%s\"", $0} END{printf "]"}')"

# Build EXCLUDE nets from interfaces with name containing MGMNT
build_mgmnt_nets(){
  uci -q show network 2>/dev/null \
  | sed -n "s/^network\.\([^=.]*MGMNT[^.=]*\)=interface/\1/p" \
  | while read -r sect; do \
      vals="$(uci -q get network.$sect.ipaddr 2>/dev/null || true)"; \
      for t in $vals; do case "$t" in */*) cidr_to_network "$t" || true ;; esac; done; \
    done | sort -u || true
}
# Start from MGMNT interfaces discovered via UCI
EXCLUDE_NETS_LIST="$(build_mgmnt_nets)"

# Always exclude known MGMNT supernets and their typical /24 splits
# - 10.255.0.0/16 (any 10.255.X.0/24 will be filtered client-side too)
# - 10.10.0.0/16  (MGMT range used on alcune navi)
EXCLUDE_NETS_LIST=$(printf '%s\n%s\n%s\n' "$EXCLUDE_NETS_LIST" '10.255.0.0/16' '10.10.0.0/16')
# Optionally enumerate /24s for 10.255.0.0/16 to catch exact-match filters server-side
for i in $(seq 0 255); do EXCLUDE_NETS_LIST=$(printf '%s\n10.255.%d.0/24' "$EXCLUDE_NETS_LIST" "$i"); done
EXCLUDE_NETS_LIST="$(printf '%s\n' "$EXCLUDE_NETS_LIST" | sort -u)"
EXCLUDE_NETS_JSON="$(printf '%s\n' $EXCLUDE_NETS_LIST | awk 'BEGIN{printf "["} {if(NR>1)printf ","; gsub(/"/,"\\\""); printf "\"%s\"", $0} END{printf "]"}')"
[ -n "$EXCLUDE_NETS_JSON" ] || EXCLUDE_NETS_JSON='[]'

# Estrai il blocco Active ipv4 user rules filtrando con le subnet dinamiche via CGI (creata sotto)
ACTIVE_IPV4_USER_RULES="$(/www/cgi-bin/ipv4_rules.sh 2>/dev/null || true)"
# Escape HTML per sicurezza e prepara file temporaneo per inserimento robusto
TMP_RULES="/tmp/active_ipv4_rules.$$"
{
  if [ -n "${ACTIVE_IPV4_USER_RULES}" ]; then
    printf '%s\n' "$ACTIVE_IPV4_USER_RULES" \
      | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
  else
    echo '—'
  fi
} > "$TMP_RULES"

# Ensure static assets (logo) are available under data_usage web root
mkdir -p /www/data_usage/static

LOGO_SRC=""
if [ -f "$SCRIPT_DIR/static/Telespazio.png" ]; then
  LOGO_SRC="$SCRIPT_DIR/static/Telespazio.png"
elif [ -f "/opt/static/Telespazio.png" ]; then
  LOGO_SRC="/opt/static/Telespazio.png"
fi
if [ -n "$LOGO_SRC" ]; then
  cp -f "$LOGO_SRC" /www/data_usage/static/Telespazio.png
fi

# Copy favicon if available
FAVICON_SRC=""
if [ -f "$SCRIPT_DIR/static/favicon.png" ]; then
  FAVICON_SRC="$SCRIPT_DIR/static/favicon.png"
elif [ -f "/opt/static/favicon.png" ]; then
  FAVICON_SRC="/opt/static/favicon.png"
fi
if [ -n "$FAVICON_SRC" ]; then
  cp -f "$FAVICON_SRC" /www/data_usage/static/favicon.png
fi

mkdir -p /www/cgi-bin

# Install CGI scripts from util (prefer relative to script, fallback to /opt/util/grimaldi)
install_cgi(){
  local SRC_BASE="${SCRIPT_DIR}/util/cgi"
  [ -d "$SRC_BASE" ] || SRC_BASE="/opt/util/grimaldi/cgi"
  if [ -d "$SRC_BASE" ]; then
    # Ensure both global cgi-bin and app-local cgi-bin exist
    mkdir -p /www/cgi-bin
    mkdir -p /www/data_usage/cgi-bin
    for f in "$SRC_BASE"/*.sh; do
      [ -f "$f" ] || continue
      local bn; bn="$(basename "$f")"
      cp -f "$f" "/www/cgi-bin/$bn" && chmod +x "/www/cgi-bin/$bn"
      cp -f "$f" "/www/data_usage/cgi-bin/$bn" && chmod +x "/www/data_usage/cgi-bin/$bn"
    done
  fi
}
install_cgi

# Install config utilities (generator) under /opt/util/grimaldi/conf
install_conf_utils(){
  local SRC_CONF="${SCRIPT_DIR}/util/conf"
  [ -d "$SRC_CONF" ] || SRC_CONF="/opt/util/grimaldi/conf"
  if [ -d "$SRC_CONF" ]; then
    mkdir -p /opt/util/grimaldi/conf
    for f in "$SRC_CONF"/*.sh; do
      [ -f "$f" ] || continue
      local bn dst
      bn="$(basename "$f")"
      dst="/opt/util/grimaldi/conf/$bn"
      # Skip if source and destination paths are identical to avoid BusyBox cp error
      if [ "$f" = "$dst" ]; then
        continue
      fi
      cp -f "$f" "$dst" && chmod +x "$dst"
    done
  fi
}
install_conf_utils

# Ensure default config file exists and generate UI config JSON once at deploy
CFG_DIR="/opt/conf"
CFG_FILE="$CFG_DIR/data_usage.conf"
mkdir -p "$CFG_DIR"
if [ ! -f "$CFG_FILE" ]; then
  cat > "$CFG_FILE" <<'EOF'
# UI visibility configuration (created by installer)
# Set sections to true to hide them from the web UI.
hide:
  flows: true         # hide IPv4 Flows section by default
  rules: true         # hide Active ipv4 user rules by default
  fleetone: false
  connected_users: false
  interfaces: false
  usage: false
auto:
  fleetone_if_missing: true   # auto-hide Fleetone if no FleetOne/FBB iface
  connected_if_empty: true    # auto-hide Connected Users if list empty
EOF
fi

if [ -x "/opt/util/grimaldi/conf/generate_config.sh" ]; then
  /opt/util/grimaldi/conf/generate_config.sh || true
fi

# Prepare HTML from template file (prefer relative to script, fallback to /opt/util/grimaldi)
mkdir -p /www/data_usage
TEMPLATE_HTML="${SCRIPT_DIR}/util/www/index.template.html"
[ -f "$TEMPLATE_HTML" ] || TEMPLATE_HTML="/opt/util/grimaldi/www/index.template.html"

if [ -f "$TEMPLATE_HTML" ]; then
  mkdir -p /www/data_usage
  cp -f "$TEMPLATE_HTML" /www/data_usage/index.html
  # Note text comes from template; no additional injection needed here
else
  # Template not present locally: try alternate fallbacks, do not generate inline HTML
  if [ -f "/opt/util/grimaldi/www/index.template.html" ]; then
    mkdir -p /www/data_usage
    cp -f "/opt/util/grimaldi/www/index.template.html" /www/data_usage/index.html
  elif [ -f "/opt/util/common/www/index.template.html" ]; then
    mkdir -p /www/data_usage
    cp -f "/opt/util/common/www/index.template.html" /www/data_usage/index.html
  else
    echo "Warning: template not found; /www/data_usage/index.html left unchanged" >&2
    mkdir -p /www/data_usage
    [ -f /www/data_usage/index.html ] || touch /www/data_usage/index.html
  fi
fi

# VERSION handling: use WEBAPP_VERSION if set in the script, or allow an override from environment.
# The deploy process generates a machine-readable `/www/data_usage/version.json` file and injects a
# small HTML comment into the index for easy visual checks. We no longer probe or copy a
# repository `VERSION.txt`; `version.json` is the canonical runtime metadata file on the device.
WEBAPP_VERSION="1.5"
# Allow callers to override the version via environment variable WEBAPP_VERSION_OVERRIDE
VER="${WEBAPP_VERSION}"
if [ -n "${WEBAPP_VERSION_OVERRIDE:-}" ]; then
  VER="${WEBAPP_VERSION_OVERRIDE}"
fi

# Ensure webroot exists
mkdir -p /www/data_usage

# Preserve important runtime files: don't overwrite or remove existing data.json and call_log.json
preserve_runtime_files() {
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  for f in data.json call_log.json; do
    if [ -f "/www/data_usage/$f" ]; then
      cp -a "/www/data_usage/$f" "/www/data_usage/${f}.bak.$TS" || true
    fi
  done
}
preserve_runtime_files

# If critical runtime files are missing, attempt to restore from controller-provided repo copy (if available under SCRIPT_DIR/../data_usage)
restore_runtime_files_from_repo() {
  local REPO_DATA_DIR="${SCRIPT_DIR}/../data_usage"
  # also support repo top-level data_usage
  [ -d "$REPO_DATA_DIR" ] || REPO_DATA_DIR="${SCRIPT_DIR}/../../data_usage"
  for f in data.json call_log.json; do
    if [ ! -f "/www/data_usage/$f" ]; then
      if [ -f "$REPO_DATA_DIR/$f" ]; then
        cp -a "$REPO_DATA_DIR/$f" "/www/data_usage/$f" || true
      fi
    fi
  done
}
restore_runtime_files_from_repo

# Create a small JSON file with metadata so clients / monitoring tools can fetch the version programmatically
GEN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > /www/data_usage/version.json <<EOF || true
{
  "version": "${VER}",
  "generated": "${GEN_TS}",
  "source": "deploy"
}
EOF

# (Previously the script removed legacy /www/mwan3/VERSION.txt; that behavior is no longer
# necessary because `version.json` is the canonical artifact and we do not write VERSION.txt.)

# inject a one-line HTML comment at the top of generated index.html for easy client/server checks
if [ -f /www/data_usage/index.html ]; then
  # remove any previous webapp-version comment to avoid duplicates, then insert
  sed -i "/<!-- webapp-version:/d" /www/data_usage/index.html || true
  sed -i "1i <!-- webapp-version: ${VER} -->" /www/data_usage/index.html || true
fi

# sostituisce l’ACTIVE lato server
sed -i "s#__ACTIVE__IFACE__#$(printf '%s' "$IFACE" | sed 's/[&/]/\\&/g')#g" /www/data_usage/index.html
# sostituzione robusta multi-linea del placeholder con il contenuto del file
sed -i "/__ACTIVE_IPV4_USER_RULES__/ { r $TMP_RULES
  d
}" /www/data_usage/index.html || true
rm -f "$TMP_RULES"


# inject dynamic source nets JSON used by the client
SAFE_JSON="$(printf '%s' "$SRC_NETS_JSON" | sed 's/[&/]/\\&/g')"
sed -i "s#__SRC_NETS_JSON__#$SAFE_JSON#g" /www/data_usage/index.html
# inject EXCLUDE nets JSON
SAFE_EX_JSON="$(printf '%s' "$EXCLUDE_NETS_JSON" | sed 's/[&/]/\\&/g')"
sed -i "s#__EXCLUDE_NETS_JSON__#$SAFE_EX_JSON#g" /www/data_usage/index.html

# Hostname nave (da UCI o fallback al kernel)
SHIP_NAME="$(uci -q get system.@system[0].hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'HOST')"
# Remove leading TBOX- prefix if present
CLEAN_NAME="$(printf '%s' "$SHIP_NAME" | sed -E 's/^TBOX-//')"
# sostituisce l'HOSTNAME lato server
sed -i "s#__HOSTNAME__#$(printf '%s' "$CLEAN_NAME" | sed 's/[&/]/\\&/g')#g" /www/data_usage/index.html

# Ensure the topbar title shows only the cleaned ship name (some templates may include a trailing ' Status')
sed -i "s#<h1 class=\"brand-title\">.*</h1>#<h1 class=\"brand-title\">$(printf '%s' "$CLEAN_NAME" | sed 's/[&/]/\\&/g')</h1>#g" /www/data_usage/index.html || true

# The UI reads live consumption data from /www/data_usage/data.json maintained by an updater.
# Ensure the live directory exists.
mkdir -p /www/data_usage
