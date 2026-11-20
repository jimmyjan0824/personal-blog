#!/usr/bin/env bash
# Lab 10：InnoDB ClusterSet 跨機房 DR（Percona Server 8.4.11）
#   site A：db1~db3（clusterA，主叢集）  site B：db4~db6（clusterB，副本叢集）
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
fresh db1 db2 db3 db4 db5 db6 router app
CS="var cs = dba.getClusterSet();"
{
note "步驟 1：六台初始化、dba.configureInstance()"
id=0
for n in db1 db2 db3 db4 db5 db6; do id=$((id+1)); init_node $n $id 00-server.cnf lab09/replication.cnf >/dev/null; done
x db4 'mysqld --version; cat /etc/my.cnf.d/server-id.cnf'
for n in db1 db2 db3 db4 db5 db6; do
  jsroot $n "dba.configureInstance(null, {clusterAdmin: \"'clusteradmin'@'192.168.58.%'\", clusterAdminPassword: '$CPW', restart: false})" | grep -E 'mysqlsh>|successfully|ready|valid|ERROR|restart'
done

note "步驟 2：site A 建立 clusterA（db1 + db2、db3）"
seed_app db1
js db1 "var c = dba.createCluster('clusterA')" | grep -vE '^\s*$'
for n in db2 db3; do js db1 "dba.getCluster().addInstance('$n:3306', {recoveryMethod: 'clone'})" | grep -E 'mysqlsh>|Clone process has finished|was successfully added|ERROR'; done

note "步驟 3：建立 ClusterSet，site B 建立副本叢集 clusterB（db4 + db5、db6）"
js db1 "dba.getCluster().createClusterSet('cs_lab')"
js db1 "$CS cs.createReplicaCluster('db4:3306', 'clusterB', {recoveryMethod: 'clone'})" | grep -vE '^\s*$|^\*\* Stage'
for n in db5 db6; do js db4 "dba.getCluster().addInstance('$n:3306', {recoveryMethod: 'clone'})" | grep -E 'mysqlsh>|Clone process has finished|was successfully added|ERROR'; done
js db1 "$CS print(cs.status())"
js db1 "$CS print(cs.describe())"
x db4 'mysql --table -e "SELECT CHANNEL_NAME, HOST, PORT, SOURCE_CONNECTION_AUTO_FAILOVER FROM performance_schema.replication_connection_configuration WHERE CHANNEL_NAME LIKE \"clusterset%\"; SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE FROM performance_schema.replication_group_members;"'

note "步驟 4：Router bootstrap 到 ClusterSet，app 寫入 6446"
x router "mysqlrouter --bootstrap 'clusteradmin:$CPW@db1:3306' --user=mysqlrouter 2>&1 | grep -E 'Bootstrapping|configured for|Read/Write Conn|Read/Only Conn'"
x router 'systemctl enable --now mysqlrouter >/dev/null 2>&1; sleep 2; systemctl is-active mysqlrouter'
js db1 "$CS print(cs.listRouters())"
writer_start router:6446

note "步驟 5：計畫內切換 cs.setPrimaryCluster('clusterB')（例如機房 A 要停機維護）"
T1=$(now)
js db1 "$CS cs.setPrimaryCluster('clusterB')" | grep -vE '^\s*$'
x app 'sleep 3; tail -2 /tmp/writer.log'
outage $T1
js db4 "$CS print(cs.status())"

note "步驟 6：災難：site B（現在的主叢集）整個機房斷線"
T2=$(now)
for n in db4 db5 db6; do x $n 'systemctl kill -s KILL mysqld; systemctl stop mysqld; systemctl is-active mysqld'; done
x app 'sleep 5; tail -3 /tmp/writer.log'
js db1 "$CS print(cs.status())"

note "步驟 7：在 site A 強制把 clusterA 升為主叢集 cs.forcePrimaryCluster('clusterA')"
js db1 "$CS cs.forcePrimaryCluster('clusterA')" | grep -vE '^\s*$'
x app 'sleep 12; tail -2 /tmp/writer.log'
outage $T2 $(now)
js db1 "$CS print(cs.status())"

note "步驟 8：site B 恢復：叢集要從完全停機重新啟動，再加回 ClusterSet"
for n in db4 db5 db6; do x $n 'systemctl start mysqld; systemctl is-active mysqld'; done
js db1 "$CS print(cs.status())"
js db4 "dba.rebootClusterFromCompleteOutage('clusterB')" | grep -vE '^\s*$'
js db1 "$CS print(cs.status())"
js db1 "$CS cs.rejoinCluster('clusterB')" | grep -vE '^\s*$'
for n in db5 db6; do js db4 "dba.getCluster().rejoinInstance('$n:3306')" | grep -vE '^\s*$'; done
x db4 'sleep 5'
js db1 "$CS print(cs.status({extended: 1}))"

note "最終驗證"
x app 'touch /tmp/writer.stop; sleep 1; echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; grep " OK " /tmp/writer.log | awk "{print \$4}" | sort | uniq -c'
m db1 "SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;"
sync_cmp db1 db2 db3 db4 db5 db6
} 2>&1 | tee results/10-clusterset.log
