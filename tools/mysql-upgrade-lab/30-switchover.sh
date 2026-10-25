#!/usr/bin/env bash
# 計畫內主從切換：db1（5.7）→ db2（8.0）成為新主庫，db3 改接 db2；接著測試舊主庫 db1（5.7）能不能當 8.0 的從庫
source "$(dirname "$0")/lib.sh"
{
note "切換前檢查"
m db1 "SELECT @@hostname, @@version, @@read_only, @@super_read_only;"
for n in db2 db3; do rs $n; done
m db2 "SELECT @@hostname, @@version, @@read_only, @@super_read_only, @@gtid_mode;"
x app 'echo "OK=$(grep -c OK /tmp/writer.log) ERR=$(grep -c ERR /tmp/writer.log)"; tail -1 /tmp/writer.log'

note "步驟 1：舊主庫 db1 停止寫入（super_read_only），app 從這一刻開始寫入失敗"
x app 'date +%T.%3N'
m db1 "SET GLOBAL super_read_only = ON; SELECT @@GLOBAL.gtid_executed\\G"
note "步驟 2：等 db2、db3 套用完 db1 的所有交易"
G=$(docker compose exec -T db1 mysql -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')
for n in db2 db3; do m $n "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 30) AS waited;"; done
note "步驟 3：db2 升為主庫"
m db2 "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;"
x db2 "sed -i '/super_read_only/d' /etc/my.cnf.d/server-id.cnf; cat /etc/my.cnf.d/server-id.cnf; cat /var/lib/mysql/mysqld-auto.cnf; echo"
note "步驟 4：app 改寫 db2（實務上是改 VIP / DNS / Proxy）"
x app 'echo db2 > /tmp/target; date +%T.%3N; sleep 2; tail -2 /tmp/writer.log'
note "步驟 5：db3 改接 db2"
m db3 "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='ChangeMe_Repl_2026', SOURCE_AUTO_POSITION=1; START REPLICA;"
x db3 'sleep 3'
rs db3
m db2 "SHOW REPLICAS;"
note "寫入中斷時間（app 寫入失敗的區間）"
x app 'grep -n ERR /tmp/writer.log | head -3; echo ...; grep ERR /tmp/writer.log | tail -2; echo "ERR 筆數: $(grep -c ERR /tmp/writer.log)"; grep -m1 "OK db2" /tmp/writer.log'
x app 'F=$(grep -m1 ERR /tmp/writer.log | cut -d" " -f1); L=$(grep -m1 "OK db2" /tmp/writer.log | cut -d" " -f1); echo "first ERR=$F  first OK on db2=$L"; python3 -c "import sys;from datetime import datetime as d;f=\"%H:%M:%S.%f\";print(\"寫入中斷秒數:\",(d.strptime(sys.argv[2],f)-d.strptime(sys.argv[1],f)).total_seconds())" $F $L 2>/dev/null || true'
sync_cmp db2 db3

note "步驟 6：舊主庫 db1（5.7）改當新主庫 db2（8.0）的從庫"
x db1 "printf 'super_read_only = ON\\n' >> /etc/my.cnf.d/server-id.cnf; cat /etc/my.cnf.d/server-id.cnf"
m db1 "CHANGE MASTER TO MASTER_HOST='db2', MASTER_USER='repl', MASTER_PASSWORD='ChangeMe_Repl_2026', MASTER_AUTO_POSITION=1; START SLAVE;"
x db1 'sleep 5'
rs db1
m db1 "SELECT COUNT(*) FROM appdb.t_orders;"
m db2 "SELECT COUNT(*) FROM appdb.t_orders;"
x db1 'grep -E "\[ERROR\]" /var/log/mysqld.log | tail -5'
note "步驟 6b：在 db2 做一次 DDL，看 5.7 從庫的反應"
m db2 "CREATE TABLE appdb.t_after_switch (id INT PRIMARY KEY, v VARCHAR(20)); INSERT INTO appdb.t_after_switch VALUES (1, 'from-8.0'); SHOW CREATE TABLE appdb.t_after_switch\\G"
x db1 'sleep 3'
rs db1
rs db3
x db1 'grep -E "\[ERROR\]" /var/log/mysqld.log | tail -5'
} 2>&1 | tee results/30-switchover.log
