---
title: Redis 運維 06：容量規劃與擴展
date: 2026-10-24 11:50:00 +0800
categories: [Redis, 容量規劃]
tags: [redis, redis7, redis8, dba, capacity, memory, eviction, cluster, resharding]
description: 以 Redis 7.4 為主，整理記憶體估算方法、主機規格與 maxmemory、淘汰策略的選擇、垂直擴展、讀寫分離與 Cluster 水平擴展、slot 搬遷與 hash tag，並比較 8.x 的差異。
---

Redis 的容量規劃幾乎就是**記憶體規劃**：資料要全部放在記憶體裡，放不下就只能淘汰、拒絕寫入，或擴展。本篇以 Redis 7.4 為主，最後比較 8.x。

{% include redis-ops-series.md %}

## 先量測現況

```bash
redis-cli INFO memory | grep -E "used_memory_human|used_memory_rss_human|used_memory_dataset_perc|mem_fragmentation_ratio|maxmemory_human"
redis-cli INFO keyspace                # 每個 db 的 key 數、有 TTL 的 key 數
redis-cli MEMORY USAGE user:1001       # 單一 key 的實際用量（含 Redis 內部開銷）
redis-cli --memkeys -i 0.01            # 依記憶體排序的大 key
```

估算新業務的用量時，不要只算「key + value 的位元組數」。每個 key 在 Redis 內部有 dictEntry、redisObject、SDS 標頭等開銷，**一個小 String key 至少多 50～70 bytes**。最準的方式是寫入一批真實格式的樣本資料，量測 `used_memory` 的變化再乘上筆數：

```bash
redis-cli INFO memory | grep "^used_memory:"     # 寫入前
# 寫入 10 萬筆真實格式的樣本
redis-cli INFO memory | grep "^used_memory:"     # 寫入後，相減 ÷ 100000 = 每筆平均
```

## 主機規格與 maxmemory

```text
實體記憶體
├── maxmemory（資料）
├── copy-on-write 預留（BGSAVE / AOF rewrite 期間被修改的頁面）
├── 用戶端輸出緩衝、複製緩衝（repl-backlog、replica 輸出緩衝）
├── 記憶體碎片（mem_fragmentation_ratio 通常 1.0～1.5）
└── OS 與其他程式
```

| 實體記憶體 | 開持久化的 `maxmemory` | 純快取（不持久化）的 `maxmemory` |
| :--- | :--- | :--- |
| 8 GB | 5gb | 6gb |
| 16 GB | 10gb | 12gb |
| 32 GB | 20gb | 25gb |
| 64 GB | 40gb | 50gb |

單一實例不建議太大：資料越多，fork 越慢、全量同步越久、重啟載入越久。實務上常把單一實例控制在 10～25 GB，超過就拆成多個實例或改用 Cluster。

## 淘汰策略

| 策略 | 淘汰範圍 | 演算法 | 適用 |
| :--- | :--- | :--- | :--- |
| `noeviction`（預設） | 不淘汰，寫入回錯誤 | — | 當資料庫用、不能丟資料 |
| `allkeys-lru` | 所有 key | 最久沒存取 | **通用快取的首選** |
| `allkeys-lfu` | 所有 key | 存取頻率最低 | 有明顯熱點的快取 |
| `allkeys-random` | 所有 key | 隨機 | 存取平均分布 |
| `volatile-lru` / `volatile-lfu` / `volatile-random` | 只有設 TTL 的 key | 同上 | 快取與永久資料混用 |
| `volatile-ttl` | 只有設 TTL 的 key | TTL 最短的 | 想先淘汰快過期的 |

- `volatile-*` 在沒有任何 key 設 TTL 時，行為等同 `noeviction`，記憶體滿了一樣會拒絕寫入。
- LRU / LFU 都是抽樣近似（`maxmemory-samples` 預設 5）。
- 淘汰本身也耗 CPU，記憶體長期貼著上限、每秒淘汰大量 key 時，延遲會上升。**看到 `evicted_keys` 持續增加，就該擴容**。

## 擴展的順序

1. **先減量**：清掉沒設 TTL 的垃圾資料、拆大 key、壓縮 value（JSON 改 MessagePack、gzip 長文字）、小 key 合併成 Hash。
2. **垂直擴展**：換更大的機器。Sentinel 架構可以先擴從庫再切換，幾乎不停機。
3. **讀寫分離**：讀取量大時加從庫分擔讀取。要注意從庫的資料可能有延遲，不適合「寫完馬上讀」的場景。
4. **水平擴展（Cluster）**：資料量或寫入量超過單機上限時才上 Cluster。

