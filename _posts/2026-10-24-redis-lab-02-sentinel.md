---
title: Redis 安裝部署 02：Sentinel（Redis 7.4 / Rocky Linux 9）
date: 2026-10-24 11:02:00 +0800
categories: [Redis, 安裝部署]
tags: [redis, redis7, rocky-linux, sentinel, replication, failover, ha, dba]
description: 在 Rocky Linux 9 上以 Redis 7.4.11 建立 1 主 2 從 + 3 Sentinel，附上資料節點的 redis.conf 與 sentinel.conf（每個參數標明建議值或預設值），並實測計畫內切換、主庫當機自動切換與 min-replicas-to-write，所有輸出皆為實測結果。
---

[Standalone]({% post_url 2026-10-24-redis-lab-01-standalone %}) 一篇完成了單機安裝，這篇加上從庫與 Sentinel，讓主庫掛掉時能自動切換。原理請看[高可用與災難復原]({% post_url 2026-10-24-redis-ops-03-ha-dr %})。

{% include redis-ops-series.md %}

{% include redis-lab-env.md %}

## 架構

| 主機 | IP | Redis（6379） | Sentinel（26379） |
| :--- | :--- | :--- | :--- |
| `rs1` | 192.168.58.21 | 主庫（初始） | ✅ |
| `rs2` | 192.168.58.22 | 從庫 | ✅ |
| `rs3` | 192.168.58.23 | 從庫 | ✅ |

- 三台都跑一個 Redis 與一個 Sentinel，主機規格和 Standalone 篇相同（16 GB RAM、8 vCPU）。
- Sentinel `quorum = 2`：3 台中有 2 台認為主庫掛了才切換；選出執行切換的 leader 也需要過半數（2 台），所以**任何一台主機掛掉都還能完成切換**。
- 正式環境的 3 台要分散在不同的實體機、機櫃或可用區。

## 步驟 0～2：OS 參數、安裝、使用者與目錄（三台都做）

OS 參數與安裝步驟和 [Standalone 篇]({% post_url 2026-10-24-redis-lab-01-standalone %})的步驟 0、1 完全相同。使用者與目錄多一個 Sentinel 的工作目錄：

```bash
sudo groupadd -r redis
sudo useradd -r -g redis -s /sbin/nologin -d /var/lib/redis redis
sudo mkdir -p /etc/redis /var/lib/redis /var/lib/redis-sentinel /var/log/redis
sudo chown -R redis:redis /etc/redis /var/lib/redis /var/lib/redis-sentinel /var/log/redis
sudo chmod 750 /etc/redis /var/lib/redis /var/lib/redis-sentinel /var/log/redis
```

> `/etc/redis` 目錄一定要讓 `redis` 使用者可寫。切換時 Sentinel 會改寫 `sentinel.conf`，也會讓 Redis 執行 `CONFIG REWRITE` 改寫 `redis.conf` 的 `replicaof`。兩者都是先寫暫存檔再改名，只有檔案可寫、目錄不可寫也會失敗。
{: .prompt-warning }

防火牆（**未實測**）：

```bash
sudo firewall-cmd --permanent --add-port=6379/tcp --add-port=26379/tcp
sudo firewall-cmd --reload
```

## 步驟 3：redis.conf（三台）

和 Standalone 的設定檔相比，差別在「複製」區段：所有節點都設 `masterauth`（切換後舊主庫變成從庫時要用），並加上 `min-replicas-to-write` 降低腦裂時的資料遺失。三台用同一份，只有 `bind` 的 IP 不同。

