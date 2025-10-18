#!/bin/sh
# Offline generator: read /opt/conf/data_usage.conf (YAML-like) and emit JSON to /www/data_usage/ui_config.json
# This script is run only during deploy; the UI reads the static JSON file.

set -eu

CFG_FILE="/opt/conf/data_usage.conf"
OUT_JSON="/www/data_usage/ui_config.json"

# defaults
hide_fleetone=false
hide_connected=false
hide_interfaces=false
hide_usage=false
hide_flows=true
hide_rules=true
auto_fleetone_if_missing=true
auto_connected_if_empty=true

get_nested_bool() {
  sec="$1"; key="$2"
  [ -f "$CFG_FILE" ] || return 1
  awk -v sec="$sec" -v key="$key" '
    BEGIN{INS=0; v=""}
    $0 ~ "^[[:space:]]*"sec"[:][[:space:]]*$" { INS=1; next }
    INS && $0 ~ /^[^[:space:]]/ { INS=0 }
    INS {
      # match lines like "  key: true" with arbitrary spaces
      if ($0 ~ "^[[:space:]]*"key"[[:space:]]*:[[:space:]]*(true|false)") {
        if (match($0, /:[[:space:]]*(true|false)/, m)) { v=m[1] }
      }
    }
    END{ if(v!="") print v }
  ' "$CFG_FILE"
}

get_flat_bool() {
  sec="$1"; key="$2"
  [ -f "$CFG_FILE" ] || return 1
  sed -n "s/^[[:space:]]*""$sec""\.""$key""[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$CFG_FILE" | head -n1
}

get_bool() {
  sec="$1"; key="$2"
  val="$(get_nested_bool "$sec" "$key" 2>/dev/null || true)"
  [ -z "$val" ] && val="$(get_flat_bool "$sec" "$key" 2>/dev/null || true)"
  if [ -z "$val" ] && [ -f "$CFG_FILE" ]; then
    val="$(sed -n "s/^[[:space:]]*""$sec""_""$key""[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$CFG_FILE" | head -n1)"
  fi
  [ -n "$val" ] && printf '%s' "$val"
  return 0
}

if [ -f "$CFG_FILE" ]; then
  v="$(get_bool hide fleetone)";            [ -n "$v" ] && hide_fleetone="$v"
  v="$(get_bool hide connected_users)";     [ -n "$v" ] && hide_connected="$v"
  v="$(get_bool hide interfaces)";          [ -n "$v" ] && hide_interfaces="$v"
  v="$(get_bool hide usage)";               [ -n "$v" ] && hide_usage="$v"
  v="$(get_bool hide flows)";               [ -n "$v" ] && hide_flows="$v"
  v="$(get_bool hide rules)";               [ -n "$v" ] && hide_rules="$v"
  v="$(get_bool auto fleetone_if_missing)"; [ -n "$v" ] && auto_fleetone_if_missing="$v"
  v="$(get_bool auto connected_if_empty)";  [ -n "$v" ] && auto_connected_if_empty="$v"
fi

mkdir -p "$(dirname "$OUT_JSON")"
cat > "$OUT_JSON" <<JSON
{
  "hide": {
    "fleetone": $hide_fleetone,
    "connected_users": $hide_connected,
    "interfaces": $hide_interfaces,
    "usage": $hide_usage,
    "flows": $hide_flows,
    "rules": $hide_rules
  },
  "auto": {
    "fleetone_if_missing": $auto_fleetone_if_missing,
    "connected_if_empty": $auto_connected_if_empty
  }
}
JSON

echo "Wrote $OUT_JSON"