## Cluster 擴容

新增一組主從（`192.168.58.37` 主、`.38` 從），再把 slot 搬過去：

```bash
# 1. 加入主庫
redis-cli -a '<密碼>' --cluster add-node 192.168.58.37:6379 192.168.58.31:6379
# 2. 加入從庫並指定它的主庫
redis-cli -a '<密碼>' --cluster add-node 192.168.58.38:6379 192.168.58.31:6379 \
  --cluster-slave --cluster-master-id <新主庫的 node id>
# 3. 平均分配 slot（含空的主庫）
redis-cli -a '<密碼>' --cluster rebalance 192.168.58.31:6379 --cluster-use-empty-masters
# 4. 檢查
redis-cli -a '<密碼>' --cluster check 192.168.58.31:6379
```

7.x 的搬遷是逐 key `MIGRATE`：

- 搬遷期間用戶端會收到 `ASK` 重導向，用戶端函式庫要支援。
- 搬到大 key 時 `MIGRATE` 會阻塞來源與目標節點，**搬遷前先處理大 key**，並選離峰時間進行。
- 可以用 `--cluster-pipeline` 調整每批搬遷的 key 數。

縮容則是反過來：先 `reshard` 把要移除節點的 slot 全部搬走，再 `--cluster del-node`。

## Hash Tag 與多 key 操作

Cluster 依 `CRC16(key) mod 16384` 決定 slot，多 key 指令（`MGET`、`MULTI`、Lua）的 key 必須在同一個 slot，否則回 `CROSSSLOT` 錯誤。用大括號指定只用哪一段計算 slot：

```text
{order:1001}:items
{order:1001}:total     → 兩個 key 只用 "order:1001" 計算，一定在同一個 slot
```

不要讓太多資料共用同一個 hash tag，否則會集中在一個 slot、形成熱點。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| slot 搬遷 | `MIGRATE` 逐 key 搬，大 key 會阻塞、用戶端要處理 `ASK` | 8.4 新增 `CLUSTER MIGRATION` 原子 slot 搬遷；8.10 起 `redis-cli --cluster reshard / rebalance` 預設使用它 |
| 搬遷相關參數 | — | `cluster-slot-migration-write-pause-timeout`、`cluster-slot-migration-handoff-max-lag-bytes` |
| 淘汰策略 | 8 種 | 8.6 新增 `volatile-lrm`、`allkeys-lrm`（依「最近修改」而不是「最近存取」淘汰） |
| 記憶體用量 | — | 8.6 降低 Hash（hashtable）與 Sorted Set（skiplist）的記憶體；8.4 起 JSON 同質陣列最多可省 91%；8.10 compact hash |
| 單機轉 Cluster 評估 | 要自己檢查程式 | 8.0 新增 `cluster-compatibility-sample-ratio`，抽樣統計不相容 Cluster 的指令（`INFO` 的 `cluster_incompatible_ops`） |
| slot 用量 | 無 | 8.2～8.4 新增 `CLUSTER SLOT-STATS`，找出熱點 slot |

### 給容量規劃的升級建議

- 同樣的資料在 8.6 之後通常用更少記憶體，升級前後記得重新量測，調整 `maxmemory` 與擴容計畫。
- 準備從 Standalone / Sentinel 轉 Cluster 的團隊，可以在 8.x 上先開 `cluster-compatibility-sample-ratio`，觀察應用程式有多少指令會不相容。
- 8.4 以後擴縮容不再怕大 key 卡住搬遷，但仍建議在離峰時間進行。

## 小結

- 記憶體估算要用真實樣本量測，內部開銷不可忽略。
- 開持久化時 `maxmemory` 抓實體記憶體的 60%～65%；單一實例不要太大。
- 快取首選 `allkeys-lru`；`volatile-*` 在沒有 TTL 時等同 `noeviction`。
- 先減量、再垂直擴展、最後才上 Cluster；多 key 操作用 hash tag。

下一篇：[安全與權限管理]({% post_url 2026-10-24-redis-ops-07-security %})。

### 參考資料

- [Key eviction](https://redis.io/docs/latest/develop/reference/eviction/)
- [Memory optimization](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/)
- [Scale with Redis Cluster](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)
- [Redis 8.6 release notes](https://github.com/redis/redis/blob/8.6/00-RELEASENOTES)
