#!/usr/bin/env bash
# 建立 Percona Server 5.7 一主二從（GTID）：db1 主、db2 / db3 從，並灌入測試資料
source "$(dirname "$0")/lib.sh"
docker compose down -v >/dev/null 2>&1; docker compose up -d; sleep 8
# 實驗環境修正：Docker Desktop VM 的 fs.nr_open 是 1073741816，容器裡的 systemd（PID 1）nofile 也是這個值。
# mysqld.service 有 PermissionsStartOnly=true，systemd 252 不會把 LimitNOFILE=5000 套用到 ExecStartPre，
# mysqld_pre_systemd 裡的 mysqld --initialize 依這個上限配置記憶體，吃到 7 GB 被 OOM kill。
# 把 PID 1 的上限降成實體 Rocky 9 主機的值（fs.nr_open 預設 1048576）
for n in db1 db2 db3 app; do docker compose exec -T $n prlimit --pid 1 --nofile=1048576:1048576; done

{
note "環境"
x db1 'cat /etc/rocky-release; uname -m; rpm -qa | grep -i percona | sort; mysqld --version'
x db1 'ls -l /etc/my.cnf; readlink -f /etc/my.cnf; grep -v "^#" $(readlink -f /etc/my.cnf) | grep -v "^$"; ls /etc/my.cnf.d /etc/percona-server.conf.d 2>/dev/null; grep -v "^#" /etc/percona-server.conf.d/mysqld.cnf 2>/dev/null | grep -v "^$"'

note "步驟 1：三台放設定檔、啟動、改 root 密碼"
id=0
for n in db1 db2 db3; do
  id=$((id+1))
  x $n "cp /root/conf/57-replication.cnf /etc/my.cnf.d/replication.cnf && printf '[mysqld]\nserver_id   = $id\nreport_host = $n\n' > /etc/my.cnf.d/server-id.cnf && cat /etc/my.cnf.d/server-id.cnf"
  x $n 'systemctl enable --now mysqld && systemctl is-active mysqld'
  x $n "TMP=\$(grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print \$NF}'); echo \"temporary password: \$TMP\"; mysql --connect-expired-password -uroot -p\"\$TMP\" -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$PW';\" 2>&1 | grep -v Warning; printf '[client]\nuser=root\npassword=\"$PW\"\n' > /root/.my.cnf; chmod 600 /root/.my.cnf"
  m $n "SELECT @@hostname, @@server_id, @@version, @@gtid_mode, @@log_bin_basename, @@collation_server, @@sql_mode\\G"
done

note "步驟 2：主庫 db1 建複製帳號與測試資料"
m db1 "CREATE USER 'repl'@'192.168.57.%' IDENTIFIED BY 'ChangeMe_Repl_2026'; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'repl'@'192.168.57.%';"
m db1 "CREATE USER 'app'@'192.168.57.%' IDENTIFIED BY 'ChangeMe_App_2026'; GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'app'@'192.168.57.%';"
m db1 "SELECT user, host, plugin FROM mysql.user WHERE user IN ('repl','app','root');"
m db1 "CREATE DATABASE appdb;
CREATE TABLE appdb.t_orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(100), src VARCHAR(20), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;
CREATE TABLE appdb.t_legacy (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB DEFAULT CHARSET=utf8;
CREATE TABLE appdb.t_rank (id INT PRIMARY KEY, \`rank\` INT, qty INT(10) ZEROFILL) ENGINE=InnoDB;
CREATE TABLE appdb.t_myisam (id INT PRIMARY KEY, v VARCHAR(20)) ENGINE=MyISAM;
INSERT INTO appdb.t_legacy VALUES (1,'a'),(2,'b');
INSERT INTO appdb.t_rank VALUES (1,1,5),(2,2,50);
INSERT INTO appdb.t_myisam VALUES (1,'x');"
m db1 "INSERT INTO appdb.t_orders (note, src) SELECT CONCAT('init-', seq), 'db1-57' FROM (SELECT @r:=@r+1 AS seq FROM information_schema.columns a, information_schema.columns b, (SELECT @r:=0) z LIMIT 5000) s; SELECT COUNT(*) FROM appdb.t_orders;"
m db1 "SHOW MASTER STATUS;"

note "步驟 3：db2、db3 用 GTID 自動定位接上 db1（三台都是全新初始化，沒有既有資料，不需要先 dump）"
for n in db2 db3; do
  m $n "RESET MASTER; CHANGE MASTER TO MASTER_HOST='db1', MASTER_USER='repl', MASTER_PASSWORD='ChangeMe_Repl_2026', MASTER_AUTO_POSITION=1; START SLAVE; SET GLOBAL super_read_only = ON;"
  x $n "printf 'super_read_only = ON\n' >> /etc/my.cnf.d/server-id.cnf; cat /etc/my.cnf.d/server-id.cnf"
done
x db1 'sleep 3'
for n in db2 db3; do rs $n; done
m db1 "SHOW SLAVE HOSTS;"
sync_cmp db1 db2 db3

note "步驟 4：app 開始持續寫入（每 0.2 秒一筆，寫到 /tmp/target 指定的主庫）"
x app 'echo db1 > /tmp/target; rm -f /tmp/writer.stop /tmp/writer.log; (nohup /root/conf/writer.sh >/dev/null 2>&1 &); sleep 3; tail -3 /tmp/writer.log'
} 2>&1 | tee results/10-setup-57.log
