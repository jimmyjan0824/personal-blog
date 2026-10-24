#!/usr/bin/env bash
# 單節點：在 es1（只有 systemd 的 Rocky 9）現場照文章步驟 0~5 操作並驗證，最後把同一份設定檔放到 8.19.23 上比較
source "$(dirname "$0")/lib.sh"
LOG=/var/log/elasticsearch/es-single.log
docker compose rm -sf es1 >/dev/null 2>&1; docker compose up -d es1; sleep 5
# 在 es1 暫時加一行設定，啟動應該失敗：印出錯誤訊息後還原
tryconf() {
  x es1 "cp -p /etc/elasticsearch/elasticsearch.yml /tmp/es.yml.ok && echo '$1' >> /etc/elasticsearch/elasticsearch.yml && tail -1 /etc/elasticsearch/elasticsearch.yml"
  x es1 "systemctl start elasticsearch; systemctl is-active elasticsearch; journalctl -u elasticsearch --no-pager -n 40 | grep -E 'ERROR|Exception|bootstrap check|setting \[' | cut -c1-500 | tail -6"
  x es1 'cp -p /tmp/es.yml.ok /etc/elasticsearch/elasticsearch.yml; systemctl reset-failed elasticsearch'
}
{
note "環境"
x es1 'cat /etc/rocky-release; uname -m; nproc; free -m | head -2; df -h / | sed 1d'

note "步驟 0：OS 參數"
x es1 'cp /root/conf/99-elasticsearch.conf /etc/sysctl.d/99-elasticsearch.conf && sysctl -p /etc/sysctl.d/99-elasticsearch.conf'
x es1 'swapon --show; free -m | grep -i swap; cat /sys/kernel/mm/transparent_hugepage/enabled'

note "步驟 1：安裝（Elastic 官方 RPM 套件庫）"
x es1 'rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch && rpm -q gpg-pubkey --qf "%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n" | grep -i elastic'
x es1 'cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && dnf repolist --all | grep -i elastic'
x es1 'dnf --enablerepo=elasticsearch list --showduplicates elasticsearch 2>/dev/null | tail -4'
x es1 'time dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 2>&1 | grep -vE "B/s \||^\s*$"'
x es1 'rpm -qi elasticsearch | grep -E "^(Name|Version|Release|Architecture|Size|Signature)"'
x es1 'rpm -qc elasticsearch; rpm -ql elasticsearch | grep -E "^/usr/lib/(systemd|sysctl.d|tmpfiles.d)/"'
x es1 'id elasticsearch; ls -la /etc/elasticsearch /etc/elasticsearch/certs; ls -ld /var/lib/elasticsearch /var/log/elasticsearch /usr/share/elasticsearch'
x es1 'grep -Ev "^\s*(#|$)" /etc/elasticsearch/elasticsearch.yml'
x es1 '/usr/share/elasticsearch/bin/elasticsearch-keystore list'
x es1 'openssl x509 -in /etc/elasticsearch/certs/http_ca.crt -noout -subject -enddate; openssl pkcs12 -in /etc/elasticsearch/certs/http.p12 -nokeys -passin pass:$(/usr/share/elasticsearch/bin/elasticsearch-keystore show xpack.security.http.ssl.keystore.secure_password) 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -enddate'
x es1 '/usr/share/elasticsearch/jdk/bin/java -version 2>&1; /usr/share/elasticsearch/bin/elasticsearch --version 2>/dev/null'

note "步驟 2：設定檔"
x es1 'cp -p /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml.rpm && install -o root -g elasticsearch -m 660 /root/conf/elasticsearch-single.yml /etc/elasticsearch/elasticsearch.yml && grep -Ev "^\s*(#|$)" /etc/elasticsearch/elasticsearch.yml | wc -l'
x es1 'install -o root -g elasticsearch -m 660 /root/conf/heap.options /etc/elasticsearch/jvm.options.d/heap.options && install -o root -g elasticsearch -m 660 /root/conf/lab-heap.options /etc/elasticsearch/jvm.options.d/lab-heap.options && ls -l /etc/elasticsearch/jvm.options.d/'
x es1 'install -d -o elasticsearch -g elasticsearch -m 750 /mnt/es-snapshots/single && ls -ld /mnt/es-snapshots/single'

note "實測踩坑 1：bootstrap.memory_lock: true，但 systemd 沒有 LimitMEMLOCK"
x es1 'systemctl start elasticsearch; systemctl is-active elasticsearch'
x es1 "journalctl -u elasticsearch --no-pager -n 40 | grep -E 'ERROR|bootstrap check|memory' | cut -c1-500 | tail -6; grep -E 'bootstrap check|memory lock' $LOG | cut -c1-500 | tail -4"
x es1 'systemctl reset-failed elasticsearch'

note "步驟 3：systemd override"
x es1 'mkdir -p /etc/systemd/system/elasticsearch.service.d && cp /root/conf/override.conf /etc/systemd/system/elasticsearch.service.d/override.conf && systemctl daemon-reload && systemctl cat elasticsearch | grep -Ev "^\s*(#|$)"'

note "實測踩坑 2：discovery.type: single-node 又設了 cluster.initial_master_nodes"
tryconf 'cluster.initial_master_nodes: ["es1"]'
note "實測踩坑 3：9.x 已移除的設定"
tryconf 'cluster.routing.allocation.disk.watermark.enable_for_single_data_node: true'
note "實測踩坑 4：設定名稱打錯"
tryconf 'indices.memory.index_buffer_sizes: 10%'

note "步驟 4：啟動"
x es1 'time systemctl enable --now elasticsearch; systemctl status elasticsearch --no-pager | head -12'
x es1 "grep -E 'heap size|JVM arguments|bound_addresses|publish_address|started|license|WARN|ERROR' $LOG | cut -c1-400"
x es1 'cat /proc/$(pgrep -f org.elasticsearch.bootstrap.Elasticsearch | head -1)/limits | grep -E "open files|processes|locked memory|address space"'
x es1 'ls -l /var/log/elasticsearch/'

note "elastic 密碼：重設為隨機值，再用 API 改成實驗用密碼"
PW=$(docker compose exec -T es1 /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
echo "[es1]# /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s"
echo "（輸出的隨機密碼省略，長度 ${#PW}）"; echo
ES_PW=$PW e es1 POST /_security/user/elastic/_password '{"password":"ChangeMe_Elastic_2026"}'

note "步驟 5：驗證"
e es1 GET /
e es1 GET '/_cat/nodes?v&h=name,ip,version,node.role,master,heap.max,ram.max,cpu,disk.total'
e es1 GET '/_cluster/health?pretty'
e es1 GET '/_nodes/_local/process?filter_path=nodes.*.process.mlockall,nodes.*.process.max_file_descriptors&pretty'
e es1 GET '/_nodes/_local/jvm?filter_path=nodes.*.jvm.version,nodes.*.jvm.vm_name,nodes.*.jvm.mem,nodes.*.jvm.gc_collectors,nodes.*.jvm.using_compressed_ordinary_object_pointers,nodes.*.jvm.input_arguments&pretty'
e es1 GET '/_nodes/_local/os?filter_path=nodes.*.os.available_processors,nodes.*.os.allocated_processors&pretty'
e es1 GET '/_cat/thread_pool?v&h=name,type,size,queue_size&s=name'
e es1 GET '/_nodes/_local/settings?flat_settings&filter_path=nodes.*.settings&pretty'

note "設定檔 vs 預設值比對（預設值來自 05-defaults.sh 匯出的 9.5.5 全新節點）"
eq es1 GET '/_nodes/_local/settings?flat_settings' > results/actual-node-es1.json
x es1 'python3 /root/bin/checkconf.py /etc/elasticsearch/elasticsearch.yml /root/results/defaults-node-9.5.5.txt /root/results/actual-node-es1.json'
e es1 GET '/_cluster/settings?include_defaults=true&flat_settings=true&filter_path=defaults.thread_pool.write.*,defaults.thread_pool.search.*,defaults.node.processors&pretty'

note "索引範本（component template 用 YAML 送出，註解會被忽略）"
e es1 PUT /_component_template/base-settings @/root/conf/index-template-single.yaml
e es1 PUT /_index_template/apps '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
e es1 POST '/_index_template/_simulate_index/orders?filter_path=template.settings&pretty'
e es1 PUT /orders '{"mappings":{"dynamic":"strict","properties":{"order_id":{"type":"keyword"},"customer_id":{"type":"keyword"},"status":{"type":"keyword"},"amount":{"type":"scaled_float","scaling_factor":100},"region":{"type":"keyword"},"product":{"type":"keyword"},"qty":{"type":"integer"},"created_at":{"type":"date"},"note":{"type":"text"}}}}'
eq es1 GET '/orders/_settings?flat_settings&include_defaults' > results/actual-index-es1.json
x es1 'python3 /root/bin/checkconf.py /root/conf/index-template-single.yaml /root/results/defaults-index-9.5.5.txt /root/results/actual-index-es1.json'
e es1 GET '/_cluster/health?filter_path=status,active_shards,unassigned_shards'

note "帳號：應用程式用的角色與使用者"
e es1 PUT /_security/role/orders_rw '{"cluster":["monitor"],"indices":[{"names":["orders*"],"privileges":["read","create_doc","index","view_index_metadata"]}]}'
e es1 PUT /_security/user/app '{"password":"ChangeMe_App_2026","roles":["orders_rw"],"full_name":"Order application"}'
x es1 'curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:ChangeMe_App_2026 -X POST "https://es1:9200/orders/_doc?refresh=wait_for" -H "Content-Type: application/json" -d "{\"order_id\":\"ORD-TEST-1\",\"status\":\"paid\",\"amount\":100,\"created_at\":\"2026-10-24T08:00:00Z\"}"; echo'
x es1 'curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:ChangeMe_App_2026 -X DELETE "https://es1:9200/orders" | jq -c ".error | {type, reason}"'
x es1 'curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:wrong "https://es1:9200/" | jq -c ".error | {type, reason}, .status"'
x es1 'curl -sS -o /dev/null -w "http://es1:9200/ → %{http_code}\n" http://es1:9200/; curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -o /dev/null -w "https://es1:9200/（不帶帳號）→ %{http_code}\n" https://es1:9200/'

note "bulk 寫入（容器內，只確認服務正常，不代表正式主機效能）"
x es1 '/root/bin/gen-orders.sh 300000 > /tmp/orders.ndjson; ls -lh /tmp/orders.ndjson; wc -l < /tmp/orders.ndjson'
x es1 'ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh es1 orders /tmp/orders.ndjson 5000'
e es1 POST /orders/_refresh
e es1 GET '/_cat/indices/orders?v&h=health,index,pri,rep,docs.count,store.size,pri.store.size'
e es1 GET '/_cat/segments/orders?v&h=shard,segment,docs.count,size,committed,searchable'
e es1 GET '/_stats/indexing,refresh,merge,flush?filter_path=_all.primaries.indexing.index_total,_all.primaries.indexing.index_time_in_millis,_all.primaries.refresh.total,_all.primaries.merges.total,_all.primaries.flush.total&pretty'

note "查詢：filter + 聚合"
e es1 POST '/orders/_search?filter_path=took,hits.total,aggregations&pretty' '{"size":0,"query":{"bool":{"filter":[{"term":{"status":"paid"}},{"range":{"created_at":{"gte":"2026-07-01","lt":"2026-10-01"}}}]}},"aggs":{"by_region":{"terms":{"field":"region"},"aggs":{"revenue":{"sum":{"field":"amount"}}}}}}'
e es1 POST '/orders/_search?filter_path=took,hits.total,hits.hits._source.order_id&pretty' '{"size":3,"query":{"match":{"note":"laptop"}},"sort":[{"created_at":"desc"}]}'
e es1 GET '/_nodes/stats/indices/query_cache,request_cache?filter_path=nodes.*.indices.query_cache.memory_size_in_bytes,nodes.*.indices.query_cache.hit_count,nodes.*.indices.request_cache&pretty'

note "慢查詢日誌：暫時把門檻設為 0ms"
e es1 PUT /orders/_settings '{"index.search.slowlog.threshold.query.info":"0ms"}'
e es1 POST '/orders/_search?filter_path=took' '{"size":0,"query":{"wildcard":{"customer_id":{"value":"*99"}}}}'
x es1 'sleep 1; tail -1 /var/log/elasticsearch/es-single_index_search_slowlog.json | jq -c "{\"@timestamp\", \"log.level\", \"elasticsearch.slowlog.took\", \"elasticsearch.slowlog.source\", \"user.name\"}"'
e es1 PUT /orders/_settings '{"index.search.slowlog.threshold.query.info":null}'

note "快照儲存庫（單節點用本機路徑）"
e es1 PUT /_snapshot/local_repo '{"type":"fs","settings":{"location":"/mnt/es-snapshots/single"}}'
e es1 POST '/_snapshot/local_repo/_verify?pretty'
e es1 PUT '/_snapshot/local_repo/snap-1?wait_for_completion=true&filter_path=snapshot.state,snapshot.indices,snapshot.shards,snapshot.duration_in_millis' '{"indices":"orders","include_global_state":false}'

note "重啟後資料仍在"
x es1 'time systemctl restart elasticsearch'
e es1 GET '/_cat/indices/orders?v&h=health,index,docs.count,store.size'

note "錯誤日誌中的 WARN / ERROR"
x es1 "grep -E '\]\[(WARN|ERROR)' $LOG | cut -c1-400 || echo '(none)'"
x es1 'jq -r ".message" /var/log/elasticsearch/es-single_deprecation.json 2>/dev/null | sort | uniq -c | sort -rn | head -10 || echo "(none)"'
} 2>&1 | tee results/10-single-node.log

note "比較：同一份 elasticsearch.yml 放到 8.19.23（esd8）" 2>&1 | tee results/15-single-node-8.19.log
docker compose rm -sf esd8 >/dev/null 2>&1; docker compose up -d esd8; sleep 5
{
x esd8 'rpm -q elasticsearch; cp /root/conf/99-elasticsearch.conf /etc/sysctl.d/ && sysctl -p /etc/sysctl.d/99-elasticsearch.conf >/dev/null; mkdir -p /etc/systemd/system/elasticsearch.service.d && cp /root/conf/override.conf /etc/systemd/system/elasticsearch.service.d/ && systemctl daemon-reload'
x esd8 'sed -e "s/^node.name: es1/node.name: esd8/" -e "s/192.168.60.11/192.168.60.42/" /root/conf/elasticsearch-single.yml > /etc/elasticsearch/elasticsearch.yml && install -o root -g elasticsearch -m 660 /root/conf/lab-heap.options /etc/elasticsearch/jvm.options.d/ && install -d -o elasticsearch -g elasticsearch /mnt/es-snapshots/single8'
x esd8 'systemctl start elasticsearch; systemctl is-active elasticsearch; journalctl -u elasticsearch --no-pager -n 40 | grep -E "ERROR|Exception|setting \[" | cut -c1-500 | tail -6'
note "移除 8.19 不認得的設定後再啟動"
x esd8 'systemctl reset-failed elasticsearch; sed -i "/^cluster.state.encryption.required/d" /etc/elasticsearch/elasticsearch.yml && time systemctl start elasticsearch; systemctl is-active elasticsearch; journalctl -u elasticsearch --no-pager -n 40 | grep -E "ERROR|Exception|setting \[" | cut -c1-500 | tail -6'
PW=$(docker compose exec -T esd8 /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s --url https://localhost:9200 2>/dev/null | tail -1 | tr -d '\r')
[ -n "$PW" ] && ES_PW=$PW eq esd8 GET / >/dev/null && ES_PW=$PW e esd8 POST /_security/user/elastic/_password '{"password":"ChangeMe_Elastic_2026"}'
e esd8 GET '/?filter_path=version.number,version.lucene_version'
eq esd8 GET '/_nodes/_local/settings?flat_settings' > results/actual-node-esd8.json
x esd8 'python3 /root/bin/checkconf.py /etc/elasticsearch/elasticsearch.yml /root/results/defaults-node-8.19.23.txt /root/results/actual-node-esd8.json'
x esd8 "grep -E '\]\[(WARN|ERROR)' /var/log/elasticsearch/es-single.log | cut -c1-400 || echo '(none)'"
} 2>&1 | tee -a results/15-single-node-8.19.log
docker compose stop esd8 >/dev/null 2>&1; docker compose rm -sf esd8 >/dev/null 2>&1