```conf
# /etc/redis/redis.conf
# Redis 7.4.11 Sentinel 架構的資料節點（rs1~rs3 共用，只有 bind 的 IP 不同）：效能與運維設定
# 以「16 GB RAM、8 vCPU、SSD、專用 Redis 主機、快取為主但重啟後要保留資料」為基準。
# 標「建議」的是調整過的值；標「預設」的是 7.4.11 的預設值（在全新安裝的 7.4.11 上用 CONFIG GET 逐一查過），
# 寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。
# 注意：Sentinel 切換時會用 CONFIG REWRITE 改寫這個檔案，/etc/redis 目錄與檔案都要讓 redis 使用者可寫。

# ==================== 網路 ====================
# 建議（預設 * -::*）。只聽內網 IP 與本機，不要對外
bind 192.168.58.21 127.0.0.1 -::1
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
# 預設。新專案只用 db 0，Cluster 也只支援 db 0
databases 16
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

# ==================== 複製 ====================
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
# 建議（預設 0）。設成從庫數，全部從庫到齊就立即開始，不用等滿 5 秒
repl-diskless-sync-max-replicas 2
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
# 建議（預設 0）。至少 1 台從庫延遲 ≤ min-replicas-max-lag 才接受寫入，降低腦裂時舊主庫寫入遺失
min-replicas-to-write 1
# 預設（秒）
min-replicas-max-lag 10

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

rs2、rs3 在檔尾加上：

```conf
replicaof 192.168.58.21 6379
```

```console
[rs1]# install -o redis -g redis -m 640 /root/conf/redis-sentinel.conf /etc/redis/redis.conf && sed -i 's/^bind 192.168.58.21 /bind 192.168.58.21 /' /etc/redis/redis.conf && grep '^bind' /etc/redis/redis.conf
bind 192.168.58.21 127.0.0.1 -::1

[rs2]# install -o redis -g redis -m 640 /root/conf/redis-sentinel.conf /etc/redis/redis.conf && sed -i 's/^bind 192.168.58.21 /bind 192.168.58.22 /' /etc/redis/redis.conf && grep '^bind' /etc/redis/redis.conf
bind 192.168.58.22 127.0.0.1 -::1

[rs3]# install -o redis -g redis -m 640 /root/conf/redis-sentinel.conf /etc/redis/redis.conf && sed -i 's/^bind 192.168.58.21 /bind 192.168.58.23 /' /etc/redis/redis.conf && grep '^bind' /etc/redis/redis.conf
bind 192.168.58.23 127.0.0.1 -::1

[rs2]# echo 'replicaof 192.168.58.21 6379' >> /etc/redis/redis.conf && tail -1 /etc/redis/redis.conf
replicaof 192.168.58.21 6379

[rs3]# echo 'replicaof 192.168.58.21 6379' >> /etc/redis/redis.conf && tail -1 /etc/redis/redis.conf
replicaof 192.168.58.21 6379
```

## 步驟 4：啟動 Redis（先主後從）

systemd unit 和 Standalone 篇相同（`/etc/systemd/system/redis.service`）。

```bash
sudo systemctl enable --now redis      # rs1 → rs2 → rs3
```

```console
[rs1]# cp /root/conf/redis.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now redis && systemctl is-active redis
Created symlink /etc/systemd/system/multi-user.target.wants/redis.service → /etc/systemd/system/redis.service.
active

[rs1]# redis-cli info replication
# Replication
role:master
connected_slaves:2
min_slaves_good_slaves:2
slave0:ip=192.168.58.22,port=6379,state=online,offset=0,lag=0
slave1:ip=192.168.58.23,port=6379,state=online,offset=0,lag=1
master_failover_state:no-failover
master_replid:cdf63b448c4c8b4d90187de83bd415e427af3f47
master_replid2:0000000000000000000000000000000000000000
master_repl_offset:0
second_repl_offset:-1
repl_backlog_active:1
repl_backlog_size:268435456
repl_backlog_first_byte_offset:1
repl_backlog_histlen:0

[rs2]# redis-cli info replication | head -12
# Replication
role:slave
master_host:192.168.58.21
master_port:6379
master_link_status:up
master_last_io_seconds_ago:3
master_sync_in_progress:0
slave_read_repl_offset:0
slave_repl_offset:0
slave_priority:100
slave_read_only:1
replica_announced:1

