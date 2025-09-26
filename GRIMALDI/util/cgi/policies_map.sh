#!/bin/sh
set -eu
echo "Content-Type: application/json"
echo
mwan3 status 2>/dev/null | awk '
  /^Current ipv4 policies:/ { f=1; next }
  f && /^Current ipv6 policies:/ { f=0 }
  f && /:$/ { gsub(":$","",$0); pol=$0; next }
  f && /%/ {
    line=$0;
    while (match(line, /[A-Za-z0-9_]+[ \t]+\([0-9]+%\)/)) {
      token=substr(line, RSTART, RLENGTH);
      name=token; sub(/[ \t]+\([0-9]+%\)$/, "", name);
      w=token; sub(/^.*\(/, "", w); sub(/%\).*/, "", w);
      if (pol!="") {
        if (map[pol]!="") map[pol]=map[pol]" ";
        map[pol]=map[pol] name":"w;
      }
      line=substr(line, RSTART+RLENGTH);
    }
  }
  END{
    printf("{\"policies\":["); sep="";
    for (p in map) {
      printf("%s{\"name\":\"%s\",\"members\":[", sep, p); sep=",";
      n=split(map[p], arr, " "); msep="";
      for(i=1;i<=n;i++) if(arr[i]!=""){
        split(arr[i],kv,":");
        printf("%s{\"name\":\"%s\",\"weight\":%s}", msep, kv[1], kv[2]);
        msep=",";
      }
      printf("]}");
    }
    printf("]}");
  }'

