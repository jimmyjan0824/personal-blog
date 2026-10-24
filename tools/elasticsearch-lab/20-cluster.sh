#!/usr/bin/env bash
# 三節點叢集：esc1~esc3（master + data + ingest），自建 CA，照文章步驟建置並做故障、滾動重啟、快照、擴充測試
source "$(dirname "$0")/lib.sh"
N="esc1 esc2 esc3"
LOG=/var/log/elasticsearch/es-prod.log
ip() { case $1 in esc1) echo 192.168.60.21;; esc2) echo 192.168.60.22;; esc3) echo 192.168.60.23;; esc4) echo 192.168.60.24;; esac; }
nodes_seen() { eq $1 GET '/_cat/nodes?h=name' 2>/dev/null | tr -d '\r' | sort | tr '\n' ' '; }
health() { eq $1 GET '/_cluster/health' 2>/dev/null | jq -r .status 2>/dev/null; }
docker compose rm -sf $N esc4 >/dev/null 2>&1; docker volume rm -f "$(basename "$PWD")_snap" >/dev/null 2>&1
docker compose up -d $N; sleep 5
{
note "環境"
x esc1 'cat /etc/rocky-release; rpm -q elasticsearch; nproc; free -m | head -2'

note "步驟 1：建立 CA 與節點憑證（在 esc1 上，用 elasticsearch-certutil）"
x esc1 'cd /usr/share/elasticsearch && bin/elasticsearch-certutil ca --pem --days 3650 --out /root/es-ca.zip -s && python3 -m zipfile -e /root/es-ca.zip /root/es-ca && ls -l /root/es-ca/ca'
x esc1 'cd /usr/share/elasticsearch && bin/elasticsearch-certutil cert --pem --days 825 --ca-cert /root/es-ca/ca/ca.crt --ca-key /root/es-ca/ca/ca.key --in /root/conf/instances.yml --out /root/es-certs.zip -s && python3 -m zipfile -e /root/es-certs.zip /root/es-certs && ls /root/es-certs /root/es-certs/esc1'
x esc1 'openssl x509 -in /root/es-certs/esc1/esc1.crt -noout -subject -issuer -enddate -ext subjectAltName'
echo "（實驗環境用共用 volume 發送憑證；正式環境用 scp / 設定管理工具，CA 私鑰不要放在節點上）"
x esc1 'mkdir -p /mnt/es-snapshots/.dist && cp -r /root/es-certs /mnt/es-snapshots/.dist/ && mkdir -p /mnt/es-snapshots/.dist/ca && cp /root/es-ca/ca/ca.crt /mnt/es-snapshots/.dist/ca/'

note "步驟 2：三台都做（OS 參數、systemd override、移除 auto-config 憑證、放憑證、elasticsearch.yml、heap）"
x esc1 'grep -Ev "^\s*(#|$)" /etc/elasticsearch/elasticsearch.yml; /usr/share/elasticsearch/bin/elasticsearch-keystore list; ls /etc/elasticsearch/certs'
for n in $N; do setup_node $n $(ip $n) elasticsearch-cluster.yml; done
x esc1 'rm -rf /mnt/es-snapshots/prod && install -d -o elasticsearch -g elasticsearch -m 750 /mnt/es-snapshots/prod && ls -ld /mnt/es-snapshots/prod'

note "步驟 3：三台同時啟動（第一次 bootstrap）"
for n in $N; do x $n 'systemctl enable elasticsearch -q && systemctl start --no-block elasticsearch && echo started'; done
wait_until "叢集組成（esc1 日誌出現 master node changed）" 180 "docker compose exec -T esc1 grep -q 'master node changed' $LOG"
for n in $N; do wait_until "$n systemd active" 180 "docker compose exec -T $n systemctl is-active -q elasticsearch"; done
x esc1 "grep -E 'master node changed|elected-as-master|cluster UUID|initial_master_nodes|added \{' $LOG | cut -c1-400 | head -10"
PW=$(docker compose exec -T esc1 /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
echo "[esc1]# /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s"; echo "（輸出的隨機密碼省略，長度 ${#PW}）"; echo
ES_PW=$PW e esc1 POST /_security/user/elastic/_password '{"password":"ChangeMe_Elastic_2026"}'

note "步驟 4：驗證叢集"
e esc1 GET '/_cat/nodes?v&h=name,ip,version,node.role,master,heap.max,heap.percent,ram.max'
e esc1 GET '/_cat/master?v'
e esc1 GET '/_cluster/health?pretty'
e esc1 GET '/_cluster/state?filter_path=metadata.cluster_coordination&pretty'
e esc1 GET '/_nodes/process?filter_path=nodes.*.name,nodes.*.process.mlockall&pretty'
e esc2 GET '/_ssl/certificates?filter_path=path,subject_dn,expiry,format&pretty'
eq esc1 GET '/_nodes/_local/settings?flat_settings' > results/actual-node-esc1.json
x esc1 'python3 /root/bin/checkconf.py /etc/elasticsearch/elasticsearch.yml /root/results/defaults-node-9.5.5.txt /root/results/actual-node-esc1.json'
x esc1 "grep -E 'initial_master_nodes' $LOG | cut -c1-500 | tail -3 || echo '(no initial_master_nodes warning yet)'"

note "索引範本與測試資料（3 個主分片、1 份副本）"
e esc1 PUT /_component_template/base-settings @/root/conf/index-template.yaml
e esc1 PUT /_index_template/apps '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
e esc1 PUT /orders '{"settings":{"index.number_of_shards":3},"mappings":{"dynamic":"strict","properties":{"order_id":{"type":"keyword"},"customer_id":{"type":"keyword"},"status":{"type":"keyword"},"amount":{"type":"scaled_float","scaling_factor":100},"region":{"type":"keyword"},"product":{"type":"keyword"},"qty":{"type":"integer"},"created_at":{"type":"date"},"note":{"type":"text"}}}}'
eq esc1 GET '/orders/_settings?flat_settings&include_defaults' > results/actual-index-esc1.json
x esc1 'python3 /root/bin/checkconf.py /root/conf/index-template.yaml /root/results/defaults-index-9.5.5.txt /root/results/actual-index-esc1.json'
x esc1 '/root/bin/gen-orders.sh 300000 > /tmp/orders.ndjson && ES_PW=ChangeMe_Elastic_2026 /root/bin/bulk-load.sh esc1 orders /tmp/orders.ndjson 5000'
e esc1 POST /orders/_refresh
e esc1 GET '/_cat/indices/orders?v&h=health,index,pri,rep,docs.count,store.size,pri.store.size'
e esc1 GET '/_cat/shards/orders?v&h=index,shard,prirep,state,docs,store,node&s=shard,prirep'

note "測試 1：data 節點無回應（docker pause，非 master 的節點）"
M=$(master $N); V=$(for n in $N; do [ $n != "$M" ] && echo $n; done | tail -1); O=$M
echo "master=$M，暫停 $V，從 $O 觀察"
x $O 'date "+%T"'
T0=$(date +%s); h "docker compose pause $V"
for i in $(seq 1 120); do case "$(nodes_seen $O)" in *$V*) sleep 1;; *) echo "$(date '+%T') $V 已從叢集移除，經過 $(( $(date +%s)-T0 )) 秒"; break;; esac; done
x $O "grep -E 'node-left|followers check|$V' $LOG | cut -c1-400 | tail -4"
e $O GET '/_cluster/health?filter_path=status,number_of_nodes,active_primary_shards,active_shards,unassigned_shards,delayed_unassigned_shards'
e $O GET '/_cat/shards/orders?v&h=index,shard,prirep,state,node,unassigned.reason&s=shard,prirep'
e $O GET '/_cluster/allocation/explain?filter_path=index,shard,primary,current_state,unassigned_info.reason,unassigned_info.delayed,allocate_explanation,configured_delay_in_millis,remaining_delay_in_millis&pretty' '{"index":"orders","shard":0,"primary":false}'
e $O POST '/orders/_doc?refresh=wait_for&filter_path=result,_shards' '{"order_id":"ORD-DURING-T1","status":"paid","amount":1,"created_at":"2026-10-24T08:00:00Z"}'
e $O GET '/orders/_count'
T1=$(date +%s); h "docker compose unpause $V"
wait_until "green" 300 "[ \"\$(health $O)\" = green ]"
echo "unpause 後回到 green 共 $(( $(date +%s)-T1 )) 秒"
e $O GET '/_cat/recovery/orders?v&h=index,shard,type,stage,source_node,target_node,files_percent,bytes_total,translog_ops&active_only=false&s=shard'

