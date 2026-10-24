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
# 容器內 curl 指令。RPM 的 auto-config 在 docker build 時就產生憑證（SAN 是 buildkitsandbox / localhost / 127.0.0.1），
# 所以只有 auto-config 的 http_ca.crt 時改連 localhost；用自己簽的 ca.crt 時照節點名稱連
curl_cmd() {
  local n=$1 m=$2 path=$3
  echo "C=/etc/elasticsearch/certs; if [ -f \$C/ca.crt ]; then CA=\$C/ca.crt H=$n; else CA=\$C/http_ca.crt H=localhost; fi; curl -sS --cacert \$CA -u 'elastic:$ES_PW' -X $m \"https://\$H:9200$path\""
}
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
  local CURL="$(curl_cmd "$n" "$m" "$path")"
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
  docker compose exec -T "$n" bash -c "$(curl_cmd "$n" "$m" "$path")" 2>/dev/null
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
# 叢集節點的共用設定：OS 參數、systemd override、移除 RPM auto-config 的憑證、放自建 CA 簽的憑證、elasticsearch.yml、heap
#   setup_node <節點> <IP> <設定檔> [roles 覆寫]
setup_node() {
  local n=$1 ip=$2 conf=$3 roles=${4:-}
  local sedroles=""; [ -n "$roles" ] && sedroles="-e 's/^node.roles: .*/node.roles: $roles/'"
  x $n "cp /root/conf/99-elasticsearch.conf /etc/sysctl.d/ && sysctl -p /etc/sysctl.d/99-elasticsearch.conf >/dev/null \
 && mkdir -p /etc/systemd/system/elasticsearch.service.d && cp /root/conf/override.conf /etc/systemd/system/elasticsearch.service.d/ && systemctl daemon-reload \
 && cd /etc/elasticsearch && rm -f certs/http_ca.crt certs/http.p12 certs/transport.p12 \
 && for k in xpack.security.http.ssl.keystore.secure_password xpack.security.transport.ssl.keystore.secure_password xpack.security.transport.ssl.truststore.secure_password; do /usr/share/elasticsearch/bin/elasticsearch-keystore remove \$k 2>/dev/null; done; \
 install -o root -g elasticsearch -m 640 /mnt/es-snapshots/.dist/es-certs/$n/$n.crt certs/node.crt && install -o root -g elasticsearch -m 640 /mnt/es-snapshots/.dist/es-certs/$n/$n.key certs/node.key && install -o root -g elasticsearch -m 644 /mnt/es-snapshots/.dist/ca/ca.crt certs/ca.crt \
 && sed -e 's/^node.name: .*/node.name: $n/' -e 's/^network.host: .*/network.host: $ip/' $sedroles /root/conf/$conf > elasticsearch.yml && chown root:elasticsearch elasticsearch.yml && chmod 660 elasticsearch.yml \
 && install -o root -g elasticsearch -m 660 /root/conf/heap.options /root/conf/lab-heap.options jvm.options.d/ \
 && /usr/share/elasticsearch/bin/elasticsearch-keystore list | tr '\n' ' ' && echo && ls certs && grep -E '^(cluster.name|node.name|node.roles|network.host)' elasticsearch.yml"
}
# 目前的 master 節點名稱（問第一個有回應的節點）
master() { local n; for n in "$@"; do eq $n GET '/_cat/master?h=node' 2>/dev/null | tr -d '\r\n ' | grep -E '^es' && return; done; }