[rs1]# grep -E "Replica .* asks|Synchronization with replica|Starting BGSAVE|diskless|succeeded" /var/log/redis/redis.log
102:M 24 Oct 2026 06:33:57.997 * Replica 192.168.58.22:6379 asks for synchronization
102:M 24 Oct 2026 06:33:57.998 * Delay next BGSAVE for diskless SYNC
102:M 24 Oct 2026 06:33:58.139 * Replica 192.168.58.23:6379 asks for synchronization
102:M 24 Oct 2026 06:33:58.139 * Delay next BGSAVE for diskless SYNC
102:M 24 Oct 2026 06:33:58.919 * Starting BGSAVE for SYNC with target: replicas sockets
102:M 24 Oct 2026 06:33:58.927 * Streamed RDB transfer with replica 192.168.58.22:6379 succeeded (socket). Waiting for REPLCONF ACK from replica to enable streaming
102:M 24 Oct 2026 06:33:58.927 * Synchronization with replica 192.168.58.22:6379 succeeded
102:M 24 Oct 2026 06:33:58.927 * Streamed RDB transfer with replica 192.168.58.23:6379 succeeded (socket). Waiting for REPLCONF ACK from replica to enable streaming
102:M 24 Oct 2026 06:33:58.927 * Synchronization with replica 192.168.58.23:6379 succeeded

[rs2]# grep -E "MASTER <-> REPLICA|Connecting to MASTER|Loading|Finished|Successful" /var/log/redis/redis.log
100:S 24 Oct 2026 06:33:57.997 * Connecting to MASTER 192.168.58.21:6379
100:S 24 Oct 2026 06:33:57.997 * MASTER <-> REPLICA sync started
100:S 24 Oct 2026 06:33:58.921 * MASTER <-> REPLICA sync: receiving streamed RDB from master with EOF to disk
100:S 24 Oct 2026 06:33:58.921 * MASTER <-> REPLICA sync: Flushing old data
100:S 24 Oct 2026 06:33:58.922 * MASTER <-> REPLICA sync: Loading DB in memory
100:S 24 Oct 2026 06:33:58.926 * Loading RDB produced by version 7.4.11
100:S 24 Oct 2026 06:33:58.926 * MASTER <-> REPLICA sync: Finished with success
111:C 24 Oct 2026 06:33:58.929 * Successfully created the temporary AOF base file temp-rewriteaof-bg-111.aof
100:S 24 Oct 2026 06:33:58.952 * Successfully renamed the temporary AOF base file temp-rewriteaof-bg-111.aof into appendonly.aof.2.base.rdb
100:S 24 Oct 2026 06:33:58.952 * Successfully renamed the temporary AOF incr file temp-appendonly.aof.incr into appendonly.aof.2.incr.aof

save: 3600 1 300 100 60 10000
client-output-buffer-limit: normal 0 0 0 slave 268435456 67108864 60 pubsub 33554432 8388608 60
bind: 192.168.58.21 127.0.0.1 -::1
compare done
```

從日誌可以看到 `repl-diskless-sync yes` 的效果：主庫 `Starting BGSAVE for SYNC with target: replicas sockets`，RDB 直接經網路送給從庫，不落主庫磁碟；兩台從庫到齊（`repl-diskless-sync-max-replicas 2`）後立刻開始，不用等滿 5 秒。

## 步驟 5：Sentinel

```conf
# /etc/redis/sentinel.conf
# Redis 7.4.11 Sentinel（rs1~rs3 共用，只有 bind 的 IP 不同）
# 標「建議」的是調整過的值；標「預設」的是 7.4.11 的預設值（在全新啟動的 Sentinel 上用 SENTINEL CONFIG GET / SENTINEL MASTER 查過）。
# 注意：Sentinel 會把偵測到的從庫、其他 Sentinel、切換結果寫回這個檔案，檔案與 /etc/redis 目錄都要讓 redis 使用者可寫。

