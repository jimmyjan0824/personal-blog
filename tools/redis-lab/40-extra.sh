#!/usr/bin/env bash
# 補充驗證：(a) redis.conf 行尾註解 (b) appendonly yes 時從 RDB 還原的陷阱 (c) 8.10.2 Cluster 啟動警告
source "$(dirname "$0")/lib.sh"
docker compose rm -sf rc1 >/dev/null 2>&1; docker compose up -d rc1; sleep 5
{
note "(a) redis.conf 不支援行尾註解"
x rc1 'printf "port 6390                                   # 預設\n" > /tmp/bad.conf; cat /tmp/bad.conf; redis-server /tmp/bad.conf; echo "exit=$?"'

note "(b) 從 RDB 還原：appendonly yes 時 Redis 只讀 AOF"
x rc1 'mkdir -p /tmp/src && cd /tmp/src && redis-server --port 6391 --dir /tmp/src --appendonly no --daemonize yes --logfile /tmp/src/log >/dev/null; sleep 1; for i in $(seq 1 1000); do echo "SET k:$i $i"; done | env -u REDISCLI_AUTH redis-cli -p 6391 >/dev/null; env -u REDISCLI_AUTH redis-cli -p 6391 dbsize; env -u REDISCLI_AUTH redis-cli -p 6391 save; env -u REDISCLI_AUTH redis-cli -p 6391 shutdown; ls -l /tmp/src/dump.rdb'
echo "--- 錯誤做法：只放 dump.rdb，用 appendonly yes 啟動"
x rc1 'mkdir -p /tmp/bad && cp /tmp/src/dump.rdb /tmp/bad/ && redis-server --port 6392 --dir /tmp/bad --appendonly yes --daemonize yes --logfile /tmp/bad/log >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6392 dbsize; grep -E "AOF|DB loaded" /tmp/bad/log; env -u REDISCLI_AUTH redis-cli -p 6392 shutdown nosave'
echo "--- 正確做法：先 appendonly no 載入 RDB，再線上開 AOF"
x rc1 'mkdir -p /tmp/good && cp /tmp/src/dump.rdb /tmp/good/ && redis-server --port 6393 --dir /tmp/good --appendonly no --daemonize yes --logfile /tmp/good/log >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6393 dbsize; env -u REDISCLI_AUTH redis-cli -p 6393 config set appendonly yes; sleep 2; env -u REDISCLI_AUTH redis-cli -p 6393 info persistence | grep -E "aof_enabled|aof_rewrite_in_progress|aof_last_bgrewrite_status"; ls /tmp/good/appendonlydir; env -u REDISCLI_AUTH redis-cli -p 6393 shutdown'
x rc1 'redis-server --port 6393 --dir /tmp/good --appendonly yes --daemonize yes --logfile /tmp/good/log2 >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6393 dbsize; grep -E "DB loaded" /tmp/good/log2; env -u REDISCLI_AUTH redis-cli -p 6393 shutdown nosave'

note "(c) 8.10.2 Cluster 節點啟動時的 Cluster Bus 警告（對照 7.4.11）"
x rc1 'dnf install -y -q gcc make tar gzip >/dev/null 2>&1; cd /usr/local/src && curl -fsSLO https://download.redis.io/releases/redis-8.10.2.tar.gz && tar xzf redis-8.10.2.tar.gz && cd redis-8.10.2 && make -j"$(nproc)" build redis >/tmp/m.log 2>&1; echo rc=$?; src/redis-server --version'
x rc1 'mkdir -p /tmp/c8 /tmp/c7; /usr/local/src/redis-8.10.2/src/redis-server --port 7000 --cluster-enabled yes --dir /tmp/c8 --daemonize yes --logfile /tmp/c8/log >/dev/null; redis-server --port 7001 --cluster-enabled yes --dir /tmp/c7 --daemonize yes --logfile /tmp/c7/log >/dev/null; sleep 1; echo "== 8.10.2"; grep -E "WARNING|# " /tmp/c8/log; echo "== 7.4.11"; grep -E "WARNING|# " /tmp/c7/log || echo "(no warnings)"; env -u REDISCLI_AUTH redis-cli -p 7000 config get cluster-bus-port-protected-mode; env -u REDISCLI_AUTH redis-cli -p 7000 shutdown nosave; env -u REDISCLI_AUTH redis-cli -p 7001 shutdown nosave'
} 2>&1 | tee results/40-extra.log
docker compose rm -sf rc1 >/dev/null 2>&1
