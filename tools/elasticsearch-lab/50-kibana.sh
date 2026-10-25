#!/usr/bin/env bash
# Kibana 9.5.5：kb1 現場以 RPM 安裝，連到三節點叢集 es-prod（esc1~esc3，建置步驟同 20-cluster.sh，不重複印出細節）
# TLS（瀏覽器 → Kibana、Kibana → Elasticsearch 都用自建 CA）、kibana_system 帳號、keystore、加密金鑰、heap、
# 狀態 / Task Manager / data view、重啟時間、Elasticsearch 節點故障、拼錯參數、最後把同一份設定放到 Kibana 8.19.23
source "$(dirname "$0")/lib.sh"
N="esc1 esc2 esc3"
LOG=/var/log/elasticsearch/es-prod.log
KB_PW=ChangeMe_Kibana_2026
ip() { case $1 in esc1) echo 192.168.60.21;; esc2) echo 192.168.60.22;; esc3) echo 192.168.60.23;; esac; }
# Kibana REST API：k <METHOD> <路徑> [body] [jq 篩選]，印成「[kb1] GET /路徑」（elastic 帳號、驗證 CA 憑證、kbn-xsrf 標頭）
k() {
  local m=$1 p=$2 b=${3:-} f=${4:-}
  echo "[kb1] $m $p"; [ -n "$b" ] && echo "$b"; [ -n "$f" ] && echo "（jq：$f）"
  local C="curl -sS --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -X $m 'https://kb1:5601$p'"
  local out
  if [ -n "$b" ]; then out=$(printf '%s' "$b" | docker compose exec -T kb1 bash -c "$C --data-binary @-" 2>&1)
  else out=$(docker compose exec -T kb1 bash -c "$C" 2>&1); fi
  if [ -n "$f" ]; then printf '%s' "$out" | jq "$f" 2>/dev/null || printf '%s\n' "$out"; else printf '%s\n' "$out"; fi
  echo
}
kq() { docker compose exec -T kb1 bash -c "curl -sS --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' https://kb1:5601$1" 2>/dev/null; }
kcount() { docker compose exec -T kb1 bash -c "curl -sS --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' -H 'kbn-xsrf: true' -X POST 'https://kb1:5601/api/console/proxy?path=%2Forders%2F_count&method=GET'" 2>/dev/null | jq -r .count 2>/dev/null; }
ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }   # macOS 的 date 沒有 %N
kb_level() { kq /api/status | jq -r .status.overall.level 2>/dev/null; }
{
note "建置 es-prod（esc1~esc3），步驟同 20-cluster.sh；instances.yml 多了 kb1，CA 一起簽發 Kibana 的憑證"
docker compose rm -sf $N kb1 >/dev/null 2>&1; docker compose up -d $N kb1; sleep 5
docker compose exec -T esc1 bash -c 'cd /usr/share/elasticsearch && bin/elasticsearch-certutil ca --pem --days 3650 --out /root/es-ca.zip -s && python3 -m zipfile -e /root/es-ca.zip /root/es-ca && bin/elasticsearch-certutil cert --pem --days 825 --ca-cert /root/es-ca/ca/ca.crt --ca-key /root/es-ca/ca/ca.key --in /root/conf/instances.yml --out /root/es-certs.zip -s && python3 -m zipfile -e /root/es-certs.zip /root/es-certs && rm -rf /mnt/es-snapshots/.dist && mkdir -p /mnt/es-snapshots/.dist/ca && cp -r /root/es-certs /mnt/es-snapshots/.dist/ && cp /root/es-ca/ca/ca.crt /mnt/es-snapshots/.dist/ca/' >/dev/null 2>&1
for n in $N; do setup_node $n $(ip $n) elasticsearch-cluster.yml >/dev/null; done
for n in $N; do docker compose exec -T $n bash -c 'systemctl enable -q elasticsearch && systemctl start --no-block elasticsearch'; done
wait_until "es-prod 組成" 180 "docker compose exec -T esc1 grep -q 'master node changed' $LOG"
for n in $N; do wait_until "$n active" 180 "docker compose exec -T $n systemctl is-active -q elasticsearch"; done
PW=$(docker compose exec -T esc1 /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
printf '{"password":"%s"}' "$ES_PW" | docker compose exec -T esc1 bash -c "curl -sS --cacert /etc/elasticsearch/certs/ca.crt -u 'elastic:$PW' -X POST https://esc1:9200/_security/user/elastic/_password -H 'Content-Type: application/json' --data-binary @-"; echo
for n in $N; do docker compose exec -T $n sed -i '/^cluster.initial_master_nodes/d' /etc/elasticsearch/elasticsearch.yml; done
e esc1 GET '/_cat/nodes?v&h=name,version,node.role,master'
e esc1 PUT /_component_template/base-settings @/root/conf/index-template.yaml
e esc1 PUT /_index_template/apps '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
e esc1 PUT /orders '{"settings":{"index.number_of_shards":3},"mappings":{"dynamic":"strict","properties":{"order_id":{"type":"keyword"},"customer_id":{"type":"keyword"},"status":{"type":"keyword"},"amount":{"type":"scaled_float","scaling_factor":100},"region":{"type":"keyword"},"product":{"type":"keyword"},"qty":{"type":"integer"},"created_at":{"type":"date"},"note":{"type":"text"}}}}'
x esc1 "/root/bin/gen-orders.sh 50000 1 > /tmp/o1.ndjson; ES_PW=$ES_PW /root/bin/bulk-load.sh esc1 orders /tmp/o1.ndjson 5000"

note "步驟 1：kb1 安裝 Kibana 9.5.5（同一個 Elastic 套件庫，套件名稱 kibana）"
x kb1 'cat /etc/os-release | grep PRETTY; free -m | head -2; nproc'
x kb1 'rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch && cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && dnf install -y -q --enablerepo=elasticsearch kibana-9.5.5 2>&1 | tail -5; rpm -q kibana'
x kb1 'rpm -qi kibana | grep -E "^(Version|Release|Architecture|Size)"; du -sh /usr/share/kibana; ls /usr/share/kibana; ls /usr/share/kibana/bin'
x kb1 'ls -la /etc/kibana /var/lib/kibana /var/log/kibana; id kibana'
x kb1 'systemctl cat kibana | grep -vE "^\s*$"'
x kb1 'cat /etc/default/kibana 2>/dev/null || cat /etc/sysconfig/kibana 2>/dev/null'
echo "# RPM 原本的 kibana.yml（只列沒有註解的行）"
x kb1 'grep -vE "^\s*(#|$)" /etc/kibana/kibana.yml'
echo "# RPM 原本的 node.options"
x kb1 'cat /etc/kibana/node.options'
x kb1 'ls /usr/share/kibana/node; f=$(ls /usr/share/kibana/node/*/bin/node /usr/share/kibana/node/bin/node 2>/dev/null | head -1); echo $f; $f --version; $f -e "console.log(Math.round(require(\"v8\").getHeapStatistics().heap_size_limit/1048576)+\" MB（Node.js 預設 heap 上限）\")"'

note "步驟 2：kibana_system 帳號的密碼（在 Elasticsearch 上設定）"
e esc1 POST /_security/user/kibana_system/_password "{\"password\":\"$KB_PW\"}"
e esc1 GET '/_security/user/kibana_system?filter_path=*.roles,*.metadata,*.enabled'

note "步驟 3：憑證、kibana.yml、keystore、加密金鑰、heap"
x kb1 'mkdir -p /etc/kibana/certs && install -o root -g kibana -m 640 /mnt/es-snapshots/.dist/es-certs/kb1/kb1.crt /etc/kibana/certs/kb1.crt && install -o root -g kibana -m 640 /mnt/es-snapshots/.dist/es-certs/kb1/kb1.key /etc/kibana/certs/kb1.key && install -o root -g kibana -m 644 /mnt/es-snapshots/.dist/ca/ca.crt /etc/kibana/certs/ca.crt && ls -l /etc/kibana/certs && openssl x509 -in /etc/kibana/certs/kb1.crt -noout -subject -ext subjectAltName'
x kb1 'cp /etc/kibana/kibana.yml /etc/kibana/kibana.yml.rpm && install -o root -g kibana -m 660 /root/conf/kibana.yml /etc/kibana/kibana.yml && ls -l /etc/kibana/kibana.yml'
x kb1 'cd /usr/share/kibana && ls -l /etc/kibana/kibana.keystore 2>/dev/null || bin/kibana-keystore create; bin/kibana-keystore list'
x kb1 "cd /usr/share/kibana && echo '$KB_PW' | bin/kibana-keystore add elasticsearch.password --stdin && bin/kibana-keystore list"
x kb1 'cd /usr/share/kibana && bin/kibana-encryption-keys generate -q 2>&1 | tee /root/kb-keys.txt'
x kb1 'cd /usr/share/kibana && grep -E "^xpack\.[a-zA-Z.]+encryptionKey: " /root/kb-keys.txt | while IFS=": " read -r key val; do echo "$val" | tr -d "\r" | bin/kibana-keystore add "$key" --stdin -x >/dev/null && echo "added $key"; done; bin/kibana-keystore list; ls -l /etc/kibana/kibana.keystore; rm -f /root/kb-keys.txt'
# 實測環境：Docker VM 記憶體有限，heap 上限改成 1 GB（文章的設定是 2048）
x kb1 'grep -vE "^\s*#" /root/conf/kibana-node.options | sed "s/=2048/=1024/" | { echo; echo "# 實測環境（Docker VM 記憶體有限），文章的設定是 2048"; cat; } >> /etc/kibana/node.options && cat /etc/kibana/node.options'

note "步驟 4：啟動 Kibana（第一次啟動會建立 .kibana* 系統索引）"
T0=$(date +%s); x kb1 'systemctl daemon-reload && systemctl enable -q kibana && systemctl start kibana && systemctl is-active kibana'
wait_until "Kibana available" 600 "[ \"\$(kb_level)\" = available ]"
echo "第一次啟動到 available：$(( $(date +%s)-T0 )) 秒"
x kb1 'systemctl status kibana --no-pager | head -12'
x kb1 'ss -ltnp | grep 5601'
x kb1 'grep -oE "\"message\":\"[^\"]{0,240}" /var/log/kibana/kibana.log | sed "s/\"message\":\"//" | grep -iE "http server running|starting|kibana is now|deprecat|warn|elasticsearch|migrat|ready|config" | head -40'
x kb1 'grep -E "\"log\":\{\"level\":\"(WARN|ERROR|FATAL)\"" /var/log/kibana/kibana.log | grep -oE "\"logger\":\"[^\"]+\"|\"message\":\"[^\"]{0,200}" | paste - - | sort | uniq -c | sort -rn | head -20'
x kb1 'ps -o pid,user,rss,args -C node | cut -c1-220'

note "測試 1：狀態"
k GET /api/status '' '{name, version: .version.number, overall: .status.overall, core: .status.core}'
k GET /api/status '' '.metrics | {last_updated, collection_interval_in_millis, process: {memory: .process.memory.heap, event_loop_delay: .process.event_loop_delay, uptime_ms: .process.uptime_in_millis}, os_load: .os.load, requests: .requests, response_times: .response_times, concurrent_connections}'
k GET /api/status '' '[.status.plugins | to_entries[] | select(.value.level != "available") | {plugin: .key, level: .value.level, summary: .value.summary}] | .[:15]'
echo "# 不帶帳號（status.allowAnonymous 預設 false）"
x kb1 "curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/kibana/certs/ca.crt https://kb1:5601/api/status"
echo "# HTTP/2 與 TLS 版本"
x kb1 "curl -sS -o /dev/null -w 'http_version=%{http_version}\n' --http2 --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' https://kb1:5601/api/status; for v in 1.1 1.2 1.3; do printf 'TLSv%s: ' \$v; openssl s_client -connect kb1:5601 -CAfile /etc/kibana/certs/ca.crt -tls\${v/./_} </dev/null 2>&1 | grep -qE '^ *Protocol *: TLSv' && echo ok || echo rejected; done"
x kb1 "curl -sS -o /dev/null -D - --compressed --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' https://kb1:5601/login | grep -iE '^(HTTP|content-encoding|content-security)' | cut -c1-120"

note "測試 2：Kibana 在 Elasticsearch 上建立的系統索引與連線"
e esc1 GET '/_cat/indices/.kibana*,.kibana_task_manager*,.kibana_security_session*?v&h=index,health,pri,rep,docs.count,store.size&expand_wildcards=all&s=index'
e esc1 GET '/_cat/aliases/.kibana*?v&h=alias,index&expand_wildcards=all&s=alias'
e esc1 GET '/_nodes/stats/http?filter_path=nodes.*.name,nodes.*.http.current_open,nodes.*.http.total_opened&pretty'

note "測試 3：Task Manager 健康狀態（顯示實際生效的 capacity / poll_interval）"
k GET /api/task_manager/_health '' '{status, last_update, configuration: .stats.configuration.value, runtime_status: .stats.runtime.status, capacity_estimation: .stats.capacity_estimation.value, workload_overdue: .stats.workload.value.overdue}'

note "測試 4：建立 data view 並用 Kibana 查詢"
k POST /api/data_views/data_view '{"data_view":{"title":"orders*","name":"orders","timeFieldName":"created_at"}}' '{id: .data_view.id, title: .data_view.title, timeFieldName: .data_view.timeFieldName, fields: (.data_view.fields | length)}'
k GET /api/data_views '' '.data_view | map({id, title, name})'
k POST '/api/console/proxy?path=%2Forders%2F_count&method=GET' '' '.'
k GET '/api/saved_objects/_find?type=index-pattern&fields=title' '' '{total, saved_objects: [.saved_objects[] | {id, type, title: .attributes.title, namespaces}]}'

note "測試 5：重新啟動所需時間（已有 .kibana 索引）"
T0=$(date +%s); x kb1 'systemctl restart kibana && echo restarted'
wait_until "Kibana available" 300 "[ \"\$(kb_level)\" = available ]"
echo "systemctl restart 到 available：$(( $(date +%s)-T0 )) 秒"
k GET /api/status '' '{overall: .status.overall.level, uptime_ms: .metrics.process.uptime_in_millis, heap: .metrics.process.memory.heap}'

note "測試 6：Elasticsearch 節點故障（停 esc1，elasticsearch.hosts 的第一個）"
x esc1 'systemctl stop elasticsearch && echo stopped'
for i in 1 2 3 4 5 6; do
  t0=$(ms); lv=$(kb_level); c=$(kcount)
  echo "第 $i 次：overall=$lv，透過 Kibana 查 orders/_count=${c:-（失敗）}，$(( $(ms)-t0 )) ms"; sleep 5
done
k GET /api/data_views '' '.data_view | map(.title)'
k GET /api/status '' '{overall: .status.overall, elasticsearch: .status.core.elasticsearch}'
x kb1 'grep -E "\"level\":\"(WARN|ERROR)\"" /var/log/kibana/kibana.log | grep -oE "\"message\":\"[^\"]{0,240}" | grep -iE "esc1|ECONNREFUSED|connection|NoLivingConnections|resurrect" | sort | uniq -c | head -10 || echo "(none)"'
x esc1 'systemctl start elasticsearch && echo started'
wait_until "green" 180 "[ \"\$(eq esc2 GET /_cluster/health | jq -r .status)\" = green ]"
echo "# 全部停掉：Elasticsearch 都不在時 Kibana 的狀態"
for n in $N; do docker compose exec -T $n systemctl stop elasticsearch; done
sleep 15
k GET /api/status '' '{overall: .status.overall, elasticsearch: .status.core.elasticsearch}'
x kb1 "curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/kibana/certs/ca.crt -u 'elastic:$ES_PW' https://kb1:5601/api/status; systemctl is-active kibana"
for n in $N; do docker compose exec -T $n systemctl start --no-block elasticsearch; done
T0=$(date +%s)
wait_until "Kibana available" 300 "[ \"\$(kb_level)\" = available ]"
echo "Elasticsearch 重新啟動後 Kibana 恢復 available：$(( $(date +%s)-T0 )) 秒（含叢集組成）"

note "測試 7：拼錯參數（elasticsearch.requestTimout），Kibana 拒絕啟動"
x kb1 'cp /etc/kibana/kibana.yml /root/kibana.yml.bak && echo "elasticsearch.requestTimout: 60000" >> /etc/kibana/kibana.yml && systemctl restart kibana; sleep 20; systemctl is-active kibana; journalctl -u kibana --no-pager -n 200 | grep -E "FATAL|Error:|definition for this key" | cut -c1-300 | head -5'
x kb1 'cp /root/kibana.yml.bak /etc/kibana/kibana.yml && systemctl reset-failed kibana; systemctl restart kibana && echo restarted'
wait_until "Kibana available" 300 "[ \"\$(kb_level)\" = available ]"

note "預設值核對：載入 9.5.5 安裝目錄裡的設定 schema，對空物件 validate 取預設值（bin/kibana-defaults.js）"
x kb1 'f=$(ls /usr/share/kibana/node/*/bin/node /usr/share/kibana/node/bin/node 2>/dev/null | head -1); cd /tmp && timeout 600 $f /root/bin/kibana-defaults.js /usr/share/kibana > /tmp/kb-defaults.txt 2>/dev/null; wc -l < /tmp/kb-defaults.txt; mkdir -p /mnt/es-snapshots/.dist && cp /tmp/kb-defaults.txt /mnt/es-snapshots/.dist/kibana-defaults-9.5.5.txt'
docker compose exec -T kb1 cat /mnt/es-snapshots/.dist/kibana-defaults-9.5.5.txt > results/kibana-defaults-9.5.5.txt 2>/dev/null
echo "# kibana.yml 裡每個參數在 schema 預設值裡的對應（找不到的印 NOT FOUND）"
grep -E '^[a-zA-Z][a-zA-Z0-9_.]+:' conf/kibana.yml | cut -d: -f1 | while read -r key; do
  hit=$(grep -E "^\??[^|]*\b${key//./\\.}\|" results/kibana-defaults-9.5.5.txt | head -1)
  [ -z "$hit" ] && { tail=${key#*.}; hit=$(grep -E "^\?[^|]*\.${tail//./\\.}\|" results/kibana-defaults-9.5.5.txt | head -1); [ -n "$hit" ] && hit="（以 $tail 比對）$hit"; }
  printf '%-58s %s\n' "$key" "${hit:-NOT FOUND}"
done

note "對照：同一份 kibana.yml 放到 Kibana 8.19.23（Elasticsearch 仍是 9.5.5）"
x kb1 'systemctl stop kibana && cp /root/conf/elasticsearch-8.repo /etc/yum.repos.d/elasticsearch.repo && dnf downgrade -y -q --enablerepo=elasticsearch kibana-8.19.23 2>&1 | tail -3; rpm -q kibana; ls /etc/kibana; diff -q /root/conf/kibana.yml /etc/kibana/kibana.yml && echo "kibana.yml 保留"'
x kb1 'systemctl start kibana; sleep 60; systemctl is-active kibana; journalctl -u kibana --no-pager -n 300 | grep -E "FATAL|Error:|definition for this key|incompatible|newer" | cut -c1-400 | head -8; grep -E "\"level\":\"(ERROR|FATAL)\"" /var/log/kibana/kibana.log | tail -3 | grep -oE "\"message\":\"[^\"]{0,400}"'
x esc1 'rm -rf /mnt/es-snapshots/.dist'
} 2>&1 | tee results/50-kibana.log
