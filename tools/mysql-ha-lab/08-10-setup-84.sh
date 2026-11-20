#!/usr/bin/env bash
# Lab 08 起點：Percona Server 8.4.11 一主二從（Lab 07 升級後的狀態），另有一個還在用 mysql_native_password 的舊帳號
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
fresh db1 db2 db3 app
{
note "環境"
x db1 'cat /etc/rocky-release; rpm -qa | grep -iE "percona-(server|mysql|xtrabackup)" | sort; mysqld --version'
note "三台初始化"
id=0
for n in db1 db2 db3; do id=$((id+1)); init_node $n $id 00-server.cnf lab08/replication-84.cnf; done
m db1 "CREATE USER 'repl'@'192.168.58.%' IDENTIFIED BY '$RPW'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.58.%';
CREATE USER 'app'@'192.168.58.%' IDENTIFIED BY 'ChangeMe_App_2026'; GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'app'@'192.168.58.%';
CREATE USER 'legacy_report'@'192.168.58.%' IDENTIFIED WITH mysql_native_password BY 'ChangeMe_Legacy_2026'; GRANT SELECT ON appdb.* TO 'legacy_report'@'192.168.58.%';"
m db1 "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"
m db1 "CREATE DATABASE appdb;
CREATE TABLE appdb.t_orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(100), src VARCHAR(20), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
SET SESSION cte_max_recursion_depth = 10000;
INSERT INTO appdb.t_orders (note, src) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 5000) SELECT CONCAT('init-', n), 'seed' FROM s;"
for n in db2 db3; do
  m $n "RESET BINARY LOGS AND GTIDS;   -- 8.4 起 RESET MASTER 改名
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA; SET PERSIST super_read_only = ON;"
done
x db1 'sleep 3'
for n in db2 db3; do rs $n; done
sync_cmp db1 db2 db3
x app "mysql -hdb1 -ulegacy_report -pChangeMe_Legacy_2026 -e 'SELECT COUNT(*) AS legacy_can_read FROM appdb.t_orders' 2>&1 | grep -v Warning"
writer_start db1
} 2>&1 | tee results/08-10-setup-84.log
