---
title: MySQL 運維 08：變更管理與發布
date: 2026-10-24 09:37:00 +0800
categories: [MySQL, 變更管理]
tags: [mysql, mysql8, dba, ddl, online-ddl, gh-ost, pt-online-schema-change, flyway, liquibase]
description: 以 MySQL 8.0 為主，整理 Schema 變更審核、Online DDL 與 INSTANT 演算法、gh-ost / pt-online-schema-change、Flyway / Liquibase 版本控管與回滾方案，並比較 5.7 與 8.4 LTS 的差異。
---

正式環境中，Schema 變更是最常引發事故的操作之一：一個 `ALTER TABLE` 鎖住熱門表，整個服務就停了。本篇以 MySQL 8.0 為主，整理變更從審核、執行到回滾的完整流程，最後比較 5.7 與 8.4 的差異。

{% include mysql-ops-series.md %}

## 變更流程

```text
開發提交 migration ──► 自動檢查（lint） ──► DBA 審核 ──► 測試環境執行
       ──► 預估影響（表大小、鎖、複製延遲） ──► 排程上線 ──► 執行 + 監控 ──► 驗證 / 回滾
```

### 審核檢查清單

- 表有沒有主鍵？欄位型別、長度、`NOT NULL`、預設值合不合理？
- 新索引是否和既有索引重複？是否真的會被查詢用到？
- 這個 DDL 用哪種演算法（INSTANT / INPLACE / COPY）？會不會鎖表？
- 表有多大？要跑多久？磁碟空間夠不夠？
- 從庫會延遲多久？
- 應用程式是否**向前相容**（先加欄位再上程式，先下程式再刪欄位）？
- 回滾方案是什麼？

## Online DDL 與演算法

8.0 的 `ALTER TABLE` 有三種演算法：

| 演算法 | 行為 | 範例 |
| :--- | :--- | :--- |
| `INSTANT` | 只改資料字典，瞬間完成 | 在末尾或任意位置新增欄位（8.0.29+）、刪除欄位（8.0.29+）、改欄位預設值、改名 |
| `INPLACE` | 在原表上重建或建索引，期間允許 DML | 新增二級索引、`OPTIMIZE TABLE` |
| `COPY` | 複製整張表，期間阻擋 DML | 改欄位型別、改字元集 |

**明確指定演算法與鎖**，不支援時 MySQL 會直接報錯，而不是默默改用 COPY：

```sql
ALTER TABLE orders ADD COLUMN coupon_code VARCHAR(32) NULL, ALGORITHM=INSTANT;
ALTER TABLE orders ADD INDEX idx_coupon (coupon_code), ALGORITHM=INPLACE, LOCK=NONE;
```

### 小心 Metadata Lock（MDL）

即使是 `INSTANT`，DDL 一開始與結束時仍需要取得**排他 MDL**。若剛好有一個未提交的長交易碰過這張表，DDL 就會等待，而後面所有對這張表的查詢又會排在 DDL 後面，形成連鎖阻塞。

```sql
-- 上線前先檢查長交易
SELECT trx_id, trx_started, trx_mysql_thread_id, trx_query
FROM information_schema.innodb_trx
WHERE trx_started < NOW() - INTERVAL 60 SECOND;

-- 為 DDL 設定較短的 MDL 等待時間，等不到就放棄，避免拖垮服務
SET SESSION lock_wait_timeout = 5;
ALTER TABLE orders ADD COLUMN memo VARCHAR(255) NULL, ALGORITHM=INSTANT;
```

> 用 `sys.schema_table_lock_waits` 可以看到誰持有 MDL、誰在等。DDL 卡住時，先 KILL DDL 本身通常是最安全的選擇。
{: .prompt-tip }

## 線上 Schema 變更工具

當 DDL 只能用 COPY、或 INPLACE 會造成嚴重複製延遲時，改用工具：

### gh-ost

```bash
gh-ost \
  --host=replica-1 --database=shop --table=orders \
  --alter="MODIFY amount DECIMAL(14,2) NOT NULL" \
  --user=ghost --password=*** \
  --max-load=Threads_running=50 \
  --critical-load=Threads_running=200 \
  --max-lag-millis=1500 \
  --chunk-size=1000 \
  --postpone-cut-over-flag-file=/tmp/ghost.postpone \
  --execute
```

- 透過讀取 **binlog** 同步增量變更，不使用 trigger，對主庫負載低。
- 可以暫停、調速，並由人工決定 cut-over 時機（刪除 postpone 檔案即切換）。
- 需要 `binlog_format=ROW` 與 `binlog_row_image=FULL`。

### pt-online-schema-change

```bash
pt-online-schema-change \
  --alter "ADD INDEX idx_user_created (user_id, created_at)" \
  D=shop,t=orders \
  --max-load Threads_running=50 --critical-load Threads_running=200 \
  --max-lag 2 --chunk-size 1000 --execute
```

