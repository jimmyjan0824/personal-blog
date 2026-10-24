---
title: PostgreSQL 運維 08：變更管理與發布
date: 2026-10-24 14:10:00 +0800
categories: [PostgreSQL, 變更管理]
tags: [postgresql, postgresql17, postgresql18, dba, ddl, migration, lock, flyway, liquibase, pg_repack]
description: 以 PostgreSQL 17 為主，整理變更流程、DDL 的鎖等級與 lock_timeout、哪些 DDL 會重寫整張表、線上變更的安全寫法、pg_repack、Flyway / Liquibase 版本控管與回滾方案，並比較 18 的差異。
---

PostgreSQL 的 DDL 有兩個和 MySQL 很不一樣的特性：**DDL 可以放在交易裡**（失敗就整個回滾），但**大部分 DDL 需要 `ACCESS EXCLUSIVE` 鎖**，排隊等鎖時會擋住後面所有查詢。本篇整理怎麼安全地上線 Schema 變更，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 變更流程

| 階段 | 做什麼 |
| :--- | :--- |
| 1. 申請 | 變更內容、原因、影響的表與資料量、回滾方式 |
| 2. 審核 | DBA 檢查鎖等級、是否重寫表、索引、執行時間 |
| 3. 測試 | 在接近正式資料量的環境執行並計時 |
| 4. 排程 | 離峰時段；確認備份與複製狀態正常 |
| 5. 執行 | 用版本控管工具執行，設定 `lock_timeout` |
| 6. 驗證 | 應用程式正常、錯誤率與延遲沒有上升 |
| 7. 記錄 | 實際執行時間、遇到的問題 |

## DDL 的鎖等級

| 操作 | 鎖 | 擋讀取？ | 擋寫入？ |
| :--- | :--- | :--- | :--- |
| `CREATE INDEX` | `SHARE` | 否 | **是** |
| `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | 否 | 否 |
| `ALTER TABLE ADD COLUMN`（無預設值或常數預設值） | `ACCESS EXCLUSIVE` | 是（瞬間） | 是（瞬間） |
| `ALTER TABLE ADD CONSTRAINT ... NOT VALID` | `SHARE ROW EXCLUSIVE` | 否 | 是（瞬間） |
| `ALTER TABLE VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` | 否 | 否 |
| `VACUUM`（一般） | `SHARE UPDATE EXCLUSIVE` | 否 | 否 |
| `VACUUM FULL`、`CLUSTER` | `ACCESS EXCLUSIVE` | **是** | **是** |
| `REINDEX` | `SHARE`（擋寫入）＋ 索引的 `ACCESS EXCLUSIVE` | 用到該索引的查詢 | 是 |
| `REINDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | 否 | 否 |

### 鎖佇列：最常見的事故

```text
1. 長查詢 A 正在讀 orders（持有 ACCESS SHARE）
2. ALTER TABLE orders ADD COLUMN ...（要 ACCESS EXCLUSIVE，等 A）
3. 之後所有讀寫 orders 的查詢都排在 ALTER 後面 → 整個服務卡住
```

`ALTER` 本身可能只要 1 毫秒，但它在佇列裡等鎖時會擋住後面所有人。解法是**一定要設 `lock_timeout`**，拿不到鎖就放棄、稍後重試：

```sql
SET lock_timeout = '3s';
SET statement_timeout = '30s';
ALTER TABLE orders ADD COLUMN note text;
```

Flyway / Liquibase 可以在每個 migration 開頭加上這兩行，或對 migration 專用帳號 `ALTER ROLE ... SET lock_timeout = '3s'`。

## 哪些 DDL 會重寫整張表

重寫表 = 複製一份新的表，期間持有 `ACCESS EXCLUSIVE`，大表可能要數十分鐘。

