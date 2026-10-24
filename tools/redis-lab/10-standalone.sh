#!/usr/bin/env bash
# Standalone：在 redis1（只有 systemd 的 Rocky 9）現場照文章步驟 0~5 操作並驗證
source "$(dirname "$0")/lib.sh"
docker compose rm -sf redis1 >/dev/null 2>&1; docker compose up -d redis1; sleep 5
{
note "環境"
x redis1 'cat /etc/rocky-release; uname -m; nproc; free -g | head -2'

note "步驟 0：OS 參數"
x redis1 'cat /proc/sys/vm/overcommit_memory /proc/sys/net/core/somaxconn /sys/kernel/mm/transparent_hugepage/enabled'
x redis1 'mkdir -p /etc/sysctl.d && cp /root/conf/99-redis.conf /etc/sysctl.d/99-redis.conf && sysctl -p /etc/sysctl.d/99-redis.conf'

note "步驟 1：安裝編譯工具並編譯安裝"
x redis1 'dnf install -y gcc make tar gzip systemd-devel 2>&1 | grep -E "^Install|^Upgrade|Complete|gcc  |systemd-devel" | head'
x redis1 'cd /usr/local/src && curl -fsSLO https://download.redis.io/releases/redis-7.4.11.tar.gz && ls -l redis-7.4.11.tar.gz && sha256sum redis-7.4.11.tar.gz'
x redis1 'curl -fsSL https://raw.githubusercontent.com/redis/redis-hashes/master/README | grep "redis-7.4.11.tar.gz"'
x redis1 'cd /usr/local/src && tar xzf redis-7.4.11.tar.gz && cd redis-7.4.11 && (time make -j"$(nproc)" USE_SYSTEMD=yes) 2>&1 | tail -8'
x redis1 'cd /usr/local/src/redis-7.4.11 && make install 2>&1 | tail -8'
x redis1 'ls /usr/local/bin/redis-*; redis-server --version; ldd /usr/local/bin/redis-server | grep systemd'

note "預設值：不帶設定檔啟動 7.4.11，匯出 CONFIG GET *"
x redis1 'redis-server --port 7777 --daemonize yes --logfile /tmp/def.log >/dev/null; sleep 1; REDISCLI_AUTH= redis-cli -p 7777 config get "*" | paste - - | sort > /tmp/defaults-7.4.11.txt; REDISCLI_AUTH= redis-cli -p 7777 shutdown nosave; wc -l /tmp/defaults-7.4.11.txt'
docker compose exec -T redis1 cat /tmp/defaults-7.4.11.txt > results/defaults-7.4.11.txt
note "對照：編譯 8.10.2（不安裝），匯出預設值"
x redis1 'cd /usr/local/src && curl -fsSLO https://download.redis.io/releases/redis-8.10.2.tar.gz && tar xzf redis-8.10.2.tar.gz && cd redis-8.10.2 && make -j"$(nproc)" USE_SYSTEMD=yes >/tmp/make810.log 2>&1; echo rc=$?; tail -3 /tmp/make810.log; src/redis-server --version'
x redis1 '/usr/local/src/redis-8.10.2/src/redis-server --port 7778 --daemonize yes --logfile /tmp/def8.log >/dev/null; sleep 1; REDISCLI_AUTH= redis-cli -p 7778 config get "*" | paste - - | sort > /tmp/defaults-8.10.2.txt; REDISCLI_AUTH= redis-cli -p 7778 shutdown nosave; wc -l /tmp/defaults-8.10.2.txt'
docker compose exec -T redis1 cat /tmp/defaults-8.10.2.txt > results/defaults-8.10.2.txt
docker compose exec -T redis1 bash -c 'cd /usr/local/src && grep -Ev "^\s*(#|$)" redis-7.4.11/redis.conf > /tmp/a; grep -Ev "^\s*(#|$)" redis-8.10.2/redis.conf > /tmp/b; diff /tmp/a /tmp/b' > results/redis.conf-template-diff.txt

note "步驟 2：使用者與目錄"
x redis1 'groupadd -r redis && useradd -r -g redis -s /sbin/nologin -d /var/lib/redis -c "Redis Server" redis && id redis'
x redis1 'mkdir -p /etc/redis /var/lib/redis /var/log/redis && chown -R redis:redis /etc/redis /var/lib/redis /var/log/redis && chmod 750 /etc/redis /var/lib/redis /var/log/redis'

note "步驟 3：設定檔"
x redis1 'install -o redis -g redis -m 640 /root/conf/redis-standalone.conf /etc/redis/redis.conf && grep -Ev "^\s*(#|$)" /etc/redis/redis.conf | wc -l'

note "步驟 4：systemd"
x redis1 'cp /root/conf/redis.service /etc/systemd/system/redis.service && systemctl daemon-reload && systemctl enable --now redis'
x redis1 'systemctl status redis --no-pager | head -9'
x redis1 'cat /var/log/redis/redis.log'

note "步驟 5：驗證"
x redis1 'redis-cli ping; redis-cli info server | grep -E "redis_version|redis_mode|os:|arch_bits|multiplexing_api|gcc_version|process_supervised|config_file|io_threads_active"'
x redis1 'redis-cli config get maxmemory; redis-cli config get maxmemory-policy; redis-cli config get io-threads; redis-cli config get appendonly; redis-cli config get lazyfree-lazy-user-del'
x redis1 'cat /proc/$(pidof redis-server)/limits | grep "open files"; redis-cli config get maxclients'
note "設定檔 vs 實際值比對（只印出不同的）"
cmpconf redis1 /etc/redis/redis.conf
x redis1 'REDISCLI_AUTH= redis-cli ping; redis-cli -h 192.168.58.11 ping'
x redis1 'redis-cli set user:1001:name Jimmy EX 3600; redis-cli get user:1001:name; redis-cli debug populate 100000 key 100 >/dev/null; redis-cli dbsize; redis-cli info memory | grep -E "used_memory_human|maxmemory_human|maxmemory_policy|mem_fragmentation_ratio|mem_allocator"'
x redis1 'redis-cli info persistence | grep -E "aof_enabled|aof_rewrite_in_progress|rdb_last_bgsave_status|aof_last_write_status"; ls -l /var/lib/redis /var/lib/redis/appendonlydir'
note "重啟後資料仍在（AOF）"
x redis1 'systemctl restart redis && sleep 2 && redis-cli dbsize && redis-cli get user:1001:name && grep -E "DB loaded|Ready to accept" /var/log/redis/redis.log | tail -3'
note "慢查詢與延遲監控"
x redis1 'redis-cli debug sleep 0.2; redis-cli latency latest; redis-cli slowlog get 1'
note "錯誤日誌中的 WARNING"
x redis1 'grep -E "WARNING|# " /var/log/redis/redis.log || echo "(no warnings)"'
note "redis-benchmark（容器內，僅確認服務正常，不代表正式主機效能）"
x redis1 'redis-benchmark -h 127.0.0.1 -a ChangeMe_Redis_2026 -q -n 100000 -c 50 -t set,get --threads 2 2>&1 | grep -v Warning'
} 2>&1 | tee results/10-standalone.log
