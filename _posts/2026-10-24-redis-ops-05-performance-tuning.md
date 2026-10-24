---
title: Redis 運維 05：效能調校
date: 2026-10-24 11:40:00 +0800
categories: [Redis, 效能調校]
tags: [redis, redis7, redis8, dba, performance, latency, pipeline, bigkey, io-threads]
description: 以 Redis 7.4 為主，從單執行緒模型出發，整理延遲的來源、大 key 與 O(N) 指令、Pipeline 與連線池、I/O 多執行緒、Lazy Free、編碼門檻與持久化對效能的影響，並比較 8.x 的效能改進。
---

Redis 每秒可以處理十萬以上的指令，但只要一個不當的指令就能讓所有用戶端一起卡住。原因很簡單：**指令是由單一主執行緒依序執行的**。本篇以 Redis 7.4 為主，整理調校的方向，最後比較 8.x。

{% include redis-ops-series.md %}

## 先理解單執行緒模型

```text
用戶端 ─┐
用戶端 ─┼─► 網路讀取 ─► 主執行緒依序執行指令 ─► 網路寫回
用戶端 ─┘   （io-threads 可分擔）   （永遠只有一個）    （io-threads 可分擔）

背景執行緒：lazy free 釋放記憶體、AOF fsync、關閉檔案
子行程：BGSAVE、AOF rewrite（fork）
```

- 一個指令執行 100 ms，其他所有用戶端就排隊 100 ms。
- `io-threads` 只分擔網路讀寫與協定解析，**指令本身仍然是單執行緒**。
- 所以調校的第一原則：**不要讓任何單一指令跑太久**。

## 調校流程

1. 用 `redis-cli --latency` 從用戶端量測，確認慢的是 Redis 還是網路。
2. `SLOWLOG GET` 找出慢指令；`LATENCY DOCTOR` 看是否和 fork、AOF 有關。
3. `INFO commandstats` 找出呼叫次數最多、累計耗時最多的指令。
4. `--bigkeys` / `--memkeys` 找出大 key。
5. 調整指令或資料結構，最後才是調參數。

## 大 key 與 O(N) 指令

最常見的延遲兇手：

| 指令 | 問題 | 替代方案 |
| :--- | :--- | :--- |
| `KEYS *` | 掃描全部 key | `SCAN` 分批 |
| `HGETALL`、`SMEMBERS`、`LRANGE 0 -1` | 大集合一次回傳全部 | `HSCAN` / `SSCAN`，或只取需要的欄位 |
| `DEL` 大 key | 同步釋放幾百萬個元素 | `UNLINK`，或開 `lazyfree-lazy-user-del yes` |
| `FLUSHALL` | 同步清空 | `FLUSHALL ASYNC`，或開 `lazyfree-lazy-user-flush yes` |
| `SORT`、`ZUNIONSTORE` 大集合 | 計算量大 | 在應用程式端處理，或預先計算 |
| 長時間的 Lua 腳本 | 執行期間其他指令全部等待 | 拆小、限制處理筆數 |

大 key 的拆分方式：

```text
# 一個 Hash 存 100 萬個使用者 → 依 ID 分桶
user:profile           → user:profile:{0..999}   （HSET user:profile:{id % 1000} id ...）
# 一個 List 當佇列存了幾百萬筆 → 改用 Stream 並設定 MAXLEN
XADD events MAXLEN ~ 1000000 * ...
```

## 網路：Pipeline 與連線池

Redis 單一指令的執行時間通常是微秒等級，真正的成本在**網路往返（RTT）**。

```python
# 1000 次往返
for i in range(1000):
    r.set(f"k:{i}", i)

# 1 次往返
with r.pipeline(transaction=False) as p:
    for i in range(1000):
        p.set(f"k:{i}", i)
    p.execute()
```

- 批次操作一律用 Pipeline，或用 `MSET` / `MGET` 等多 key 指令。單次 Pipeline 建議不超過數千個指令，避免單次回應太大。
- 用連線池，不要每個請求都建新連線（建立連線、`AUTH` 都有成本）。連線池大小抓「應用程式並行數」即可，太大只是增加 Redis 的連線數。
- 應用與 Redis 在同一台時可以用 Unix socket。
- 讀多寫少的資料可以用 6.0 起的 **Client-side caching**（`CLIENT TRACKING`），讓用戶端快取熱資料，Redis 在資料變動時通知失效。

## I/O 多執行緒

```ini
io-threads 4            # 8 vCPU 建議 4；4 核以下維持 1
io-threads-do-reads no  # 7.x 預設；官方說明讀取多執行緒通常幫助不大
```

- 只有在 **CPU 瓶頸出現在網路處理**（大量連線、高 QPS 的小指令）時才有明顯效果。
- 設定要重啟才生效（`CONFIG SET` 不能改）。
- 7.x 的 I/O 執行緒和 TLS 不相容。
- 用 `redis-benchmark` 測試時要加 `--threads`，否則瓶頸在壓測工具本身。

## Lazy Free

7.x 的 `lazyfree-*` 預設全部是 `no`，代表淘汰、過期、`DEL`、從庫全量同步清空舊資料時，大 key 都在主執行緒同步釋放。建議全部打開：

