---
title: Redis 安裝部署 03：Cluster（Redis 7.4 / Rocky Linux 9）
date: 2026-10-24 11:03:00 +0800
categories: [Redis, 安裝部署]
tags: [redis, redis7, rocky-linux, cluster, sharding, failover, ha, dba]
description: 在 Rocky Linux 9 上以 Redis 7.4.11 建立 3 主 3 從的 Redis Cluster，附上 Cluster 節點的 redis.conf（每個參數標明建議值或預設值），並實測 MOVED 重導向、hash tag、主庫當機自動切換、CLUSTER FAILOVER 與整組分片失效，所有輸出皆為實測結果。
---

[Sentinel]({% post_url 2026-10-24-redis-lab-02-sentinel %}) 解決了高可用，但資料仍然要放得進一台機器。資料量或寫入量超過單機上限時，就要用 **Redis Cluster** 把 16384 個 slot 分散到多個主庫。何時該用 Cluster、它帶來哪些限制，請看[容量規劃與擴展]({% post_url 2026-10-24-redis-ops-06-capacity-scaling %})。

{% include redis-ops-series.md %}

{% include redis-lab-env.md %}

## 架構

| 主機 | IP | 初始角色 | slot |
| :--- | :--- | :--- | :--- |
| `rc1` | 192.168.58.31 | 主庫 | 0～5460 |
| `rc2` | 192.168.58.32 | 主庫 | 5461～10922 |
| `rc3` | 192.168.58.33 | 主庫 | 10923～16383 |
| `rc4` | 192.168.58.34 | rc3 的從庫 | — |
| `rc5` | 192.168.58.35 | rc1 的從庫 | — |
| `rc6` | 192.168.58.36 | rc2 的從庫 | — |

- 每台主機一個 Redis，port 6379 給用戶端，**16379（port + 10000）給節點之間的 Cluster Bus**。
- 主從的配對由 `redis-cli --cluster create` 自動決定，它會盡量避免主從在同一台主機（這裡每台都不同，所以沒有問題）。
- 故障判定與選舉都由主庫投票，**至少要 3 個主庫**。

## 步驟 0～2：OS 參數、安裝、使用者與目錄（六台都做）

和 [Standalone 篇]({% post_url 2026-10-24-redis-lab-01-standalone %})的步驟 0～2 完全相同。

防火牆（**未實測**），兩個 port 都要開：

```bash
sudo firewall-cmd --permanent --add-port=6379/tcp --add-port=16379/tcp
sudo firewall-cmd --reload
```

> Cluster Bus（16379）在 7.x 沒有任何驗證，任何連得到這個 port 的主機都能用叢集協定和節點溝通。一定要用防火牆限制只有叢集節點彼此能連。
{: .prompt-danger }

## 步驟 3～4：redis.conf 與啟動（六台）

和 Standalone 的設定檔相比，多了「Cluster」區段，`databases` 改成 1，並加上 `masterauth`（從庫連主庫、切換後舊主庫重新加入都要用）。**不要設 `replicaof`**，主從關係由 Cluster 管理。六台用同一份，只有 `bind` 的 IP 不同。

