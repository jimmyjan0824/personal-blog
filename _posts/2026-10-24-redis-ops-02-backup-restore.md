---
title: Redis 運維 02：備份與還原
date: 2026-10-24 11:10:00 +0800
categories: [Redis, 備份還原]
tags: [redis, redis7, redis8, dba, backup, rdb, aof, restore]
description: 以 Redis 7.4 為主，整理 RDB 與多檔 AOF 的備份方式、安全的備份流程、還原步驟與常見陷阱、以 AOF 做時間點還原，以及 Sentinel / Cluster 的備份重點，並比較 8.x 新增的 BACKUP 指令。
---

很多團隊把 Redis 當「只是快取」，從來沒備份過，直到有一天 Session、排行榜或計數器整個不見。本篇以 Redis 7.4 為主，整理 RDB 與 AOF 的備份還原流程，最後比較 8.x 的差異。

{% include redis-ops-series.md %}

## 持久化方式總覽

| 方式 | 原理 | 遺失資料量 | 還原速度 | 備份方式 |
| :--- | :--- | :--- | :--- | :--- |
| RDB | 定時 fork 子行程把整個資料集寫成快照 | 上次快照之後的全部 | 快 | 複製 `dump.rdb` |
| AOF | 記錄每個寫入指令，定期 rewrite 壓縮 | `everysec` 約 1 秒 | 較慢（重播指令） | 複製整個 `appendonlydir/` |
| RDB + AOF | 兩者都開，重啟時優先用 AOF | 約 1 秒 | AOF 的 base 用 RDB 格式，快很多 | 兩者都備 |

正式環境建議兩個都開（實作文的設定就是如此）。**RDB 是備份與搬遷的主要格式**，AOF 用來把當機時的遺失量降到最低。

## 7.0 起的多檔 AOF

7.0 開始，AOF 從單一檔案改成一個目錄：

```text
/var/lib/redis/appendonlydir/
├── appendonly.aof.1.base.rdb      # base：rewrite 時的完整快照（aof-use-rdb-preamble yes 時是 RDB 格式）
├── appendonly.aof.1.incr.aof      # incr：base 之後的增量指令
└── appendonly.aof.manifest        # 清單：記錄哪些檔案組成目前的 AOF
```

備份 AOF 一定要**整個目錄一起備**，少了 manifest 或任何一個 incr 檔都無法還原。

## RDB 備份

```bash
# 1. 觸發快照並等它完成
redis-cli BGSAVE
redis-cli INFO persistence | grep -E "rdb_bgsave_in_progress|rdb_last_bgsave_status|rdb_last_save_time"
# rdb_bgsave_in_progress:0 且 rdb_last_bgsave_status:ok 才算完成

# 2. 複製並檢查
cp /var/lib/redis/dump.rdb /backup/redis/dump-$(date +%F_%H%M).rdb
redis-check-rdb /backup/redis/dump-*.rdb
```

- `dump.rdb` 是先寫成暫存檔再改名，**任何時間點複製都是完整的檔案**，可以直接用 cron 定期複製。
- 也可以從遠端拉一份：`redis-cli -h <主機> --rdb /backup/dump.rdb`，原理是假裝成從庫做一次全量同步，不需要登入主機。
- 在**從庫**上備份，避免主庫 fork 的延遲影響線上服務。

## AOF 備份

AOF rewrite 期間檔案會被替換，直接複製可能拿到不一致的組合。官方建議的做法：

```bash
# 1. 暫時關閉自動 rewrite
redis-cli CONFIG SET auto-aof-rewrite-percentage 0

# 2. 確認目前沒有 rewrite 在跑
redis-cli INFO persistence | grep aof_rewrite_in_progress   # 要是 0

# 3. 複製整個目錄（用硬連結最快，也不佔額外空間）
cp -al /var/lib/redis/appendonlydir /backup/redis/aof-$(date +%F_%H%M)

# 4. 恢復自動 rewrite（改回設定檔裡的值）
redis-cli CONFIG SET auto-aof-rewrite-percentage 100
```

## 還原

### 從 RDB 還原

```bash
sudo systemctl stop redis
sudo mv /var/lib/redis/appendonlydir /var/lib/redis/appendonlydir.bak   # 若有開 AOF
sudo cp /backup/redis/dump-2026-10-24_0300.rdb /var/lib/redis/dump.rdb
sudo chown redis:redis /var/lib/redis/dump.rdb
```

