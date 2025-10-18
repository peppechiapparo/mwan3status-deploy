#!/usr/bin/env bash
set -euo pipefail

# Safe fleet deploy runner for GRIMALDI hosts.
# - Reads grimaldi_list_hostname.csv with lines: NAME,IP
# - For each host: backup /opt/updateMwan3StatusPage.sh -> .bak.TIMESTAMP
#   scp updateMwan3StatusPage.sh -> /opt/updateMwan3StatusPage.sh.new
#   ssh host: mv /opt/updateMwan3StatusPage.sh.new /opt/updateMwan3StatusPage.sh && chmod +x
#   ssh host: run /opt/updateMwan3StatusPage.sh
#   then run verification checks and append results to deploy_report.csv

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS_CSV="$WORKDIR/grimaldi_list_hostname.csv"
SRC_SCRIPT="$WORKDIR/updateMwan3StatusPage.sh"
REPORT="$WORKDIR/deploy_report.csv"

# SSH configuration: default to root user, allow overriding via env vars
# Example: SSH_USER=admin SSH_KEYFILE=/home/me/.ssh/id_rsa ./run_fleet_deploy.sh
SSH_USER="${SSH_USER:-root}"
SSH_KEYFILE="${SSH_KEYFILE:-}"
# Non-interactive options (fail fast if key not present)
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
if [ -n "$SSH_KEYFILE" ]; then
  SSH_OPTS="$SSH_OPTS -i $SSH_KEYFILE"
fi

if [ ! -f "$HOSTS_CSV" ]; then
  echo "Hosts CSV not found: $HOSTS_CSV" >&2
  exit 2
fi
if [ ! -f "$SRC_SCRIPT" ]; then
  echo "Source script not found: $SRC_SCRIPT" >&2
  exit 2
fi

# Header for report
printf 'HOST,IP,STATUS,VERSION_JSON,INDEX_COMMENT,CGI_OK,HTTP_STATUS,NOTE\n' > "$REPORT"

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)

while IFS=, read -r name ip; do
  [ -n "${ip:-}" ] || continue
  echo "--- Deploying to $name ($ip) ---"
  host="$ip"
  status="OK"
  note=""
  version_json=""
  index_comment=""
  cgi_ok="no"
  http_status=""

  # Build remote user@host (configurable)
  REMOTE="${SSH_USER}@${host}"

  # Backup existing remote script safely
  ssh $SSH_OPTS "$REMOTE" "if [ -f /opt/updateMwan3StatusPage.sh ]; then cp -a /opt/updateMwan3StatusPage.sh /opt/updateMwan3StatusPage.sh.bak.$TIMESTAMP || true; fi" || { status="SSH_FAIL"; note="backup-failed"; }

  # Copy new script (as root)
  scp $SSH_OPTS "$SRC_SCRIPT" "$REMOTE":/opt/updateMwan3StatusPage.sh.new || { status="SCP_FAIL"; note="scp-failed"; }

  # Move into place atomically and make executable
  if [ "$status" = "OK" ]; then
  ssh $SSH_OPTS "$REMOTE" "mv /opt/updateMwan3StatusPage.sh.new /opt/updateMwan3StatusPage.sh && chmod +x /opt/updateMwan3StatusPage.sh" || { status="SSH_FAIL"; note="mv-chmod-failed"; }
  fi

  # Execute script on remote host (non-interactive)
  if [ "$status" = "OK" ]; then
  ssh $SSH_OPTS "$REMOTE" "/opt/updateMwan3StatusPage.sh" || { status="RUN_FAIL"; note="remote-run-failed"; }
  fi

  # Verification checks
  if [ "$status" = "OK" ]; then
    # fetch version.json
  version_json=$(ssh $SSH_OPTS "$REMOTE" "cat /www/data_usage/version.json 2>/dev/null || true" | tr -d '\n' | sed 's/,/;/g')
    # check index.html comment
  index_comment=$(ssh $SSH_OPTS "$REMOTE" "grep -m1 '<!-- webapp-version:' /www/data_usage/index.html 2>/dev/null || true" | tr -d '\n')
    # check CGI endpoint
  # Use curl's --max-time on the remote side to avoid calling 'timeout' which may not exist
  cgi_out=$(ssh $SSH_OPTS "$REMOTE" "curl --max-time 5 -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5500/cgi-bin/mwan3_json.sh || true" || true)
    cgi_ok="no"
    if [ "$cgi_out" = "200" ]; then cgi_ok="yes"; fi
    # public HTTP probe
    http_status=$(curl -s -o /dev/null -w '%{http_code}' "http://$host:5500/" || true)
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${name//,/ }" "$ip" "$status" "${version_json//,/; }" "${index_comment//,/ }" "$cgi_ok" "$http_status" "$note" >> "$REPORT"

  echo "--- $name ($ip) => $status (HTTP:$http_status CGI:$cgi_ok) ---"
  sleep 0.5

done < "$HOSTS_CSV"

echo "Deploy complete. Report: $REPORT"
