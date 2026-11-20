#!/usr/bin/env bash
# Lab 07：計畫內切換 db1（8.0）→ db2（8.4），db3 改接 db2，量測寫入中斷
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps80
{
note "切換前檢查"
for n in db2 db3; do rs $n; done
m db1 "SELECT @@hostname, @@version, @@read_only, @@super_read_only;"
writer_stat

note "步驟 1：舊主庫 db1 停止寫入"
m db1 "SET GLOBAL super_read_only = ON; SELECT @@GLOBAL.gtid_executed\\G"
note "步驟 2：等 db2、db3 套用完 db1 的所有交易"
G=$(q db1 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')
for n in db2 db3; do m $n "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 30) AS waited;"; done
note "步驟 3：db2 升為主庫"
m db2 "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;"
note "步驟 4：app 改寫 db2"
x app 'echo db2 > /tmp/target; sleep 2; tail -2 /tmp/writer.log'
note "步驟 5：db3 改接 db2"
m db3 "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1; START REPLICA;"
x db3 'sleep 3'
rs db3
m db2 "SHOW REPLICAS; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients'; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_status';"
note "寫入中斷時間"
x app 'grep ERR /tmp/writer.log | head -3; echo "ERR 筆數: $(grep -c " ERR " /tmp/writer.log)"; F=$(grep -m1 " ERR " /tmp/writer.log | cut -d" " -f1); L=$(grep -m1 "OK db2" /tmp/writer.log | cut -d" " -f1); echo "first ERR=$F  first OK on db2=$L"; python3 -c "import sys;from datetime import datetime as d;f=\"%H:%M:%S.%f\";print(\"寫入中斷秒數:\",(d.strptime(sys.argv[2],f)-d.strptime(sys.argv[1],f)).total_seconds())" $F $L'
sync_cmp db2 db3
} 2>&1 | tee results/07-30-switchover.log
