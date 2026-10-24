---
title: PostgreSQL 運維 05：效能調校
date: 2026-10-24 13:40:00 +0800
categories: [PostgreSQL, 效能調校]
tags: [postgresql, postgresql17, postgresql18, dba, performance, explain, index, vacuum, pgbouncer, auto_explain]
description: 以 PostgreSQL 17 為主，整理慢查詢定位、EXPLAIN 執行計畫判讀、索引類型與設計、SQL 改寫、VACUUM 與膨脹、參數調整與 PgBouncer 連線池，並比較 18 的差異。
---

效能問題九成出在 SQL 與索引，剩下的才是參數與硬體。本篇照「找出慢查詢 → 看懂執行計畫 → 修正索引與 SQL → 調參數 → 連線池」的順序整理，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 第一步：找出慢查詢

三個來源互補：

| 來源 | 看什麼 | 設定 |
| :--- | :--- | :--- |
| `pg_stat_statements` | 哪些 SQL **總耗時**最多（高頻的小查詢加起來常常最多） | `shared_preload_libraries` |
| 慢查詢日誌 | 個別超過門檻的執行，含實際參數 | `log_min_duration_statement = 1s` |
| `auto_explain` | 慢查詢**當下的執行計畫** | `shared_preload_libraries`、`auto_explain.log_min_duration` |

```ini
# postgresql.conf：auto_explain 自動記錄超過 3 秒的查詢計畫
shared_preload_libraries = 'pg_stat_statements,auto_explain'
auto_explain.log_min_duration = '3s'
auto_explain.log_analyze = on        # 記錄實際列數與時間（有額外開銷）
auto_explain.log_buffers = on
auto_explain.log_timing = off        # 關掉每個節點的計時，降低開銷
```

`auto_explain` 最大的價值是抓到「平常很快、偶爾很慢」的查詢：事後手動 `EXPLAIN` 時資料分布或參數不同，常常看不到當時的計畫。

## 第二步：看懂執行計畫

```sql
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
SELECT o.id, o.amount FROM orders o
WHERE o.customer_id = 1001 AND o.created_at >= now() - interval '30 days'
ORDER BY o.created_at DESC LIMIT 20;
```

判讀重點：

| 看什麼 | 代表 |
| :--- | :--- |
| `rows=` 估算 vs `actual rows=` 差很多（10 倍以上） | 統計資訊不準：`ANALYZE`、調高該欄位的 `STATISTICS`、或建立 extended statistics |
| `Seq Scan` 在大表上、只回傳少量列 | 缺索引，或條件寫法讓索引用不上 |
| `Rows Removed by Filter` 很大 | 索引不夠選擇性，考慮複合索引 |
| `Buffers: shared read=` 很大 | 從磁碟讀；`hit=` 是從 shared_buffers |
| `Sort Method: external merge  Disk:` | `work_mem` 不夠，排序落到暫存檔 |
| `Nested Loop` 外層列數很大 | 估算錯誤導致選錯 join 方式 |
| `Heap Fetches:`（Index Only Scan） | visibility map 不夠新，需要 vacuum |

> `EXPLAIN ANALYZE` 會**真的執行** SQL。對 `UPDATE` / `DELETE` 要包在交易裡：`BEGIN; EXPLAIN ANALYZE DELETE ...; ROLLBACK;`
{: .prompt-warning }

估算不準的常見原因是欄位之間有相關性（例如 `city` 和 `zip_code`），PostgreSQL 預設假設各欄位獨立：

```sql
CREATE STATISTICS orders_city_zip (dependencies, ndistinct) ON city, zip_code FROM orders;
ANALYZE orders;
```

## 第三步：索引

| 索引類型 | 適用 |
| :--- | :--- |
| B-tree（預設） | 等值、範圍、排序、`LIKE 'abc%'` |
| Hash | 只有等值，少用 |
| GIN | `jsonb`、陣列、全文檢索、`pg_trgm` 的模糊搜尋 |
| GiST | 幾何、範圍型別、排他約束 |
| BRIN | 依插入順序排列的超大表（例如時間序列），索引極小 |

設計原則：

```sql
-- 複合索引：等值條件在前、範圍條件在後，順便涵蓋 ORDER BY
CREATE INDEX CONCURRENTLY idx_orders_customer_created ON orders (customer_id, created_at DESC);

-- 部分索引：只索引需要的資料
CREATE INDEX CONCURRENTLY idx_orders_pending ON orders (created_at) WHERE status = 'pending';

-- 涵蓋索引（INCLUDE）：讓查詢只讀索引（Index Only Scan）
CREATE INDEX CONCURRENTLY idx_orders_customer_inc ON orders (customer_id) INCLUDE (amount);

-- 運算式索引：WHERE lower(email) = ... 才用得上
CREATE INDEX CONCURRENTLY idx_users_email_lower ON users (lower(email));
```

