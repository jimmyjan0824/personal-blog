---
title: MySQL 運維 05：效能調校
date: 2026-10-24 09:34:00 +0800
categories: [MySQL, 效能調校]
tags: [mysql, mysql8, dba, performance, explain, index, slow-query, proxysql]
description: 以 MySQL 8.0 為主，整理慢查詢分析、EXPLAIN / EXPLAIN ANALYZE、索引優化、SQL 改寫、參數調整與連線池，並比較 5.7 與 8.4 LTS 的差異。
---

效能問題十之八九出在 SQL 與索引，參數調整通常只是錦上添花。本篇以 MySQL 8.0 為主，依照「找出慢 SQL → 看懂執行計畫 → 改索引或改寫 → 調參數」的順序整理，最後比較 5.7 與 8.4 的差異。

{% include mysql-ops-series.md %}

## 第一步：找出慢查詢

```ini
slow_query_log                  = ON
long_query_time                 = 0.5
log_queries_not_using_indexes   = OFF   # 開啟會非常吵，視需要短暫打開
log_slow_extra                  = ON    # 8.0.14+，記錄更多欄位（Rows_examined、Bytes_sent…）
```

用 `pt-query-digest` 彙整：

```bash
pt-query-digest /var/lib/mysql/slow.log --limit 20 > slow_report.txt
```

報表會依「總耗時」排序。優先處理**總耗時最高**的 SQL，而不是單次最慢的那一筆；一支 10ms 但每秒執行 5000 次的 SQL，往往比一支 10 秒但一天跑一次的 SQL 更值得優化。

也可以直接從 sys schema 查：

```sql
SELECT query, exec_count, total_latency, rows_examined_avg, rows_sent_avg
FROM sys.statement_analysis
ORDER BY total_latency DESC LIMIT 10;
```

## 第二步：看懂執行計畫

### EXPLAIN

```sql
EXPLAIN SELECT o.id, o.amount
FROM orders o
WHERE o.user_id = 42 AND o.status = 'paid'
ORDER BY o.created_at DESC LIMIT 20;
```

重點欄位：

| 欄位 | 看什麼 |
| :--- | :--- |
| `type` | `ALL`（全表）< `index` < `range` < `ref` < `eq_ref` < `const`，越右越好 |
| `key` | 實際用到的索引 |
| `rows` × `filtered` | 預估要掃描並保留的列數 |
| `Extra` | `Using filesort`、`Using temporary` 是警訊；`Using index` 代表覆蓋索引 |

### EXPLAIN FORMAT=TREE 與 EXPLAIN ANALYZE（8.0.18+）

```sql
EXPLAIN ANALYZE
SELECT u.name, COUNT(*) FROM users u JOIN orders o ON o.user_id = u.id
WHERE o.created_at >= '2026-10-01' GROUP BY u.name;
```

```text
-> Table scan on <temporary>  (actual time=152..153 rows=812 loops=1)
    -> Aggregate using temporary table  (actual time=152..152 rows=812 loops=1)
        -> Nested loop inner join  (cost=4120 rows=9500) (actual time=0.08..120 rows=9312 loops=1)
            -> Index range scan on o using idx_created_at ...
            -> Single-row index lookup on u using PRIMARY (id=o.user_id) ...
```

`EXPLAIN ANALYZE` 會**真的執行** SQL，並列出每個步驟的實際時間與列數。拿「預估 rows」跟「實際 rows」比對，差很多就代表統計資訊不準。

> `EXPLAIN ANALYZE` 會實際執行查詢，不要對正式環境的 `UPDATE`/`DELETE` 或超重查詢使用。
{: .prompt-warning }

## 第三步：索引優化

### 複合索引的欄位順序

以上面的查詢為例，最佳索引是：

```sql
ALTER TABLE orders ADD INDEX idx_user_status_created (user_id, status, created_at);
```

原則：**等值條件在前、範圍或排序在後**。這樣可以同時滿足過濾與 `ORDER BY`，消除 `Using filesort`。

### 8.0 新增的索引功能

```sql
-- 隱藏索引：先隱藏觀察，確認沒影響再刪除，比直接 DROP 安全
ALTER TABLE orders ALTER INDEX idx_old INVISIBLE;
ALTER TABLE orders ALTER INDEX idx_old VISIBLE;     -- 有問題立即還原

-- 降冪索引（5.7 會忽略 DESC）
CREATE INDEX idx_created_desc ON orders (created_at DESC);

-- 函數索引（8.0.13+）
CREATE INDEX idx_email_lower ON users ((LOWER(email)));
SELECT * FROM users WHERE LOWER(email) = 'jimmy@example.com';

-- 直方圖：讓優化器知道非索引欄位的資料分布
ANALYZE TABLE orders UPDATE HISTOGRAM ON status WITH 16 BUCKETS;
```

### 常見讓索引失效的寫法

| 寫法 | 問題 | 改寫 |
| :--- | :--- | :--- |
| `WHERE DATE(created_at) = '2026-10-24'` | 對欄位套函數 | `created_at >= '2026-10-24' AND created_at < '2026-10-25'` |
| `WHERE phone = 912345678`（phone 是 VARCHAR） | 隱式型別轉換 | `WHERE phone = '912345678'` |
| `WHERE name LIKE '%jimmy'` | 前置萬用字元 | 全文索引或反轉欄位 |
| `ORDER BY RAND()` | 全表排序 | 應用程式端隨機取 ID |
| `LIMIT 1000000, 20` | 深分頁 | 改用 `WHERE id > ? LIMIT 20`（Keyset Pagination） |

