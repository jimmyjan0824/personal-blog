---
title: Redis 安裝部署 01：Standalone（Redis 7.4 / Rocky Linux 9）
date: 2026-10-24 11:01:00 +0800
categories: [Redis, 安裝部署]
tags: [redis, redis7, rocky-linux, installation, redis.conf, systemd, dba]
description: 在 Rocky Linux 9 上從原始碼編譯安裝 Redis 7.4.11，以 systemd 管理單機 Redis，附上包含所有效能相關參數的 redis.conf（每個參數標明建議值或預設值），所有輸出皆為實測結果。
---

[安裝部署與環境配置]({% post_url 2026-10-24-redis-ops-01-installation-config %})一篇整理了版本選擇與共通觀念，這篇開始動手做。第一篇是最基本的 **Standalone（單機）**，後面的 Sentinel 與 Cluster 都建立在這篇的安裝步驟與設定檔上。

{% include redis-ops-series.md %}

{% include redis-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `redis1` | 192.168.58.11 | Redis Standalone（port 6379） |

規劃的主機規格：16 GB RAM、8 vCPU、SSD，專門跑 Redis；用途是**快取為主，但重啟後要保留資料**（RDB + AOF）。

## 步驟 0：OS 參數

```bash
sudo tee /etc/sysctl.d/99-redis.conf <<'CONF'
vm.overcommit_memory = 1
net.core.somaxconn = 1024
vm.swappiness = 1
CONF
sudo sysctl -p /etc/sysctl.d/99-redis.conf
```

```console
[redis1]# sysctl -p /etc/sysctl.d/99-redis.conf
vm.overcommit_memory = 1
net.core.somaxconn = 1024
vm.swappiness = 1
```

| 參數 | 為什麼 |
| :--- | :--- |
| `vm.overcommit_memory = 1` | BGSAVE / AOF rewrite 要 fork，設 0 時資料量大可能 fork 失敗，寫入會被 `MISCONF` 擋下 |
| `net.core.somaxconn = 1024` | 要 ≥ redis.conf 的 `tcp-backlog 511`，否則 backlog 會被截斷 |
| `vm.swappiness = 1` | Redis 被 swap 出去時延遲會暴增 |

Transparent Huge Pages 不用另外關：Redis 預設 `disable-thp yes`，會自己對 Redis 行程關閉 THP。

防火牆（**未實測**，容器內沒有 firewalld）：

```bash
sudo firewall-cmd --permanent --add-port=6379/tcp
sudo firewall-cmd --reload
```

## 步驟 1：安裝（原始碼編譯）

```bash
sudo dnf install -y gcc make tar gzip systemd-devel
cd /usr/local/src
sudo curl -fsSLO https://download.redis.io/releases/redis-7.4.11.tar.gz
sha256sum redis-7.4.11.tar.gz      # 和 github.com/redis/redis-hashes 公布的值比對
sudo tar xzf redis-7.4.11.tar.gz && cd redis-7.4.11
sudo make -j"$(nproc)" USE_SYSTEMD=yes
sudo make install                  # 安裝到 /usr/local/bin
```

`USE_SYSTEMD=yes` 會連結 libsystemd（所以要裝 `systemd-devel`），讓 Redis 能在載入完資料後才通知 systemd 啟動完成（`Type=notify`）。

實測輸出（aarch64；x86_64 主機上架構字樣會是 `x86_64`）：

```console
[redis1]# dnf install -y gcc make tar gzip systemd-devel 2>&1 | grep -E "^Install|^Upgrade|Complete|gcc  |systemd-devel" | head
Installing:
 gcc                     aarch64  11.5.0-14.el9                appstream   30 M
 systemd-devel           aarch64  252-67.el9_8.6.rocky.0.1     appstream  465 k
 libgcc                  aarch64  11.5.0-14.el9                baseos      79 k
Installing dependencies:
Install  14 Packages
Upgrade   7 Packages
(13/21): systemd-devel-252-67.el9_8.6.rocky.0.1 1.6 MB/s | 465 kB     00:00    
  Installing       : systemd-devel-252-67.el9_8.6.rocky.0.1.aarch64       21/28 
  Verifying        : systemd-devel-252-67.el9_8.6.rocky.0.1.aarch64       14/28

[redis1]# cd /usr/local/src && curl -fsSLO https://download.redis.io/releases/redis-7.4.11.tar.gz && ls -l redis-7.4.11.tar.gz && sha256sum redis-7.4.11.tar.gz
-rw-r--r-- 1 root root 3550434 Oct 24 06:28 redis-7.4.11.tar.gz
3c266ece0abd54ed3b1c912c6eb86b7508cf382cb690ee6649d3843f018f6357  redis-7.4.11.tar.gz

[redis1]# curl -fsSL https://raw.githubusercontent.com/redis/redis-hashes/master/README | grep "redis-7.4.11.tar.gz"
hash redis-7.4.11.tar.gz sha256 3c266ece0abd54ed3b1c912c6eb86b7508cf382cb690ee6649d3843f018f6357 http://download.redis.io/releases/redis-7.4.11.tar.gz

[redis1]# cd /usr/local/src && tar xzf redis-7.4.11.tar.gz && cd redis-7.4.11 && (time make -j"$(nproc)" USE_SYSTEMD=yes) 2>&1 | tail -8

Hint: It's a good idea to run 'make test' ;)

make[1]: Leaving directory '/usr/local/src/redis-7.4.11/src'

real	0m15.709s
user	1m38.695s
sys	0m8.455s

[redis1]# cd /usr/local/src/redis-7.4.11 && make install 2>&1 | tail -8
    CC Makefile.dep

Hint: It's a good idea to run 'make test' ;)

    INSTALL redis-server
    INSTALL redis-benchmark
    INSTALL redis-cli
make[1]: Leaving directory '/usr/local/src/redis-7.4.11/src'

[redis1]# ls /usr/local/bin/redis-*; redis-server --version; ldd /usr/local/bin/redis-server | grep systemd
/usr/local/bin/redis-benchmark
/usr/local/bin/redis-check-aof
/usr/local/bin/redis-check-rdb
/usr/local/bin/redis-cli
/usr/local/bin/redis-sentinel
/usr/local/bin/redis-server
Redis server v=7.4.11 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=7976ce91a6632ff3
	libsystemd.so.0 => /lib64/libsystemd.so.0 (0x0000ffff8a0ed000)
```

`sha256sum` 的值和官方 [redis-hashes](https://github.com/redis/redis-hashes) 公布的一致；`ldd` 看得到 `libsystemd.so.0`，代表 systemd 支援有編進去。

## 步驟 2：使用者與目錄

```bash
sudo groupadd -r redis
sudo useradd -r -g redis -s /sbin/nologin -d /var/lib/redis -c "Redis Server" redis
sudo mkdir -p /etc/redis /var/lib/redis /var/log/redis
sudo chown -R redis:redis /etc/redis /var/lib/redis /var/log/redis
sudo chmod 750 /etc/redis /var/lib/redis /var/log/redis
```

| 路徑 | 用途 |
| :--- | :--- |
| `/etc/redis/redis.conf` | 設定檔（`CONFIG REWRITE` 會改寫，所以要讓 redis 使用者可寫） |
| `/var/lib/redis` | RDB、AOF（`dir`），放在 SSD |
| `/var/log/redis` | 日誌 |

## 步驟 3：設定檔

註解標「建議」的是調整過的值；標「預設」的是 7.4.11 的預設值（在全新安裝的 7.4.11 上不帶設定檔啟動，用 `CONFIG GET *` 逐一查過，共 202 個參數），寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。

> Redis 的設定檔**不支援行尾註解**，`port 6379   # 預設` 會讓 Redis 啟動失敗（見文末「實測踩到的坑」），所以每個參數的說明都寫在上一行。
{: .prompt-danger }

```conf
# /etc/redis/redis.conf
# Redis 7.4.11 Standalone：效能與運維設定
# 以「16 GB RAM、8 vCPU、SSD、專用 Redis 主機、快取為主但重啟後要保留資料」為基準。
# 標「建議」的是調整過的值；標「預設」的是 7.4.11 的預設值（在全新安裝的 7.4.11 上用 CONFIG GET 逐一查過），
# 寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。

# ==================== 網路 ====================
# 建議（預設 * -::*）。只聽內網 IP 與本機，不要對外
bind 192.168.58.11 127.0.0.1 -::1
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

# ==================== 複製（Standalone 沒有從庫時也先準備好） ====================
# 建議（預設 1mb）。從庫斷線重連時能部分同步的緩衝；約「寫入量/秒 × 可容忍斷線秒數」
repl-backlog-size 256mb
# 預設
repl-backlog-ttl 3600

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

```bash
sudo install -o redis -g redis -m 640 redis-standalone.conf /etc/redis/redis.conf
```

主機規格不同時，主要調整下面這幾個，其他維持上面的值即可：

| 實體記憶體 | `maxmemory`（開持久化） | `maxmemory`（純快取、不持久化） |
| :--- | :--- | :--- |
| 8 GB | 5gb | 6gb |
| 16 GB | 10gb | 12gb |
| 32 GB | 20gb | 25gb |
| 64 GB | 40gb | 50gb |

| vCPU | `io-threads` |
| :--- | :--- |
| 1～4 | 1（預設） |
| 8 | 4 |
| 16 以上 | 6～8 |

- `maxmemory` 要預留 fork 的 copy-on-write 與緩衝區；實務上單一實例不要超過 25 GB 左右，再大 fork 與全量同步都會很慢。
- 只當快取、可以接受資料全失時，關掉持久化：`save ""`、`appendonly no`。
- 當資料庫用（不能丟資料）時，`maxmemory-policy` 改回 `noeviction`。

## 步驟 4：systemd

```ini
# /etc/systemd/system/redis.service
[Unit]
Description=Redis 7.4 (port 6379)
Documentation=https://redis.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
User=redis
Group=redis
RuntimeDirectory=redis
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

- `Type=notify` 搭配 redis.conf 的 `supervised systemd`：資料量大時載入可能要幾分鐘，systemd 會等 Redis 真正可以服務才算啟動完成。
- `TimeoutStartSec` / `TimeoutStopSec=infinity`：載入大資料集、關機前存 RDB 都可能很久，不要讓 systemd 中途砍掉。Redis 啟動時也會提醒這件事。
- `RuntimeDirectory=redis`：自動建立 `/run/redis` 放 pid 檔。
- `LimitNOFILE=65535`：`maxclients 10000` 需要至少 10032 個 fd。

```console
[redis1]# cp /root/conf/redis.service /etc/systemd/system/redis.service && systemctl daemon-reload && systemctl enable --now redis
Created symlink /etc/systemd/system/multi-user.target.wants/redis.service → /etc/systemd/system/redis.service.

[redis1]# systemctl status redis --no-pager | head -9
● redis.service - Redis 7.4 (port 6379)
     Loaded: loaded (/etc/systemd/system/redis.service; enabled; preset: disabled)
     Active: active (running) since Sat 2026-10-24 06:29:03 UTC; 76ms ago
       Docs: https://redis.io/docs/
   Main PID: 11839 (redis-server)
     Status: "Ready to accept connections"
      Tasks: 9 (limit: 51007)
     Memory: 9.3M (peak: 9.3M)
        CPU: 4ms

[redis1]# cat /var/log/redis/redis.log
11839:C 24 Oct 2026 06:29:03.778 * Supervised by systemd. Please make sure you set appropriate values for TimeoutStartSec and TimeoutStopSec in your service unit.
11839:C 24 Oct 2026 06:29:03.778 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
11839:C 24 Oct 2026 06:29:03.778 * Redis version=7.4.11, bits=64, commit=00000000, modified=0, pid=11839, just started
11839:C 24 Oct 2026 06:29:03.778 * Configuration loaded
11839:M 24 Oct 2026 06:29:03.779 * monotonic clock: POSIX clock_gettime
11839:M 24 Oct 2026 06:29:03.779 * Running mode=standalone, port=6379.
11839:M 24 Oct 2026 06:29:03.779 * Server initialized
11839:M 24 Oct 2026 06:29:03.781 * Creating AOF base file appendonly.aof.1.base.rdb on server start
11839:M 24 Oct 2026 06:29:03.782 * Creating AOF incr file appendonly.aof.1.incr.aof on server start
11839:M 24 Oct 2026 06:29:03.782 * Ready to accept connections tcp
```

## 步驟 5：驗證

```console
[redis1]# redis-cli ping; redis-cli info server | grep -E "redis_version|redis_mode|os:|arch_bits|multiplexing_api|gcc_version|process_supervised|config_file|io_threads_active"
PONG
redis_version:7.4.11
redis_mode:standalone
os:Linux 7.0.14-linuxkit aarch64
arch_bits:64
multiplexing_api:epoll
gcc_version:11.5.0
process_supervised:systemd
config_file:/etc/redis/redis.conf
io_threads_active:0

[redis1]# redis-cli config get maxmemory; redis-cli config get maxmemory-policy; redis-cli config get io-threads; redis-cli config get appendonly; redis-cli config get lazyfree-lazy-user-del
maxmemory
10737418240
maxmemory-policy
allkeys-lru
io-threads
4
appendonly
yes
lazyfree-lazy-user-del
yes

[redis1]# cat /proc/$(pidof redis-server)/limits | grep "open files"; redis-cli config get maxclients
Max open files            65535                65535                files     
maxclients
10000

[redis1]# env -u REDISCLI_AUTH redis-cli ping; redis-cli -h 192.168.58.11 ping
NOAUTH Authentication required.

PONG

[redis1]# redis-cli set user:1001:name Jimmy EX 3600; redis-cli get user:1001:name; seq 1 100000 | awk "{printf \"SET key:%d %0100d\\n\", \$1, \$1}" | redis-cli >/dev/null; redis-cli dbsize; redis-cli info memory | grep -E "used_memory_human|maxmemory_human|maxmemory_policy|mem_fragmentation_ratio|mem_allocator"
OK
Jimmy
100001
used_memory_human:18.16M
maxmemory_human:10.00G
maxmemory_policy:allkeys-lru
mem_fragmentation_ratio:1.58
mem_allocator:jemalloc-5.3.0

[redis1]# redis-cli info persistence | grep -E "aof_enabled|aof_rewrite_in_progress|rdb_last_bgsave_status|aof_last_write_status"; ls -l /var/lib/redis /var/lib/redis/appendonlydir
rdb_last_bgsave_status:ok
aof_enabled:1
aof_rewrite_in_progress:0
aof_last_write_status:ok
/var/lib/redis:
total 4
drwx------ 2 redis redis 4096 Oct 24 06:29 appendonlydir

/var/lib/redis/appendonlydir:
total 13280
-rw------- 1 redis redis       89 Oct 24 06:29 appendonly.aof.1.base.rdb
-rw------- 1 redis redis 13588994 Oct 24 06:29 appendonly.aof.1.incr.aof
-rw------- 1 redis redis       88 Oct 24 06:29 appendonly.aof.manifest

[redis1]# systemctl restart redis && sleep 2 && redis-cli dbsize && redis-cli get user:1001:name && grep -E "DB loaded|Ready to accept" /var/log/redis/redis.log | tail -3
100001
Jimmy
12296:M 24 Oct 2026 06:29:08.784 * DB loaded from incr file appendonly.aof.1.incr.aof: 0.039 seconds
12296:M 24 Oct 2026 06:29:08.784 * DB loaded from append only file: 0.039 seconds
12296:M 24 Oct 2026 06:29:08.784 * Ready to accept connections tcp

[redis1]# redis-cli eval "for i=1,150000000 do end return 1" 0; redis-cli latency latest; redis-cli slowlog get 1
1
command
1792823351
201
201
0
1792823351
201106
eval
for i=1,150000000 do end return 1
0
127.0.0.1:39498

[redis1]# redis-benchmark -h 127.0.0.1 -a ChangeMe_Redis_2026 -q -n 100000 -c 50 -t set,get --threads 2 2>&1 | tr "\\r" "\\n" | grep "requests per second"
SET: 199203.20 requests per second, p50=0.119 msec
GET: 199600.80 requests per second, p50=0.095 msec
```

幾個重點：

- `process_supervised:systemd`、`Max open files 65535`：systemd 整合正確。
- `io_threads_active:0` 不是設定沒生效：Redis 7.x 只有在待處理的連線多到一定程度時才會啟動 I/O 執行緒，閒置時是 0。`CONFIG GET io-threads` 是 4。
- 不帶密碼回 `NOAUTH`：`requirepass` 生效。
- 重啟後 100001 個 key 都在，日誌顯示是從 AOF 載入。
- Lua 迴圈約 200 ms，被 `SLOWLOG`（> 10 ms）與 `LATENCY`（> 100 ms）都記錄下來。

`redis-cli` 用環境變數 `REDISCLI_AUTH` 帶密碼，比 `-a` 好：不會出現在 `ps` 與 shell 歷史紀錄，也不會印出警告。

```bash
export REDISCLI_AUTH='ChangeMe_Redis_2026'
```

設定檔裡的每個參數（`save`、`client-output-buffer-limit`、`bind` 等多值參數除外）都用 `CONFIG GET` 逐一比對過，**實際值與設定檔完全一致**（記憶體單位換算成 bytes 後比較）。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `FATAL CONFIG FILE ERROR ... wrong number of arguments` | redis.conf 不支援行尾註解 | 註解寫在參數上一行 |
| `DEBUG POPULATE`、`DEBUG SLEEP` 被拒絕 | 7.0 起 `enable-debug-command` 預設 `no`，`DEBUG` 完全不能用（設 `local` 才允許本機連線使用） | 測試資料改用 Pipeline 寫入；正式環境維持 `no` |
| 用 `REDISCLI_AUTH= redis-cli` 想清掉密碼，仍出現 `AUTH failed` | 空字串也會被送出 `AUTH` | 用 `env -u REDISCLI_AUTH redis-cli` |
| `io_threads_active:0` | I/O 執行緒依負載動態啟動 | 不是錯誤，壓測時再看 |

行尾註解的實際錯誤：

```console
[rc1]# printf "port 6390                                   # 預設\n" > /tmp/bad.conf; cat /tmp/bad.conf; redis-server /tmp/bad.conf; echo "exit=$?"
port 6390                                   # 預設

*** FATAL CONFIG FILE ERROR (Redis 7.4.11) ***
Reading the configuration file, at line 1
>>> 'port 6390                                   # 預設'
wrong number of arguments
exit=1
```

## 驗證方式與結果

**驗證環境**

| 項目 | 內容 |
| :--- | :--- |
| 主機 | MacBook Air M4（Mac16,12），macOS 15.7.4 |
| 容器 | Docker Desktop 4.96.3（Engine 29.9.2），VM 10 CPU / 約 7.7 GB |
| 作業系統 | `rockylinux:9` 映像（Rocky Linux 9.3）+ systemd，`dnf` 套件來自目前的 Rocky 9 套件庫（gcc 11.5.0、systemd 252） |
| Redis | 7.4.11，`download.redis.io` 原始碼，`make USE_SYSTEMD=yes` |
| 架構 | aarch64 |

每台主機是一個 privileged 容器，以 `/usr/sbin/init`（systemd）為 PID 1，所以 `systemctl`、`Type=notify` 都是真實流程。`redis1` 是只有 systemd 的乾淨 Rocky 9，步驟 0～5 全部在容器裡照文章執行。建置檔與腳本放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/redis-lab)：

```dockerfile
# Rocky Linux 9 + systemd（還沒裝 Redis）：給 redis1 現場照「步驟 1」編譯安裝用
FROM rockylinux:9
RUN dnf install -y systemd procps-ng iproute hostname which less vim-minimal \
 && dnf clean all \
 && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
```

```dockerfile
# Rocky Linux 9 + systemd + 依「步驟 1」從原始碼編譯安裝 Redis（Sentinel / Cluster 節點用）
FROM rocky9-base
ARG REDIS_VER=7.4.11
RUN dnf install -y gcc make tar gzip systemd-devel \
 && cd /usr/local/src \
 && curl -fsSLO https://download.redis.io/releases/redis-${REDIS_VER}.tar.gz \
 && tar xzf redis-${REDIS_VER}.tar.gz \
 && cd redis-${REDIS_VER} \
 && make -j"$(nproc)" USE_SYSTEMD=yes \
 && make install \
 && dnf clean all
```

```yaml
# redis1：Standalone；rs1~rs3：Sentinel（每台 Redis + Sentinel）；rc1~rc6：Cluster（3 主 3 從）
x-node: &node
  image: rocky9-redis74
  pull_policy: never
  privileged: true            # systemd 當 PID 1、sysctl 需要
  cgroup: host
  volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw", "./conf:/root/conf:ro"]
  tmpfs: ["/run", "/run/lock"]
  extra_hosts:
    - "redis1:192.168.58.11"
    - "rs1:192.168.58.21"
    - "rs2:192.168.58.22"
    - "rs3:192.168.58.23"
    - "rc1:192.168.58.31"
    - "rc2:192.168.58.32"
    - "rc3:192.168.58.33"
    - "rc4:192.168.58.34"
    - "rc5:192.168.58.35"
    - "rc6:192.168.58.36"
services:
  redis1: { <<: *node, image: rocky9-base, hostname: redis1, networks: { labnet: { ipv4_address: 192.168.58.11 } } }
  rs1:    { <<: *node, hostname: rs1, networks: { labnet: { ipv4_address: 192.168.58.21 } } }
  rs2:    { <<: *node, hostname: rs2, networks: { labnet: { ipv4_address: 192.168.58.22 } } }
  rs3:    { <<: *node, hostname: rs3, networks: { labnet: { ipv4_address: 192.168.58.23 } } }
  rc1:    { <<: *node, hostname: rc1, networks: { labnet: { ipv4_address: 192.168.58.31 } } }
  rc2:    { <<: *node, hostname: rc2, networks: { labnet: { ipv4_address: 192.168.58.32 } } }
  rc3:    { <<: *node, hostname: rc3, networks: { labnet: { ipv4_address: 192.168.58.33 } } }
  rc4:    { <<: *node, hostname: rc4, networks: { labnet: { ipv4_address: 192.168.58.34 } } }
  rc5:    { <<: *node, hostname: rc5, networks: { labnet: { ipv4_address: 192.168.58.35 } } }
  rc6:    { <<: *node, hostname: rc6, networks: { labnet: { ipv4_address: 192.168.58.36 } } }
networks:
  labnet:
    ipam: { config: [ { subnet: 192.168.58.0/24 } ] }
```

想自己重現的話，把 `tools/redis-lab` 整個資料夾複製下來，依序執行 `./00-build.sh`、`./10-standalone.sh`（Sentinel、Cluster 分別是 `20-`、`30-`），輸出會記錄在 `results/`。

**驗證項目**

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 1 安裝 | `sha256sum`、`redis-server --version`、`ldd` | 雜湊與官方一致、7.4.11、有 libsystemd | ✅ |
| 2~4 設定與啟動 | `systemctl status`、`redis.log` | `active (running)`、`Ready to accept connections`、日誌沒有 WARNING | ✅ |
| 3 設定檔 | 逐項 `CONFIG GET` 比對 | 實際值與設定檔一致 | ✅ 0 項不同 |
| 5 認證 | 不帶密碼連線 | `NOAUTH` | ✅ |
| 5 持久化 | 寫入 10 萬筆後 `systemctl restart` | `DBSIZE` 不變、從 AOF 載入 | ✅ |
| 5 監控 | 執行約 200 ms 的 Lua | `SLOWLOG`、`LATENCY LATEST` 有紀錄 | ✅ |
| 預設值 | 不帶設定檔啟動，`CONFIG GET *` | 用來標註設定檔的「預設」 | ✅ 7.4.11：202 個參數；8.10.2：228 個 |

**錯誤處理紀錄**（對應上方「實測踩到的坑」）：

- 行尾註解：撰寫設定檔時第一次啟動就遇到，改成註解在上一行後通過。
- `DEBUG POPULATE` / `DEBUG SLEEP` 被擋：原本想用來灌測試資料與製造慢查詢，改用 Pipeline 寫入與 Lua 迴圈。
- `REDISCLI_AUTH=` 空字串：驗證預設值時遇到，改用 `env -u`。

## 版本差異比較：7.4.11 vs 8.10.2

同樣的 redis.conf 拿到 8.10.2 上可以直接啟動（`io-threads-do-reads` 在 8.x 已移除，但設定檔裡出現會被忽略，不會報錯）。兩版不帶設定檔啟動後的 `CONFIG GET *` 比對：

| 項目 | 7.4.11 | 8.10.2 |
| :--- | :--- | :--- |
| 參數數量 | 202 | 228（新增 27、移除 1） |
| 移除 | — | `io-threads-do-reads` |
| 新增（和單機效能有關的） | — | `lookahead 16`、`key-memory-histograms no`、`slowlog-entry-max-argc 32`、`slowlog-entry-max-string-len 128`、`hash-*-template-entries 0`（compact hash）、`aof-load-corrupt-tail-max-size 0`、`replica-full-sync-buffer-limit 0` |
| 新增（其他） | — | `backupdirname`、`backup-sealed-ttl`、`preload-file`、`stream-idmp-*`、`array-*`、`vset-force-single-threaded-execution`、`tls-auth-clients-user`、`tls-expected-peer-name` 等 |
| 預設值改變 | — | 兩版共有的參數，**預設值完全相同**（包括 `lazyfree-*` 仍是 `no`） |
| 官方 redis.conf 範本 | — | 8.10.2 多了上述新參數，以及載入 4 個內建模組的 `loadmodule` |
| 編譯 | `make` 只編核心 | `make` 會連內建模組（JSON、搜尋、時序、Bloom）一起編，需要更多相依套件；只要核心用 `make build redis`（實測） |

> 從 8.x 降回 7.4 時要注意相反方向：8.x 新增的參數寫進設定檔後，7.4 會因為不認得而**啟動失敗**。
{: .prompt-warning }

## 小結

- Rocky 9 用原始碼編譯 7.4.11，`USE_SYSTEMD=yes` + `Type=notify` + `supervised systemd`。
- OS 至少設 `vm.overcommit_memory = 1` 與 `somaxconn`。
- redis.conf 不支援行尾註解。
- 最重要的建議值：`maxmemory`、`maxmemory-policy`、`appendonly yes`、Lazy Free 全開、`io-threads`、`repl-backlog-size`、`slowlog-max-len`、`latency-monitor-threshold`。

下一篇：[Sentinel]({% post_url 2026-10-24-redis-lab-02-sentinel %})，在這個基礎上加上從庫與自動故障切換。

### 參考資料

- [Redis：Install Redis from source](https://redis.io/docs/latest/operate/oss_and_stack/install/build-stack/)
- [Redis configuration（redis.conf 7.4）](https://github.com/redis/redis/blob/7.4/redis.conf)
- [Redis administration](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/)
- [redis-hashes](https://github.com/redis/redis-hashes)