| 操作 | 重寫？ |
| :--- | :--- |
| `ADD COLUMN`（無預設值） | 否 |
| `ADD COLUMN ... DEFAULT 常數`（11+） | 否，只記在 catalog |
| `ADD COLUMN ... DEFAULT now()`、`random()` 等 volatile 預設值 | **是** |
| `ADD COLUMN ... GENERATED ALWAYS AS (...) STORED` | **是** |
| `DROP COLUMN` | 否，只標記刪除（空間在之後的更新中逐漸回收） |
| `ALTER COLUMN TYPE varchar(50) → varchar(100)` 或 `→ text` | 否 |
| `ALTER COLUMN TYPE int → bigint` | **是**，還要重建相關索引 |
| `SET NOT NULL` | 否，但要掃全表驗證（持有 `ACCESS EXCLUSIVE`） |
| `ALTER TABLE ... SET LOGGED / UNLOGGED` | **是** |

## 線上變更的安全寫法

### 新增 NOT NULL 欄位

```sql
-- 1. 加欄位（常數預設值，不重寫）
ALTER TABLE orders ADD COLUMN source text DEFAULT 'web';
-- 2. 如果要 NOT NULL：先加 CHECK NOT VALID（瞬間）
ALTER TABLE orders ADD CONSTRAINT orders_source_nn CHECK (source IS NOT NULL) NOT VALID;
-- 3. 驗證（不擋讀寫）
ALTER TABLE orders VALIDATE CONSTRAINT orders_source_nn;
-- 4. SET NOT NULL 會利用已驗證的 CHECK，不再掃表（12+）
ALTER TABLE orders ALTER COLUMN source SET NOT NULL;
ALTER TABLE orders DROP CONSTRAINT orders_source_nn;
```

### 新增外鍵

```sql
ALTER TABLE order_items ADD CONSTRAINT fk_order FOREIGN KEY (order_id) REFERENCES orders(id) NOT VALID;
ALTER TABLE order_items VALIDATE CONSTRAINT fk_order;
```

### 新增唯一約束

```sql
CREATE UNIQUE INDEX CONCURRENTLY uq_users_email ON users (email);
ALTER TABLE users ADD CONSTRAINT uq_users_email UNIQUE USING INDEX uq_users_email;
```

### int 主鍵快用完時改 bigint

直接 `ALTER COLUMN TYPE bigint` 會重寫表。線上做法：新增 `id_new bigint` 欄位 → trigger 同步新寫入 → 分批回填舊資料 → 建立唯一索引（`CONCURRENTLY`）→ 在短暫的維護窗口內切換主鍵與欄位名稱。步驟多，建議新表一開始就用 `bigint`。

### CONCURRENTLY 的注意事項

- 不能放在交易區塊裡（Flyway 要對該 migration 關閉交易，例如 `executeInTransaction=false`）。
- 失敗會留下 `INVALID` 索引，要 `DROP INDEX CONCURRENTLY` 後重來：

```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
```

## 線上重整：pg_repack

`VACUUM FULL` 會鎖表，`pg_repack` 用 trigger 記錄變更、在背景建立新表，只在最後切換時短暫持有鎖：

```bash
sudo dnf install -y pg_repack_17
pg_repack -h 127.0.0.1 -U postgres -d appdb -t app.orders --wait-timeout=30 -j 4
```

需要表上有主鍵或非 NULL 的唯一索引，並預留一份表大小的磁碟空間。

## 版本控管：Flyway 與 Liquibase

| 工具 | 特色 |
| :--- | :--- |
| Flyway | 純 SQL 檔案（`V1__init.sql`、`V2__add_column.sql`），簡單直覺 |
| Liquibase | XML / YAML / SQL，支援 rollback 定義、差異比對 |
| Sqitch | 以依賴關係而非版本號排序，每個變更都有 deploy / revert / verify |

原則：

