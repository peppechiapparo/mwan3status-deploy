#!/bin/sh
# Simple CGI that exposes UI config as JSON, reading optional /opt/conf/data_usage.conf (YAML-like)
# Supported keys (either nested under 'hide:'/'auto:' or flat variants):
#   hide:
#     fleetone: true|false
#     connected_users: true|false
#     interfaces: true|false
#     usage: true|false
#     flows: true|false
#     rules: true|false
#   auto:
#     fleetone_if_missing: true|false
#     connected_if_empty: true|false

echo "Content-Type: application/json"
echo

CFG_FILE="/opt/conf/data_usage.conf"

# defaults
hide_fleetone=false
hide_connected=false
hide_interfaces=false
hide_usage=false
hide_flows=false
hide_rules=false
auto_fleetone_if_missing=true
auto_connected_if_empty=true

get_nested_bool() {
  # $1 = section (e.g. hide), $2 = key (e.g. fleetone)
  sec="$1"; key="$2"
  [ -f "$CFG_FILE" ] || return 1
  awk -v sec="$sec" -v key="$key" '
    BEGIN{in=0; v=""}
    $0 ~ "^"sec":[[:space:]]*$" { in=1; next }
    in && $0 ~ /^[^[:space:]]/ { in=0 }
    in {
      # Match lines like "  key: true" or with additional spaces
      if ($1 == key":" && ($2 == "true" || $2 == "false")) { v=$2 }
    }
    END{ if(v!="") print v }
  ' "$CFG_FILE"
}

get_flat_bool() {
  # try patterns like "hide.key: true" or "hide_key: true"
  sec="$1"; key="$2"
  [ -f "$CFG_FILE" ] || return 1
  # hide.key: true
  sed -n "s/^[[:space:]]*""$sec""\.""$key""[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$CFG_FILE" | head -n1
}

get_bool() {
  sec="$1"; key="$2"
  val="$(get_nested_bool "$sec" "$key" 2>/dev/null)"
  [ -z "$val" ] && val="$(get_flat_bool "$sec" "$key" 2>/dev/null)"
  # also try underscore variant: sec_key
  if [ -z "$val" ] && [ -f "$CFG_FILE" ]; then
    val="$(sed -n "s/^[[:space:]]*""$sec""_""$key""[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$CFG_FILE" | head -n1)"
  fi
  [ -n "$val" ] && printf '%s' "$val"
}

if [ -f "$CFG_FILE" ]; then
  v="$(get_bool hide fleetone)";          [ -n "$v" ] && hide_fleetone="$v"
  v="$(get_bool hide connected_users)";   [ -n "$v" ] && hide_connected="$v"
  v="$(get_bool hide interfaces)";        [ -n "$v" ] && hide_interfaces="$v"
  v="$(get_bool hide usage)";             [ -n "$v" ] && hide_usage="$v"
  v="$(get_bool hide flows)";             [ -n "$v" ] && hide_flows="$v"
  v="$(get_bool hide rules)";             [ -n "$v" ] && hide_rules="$v"
  v="$(get_bool auto fleetone_if_missing)"; [ -n "$v" ] && auto_fleetone_if_missing="$v"
  v="$(get_bool auto connected_if_empty)";  [ -n "$v" ] && auto_connected_if_empty="$v"
fi

# emit JSON
cat <<JSON
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
