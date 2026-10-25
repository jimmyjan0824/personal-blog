#!/usr/bin/env bash
# 舊主庫 db1 就地升級到 8.0，重新接上新主庫 db2，三台都是 8.0；最後比對資料、確認 app 寫入沒有遺失
source "$(dirname "$0")/lib.sh"
{
SRC=db2 upgrade_node db1 no
note "三台都是 8.0"
for n in db1 db2 db3; do m $n "SELECT @@hostname, @@version, @@read_only, @@super_read_only;"; done
m db2 "SHOW REPLICAS;"
for n in db1 db3; do rs $n; done
sync_cmp db2 db1 db3
note "停止 app 寫入，核對每一筆成功的寫入都在資料庫裡"
x app 'touch /tmp/writer.stop; sleep 2; echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"; grep " ERR " /tmp/writer.log | cut -d" " -f3- | sort | uniq -c'
m db2 "SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;"
sync_cmp db2 db1 db3
note "升級後的 8.0 仍有的 5.7 遺留，清理建議"
m db2 "SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='appdb' ORDER BY 1;"
m db2 "SELECT user, host, plugin FROM mysql.user WHERE user IN ('repl','app','root');"
x db2 'ls -d /var/lib/mysql-5.7-backup; du -sh /var/lib/mysql-5.7-backup'
} 2>&1 | tee results/40-upgrade-old-primary.log
