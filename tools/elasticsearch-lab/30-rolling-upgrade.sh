#!/usr/bin/env bash
# 滾動升級：esu1~esu3 先用 8.19.23 建三節點叢集（設定同 20-cluster.sh），再一台一台升到 9.5.5，背景持續寫入，最後測試降版
source "$(dirname "$0")/lib.sh"
N="esu1 esu2 esu3"
LOG=/var/log/elasticsearch/es-upgrade.log
ip() { case $1 in esu1) echo 192.168.60.31;; esu2) echo 192.168.60.32;; esu3) echo 192.168.60.33;; esac; }
nodes_seen() { eq $1 GET '/_cat/nodes?h=name' 2>/dev/null | tr -d '\r' | sort | tr '\n' ' '; }
health() { eq $1 GET '/_cluster/health' 2>/dev/null | jq -r .status 2>/dev/null; }
# 8.19 用的設定檔：叢集名稱、節點、seed hosts 換成 esu*（其餘與 20-cluster.sh 相同）
# 8.19 不認得 cluster.state.encryption.required（9.x 新增）；search 佇列寫成 8.19 的預設值 1000，觀察升級後明確寫死的舊預設值會不會被保留
sed -e 's/^cluster.name: .*/cluster.name: es-upgrade/' -e 's/esc\([1-3]\)/esu\1/g' -e 's/192\.168\.60\.2\([1-3]\)/192.168.60.3\1/g' \
  -e '/^cluster.state.encryption.required/d' -e 's/^thread_pool.search.queue_size: .*/thread_pool.search.queue_size: 1000/' \
  conf/elasticsearch-cluster.yml > conf/elasticsearch-upgrade.yml