- 用 **trigger** 同步增量變更，相容性高。
- trigger 會增加寫入成本；有外鍵的表要特別小心 `--alter-foreign-keys-method`。

| 比較 | gh-ost | pt-osc |
| :--- | :--- | :--- |
| 增量同步 | binlog | trigger |
| 主庫額外負載 | 低 | 較高 |
| 可暫停 | 可以 | 有限 |
| 外鍵支援 | 不支援 | 支援 |
| 需求 | ROW binlog | 表上不能已有同類型 trigger（舊版限制） |

> 使用前確認工具版本支援你的 MySQL 版本。8.4 移除了 `SHOW SLAVE STATUS` 等舊語法，太舊的工具版本會直接失敗。
{: .prompt-warning }

## 版本控管：Flyway 與 Liquibase

```text
db/migration/
├── V1__init_schema.sql
├── V2__add_orders_coupon.sql
└── V3__add_idx_orders_coupon.sql
```

```bash
flyway -url=jdbc:mysql://db:3306/shop -user=migrator -password=*** migrate
flyway info
```

- Schema 變更與程式碼一起進 Git，在 PR 中審核。
- 每個環境的 Schema 版本可以追溯（`flyway_schema_history` 表）。
- **大表變更不要直接交給 migration 工具跑**，應由 DBA 用 gh-ost 執行後，再標記為已套用。
- Liquibase 支援 XML/YAML/SQL 格式與 rollback 定義，適合需要多種資料庫的團隊。

## 回滾方案

| 變更 | 回滾方式 |
| :--- | :--- |
| 新增欄位 / 索引 | 刪除即可（可先用隱藏索引觀察） |
| 刪除索引 | 先 `ALTER INDEX ... INVISIBLE` 觀察一週，有問題立即 `VISIBLE` |
| 刪除欄位 | 先停止程式使用 → 改名保留一段時間 → 確認後再刪；刪除前備份該欄資料 |
| 修改型別 | gh-ost 可保留舊表（`_orders_del`），確認後再刪 |
| 資料修正（UPDATE/DELETE） | 執行前先 `SELECT ... INTO` 備份受影響資料，或依 binlog 反向產生 SQL |

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| `ALGORITHM=INSTANT` | 無 | 8.0.12+（新增欄位在末尾），8.0.29+（任意位置、刪除欄位） | 有 |
| Atomic DDL | 無，crash 可能留下殘骸 | 有，DDL 失敗會完整回滾 | 有 |
| 資料字典 | `.frm` 檔，DDL 不具交易性 | InnoDB 資料字典 | 同 8.0 |
| `RENAME COLUMN` | 無，需 `CHANGE COLUMN` 重寫定義 | 有 | 有 |
| 隱藏索引 | 無 | 有 | 有 |
| 隱藏欄位 | 無 | 8.0.23+ `INVISIBLE` 欄位 | 有 |
| 平行建索引 | 無 | 8.0.27+ `innodb_ddl_threads` | 有 |
| 非標準外鍵（參照非唯一鍵） | 允許 | 允許 | `restrict_fk_on_non_standard_key` 預設 `ON`，**拒絕** |
| 保留字 | — | 新增 `RANK`、`GROUPS`、`WINDOW`、`LATERAL` 等 | 同 8.0，升級前仍應跑升級檢查工具 |
| `LOCK TABLES ... LOW_PRIORITY` | 可用 | 棄用 | **語法錯誤** |
| `ALTER/DROP TABLESPACE ... ENGINE` | 可用 | 棄用 | **移除**（大多數情況） |

### 升級時的變更管理重點

- 5.7 → 8.0：檢查 migration 裡是否有用到新保留字當欄位名（例如 `rank`、`groups`），沒加反引號會在 8.0 報語法錯誤。
- 8.0 → 8.4：參照非唯一鍵或部分鍵的外鍵會被拒絕，既有 migration 重新跑（例如建新環境）時可能失敗。
- 8.0 的 INSTANT 新增欄位有次數上限（每張表最多 64 次 row version），超過後要重建表才能再用 INSTANT。

## 小結

- 先決定演算法，明確寫出 `ALGORITHM` 與 `LOCK`；上線前檢查長交易，設定 `lock_wait_timeout`。
- 大表變更交給 gh-ost / pt-osc，並控制負載與複製延遲。
- Schema 進版本控管，每個變更都要有回滾方案。

下一篇：[故障排查與事件處理]({% post_url 2026-10-24-mysql-ops-09-troubleshooting %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Online DDL Operations](https://dev.mysql.com/doc/refman/8.0/en/innodb-online-ddl-operations.html)
- [MySQL 8.0 Reference Manual：Atomic Data Definition Statement Support](https://dev.mysql.com/doc/refman/8.0/en/atomic-ddl.html)
- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
- [gh-ost](https://github.com/github/gh-ost)
