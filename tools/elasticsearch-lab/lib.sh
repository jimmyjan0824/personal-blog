#!/usr/bin/env bash
# 共用函式：先印出要執行的指令再在容器內執行，輸出就是文章裡的實測輸出
#   x <節點> <shell 指令>            以 root 執行，印成「[節點]# 指令」
#   e <節點> <METHOD> <路徑> [body]   呼叫 REST API（elastic 帳號、HTTPS），印成「[節點] GET /路徑」+ body，
#                                     body 以 @ 開頭代表檔案（容器內路徑），.yaml 檔用 application/yaml 送出
set -u
cd "$(dirname "$0")"
export PATH="$HOME/.docker/bin:$PATH"
mkdir -p results
ES_PW=${ES_PW:-ChangeMe_Elastic_2026}
x() {
  local n=$1; shift
  echo "[$n]# $*"
  docker compose exec -T "$n" bash -c "$*" 2>&1
  echo
}
e() {
  local n=$1 m=$2 path=$3 body=${4:-} ct=application/json
  echo "[$n] $m $path"
  case "$body" in @*) echo "（body：${body:1}）";; ?*) echo "$body";; esac
  case "$body" in *.yaml) ct=application/yaml;; *.ndjson) ct=application/x-ndjson;; esac
  local CURL="curl -sS --cacert \$(ls /etc/elasticsearch/certs/ca.crt /etc/elasticsearch/certs/http_ca.crt 2>/dev/null | head -1) -u 'elastic:$ES_PW' -X $m 'https://$n:9200$path'"
  case "$body" in
    @*) docker compose exec -T "$n" bash -c "$CURL -H 'Content-Type: $ct' --data-binary '$body'" 2>&1;;
    ?*) printf '%s' "$body" | docker compose exec -T "$n" bash -c "$CURL -H 'Content-Type: $ct' --data-binary @-" 2>&1;;
    *)  docker compose exec -T "$n" bash -c "$CURL" 2>&1;;
  esac
  echo; echo
}
# 不印指令、只取結果（給腳本判斷用）
eq() {
  local n=$1 m=$2 path=$3
  docker compose exec -T "$n" bash -c "curl -sS --cacert \$(ls /etc/elasticsearch/certs/ca.crt /etc/elasticsearch/certs/http_ca.crt 2>/dev/null | head -1) -u 'elastic:$ES_PW' -X $m 'https://$n:9200$path'" 2>/dev/null
}
note() { echo; echo "======== $* ========  ($(date '+%F %T'))"; }
# 主機端指令：印成「# 主機端：指令」再執行
h() { echo "# 主機端：$*"; eval "$@" 2>&1; echo; }
# 等到條件成立（最多 $2 秒），印出等了幾秒
wait_until() {
  local desc=$1 max=$2; shift 2; local t0=$(date +%s)
  for _ in $(seq 1 "$max"); do if eval "$@" >/dev/null 2>&1; then echo "（$desc：等了 $(( $(date +%s)-t0 )) 秒）"; return 0; fi; sleep 1; done
  echo "（$desc：$max 秒內沒有成立）"; return 1
}
