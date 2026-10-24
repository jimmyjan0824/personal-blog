#!/usr/bin/env bash
# Cluster：rc1~rc6，3 主 3 從。照文章步驟操作並做故障切換測試
source "$(dirname "$0")/lib.sh"
N="rc1 rc2 rc3 rc4 rc5 rc6"
docker compose rm -sf $N >/dev/null 2>&1; docker compose up -d $N; sleep 5
ip() { echo 192.168.58.3${1#rc}; }
role_of() { docker compose exec -T $1 redis-cli -a ChangeMe_Redis_2026 --no-auth-warning info replication | grep '^role:' | tr -d '\r' | cut -d: -f2; }
{
note "環境"
x rc1 'cat /etc/rocky-release; redis-server --version'

note "步驟 0~4：OS 參數、使用者與目錄、redis.conf、systemd（六台都做）"
for n in $N; do
  x $n "mkdir -p /etc/sysctl.d && cp /root/conf/99-redis.conf /etc/sysctl.d/ && sysctl -p /etc/sysctl.d/99-redis.conf >/dev/null && groupadd -r redis && useradd -r -g redis -s /sbin/nologin -d /var/lib/redis redis && mkdir -p /etc/redis /var/lib/redis /var/log/redis && chown -R redis:redis /etc/redis /var/lib/redis /var/log/redis && chmod 750 /etc/redis /var/lib/redis /var/log/redis && install -o redis -g redis -m 640 /root/conf/redis-cluster.conf /etc/redis/redis.conf && sed -i 's/^bind 192.168.58.31 /bind $(ip $n) /' /etc/redis/redis.conf && cp /root/conf/redis.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now redis && systemctl is-active redis && grep '^bind' /etc/redis/redis.conf"
done
x rc1 'cat /var/log/redis/redis.log'
x rc1 'redis-cli cluster info | head -7'
cmpconf rc1 /etc/redis/redis.conf

note "步驟 5：建立叢集"
x rc1 'redis-cli --cluster create 192.168.58.31:6379 192.168.58.32:6379 192.168.58.33:6379 192.168.58.34:6379 192.168.58.35:6379 192.168.58.36:6379 --cluster-replicas 1 --cluster-yes'
sleep 5
x rc1 'redis-cli cluster info | head -7'
x rc1 'redis-cli cluster nodes | sort -k2'
x rc1 'redis-cli --cluster check 192.168.58.31:6379'
x rc1 'cat /var/lib/redis/nodes-6379.conf'

note "資料寫入：-c 跟隨 MOVED 重導向"
x rc1 'redis-cli -c set user:1001 Jimmy; redis-cli -c get user:1001; redis-cli set user:1001 x; redis-cli cluster keyslot user:1001'
x rc1 'for i in $(seq 1 3000); do echo "SET key:$i $i"; done | redis-cli -c -h 192.168.58.31 >/dev/null 2>&1; for p in 31 32 33 34 35 36; do echo -n "192.168.58.$p "; redis-cli -h 192.168.58.$p info keyspace | grep db0 || echo; done'
x rc1 'redis-cli -c set "{order:1}:items" a; redis-cli -c set "{order:1}:total" 100; redis-cli -c mget "{order:1}:items" "{order:1}:total"; redis-cli -c mget key:1 key:2'

note "測試 1：主庫無回應（docker pause rc1）"
x rc1 'redis-cli cluster nodes | grep myself'
T0=$(date +%s); echo "$(date '+%T') docker compose pause rc1"; docker compose pause rc1
for i in $(seq 1 60); do
  st=$(docker compose exec -T rc2 redis-cli -a ChangeMe_Redis_2026 --no-auth-warning cluster nodes | grep 192.168.58.31 | awk '{print $3}')
  newm=$(for n in rc4 rc5 rc6; do [ "$(role_of $n)" = "master" ] && echo $n; done)
  if [ -n "$newm" ]; then echo "$(date '+%T') $newm 已升為主庫，經過 $(( $(date +%s)-T0 )) 秒（rc1 狀態：$st）"; break; fi
  sleep 1
done
x rc2 'redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok|cluster_slots_fail|cluster_known_nodes"'
x rc2 'redis-cli cluster nodes | sort -k2'
x $newm 'grep -E "FAIL message|Failover|election|failover|Starting|configEpoch|Setting myself" /var/log/redis/redis.log | tail -10'
x rc2 'redis-cli -c get key:1; redis-cli -c get user:1001; redis-cli -c set after:failover 1'
note "rc1 恢復後自動變成從庫"
echo "$(date '+%T') docker compose unpause rc1"; docker compose unpause rc1; sleep 8
x rc1 'redis-cli cluster nodes | grep myself; redis-cli info replication | head -6'
x rc1 'grep -E "Configuration change|Clear FAIL|MASTER <-> REPLICA sync|Connecting to MASTER" /var/log/redis/redis.log | tail -5'

note "測試 2：計畫內切換 CLUSTER FAILOVER（在 rc1 執行，把主庫角色拿回來）"
x rc1 'redis-cli cluster failover; sleep 3; redis-cli cluster nodes | grep myself; redis-cli info replication | head -4'
x rc1 'grep -E "Manual failover|failover" /var/log/redis/redis.log | tail -6'

note "測試 3：同一組主從都掛掉 → 叢集失去 slot 覆蓋，cluster-require-full-coverage yes 讓整個叢集停止服務"
M2=rc2; R2=$(docker compose exec -T rc2 redis-cli -a ChangeMe_Redis_2026 --no-auth-warning cluster nodes | grep myself | awk '{print $1}')
R2N=$(for n in rc4 rc5 rc6; do docker compose exec -T $n redis-cli -a ChangeMe_Redis_2026 --no-auth-warning cluster nodes | grep myself | grep -q "$R2" && echo $n; done)
echo "rc2 的從庫是 $R2N"
docker compose pause rc2 $R2N; echo "$(date '+%T') docker compose pause rc2 $R2N"; sleep 12
x rc1 'redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok|cluster_slots_fail"; redis-cli -c get key:1; redis-cli -c get key:2'
docker compose unpause rc2 $R2N; echo "$(date '+%T') docker compose unpause rc2 $R2N"; sleep 10
x rc1 'redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok"; redis-cli -c get key:1'
note "最後狀態"
x rc1 'redis-cli --cluster check 192.168.58.31:6379 | head -12'
for n in $N; do x $n 'grep -E "WARNING" /var/log/redis/redis.log || echo "(no warnings)"'; done
} 2>&1 | tee results/30-cluster.log