```ini
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
replica-lazy-flush yes
lazyfree-lazy-user-del yes
lazyfree-lazy-user-flush yes
```

## 資料結構的編碼

小集合用 listpack（緊湊的連續記憶體）儲存，省記憶體；超過門檻會轉成 hashtable / skiplist：

| 參數 | 7.4 預設 |
| :--- | :--- |
| `hash-max-listpack-entries` / `-value` | 512 / 64 |
| `zset-max-listpack-entries` / `-value` | 128 / 64 |
| `set-max-intset-entries` | 512 |
| `set-max-listpack-entries` / `-value` | 128 / 64 |
| `list-max-listpack-size` | -2（每節點 8 KB） |

- 調大門檻可以省記憶體，但 listpack 的操作是 O(N)，元素太多時 CPU 會增加。預設值是官方權衡過的結果，一般不需要調整。
- 用 `OBJECT ENCODING <key>` 查看目前的編碼。
- 利用這個特性的經典技巧：把大量小 key 合併成小 Hash（例如 `HSET user:1000 name ...` 取代 `SET user:1000:name ...`），在 key 數量很大時能大幅省記憶體。

## 持久化對效能的影響

| 來源 | 影響 | 緩解 |
| :--- | :--- | :--- |
| fork（BGSAVE / AOF rewrite） | 大資料集時 fork 本身可能花數百毫秒，期間主執行緒停住 | 主機用實體機或支援大頁表的 VM；在從庫做 BGSAVE；單一實例不要太大（實務上常控制在 10～25 GB） |
| copy-on-write | fork 後寫入越多，記憶體增加越多 | 預留記憶體（`maxmemory` 抓 60%～65%） |
| AOF `everysec` | 磁碟忙時 fsync 變慢，背景執行緒等太久主執行緒會延遲寫入 | 用 SSD；AOF 和其他高 IO 服務分開 |
| AOF rewrite + RDB 同時進行 | IO 加倍 | Redis 本身會避免同時進行 |

只當純快取、可以接受資料全失時，關掉持久化（`save ""`、`appendonly no`）是最大的效能提升。

## 用 redis-benchmark 驗證

```bash
redis-benchmark -h 127.0.0.1 -a '<密碼>' -q -n 1000000 -c 50 -t set,get --threads 4
redis-benchmark -h 127.0.0.1 -a '<密碼>' -q -n 1000000 -c 50 -t set,get -P 16   # Pipeline 16
```

壓測結果只能用來比較「調整前後」，不能直接代表正式環境的效能。正式環境的指令組合、key 大小、網路都不同。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| I/O 多執行緒 | 主執行緒和 I/O 執行緒輪流處理，讀取預設不分擔 | 8.0 全新實作：每個 I/O 執行緒負責一批連線的讀寫與解析，多核心的吞吐明顯提高；8.4 再提升（官方數據：4 核、90% GET 情境 > 30%） |
| 指令預取 | 無 | 8.4 新增可調整的 `lookahead`（預設 16），控制處理 Pipeline 時往後預取的指令深度 |
| 記憶體 | — | 8.6 大幅降低 hashtable 編碼的 Hash 與 skiplist 編碼的 Sorted Set 記憶體；8.10 新增 compact hash（同結構的 Hash 共用欄位名稱，`hash-*-template-entries` 控制） |
| 新的原子指令 | — | 8.0 `HGETDEL` / `HGETEX` / `HSETEX`；8.4 `MSETEX`、`SET` 的比較後寫入；8.8 `INCREX`（計數器限流），可以取代部分 Lua 腳本 |
| 其他 | — | 8.0 起有超過 30 項效能改進（`GET` 高 Pipeline、`LRANGE`、`HGETALL`、`PFCOUNT` SIMD 等） |

### 給效能調校的升級建議

- 7.x 開 `io-threads` 效果有限的環境，升級到 8.x 後值得重新測試，新實作在多核心上的擴展性好很多。
- 8.x 新增的原子指令（`HSETEX`、`MSETEX`、`INCREX`）可以取代原本用 Lua 或 `MULTI` 組合的邏輯，減少往返與腳本執行時間。
- 8.10 的 compact hash 預設關閉（`hash-*-template-entries 0`），大量同結構 Hash 的場景可以評估開啟。

## 小結

- 單執行緒模型下，**一個慢指令會拖慢所有人**。先處理大 key 與 O(N) 指令。
- 網路往返是主要成本，用 Pipeline、多 key 指令與連線池。
- Lazy Free 建議全部開啟；`io-threads` 在網路成為瓶頸時才有幫助。
- fork 的延遲與記憶體是持久化的主要代價。

下一篇：[容量規劃與擴展]({% post_url 2026-10-24-redis-ops-06-capacity-scaling %})。

### 參考資料

- [Redis benchmark](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/)
- [Diagnosing latency issues](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/)
- [Memory optimization](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/memory-optimization/)
- [Client-side caching](https://redis.io/docs/latest/develop/reference/client-side-caching/)
- [Redis 8.4 release notes](https://github.com/redis/redis/blob/8.4/00-RELEASENOTES)