# 背景寫入：每 0.5 秒寫一筆，寫到 results/.writer-target 指定的節點（升級中的節點不當目標）
writer() {
  local i=0 t r
  while [ -f results/.writer-on ]; do
    i=$((i+1)); t=$(cat results/.writer-target)
    r=$(docker compose exec -T $t curl -sS -m 5 --cacert /etc/elasticsearch/certs/ca.crt -u "elastic:$ES_PW" -X POST "https://$t:9200/orders/_doc" -H 'Content-Type: application/json' \
      -d "{\"order_id\":\"ORD-W-$i\",\"status\":\"paid\",\"amount\":1,\"created_at\":\"2026-10-24T08:00:00Z\"}" -o /dev/null -w '%{http_code}' 2>/dev/null)
    echo "$(date +%T) $t $i ${r:-ERR}"; sleep 0.5
  done > results/30-writer.log
}
docker compose rm -sf $N >/dev/null 2>&1; docker compose up -d $N; sleep 5
{
note "環境：8.19.23 三節點"
x esu1 'cat /etc/rocky-release; rpm -q elasticsearch; cat /etc/yum.repos.d/elasticsearch.repo | grep baseurl'
x esu1 'cd /usr/share/elasticsearch && bin/elasticsearch-certutil ca --pem --days 3650 --out /root/es-ca.zip -s && python3 -m zipfile -e /root/es-ca.zip /root/es-ca && bin/elasticsearch-certutil cert --pem --days 825 --ca-cert /root/es-ca/ca/ca.crt --ca-key /root/es-ca/ca/ca.key --in /root/conf/instances.yml --out /root/es-certs.zip -s && python3 -m zipfile -e /root/es-certs.zip /root/es-certs && rm -rf /mnt/es-snapshots/.dist && mkdir -p /mnt/es-snapshots/.dist/ca && cp -r /root/es-certs /mnt/es-snapshots/.dist/ && cp /root/es-ca/ca/ca.crt /mnt/es-snapshots/.dist/ca/ && ls /mnt/es-snapshots/.dist/es-certs'
for n in $N; do setup_node $n $(ip $n) elasticsearch-upgrade.yml; done
x esu1 'rm -rf /mnt/es-snapshots/upgrade && install -d -o elasticsearch -g elasticsearch -m 750 /mnt/es-snapshots/upgrade'
for n in $N; do x $n 'systemctl enable -q elasticsearch && systemctl start --no-block elasticsearch && echo started'; done
wait_until "叢集組成" 180 "docker compose exec -T esu1 grep -q 'master node changed' $LOG"
for n in $N; do wait_until "$n active" 180 "docker compose exec -T $n systemctl is-active -q elasticsearch"; done
x esu1 "journalctl -u elasticsearch --no-pager -n 40 | grep -E 'ERROR|setting \[' | cut -c1-400 | tail -5; grep -E '\]\[(WARN|ERROR)' $LOG | cut -c1-300 | head -10"
PW=$(docker compose exec -T esu1 /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
ES_PW=$PW e esu1 POST /_security/user/elastic/_password '{"password":"ChangeMe_Elastic_2026"}'
for n in $N; do x $n "sed -i '/^cluster.initial_master_nodes/d' /etc/elasticsearch/elasticsearch.yml"; done
e esu1 GET '/_cat/nodes?v&h=name,version,node.role,master'
e esu1 GET '/_cluster/health?filter_path=status,number_of_nodes'

note "升級前的資料：orders（3 主分片 1 副本）與內建 logs 範本的 data stream"
e esu1 PUT /_component_template/base-settings @/root/conf/index-template.yaml
e esu1 PUT /_index_template/apps '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
e esu1 PUT /orders '{"settings":{"index.number_of_shards":3},"mappings":{"dynamic":"strict","properties":{"order_id":{"type":"keyword"},"customer_id":{"type":"keyword"},"status":{"type":"keyword"},"amount":{"type":"scaled_float","scaling_factor":100},"region":{"type":"keyword"},"product":{"type":"keyword"},"qty":{"type":"integer"},"created_at":{"type":"date"},"note":{"type":"text"}}}}'
x esu1 '/root/bin/gen-orders.sh 100000 > /tmp/orders.ndjson && ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esu1 orders /tmp/orders.ndjson 5000'
e esu1 POST '/logs-app-default/_doc?refresh=wait_for&filter_path=result,_index' '{"@timestamp":"2026-10-24T08:00:00Z","message":"before upgrade","host":{"name":"web1"}}'
e esu1 GET '/_data_stream/logs-app-default?filter_path=data_streams.name,data_streams.indices.index_name,data_streams.index_mode&pretty'
e esu1 GET '/.ds-logs-app-default-*/_settings/index.mode,index.version.created?flat_settings&include_defaults&filter_path=*.settings,*.defaults.index\.mode&pretty'
e esu1 POST /orders/_refresh
e esu1 GET '/_cat/indices/orders?v&h=health,index,pri,rep,docs.count,store.size'

note "升級前檢查：deprecation、system features、快照"
e esu1 GET '/_migration/deprecations?pretty'
e esu1 GET '/_migration/system_features?filter_path=migration_status,features.feature_name,features.migration_status&pretty'
e esu1 PUT /_snapshot/upgrade_repo '{"type":"fs","settings":{"location":"/mnt/es-snapshots/upgrade"}}'
e esu1 PUT '/_snapshot/upgrade_repo/before-9.5.5?wait_for_completion=true&filter_path=snapshot.snapshot,snapshot.version,snapshot.state,snapshot.shards' '{"indices":"*","include_global_state":true}'

note "滾動升級：非 master 先、master 最後；背景每 0.5 秒寫入一筆"
M=$(master $N); ORDER="$(for n in $N; do [ $n != "$M" ] && echo $n; done | tr '\n' ' ')$M"
echo "master=$M，升級順序：$ORDER"
touch results/.writer-on; echo $M > results/.writer-target; writer & WPID=$!
for n in $ORDER; do
  T0=$(date +%s)
  O=$(for m in $N; do [ $m != $n ] && echo $m; done | head -1); echo $O > results/.writer-target
  note "升級 $n（寫入改送 $O）"
  e $n PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
  e $n POST '/_flush?filter_path=_shards'
  x $n 'systemctl stop elasticsearch && echo stopped'
  x $n 'cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && time dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 2>&1 | grep -vE "B/s \||^\s*$" | tail -25'
  x $n 'rpm -q elasticsearch; ls /etc/elasticsearch/ | grep -E "rpmnew|rpmsave" || echo "(no .rpmnew / .rpmsave)"'
  x $n 'systemctl daemon-reload && time systemctl start elasticsearch && systemctl is-active elasticsearch'
  wait_until "$n 重新加入" 180 "nodes_seen $O | grep -q $n"
  e $O GET '/_cat/nodes?v&h=name,version,master&s=name'
  e $O PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":null}}'
  if ! wait_until "green" 180 "[ \"\$(health $O)\" = green ]"; then
    e $O GET '/_cluster/health?filter_path=status,unassigned_shards'
    e $O GET '/_cluster/allocation/explain?filter_path=index,shard,primary,current_state,allocate_explanation,node_allocation_decisions.node_name,node_allocation_decisions.deciders.decider,node_allocation_decisions.deciders.explanation&pretty'
  fi
  echo "$n：$(( $(date +%s)-T0 )) 秒"
done
rm -f results/.writer-on; wait $WPID

note "升級後"
e esu1 GET '/_cat/nodes?v&h=name,version,node.role,master&s=name'
e esu1 GET '/?filter_path=version.number,version.lucene_version,version.minimum_wire_compatibility_version,version.minimum_index_compatibility_version&pretty'
e esu1 GET '/_cluster/health?filter_path=status,number_of_nodes,active_shards,unassigned_shards'
echo "背景寫入：共 $(wc -l < results/30-writer.log) 次，HTTP 狀態統計："; awk '{print $4}' results/30-writer.log | sort | uniq -c
awk '$4 != "201"' results/30-writer.log | head -20
e esu1 POST /orders/_refresh
e esu1 GET '/orders/_count'
e esu1 GET '/orders/_settings/index.version.created,index.version.compatibility?flat_settings&include_defaults&filter_path=*.settings,*.defaults&pretty'
e esu1 GET '/_migration/deprecations?filter_path=cluster_settings,node_settings,index_settings&pretty'
e esu1 POST '/logs-app-default/_rollover?filter_path=old_index,new_index,rolled_over'
e esu1 POST '/logs-app-default/_doc?refresh=wait_for&filter_path=result,_index' '{"@timestamp":"2026-10-24T09:00:00Z","message":"after upgrade","host":{"name":"web1"}}'
e esu1 GET '/.ds-logs-app-default-*/_settings/index.mode,index.version.created?flat_settings&include_defaults&filter_path=*.settings,*.defaults.index\.mode&pretty'
e esu1 GET '/_cat/snapshots/upgrade_repo?v&h=id,status,indices'

note "9.x 新增的叢集狀態加密：升級上來的節點沒有 auto-config，要自己在每台的 keystore 加密碼"
x esu1 '/usr/share/elasticsearch/bin/elasticsearch-keystore list'
e esu1 GET '/_health_report/cluster_state_encryption?pretty'
for n in $N; do x $n 'openssl rand -base64 32 | tr -d "\n" | /usr/share/elasticsearch/bin/elasticsearch-keystore add -x -f cluster.state.encryption.password.v1 && printf v1 | /usr/share/elasticsearch/bin/elasticsearch-keystore add -x -f cluster.state.encryption.active_password_id && /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep cluster.state'; done
e esu1 POST '/_nodes/reload_secure_settings?filter_path=_nodes,nodes.*.name,nodes.*.reload_exception&pretty'
e esu1 GET '/_health_report/cluster_state_encryption?pretty'

note "降版測試：esu1 裝回 8.19.23"
e esu2 PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
x esu1 'systemctl stop elasticsearch && cp /root/conf/elasticsearch-8.repo /etc/yum.repos.d/elasticsearch.repo && dnf downgrade -y --enablerepo=elasticsearch elasticsearch-8.19.23 2>&1 | grep -E "Downgrad|Complete|Error" | head -5; rpm -q elasticsearch'
x esu1 "systemctl start elasticsearch; systemctl is-active elasticsearch; journalctl -u elasticsearch --no-pager -n 60 | grep -E 'ERROR|Exception|cannot|incompatible|downgrade' | cut -c1-600 | tail -6"
x esu1 'systemctl reset-failed elasticsearch; cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 2>&1 | grep -E "Upgrad|Complete" | head -3 && systemctl daemon-reload && systemctl start elasticsearch && rpm -q elasticsearch'
wait_until "esu1 重新加入" 180 "nodes_seen esu2 | grep -q esu1"
e esu2 PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":null}}'
wait_until "green" 180 "[ \"\$(health esu2)\" = green ]"
e esu2 GET '/_cat/nodes?v&h=name,version,master&s=name'
for n in $N; do x $n "grep -E '\]\[(WARN|ERROR)' $LOG | cut -c1-300 | sed -E 's/^\[[^]]+\]//' | sort | uniq -c | sort -rn | head -12 || echo '(none)'"; done
x esu1 'rm -rf /mnt/es-snapshots/.dist'
} 2>&1 | tee results/30-rolling-upgrade.log
rm -f results/.writer-target conf/elasticsearch-upgrade.yml