接下來是最容易出事的地方：**`appendonly yes` 時，Redis 啟動只會讀 AOF，不讀 RDB**。如果 AOF 目錄不存在，它會建立一個空的 AOF，然後以空資料啟動，你辛苦放進去的 `dump.rdb` 完全沒被讀取。

實測（Rocky Linux 9 + Redis 7.4.11）：先用 `appendonly no` 寫入 1000 個 key 並 `SAVE`，再把 `dump.rdb` 放進一個空目錄、用 `appendonly yes` 啟動：

```console
[rc1]# mkdir -p /tmp/bad && cp /tmp/src/dump.rdb /tmp/bad/ && redis-server --port 6392 --dir /tmp/bad --appendonly yes --daemonize yes --logfile /tmp/bad/log >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6392 dbsize; grep -E "AOF|DB loaded" /tmp/bad/log; env -u REDISCLI_AUTH redis-cli -p 6392 shutdown nosave
0
76:M 24 Oct 2026 06:40:41.896 * Creating AOF base file appendonly.aof.1.base.rdb on server start
76:M 24 Oct 2026 06:40:41.897 * Creating AOF incr file appendonly.aof.1.incr.aof on server start
```

`DBSIZE` 是 0，日誌只有建立新的 AOF，完全沒有載入 RDB。

正確步驟：

```bash
# 1. 先暫時用 appendonly no 啟動，讓 Redis 讀 dump.rdb
sudo sed -i 's/^appendonly yes/appendonly no/' /etc/redis/redis.conf
sudo systemctl start redis
redis-cli DBSIZE                       # 確認資料量正確

# 2. 線上開啟 AOF，Redis 會用目前的資料建立新的 AOF
redis-cli CONFIG SET appendonly yes
redis-cli INFO persistence | grep -E "aof_enabled|aof_rewrite_in_progress"   # 等 rewrite 完成

# 3. 把設定檔改回 appendonly yes
sudo sed -i 's/^appendonly no/appendonly yes/' /etc/redis/redis.conf
```

照上面的正確步驟實測：

```console
[rc1]# mkdir -p /tmp/good && cp /tmp/src/dump.rdb /tmp/good/ && redis-server --port 6393 --dir /tmp/good --appendonly no --daemonize yes --logfile /tmp/good/log >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6393 dbsize; env -u REDISCLI_AUTH redis-cli -p 6393 config set appendonly yes; sleep 2; env -u REDISCLI_AUTH redis-cli -p 6393 info persistence | grep -E "aof_enabled|aof_rewrite_in_progress|aof_last_bgrewrite_status"; ls /tmp/good/appendonlydir; env -u REDISCLI_AUTH redis-cli -p 6393 shutdown
1000
OK
aof_enabled:1
aof_rewrite_in_progress:0
aof_last_bgrewrite_status:ok
appendonly.aof.1.base.rdb
appendonly.aof.1.incr.aof
appendonly.aof.manifest

[rc1]# redis-server --port 6393 --dir /tmp/good --appendonly yes --daemonize yes --logfile /tmp/good/log2 >/dev/null; sleep 1; env -u REDISCLI_AUTH redis-cli -p 6393 dbsize; grep -E "DB loaded" /tmp/good/log2; env -u REDISCLI_AUTH redis-cli -p 6393 shutdown nosave
1000
117:M 24 Oct 2026 06:40:46.216 * DB loaded from base file appendonly.aof.1.base.rdb: 0.001 seconds
117:M 24 Oct 2026 06:40:46.216 * DB loaded from append only file: 0.001 seconds
```

用 `appendonly no` 載入 RDB 後線上開啟 AOF，再以 `appendonly yes` 重啟，1000 個 key 都在，日誌顯示是從新的 AOF base 檔載入。

### 從 AOF 還原

把整個 `appendonlydir/` 放回 `dir` 底下，確認 `appenddirname` 與 manifest 檔名和設定一致，再啟動即可。啟動前可以先檢查：

```bash
redis-check-aof /var/lib/redis/appendonlydir/appendonly.aof.manifest
```

## 時間點還原（PITR）

Redis 沒有 MySQL binlog 那種完整的 PITR，但 7.0 起有一個實用的替代方案：開啟 `aof-timestamp-enabled yes`，AOF 會在指令間加上時間戳記註解，事後可以把 AOF 截斷到某個時間點：

```bash
# 例：有人在 10:15:30 誤下 FLUSHALL，要還原到 10:15:00
cp -a /var/lib/redis/appendonlydir /restore/appendonlydir
redis-check-aof --truncate-to-timestamp 1792721700 /restore/appendonlydir/appendonly.aof.manifest
```

限制：