```conf
# /etc/redis/redis.conf
# Redis 7.4.11 Cluster 節點（rc1~rc6 共用，只有 bind 的 IP 不同）：效能與運維設定
# 以「16 GB RAM、8 vCPU、SSD、專用 Redis 主機、快取為主但重啟後要保留資料」為基準。
# 標「建議」的是調整過的值；標「預設」的是 7.4.11 的預設值（在全新安裝的 7.4.11 上用 CONFIG GET 逐一查過），
# 寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。

# ==================== 網路 ====================
# 建議（預設 * -::*）。只聽內網 IP 與本機，不要對外
bind 192.168.58.31 127.0.0.1 -::1
# 預設
port 6379
# 預設。沒設密碼時拒絕非本機連線，設了 requirepass 也維持 yes
protected-mode yes
# 預設。實際上限受 net.core.somaxconn 限制，OS 要調到 ≥ 這個值
tcp-backlog 511
# 預設（不斷開閒置連線）。由應用端連線池管理；有連線洩漏問題時可設 300
timeout 0
# 預設（秒）。偵測已斷線的對端，避免死連線占用 maxclients
tcp-keepalive 300
# 應用與 Redis 同機時可改用 Unix socket，省去 TCP 協定堆疊的開銷
# unixsocket /run/redis/redis.sock
# unixsocketperm 770

# ==================== 一般 ====================
# 預設。由 systemd 管理，不要 fork 到背景
daemonize no
# 建議（預設 no）。搭配 Type=notify，Redis 載入完資料才回報啟動完成
supervised systemd
# 建議（預設 /var/run/redis.pid）
pidfile /run/redis/redis.pid
# 預設。正式環境不要用 debug / verbose，大量日誌會拖慢效能
loglevel notice
# 建議（預設空字串 = 輸出到 stdout）
logfile /var/log/redis/redis.log
# 建議（預設 16）。Cluster 模式只能用 db 0；設成 16 啟動時會出現「WARNING: Changing databases number from 16 to 1」
databases 1
# 預設
always-show-logo no
# 預設
set-proc-title yes

# ==================== 安全 ====================
# 建議（預設空 = 不驗證）。正式環境改用 ACL 帳號，見安全篇
requirepass "ChangeMe_Redis_2026"
# 危險指令（KEYS、FLUSHALL、DEBUG）建議用 ACL 禁止，見安全篇

# ==================== RDB 快照 ====================
# 預設。1 小時 1 次寫入 / 5 分鐘 100 次 / 1 分鐘 1 萬次就觸發 BGSAVE
save 3600 1 300 100 60 10000
# 預設。BGSAVE 失敗時拒絕寫入，避免在不知情下失去持久化
stop-writes-on-bgsave-error yes
# 預設。LZF 壓縮，CPU 換磁碟空間
rdbcompression yes
# 預設。CRC64 校驗，存檔與載入多約 10% 時間，換來資料完整性
rdbchecksum yes
# 預設
dbfilename dump.rdb
# 預設
rdb-del-sync-files no
# 建議（預設是啟動時的工作目錄）。放在 SSD 上
dir /var/lib/redis

# ==================== AOF ====================
# 建議（預設 no）。RDB + AOF 一起開，當機最多遺失約 1 秒資料
appendonly yes
# 預設
appendfilename "appendonly.aof"
# 預設（7.0+ 多檔 AOF 目錄）
appenddirname "appendonlydir"
# 預設。每秒 fsync 一次，效能與安全的平衡點；always 每次寫入都 fsync，非常慢
appendfsync everysec
# 預設。改 yes 可降低 rewrite 期間的延遲尖峰，但當機可能遺失最多 30 秒資料
no-appendfsync-on-rewrite no
# 預設。AOF 比上次 rewrite 後大 1 倍就重寫
auto-aof-rewrite-percentage 100
# 預設。資料量大時可提高到 1gb，減少 rewrite 次數
auto-aof-rewrite-min-size 64mb
# 預設。AOF 尾端不完整時仍可啟動
aof-load-truncated yes
# 預設。rewrite 後的 base 檔用 RDB 格式，載入快很多
aof-use-rdb-preamble yes
# 預設
aof-timestamp-enabled no
# 預設。rewrite 時每 4 MB fsync 一次，避免一次大量落盤造成延遲
aof-rewrite-incremental-fsync yes
# 預設。同上，針對 RDB
rdb-save-incremental-fsync yes

# ==================== 複製（主從由 Cluster 自動管理，不要設 replicaof） ====================
# 建議。和 requirepass 相同；切換後舊主庫變成從庫時才連得上新主庫
masterauth "ChangeMe_Redis_2026"
# 預設。和主庫斷線或同步中時，從庫仍回應（可能是舊資料）
replica-serve-stale-data yes
# 預設
replica-read-only yes
# 預設。全量同步時 RDB 直接經網路送給從庫，不落主庫磁碟
repl-diskless-sync yes
# 預設（秒）。等更多從庫一起同步
repl-diskless-sync-delay 5
# 建議（預設 0）。設成每個主庫的從庫數，從庫到齊就立即開始，不用等滿 5 秒
repl-diskless-sync-max-replicas 1
# 預設。從庫先把 RDB 存檔再載入；swapdb 較快但同步期間記憶體要兩倍
repl-diskless-load disabled
# 預設（秒）
repl-ping-replica-period 10
# 預設（秒）。要大於 repl-ping-replica-period；大資料量全量同步可調到 120
repl-timeout 60
# 預設。no = 低延遲；yes 省頻寬但從庫延遲增加約 40 ms
repl-disable-tcp-nodelay no
# 建議（預設 1mb）。從庫斷線重連時能部分同步的緩衝；約「寫入量/秒 × 可容忍斷線秒數」
repl-backlog-size 256mb
# 預設（秒）
repl-backlog-ttl 3600
# 預設。越小越優先被選為新主庫；0 = 永遠不會被選上
replica-priority 100
# 預設
replica-announced yes

# ==================== Cluster ====================
# 建議（預設 no）。啟用 Cluster 模式，只能在啟動前設定
cluster-enabled yes
# 預設 nodes.conf。由 Redis 自己維護的叢集狀態檔（放在 dir 底下），不要手動編輯
cluster-config-file nodes-6379.conf
# 預設（0 = port + 10000，即 16379）。節點間的 Cluster Bus，防火牆要一起開
cluster-port 0
# 建議（預設 15000 毫秒）。節點失聯多久判定故障，越小切換越快，但網路抖動時容易誤判
cluster-node-timeout 5000
# 預設。從庫和主庫斷線超過 node-timeout × 10 就不參與選舉；0 = 一律可參選（可用性優先）
cluster-replica-validity-factor 10
# 預設。主庫至少保留 1 個從庫，多的從庫才會遷移給沒有從庫的主庫
cluster-migration-barrier 1
# 預設
cluster-allow-replica-migration yes
# 預設。有 slot 沒人負責時整個叢集停止服務；快取用途可改 no，讓其他 slot 繼續服務
cluster-require-full-coverage yes
# 預設
cluster-replica-no-failover no
# 預設
cluster-allow-reads-when-down no
# 預設
cluster-allow-pubsubshard-when-down yes
# 預設（不限制）。Cluster Bus 單一連線的傳送緩衝上限，大叢集可設 64mb 防止記憶體暴增
cluster-link-sendbuf-limit 0
# 預設。MOVED / ASK 重導向時回傳 IP
cluster-preferred-endpoint-type ip

# ==================== 用戶端 ====================
# 預設。實際上限 = LimitNOFILE - 32，systemd 要設 LimitNOFILE ≥ 10032
maxclients 10000
# 預設
client-output-buffer-limit normal 0 0 0
# 預設。資料量大、全量同步久時要調大，否則從庫會一直重新全量同步
client-output-buffer-limit replica 256mb 64mb 60
# 預設
client-output-buffer-limit pubsub 32mb 8mb 60
# 預設
client-query-buffer-limit 1gb
# 預設。單一 value 上限，實務上 value 應遠小於 1 MB（大 key 會阻塞）
proto-max-bulk-len 512mb
# 預設（不限制）。連線多且有大量輸出緩衝時，可設 5% 之類避免用戶端吃光記憶體
maxmemory-clients 0

# ==================== 記憶體與淘汰 ====================
# 建議（預設 0 = 不限制）。開持久化時抓實體記憶體的 60~65%，預留 fork 的 copy-on-write 與緩衝區
maxmemory 10gb
# 建議（預設 noeviction）。快取用途用 allkeys-lru；當資料庫用（不能丟資料）維持 noeviction
maxmemory-policy allkeys-lru
# 預設。LRU/LFU 抽樣數，10 更接近真正 LRU 但 CPU 多一點
maxmemory-samples 5
# 預設
maxmemory-eviction-tenacity 10
# 預設。從庫不自行淘汰，跟著主庫
replica-ignore-maxmemory yes
# 預設（1~10）。過期 key 很多、記憶體回收不夠快時再調高
active-expire-effort 1

# ==================== Lazy Free（非同步釋放記憶體） ====================
# 刪除大 key 時改在背景執行緒釋放，避免主執行緒卡住。7.x 預設全部是 no，8.x 的 redis.conf 也還是 no，建議全部開
# 建議（預設 no）
lazyfree-lazy-eviction yes
# 建議（預設 no）
lazyfree-lazy-expire yes
# 建議（預設 no）
lazyfree-lazy-server-del yes
# 建議（預設 no）。從庫全量同步時非同步清空舊資料
replica-lazy-flush yes
# 建議（預設 no）。DEL 行為等同 UNLINK
lazyfree-lazy-user-del yes
# 建議（預設 no）。FLUSHALL / FLUSHDB 預設為 ASYNC
lazyfree-lazy-user-flush yes

# ==================== I/O 執行緒 ====================
# 建議（預設 1）。8 vCPU 設 4，保留核心給 fork 子程序與背景執行緒；4 核以下維持 1
io-threads 4
# 預設。7.x 官方說明讀取多執行緒通常幫助不大；8.x 已移除此參數（一律讀寫都用執行緒）
io-threads-do-reads no

# ==================== 核心相關 ====================
# 預設
oom-score-adj no
# 預設。Redis 自己對行程關閉 THP，避免 fork 後 COW 延遲暴增
disable-thp yes

# ==================== Lua / Functions ====================
# 預設（毫秒）。腳本執行超過此時間才開始回 BUSY，腳本本身仍會跑完
busy-reply-threshold 5000

# ==================== 慢查詢與延遲監控 ====================
# 預設（微秒 = 10 ms）。對延遲敏感的服務可降到 1000~5000
slowlog-log-slower-than 10000
# 建議（預設 128）。保留更多慢查詢紀錄，每筆只占少量記憶體
slowlog-max-len 1024
# 建議（預設 0 = 關閉）。記錄超過 100 ms 的事件，LATENCY DOCTOR 才有資料
latency-monitor-threshold 100
# 預設。INFO latencystats 的每指令延遲百分位
latency-tracking yes
# 預設
latency-tracking-info-percentiles 50 99 99.9

# ==================== Keyspace 通知 ====================
# 預設（關閉）。開啟會增加 CPU 負擔，只開需要的事件類型
notify-keyspace-events ""

# ==================== 資料結構編碼（小集合用 listpack 省記憶體） ====================
# 超過門檻會轉成 hashtable / skiplist，記憶體用量變大但大集合操作更快。維持預設即可
# 預設
hash-max-listpack-entries 512
# 預設
hash-max-listpack-value 64
# 預設（每個 quicklist 節點 8 KB）
list-max-listpack-size -2
# 預設（不壓縮）
list-compress-depth 0
# 預設
set-max-intset-entries 512
# 預設
set-max-listpack-entries 128
# 預設
set-max-listpack-value 64
# 預設
zset-max-listpack-entries 128
# 預設
zset-max-listpack-value 64
# 預設
hll-sparse-max-bytes 3000
# 預設
stream-node-max-bytes 4096
# 預設
stream-node-max-entries 100

# ==================== 背景作業 ====================
# 預設。主執行緒每秒用約 1 ms 漸進 rehash，釋放記憶體
activerehashing yes
# 預設。背景任務頻率，連線很多可提高到 100，但會多吃 CPU
hz 10
# 預設。連線多時自動提高 hz
dynamic-hz yes
# 預設。jemalloc 背景執行緒歸還記憶體
jemalloc-bg-thread yes
# 預設
max-new-connections-per-cycle 10

# ==================== 主動碎片整理 ====================
# INFO memory 的 mem_fragmentation_ratio 長期 > 1.5 再開啟，會多用 CPU
# 預設
activedefrag no
# 預設
active-defrag-ignore-bytes 100mb
# 預設（%）
active-defrag-threshold-lower 10
# 預設（%）
active-defrag-threshold-upper 100
# 預設（% CPU）
active-defrag-cycle-min 1
# 預設（% CPU）
active-defrag-cycle-max 25
# 預設
active-defrag-max-scan-fields 1000

# ==================== 關機 ====================
# 預設（秒）。關機前等從庫追上的時間
shutdown-timeout 10
# 預設。SIGTERM 時若有設定 save 會先存 RDB
shutdown-on-sigterm default
```

