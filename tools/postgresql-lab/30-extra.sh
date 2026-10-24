#!/usr/bin/env bash
# 補充驗證：運維文章中 17 vs 18 差異的實測（在 pg1 上，17 跑在 5432、18 啟動在 5433）
source "$(dirname "$0")/lib.sh"
P18=/usr/pgsql-18/bin
p18() { PGBIN=$P18 p "$@"; }
{
note "啟動 18（10-standalone.sh 建好的 /var/lib/pgsql/18/data）"
x pg1 "runuser -u postgres -- $P18/pg_ctl -D /var/lib/pgsql/18/data -l /var/lib/pgsql/18/startup.log -w start >/dev/null; runuser -u postgres -- $P18/psql -X -p 5433 -Atc 'SELECT version()'"

note "pg_stat_checkpointer 欄位"
p pg1 "SELECT string_agg(attname, ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'pg_stat_checkpointer'::regclass AND attnum > 0;"
p18 pg1 "SELECT string_agg(attname, ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'pg_stat_checkpointer'::regclass AND attnum > 0;" postgres 5433
note "pg_stat_io 欄位"
p pg1 "SELECT string_agg(attname, ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'pg_stat_io'::regclass AND attnum > 0;"
p18 pg1 "SELECT string_agg(attname, ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'pg_stat_io'::regclass AND attnum > 0;" postgres 5433
note "pg_wait_events（17 新增）"
p pg1 "SELECT type, name, description FROM pg_wait_events WHERE name IN ('SyncRep', 'WALWrite', 'DataFileRead');"
note "內建角色"
p pg1 "SELECT rolname FROM pg_roles WHERE rolname IN ('pg_maintain','pg_signal_autovacuum_worker','pg_use_reserved_connections','pg_checkpoint') ORDER BY 1;"
p18 pg1 "SELECT rolname FROM pg_roles WHERE rolname IN ('pg_maintain','pg_signal_autovacuum_worker','pg_use_reserved_connections','pg_checkpoint') ORDER BY 1;" postgres 5433
note "EXPLAIN ANALYZE 預設是否帶 BUFFERS"
p pg1 "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM pg_class;"
p18 pg1 "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM pg_class;" postgres 5433
note "uuidv7()"
p pg1 "SELECT uuidv7();"
p18 pg1 "SELECT uuidv7(), uuid_extract_timestamp(uuidv7());" postgres 5433
note "Generated column 預設 virtual / stored"
p pg1 "CREATE TEMP TABLE g (a int, b int GENERATED ALWAYS AS (a * 2));"
p18 pg1 "CREATE TABLE g (a int, b int GENERATED ALWAYS AS (a * 2)); SELECT attname, attgenerated FROM pg_attribute WHERE attrelid = 'g'::regclass AND attname = 'b'; DROP TABLE g;" postgres 5433
note "NOT NULL ... NOT VALID"
p pg1 "CREATE TEMP TABLE n (a int); ALTER TABLE n ADD CONSTRAINT n_a_nn NOT NULL a NOT VALID;"
p18 pg1 "CREATE TABLE n (a int); INSERT INTO n VALUES (NULL); ALTER TABLE n ADD CONSTRAINT n_a_nn NOT NULL a NOT VALID; DELETE FROM n; ALTER TABLE n VALIDATE CONSTRAINT n_a_nn; SELECT conname, contype, convalidated FROM pg_constraint WHERE conrelid = 'n'::regclass; DROP TABLE n;" postgres 5433
note "RETURNING OLD / NEW"
p18 pg1 "CREATE TABLE r (id int, v int); INSERT INTO r VALUES (1, 10); UPDATE r SET v = 20 WHERE id = 1 RETURNING old.v AS old_v, new.v AS new_v; DROP TABLE r;" postgres 5433
note "md5 密碼"
p pg1 "SET password_encryption = 'md5'; CREATE ROLE md5_test LOGIN PASSWORD 'x'; DROP ROLE md5_test;"
p18 pg1 "SET password_encryption = 'md5'; CREATE ROLE md5_test LOGIN PASSWORD 'x'; DROP ROLE md5_test;" postgres 5433
note "MAINTAIN 權限（17）"
p pg1 "CREATE ROLE ops_test NOLOGIN; CREATE TABLE maint_t (a int); GRANT MAINTAIN ON maint_t TO ops_test; SELECT has_table_privilege('ops_test', 'maint_t', 'MAINTAIN'); DROP TABLE maint_t; DROP ROLE ops_test;"
note "pg_upgrade：17 沒開 checksums 的叢集升到 18 預設 initdb（checksums 開）"
x pg1 "runuser -u postgres -- /usr/pgsql-17/bin/initdb -D /tmp/pg17nock --encoding=UTF8 --locale=C.UTF-8 >/dev/null && runuser -u postgres -- $P18/initdb -D /tmp/pg18ck --encoding=UTF8 --locale=C.UTF-8 >/dev/null && runuser -u postgres -- /usr/pgsql-17/bin/pg_controldata /tmp/pg17nock | grep checksum && runuser -u postgres -- $P18/pg_controldata /tmp/pg18ck | grep checksum"
x pg1 "cd /tmp && runuser -u postgres -- $P18/pg_upgrade -b /usr/pgsql-17/bin -B $P18 -d /tmp/pg17nock -D /tmp/pg18ck -p 50432 -P 50433 --check 2>&1 | tail -6"
x pg1 "rm -rf /tmp/pg18ck && runuser -u postgres -- $P18/initdb -D /tmp/pg18ck --no-data-checksums --encoding=UTF8 --locale=C.UTF-8 >/dev/null && cd /tmp && runuser -u postgres -- $P18/pg_upgrade -b /usr/pgsql-17/bin -B $P18 -d /tmp/pg17nock -D /tmp/pg18ck -p 50432 -P 50433 --check 2>&1 | tail -4"
x pg1 "rm -rf /tmp/pg17nock /tmp/pg18ck /tmp/pg_upgrade_output.d"
note "18 的 io_method / io_workers 實際行程"
x pg1 "ps -o pid,cmd -u postgres | grep -E 'io worker' | grep -v grep"
x pg1 "runuser -u postgres -- $P18/pg_ctl -D /var/lib/pgsql/18/data -m fast stop"
} 2>&1 | tee results/30-extra.log
