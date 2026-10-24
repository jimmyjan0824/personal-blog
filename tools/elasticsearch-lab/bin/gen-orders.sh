#!/usr/bin/env bash
# 產生 bulk 用的 NDJSON：gen-orders.sh <筆數> [起始編號] > orders.ndjson
# 每筆約 300 bytes：訂單編號、客戶、狀態、金額、地區、時間、備註
n=${1:-100000}; start=${2:-1}
awk -v n="$n" -v s="$start" 'BEGIN {
  srand(20261024 + s)
  split("paid,shipped,delivered,cancelled,refunded", st, ",")
  split("tw,jp,kr,sg,us", rg, ",")
  split("laptop,phone,tablet,monitor,keyboard,mouse,headset,camera", pr, ",")
  base = 1761264000   # 2025-10-24T00:00:00Z
  for (i = s; i < s + n; i++) {
    t = base + int(rand() * 31536000)
    printf "{\"create\":{}}\n"
    printf "{\"order_id\":\"ORD-%09d\",\"customer_id\":\"C%06d\",\"status\":\"%s\",\"amount\":%.2f,\"region\":\"%s\",\"product\":\"%s\",\"qty\":%d,\"created_at\":\"%s\",\"note\":\"%s %s order for customer %06d\"}\n",
      i, int(rand() * 50000), st[int(rand() * 5) + 1], rand() * 2000 + 10, rg[int(rand() * 5) + 1], pr[int(rand() * 8) + 1],
      int(rand() * 5) + 1, strftime("%Y-%m-%dT%H:%M:%SZ", t, 1), rg[int(rand() * 5) + 1], pr[int(rand() * 8) + 1], int(rand() * 50000)
  }
}'
