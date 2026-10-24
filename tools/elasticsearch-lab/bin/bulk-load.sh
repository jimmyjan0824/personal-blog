#!/usr/bin/env bash
# 分批送 _bulk：bulk-load.sh <主機> <索引> <NDJSON 檔> [每批筆數]，印出筆數、秒數、每秒筆數、失敗筆數
# 帳號密碼用環境變數 ES_USER / ES_PW（預設 elastic）
h=$1 idx=$2 f=$3 per=${4:-5000}
ca=$(ls /etc/elasticsearch/certs/ca.crt /etc/elasticsearch/certs/http_ca.crt 2>/dev/null | head -1)
tmp=$(mktemp -d); split -l $((per * 2)) "$f" "$tmp/part."
t0=$(date +%s.%N); docs=0; fail=0; batches=0
for p in "$tmp"/part.*; do
  r=$(curl -sS --cacert "$ca" -u "${ES_USER:-elastic}:${ES_PW}" -H 'Content-Type: application/x-ndjson' -X POST "https://$h:9200/$idx/_bulk?filter_path=errors,items.*.status" --data-binary "@$p")
  docs=$((docs + $(wc -l < "$p") / 2)); batches=$((batches + 1))
  fail=$((fail + $(echo "$r" | grep -o '"status":[0-9]*' | grep -vc '"status":20[01]')))
done
t1=$(date +%s.%N); rm -rf "$tmp"
awk -v d=$docs -v b=$batches -v f=$fail -v a=$t0 -v z=$t1 'BEGIN { printf "docs=%d batches=%d failed=%d seconds=%.1f docs/s=%.0f\n", d, b, f, z-a, d/(z-a) }'
