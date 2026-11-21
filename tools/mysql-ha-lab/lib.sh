#!/usr/bin/env bash
# 共用函式：先印出要執行的指令再在容器內執行，輸出就是文章裡的實測輸出
#   x  <節點> <shell 指令>   以 root 執行，印成「[節點]# 指令」
#   m  <節點> <SQL>          用 mysql 用戶端執行（帳密在 /root/.my.cnf），印成「[節點] mysql> SQL」
#   mg <節點> <SQL>          同上，輸出用 \G 直式
#   js <節點> <JS>           用 MySQL Shell（clusteradmin 帳號）執行 AdminAPI，印成「[節點] mysqlsh> JS」
set -u
cd "$(dirname "$0")"
export PATH="$HOME/.docker/bin:$PATH"
mkdir -p results
PW='ChangeMe_Root_2026'
RPW='ChangeMe_Repl_2026'
CPW='ChangeMe_Admin_2026'
x() {
  local n=$1; shift
  echo "[$n]# $*"
  docker compose exec -T "$n" bash -c "umask 022; $*" 2>&1
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
  docker compose exec -T "$n" mysql --vertical -e "$sql" 2>&1   # 9.x 用戶端非互動模式預設不處理 \G，改用 --vertical（輸出相同）
  echo
}
js() {
  local n=$1 code=$2
  echo "[$n] mysqlsh> $code"
  docker compose exec -T "$n" mysqlsh --no-wizard --js --uri "clusteradmin:$CPW@$n:3306" -e "$code" 2>&1 \
    | grep -v -E 'Cannot set LC_ALL|Using a password on the command line'
  echo
}
q() { docker compose exec -T "$1" mysql -N -r -e "$2" 2>/dev/null | tr -d '\r'; }   # 只取值、不印（給腳本判斷用）
note() { echo; echo "======== $* ========  ($(date '+%F %T'))"; }
h() { echo "# 主機端：$*"; eval "$@" 2>&1; echo; }
# 複製狀態摘要（8.0.22+ 的 SHOW REPLICA STATUS）；第二個參數是 channel 名稱
rs() {
  local n=$1 ch=${2:-}
  local f=""; [ -n "$ch" ] && f=" FOR CHANNEL '$ch'"
  echo "[$n] mysql> SHOW REPLICA STATUS$f\\G   （節錄）"
  docker compose exec -T "$n" mysql --vertical -e "SHOW REPLICA STATUS$f" 2>&1 \
    | grep -E 'Source_Host|Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind|Last_(IO_|SQL_)?Err(no|or)|Retrieved_Gtid|Executed_Gtid|Auto_Position|SQL_Delay: [1-9]|SQL_Remaining_Delay: [0-9]|Replicate_[A-Za-z_]+: .+|Channel_Name: .+|^ *[0-9a-f]{8}-'
  echo
}
# 全新啟動指定節點（每個 lab 都從乾淨的主機開始）
fresh() {
  docker compose down -v >/dev/null 2>&1
  docker compose up -d "$@" >/dev/null 2>&1
  sleep 6
}
# 初始化一台：放設定檔、啟動、改 root 密碼、寫 /root/.my.cnf；設定檔來源是 conf/ 底下的檔名（可多個）
init_node() {
  local n=$1 id=$2; shift 2
  local cp=""
  for f in "$@"; do local d=$(basename $f); d=${d/-8[04]/}; d=${d/-97/}; cp="$cp cp /root/conf/$f /etc/my.cnf.d/$d &&"; done
  x $n "grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf; $cp printf '[mysqld]\nserver_id   = $id\nreport_host = $n\n' > /etc/my.cnf.d/server-id.cnf && ls /etc/my.cnf.d"
  x $n 'systemctl enable --now mysqld && systemctl is-active mysqld'
  x $n "TMP=\$(grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print \$NF}'); mysql --connect-expired-password -uroot -p\"\$TMP\" -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$PW';\" 2>&1 | grep -v Warning; printf '[client]\nuser=root\npassword=\"$PW\"\n' > /root/.my.cnf; chmod 600 /root/.my.cnf; echo root password set"
}
# 資料比對：每台的筆數與內容雜湊
#   sync_cmp <主庫> <其他節點...>：先暫停 app 寫入，等其他節點追上主庫的 gtid_executed 再比對，最後恢復寫入
sync_cmp() {
  local src=$1; shift
  docker compose exec -T app touch /tmp/writer.pause 2>/dev/null; sleep 1
  local g; g=$(q "$src" 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')
  for n in "$@"; do
    m "$n" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$g', 60) AS waited;   -- 0 = 已追上 $src"
  done
  cmp_data "$src" "$@"
  docker compose exec -T app rm -f /tmp/writer.pause 2>/dev/null
}
cmp_data() {
  for n in "$@"; do
    m "$n" "SELECT @@hostname AS node, @@version AS version, COUNT(*) AS rows_cnt, SUM(CRC32(CONCAT_WS('#', id, note, src))) AS crc FROM appdb.t_orders;"
  done
}
# app 寫入器：writer_start <目標主機或 router:port>
writer_start() {
  x app "echo $1 > /tmp/target; rm -f /tmp/writer.stop /tmp/writer.pause /tmp/writer.log; (nohup /root/conf/writer.sh >/dev/null 2>&1 &); sleep 3; tail -3 /tmp/writer.log"
}
writer_stat() { x app 'echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; tail -1 /tmp/writer.log'; }
# 以 root（本機 socket）執行 MySQL Shell，給還沒有 clusteradmin 帳號時用
jsroot() {
  local n=$1 code=$2
  echo "[$n] mysqlsh> $code"
  docker compose exec -T "$n" mysqlsh --no-wizard --js --uri "root@localhost" --socket=/var/lib/mysql/mysql.sock --password="$PW" -e "$code" 2>&1 \
    | grep -v -E 'Cannot set LC_ALL|Using a password on the command line'
  echo
}
# 建立 app 帳號、appdb.t_orders 與 5000 筆種子資料（在主庫執行）
seed_app() {
  m $1 "CREATE USER 'app'@'192.168.58.%' IDENTIFIED BY 'ChangeMe_App_2026'; GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'app'@'192.168.58.%';
CREATE DATABASE appdb;
CREATE TABLE appdb.t_orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(100), src VARCHAR(20), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
SET SESSION cte_max_recursion_depth = 10000;
INSERT INTO appdb.t_orders (note, src) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 5000) SELECT CONCAT('init-', n), 'seed' FROM s;"
}
# 寫入中斷：outage <起始時間 HH:MM:SS.mmm>，從該時間之後的 app 紀錄算出失敗筆數，以及相鄰兩筆成功寫入之間最長的空檔
outage() {
  x app "python3 /root/conf/outage.py '$1' /tmp/writer.log ${2:-}"
}
now() { date -u +%T.000; }
