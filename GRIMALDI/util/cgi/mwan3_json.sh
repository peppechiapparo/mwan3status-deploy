#!/bin/sh
# Hardened CGI: strict shell options and safe environment
set -eu
IFS=$' \t\n'
# Restrict PATH to trusted system locations only
PATH='/usr/sbin:/usr/bin:/sbin:/bin'

echo "Content-Type: application/json"; echo "Cache-Control: no-store"; echo

# locate runtime binaries (fallbacks in case command -v is not available)
AWK_BIN="$(command -v awk 2>/dev/null || echo /usr/bin/awk)"
MWAN3_BIN="$(command -v mwan3 2>/dev/null || echo /usr/bin/mwan3)"

# --- "Interface status:" -> JSON (parsing per colonne) ---
int_json() {
  "${MWAN3_BIN}" status | "${AWK_BIN}" -v dq='"' '
    BEGIN{ insec=0; first=1 }
    /^Interface status:/ { insec=1; next }
    insec && /^$/        { insec=0 }
    insec && $1=="interface" {
      name=$2
      status=$4
      online_for=""; uptime=""; tracking=""

      if (match($0, /, uptime /)) {
        of=$5; gsub(/,/, "", of)
        up=$7; gsub(/,/, "", up)
        online_for=of; uptime=up
      }
      if ($(NF)=="enabled") {
        tracking = ($(NF-1)=="not") ? "not enabled" : "enabled"
      } else {
        tracking = $(NF)
      }

      if(!first) printf(","); first=0
      printf("{%sname%s:%s%s%s,%sstatus%s:%s%s%s", dq,dq,dq,name,dq, dq,dq,dq,status,dq)
      if (online_for!="") printf(",%sonline_for%s:%s%s%s", dq,dq,dq,online_for,dq)
      if (uptime!="")     printf(",%suptime%s:%s%s%s",     dq,dq,dq,uptime,dq)
      if (tracking!="")   printf(",%stracking%s:%s%s%s",   dq,dq,dq,tracking,dq)
      printf("}")
    }'
}

# --- "Current ipv4 policies:" -> JSON {POL:[{name,weight},...] } ---
pol_json() {
  mwan3 status | awk -v dq='"' '
    BEGIN{ in4=0; inblk=0; sep1="" }
    /^Current ipv4 policies:/ { in4=1; next }
    in4 && /^Current ipv6 policies:/ { in4=0 }
    in4 && /^[A-Z0-9_]+:$/ {
      if(inblk){ printf("]"); sep1="," }
      gsub(/:$/,""); pol=$0
      printf("%s%s%s:[", sep1,dq pol dq)
      inblk=1; first=1; next
    }
    in4 && inblk && /^[ ]+[A-Z0-9_]+/ {
      gsub(/^[ ]+/,"")
      split($0,a," ")
      name=a[1]; w=a[2]; gsub(/[()%%]/,"",w)
      if(!first) printf(","); first=0
      printf("{%sname%s:%s%s%s,%sweight%s:%s}", dq,dq,dq,name,dq, dq,dq,w)
    }
    END{ if(inblk) printf("]") }
  '
}

printf '{ "interfaces":[%s], "policies_v4":{%s} }\n' "$(int_json)" "$(pol_json)"
