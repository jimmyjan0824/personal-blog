#!/usr/bin/env bash
# Lab 08：8.4 LTS → 9.7 LTS 滾動升級（先升從庫 → 切換 → 升舊主庫），並觀察日曆版號與 mysql_native_password 移除的影響
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps84
upgrade_node() {
  local n=$1 first=$2
  note "[$n] 切換到 ps-97-lts 套件庫"
  if [ "$first" = yes ]; then
    note "[$n] 坑：percona-release 1.0-34 的 setup 不認得 ps-97-lts（停用全部套件庫後什麼都沒啟用）"
    x $n 'rpm -q percona-release; percona-release setup -y ps-97-lts 2>&1 | tail -2; ls /etc/yum.repos.d/ | grep percona; dnf -q --showduplicates list percona-server-server 2>&1 | tail -2'
  fi
  x $n 'percona-release disable ps-84-lts release >/dev/null 2>&1; percona-release enable ps-97-lts release 2>&1 | tail -2; ls /etc/yum.repos.d/ | grep percona; dnf -q --showduplicates list percona-server-server percona-mysql-shell 2>&1 | grep -v "^Installed\|^Available" | tail -6'
  if [ "$first" = yes ]; then
    note "[$n] 升級檢查（MySQL Shell 9.7）"
    x $n 'dnf upgrade -y percona-mysql-shell 2>&1 | grep -E "^ percona|Complete|Error"; mysqlsh --version'
    x $n "mysqlsh --no-wizard -uroot --password='$PW' --socket=/var/lib/mysql/mysql.sock -- util check-for-server-upgrade --target-version=9.7 --config-path=/etc/my.cnf 2>&1 | grep -v 'Using a password'"
  fi
  note "[$n] 停複製、完整關機、備份"
  x $n 'mysql -N -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables" > /root/vars-84.txt; wc -l < /root/vars-84.txt' 
  m $n "STOP REPLICA; SET GLOBAL innodb_fast_shutdown = 0;"
  x $n 'time systemctl stop mysqld; cp -a /var/lib/mysql /var/lib/mysql-8.4-backup && cp -a /etc/my.cnf.d /root/my.cnf.d-8.4 && du -sh /var/lib/mysql-8.4-backup'
  note "[$n] 升級套件"
  x $n "dnf upgrade -y 'percona-server-*' percona-mysql-router percona-icu-data-files percona-mysql-shell 2>&1 | grep -E '^ percona|Complete|Error'; rpm -qa | grep -iE 'percona-(server|mysql|icu|xtrabackup)' | sort; mysqld --version"
  if [ "$first" = yes ]; then
    note "[$n] 8.4 的設定直接給 9.7"
    x $n 'mysqld --validate-config --user=mysql; echo "exit=$?"'
  fi
  x $n 'cp /root/conf/lab08/replication-97.cnf /etc/my.cnf.d/replication.cnf; mysqld --validate-config --user=mysql; echo "exit=$?"'
  note "[$n] 啟動 9.7"
  x $n 'time systemctl start mysqld; systemctl is-active mysqld; grep -E "Data dictionary upgrad|Server upgrade|ready for connections|\[ERROR\]" /var/log/mysqld.log | tail -5'
  mg $n "SELECT @@hostname, @@version, @@version_comment, @@super_read_only"
  x $n 'sleep 3'
  rs $n
  if [ "$first" = yes ]; then
    m $n "SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;"
    m $n "SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE '%native%' OR PLUGIN_NAME LIKE 'rpl_semi%';"
    x app "mysql -h$n -ulegacy_report -pChangeMe_Legacy_2026 -e 'SELECT COUNT(*) FROM appdb.t_orders' 2>&1 | grep -v Warning"
    note "[$n] 解法：在 8.4 主庫把帳號換成 caching_sha2_password（複製到 9.7 從庫）"
    m db1 "ALTER USER 'legacy_report'@'192.168.58.%' IDENTIFIED WITH caching_sha2_password BY 'ChangeMe_Legacy_2026';"
    x app "sleep 1; mysql -h$n -ulegacy_report -pChangeMe_Legacy_2026 -e 'SELECT COUNT(*) AS legacy_can_read FROM appdb.t_orders' 2>&1 | grep -v Warning"
    note "[$n] 坑：9.x 的 mysql 用戶端在非互動模式預設不處理 \\G 等用戶端指令"
    x $n 'mysql --version; mysql -e "SELECT @@version\\G"; echo "exit=$?"; echo "SELECT @@version\\G" | mysql; echo "exit=$?"'
    x $n 'mysql --commands -e "SELECT @@version\\G"; mysql --vertical -e "SELECT @@version"'
    note "[$n] 預設值改變的變數（同一台 8.4 → 9.7）"
    x $n 'mysql -N -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables" > /root/vars-97.txt; join -t$'"'"'\t'"'"' <(sort /root/vars-84.txt) <(sort /root/vars-97.txt) | awk -F"\t" "\$2!=\$3" | grep -vE "^(version|version_comment|innodb_version|server_uuid|gtid_|pseudo|timestamp|warning_count|hostname|report_host)|_path$|^ssl_|^tls_|admin_ssl|^character_sets_dir|^lc_messages_dir|^basedir|^plugin_dir" | column -t -s$'"'"'\t'"'"' | sed "1i VARIABLE  8.4.11  9.7.2"'
  fi
  [ -n "${SRC}" ] && sync_cmp ${SRC} $n
}
{
note "版本號：LTS 與 Innovation、日曆版號"
x db1 'for r in ps-84-lts ps-97-lts ps-8x-innovation; do echo "== $r"; dnf -q --disablerepo="*" --repofrompath=t,https://repo.percona.com/$r/yum/release/9/RPMS/x86_64/ --showduplicates list percona-server-server 2>/dev/null | awk "NR>1{print \$2}" | tail -3; done'
m db1 "SELECT @@version, @@version_comment;"
writer_stat

SRC=db1 upgrade_node db2 yes
note "混合版本：db1 8.4 → db2 9.7、db3 8.4"
SRC=db1 upgrade_node db3 no
writer_stat

note "切換：db1（8.4）→ db2（9.7）"
m db1 "SET GLOBAL super_read_only = ON;"
G=$(q db1 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')
for n in db2 db3; do m $n "SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 30) AS waited;"; done
m db2 "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;"
x app 'echo db2 > /tmp/target; sleep 2; tail -1 /tmp/writer.log'
m db3 "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2'; START REPLICA;"
x db3 'sleep 3'
rs db3
x app 'F=$(grep -m1 " ERR " /tmp/writer.log | cut -d" " -f1); L=$(grep -m1 "OK db2" /tmp/writer.log | cut -d" " -f1); echo "ERR 筆數: $(grep -c " ERR " /tmp/writer.log)  first ERR=$F  first OK on db2=$L"; python3 -c "import sys;from datetime import datetime as d;f=\"%H:%M:%S.%f\";print(\"寫入中斷秒數:\",(d.strptime(sys.argv[2],f)-d.strptime(sys.argv[1],f)).total_seconds())" $F $L'

note "舊主庫 db1 升級到 9.7 再接回"
x db1 "printf 'super_read_only = ON\n' >> /etc/my.cnf.d/server-id.cnf"
SRC= upgrade_node db1 no
m db1 "CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='$RPW', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
x db1 'sleep 3'
rs db1
m db2 "SHOW REPLICAS; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';"

note "最終驗證"
x app 'touch /tmp/writer.stop; sleep 1; echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; grep " ERR " /tmp/writer.log | cut -d" " -f3- | sort | uniq -c'
m db2 "SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;"
sync_cmp db2 db1 db3
} 2>&1 | tee results/08-20-upgrade-97.log
