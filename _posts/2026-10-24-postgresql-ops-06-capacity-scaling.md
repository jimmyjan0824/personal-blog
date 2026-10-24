---
title: PostgreSQL 運維 06：容量規劃與擴展
date: 2026-10-24 13:50:00 +0800
categories: [PostgreSQL, 容量規劃]
tags: [postgresql, postgresql17, postgresql18, dba, capacity, partitioning, read-replica, citus, archiving]
description: 以 PostgreSQL 17 為主，整理容量量測與成長預估、分區表、讀寫分離、垂直與水平擴展（Citus）、歷史資料歸檔，並比較 18 的差異。
---

容量規劃要回答兩個問題：**現在多大、多久會滿**，以及**滿了之後怎麼辦**。本篇先量測與預估，再由簡到繁整理擴展手段，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 量測：先知道現在多大

```sql
-- 各資料庫大小
SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;

-- 最大的 10 張表（含索引與 TOAST）
SELECT relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       pg_size_pretty(pg_total_relation_size(c.oid) - pg_relation_size(c.oid) - pg_indexes_size(c.oid)) AS toast,
       c.reltuples::bigint AS est_rows
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 10;

-- WAL 產生速度：每小時記一次，相減就是寫入量
SELECT now(), pg_current_wal_lsn(), pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0'));
```

除了資料本身，還要算進：

| 項目 | 估算 |
| :--- | :--- |
| 索引 | 常是資料的 30%～100% |
| 膨脹 | 預留 20%～30%，更新頻繁的表更多 |
| `pg_wal` | 約 `max_wal_size` 的 1～2 倍，加上 slot 保留量（上限 `max_slot_wal_keep_size`） |
| 暫存檔 | 大型排序、建索引時暫時使用 |
| 維運空間 | `pg_repack` 需要一份表的大小、`VACUUM FULL` 也是 |
| 本機備份 | 若備份放同一台 |

## 預估：多久會滿

每天把最大的幾張表與資料庫大小記錄到監控系統，用最近 3 個月的成長斜率推算。簡單的做法：

```sql
CREATE TABLE IF NOT EXISTS dba_capacity_log (
  ts date DEFAULT current_date, relname text, total_bytes bigint, PRIMARY KEY (ts, relname));

INSERT INTO dba_capacity_log (relname, total_bytes)
SELECT relname, pg_total_relation_size(oid) FROM pg_class
WHERE relkind IN ('r', 'p') AND relnamespace = 'public'::regnamespace
ON CONFLICT DO NOTHING;
```

原則：**磁碟用量 70% 就要啟動擴容或歸檔計畫**，因為擴容（換機、搬資料）本身需要時間，而 PostgreSQL 磁碟滿時會直接停止寫入（WAL 寫不進去就是 `PANIC`）。

## 擴展手段，由簡到繁

### 1. 先清理

- 刪除沒在用的索引（見[效能調校]({% post_url 2026-10-24-postgresql-ops-05-performance-tuning %})）。
- 處理膨脹：`pg_repack` 線上重建。
- 歷史資料歸檔（見下方）。

### 2. 垂直擴展

加 CPU、記憶體、換更快的磁碟。PostgreSQL 單機可以撐到數 TB、數萬 TPS，大多數系統這一步就夠了。加記憶體後記得照比例調整 `shared_buffers`、`effective_cache_size`。

### 3. 分區表（Declarative Partitioning）

```sql
CREATE TABLE events (
  id bigint GENERATED ALWAYS AS IDENTITY,
  created_at timestamptz NOT NULL,
  payload jsonb,
  PRIMARY KEY (id, created_at)          -- 主鍵必須包含分區鍵
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2026_10 PARTITION OF events FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE events_2026_11 PARTITION OF events FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE events_default PARTITION OF events DEFAULT;
```

| 好處 | 說明 |
| :--- | :--- |
| 刪除舊資料 | `DETACH PARTITION ... CONCURRENTLY` + `DROP TABLE`，瞬間完成，沒有膨脹 |
| 查詢裁剪 | `WHERE created_at >= ...` 只掃相關分區 |
| 維護 | VACUUM、REINDEX 以分區為單位 |

注意事項：