# ==================== 網路與一般 ====================
# 建議（預設不限制）。只聽內網 IP 與本機
bind 192.168.58.21 127.0.0.1
# 預設
port 26379
# 範本預設。Sentinel 之間要互連，已用 bind 限制來源；要更嚴格可再設 sentinel 的 requirepass
protected-mode no
# 預設。由 systemd 管理
daemonize no
# 建議（預設 no）。搭配 Type=notify
supervised systemd
# 建議
pidfile /run/redis-sentinel/redis-sentinel.pid
# 預設
loglevel notice
# 建議（預設空字串 = stdout）
logfile /var/log/redis/sentinel.log
# 建議（範本為 /tmp）。Sentinel 本身不存資料，但要有可寫的工作目錄
dir /var/lib/redis-sentinel

# ==================== 監控的主庫 ====================
# quorum = 2：3 台 Sentinel 中有 2 台認為主庫掛了才判定客觀下線（ODOWN）
sentinel monitor mymaster 192.168.58.21 6379 2
# 主從節點的 requirepass / masterauth
sentinel auth-pass mymaster ChangeMe_Redis_2026
# 建議（預設 30000）。主庫多久沒回應判定主觀下線（SDOWN），越小切換越快，但太小會因網路抖動誤判
sentinel down-after-milliseconds mymaster 5000
# 建議（預設 180000）。一次切換的逾時；也決定同一主庫兩次切換的最小間隔（2 倍）
sentinel failover-timeout mymaster 60000
# 預設。切換後同時向新主庫全量同步的從庫數；1 最慢但同步期間仍有從庫可讀
sentinel parallel-syncs mymaster 1
# 預設（0 = 關閉）。主庫重啟後回應 LOADING 多久也視為下線
sentinel master-reboot-down-after-period mymaster 0
# 預設。禁止用 SENTINEL SET 修改 notification-script / client-reconfig-script
sentinel deny-scripts-reconfig yes
# 預設。全部用 IP；要用主機名時設 yes（並確保 DNS 穩定）
sentinel resolve-hostnames no
# 預設
sentinel announce-hostnames no
# 預設
acllog-max-len 128
```

```ini
# /etc/systemd/system/redis-sentinel.service
[Unit]
Description=Redis Sentinel 7.4 (port 26379)
Documentation=https://redis.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/redis-sentinel /etc/redis/sentinel.conf
User=redis
Group=redis
RuntimeDirectory=redis-sentinel
RuntimeDirectoryMode=0755
UMask=0077
LimitNOFILE=65535
TimeoutStartSec=infinity
TimeoutStopSec=infinity
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

```bash
sudo install -o redis -g redis -m 640 sentinel.conf /etc/redis/sentinel.conf   # 改 bind 的 IP
sudo systemctl daemon-reload
sudo systemctl enable --now redis-sentinel
```

