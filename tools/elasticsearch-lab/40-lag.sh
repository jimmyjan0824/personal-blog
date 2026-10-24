#!/usr/bin/env bash
# 同步落後：A. 叢集內副本落後（節點停機期間持續寫入，重新加入後副本追上主分片的過程）
#           B. CCR 跨叢集複製的落後（esc1~esc3 = leader 叢集 es-prod，esd9 = follower 叢集 es-dr，30 天試用授權）
# 叢集建置步驟與 20-cluster.sh 相同（不重複印出細節）
source "$(dirname "$0")/lib.sh"
N="esc1 esc2 esc3"
LOG=/var/log/elasticsearch/es-prod.log
ip() { case $1 in esc1) echo 192.168.60.21;; esc2) echo 192.168.60.22;; esc3) echo 192.168.60.23;; esd9) echo 192.168.60.41;; esac; }
nodes_seen() { eq $1 GET '/_cat/nodes?h=name' 2>/dev/null | tr -d '\r' | sort | tr '\n' ' '; }
health() { eq $1 GET '/_cluster/health' 2>/dev/null | jq -r .status 2>/dev/null; }
# DR 叢集（單節點 follower）：叢集名稱 es-dr、single-node、加上 remote_cluster_client 角色（CCR follower 需要）
sed -e 's/^cluster.name: .*/cluster.name: es-dr/' -e 's/^node.roles: .*/node.roles: [ master, data, ingest, remote_cluster_client ]/' \
    -e 's/^discovery.seed_hosts: .*/discovery.type: single-node/' -e '/^cluster.initial_master_nodes/d' \
    conf/elasticsearch-cluster.yml > conf/elasticsearch-dr.yml