systemd unit 和 Standalone 篇相同。六台都啟動：

```bash
sudo install -o redis -g redis -m 640 redis-cluster.conf /etc/redis/redis.conf   # 改 bind 的 IP
sudo systemctl enable --now redis
```

```console
[rc1]# cat /var/log/redis/redis.log
89:C 24 Oct 2026 06:39:31.815 * Supervised by systemd. Please make sure you set appropriate values for TimeoutStartSec and TimeoutStopSec in your service unit.
89:C 24 Oct 2026 06:39:31.815 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
89:C 24 Oct 2026 06:39:31.815 * Redis version=7.4.11, bits=64, commit=00000000, modified=0, pid=89, just started
89:C 24 Oct 2026 06:39:31.815 * Configuration loaded
89:M 24 Oct 2026 06:39:31.815 * monotonic clock: POSIX clock_gettime
89:M 24 Oct 2026 06:39:31.815 * Running mode=cluster, port=6379.
89:M 24 Oct 2026 06:39:31.815 * No cluster configuration found, I'm 979b4d733d04379d642e37ae60f775b0bf48a6d6
89:M 24 Oct 2026 06:39:31.818 * Server initialized
89:M 24 Oct 2026 06:39:31.819 * Creating AOF base file appendonly.aof.1.base.rdb on server start
89:M 24 Oct 2026 06:39:31.820 * Creating AOF incr file appendonly.aof.1.incr.aof on server start
89:M 24 Oct 2026 06:39:31.820 * Ready to accept connections tcp

[rc1]# redis-cli cluster info | head -7
cluster_state:fail
cluster_slots_assigned:0
cluster_slots_ok:0
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:1
cluster_size:0

save: 3600 1 300 100 60 10000
client-output-buffer-limit: normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60
bind: 192.168.58.31 127.0.0.1 -::1
compare done
```

