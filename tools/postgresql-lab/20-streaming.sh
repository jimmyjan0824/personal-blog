#!/usr/bin/env bash
# Streaming Replication：pgs1（主）+ pgs2、pgs3（從，quorum 同步），測試同步提交、故障切換（promote）與 pg_rewind 讓舊主庫回歸
source "$(dirname "$0")/lib.sh"
docker compose rm -sf pgs1 pgs2 pgs3 >/dev/null 2>&1; docker compose up -d pgs1 pgs2 pgs3; sleep 6
D=/var/lib/pgsql/17/data
# 在節點上以 postgres 帳號執行 shell 指令
xp() { local n=$1; shift; echo "[$n]\$ $*"; docker compose exec -T -u postgres -w /var/lib/pgsql "$n" bash -c "export PATH=$PGBIN:\$PATH PGPASSFILE=/var/lib/pgsql/.pgpass; $*" 2>&1; echo; }
# 背景執行 SQL（模擬卡住的用戶端），輸出寫到 /tmp/bg.out
bg() { local n=$1 sql=$2; echo "[$n] postgres=# $sql    （背景執行）"; docker compose exec -T -u postgres "$n" bash -c "nohup $PGBIN/psql -X -c \"$sql\" > /tmp/bg.out 2>&1 &"; echo; }
{
note "環境"
x pgs1 'cat /etc/rocky-release; rpm -q postgresql17-server; ls -la /var/lib/pgsql/17/'

note "步驟 0：三台都做 OS 參數與 .pgpass"
for n in pgs1 pgs2 pgs3; do
  x $n 'cp /root/conf/99-postgresql.conf /etc/sysctl.d/ && sysctl -q -p /etc/sysctl.d/99-postgresql.conf && install -d -o postgres -g postgres -m 700 /var/lib/pgsql/17/archive'
  x $n 'printf "%s\n" "*:5432:replication:replicator:ChangeMe_Repl_2026" "*:5432:postgres:rewind_user:ChangeMe_Rewind_2026" > /var/lib/pgsql/.pgpass && chown postgres: /var/lib/pgsql/.pgpass && chmod 600 /var/lib/pgsql/.pgpass && ls -l /var/lib/pgsql/.pgpass'
done

note "步驟 1：主庫 pgs1 initdb、設定檔、啟動"
x pgs1 'PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" /usr/pgsql-17/bin/postgresql-17-setup initdb'
x pgs1 "install -o postgres -g postgres -m 600 /root/conf/postgresql-streaming.conf $D/postgresql.conf && install -o postgres -g postgres -m 600 /root/conf/pg_hba-streaming.conf $D/pg_hba.conf && systemctl enable --now postgresql-17 && systemctl is-active postgresql-17"
x pgs1 '/root/bin/checkconf.sh /var/lib/pgsql/17/data/postgresql.conf'

note "步驟 2：複製帳號與 pg_rewind 帳號"
p pgs1 "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'ChangeMe_Repl_2026';"
p pgs1 "CREATE ROLE rewind_user LOGIN PASSWORD 'ChangeMe_Rewind_2026';"
p pgs1 "GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;"
p pgs1 "CREATE TABLE t_repl (id bigserial PRIMARY KEY, note text, node text DEFAULT inet_server_addr()::text, ts timestamptz DEFAULT now()); INSERT INTO t_repl(note) VALUES ('before-standby');"

note "步驟 3：從庫 pg_basebackup（-R 寫入 primary_conninfo，-C -S 建立 replication slot）"
for n in pgs2 pgs3; do
  x $n "ls -A $D | wc -l"
  xp $n "time pg_basebackup -d 'host=pgs1 user=replicator application_name=$n' -D $D -X stream -c fast -R -C -S $n -P 2>&1 | tail -2"
  x $n "cat $D/postgresql.auto.conf; ls $D/standby.signal"
  x $n 'systemctl enable --now postgresql-17 && systemctl is-active postgresql-17'
done
x pgs2 'sleep 2; grep -hE "standby|streaming|consistent|redo" /var/lib/pgsql/17/data/log/postgresql-*.log'

note "步驟 4：驗證複製狀態"
p pgs1 "SELECT application_name, client_addr, state, sync_state, sync_priority, sent_lsn, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY application_name;"
p pgs1 "SELECT slot_name, slot_type, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots ORDER BY slot_name;"
p pgs2 "SELECT pg_is_in_recovery(), status, sender_host, slot_name, received_tli, flushed_lsn FROM pg_stat_wal_receiver;"
p pgs2 "SHOW synchronous_standby_names;"
note "測試 1：主庫寫入，從庫讀得到"
p pgs1 "INSERT INTO t_repl(note) SELECT 'row-' || g FROM generate_series(1, 1000) g; SELECT count(*) FROM t_repl;"
p pgs2 "SELECT count(*) FROM t_repl;"
p pgs3 "SELECT count(*) FROM t_repl;"
note "測試 2：從庫是唯讀"
p pgs2 "INSERT INTO t_repl(note) VALUES ('write-on-standby');"
note "測試 3：quorum 同步提交（ANY 1）"
x pgs2 'systemctl stop postgresql-17'
p pgs1 "INSERT INTO t_repl(note) VALUES ('pgs2-down');"
p pgs1 "SELECT application_name, state, sync_state FROM pg_stat_replication;"
x pgs3 'systemctl stop postgresql-17'
bg pgs1 "INSERT INTO t_repl(note) VALUES ('both-down')"
x pgs1 'sleep 3; cat /tmp/bg.out; echo "(還沒有輸出 = COMMIT 卡住)"'
p pgs1 "SELECT pid, state, wait_event_type, wait_event, now() - query_start AS waiting, left(query, 50) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
x pgs3 'systemctl start postgresql-17; sleep 2'
x pgs1 'sleep 1; cat /tmp/bg.out'
note "測試 3b：同步等待被取消時，交易其實已經在主庫提交"
x pgs3 'systemctl stop postgresql-17'
bg pgs1 "INSERT INTO t_repl(note) VALUES ('cancelled-wait')"
x pgs1 'sleep 2'
p pgs1 "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
x pgs1 'sleep 1; cat /tmp/bg.out'
p pgs1 "SELECT id, note FROM t_repl WHERE note IN ('both-down', 'cancelled-wait');"
x pgs2 'systemctl start postgresql-17'
x pgs3 'systemctl start postgresql-17; sleep 3'
p pgs1 "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1;"
note "測試 4：pgbench 寫入壓力下的複製延遲"
xp pgs1 'pgbench -i -s 10 -q postgres 2>&1 | tail -1'
xp pgs1 '(pgbench -c 8 -j 4 -T 20 postgres > /tmp/pgbench.out 2>&1 &); for i in 1 2 3 4; do sleep 4; psql -X -Atc "SELECT now()::time(0), application_name, sync_state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_bytes, replay_lag FROM pg_stat_replication ORDER BY 2"; done; sleep 6; grep -E "^(tps|latency average|number of transactions actually)" /tmp/pgbench.out'
for n in pgs1 pgs2 pgs3; do p $n "SELECT '$n' AS node, sum(abalance) AS sum_abalance, (SELECT count(*) FROM pgbench_history) AS history FROM pgbench_accounts;"; done

note "測試 5：故障切換（主庫 pgs1 當機，提升 pgs2）"
p pgs1 "INSERT INTO t_repl(note) VALUES ('last-before-crash'); SELECT count(*), pg_current_wal_lsn() FROM t_repl;"
h "date '+%F %T'; docker compose kill pgs1"
x pgs2 'sleep 3; grep -hE "terminat|could not|FATAL" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -3'
note "提升前：比較兩台從庫收到的 WAL 位置，挑最新的那台提升"
for n in pgs2 pgs3; do p $n "SELECT '$n' AS node, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"; done
h "date '+%F %T.%N' | cut -c1-23"
p pgs2 "SELECT pg_promote(wait => true, wait_seconds => 60);"
h "date '+%F %T.%N' | cut -c1-23"
p pgs2 "SELECT pg_is_in_recovery(), pg_walfile_name(pg_current_wal_lsn()) AS walfile, count(*) FROM t_repl;"
x pgs2 'grep -hE "promote|selected new timeline|archive recovery complete|ready to accept" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4; ls /var/lib/pgsql/17/data/pg_wal/*.history'
note "新主庫 pgs2：先替 pgs3、pgs1 建 slot，再把 pgs3 改接 pgs2"
p pgs2 "SELECT pg_create_physical_replication_slot('pgs3'); SELECT pg_create_physical_replication_slot('pgs1');"
p pgs3 "ALTER SYSTEM SET primary_conninfo = 'host=pgs2 user=replicator application_name=pgs3'; SELECT pg_reload_conf();"
x pgs3 'sleep 4; grep -hE "timeline|streaming|primary_conninfo" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4'
p pgs3 "SELECT status, sender_host, received_tli, flushed_lsn FROM pg_stat_wal_receiver;"
p pgs2 "INSERT INTO t_repl(note) VALUES ('after-failover'); SELECT application_name, state, sync_state FROM pg_stat_replication;"
p pgs3 "SELECT count(*), max(note) FILTER (WHERE id = (SELECT max(id) FROM t_repl)) AS last_note FROM t_repl;"

note "測試 6：舊主庫 pgs1 回來了（systemd 會自動啟動成主庫 = 腦裂風險）"
h "docker compose start pgs1"
x pgs1 'sleep 5; systemctl is-active postgresql-17'
p pgs1 "SELECT pg_is_in_recovery(), pg_walfile_name(pg_current_wal_lsn()) AS walfile;"
bg pgs1 "INSERT INTO t_repl(note) VALUES ('split-brain')"
x pgs1 'sleep 2'
p pgs1 "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';"
x pgs1 'sleep 1; cat /tmp/bg.out'
p pgs1 "SELECT id, note FROM t_repl ORDER BY id DESC LIMIT 2;"
note "直接把 pgs1 當從庫啟動會失敗（timeline 已分岔）"
x pgs1 "systemctl stop postgresql-17 && runuser -u postgres -- touch $D/standby.signal && printf \"%s\n\" \"primary_conninfo = 'host=pgs2 user=replicator application_name=pgs1'\" \"primary_slot_name = 'pgs1'\" >> $D/postgresql.auto.conf && cat $D/postgresql.auto.conf && systemctl start postgresql-17; sleep 5; systemctl is-active postgresql-17"
x pgs1 'grep -hE "FATAL|forked|not a child|timeline" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4'
note "pg_rewind（-n 先試跑），再接回 pgs2"
x pgs1 'systemctl stop postgresql-17; systemctl is-active postgresql-17'
xp pgs1 "pg_controldata $D | grep -E 'cluster state|TimeLineID'"
xp pgs1 "pg_rewind -D $D --source-server='host=pgs2 user=rewind_user dbname=postgres' -n -P 2>&1 | tail -6"
xp pgs1 "time pg_rewind -D $D --source-server='host=pgs2 user=rewind_user dbname=postgres' -P 2>&1 | tail -6"
x pgs1 "ls $D/standby.signal 2>&1; cat $D/postgresql.auto.conf"
x pgs1 "runuser -u postgres -- touch $D/standby.signal; printf \"%s\n\" \"primary_conninfo = 'host=pgs2 user=replicator application_name=pgs1'\" \"primary_slot_name = 'pgs1'\" > $D/postgresql.auto.conf; chown postgres: $D/postgresql.auto.conf; systemctl start postgresql-17; sleep 5; systemctl is-active postgresql-17"
x pgs1 'grep -hE "redo|consistent|streaming|timeline" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -5'
p pgs1 "SELECT pg_is_in_recovery(), status, sender_host, received_tli FROM pg_stat_wal_receiver;"
p pgs2 "SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication ORDER BY 1;"
for n in pgs1 pgs2 pgs3; do p $n "SELECT '$n' AS node, count(*), count(*) FILTER (WHERE note = 'split-brain') AS split_brain_rows, max(id) FROM t_repl;"; done
note "錯誤日誌摘要"
for n in pgs1 pgs2 pgs3; do x $n 'grep -hcE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log; grep -hE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log | sed -E "s/^[0-9-]+ [0-9:.]+ CST \[[0-9]+\] //" | sort | uniq -c | sort -rn | head -12'; done
} 2>&1 | tee results/20-streaming.log