docker compose rm -sf $N esd9 >/dev/null 2>&1; docker compose up -d $N esd9; sleep 5
# 每秒印一次 orders 各分片副本的 seq_no 與狀態
shard_seq() { eq $1 GET '/_cat/shards/orders?h=shard,prirep,state,node,seq_no.max,seq_no.local_checkpoint,seq_no.global_checkpoint&s=shard,prirep' | tr -s ' '; }
{
note "建置 es-prod（esc1~esc3）與 es-dr（esd9），步驟同 20-cluster.sh"
docker compose exec -T esc1 bash -c 'cd /usr/share/elasticsearch && bin/elasticsearch-certutil ca --pem --days 3650 --out /root/es-ca.zip -s && python3 -m zipfile -e /root/es-ca.zip /root/es-ca && bin/elasticsearch-certutil cert --pem --days 825 --ca-cert /root/es-ca/ca/ca.crt --ca-key /root/es-ca/ca/ca.key --in /root/conf/instances.yml --out /root/es-certs.zip -s && python3 -m zipfile -e /root/es-certs.zip /root/es-certs && rm -rf /mnt/es-snapshots/.dist && mkdir -p /mnt/es-snapshots/.dist/ca && cp -r /root/es-certs /mnt/es-snapshots/.dist/ && cp /root/es-ca/ca/ca.crt /mnt/es-snapshots/.dist/ca/' >/dev/null 2>&1
for n in $N; do setup_node $n $(ip $n) elasticsearch-cluster.yml >/dev/null; done
setup_node esd9 $(ip esd9) elasticsearch-dr.yml >/dev/null
for n in $N esd9; do docker compose exec -T $n bash -c 'systemctl enable -q elasticsearch && systemctl start --no-block elasticsearch'; done
wait_until "es-prod 組成" 180 "docker compose exec -T esc1 grep -q 'master node changed' $LOG"
for n in $N esd9; do wait_until "$n active" 180 "docker compose exec -T $n systemctl is-active -q elasticsearch"; done
for n in esc1 esd9; do
  PW=$(docker compose exec -T $n /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
  printf '{"password":"%s"}' ChangeMe_Elastic_2026 | docker compose exec -T $n bash -c "curl -sS --cacert /etc/elasticsearch/certs/ca.crt -u 'elastic:$PW' -X POST https://$n:9200/_security/user/elastic/_password -H 'Content-Type: application/json' --data-binary @-"; echo
done
for n in $N; do docker compose exec -T $n sed -i '/^cluster.initial_master_nodes/d' /etc/elasticsearch/elasticsearch.yml; done
e esc1 GET '/_cat/nodes?v&h=name,version,node.role,master'
e esd9 GET '/_cat/nodes?v&h=name,version,node.role,master'
e esc1 PUT /_component_template/base-settings @/root/conf/index-template.yaml
e esc1 PUT /_index_template/apps '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
e esc1 PUT /orders '{"settings":{"index.number_of_shards":3},"mappings":{"dynamic":"strict","properties":{"order_id":{"type":"keyword"},"customer_id":{"type":"keyword"},"status":{"type":"keyword"},"amount":{"type":"scaled_float","scaling_factor":100},"region":{"type":"keyword"},"product":{"type":"keyword"},"qty":{"type":"integer"},"created_at":{"type":"date"},"note":{"type":"text"}}}}'
x esc1 '/root/bin/gen-orders.sh 100000 1 > /tmp/o1.ndjson; /root/bin/gen-orders.sh 200000 100001 > /tmp/o2.ndjson; /root/bin/gen-orders.sh 200000 300001 > /tmp/o3.ndjson; ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esc1 orders /tmp/o1.ndjson 5000'
wait_until "green" 120 "[ \"\$(health esc1)\" = green ]"

note "A-1：正常狀態下，主分片與副本的 seq_no / checkpoint（同步複製，三個值都相同）"
e esc1 GET '/_cat/shards/orders?v&h=shard,prirep,state,node,docs,seq_no.max,seq_no.local_checkpoint,seq_no.global_checkpoint&s=shard,prirep'
e esc1 GET '/orders/_stats?level=shards&filter_path=indices.orders.shards.0.routing.node,indices.orders.shards.0.routing.primary,indices.orders.shards.0.seq_no,indices.orders.shards.0.retention_leases.leases&pretty'

note "A-2：esc3 停機期間寫入 20 萬筆，再啟動 esc3，觀察副本追上主分片"
x esc3 'systemctl stop elasticsearch && echo stopped'
wait_until "esc3 離開" 60 "! nodes_seen esc1 | grep -q esc3"
x esc1 'ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esc1 orders /tmp/o2.ndjson 5000'
e esc1 GET '/_cluster/health?filter_path=status,unassigned_shards,delayed_unassigned_shards'
e esc1 GET '/_cat/shards/orders?v&h=shard,prirep,state,node,unassigned.reason,seq_no.max,seq_no.global_checkpoint&s=shard,prirep'
T0=$(date +%s); x esc3 'systemctl start elasticsearch && echo started'
echo "# 每秒取樣（秒數從 esc3 start 指令完成起算）：shard prirep state node seq_no.max local_checkpoint global_checkpoint"
for i in $(seq 1 180); do
  s=$(shard_seq esc1); echo "--- t=$(( $(date +%s)-T0 ))s"; echo "$s" | grep -E " r " ;
  [ "$(health esc1)" = green ] && { echo "green：esc3 start 後 $(( $(date +%s)-T0 )) 秒"; break; }; sleep 1
done
e esc1 GET '/_cat/recovery/orders?v&h=shard,type,stage,source_node,target_node,files,files_percent,bytes,translog_ops,translog_ops_percent,time&active_only=false&s=shard'
e esc1 GET '/_cat/shards/orders?v&h=shard,prirep,state,node,docs,seq_no.max,seq_no.local_checkpoint,seq_no.global_checkpoint&s=shard,prirep'

note "B-1：CCR 設定（兩邊都要 Platinum 以上授權，這裡用 30 天試用）"
e esc1 POST '/_license/start_trial?acknowledge=true'
e esd9 POST '/_license/start_trial?acknowledge=true'
e esd9 PUT /_cluster/settings '{"persistent":{"cluster.remote.prod.mode":"sniff","cluster.remote.prod.seeds":["esc1:9300","esc2:9300","esc3:9300"]}}'
wait_until "remote 連線" 60 "eq esd9 GET /_remote/info | jq -e '.prod.connected'"
e esd9 GET '/_remote/info?pretty'
T0=$(date +%s)
e esd9 PUT '/orders-follower/_ccr/follow?wait_for_active_shards=1' '{"remote_cluster":"prod","leader_index":"orders"}'
wait_until "follower 追上（文件數相同）" 300 "[ \"\$(eq esd9 GET /orders-follower/_count | jq .count)\" = \"\$(eq esc1 GET /orders/_count | jq .count)\" ]"
echo "建立 follower 到文件數相同：$(( $(date +%s)-T0 )) 秒（含初始的檔案複製）"
e esd9 GET '/orders-follower/_ccr/stats?filter_path=indices.shards.shard_id,indices.shards.leader_global_checkpoint,indices.shards.leader_max_seq_no,indices.shards.follower_global_checkpoint,indices.shards.follower_max_seq_no,indices.shards.outstanding_read_requests,indices.shards.time_since_last_read_millis,indices.shards.total_read_time_millis,indices.shards.operations_read&pretty'

note "B-2：落後量測：follower 讀取速度限制在每次 500 筆、1 個 outstanding read，leader 寫入 20 萬筆"
e esd9 POST /orders-follower/_ccr/pause_follow
e esd9 POST /orders-follower/_ccr/resume_follow '{"max_read_request_operation_count":500,"max_outstanding_read_requests":1}'
(docker compose exec -T esc1 bash -c 'ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esc1 orders /tmp/o3.ndjson 5000' > results/40-bulk.out 2>&1 &)
T0=$(date +%s)
echo "# 每 2 秒取樣：落後操作數 = Σ(leader_global_checkpoint - follower_global_checkpoint)，time_since_last_read 取最大值"
for i in $(seq 1 150); do
  st=$(eq esd9 GET /orders-follower/_ccr/stats)
  lag=$(echo "$st" | jq '[.indices[0].shards[] | (.leader_global_checkpoint - .follower_global_checkpoint)] | add')
  tsl=$(echo "$st" | jq '[.indices[0].shards[] | .time_since_last_read_millis] | max')
  lc=$(eq esc1 GET /orders/_count | jq .count); fc=$(eq esd9 GET /orders-follower/_count | jq .count)
  echo "t=$(( $(date +%s)-T0 ))s ops_behind=$lag time_since_last_read_ms=$tsl leader_docs=$lc follower_docs=$fc"
  [ "$lag" = 0 ] && [ "$lc" = "$fc" ] && [ $(( $(date +%s)-T0 )) -gt 10 ] && break
  sleep 2
done
cat results/40-bulk.out; rm -f results/40-bulk.out
e esd9 GET '/orders-follower/_ccr/info?pretty'
e esd9 GET '/_ccr/stats?filter_path=auto_follow_stats.number_of_failed_follow_indices,follow_stats.indices.index,follow_stats.indices.shards.shard_id,follow_stats.indices.shards.read_exceptions,follow_stats.indices.shards.fatal_exception&pretty'

note "B-3：leader 叢集斷線（docker network disconnect esd9），恢復後的追趕"
NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' $(docker compose ps -q esd9))
h "docker network disconnect $NET $(docker compose ps -q esd9)"
docker compose exec -T esc1 bash -c '/root/bin/gen-orders.sh 50000 500001 > /tmp/o4.ndjson; ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esc1 orders /tmp/o4.ndjson 5000'
sleep 20
echo "（斷線期間 esd9 的 9200 也連不到：network.host 只綁 192.168.60.41；leader 端的文件數）"
e esc1 GET '/orders/_count'
T0=$(date +%s); h "docker network connect --ip 192.168.60.41 $NET $(docker compose ps -q esd9)"
for i in $(seq 1 120); do
  lag=$(eq esd9 GET /orders-follower/_ccr/stats | jq '[.indices[0].shards[] | (.leader_global_checkpoint - .follower_global_checkpoint)] | add')
  echo "t=$(( $(date +%s)-T0 ))s ops_behind=$lag"; [ "$lag" = 0 ] && break; sleep 2
done
e esc1 GET '/orders/_count'
e esd9 GET '/orders-follower/_count'
x esd9 "grep -E 'ccr|remote' /var/log/elasticsearch/es-dr.log | grep -E 'WARN|ERROR' | cut -c1-300 | sed -E 's/^\[[^]]+\]//' | sort | uniq -c | head -8 || echo '(none)'"
x esc1 'rm -rf /mnt/es-snapshots/.dist'
} 2>&1 | tee results/40-lag.log
rm -f conf/elasticsearch-dr.yml