- 所有 Schema 變更都進版本控管，**禁止直接在正式環境手動改**。
- Migration 檔案一旦上線就不能修改，要改就新增一個。
- CI 中先在空資料庫跑全部 migration，再用 [squawk](https://squawkhq.com/) 之類的工具檢查危險寫法（缺 `CONCURRENTLY`、缺 `lock_timeout`、會重寫表的型別變更）。

## 回滾方案

PostgreSQL 的 DDL 是交易性的，**單一 migration 失敗會自動回滾**（`CONCURRENTLY` 除外），不會留下改一半的狀態。真正難的是「上線成功但應用程式有問題」：

| 變更 | 回滾方式 |
| :--- | :--- |
| 新增欄位、表、索引 | 刪除即可，或保留不影響 |
| 刪除欄位 | **無法回滾**。先讓應用程式停止使用，觀察一個版本週期後再刪 |
| 改名 | 先新增新名稱、雙寫，再刪舊的（expand-contract） |
| 資料修正 | 執行前備份受影響的列：`CREATE TABLE bak_orders_20261024 AS SELECT * FROM orders WHERE ...;` |

**Expand-contract** 是最安全的模式：先「擴充」（新增欄位或表，舊程式不受影響）→ 部署新程式 → 確認穩定後再「收縮」（刪除舊欄位）。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| NOT NULL 約束 | 只能直接 `SET NOT NULL`（掃全表），或繞道用 CHECK | 可以 `ADD CONSTRAINT ... NOT NULL ... NOT VALID` 再 `VALIDATE`，NOT NULL 有自己的約束名稱 |
| Generated column | 只有 `STORED`，新增會重寫表 | 新增 **virtual**（且為預設），新增時不重寫表 |
| MERGE | 新增 `RETURNING`、可以對 view 執行 | 沿用 |
| `RETURNING` | 只能取新值 | 可以同時取 `OLD` 與 `NEW` 的值，方便記錄變更前後 |
| 時間區間約束 | 無 | 主鍵 / 唯一 / 外鍵支援 `WITHOUT OVERLAPS` / `PERIOD` |
| 分區表 | `SPLIT` / `MERGE PARTITION` 曾在 17 開發期間加入，但正式版前被撤回 | 尚未提供，仍需手動建新分區搬移 |

18.6 上的實測：表裡還有 NULL 時也能先加上 `NOT VALID` 的 NOT NULL 約束（只檢查之後的寫入），清掉 NULL 後再 `VALIDATE`；17.11 執行同樣的語法是 `syntax error`。

```text
postgres=# CREATE TABLE n (a int); INSERT INTO n VALUES (NULL);
postgres=# ALTER TABLE n ADD CONSTRAINT n_a_nn NOT NULL a NOT VALID;
ALTER TABLE
postgres=# DELETE FROM n; ALTER TABLE n VALIDATE CONSTRAINT n_a_nn;
ALTER TABLE
postgres=# SELECT conname, contype, convalidated FROM pg_constraint WHERE conrelid = 'n'::regclass;
 conname | contype | convalidated
---------+---------+--------------
 n_a_nn  | n       | t
```

`GENERATED ALWAYS AS (a * 2)` 不寫 `STORED`：18.6 建立的是 virtual 欄位（`attgenerated = 'v'`），17.11 則是語法錯誤。

### 給變更管理的升級建議

- 18 的 `NOT NULL ... NOT VALID` 讓「既有大表加 NOT NULL」不必再繞 CHECK 約束。
- 18 新增欄位時若沒寫 `STORED`，generated column 預設是 virtual，和 17 的行為不同，migration 要明確寫出想要的類型。

## 小結

- 每個 migration 都要設 `lock_timeout`，避免鎖佇列拖垮服務。
- 知道哪些 DDL 會重寫表；索引一律 `CONCURRENTLY`，約束先 `NOT VALID` 再 `VALIDATE`。
- 用 Flyway / Liquibase 版本控管，CI 加上危險寫法檢查。
- 刪除操作採 expand-contract，留一個版本週期的緩衝。

下一篇：[故障排查與事件處理]({% post_url 2026-10-24-postgresql-ops-09-troubleshooting %})。

### 參考資料

- [PostgreSQL 17 文件：Explicit Locking](https://www.postgresql.org/docs/17/explicit-locking.html)
- [PostgreSQL 17 文件：ALTER TABLE](https://www.postgresql.org/docs/17/sql-altertable.html)
- [PostgreSQL 17 文件：CREATE INDEX（Building Indexes Concurrently）](https://www.postgresql.org/docs/17/sql-createindex.html#SQL-CREATEINDEX-CONCURRENTLY)
- [pg_repack](https://reorg.github.io/pg_repack/)
- [Flyway](https://documentation.red-gate.com/flyway)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
