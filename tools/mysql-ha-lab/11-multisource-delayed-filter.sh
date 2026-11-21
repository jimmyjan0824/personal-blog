#!/usr/bin/env bash
# Lab 11：多來源複製（db1 + db2 → db3）、通道過濾、延遲從庫（db1 → db4，SOURCE_DELAY）救回誤刪的表
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
fresh db1 db2 db3 db4
{
note "步驟 1：四台初始化（GTID、ROW）"
id=0
for n in db1 db2 db3 db4; do id=$((id+1)); init_node $n $id 00-server.cnf lab09/replication.cnf >/dev/null; done
for n in db1 db2; do
  m $n "CREATE USER 'repl'@'192.168.58.%' IDENTIFIED BY '$RPW'; GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.58.%';"
done
m db1 "CREATE DATABASE sales; CREATE TABLE sales.orders (id INT AUTO_INCREMENT PRIMARY KEY, customer VARCHAR(30), amount DECIMAL(10,2), created_at DATETIME DEFAULT NOW());
INSERT INTO sales.orders (customer, amount) VALUES ('alice', 120.00), ('bob', 75.50), ('carol', 300.00);"
m db2 "CREATE DATABASE inventory; CREATE TABLE inventory.stock (sku VARCHAR(20) PRIMARY KEY, qty INT);
INSERT INTO inventory.stock VALUES ('A-001', 50), ('B-002', 8), ('C-003', 0);
CREATE DATABASE tmp_report; CREATE TABLE tmp_report.daily (d DATE PRIMARY KEY, total INT); INSERT INTO tmp_report.daily VALUES (CURDATE(), 58);"
m db1 "SELECT @@server_uuid, @@GLOBAL.gtid_executed;"
m db2 "SELECT @@server_uuid, @@GLOBAL.gtid_executed;"

note "步驟 2：db3 多來源複製：兩個通道 ch_sales（db1）、ch_inv（db2）"
m db3 "RESET BINARY LOGS AND GTIDS;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1 FOR CHANNEL 'ch_sales';
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1 FOR CHANNEL 'ch_inv';
CHANGE REPLICATION FILTER REPLICATE_IGNORE_DB = (tmp_report) FOR CHANNEL 'ch_inv';
START REPLICA FOR CHANNEL 'ch_sales'; START REPLICA FOR CHANNEL 'ch_inv';
SET PERSIST super_read_only = ON;"
x db3 'sleep 3'
m db3 "SELECT CHANNEL_NAME, HOST, SERVICE_STATE FROM performance_schema.replication_connection_status JOIN performance_schema.replication_connection_configuration USING (CHANNEL_NAME);"
m db3 "SELECT * FROM performance_schema.replication_applier_filters;"
rs db3 ch_sales
rs db3 ch_inv
m db3 "SELECT CHANNEL_NAME, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE FROM performance_schema.replication_applier_status_by_worker WHERE LAST_ERROR_NUMBER <> 0;"
note "坑 1：db1、db2 各自建了同一個 repl 帳號，ch_inv 套到 db2 的 CREATE USER 時撞到 ch_sales 已經建好的帳號"
EG=$(q db3 "SELECT LAST_ERROR_MESSAGE FROM performance_schema.replication_applier_status_by_worker WHERE CHANNEL_NAME='ch_inv' AND LAST_ERROR_NUMBER=1396 LIMIT 1" | grep -oE "transaction '[^']+'" | cut -d"'" -f2)
x db3 "echo '出錯的交易: $EG'"
m db3 "STOP REPLICA FOR CHANNEL 'ch_inv';
SET GLOBAL super_read_only = OFF;
SET GTID_NEXT = '$EG'; BEGIN; COMMIT; SET GTID_NEXT = 'AUTOMATIC';   -- 帳號 db3 已經有了，用空交易跳過
SET GLOBAL super_read_only = ON;
START REPLICA FOR CHANNEL 'ch_inv';"
x db3 'sleep 2'
rs db3 ch_inv
m db3 "SELECT CHANNEL_NAME, LAST_ERROR_NUMBER, LAST_ERROR_MESSAGE FROM performance_schema.replication_applier_status_by_worker WHERE LAST_ERROR_NUMBER <> 0;"
note "坑 2：REPLICATE_IGNORE_DB 對 DDL（statement 格式）看的是「預設資料庫」，CREATE TABLE tmp_report.daily 沒被擋"
x db2 "mysqlbinlog --no-defaults \$(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -E '^(use|CREATE|INSERT)|GTID_NEXT=' | grep -B1 -E 'tmp_report' | head -8"
note "解法：改用 REPLICATE_WILD_IGNORE_TABLE（依實際的庫名.表名判斷），那筆交易就會被過濾，不需要跳過"
m db3 "STOP REPLICA FOR CHANNEL 'ch_inv';
CHANGE REPLICATION FILTER REPLICATE_IGNORE_DB = (), REPLICATE_WILD_IGNORE_TABLE = ('tmp_report.%') FOR CHANNEL 'ch_inv';
START REPLICA FOR CHANNEL 'ch_inv';"
x db3 'sleep 2'
m db3 "SELECT * FROM performance_schema.replication_applier_filters;"
rs db3 ch_inv
m db3 "SHOW DATABASES; SELECT @@GLOBAL.gtid_executed\\G"
m db3 "SELECT 'sales.orders' AS t, COUNT(*) FROM sales.orders UNION ALL SELECT 'inventory.stock', COUNT(*) FROM inventory.stock;"
x db3 "printf '[mysqld]\\nreplicate-wild-ignore-table = ch_inv:tmp_report.%%\\n' > /etc/my.cnf.d/filters.cnf; cat /etc/my.cnf.d/filters.cnf   # 寫進設定檔，重啟後仍有效"

note "步驟 3：兩邊同時寫入，db3 都收到；tmp_report 不管從哪個預設資料庫改都被擋掉"
m db1 "INSERT INTO sales.orders (customer, amount) VALUES ('dave', 42.00);"
m db2 "UPDATE inventory.stock SET qty = qty - 1 WHERE sku = 'A-001'; INSERT INTO tmp_report.daily VALUES (CURDATE() - INTERVAL 1 DAY, 61);
USE inventory; CREATE TABLE tmp_report.weekly (w INT PRIMARY KEY); INSERT INTO inventory.stock VALUES ('D-004', 12);"
x db3 'sleep 2'
m db3 "SELECT * FROM sales.orders ORDER BY id DESC LIMIT 2; SELECT * FROM inventory.stock ORDER BY sku;"
m db3 "SHOW DATABASES LIKE 'tmp%'; SELECT FILTER_NAME, FILTER_RULE, COUNTER FROM performance_schema.replication_applier_filters WHERE FILTER_RULE <> '';"
rs db3 ch_inv

note "步驟 4：db4 延遲從庫：落後 db1 60 秒"
m db4 "RESET BINARY LOGS AND GTIDS;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_DELAY=60;
START REPLICA; SET PERSIST super_read_only = ON;"
x db4 'sleep 65'
m db4 "SELECT COUNT(*) FROM sales.orders;"
m db1 "INSERT INTO sales.orders (customer, amount) VALUES ('erin', 18.00), ('frank', 999.00);"
x db4 'sleep 3'
rs db4
m db4 "SELECT COUNT(*) AS db4_rows FROM sales.orders;"
m db1 "SELECT COUNT(*) AS db1_rows FROM sales.orders;"

note "步驟 5：事故：有人在主庫誤刪了 sales.orders"
m db1 "SELECT NOW(); DROP TABLE sales.orders;"
m db3 "SELECT COUNT(*) FROM sales.orders;"
note "步驟 6：在延遲從庫上停住 SQL 執行緒，找出 DROP 的 GTID，套用到它之前為止"
m db4 "STOP REPLICA SQL_THREAD;"
x db1 "mysqlbinlog --no-defaults -v \$(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -B12 'DROP TABLE' | grep -E 'GTID_NEXT|DROP TABLE'"
DG=$(docker compose exec -T db1 bash -c "mysqlbinlog --no-defaults \$(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -B12 'DROP TABLE' | grep -oE \"GTID_NEXT= '[^']+'\" | tail -1 | cut -d\"'\" -f2" | tr -d '\r')
m db4 "START REPLICA SQL_THREAD UNTIL SQL_BEFORE_GTIDS = '$DG';"
x db4 'sleep 3'
rs db4
m db4 "SELECT COUNT(*) AS rows_on_db4, MAX(id) FROM sales.orders;"
note "坑 3：UNTIL 一樣要等 SOURCE_DELAY，GTID :8（erin、frank）還在排隊；先把延遲歸零再套用"
m db4 "STOP REPLICA SQL_THREAD;
CHANGE REPLICATION SOURCE TO SOURCE_DELAY = 0;
START REPLICA SQL_THREAD UNTIL SQL_BEFORE_GTIDS = '$DG';"
x db4 'sleep 3'
rs db4
m db4 "SELECT COUNT(*) AS rows_on_db4, MAX(id) FROM sales.orders; SELECT * FROM sales.orders ORDER BY id;"
note "步驟 7：從延遲從庫匯出這張表，匯回主庫"
x db4 'mysqldump --set-gtid-purged=OFF --single-transaction sales orders > /root/orders.sql; ls -l /root/orders.sql'
echo "# 主機端：把 db4:/root/orders.sql 複製到 db1（實務上用 scp）"
docker compose exec -T db4 cat /root/orders.sql | docker compose exec -T db1 bash -c 'cat > /root/orders.sql'
x db1 'mysql sales < /root/orders.sql; mysql -e "SELECT COUNT(*) AS restored_rows FROM sales.orders; SELECT * FROM sales.orders ORDER BY id"'
x db3 'sleep 2'
m db3 "SELECT COUNT(*) FROM sales.orders;"
note "延遲從庫恢復正常延遲複製"
m db4 "CHANGE REPLICATION SOURCE TO SOURCE_DELAY = 60; START REPLICA SQL_THREAD;"
x db4 'sleep 2'
rs db4
} 2>&1 | tee results/11-multisource-delayed-filter.log
