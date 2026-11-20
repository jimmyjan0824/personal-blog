#!/usr/bin/env bash
# Lab 12：Percona XtraBackup 8.4 全量 + 兩次增量備份，在另一台還原後用 binlog 做時間點復原（PITR），跳過誤刪的那一筆
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
fresh db1 db2 app
BPW='ChangeMe_Bkp_2026'
XB="xtrabackup --user=bkp --password=$BPW"
{
note "步驟 0：環境與版本"
id=0
for n in db1 db2; do id=$((id+1)); init_node $n $id 00-server.cnf lab09/replication.cnf >/dev/null; done
x db1 'mysqld --version; xtrabackup --version 2>&1 | tail -1; rpm -q percona-xtrabackup-84'
seed_app db1
writer_start db1

note "步驟 1：備份帳號（最小權限）"
m db1 "CREATE USER 'bkp'@'localhost' IDENTIFIED BY '$BPW';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.replication_group_members TO 'bkp'@'localhost';"

note "步驟 2：全量備份（線上、不鎖表，app 持續寫入）"
x db1 "mkdir -p /backup; time $XB --backup --target-dir=/backup/full 2>&1 | grep -E 'version|Using server version|tested|Warning|WARNING|Error|ERROR|binlog position|completed OK' | grep -v 'Using a password'"
x db1 'ls /backup/full; cat /backup/full/xtrabackup_binlog_info; grep -E "backup_type|from_lsn|to_lsn|last_lsn" /backup/full/xtrabackup_checkpoints; du -sh /backup/full'
writer_stat

note "步驟 3：增量備份 1、2（只備份變更過的頁面）"
x db1 'sleep 10'
x db1 "time $XB --backup --target-dir=/backup/inc1 --incremental-basedir=/backup/full 2>&1 | grep -E 'completed OK|binlog position|ERROR'"
x db1 'sleep 10'
x db1 "time $XB --backup --target-dir=/backup/inc2 --incremental-basedir=/backup/inc1 2>&1 | grep -E 'completed OK|binlog position|ERROR'"
x db1 'for d in full inc1 inc2; do echo "== $d: $(du -sh /backup/$d | cut -f1)"; grep -E "backup_type|from_lsn|to_lsn" /backup/$d/xtrabackup_checkpoints; done; cat /backup/inc2/xtrabackup_binlog_info'

note "步驟 4：事故：增量備份之後又寫了一段時間，有人誤刪了 appdb.t_orders"
x db1 'sleep 8'
docker compose exec -T app touch /tmp/writer.pause; sleep 1
m db1 "SELECT COUNT(*) AS rows_before_drop, MAX(id) FROM appdb.t_orders; SELECT @@GLOBAL.gtid_executed AS gtid_before_drop;"
BEFORE=$(q db1 "SELECT COUNT(*) FROM appdb.t_orders")
m db1 "DROP TABLE appdb.t_orders;"
m db1 "CREATE TABLE appdb.t_audit (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(50)); INSERT INTO appdb.t_audit (msg) VALUES ('after-drop-1'), ('after-drop-2');   -- 誤刪之後的正常交易，復原時要保留"
docker compose exec -T app rm -f /tmp/writer.pause
x app 'sleep 2; touch /tmp/writer.stop; tail -2 /tmp/writer.log; echo "OK=$(grep -c " OK " /tmp/writer.log)"'
x db1 "mysqlbinlog --no-defaults \$(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -B12 'DROP TABLE' | grep -E 'GTID_NEXT|DROP TABLE'"
DG=$(docker compose exec -T db1 bash -c "mysqlbinlog --no-defaults \$(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -B12 'DROP TABLE' | grep -oE \"GTID_NEXT= '[^']+'\" | tail -1 | cut -d\"'\" -f2" | tr -d '\r')
x db1 "echo 'DROP TABLE 的 GTID: $DG'"

note "步驟 5：把備份與 binlog 複製到還原用的 db2"
x db1 'mysql -e "FLUSH BINARY LOGS"; ls -l /var/lib/mysql/mysql-bin.0*'
echo "# 主機端：db1:/backup 與 binlog → db2:/backup（實務上用 rsync / scp，或從備份儲存取回）"
docker compose exec -T db1 bash -c 'mkdir -p /backup/binlog && cp /var/lib/mysql/mysql-bin.0* /backup/binlog/ && tar -C /backup -cf - .' | docker compose exec -T db2 bash -c 'mkdir -p /backup && tar -C /backup -xf -'
x db2 'ls /backup /backup/binlog; du -sh /backup/*'

note "步驟 6：prepare：全量 → 套用增量 1 → 套用增量 2（最後一次才做 rollback）"
x db2 "time xtrabackup --prepare --apply-log-only --target-dir=/backup/full 2>&1 | grep -E 'completed OK|ERROR|Starting'"
x db2 "time xtrabackup --prepare --apply-log-only --target-dir=/backup/full --incremental-dir=/backup/inc1 2>&1 | grep -E 'completed OK|ERROR'"
x db2 "time xtrabackup --prepare --target-dir=/backup/full --incremental-dir=/backup/inc2 2>&1 | grep -E 'completed OK|ERROR'"
x db2 'grep -E "backup_type|to_lsn|last_lsn" /backup/full/xtrabackup_checkpoints; cat /backup/full/xtrabackup_binlog_info'

note "步驟 7：還原到 db2：停機、清空資料目錄、copy-back、修正擁有者、啟動"
x db2 'systemctl stop mysqld; rm -rf /var/lib/mysql/*; time xtrabackup --copy-back --target-dir=/backup/full 2>&1 | grep -E "completed OK|ERROR"; chown -R mysql:mysql /var/lib/mysql; systemctl start mysqld; systemctl is-active mysqld'
x db2 'mysql -uroot -p"ChangeMe_Root_2026" -e "SELECT @@hostname, @@server_uuid, @@GLOBAL.gtid_executed\G" 2>&1 | grep -v Warning'
m db2 "SELECT COUNT(*) AS rows_in_backup, MAX(id) FROM appdb.t_orders;"

note "步驟 8：PITR：從備份的 binlog 位置開始重放，排除 DROP 那一筆"
x db2 'cat /backup/full/xtrabackup_binlog_info'
BF=$(docker compose exec -T db2 awk '{print $1}' /backup/full/xtrabackup_binlog_info | tr -d '\r'); BP=$(docker compose exec -T db2 awk '{print $2}' /backup/full/xtrabackup_binlog_info | tr -d '\r')
x db2 "cd /backup/binlog; FILES=\$(ls mysql-bin.0* | awk -v f=$BF '\$0>=f'); echo \"要重放的 binlog: \$FILES\"; mysqlbinlog --no-defaults --start-position=$BP --exclude-gtids='$DG' \$FILES | mysql; echo exit=\$?"
m db2 "SELECT COUNT(*) AS rows_after_pitr, MAX(id) FROM appdb.t_orders; SELECT * FROM appdb.t_audit;"
x db2 "echo '誤刪前 db1 的筆數: $BEFORE'"
m db2 "SELECT @@GLOBAL.gtid_executed\\G"
note "比對：db2（PITR 後）和誤刪前的 db1 是否一致"
m db2 "SELECT COUNT(*) AS rows_cnt, SUM(CRC32(CONCAT_WS('#', id, note, src))) AS crc FROM appdb.t_orders;"
x app "grep -c ' OK ' /tmp/writer.log | sed 's/^/app 回報成功的寫入: /'"
m db2 "SELECT COUNT(*) AS writer_rows FROM appdb.t_orders WHERE note LIKE 'w-%';"
} 2>&1 | tee results/12-xtrabackup-pitr.log
