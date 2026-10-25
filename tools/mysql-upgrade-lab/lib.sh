#!/usr/bin/env bash
# 共用函式：先印出要執行的指令再在容器內執行，輸出就是文章裡的實測輸出
#   x <節點> <shell 指令>   以 root 執行，印成「[節點]# 指令」
#   m <節點> <SQL>          用 mysql 用戶端執行（帳密在 /root/.my.cnf），印成「[節點] mysql> SQL」
#   mg <節點> <SQL>         同上，輸出用 \G 直式
set -u
cd "$(dirname "$0")"
export PATH="$HOME/.docker/bin:$PATH"
mkdir -p results
x() {
  local n=$1; shift
  echo "[$n]# $*"
  docker compose exec -T "$n" bash -c "$*" 2>&1
  echo
}
m() {
  local n=$1 sql=$2
  echo "[$n] mysql> $sql"
  docker compose exec -T "$n" mysql --table -e "$sql" 2>&1
  echo
}
mg() {
  local n=$1 sql=$2
  echo "[$n] mysql> $sql\\G"
  docker compose exec -T "$n" mysql -e "$sql\\G" 2>&1
  echo
}
note() { echo; echo "======== $* ========  ($(date '+%F %T'))"; }
h() { echo "# 主機端：$*"; eval "$@" 2>&1; echo; }
# 複製狀態摘要（5.7 / 8.0 都能用 SHOW SLAVE STATUS）
rs() {
  local n=$1
  echo "[$n] mysql> SHOW SLAVE STATUS\\G   （節錄）"
  docker compose exec -T "$n" mysql -e 'SHOW SLAVE STATUS\G' 2>&1 \
    | grep -E 'Master_Host|Slave_IO_Running|Slave_SQL_Running:|Seconds_Behind|Last_(IO_|SQL_)?Err(no|or)|Retrieved_Gtid|Executed_Gtid|Auto_Position'
  echo
}
# 資料比對：每台的筆數與內容雜湊
#   sync_cmp <主庫> <其他節點...>：先暫停 app 寫入，等其他節點追上主庫的 gtid_executed 再比對，最後恢復寫入
sync_cmp() {
  local src=$1; shift
  docker compose exec -T app touch /tmp/writer.pause; sleep 1
  local g; g=$(docker compose exec -T "$src" mysql -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')
  for n in "$@"; do
    m "$n" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$g', 60) AS waited;   -- 0 = 已追上 $src"
  done
  cmp_data "$src" "$@"
  docker compose exec -T app rm -f /tmp/writer.pause
}
cmp_data() {
  for n in "$@"; do
    m "$n" "SELECT @@hostname AS node, @@version AS version, COUNT(*) AS rows_cnt, SUM(CRC32(CONCAT_WS('#', id, note, src))) AS crc FROM appdb.t_orders;"
  done
}
PW='ChangeMe_Root_2026'
# 就地升級一台節點 5.7 → 8.0（SRC=它的主庫，用來比對資料）；first=yes 時多跑升級檢查並示範兩個坑
upgrade_node() {
  local n=$1 first=$2
  note "[$n] 1. 確認目前狀態"
  x $n 'rpm -qa | grep -i percona | sort; mysqld --version'
  rs $n

  note "[$n] 2. 啟用 ps80 套件庫（會停用 ps57），先只裝 MySQL Shell 跑升級檢查"
  x $n 'percona-release setup -y ps80 2>&1 | tail -3; dnf -q --showduplicates list percona-server-server | tail -3'
  if [ "$first" = yes ]; then
    x $n 'dnf install -y percona-mysql-shell 2>&1 | grep -E "^ percona|Complete|Error"; mysqlsh --version'
    TV=$(docker compose exec -T $n bash -c "dnf -q --showduplicates list percona-server-server | tail -1 | awk '{print \$2}' | cut -d- -f1" | tr -d '\r')
    x $n "mysqlsh --no-wizard -uroot --password='$PW' --socket=/var/lib/mysql/mysql.sock -- util check-for-server-upgrade --target-version=$TV 2>&1 | grep -v 'Using a password'"
  fi

  note "[$n] 3. 停複製、完整關機（innodb_fast_shutdown = 0）、備份資料目錄與設定"
  m $n "STOP SLAVE; SET GLOBAL innodb_fast_shutdown = 0;"
  x $n 'time systemctl stop mysqld; tail -3 /var/log/mysqld.log'
  x $n 'cp -a /var/lib/mysql /var/lib/mysql-5.7-backup && cp -a /etc/my.cnf.d /root/my.cnf.d-5.7 && du -sh /var/lib/mysql-5.7-backup'

  note "[$n] 4. 移除 5.7 套件、安裝 8.0（資料目錄不會被刪）"
  x $n 'dnf remove -y "Percona-Server-*-57" 2>&1 | grep -E "^ Percona|Removed|Complete"; ls -l /etc/my.cnf* 2>&1; ls /var/lib/mysql | head -5'
  x $n 'dnf install -y percona-server-server percona-server-client 2>&1 | grep -E "^ percona-server|Complete|Error"; rpm -qa | grep -i percona-server | sort; mysqld --version'
  x $n 'ls -l /etc/my.cnf; grep -v "^#" /etc/my.cnf | grep -v "^$"; ls /etc/my.cnf.d'

  if [ "$first" = yes ]; then
    note "[$n] 5. 坑 1：8.0 的 /etc/my.cnf 沒有 includedir，my.cnf.d 的設定不會被讀到"
    x $n 'my_print_defaults mysqld'
  fi
  x $n "grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf; tail -1 /etc/my.cnf"

  if [ "$first" = yes ]; then
    note "[$n] 6. 坑 2：5.7 的設定直接拿到 8.0 會起不來，啟動前先用 --validate-config 檢查"
    x $n 'mysqld --validate-config --user=mysql; echo "exit=$?"'
  fi
  x $n 'cp /root/conf/80-replication.cnf /etc/my.cnf.d/replication.cnf && diff /root/my.cnf.d-5.7/replication.cnf /etc/my.cnf.d/replication.cnf'
  x $n 'mysqld --validate-config --user=mysql; echo "exit=$?"'

  note "[$n] 7. 啟動 8.0：第一次啟動自動升級資料字典與系統表（8.0.16 起不用 mysql_upgrade）"
  x $n 'time systemctl start mysqld; systemctl is-active mysqld'
  x $n 'grep -E "Server upgrade|upgrad|Data dictionary|ready for connections|\[ERROR\]" /var/log/mysqld.log | tail -15'
  m $n "SELECT @@hostname, @@server_id, @@version, @@gtid_mode, @@super_read_only, @@collation_server, @@replica_parallel_workers\\G"
  x $n 'sleep 3'
  rs $n
  m $n "SELECT CHANNEL_NAME, SERVICE_STATE, LAST_ERROR_MESSAGE FROM performance_schema.replication_connection_status;"
  m $n "SELECT user, host, plugin FROM mysql.user WHERE user IN ('repl','app','root');"
  m $n "SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='appdb' ORDER BY 1;"
  sync_cmp $SRC $n
}
