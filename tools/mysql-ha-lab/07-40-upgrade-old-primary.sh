#!/usr/bin/env bash
# Lab 07：舊主庫 db1 先升級到 8.4 再接回 db2；最後把帳號換成 caching_sha2_password、關掉 mysql_native_password
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps80
{
note "步驟 1：db1 升級（不複製、super_read_only），設定檔先加 super_read_only 避免重啟後被誤寫"
x db1 "printf 'super_read_only = ON\n' >> /etc/my.cnf.d/server-id.cnf; cat /etc/my.cnf.d/server-id.cnf"
x db1 'percona-release setup -y ps-84-lts 2>&1 | tail -1'
m db1 "SET GLOBAL innodb_fast_shutdown = 0;"
x db1 'time systemctl stop mysqld; cp -a /var/lib/mysql /var/lib/mysql-8.0-backup && cp -a /etc/my.cnf.d /root/my.cnf.d-8.0 && du -sh /var/lib/mysql-8.0-backup'
x db1 "dnf upgrade -y 'percona-server-*' percona-mysql-router percona-icu-data-files percona-mysql-shell 2>&1 | grep -E '^ percona|Complete|Error'; mysqld --version"
x db1 'cp /root/conf/lab07/replication-84.cnf /etc/my.cnf.d/replication.cnf; mysqld --validate-config --user=mysql; echo "exit=$?"'
x db1 'time systemctl start mysqld; grep -E "Server upgrade|\[ERROR\]" /var/log/mysqld.log | tail -3'

note "步驟 2：db1 接回新主庫 db2"
m db1 "CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1; START REPLICA;"
x db1 'sleep 3'
rs db1
m db2 "SHOW REPLICAS; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';"
sync_cmp db2 db1 db3

note "步驟 3：帳號改成 caching_sha2_password（在主庫 db2 執行，會複製到 db1、db3）"
m db2 "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"
m db2 "ALTER USER 'app'@'192.168.58.%' IDENTIFIED WITH caching_sha2_password BY 'ChangeMe_App_2026';
ALTER USER 'repl'@'192.168.58.%' IDENTIFIED WITH caching_sha2_password BY '$RPW';
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$PW';"
m db2 "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"
x app 'sleep 2; tail -2 /tmp/writer.log; mysql -hdb2 -uapp -pChangeMe_App_2026 -e "SHOW SESSION STATUS LIKE \"Ssl_version\"" 2>&1 | grep -v Warning'

note "步驟 4：坑：repl 改成 caching_sha2_password 後，從庫重連（快取清掉時）認證失敗"
m db2 "FLUSH PRIVILEGES;   -- 清掉 caching_sha2_password 的認證快取，模擬主庫重啟"
m db3 "STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;"
x db3 'sleep 3'
rs db3
note "解法：複製連線加 GET_SOURCE_PUBLIC_KEY = 1（或 SOURCE_SSL = 1）"
for n in db1 db3; do
  m $n "STOP REPLICA; CHANGE REPLICATION SOURCE TO GET_SOURCE_PUBLIC_KEY = 1; START REPLICA;"
done
x db3 'sleep 3'
rs db3
rs db1

note "步驟 5：拿掉 mysql_native_password = ON，從庫逐台重啟驗證"
for n in db1 db3; do
  x $n "sed -i '/^mysql_native_password/d' /etc/my.cnf.d/replication.cnf; systemctl restart mysqld; mysql -e \"SELECT @@hostname, @@version\"; mysql -e \"SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'mysql_native_password'\""
done
x db2 "sed -i '/^mysql_native_password/d' /etc/my.cnf.d/replication.cnf; grep -c \"^mysql_native_password\" /etc/my.cnf.d/replication.cnf   # 主庫下次維護重啟時生效"
x db1 'sleep 3'
rs db1
rs db3

note "最終驗證"
for n in db1 db2 db3; do m $n "SELECT @@hostname, @@version, @@read_only, @@super_read_only;"; done
x app 'touch /tmp/writer.stop; sleep 1; echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; grep " ERR " /tmp/writer.log | cut -d" " -f3- | sort | uniq -c'
m db2 "SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;"
cmp_data db2 db1 db3
} 2>&1 | tee results/07-40-upgrade-old-primary.log
