#!/usr/bin/env bash
# Lab 09：InnoDB ReplicaSet（Percona Server 8.4.11）：建立、MySQL Router、計畫內切換、主庫故障後手動 failover、舊主庫重新加入
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
fresh db1 db2 db3 router app
{
note "步驟 1：三台初始化（設定檔：00-server.cnf + replication.cnf）"
id=0
for n in db1 db2 db3; do id=$((id+1)); init_node $n $id 00-server.cnf lab09/replication.cnf; done

note "步驟 2：dba.configureReplicaSetInstance()：檢查設定並建立叢集管理帳號"
for n in db1 db2 db3; do
  jsroot $n "dba.configureReplicaSetInstance(null, {clusterAdmin: \"'clusteradmin'@'192.168.58.%'\", clusterAdminPassword: '$CPW'})"
done

m db1 "SELECT @@replica_parallel_workers;   -- 設定檔寫 8"
x db1 'python3 -m json.tool /var/lib/mysql/mysqld-auto.cnf | grep -B1 -A3 replica_parallel_workers'

note "步驟 3：在 db1 建立 ReplicaSet，加入 db2、db3（Clone 複製資料）"
seed_app db1
js db1 "var rs = dba.createReplicaSet('rs_lab')"
for n in db2 db3; do
  js db1 "var rs = dba.getReplicaSet(); rs.addInstance('$n:3306', {recoveryMethod: 'clone'})"
done
js db1 "print(dba.getReplicaSet().status())"
m db2 "SELECT @@hostname, @@super_read_only, @@read_only;"
rs db2

note "步驟 4：MySQL Router bootstrap"
x router "mysqlrouter --bootstrap 'clusteradmin:$CPW@db1:3306' --user=mysqlrouter 2>&1 | grep -v -E '^$|Using a password'"
x router 'systemctl enable --now mysqlrouter; sleep 2; systemctl is-active mysqlrouter'
x app "for p in 6446 6447 6447; do mysql -hrouter -P\$p -uapp -pChangeMe_App_2026 -N -e 'SELECT @@hostname, @@super_read_only' 2>/dev/null | sed \"s/^/port \$p → /\"; done"
js db1 "print(dba.getReplicaSet().listRouters())"

note "步驟 5：app 透過 Router 的讀寫埠 6446 持續寫入"
writer_start router:6446

note "步驟 6：計畫內切換 rs.setPrimaryInstance('db2')"
T1=$(now)
js db1 "dba.getReplicaSet().setPrimaryInstance('db2:3306')"
x app 'sleep 3; tail -2 /tmp/writer.log'
outage $T1
js db2 "print(dba.getReplicaSet().status())"

note "步驟 7：主庫 db2 故障（kill -9 mysqld 並停止服務），ReplicaSet 不會自動 failover"
T2=$(now)
x db2 'systemctl kill -s KILL mysqld; systemctl stop mysqld; systemctl is-active mysqld'
x app 'sleep 5; tail -3 /tmp/writer.log'
js db1 "print(dba.getReplicaSet().status())"

note "步驟 8：手動 failover：rs.forcePrimaryInstance('db1')"
js db1 "dba.getReplicaSet().forcePrimaryInstance('db1:3306')"
x app 'sleep 3; tail -2 /tmp/writer.log'
outage $T2
js db1 "print(dba.getReplicaSet().status())"

note "步驟 9：db2 修好後重新啟動：被標記為 INVALIDATED，Router 不會把流量送給它"
x db2 'systemctl start mysqld; systemctl is-active mysqld'
m db2 "SELECT @@hostname, @@read_only, @@super_read_only;"
js db1 "print(dba.getReplicaSet().status())"
note "步驟 10：rs.rejoinInstance('db2')"
js db1 "dba.getReplicaSet().rejoinInstance('db2:3306')"
js db1 "print(dba.getReplicaSet().status())"

note "最終驗證：async 複製下 failover 有沒有遺失已回報成功的寫入"
x app 'touch /tmp/writer.stop; sleep 1; echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; grep " OK " /tmp/writer.log | awk "{print \$4}" | sort | uniq -c'
m db1 "SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;"
sync_cmp db1 db2 db3
} 2>&1 | tee results/09-replicaset.log