此時每個節點都是「只認識自己」的孤立節點，`cluster_state:fail`、`cluster_known_nodes:1` 是正常的。`nodes-6379.conf` 會在第一次啟動時建立，記錄節點 ID。

## 步驟 5：建立叢集

在任一台執行（只要做一次）：

```bash
export REDISCLI_AUTH='ChangeMe_Redis_2026'
redis-cli --cluster create \
  192.168.58.31:6379 192.168.58.32:6379 192.168.58.33:6379 \
  192.168.58.34:6379 192.168.58.35:6379 192.168.58.36:6379 \
  --cluster-replicas 1
```

`--cluster-replicas 1` 表示每個主庫配 1 個從庫；前 3 個成為主庫，後 3 個成為從庫。不加 `--cluster-yes` 時會先列出分配方案，要輸入 `yes` 確認。

```console
[rc1]# redis-cli --cluster create 192.168.58.31:6379 192.168.58.32:6379 192.168.58.33:6379 192.168.58.34:6379 192.168.58.35:6379 192.168.58.36:6379 --cluster-replicas 1 --cluster-yes
>>> Performing hash slots allocation on 6 nodes...
Master[0] -> Slots 0 - 5460
Master[1] -> Slots 5461 - 10922
Master[2] -> Slots 10923 - 16383
Adding replica 192.168.58.35:6379 to 192.168.58.31:6379
Adding replica 192.168.58.36:6379 to 192.168.58.32:6379
Adding replica 192.168.58.34:6379 to 192.168.58.33:6379
M: 979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379
   slots:[0-5460] (5461 slots) master
M: 0f680b74452965edd64704131b5a58c751c37979 192.168.58.32:6379
   slots:[5461-10922] (5462 slots) master
M: 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 192.168.58.33:6379
   slots:[10923-16383] (5461 slots) master
S: b3808706dd552952e1dc42e9ee42ab48ac602f8b 192.168.58.34:6379
   replicates 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf
S: 958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 192.168.58.35:6379
   replicates 979b4d733d04379d642e37ae60f775b0bf48a6d6
S: 71ae48e3a587af3d29044a3f13b4d4b95c8c59a5 192.168.58.36:6379
   replicates 0f680b74452965edd64704131b5a58c751c37979
>>> Nodes configuration updated
>>> Assign a different config epoch to each node
>>> Sending CLUSTER MEET messages to join the cluster
Waiting for the cluster to join
.
>>> Performing Cluster Check (using node 192.168.58.31:6379)
M: 979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379
   slots:[0-5460] (5461 slots) master
   1 additional replica(s)
M: 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 192.168.58.33:6379
   slots:[10923-16383] (5461 slots) master
   1 additional replica(s)
M: 0f680b74452965edd64704131b5a58c751c37979 192.168.58.32:6379
   slots:[5461-10922] (5462 slots) master
   1 additional replica(s)
S: 71ae48e3a587af3d29044a3f13b4d4b95c8c59a5 192.168.58.36:6379
   slots: (0 slots) slave
   replicates 0f680b74452965edd64704131b5a58c751c37979
S: 958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 192.168.58.35:6379
   slots: (0 slots) slave
   replicates 979b4d733d04379d642e37ae60f775b0bf48a6d6
S: b3808706dd552952e1dc42e9ee42ab48ac602f8b 192.168.58.34:6379
   slots: (0 slots) slave
   replicates 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf
[OK] All nodes agree about slots configuration.
>>> Check for open slots...
>>> Check slots coverage...
[OK] All 16384 slots covered.

[rc1]# redis-cli cluster info | head -7
cluster_state:ok
cluster_slots_assigned:16384
cluster_slots_ok:16384
cluster_slots_pfail:0
cluster_slots_fail:0
cluster_known_nodes:6
cluster_size:3

[rc1]# redis-cli cluster nodes | sort -k2
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379 myself,master - 0 0 1 connected 0-5460
0f680b74452965edd64704131b5a58c751c37979 192.168.58.32:6379@16379 master - 0 1792823979000 2 connected 5461-10922
270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 192.168.58.33:6379@16379 master - 0 1792823978939 3 connected 10923-16383
b3808706dd552952e1dc42e9ee42ab48ac602f8b 192.168.58.34:6379@16379 slave 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 0 1792823979151 3 connected
958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 192.168.58.35:6379@16379 slave 979b4d733d04379d642e37ae60f775b0bf48a6d6 0 1792823979571 1 connected
71ae48e3a587af3d29044a3f13b4d4b95c8c59a5 192.168.58.36:6379@16379 slave 0f680b74452965edd64704131b5a58c751c37979 0 1792823979985 2 connected

[rc1]# cat /var/lib/redis/nodes-6379.conf
270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 192.168.58.33:6379@16379,,tls-port=0,shard-id=66e494f24599857b06080446f0010a2c45bca04c master - 1792823976558 1792823974000 3 connected 10923-16383
0f680b74452965edd64704131b5a58c751c37979 192.168.58.32:6379@16379,,tls-port=0,shard-id=b99a660f1fd3dc9552fe32082d54e81834bff54b master - 0 1792823975725 2 connected 5461-10922
71ae48e3a587af3d29044a3f13b4d4b95c8c59a5 192.168.58.36:6379@16379,,tls-port=0,shard-id=b99a660f1fd3dc9552fe32082d54e81834bff54b slave 0f680b74452965edd64704131b5a58c751c37979 0 1792823975829 2 connected
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379,,tls-port=0,shard-id=8be08cf3ec032d9a7000f3078bf076825a1e4d78 myself,master - 0 0 1 connected 0-5460
958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 192.168.58.35:6379@16379,,tls-port=0,shard-id=8be08cf3ec032d9a7000f3078bf076825a1e4d78 slave 979b4d733d04379d642e37ae60f775b0bf48a6d6 0 1792823975725 1 connected
b3808706dd552952e1dc42e9ee42ab48ac602f8b 192.168.58.34:6379@16379,,tls-port=0,shard-id=66e494f24599857b06080446f0010a2c45bca04c slave 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 0 1792823976558 3 connected
vars currentEpoch 6 lastVoteEpoch 0
```