note "測試 2：master 節點無回應（docker pause 目前的 master）"
M=$(master $N); O=$(for n in $N; do [ $n != "$M" ] && echo $n; done | head -1)
echo "master=$M，從 $O 觀察"
T0=$(date +%s); h "docker compose pause $M"
for i in $(seq 1 120); do nm=$(master $O); if [ -n "$nm" ] && [ "$nm" != "$M" ]; then echo "$(date '+%T') 新的 master：$nm，經過 $(( $(date +%s)-T0 )) 秒"; break; fi; sleep 1; done
x $O "grep -E 'master node changed|elected-as-master|leader check|master not discovered' $LOG | cut -c1-400 | tail -5"
e $O GET '/_cat/nodes?v&h=name,master,node.role'
e $O POST '/orders/_doc?refresh=wait_for&filter_path=result' '{"order_id":"ORD-DURING-T2","status":"paid","amount":2,"created_at":"2026-10-24T08:00:00Z"}'
T1=$(date +%s); h "docker compose unpause $M"
wait_until "green" 300 "[ \"\$(health $O)\" = green ]"
echo "unpause 後回到 green 共 $(( $(date +%s)-T1 )) 秒"
e $O GET '/_cat/nodes?v&h=name,master'

note "測試 3：停掉兩台（失去過半數）"
S=$(for n in $N; do echo $n; done | head -2 | tr '\n' ' '); R=esc3
for n in $S; do x $n 'systemctl stop elasticsearch && echo stopped'; done
sleep 15
e $R GET '/_cluster/health?filter_path=status,error.type,error.reason'
e $R GET '/orders/_count?filter_path=count,error.type'
e $R POST '/orders/_doc?timeout=5s&filter_path=result,error.type,error.reason,status' '{"order_id":"ORD-NOQUORUM","status":"paid","amount":3,"created_at":"2026-10-24T08:00:00Z"}'
x $R "grep -E 'master not discovered' $LOG | tail -1 | cut -c1-900"
F=$(echo $S | cut -d' ' -f1)
T0=$(date +%s); x $F 'systemctl start elasticsearch && echo started'
for i in $(seq 1 120); do nm=$(master $R); [ -n "$nm" ] && { echo "$(date '+%T') master 選出：$nm，$F 啟動指令後 $(( $(date +%s)-T0 )) 秒"; break; }; sleep 1; done
e $R POST '/orders/_doc?refresh=wait_for&filter_path=result' '{"order_id":"ORD-AFTER-QUORUM","status":"paid","amount":4,"created_at":"2026-10-24T08:00:00Z"}'
x $(echo $S | cut -d' ' -f2) 'systemctl start elasticsearch && echo started'
wait_until "green" 300 "[ \"\$(health $R)\" = green ]"