```console
[rs1]# install -o redis -g redis -m 640 /root/conf/sentinel.conf /etc/redis/sentinel.conf && sed -i 's/^bind 192.168.58.21 /bind 192.168.58.21 /' /etc/redis/sentinel.conf && cp /root/conf/redis-sentinel.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now redis-sentinel && systemctl is-active redis-sentinel
Created symlink /etc/systemd/system/multi-user.target.wants/redis-sentinel.service → /etc/systemd/system/redis-sentinel.service.
active

[rs1]# cat /var/log/redis/sentinel.log
568:X 24 Oct 2026 06:34:01.819 * Supervised by systemd. Please make sure you set appropriate values for TimeoutStartSec and TimeoutStopSec in your service unit.
568:X 24 Oct 2026 06:34:01.819 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
568:X 24 Oct 2026 06:34:01.819 * Redis version=7.4.11, bits=64, commit=00000000, modified=0, pid=568, just started
568:X 24 Oct 2026 06:34:01.819 * Configuration loaded
568:X 24 Oct 2026 06:34:01.819 * monotonic clock: POSIX clock_gettime
568:X 24 Oct 2026 06:34:01.819 * Running mode=sentinel, port=26379.
568:X 24 Oct 2026 06:34:01.822 * Sentinel new configuration saved on disk
568:X 24 Oct 2026 06:34:01.822 * Sentinel ID is 1349725475cd7926088d6d19ab0e272c418977dd
568:X 24 Oct 2026 06:34:01.822 # +monitor master mymaster 192.168.58.21 6379 quorum 2
568:X 24 Oct 2026 06:34:01.822 * +slave slave 192.168.58.22:6379 192.168.58.22 6379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:01.823 * Sentinel new configuration saved on disk
568:X 24 Oct 2026 06:34:01.823 * +slave slave 192.168.58.23:6379 192.168.58.23 6379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:01.824 * Sentinel new configuration saved on disk
568:X 24 Oct 2026 06:34:03.998 * +sentinel sentinel 4a7f0e091c8df65b80caa790feaa7b123a3f7843 192.168.58.22 26379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:04.003 * Sentinel new configuration saved on disk
568:X 24 Oct 2026 06:34:04.141 * +sentinel sentinel 8156995db85c04866e04249c62f9bb75f9a0e26f 192.168.58.23 26379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:04.144 * Sentinel new configuration saved on disk

[rs1]# redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
192.168.58.21
6379

[rs1]# redis-cli -p 26379 sentinel master mymaster | paste - - | grep -E "^(name|ip|port|flags|num-slaves|num-other-sentinels|quorum|down-after-milliseconds|failover-timeout|parallel-syncs)\s"
name	mymaster
ip	192.168.58.21
port	6379
flags	master
down-after-milliseconds	5000
num-slaves	2
num-other-sentinels	2
quorum	2
failover-timeout	60000
parallel-syncs	1

[rs1]# redis-cli -p 26379 sentinel replicas mymaster | paste - - | grep -E "^(name|flags|master-link-status|slave-priority)\s"
name	192.168.58.23:6379
flags	slave
master-link-status	ok
slave-priority	100
name	192.168.58.22:6379
flags	slave
master-link-status	ok
slave-priority	100

[rs1]# redis-cli -p 26379 sentinel ckquorum mymaster
OK 3 usable Sentinels. Quorum and failover authorization can be reached

[rs1]# tail -12 /etc/redis/sentinel.conf
sentinel myid 1349725475cd7926088d6d19ab0e272c418977dd
sentinel config-epoch mymaster 0
sentinel leader-epoch mymaster 0
sentinel current-epoch 0

sentinel known-replica mymaster 192.168.58.23 6379

sentinel known-replica mymaster 192.168.58.22 6379

sentinel known-sentinel mymaster 192.168.58.23 26379 8156995db85c04866e04249c62f9bb75f9a0e26f

sentinel known-sentinel mymaster 192.168.58.22 26379 4a7f0e091c8df65b80caa790feaa7b123a3f7843
```

- Sentinel 只需要設定主庫，從庫與其他 Sentinel 都是自動發現的（`+slave`、`+sentinel`），並寫回 `sentinel.conf` 檔尾。
- `SENTINEL CKQUORUM` 回 `OK 3 usable Sentinels`，代表 quorum 與過半數都能達成。

`sentinel.conf` 裡標「預設」的值，是另外啟動一個只設 `monitor` 的 Sentinel 查出來的：

```console
[rs1]# printf "port 26399\nsentinel monitor m 127.0.0.1 6379 1\n" > /tmp/s.conf; redis-sentinel /tmp/s.conf --daemonize yes --logfile /tmp/s.log; sleep 1; redis-cli -p 26399 sentinel config get "*" | paste - -; redis-cli -p 26399 sentinel master m | paste - - | grep -E "^(down-after-milliseconds|failover-timeout|parallel-syncs|quorum)\s"; redis-cli -p 26399 shutdown nosave
resolve-hostnames	no
announce-hostnames	no
announce-ip	
announce-port	0
sentinel-user	
sentinel-pass	
loglevel	notice
down-after-milliseconds	30000
quorum	1
failover-timeout	180000
parallel-syncs	1
```

## 步驟 6：驗證主從

```console
[rs1]# redis-cli set order:1 "keyboard" && redis-cli incr counter:orders
OK
1

[rs3]# redis-cli get order:1; redis-cli set should:fail 1
keyboard
READONLY You can't write against a read only replica.
```