- `nodes-6379.conf` 是 Redis 自己維護的叢集狀態（節點 ID、角色、slot、epoch），**不要手動編輯**，也不要在節點之間複製。
- 重建叢集時要先刪除每個節點的 `nodes-6379.conf` 與資料，否則節點會記得舊的叢集。

## 步驟 6：讀寫驗證

```console
[rc1]# redis-cli -c set user:1001 Jimmy; redis-cli -c get user:1001; redis-cli set user:1001 x; redis-cli cluster keyslot user:1001
OK
Jimmy
MOVED 5712 192.168.58.32:6379

5712

[rc1]# for i in $(seq 1 3000); do echo "SET key:$i $i"; done | redis-cli -c -h 192.168.58.31 >/dev/null 2>&1; for p in 31 32 33 34 35 36; do echo -n "192.168.58.$p "; redis-cli -h 192.168.58.$p info keyspace | grep db0 || echo; done
192.168.58.31 db0:keys=1008,expires=0,avg_ttl=0,subexpiry=0
192.168.58.32 db0:keys=989,expires=0,avg_ttl=0,subexpiry=0
192.168.58.33 db0:keys=1004,expires=0,avg_ttl=0,subexpiry=0
192.168.58.34 db0:keys=1004,expires=0,avg_ttl=0,subexpiry=0
192.168.58.35 db0:keys=1008,expires=0,avg_ttl=0,subexpiry=0
192.168.58.36 db0:keys=989,expires=0,avg_ttl=0,subexpiry=0

[rc1]# redis-cli -c set "{order:1}:items" a; redis-cli -c set "{order:1}:total" 100; redis-cli -c mget "{order:1}:items" "{order:1}:total"; redis-cli -c mget key:1 key:2
OK
OK
a
100
CROSSSLOT Keys in request don't hash to the same slot
```

