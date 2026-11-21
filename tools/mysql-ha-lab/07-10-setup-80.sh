#!/usr/bin/env bash
# Lab 07 起點：Percona Server 8.0.46 一主二從（GTID + 半同步 + WRITESET），app 持續寫入 db1
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps80
fresh db1 db2 db3 app
{
note "環境"
x db1 'cat /etc/rocky-release; uname -m; rpm -qa | grep -i percona | sort; mysqld --version'

note "步驟 0-1：三台放設定檔、啟動、改 root 密碼"
id=0
for n in db1 db2 db3; do id=$((id+1)); init_node $n $id 00-server.cnf lab07/replication-80.cnf; done
m db1 "SELECT @@hostname, @@version, @@default_authentication_plugin, @@binlog_transaction_dependency_tracking, @@rpl_semi_sync_source_enabled, @@replica_parallel_workers\\G"
m db1 "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"

note "步驟 0-2：主庫 db1 建帳號與測試資料"
m db1 "CREATE USER 'repl'@'192.168.58.%' IDENTIFIED BY '$RPW'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.58.%';
CREATE USER 'app'@'192.168.58.%' IDENTIFIED BY 'ChangeMe_App_2026'; GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'app'@'192.168.58.%';
CREATE USER 'monitor'@'192.168.58.%' IDENTIFIED WITH caching_sha2_password BY 'ChangeMe_Mon_2026'; GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'monitor'@'192.168.58.%';"
m db1 "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"
m db1 "CREATE DATABASE appdb;
CREATE TABLE appdb.t_orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(100), src VARCHAR(20), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
SET SESSION cte_max_recursion_depth = 10000;
INSERT INTO appdb.t_orders (note, src) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 5000) SELECT CONCAT('init-', n), 'seed' FROM s;
SELECT COUNT(*) FROM appdb.t_orders;"

note "步驟 0-3：db2、db3 接上 db1（GTID 自動定位）"
for n in db2 db3; do
  m $n "RESET MASTER;   -- 清掉初始化改 root 密碼時產生的本機 GTID，避免變成 errant transaction
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1; START REPLICA; SET PERSIST super_read_only = ON;"
done
x db1 'sleep 3'
for n in db2 db3; do rs $n; done
m db1 "SHOW REPLICAS; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';"
sync_cmp db1 db2 db3

note "步驟 0-4：app 開始持續寫入 db1"
writer_start db1
} 2>&1 | tee results/07-10-setup-80.log