## 第四步：SQL 改寫

8.0 支援 CTE 與 Window Function，很多以前要寫子查詢或在應用程式處理的邏輯都能更有效率：

```sql
-- 每位使用者最近一筆訂單
WITH ranked AS (
  SELECT o.*, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
  FROM orders o
)
SELECT * FROM ranked WHERE rn = 1;
```

8.0.18 起支援 **Hash Join**，沒有索引可用的等值 JOIN 不再只能用 Block Nested Loop，大表 JOIN 會快很多（8.0.20 起 BNL 完全被 Hash Join 取代）。

## 第五步：參數調整

| 參數 | 建議 | 說明 |
| :--- | :--- | :--- |
| `innodb_buffer_pool_size` | RAM 60%~75% | 最重要，影響命中率 |
| `innodb_redo_log_capacity` | 能容納約 1 小時寫入量 | 太小會頻繁 checkpoint |
| `innodb_io_capacity` | 依磁碟 IOPS 設定，SSD 可 2000+ | 影響背景刷髒頁速度 |
| `innodb_flush_neighbors` | SSD 設 0 | 8.0 預設已是 0 |
| `sort_buffer_size`、`join_buffer_size` | 維持預設（256KB） | 每連線分配，調大易 OOM |
| `tmp_table_size`、`max_heap_table_size` | 依需求調整 | 避免記憶體暫存表轉成磁碟 |
| `table_open_cache` | 依表數量調整 | 觀察 `Opened_tables` 增速 |

### 優化器提示（Optimizer Hints）

```sql
SELECT /*+ INDEX(o idx_user_status_created) */ * FROM orders o WHERE user_id = 42;
SELECT /*+ MAX_EXECUTION_TIME(2000) */ * FROM big_report;   -- 超過 2 秒自動中止
SELECT /*+ SET_VAR(sort_buffer_size = 16M) */ * FROM t ORDER BY c;  -- 8.0.3+ 單句調參
```

## 連線池

MySQL 是「一條連線一個執行緒」，連線數暴增時，context switch 會拖垮效能。

- **應用程式端連線池**：HikariCP、Go `database/sql` 等，設定合理的 max pool size。
- **ProxySQL**：集中管理連線複用、讀寫分離、SQL 路由與限流。
- **Thread Pool**：Enterprise 版與 Percona Server 提供，社群版沒有。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| Query Cache | 有（預設關閉） | **移除** | 移除 |
| `EXPLAIN ANALYZE` | 無 | 8.0.18+ | 有 |
| `EXPLAIN FORMAT=TREE` | 無 | 8.0.16+ | 有，另新增 `explain_json_format_version=2`（8.3+） |
| Hash Join | 無（只有 BNL） | 8.0.18+，8.0.20 取代 BNL | 有 |
| 直方圖 | 無 | 有 | 有 |
| 隱藏 / 降冪 / 函數索引 | 無（DESC 會被忽略） | 有 | 有 |
| CTE、Window Function | 無 | 有 | 有 |
| `SET_VAR` hint | 無 | 有 | 有 |
| Resource Groups | 無 | 有 | 有 |
| `innodb_adaptive_hash_index` 預設 | `ON` | `ON` | **`OFF`** |
| `innodb_change_buffering` 預設 | `all` | `all` | **`none`** |
| `innodb_io_capacity` 預設 | 200 | 200 | **10000** |
| `temptable_max_ram` 預設 | — （無 TempTable 引擎） | 1 GB | 總記憶體 3%（1~4 GB） |
| 內部暫存表引擎 | MEMORY | TempTable | TempTable |

### 從 5.7 升到 8.0 常見的效能退化

- **優化器變聰明但也可能選錯**：同一支 SQL 執行計畫改變。升級前用正式流量在測試環境重播比對。
- **Query Cache 消失**：原本靠 Query Cache 撐住的熱門查詢，要改由應用程式快取（如 Redis）處理。
- **字元集改為 `utf8mb4`**：索引長度與記憶體暫存表大小都會變大。

### 從 8.0 升到 8.4 要注意

8.4 關掉了 Adaptive Hash Index 與 Change Buffer。對大部分 SSD 環境是正面的（減少鎖競爭），但若你的工作負載是**大量等值查詢且資料能放進記憶體**，或是**HDD 上大量非唯一二級索引寫入**，可能會變慢。升級後務必觀察，必要時在 my.cnf 明確設回舊值。

## 小結

- 先找總耗時最高的 SQL，再用 `EXPLAIN ANALYZE` 比對預估與實際。
- 8.0 的隱藏索引、函數索引、直方圖、Hash Join、CTE 都是調校利器。
- 參數調整以 buffer pool、redo log、IO capacity 為主；每連線的 buffer 不要亂調。
- 升級前後都要做效能基準比對。

下一篇：[容量規劃與擴展]({% post_url 2026-10-24-mysql-ops-06-capacity-scaling %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Optimization](https://dev.mysql.com/doc/refman/8.0/en/optimization.html)
- [MySQL 8.0 Reference Manual：Obtaining Information with EXPLAIN ANALYZE](https://dev.mysql.com/doc/refman/8.0/en/explain.html#explain-analyze)
- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