- 不加 `-c` 時，key 不在這個節點會回 `MOVED <slot> <正確節點>`；加 `-c` 時 `redis-cli` 會自動跟過去。應用程式要用支援 Cluster 的用戶端。
- 3000 個 key 平均分散在三個分片（1008 / 989 / 1004），從庫的 key 數和主庫相同。
- `MGET key:1 key:2` 因為兩個 key 在不同 slot 回 `CROSSSLOT`；用 hash tag `{order:1}` 讓相關的 key 落在同一個 slot，多 key 指令才能使用。

## 測試 1：主庫無回應（自動切換）

凍結 rc1（主庫，slot 0～5460）：

```console
[rc1]# redis-cli cluster nodes | grep myself
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379 myself,master - 0 0 1 connected 0-5460

# 14:39:41（主機端）docker compose pause rc1
# 14:39:49 rc5 已升為主庫（主庫凍結後 8 秒，rc1 狀態：master,fail）
[rc2]# redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok|cluster_slots_fail|cluster_known_nodes"
cluster_state:ok
cluster_slots_ok:16384
cluster_slots_fail:0
cluster_known_nodes:6

[rc2]# redis-cli cluster nodes | sort -k2
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379 master,fail - 1792823983709 1792823981138 1 connected
0f680b74452965edd64704131b5a58c751c37979 192.168.58.32:6379@16379 myself,master - 0 0 2 connected 5461-10922
270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 192.168.58.33:6379@16379 master - 0 1792823989000 3 connected 10923-16383
b3808706dd552952e1dc42e9ee42ab48ac602f8b 192.168.58.34:6379@16379 slave 270aa376e8ebecbe013ced7f8f2e2be5eb81cdaf 0 1792823989586 3 connected
958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 192.168.58.35:6379@16379 master - 0 1792823989000 7 connected 0-5460
71ae48e3a587af3d29044a3f13b4d4b95c8c59a5 192.168.58.36:6379@16379 slave 0f680b74452965edd64704131b5a58c751c37979 0 1792823989379 2 connected

[rc5]# grep -E "FAIL message|Failover|election|failover|Starting|configEpoch|Setting myself" /var/log/redis/redis.log | tail -10
82:M 24 Oct 2026 06:39:33.053 * configEpoch set to 5 via CLUSTER SET-CONFIG-EPOCH
82:S 24 Oct 2026 06:39:48.986 * Start of election delayed for 812 milliseconds (rank #0, offset 36571).
82:S 24 Oct 2026 06:39:49.821 * Starting a failover election for epoch 7.
82:S 24 Oct 2026 06:39:49.824 * Failover election won: I'm the new master.
82:S 24 Oct 2026 06:39:49.824 * configEpoch set to 7 after successful failover

[rc2]# redis-cli -c get key:1; redis-cli -c get user:1001; redis-cli -c set after:failover 1
1
Jimmy
OK
```

| 時間 | 事件 |
| :--- | :--- |
| 06:39:41 | rc1 凍結 |
| 約 06:39:46～47 | 其他節點超過 `cluster-node-timeout 5000` 收不到 rc1 的回應，標為 PFAIL，過半數主庫同意後升為 FAIL |
| 06:39:48.986 | rc5 收到 FAIL，選舉延遲 812 ms（rank #0：在同一個主庫的從庫中複製進度最新，延遲最短） |
| 06:39:49.824 | rc5 當選，接手 slot 0～5460 |

從主庫失聯到新主庫接手約 **8 秒**（`cluster-node-timeout` 預設 15000 時會是 18 秒以上）。切換期間這段 slot 的讀寫會失敗，切換後原本的資料都還在。

## 測試 2：舊主庫恢復與計畫內切換（CLUSTER FAILOVER）

```console
# 14:39:50（主機端）docker compose unpause rc1
[rc1]# redis-cli cluster nodes | grep myself; redis-cli info replication | head -6
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379 myself,slave 958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 0 0 7 connected
# Replication
role:slave
master_host:192.168.58.35
master_port:6379
master_link_status:up
master_last_io_seconds_ago:5

[rc1]# grep -E "Configuration change|Clear FAIL|MASTER <-> REPLICA sync|Connecting to MASTER" /var/log/redis/redis.log | tail -5
89:M 24 Oct 2026 06:39:50.348 * Configuration change detected. Reconfiguring myself as a replica of 958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 ()
89:S 24 Oct 2026 06:39:50.348 * Connecting to MASTER 192.168.58.35:6379
89:S 24 Oct 2026 06:39:50.348 * MASTER <-> REPLICA sync started
89:S 24 Oct 2026 06:39:50.351 * MASTER <-> REPLICA sync: Master accepted a Partial Resynchronization.


# --- 在 rc1（現在是從庫）執行計畫內切換，把主庫角色拿回來
[rc1]# redis-cli cluster failover; sleep 3; redis-cli cluster nodes | grep myself; redis-cli info replication | head -4
OK
979b4d733d04379d642e37ae60f775b0bf48a6d6 192.168.58.31:6379@16379 myself,master - 0 0 8 connected 0-5460
# Replication
role:master
connected_slaves:1
slave0:ip=192.168.58.35,port=6379,state=online,offset=36649,lag=0

[rc1]# grep -E "Manual failover|failover" /var/log/redis/redis.log | tail -6
89:S 24 Oct 2026 06:39:58.659 * Received replication offset for paused master manual failover: 36649
89:S 24 Oct 2026 06:39:58.659 * All master replication stream processed, manual failover can start.
89:S 24 Oct 2026 06:39:58.659 * Starting a failover election for epoch 8.
89:S 24 Oct 2026 06:39:58.666 * Currently unable to failover: Waiting for votes, but majority still not reached.
89:S 24 Oct 2026 06:39:58.666 * configEpoch set to 8 after successful failover
89:M 24 Oct 2026 06:39:58.769 * A failover occurred in shard 8be08cf3ec032d9a7000f3078bf076825a1e4d78; node 958ccf9ac0dbe194b9d5f4ead74aa8ab5d4febf5 () lost 0 slot(s) to node 979b4d733d04379d642e37ae60f775b0bf48a6d6 () with a config epoch of 8
```