note "測試 4：滾動重啟（順便移除 cluster.initial_master_nodes），master 最後"
M=$(master $N); ORDER="$(for n in $N; do [ $n != "$M" ] && echo $n; done | tr '\n' ' ')$M"
echo "重啟順序：$ORDER"
for n in $ORDER; do
  T0=$(date +%s)
  x $n "sed -i '/^cluster.initial_master_nodes/d' /etc/elasticsearch/elasticsearch.yml && grep -c initial_master_nodes /etc/elasticsearch/elasticsearch.yml"
  e $n PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
  e $n POST '/_flush?filter_path=_shards'
  x $n 'time systemctl restart elasticsearch'
  O=$(for m in $N; do [ $m != $n ] && echo $m; done | head -1)
  wait_until "$n 重新加入" 180 "nodes_seen $O | grep -q $n"
  e $O PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.enable":null}}'
  wait_until "green" 300 "[ \"\$(health $O)\" = green ]"
  echo "$n：$(( $(date +%s)-T0 )) 秒"
done
e esc1 GET '/_cat/nodes?v&h=name,master,uptime'
e esc1 GET '/_cluster/settings?flat_settings'

note "測試 5：快照與還原（fs 儲存庫，三台掛載同一個 volume）"
e esc1 PUT /_snapshot/nfs_repo '{"type":"fs","settings":{"location":"/mnt/es-snapshots/prod"}}'
e esc1 POST '/_snapshot/nfs_repo/_verify?pretty'
e esc1 PUT /_slm/policy/nightly '{"schedule":"0 30 17 * * ?","name":"<nightly-{now/d}>","repository":"nfs_repo","config":{"indices":"*","include_global_state":true},"retention":{"expire_after":"30d","min_count":7,"max_count":60}}'
e esc1 POST /_slm/policy/nightly/_execute
wait_until "SLM 快照完成" 120 "eq esc1 GET '/_snapshot/nfs_repo/_all' | jq -e '.snapshots[] | select(.state==\"SUCCESS\")'"
e esc1 GET '/_snapshot/nfs_repo/_all?filter_path=snapshots.snapshot,snapshots.state,snapshots.indices,snapshots.duration_in_millis,snapshots.shards&pretty'
SNAP=$(eq esc1 GET '/_snapshot/nfs_repo/_all' | jq -r '.snapshots[0].snapshot')
C0=$(eq esc1 GET /orders/_count | jq .count); echo "還原前 orders 文件數：$C0"
e esc1 DELETE /orders
T0=$(date +%s)
e esc1 POST "/_snapshot/nfs_repo/$SNAP/_restore?wait_for_completion=true&filter_path=snapshot.shards" '{"indices":"orders","include_global_state":false}'
wait_until "green" 300 "[ \"\$(health esc1)\" = green ]"
echo "還原到 green 共 $(( $(date +%s)-T0 )) 秒"
e esc1 GET '/orders/_count'
x esc1 'du -sh /mnt/es-snapshots/prod; ls /mnt/es-snapshots/prod'
e esc1 GET '/_slm/stats?filter_path=total_snapshots_taken,total_snapshots_failed,policy_stats&pretty'