應用程式不要寫死主庫 IP，而是問 Sentinel：

```bash
redis-cli -h 192.168.58.21 -p 26379 SENTINEL get-master-addr-by-name mymaster
```

## 測試 1：計畫內切換（SENTINEL FAILOVER）

維護主庫前，先把主庫角色移到從庫：

```console
[rs1]# redis-cli -p 26379 sentinel failover mymaster
OK

# 14:34:33 rs1 等待 17 秒後條件成立：redis-cli info replication | grep -q "^master_link_status:up"
[rs1]# redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
192.168.58.23
6379

[rs1]# grep -E "\+(try-failover|elected-leader|selected-slave|promoted-slave|switch-master|failover-end|convert-to-slave)" /var/log/redis/sentinel.log | tail -8
568:X 24 Oct 2026 06:34:16.060 # +try-failover master mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:16.159 # +elected-leader master mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:16.223 # +selected-slave slave 192.168.58.23:6379 192.168.58.23 6379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:17.239 # +promoted-slave slave 192.168.58.23:6379 192.168.58.23 6379 @ mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:18.339 # +failover-end master mymaster 192.168.58.21 6379
568:X 24 Oct 2026 06:34:18.339 # +switch-master mymaster 192.168.58.21 6379 192.168.58.23 6379

[rs1]# redis-cli info replication | head -5
# Replication
role:slave
master_host:192.168.58.23
master_port:6379
master_link_status:up

[rs1]# grep -n -A3 "Generated by CONFIG REWRITE" /etc/redis/redis.conf
263:# Generated by CONFIG REWRITE
264-replicaof 192.168.58.23 6379
265-save 300 100
266-save 60 10000
```

- 從 `+try-failover` 到 `+switch-master` 約 **2.3 秒**。
- 舊主庫 rs1 被改成從庫，`redis.conf` 檔尾出現 `# Generated by CONFIG REWRITE` 區塊，寫入了新的 `replicaof`。`CONFIG REWRITE` 也把原本一行的 `save 3600 1 300 100 60 10000` 拆成多行，這是正常行為，值沒有改變。
- 舊主庫重新以從庫身分連上（`master_link_status:up`）花了 17 秒，期間 rs1 雖然已經被改成從庫，但要等 Sentinel 的定期檢查（平時每 10 秒一次 `INFO`）與重新同步完成。

## 測試 2：主庫無回應（自動切換）

用 `docker compose pause` 凍結主庫所在的容器，模擬主機當機或網路中斷（行程還在、但完全不回應）：

```console
[rs3]# redis-cli set before:crash 1
OK

# 14:34:33（主機端）docker compose pause rs3
# 14:34:40 Sentinel 回報新主庫 192.168.58.22（主庫凍結後 7 秒）
[rs1]# grep -E "\+(sdown|odown|try-failover|elected-leader|selected-slave|promoted-slave|switch-master|failover-end)" /var/log/redis/sentinel.log | tail -9
568:X 24 Oct 2026 06:34:39.000 # +sdown master mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:39.104 # +odown master mymaster 192.168.58.23 6379 #quorum 2/2
568:X 24 Oct 2026 06:34:39.104 # +try-failover master mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:39.171 # +elected-leader master mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:39.245 # +selected-slave slave 192.168.58.22:6379 192.168.58.22 6379 @ mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:39.526 # +promoted-slave slave 192.168.58.22:6379 192.168.58.22 6379 @ mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:39.632 # +sdown sentinel 8156995db85c04866e04249c62f9bb75f9a0e26f 192.168.58.23 26379 @ mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:40.218 # +failover-end master mymaster 192.168.58.23 6379
568:X 24 Oct 2026 06:34:40.218 # +switch-master mymaster 192.168.58.23 6379 192.168.58.22 6379

[rs2]# redis-cli get before:crash; redis-cli set after:crash 1; redis-cli info replication | head -4
1
OK
# Replication
role:master
connected_slaves:1
min_slaves_good_slaves:1

# 14:34:40 rs2 等待 0 秒後條件成立：redis-cli info replication | grep -q "^min_slaves_good_slaves:[1-9]"
[rs2]# redis-cli set after:crash 1; redis-cli info replication | head -4
OK
# Replication
role:master
connected_slaves:1
min_slaves_good_slaves:1
```