- 只能截斷 **incr 檔**的內容；如果誤刪之後已經發生 AOF rewrite，誤刪前的指令早就被合併進 base，回不去了。所以發現誤刪時，**第一件事是 `CONFIG SET auto-aof-rewrite-percentage 0`**。
- 誤下 `FLUSHALL` 時也可以直接編輯 incr 檔，把最後的 `FLUSHALL` 指令刪掉，再用 `redis-check-aof` 檢查。
- `aof-timestamp-enabled` 預設是 `no`，會讓 AOF 稍微變大，要事先開啟才有用。

## Sentinel 與 Cluster 的備份

- **Sentinel**：在其中一台從庫做備份即可，主從資料相同。
- **Cluster**：每個主庫只有部分 slot 的資料，**每個分片都要備份**。還原時的 slot 分布要和備份時一樣（同樣的主庫數、同樣的 slot 範圍），否則載入的 key 不屬於該節點的 slot，節點會拒絕啟動。實務上常把每個分片的 RDB 搭配當時的 `CLUSTER NODES` 輸出一起保存。
- 要搬到 slot 分布不同的新叢集，可以用 `redis-cli --cluster import`，或第三方工具（例如 RedisShake）重新寫入。

## 備份策略與還原演練

| 項目 | 建議 |
| :--- | :--- |
| 頻率 | RDB 每小時一次、保留 48 小時；每日一份保留 30 天 |
| 位置 | 備份當下就送到異地（物件儲存），不要只放在同一台主機 |
| 驗證 | 每份備份都跑 `redis-check-rdb`；每季實際還原到測試機，比對 `DBSIZE` 與抽樣 key |
| 監控 | 告警 `rdb_last_bgsave_status`、`aof_last_write_status` 不是 `ok`，以及備份檔的時間與大小 |

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| RDB 格式版本 | 12 | 8.0～8.4 為 12；8.6 為 13、8.8 為 14、8.10 為 15 |
| 跨版本還原 | — | **8.6 以上產生的 RDB / AOF base 無法在 7.4 載入**，升級後要回退只能用升級前的備份 |
| AOF 中的複製位移 | 無 | 8.0 起 AOF 會記錄複製 offset，用來判斷哪個節點的 AOF 比較新 |
| AOF 尾端損毀 | `aof-load-truncated` | 8.4 新增 `aof-load-corrupt-tail-max-size`，可自動修復尾端損毀的部分 |
| 節點端備份 | 無，要自己控制 rewrite | 8.10 新增 `BACKUP START` / `SEAL` / `STATUS` / `LIST` / `CLEANUP` / `ABORT`，在 `dir/backupdirname` 下產生不會被改動的 MP-AOF 備份集 |
| 啟動時預載 | 無 | 8.10 新增 `preload-file`，啟動時可指定載入一個 RDB 或 AOF |

8.10 的 `BACKUP` 正好解決了 7.x「備份 AOF 要先關 rewrite」的麻煩：`BACKUP START` 之後 Redis 自己保證備份目錄裡的 base、incr 與 manifest 是一致且不會再被改動的，`BACKUP SEAL` 後就能放心上傳，`BACKUP CLEANUP` 再清掉。8.x 預設 `backup-sealed-ttl 0`，不會自動清理，記得在備份腳本最後呼叫 `CLEANUP`。

### 給備份流程的升級建議

- 升級到 8.x 前，先在 7.4 上做一份 RDB 並異地保存，這是**唯一能回退**的資料。
- 升級後若要回退，只能在回退前的 7.4 從庫還在時切回去，或用升級前的備份還原（會遺失升級後的寫入）。
- 8.10 以後可以把 AOF 備份流程改成 `BACKUP` 指令，取代手動關閉 rewrite。

## 小結

- RDB 任何時候都能直接複製；AOF 要先關 rewrite，再複製整個 `appendonlydir/`。
- **`appendonly yes` 時 Redis 只讀 AOF**，從 RDB 還原要先用 `appendonly no` 啟動，再線上開啟 AOF。
- 想要時間點還原，事先開 `aof-timestamp-enabled`，發現誤刪立刻停掉 AOF rewrite。
- Cluster 要每個分片都備份，還原時 slot 分布要一致。

下一篇：[高可用與災難復原]({% post_url 2026-10-24-redis-ops-03-ha-dr %})。

### 參考資料

- [Redis persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Redis 7.4 redis.conf](https://github.com/redis/redis/blob/7.4/redis.conf)
- [Redis 8.10 release notes](https://github.com/redis/redis/blob/8.10/00-RELEASENOTES)