note "測試 6：加入第 4 台 data 節點（esc4，roles 只有 data + ingest），再排空移除"
docker compose up -d esc4; sleep 5
setup_node esc4 $(ip esc4) elasticsearch-cluster.yml '[ data, ingest ]'
x esc4 "sed -i '/^cluster.initial_master_nodes/d' /etc/elasticsearch/elasticsearch.yml && grep -E '^(node.roles|discovery.seed_hosts)' /etc/elasticsearch/elasticsearch.yml"
T0=$(date +%s); x esc4 'systemctl enable -q elasticsearch && time systemctl start elasticsearch'
wait_until "esc4 加入" 120 "nodes_seen esc1 | grep -q esc4"
wait_until "分片搬移完成（green 且沒有 relocating）" 300 "eq esc1 GET '/_cluster/health' | jq -e '.status==\"green\" and .relocating_shards==0'"
echo "esc4 啟動到平衡完成共 $(( $(date +%s)-T0 )) 秒"
e esc1 GET '/_cat/allocation?v&h=node,shards,disk.indices&s=node'
e esc1 GET '/_cat/shards/orders?v&h=index,shard,prirep,state,node&s=shard,prirep'
e esc1 GET '/_cluster/state?filter_path=metadata.cluster_coordination.last_committed_config&pretty'
e esc1 PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.exclude._name":"esc4"}}'
wait_until "esc4 排空" 300 "[ \"\$(eq esc1 GET '/_cat/allocation/esc4?h=shards' | tr -d '\r\n ')\" = 0 ]"
e esc1 GET '/_cat/allocation?v&h=node,shards&s=node'
x esc4 'systemctl stop elasticsearch && echo stopped'
e esc1 PUT /_cluster/settings '{"persistent":{"cluster.routing.allocation.exclude._name":null}}'
wait_until "green" 120 "[ \"\$(health esc1)\" = green ]"
e esc1 GET '/_cat/nodes?v&h=name,node.role,master'

note "最後狀態與錯誤日誌"
e esc1 GET '/_cluster/health?filter_path=status,number_of_nodes,active_shards,unassigned_shards'
for n in $N; do x $n "grep -E '\]\[(WARN|ERROR)' $LOG | cut -c1-300 | sort | uniq -c | sort -rn | head -15 || echo '(none)'"; done
x esc1 'rm -rf /mnt/es-snapshots/.dist'
} 2>&1 | tee results/20-cluster.log
docker compose stop esc4 >/dev/null 2>&1