| 時間 | 事件 |
| :--- | :--- |
| 06:34:33 | 主庫 rs3 凍結 |
| 06:34:39.000 | `+sdown`：超過 `down-after-milliseconds 5000` |
| 06:34:39.104 | `+odown`：2/2 達到 quorum |
| 06:34:39.526 | `+promoted-slave`：rs2 升為主庫 |
| 06:34:40.218 | `+switch-master`：用戶端問 Sentinel 會拿到新主庫 |

主庫失聯到用戶端拿到新主庫約 **7 秒**。用預設的 `down-after-milliseconds 30000`，光判定下線就要 30 秒。切換前寫入的 `before:crash` 在新主庫上讀得到。

舊主庫恢復：

```console
# 14:34:40（主機端）docker compose unpause rs3
# 14:34:56 rs3 等待 16 秒後條件成立：redis-cli info replication | grep -q "^master_link_status:up"
[rs3]# redis-cli info replication | head -6; redis-cli get after:crash
# Replication
role:slave
master_host:192.168.58.22
master_port:6379
master_link_status:up
master_last_io_seconds_ago:1
1

[rs1]# grep -E "convert-to-slave|\-sdown" /var/log/redis/sentinel.log | tail -3
568:X 24 Oct 2026 06:34:40.929 # -sdown sentinel 8156995db85c04866e04249c62f9bb75f9a0e26f 192.168.58.23 26379 @ mymaster 192.168.58.22 6379
568:X 24 Oct 2026 06:34:50.947 * +convert-to-slave slave 192.168.58.23:6379 192.168.58.23 6379 @ mymaster 192.168.58.22 6379
```

恢復後約 10 秒被 Sentinel 改成從庫（`+convert-to-slave`），16 秒後同步完成，也拿到了切換期間寫入的 `after:crash`。

## 測試 3：min-replicas-to-write

兩台從庫都停掉時，主庫應該拒絕寫入：

```console
[rs1]# systemctl stop redis

[rs3]# systemctl stop redis

[rs2]# redis-cli info replication | grep -E "connected_slaves|min_slaves_good_slaves"; redis-cli set x 1
connected_slaves:0
min_slaves_good_slaves:0
NOREPLICAS Not enough good replicas to write.


[rs1]# systemctl start redis

[rs3]# systemctl start redis

[rs2]# redis-cli info replication | grep -E "connected_slaves|min_slaves_good_slaves"; redis-cli set x 1
connected_slaves:2
min_slaves_good_slaves:2
OK
```

`min-replicas-to-write 1` 生效：沒有健康的從庫時回 `NOREPLICAS`，從庫恢復後立即可以寫入。這個設定的意義在於腦裂：被隔離的舊主庫最多只會在 10 秒內（`min-replicas-max-lag`）接受寫入，之後就拒絕，減少切換後被覆蓋而遺失的資料。代價是從庫全部掛掉時主庫也不能寫，要依業務決定。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| 切換後第一筆寫入回 `NOREPLICAS Not enough good replicas to write` | 新主庫剛升級，另一台從庫還在重新設定、尚未連上；`min-replicas-to-write 1` 擋下寫入 | 預期行為，通常 1 秒內恢復；應用程式要能重試 |
| `redis-cli -p 26379` 每次都出現 `AUTH failed` | 匯出了 `REDISCLI_AUTH`，但 Sentinel 本身沒設密碼 | 連 Sentinel 時不要帶密碼，或替 Sentinel 也設 `requirepass` 並統一管理 |
| 舊主庫恢復後十幾秒才變成從庫 | Sentinel 每 10 秒發一次 `INFO` | 預期行為；這段期間舊主庫若還接受寫入，會被 `min-replicas-to-write` 擋下 |

## 驗證方式與結果