- rc1 恢復後發現自己的 slot 已經被 epoch 更大的 rc5 接手，自動變成 rc5 的從庫，而且是**部分同步**（`Partial Resynchronization`），不需要整份資料重傳。
- 在從庫上執行 `CLUSTER FAILOVER`（不加參數）是安全的計畫內切換：主庫先暫停寫入，等從庫追上複製進度（`All master replication stream processed`）才切換，**不會遺失資料**，在同一秒內完成。日誌中間的 `Waiting for votes, but majority still not reached` 只是還在收集選票，7 ms 後就成功了。
- 維護主庫時就用這個方式：先在從庫執行 `CLUSTER FAILOVER`，再停舊主庫。

## 測試 3：同一組主從一起掛掉

凍結 rc2 和它的從庫 rc6，slot 5461～10922 完全沒有可用的節點：

```console
# rc2 的從庫是 rc6
# 14:40:02（主機端）docker compose pause rc2 rc6
[rc1]# redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok|cluster_slots_fail"; redis-cli -c get key:1; redis-cli -c get key:2
cluster_state:fail
cluster_slots_ok:10922
cluster_slots_fail:5462
CLUSTERDOWN The cluster is down

CLUSTERDOWN The cluster is down


# 14:40:14（主機端）docker compose unpause rc2 rc6
[rc1]# redis-cli cluster info | grep -E "cluster_state|cluster_slots_ok"; redis-cli -c get key:1
cluster_state:ok
cluster_slots_ok:16384
1
```

- `cluster-require-full-coverage yes`（預設）：只要有一個 slot 沒人負責，**整個叢集停止服務**，連其他分片上的 key 也讀不到（`CLUSTERDOWN`）。
- 快取用途、寧可部分可用時，可以改成 `no`，讓其他分片繼續服務。
- 兩台恢復後叢集回到 `ok`。這次這一組的主庫變成 rc6：兩台同時恢復時，其他主庫仍把 rc2 標為 FAIL，rc6 先發起選舉並勝出，rc2 則成為它的從庫。
- 這個測試說明了為什麼**主從不能放在同一台實體機**：一台機器壞掉就等於這個測試。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| 每個節點啟動時記錄 `WARNING: Changing databases number from 16 to 1 since we are in cluster mode` | Cluster 只支援 db 0，設定檔沿用了 `databases 16` | Cluster 節點設 `databases 1`（本文設定檔已修正） |
| 不加 `-c` 回 `MOVED` | key 不在連線的節點 | `redis-cli -c`；應用程式用 Cluster 用戶端 |
| `CROSSSLOT Keys in request don't hash to the same slot` | 多 key 指令的 key 在不同 slot | hash tag |
| 計畫內切換日誌出現 `Currently unable to failover: Waiting for votes` | 正在收集其他主庫的選票 | 不用處理，隨後就會成功 |

## 驗證方式與結果

驗證環境、建置檔與 [Standalone 篇]({% post_url 2026-10-24-redis-lab-01-standalone %})相同（MacBook Air M4、Docker Desktop、Rocky Linux 9 容器 + systemd），rc1～rc6 用照步驟 1 編譯好 Redis 7.4.11 的映像，其餘步驟在容器內照文章執行。腳本是 `tools/redis-lab/30-cluster.sh`。

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 3~4 啟動 | `systemctl is-active`、`redis.log` | 六台 `active`、`Running mode=cluster` | ✅ |
| 3 設定檔 | 逐項 `CONFIG GET` 比對 | 實際值與設定檔一致 | ✅ 0 項不同 |
| 5 建立叢集 | `CLUSTER INFO`、`--cluster check` | `cluster_state:ok`、16384 個 slot 全部涵蓋 | ✅ |
| 6 讀寫 | `-c` 讀寫、key 分布、hash tag | `MOVED` 正確、3 個分片平均、hash tag 可 `MGET` | ✅ |
| 測試 1 | `docker pause` 主庫 | 從庫升級、slot 全部可用、資料仍在 | ✅ 8 秒 |
| 測試 2 | 恢復舊主庫、`CLUSTER FAILOVER` | 舊主庫變從庫且部分同步；手動切換不遺失資料 | ✅ 1 秒內 |
| 測試 3 | 同時 `docker pause` 一組主從 | `cluster_state:fail`、`CLUSTERDOWN`；恢復後 `ok` | ✅ |
| 日誌 | `grep WARNING` | 六台都沒有 WARNING | ✅（改 `databases 1` 之後） |