- 分區數量控制在數百個以內，太多會拖慢規劃時間。
- 查詢沒帶分區鍵時要掃所有分區。
- 分區要提前建好，用 **pg_partman** 自動建立與清理，或排程腳本。

### 4. 讀寫分離

用 [Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %}) 的從庫分擔讀取：

- 應用程式端：讀寫分兩組連線，或用支援讀寫分離的框架。
- 中介層：HAProxy 依 Patroni REST API 分流；Pgpool-II 可以解析 SQL 自動分流（設定複雜）。
- libpq 連線字串：`host=pg1,pg2,pg3 target_session_attrs=read-only`（14+ 支援 `read-only`、`primary`、`standby`、`prefer-standby`）。

注意**複製延遲**：剛寫入就讀從庫可能讀不到。需要「讀到自己剛寫的」的流程，讀主庫或用 `synchronous_commit = remote_apply`。

### 5. 水平擴展（分片）

| 方案 | 說明 |
| :--- | :--- |
| **Citus** | PostgreSQL 擴充套件，分散式資料表、平行查詢，開源 |
| 應用層分片 | 依租戶或使用者 ID 分到不同叢集，彈性最大但開發成本高 |
| 雲端 | Azure Cosmos DB for PostgreSQL（Citus）、AWS Aurora Limitless 等 |

分片會讓 JOIN、交易、Schema 變更都變複雜，**是最後的手段**。

## 歷史資料歸檔

| 做法 | 適用 |
| :--- | :--- |
| 分區 + `DETACH` 後 `pg_dump` 該分區再 `DROP` | 依時間分區的表，最乾淨 |
| 批次 `DELETE` + 搬到歸檔庫 | 沒有分區的表；每批 1 萬筆左右，避免長交易與大量 WAL |
| 搬到歸檔庫後用 `postgres_fdw` 查詢 | 需要偶爾查歷史資料 |

```sql
-- 沒有分區時的批次刪除：每次 1 萬筆，重複執行到 0
WITH batch AS (
  SELECT ctid FROM events_log WHERE created_at < now() - interval '1 year' LIMIT 10000
)
DELETE FROM events_log WHERE ctid IN (SELECT ctid FROM batch);
```

大量刪除後要讓 autovacuum 跟上（或手動 `VACUUM`），否則刪掉的空間不會被重複利用。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| 分區 | 分區表支援 identity 欄位、排他約束 | 分區表的規劃與執行效率持續改善 |
| 主鍵選擇 | `gen_random_uuid()`（v4）隨機寫入，大表索引膨脹 | `uuidv7()` 時間有序，插入集中在索引尾端 |
| 計算欄位 | 只有 `STORED` generated column（占空間） | 新增 **virtual generated column**（預設），讀取時計算、不占空間 |
| VACUUM | 記憶體用量大幅下降 | eager freezing，減少大表的 aggressive vacuum 尖峰 |
| `pg_upgrade` 停機 | 升級後要等 `ANALYZE` | 保留統計資訊、`--swap` 模式，大資料庫升級更快 |

### 給容量規劃的升級建議

- 新系統用 UUID 主鍵時，18 的 `uuidv7()` 對大表的索引大小與快取效率有實際幫助。
- 18 的 virtual generated column 可以取代一些「只為了查詢方便」的冗餘欄位。

## 小結

- 量測要包含索引、膨脹、WAL、維運空間；70% 就要開始行動。
- 擴展順序：清理 → 垂直擴展 → 分區 → 讀寫分離 → 分片。
- 時間序列資料一開始就用分區表，歸檔只要 `DETACH` + `DROP`。

下一篇：[安全與權限管理]({% post_url 2026-10-24-postgresql-ops-07-security %})。

### 參考資料

- [PostgreSQL 17 文件：Table Partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html)
- [PostgreSQL 17 文件：Database Object Size Functions](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-DBSIZE)
- [PostgreSQL 17 文件：libpq target_session_attrs](https://www.postgresql.org/docs/17/libpq-connect.html#LIBPQ-CONNECT-TARGET-SESSION-ATTRS)
- [pg_partman](https://github.com/pgpartman/pg_partman)
- [Citus documentation](https://docs.citusdata.com/)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