驗證環境、建置檔與 [Standalone 篇]({% post_url 2026-10-24-redis-lab-01-standalone %})相同（MacBook Air M4、Docker Desktop、Rocky Linux 9 容器 + systemd），rs1～rs3 用照步驟 1 編譯好 Redis 7.4.11 的映像，其餘步驟在容器內照文章執行。腳本是 `tools/redis-lab/20-sentinel.sh`。

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 3~4 主從 | `INFO replication`、日誌 | `connected_slaves:2`、從庫 `master_link_status:up` | ✅ |
| 3 設定檔 | 逐項 `CONFIG GET` 比對 | 實際值與設定檔一致 | ✅ 0 項不同 |
| 5 Sentinel | `SENTINEL MASTER`、`CKQUORUM` | `num-slaves 2`、`num-other-sentinels 2`、quorum 可達成 | ✅ |
| 6 唯讀 | 在從庫寫入 | `READONLY` | ✅ |
| 測試 1 | `SENTINEL FAILOVER` 後查新主庫與舊主庫角色 | 新主庫可寫、舊主庫變從庫且 link up | ✅ 2.3 秒切換 |
| 測試 2 | `docker pause` 主庫，輪詢 `get-master-addr-by-name` | 選出新主庫、資料不遺失、舊主庫恢復後成為從庫 | ✅ 7 秒 |
| 測試 3 | 停掉兩台從庫後寫入 | `NOREPLICAS`；從庫恢復後可寫 | ✅ |
| 日誌 | `grep WARNING` | 三台的 Redis 與 Sentinel 日誌都沒有 WARNING | ✅ |

**錯誤處理紀錄**：

- 第一次執行時，測試腳本在切換後固定等 8 秒、12 秒，結果舊主庫還沒變成從庫就開始檢查，改成輪詢條件成立並記錄等待秒數（文中的 17 秒、16 秒就是這樣量到的）。
- 有一次執行在切換後第一筆寫入遇到 `NOREPLICAS`，等從庫連上後重試成功；最後一次完整執行第一筆就成功了。
- 時間只量到秒（輪詢間隔 1 秒），Sentinel 日誌的毫秒時間戳記較精確。

## 版本差異比較：7.4.11 vs 8.10.2

| 項目 | 7.4.11 | 8.10.2 |
| :--- | :--- | :--- |
| Sentinel 參數與預設值 | `down-after-milliseconds 30000`、`failover-timeout 180000`、`parallel-syncs 1` | 相同；官方 `sentinel.conf` 範本兩版完全一樣 |
| 全量同步 | 增量寫入暫存在主庫的 replica 輸出緩衝 | 新複製機制，增量改由從庫端暫存（`replica-full-sync-buffer-limit`） |
| 複製壓縮 | 無 | `repl-compression`（需 `BUILD_COMPRESSION=yes`、`io-threads > 1`） |
| TLS 用戶端憑證登入 | 無 | `tls-auth-clients-user`（8.6） |
| 混合版本 | — | 升級時新版只能當舊版的從庫；8.6 以上的 RDB 7.4 讀不了 |

升級到 8.x 的順序：先把兩台從庫升級並確認同步正常 → `SENTINEL FAILOVER` 讓 8.x 的從庫成為主庫 → 最後升級舊主庫。Sentinel 本身可以在任何時候逐台升級。

## 小結

- 3 台 Sentinel、quorum 2，任何一台掛掉都還能切換。
- 所有節點都要設 `masterauth`；`/etc/redis` 要讓 redis 使用者可寫。
- `down-after-milliseconds 5000` 讓自動切換在約 7 秒內完成；預設 30 秒太慢。
- `min-replicas-to-write 1` 降低腦裂的資料遺失，但應用程式要能處理 `NOREPLICAS`。

下一篇：[Cluster]({% post_url 2026-10-24-redis-lab-03-cluster %})，當一台放不下時的水平擴展。

### 參考資料

- [High availability with Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [Redis 7.4 sentinel.conf](https://github.com/redis/redis/blob/7.4/sentinel.conf)
