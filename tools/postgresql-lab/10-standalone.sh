#!/usr/bin/env bash
# Standalone：在 pg1（只有 systemd 的 Rocky 9.8）現場照文章步驟 0~5 操作並驗證，最後在同一台裝 18 做比較
source "$(dirname "$0")/lib.sh"
docker compose rm -sf pg1 >/dev/null 2>&1; docker compose up -d pg1; sleep 5
{
note "環境"
x pg1 'cat /etc/rocky-release; uname -m; nproc; free -g | head -2; df -h / /dev/shm | sed 1d'

note "步驟 0：OS 參數"
x pg1 'cp /root/conf/99-postgresql.conf /etc/sysctl.d/99-postgresql.conf && sysctl -p /etc/sysctl.d/99-postgresql.conf'
x pg1 'cat /sys/kernel/mm/transparent_hugepage/enabled; grep -E "HugePages_Total|Hugepagesize" /proc/meminfo'

note "步驟 1：安裝 PGDG 套件庫與 PostgreSQL 17"
x pg1 'dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm 2>&1 | grep -E "^Install|pgdg-redhat-repo|Complete"'
x pg1 'dnf -qy module disable postgresql; dnf repolist --enabled | grep -i pgdg'
x pg1 'dnf install -y postgresql17-server postgresql17-contrib 2>&1 | grep -E "^Install|^ postgresql17|Importing GPG|Fingerprint|Key imported|Complete"'
x pg1 'rpm -q postgresql17 postgresql17-libs postgresql17-server postgresql17-contrib; rpm -qi postgresql17-server | grep -E "^(Version|Release|Signature)"'
x pg1 '/usr/pgsql-17/bin/postgres --version; which psql; psql --version'
x pg1 '/usr/pgsql-17/bin/pg_config --configure | tr " " "\n" | grep -E "with-(lz4|zstd|llvm|systemd|openssl|icu|libxml|gssapi|ldap|pam|selinux)|system-tzdata"'
x pg1 'id postgres; ls -ld /var/lib/pgsql /var/lib/pgsql/17 /var/lib/pgsql/17/data'

note "步驟 2：initdb"
x pg1 'PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" /usr/pgsql-17/bin/postgresql-17-setup initdb && cat /var/lib/pgsql/17/initdb.log'
x pg1 'runuser -u postgres -- pg_controldata /var/lib/pgsql/17/data | grep -E "pg_control version|Catalog version|checksum|Database block size|WAL block size|Bytes per WAL segment"'
x pg1 'ls -la /var/lib/pgsql/17/data'
docker compose exec -T pg1 bash -c 'grep -Ev "^\s*(#|$)" /var/lib/pgsql/17/data/postgresql.conf | sed "s/[[:space:]]*#.*//"' > results/initdb-postgresql.conf-17.txt
docker compose exec -T pg1 bash -c 'grep -Ev "^\s*(#|$)" /var/lib/pgsql/17/data/pg_hba.conf' > results/initdb-pg_hba.conf-17.txt

note "步驟 3：設定檔"
x pg1 'install -d -o postgres -g postgres -m 700 /var/lib/pgsql/17/archive'
x pg1 'cd /var/lib/pgsql/17/data && cp postgresql.conf postgresql.conf.initdb && cp pg_hba.conf pg_hba.conf.initdb && install -o postgres -g postgres -m 600 /root/conf/postgresql-standalone.conf postgresql.conf && install -o postgres -g postgres -m 600 /root/conf/pg_hba-standalone.conf pg_hba.conf && ls -l postgresql.conf pg_hba.conf'
x pg1 'grep -Ev "^\s*(#|$)" /var/lib/pgsql/17/data/postgresql.conf | wc -l'

note "步驟 4：systemd"
x pg1 'systemctl cat postgresql-17 | grep -Ev "^\s*(#|$)"'
x pg1 'systemctl enable --now postgresql-17'
x pg1 'systemctl status postgresql-17 --no-pager | head -12'
x pg1 'ls /var/lib/pgsql/17/data/log/; cat /var/lib/pgsql/17/data/log/postgresql-*.log'
x pg1 'grep -E "OOM|oom" /proc/$(head -1 /var/lib/pgsql/17/data/postmaster.pid)/oom_score_adj; cat /proc/$(head -1 /var/lib/pgsql/17/data/postmaster.pid)/limits | grep "open files"'

note "步驟 5：驗證"
p pg1 "SELECT version();"
p pg1 "SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','max_connections','wal_buffers','max_wal_size','random_page_cost','effective_io_concurrency','huge_pages','wal_compression','data_checksums','shared_preload_libraries','jit') ORDER BY name;"
p pg1 "SHOW huge_pages_status;"
note "設定檔 vs 實際值比對"
x pg1 '/root/bin/checkconf.sh /var/lib/pgsql/17/data/postgresql.conf'
p pg1 "SELECT datname, encoding::int, pg_encoding_to_char(encoding) AS enc, datlocprovider, datlocale, datcollate, datctype FROM pg_database ORDER BY datname;"
note "建立應用帳號與資料庫"
p pg1 "CREATE ROLE app LOGIN PASSWORD 'ChangeMe_App_2026';"
p pg1 "CREATE DATABASE appdb OWNER app;"
p pg1 "CREATE EXTENSION pg_stat_statements;" appdb
p pg1 "SELECT rolname, left(rolpassword, 14) AS pw_prefix FROM pg_authid WHERE rolname = 'app';"
x pg1 'PGPASSWORD=ChangeMe_App_2026 psql -X -h 192.168.59.11 -U app -d appdb -c "SELECT current_user, inet_server_addr(), ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();"'
x pg1 'PGPASSWORD=wrong psql -X -h 127.0.0.1 -U app -d appdb -c "SELECT 1"; tail -2 /var/lib/pgsql/17/data/log/postgresql-*.log'
note "pgbench（容器內，只確認服務正常，不代表正式主機效能）"
x pg1 'PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -i -s 20 -q appdb 2>&1 | tail -3'
x pg1 'PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -c 16 -j 4 -T 30 -P 10 appdb 2>&1 | grep -vE "^pgbench \(|^starting"'
x pg1 'PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -c 16 -j 4 -T 20 -S appdb 2>&1 | grep -E "^(tps|latency average|number of transactions actually)"'
p pg1 "SELECT left(query, 60) AS query, calls, round(mean_exec_time::numeric, 3) AS mean_ms, round(total_exec_time::numeric) AS total_ms FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;" appdb
note "平行查詢（確認 /dev/shm 夠用）"
p pg1 "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM pgbench_accounts;" appdb
note "慢查詢、暫存檔、鎖等待日誌"
p pg1 "SELECT pg_sleep(1.2);" appdb
p pg1 "SET work_mem = '1MB'; SELECT count(*) FROM (SELECT aid FROM pgbench_accounts ORDER BY abalance, filler) t;" appdb
x pg1 '(runuser -u postgres -- psql -X -d appdb -c "BEGIN; LOCK pgbench_branches; SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &) ; sleep 0.5; runuser -u postgres -- psql -X -d appdb -c "UPDATE pgbench_branches SET bbalance = bbalance WHERE bid = 1;"'
x pg1 'grep -E "duration: [0-9]{4}|temporary file|still waiting|acquired" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -8'
note "WAL 歸檔"
p pg1 "SELECT pg_switch_wal();"
x pg1 'sleep 2; ls -l /var/lib/pgsql/17/archive | tail -3'
p pg1 "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"
note "重啟後資料仍在"
x pg1 'systemctl restart postgresql-17 && runuser -u postgres -- psql -X -d appdb -Atc "SELECT count(*) FROM pgbench_accounts"'
note "時鐘開銷（track_io_timing 的前提）"
x pg1 'pg_test_timing -d 1 | head -8'
note "錯誤日誌中的 WARNING / ERROR / FATAL"
x pg1 'grep -E "WARNING|ERROR|FATAL|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log || echo "(none)"'
note "預設值：17 的 pg_settings（boot_val）"
docker compose exec -T -u postgres pg1 /usr/pgsql-17/bin/psql -X -At -F '|' -d postgres -c "SELECT name, boot_val, unit, context FROM pg_settings ORDER BY name" > results/defaults-17.txt
x pg1 'echo -n "17 參數數量："; runuser -u postgres -- psql -X -Atc "SELECT count(*) FROM pg_settings"'

note "比較：在同一台安裝 PostgreSQL 18"
x pg1 'dnf install -y postgresql18-server postgresql18-contrib 2>&1 | grep -E "^ postgresql18|Complete"; rpm -q postgresql18-server; /usr/pgsql-18/bin/postgres --version'
x pg1 'runuser -u postgres -- /usr/pgsql-18/bin/initdb -D /var/lib/pgsql/18/data --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8 2>&1 | grep -Ev "^$"'
x pg1 'runuser -u postgres -- /usr/pgsql-18/bin/pg_controldata /var/lib/pgsql/18/data | grep -E "pg_control version|Catalog version|checksum"'
docker compose exec -T pg1 bash -c 'grep -Ev "^\s*(#|$)" /var/lib/pgsql/18/data/postgresql.conf | sed "s/[[:space:]]*#.*//"' > results/initdb-postgresql.conf-18.txt
x pg1 'install -d -o postgres -g postgres -m 700 /var/lib/pgsql/18/archive; cd /var/lib/pgsql/18/data && sed -e "s#/var/lib/pgsql/17/#/var/lib/pgsql/18/#g" -e "s/^port = 5432/port = 5433/" -e "s/^listen_addresses = .*/listen_addresses = '"'"'localhost'"'"'/" /root/conf/postgresql-standalone.conf > postgresql.conf && chown postgres: postgresql.conf && runuser -u postgres -- /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/18/data -l /var/lib/pgsql/18/startup.log -w start; cat /var/lib/pgsql/18/startup.log'
x pg1 'cat /var/lib/pgsql/18/data/log/postgresql-*.log'
x pg1 '/root/bin/checkconf.sh /var/lib/pgsql/18/data/postgresql.conf 5433 /usr/pgsql-18/bin/psql'
p pg1 "SELECT name, setting FROM pg_settings WHERE name IN ('io_method','io_workers','io_combine_limit','io_max_combine_limit','effective_io_concurrency','maintenance_io_concurrency','autovacuum_worker_slots','autovacuum_vacuum_max_threshold','data_checksums','md5_password_warnings','idle_replication_slot_timeout','max_active_replication_origins','track_cost_delay_timing','log_lock_failures','vacuum_max_eager_freeze_failure_rate','vacuum_truncate','log_connections') ORDER BY name;" postgres 5433
docker compose exec -T -u postgres pg1 /usr/pgsql-18/bin/psql -X -At -F '|' -p 5433 -d postgres -c "SELECT name, boot_val, unit, context FROM pg_settings ORDER BY name" > results/defaults-18.txt
x pg1 'echo -n "18 參數數量："; runuser -u postgres -- /usr/pgsql-18/bin/psql -X -p 5433 -Atc "SELECT count(*) FROM pg_settings"'
x pg1 'runuser -u postgres -- /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/18/data -m fast stop'
} 2>&1 | tee results/10-standalone.log
# 17 vs 18 預設值差異：ADD 18 新增、DEL 18 移除、CHG 預設值改變（name|17|18）
awk -F'|' 'NR==FNR { a[$1]=$2; next }
  !($1 in a) { print "ADD " $1 "|" $2; next }
  a[$1] != $2 { print "CHG " $1 "|" a[$1] "|" $2 }
  { delete a[$1] }
  END { for (k in a) print "DEL " k }' results/defaults-17.txt results/defaults-18.txt | sort > results/defaults-diff-17-18.txt
cat results/defaults-diff-17-18.txt