- 正式環境一律 `CREATE INDEX CONCURRENTLY`，不會鎖寫入（但比較慢，且失敗會留下 `INVALID` 索引要手動刪除）。
- 找出沒在用的索引（每個索引都會拖慢寫入）：

```sql
SELECT schemaname, relname, indexrelname, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0 AND indexrelid NOT IN (SELECT conindid FROM pg_constraint)
ORDER BY pg_relation_size(indexrelid) DESC;
```

統計是從上次重設開始算的，從庫上的使用次數也要一起看，確認後再刪。

## 第四步：SQL 改寫

| 寫法 | 問題 | 改寫 |
| :--- | :--- | :--- |
| `WHERE date(created_at) = '2026-10-24'` | 對欄位套函式，索引用不上 | `created_at >= '2026-10-24' AND created_at < '2026-10-25'` |
| `WHERE id::text = '123'` | 型別轉換在欄位上 | 讓參數轉型，欄位保持原型別 |
| `OFFSET 100000 LIMIT 20` | 要先掃過 10 萬筆 | Keyset 分頁：`WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT 20` |
| `SELECT *` | 讀取不必要的欄位，TOAST 欄位特別貴 | 只選需要的欄位 |
| `NOT IN (SELECT ...)` | 子查詢有 NULL 時結果錯誤，且常無法最佳化 | `NOT EXISTS` |
| 迴圈內逐筆 INSERT | 每筆都是一次往返與提交 | 批次 `INSERT ... VALUES (...), (...)` 或 `COPY` |
| `count(*)` 整張大表 | 必須掃描 | 允許近似值時用 `pg_class.reltuples` |

## VACUUM 與膨脹

PostgreSQL 的 MVCC 讓 `UPDATE` / `DELETE` 留下舊版本（死 tuple），由 VACUUM 回收。VACUUM 跟不上就會**膨脹（bloat）**：表與索引變大、掃描變慢、快取效率變差。

```sql
-- 大表個別調整 autovacuum（全域設定見安裝部署篇）
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_limit = 4000);

-- 實際膨脹程度（需要 pgstattuple 擴充套件，會掃全表）
SELECT * FROM pgstattuple('orders');
```

- 擋住 VACUUM 的三大元兇：**長交易**、**`idle in transaction`**、**失效或落後的 replication slot**（以及 `hot_standby_feedback = on` 的從庫上的長查詢）。
- 已經嚴重膨脹的表，`VACUUM` 只能讓空間重複利用，不會還給 OS；要縮小用 `pg_repack`（線上）或 `VACUUM FULL`（鎖表）。
- 頻繁更新的表可以設 `fillfactor = 80`，讓更新有機會在同一頁完成（HOT update），減少索引更新。

## 第五步：參數

參數的建議值與說明在 [Standalone 實作]({% post_url 2026-10-24-postgresql-lab-01-standalone %})的設定檔裡，這裡只列出「看到什麼症狀調什麼」：

| 症狀 | 參數 |
| :--- | :--- |
| 排序 / 雜湊落到暫存檔（`log_temp_files`） | `work_mem`（個別 session 或角色調高） |
| `checkpoints are occurring too frequently` | `max_wal_size` |
| 建索引、VACUUM 很慢 | `maintenance_work_mem`、`max_parallel_maintenance_workers` |
| 規劃器不愛用索引（SSD） | `random_page_cost = 1.1`、`effective_cache_size` |
| 大表 vacuum 跟不上 | `autovacuum_vacuum_cost_limit`、表層級的 `scale_factor` |
| 很多短查詢 JIT 編譯時間比執行還長 | `jit = off` |
| 連線數高、記憶體吃緊 | 降低 `max_connections`，改用 PgBouncer |

## 連線池：PgBouncer

PostgreSQL 每條連線是一個行程，連線建立成本高，數千條連線時光是行程切換與記憶體就吃不消。PgBouncer 放在應用程式與資料庫之間：

| 模式 | 說明 | 注意 |
| :--- | :--- | :--- |
| session | 用戶端斷線才歸還連線 | 效益最小 |
| **transaction** | 交易結束就歸還 | 最常用；session 層級的功能（`SET`、advisory lock、`LISTEN`）不能用 |
| statement | 每個語句歸還 | 不能用多語句交易 |

