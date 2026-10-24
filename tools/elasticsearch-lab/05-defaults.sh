#!/usr/bin/env bash
# 預設值對照：esd9（9.5.5）、esd8（8.19.23）各自用 RPM 安裝後的原始設定（auto-config）啟動，一次只開一台（自動 heap），
# 匯出節點與索引層級的所有預設值，供設定檔逐一核對「預設」標記，並產生 8.19 vs 9.5 差異
source "$(dirname "$0")/lib.sh"
for d in esd9 esd8; do
docker compose rm -sf $d >/dev/null 2>&1; docker compose up -d $d; sleep 5
v=$( [ $d = esd9 ] && echo 9.5.5 || echo 8.19.23 )
{
note "$d：RPM 安裝後的原始設定（auto-config 的結果）"
x $d 'rpm -q elasticsearch; cat /etc/rocky-release; nproc; free -m | head -2'
x $d 'grep -Ev "^\s*(#|$)" /etc/elasticsearch/elasticsearch.yml'
x $d 'ls -l /etc/elasticsearch /etc/elasticsearch/certs /etc/elasticsearch/jvm.options.d'
x $d 'grep -Ev "^\s*(#|$)" /etc/elasticsearch/jvm.options'
x $d 'grep -Ev "^\s*(#|$)" /etc/sysconfig/elasticsearch || echo "(全部是註解)"'
x $d 'systemctl cat elasticsearch | grep -Ev "^\s*(#|$)"'
x $d 'ls /usr/lib/sysctl.d/; cat /usr/lib/sysctl.d/elasticsearch.conf; sysctl vm.max_map_count vm.swappiness net.ipv4.tcp_retries2'
x $d '/usr/share/elasticsearch/bin/elasticsearch-keystore list'
x $d '/usr/share/elasticsearch/jdk/bin/java -version'
x $d 'grep -Ev "^\s*(#|$)" /etc/elasticsearch/log4j2.properties | grep -E "appender\.(rolling|deprecation_rolling|index_search_slowlog_rolling|index_indexing_slowlog_rolling)\.(fileName|filePattern|policies\.size\.size|strategy\.max)|^logger\.(index_search_slowlog|index_indexing_slowlog)\.level|^rootLogger.level"'
note "$d：第一次啟動（自動 heap）"
x $d 'time systemctl start elasticsearch; systemctl is-active elasticsearch'
x $d 'ps -o args= -C java | tr " " "\n" | grep -E "^-X|^-XX|^-Des\.|^-Djava\.io|^-Dlog4j|^-Djdk" | sort'
x $d 'cat /proc/$(pgrep -f org.elasticsearch.bootstrap.Elasticsearch | head -1)/limits | grep -E "open files|processes|locked memory|address space"'
PW=$(docker compose exec -T $d /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s 2>/dev/null | tail -1 | tr -d '\r')
echo "（elastic 密碼重設為隨機值後，再用 API 改成實驗用密碼）"
ES_PW=$PW e $d POST /_security/user/elastic/_password '{"password":"ChangeMe_Elastic_2026"}'
e $d GET /
e $d GET '/_cat/nodes?v&h=name,version,node.role,heap.max,ram.max,cpu,master'
e $d GET '/_nodes/_local/jvm?filter_path=nodes.*.jvm.mem,nodes.*.jvm.gc_collectors,nodes.*.jvm.using_compressed_ordinary_object_pointers,nodes.*.jvm.version,nodes.*.jvm.vm_name&pretty'
e $d GET '/_nodes/_local/process,os?filter_path=nodes.*.process,nodes.*.os.available_processors,nodes.*.os.allocated_processors&pretty'
e $d GET '/_cat/thread_pool?v&h=name,type,size,queue_size,min,max&s=name'
e $d GET '/_nodes/_local/settings?flat_settings&filter_path=nodes.*.settings&pretty'
e $d GET '/_index_template?filter_path=index_templates.name'
e $d GET '/_cat/indices?v&expand_wildcards=all&s=index'
e $d PUT /defaults-check '{"settings":{}}'
} 2>&1 | tee results/05-defaults-$d.log
# 匯出預設值（key|value），flat_settings
eq $d GET '/_cluster/settings?include_defaults=true&flat_settings=true' | jq -r '.defaults | to_entries[] | "\(.key)|\(.value|tostring)"' | sort > results/defaults-node-$v.txt
eq $d GET '/defaults-check/_settings?include_defaults=true&flat_settings=true' | jq -r '.["defaults-check"] | (.settings + .defaults) | to_entries[] | "\(.key)|\(.value|tostring)"' | sort > results/defaults-index-$v.txt
eq $d GET '/_nodes/_local/thread_pool' | jq -r '.nodes[].thread_pool | to_entries[] | "\(.key)|\(.value|tostring)"' | sort > results/defaults-threadpool-$v.txt
eq $d GET '/_cluster/settings?flat_settings=true' > results/cluster-settings-$v.json
echo "$d：node $(wc -l < results/defaults-node-$v.txt) 筆、index $(wc -l < results/defaults-index-$v.txt) 筆" | tee -a results/05-defaults-$d.log
docker compose exec -T $d systemctl stop elasticsearch
docker compose rm -sf $d >/dev/null 2>&1
done
# 8.19 vs 9.5 差異：ADD 9.5 新增、DEL 9.5 移除、CHG 預設值改變（name|8.19|9.5）
for k in node index threadpool; do
awk -F'|' 'NR==FNR { a[$1]=substr($0, length($1)+2); next }
  { v=substr($0, length($1)+2) }
  !($1 in a) { print "ADD " $1 "|" v; next }
  a[$1] != v { print "CHG " $1 "|" a[$1] "|" v }
  { delete a[$1] }
  END { for (k in a) print "DEL " k "|" a[k] }' results/defaults-$k-8.19.23.txt results/defaults-$k-9.5.5.txt | sort > results/defaults-diff-$k-8-9.txt
echo "$k：$(wc -l < results/defaults-diff-$k-8-9.txt) 筆差異"
done
