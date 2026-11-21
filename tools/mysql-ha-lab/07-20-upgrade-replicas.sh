#!/usr/bin/env bash
# Lab 07：從庫 db2、db3 依序就地升級到 Percona Server 8.4.11（主庫 db1 維持 8.0，app 持續寫入 db1）
source "$(dirname "$0")/lib.sh"
export LAB_IMAGE=mysqllab-ps80
TV=8.4.11-12.1.el9
upgrade_node() {
  local n=$1 first=$2
  note "[$n] 1. 確認目前狀態"
  x $n 'rpm -qa | grep -iE "percona-(server|mysql)" | sort; mysqld --version'
  rs $n

  note "[$n] 2. 切換到 ps-84-lts 套件庫"
  x $n 'percona-release setup -y ps-84-lts 2>&1 | tail -2; dnf -q --showduplicates list percona-server-server | tail -3'
  if [ "$first" = yes ]; then
    note "[$n] 3. 升級檢查：先只升級 MySQL Shell 到 8.4，帶 --config-path 一併檢查設定檔"
    x $n 'dnf upgrade -y percona-mysql-shell 2>&1 | grep -E "^ percona|Complete|Error"; mysqlsh --version'
    x $n "mysqlsh --no-wizard -uroot --password='$PW' --socket=/var/lib/mysql/mysql.sock -- util check-for-server-upgrade --target-version=8.4.11 --config-path=/etc/my.cnf 2>&1 | grep -v 'Using a password' | sed -n '1,8p'"
    x $n "mysqlsh --no-wizard -uroot --password='$PW' --socket=/var/lib/mysql/mysql.sock -- util check-for-server-upgrade --target-version=8.4 --config-path=/etc/my.cnf 2>&1 | grep -v 'Using a password'"
  fi

  note "[$n] 4. 記錄升級前的變數值，停複製、完整關機、備份"
  x $n 'mysql -N -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables" > /root/vars-80.txt; wc -l < /root/vars-80.txt'
  m $n "STOP REPLICA; SET GLOBAL innodb_fast_shutdown = 0;"
  x $n 'time systemctl stop mysqld; cp -a /var/lib/mysql /var/lib/mysql-8.0-backup && cp -a /etc/my.cnf.d /root/my.cnf.d-8.0 && du -sh /var/lib/mysql-8.0-backup'

  note "[$n] 5. 升級套件（同名套件，dnf upgrade 即可；資料目錄與 /etc/my.cnf 都保留）"
  x $n "dnf upgrade -y 'percona-server-*' percona-mysql-router percona-icu-data-files 2>&1 | grep -E '^ percona|Complete|Error'; rpm -qa | grep -iE 'percona-(server|mysql|icu)' | sort; mysqld --version"
  x $n 'tail -1 /etc/my.cnf; systemctl is-enabled mysqld'

  if [ "$first" = yes ]; then
    note "[$n] 6. 8.0 的設定直接給 8.4：--validate-config"
    x $n 'mysqld --validate-config --user=mysql; echo "exit=$?"'
    x $n "sed -i '/binlog_transaction_dependency_tracking/d' /etc/my.cnf.d/replication.cnf; mysqld --validate-config --user=mysql; echo \"exit=\$?\""
    note "[$n] 7. 坑：拿掉 default_authentication_plugin 就啟動 → mysql_native_password 帳號全部登不進去"
    x $n "sed -i '/default_authentication_plugin/d' /etc/my.cnf.d/replication.cnf; mysqld --validate-config --user=mysql; echo \"exit=\$?\""
    x $n 'time systemctl start mysqld; systemctl is-active mysqld'
    x $n 'mysql -e "SELECT @@version"; echo "exit=$?"'
    x $n 'grep -iE "native|\[ERROR\]" /var/log/mysqld.log | tail -3'
    x $n 'systemctl stop mysqld'
  fi
  note "[$n] 8. 換成 8.4 版設定檔，驗證後啟動（第一次啟動自動升級資料字典與系統表）"
  x $n 'cp /root/conf/lab07/replication-84.cnf /etc/my.cnf.d/replication.cnf; diff /root/my.cnf.d-8.0/replication.cnf /etc/my.cnf.d/replication.cnf; mysqld --validate-config --user=mysql; echo "exit=$?"'
  x $n 'time systemctl start mysqld; systemctl is-active mysqld'
  x $n 'grep -E "upgrad|ready for connections|\[ERROR\]" /var/log/mysqld.log | tail -6'
  m $n "SELECT @@hostname, @@version, @@super_read_only, @@authentication_policy, @@replica_parallel_workers\\G"
  m $n "SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME IN ('mysql_native_password','rpl_semi_sync_source','rpl_semi_sync_replica');"
  x $n 'sleep 3'
  rs $n
  if [ "$first" = yes ]; then
    note "[$n] 9. 8.4 移除的舊語法（監控腳本要先改）"
    m $n "SHOW SLAVE STATUS;"
    m $n "SHOW MASTER STATUS;"
    m $n "SHOW BINARY LOG STATUS;"
    note "[$n] 10. 預設值改變的變數（同一台 8.0 → 8.4，設定檔沒寫的部分）"
    x $n 'mysql -N -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables" > /root/vars-84.txt; join -t$'"'"'\t'"'"' <(sort /root/vars-80.txt) <(sort /root/vars-84.txt) | awk -F"\t" "\$2!=\$3" | grep -E "^innodb_(adaptive_hash_index|change_buffering|buffer_pool_instances|log_buffer_size|io_capacity|io_capacity_max|purge_threads|read_io_threads|page_cleaners|doublewrite_files|doublewrite_pages|log_writer_threads|numa_interleave|parallel_read_threads)\b|^group_replication_(consistency|exit_state_action)" | column -t -s$'"'"'\t'"'"' | sed "1i VARIABLE  8.0.46  8.4.11"'
  fi
  sync_cmp db1 $n
}
{
note "升級前"
m db1 "SELECT @@version;"
writer_stat
upgrade_node db2 yes
note "db2 升級完成，混合版本：db1 8.0 → db2 8.4、db3 8.0"
m db1 "SHOW REPLICAS; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_clients';"
upgrade_node db3 no
note "兩台從庫都是 8.4，主庫 db1 仍是 8.0"
sync_cmp db1 db2 db3
writer_stat
} 2>&1 | tee results/07-20-upgrade-replicas.log