```ini
# /etc/pgbouncer/pgbouncer.ini（重點）
pool_mode = transaction
max_client_conn = 5000        ; 應用程式最多幾條連線到 PgBouncer
default_pool_size = 40        ; 每個 (使用者, 資料庫) 實際連到 PostgreSQL 的連線數，約 vCPU 數 × 2~4
max_prepared_statements = 200 ; 1.21+ 支援 transaction 模式下的 prepared statement
```

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| I/O | 新增 streaming I/O（循序掃描、ANALYZE 用合併讀取），`io_combine_limit` | **非同步 I/O**（`io_method = worker` 預設），循序掃描、bitmap heap scan、VACUUM 都能受益 |
| VACUUM 記憶體 | 新的 TID 儲存結構，記憶體用量大幅下降，不再受 1GB 限制 | 新增 eager freezing，平常的 vacuum 就順便凍結部分頁面，減少一次性的 aggressive vacuum |
| B-tree 多值查詢 | `IN (...)` 多值查詢的掃描最佳化 | 新增 **skip scan**：複合索引 `(a, b)` 上只有 `b` 的條件也可能用上索引 |
| 規劃器 | `IS NOT NULL` 在 NOT NULL 欄位上會被消除等 | 自我 join 消除（`enable_self_join_elimination`）、`OR` 條件轉成 `= ANY` 以利索引 |
| EXPLAIN | 新增 `SERIALIZE`、`MEMORY` 選項 | `ANALYZE` 預設帶 BUFFERS（開了 `track_io_timing` 還有 I/O Timings），顯示 `Index Searches`，`actual rows` 改成帶小數 |
| 平行建立索引 | B-tree、BRIN | 新增 GIN |
| `effective_io_concurrency` 預設 | 1 | 16 |
| UUID | `gen_random_uuid()`（v4，隨機分布） | 新增 `uuidv7()`：時間有序，B-tree 插入局部性好、索引不易膨脹 |

同一個查詢在 17.11 與 18.6 上的 `EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)`（實測）：

```text
-- 17.11
 Aggregate (actual rows=1 loops=1)
   ->  Index Only Scan using pg_class_tblspc_relfilenode_index on pg_class (actual rows=415 loops=1)
         Heap Fetches: 0

-- 18.6
 Aggregate (actual rows=1.00 loops=1)
   Buffers: shared read=2
   I/O Timings: shared read=0.014
   ->  Index Only Scan using pg_class_tblspc_relfilenode_index on pg_class (actual rows=415.00 loops=1)
         Heap Fetches: 0
         Index Searches: 1
         Buffers: shared read=2
         I/O Timings: shared read=0.014
 Planning:
   Buffers: shared hit=64 read=5
   I/O Timings: shared read=0.042
```

解析 EXPLAIN 輸出的工具或腳本（例如比對 `actual rows=` 的正規表示式）升級到 18 後要確認還能用。

### 給效能的升級建議

- 18 的非同步 I/O 對雲端塊儲存（延遲較高）的掃描型查詢改善最明顯；OLTP 的單筆查詢差異不大。升級前用自己的工作負載壓測。
- 升級後 `pg_upgrade` 在 18 會保留統計資訊，但仍建議對大表 `ANALYZE` 一次。
- 用 UUID 當主鍵的新系統，18 可直接用 `uuidv7()`。

## 小結

- 先用 `pg_stat_statements` 找總耗時最多的 SQL，用 `EXPLAIN (ANALYZE, BUFFERS)` 找原因。
- 索引設計：等值在前、範圍在後；善用部分索引與 INCLUDE；線上一律 `CONCURRENTLY`。
- VACUUM 跟不上就會膨脹，長交易是頭號敵人。
- 大量連線用 PgBouncer transaction 模式。

下一篇：[容量規劃與擴展]({% post_url 2026-10-24-postgresql-ops-06-capacity-scaling %})。

### 參考資料

- [PostgreSQL 17 文件：Using EXPLAIN](https://www.postgresql.org/docs/17/using-explain.html)
- [PostgreSQL 17 文件：Indexes](https://www.postgresql.org/docs/17/indexes.html)
- [PostgreSQL 17 文件：auto_explain](https://www.postgresql.org/docs/17/auto-explain.html)
- [PostgreSQL 17 文件：Routine Vacuuming](https://www.postgresql.org/docs/17/routine-vacuuming.html)
- [PgBouncer configuration](https://www.pgbouncer.org/config.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