**錯誤處理紀錄**：

- 第一次執行用的是 `databases 16`，六台都出現上面那行 WARNING，`CONFIG GET databases` 也是 1。設定檔改成 `databases 1` 後整個流程重跑一次，沒有任何 WARNING，文中的輸出都來自重跑的結果。
- 兩次執行的切換時間：第一次 9 秒（選舉延遲 919 ms）、第二次 8 秒（812 ms），輪詢間隔是 1 秒，日誌的毫秒時間戳記較精確。

## 版本差異比較：7.4.11 vs 8.10.2

| 項目 | 7.4.11 | 8.10.2 |
| :--- | :--- | :--- |
| Cluster Bus 驗證 | 無，也不會提醒 | 未開 `tls-cluster` 時啟動會警告（實測，見下方）；`cluster-bus-port-protected-mode yes` 可強制要求 TLS |
| slot 搬遷 | `MIGRATE` 逐 key 搬 | 8.4 起 `CLUSTER MIGRATION` 原子搬遷；8.10 起 `redis-cli --cluster reshard / rebalance` 改用它 |
| 新參數 | — | `cluster-slot-migration-write-pause-timeout 10000`、`cluster-slot-migration-handoff-max-lag-bytes 1mb`、`cluster-slot-stats-enabled no`、`cluster-compatibility-sample-ratio 0` |
| slot 觀測 | 無 | `CLUSTER SLOT-STATS`（每個 slot 的 key 數、CPU、網路） |
| 沒設密碼的提醒 | 無 | 實測 8.10.2 沒設密碼時會多一行 `Redis does not require authentication` 的 WARNING |
| 內建模組 | 無 | 搜尋（`FT.*`）在 Cluster 上可跨分片查詢 |

兩版各啟動一個 Cluster 模式的節點（不帶設定檔，所以兩邊都有 `databases` 的警告）：

```console
[rc1]# mkdir -p /tmp/c8 /tmp/c7; /usr/local/src/redis-8.10.2/src/redis-server --port 7000 --cluster-enabled yes --dir /tmp/c8 --daemonize yes --logfile /tmp/c8/log >/dev/null; redis-server --port 7001 --cluster-enabled yes --dir /tmp/c7 --daemonize yes --logfile /tmp/c7/log >/dev/null; sleep 1; echo "== 8.10.2"; grep -E "WARNING|# " /tmp/c8/log; echo "== 7.4.11"; grep -E "WARNING|# " /tmp/c7/log || echo "(no warnings)"; env -u REDISCLI_AUTH redis-cli -p 7000 config get cluster-bus-port-protected-mode; env -u REDISCLI_AUTH redis-cli -p 7000 shutdown nosave; env -u REDISCLI_AUTH redis-cli -p 7001 shutdown nosave
== 8.10.2
6558:C 24 Oct 2026 06:41:39.030 # WARNING: Changing databases number from 16 to 1 since we are in cluster mode
6558:C 24 Oct 2026 06:41:39.030 # WARNING: the cluster bus port is not authenticated: 'tls-cluster' is disabled and protected mode was waived with 'cluster-bus-port-protected-mode no'. Any host able to reach the cluster bus port can speak the cluster protocol, so make sure the port is reachable by trusted hosts only.
6560:M 24 Oct 2026 06:41:39.055 # WARNING: Redis does not require authentication. Redis will accept connections from any local client.
== 7.4.11
6561:C 24 Oct 2026 06:41:39.031 # WARNING: Changing databases number from 16 to 1 since we are in cluster mode
cluster-bus-port-protected-mode
no
```

> 7.4 的 Cluster Bus 沒有任何驗證，8.10.2 只是**把風險明確寫進日誌**，預設仍然允許。不論哪一版，都要用防火牆把 16379 限制在叢集節點之間；跨網段部署時開 `tls-cluster`。
{: .prompt-warning }

## 小結

- 至少 3 主 3 從；主從不能在同一台實體機。6379 與 16379 都要開，但 16379 只開給叢集節點。
- Cluster 節點設 `databases 1`，不要設 `replicaof`；`nodes-6379.conf` 由 Redis 自己維護。
- `cluster-node-timeout 5000` 讓自動切換在約 8 秒內完成；維護時用 `CLUSTER FAILOVER` 做無損切換。
- 一組主從都掛掉時，預設整個叢集停止服務（`cluster-require-full-coverage yes`）。
- 應用程式要用支援 Cluster 的用戶端，多 key 操作用 hash tag。

這三篇實作完成了 Redis 的安裝部署。接下來回到運維系列：[備份與還原]({% post_url 2026-10-24-redis-ops-02-backup-restore %})。

### 參考資料

- [Scale with Redis Cluster](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)
- [Redis cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/)
- [CLUSTER FAILOVER](https://redis.io/docs/latest/commands/cluster-failover/)
- [Redis 8.10 release notes](https://github.com/redis/redis/blob/8.10/00-RELEASENOTES)
