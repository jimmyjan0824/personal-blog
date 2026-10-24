---
title: MySQL vs PostgreSQL：該怎麼選？
date: 2026-10-24 09:00:00 +0800
categories: [資料庫比較]
tags: [mysql, postgresql, rdbms]
description: 從架構、資料型別、交易隔離、擴充性與使用情境，比較兩大開源關聯式資料庫。
---

MySQL 與 PostgreSQL 是最常見的兩套開源關聯式資料庫（RDBMS）。兩者都成熟、穩定，也都能撐起大型服務，但設計哲學不太一樣。這篇文章整理兩者的主要差異，幫助你在新專案中做選擇。

## 一句話總結

- **MySQL**：簡單、快速上手，讀取為主的 Web 應用非常普及，生態系與託管服務選擇多。
- **PostgreSQL**：功能完整、嚴格遵循 SQL 標準，擅長複雜查詢、進階資料型別與擴充。

## 快速比較

| 項目 | MySQL (InnoDB) | PostgreSQL |
| :--- | :--- | :--- |
| 授權 | GPL（另有商業授權） | PostgreSQL License（類 BSD） |
| 儲存引擎 | 可插拔，預設 InnoDB | 單一引擎 |
| 併發控制 | MVCC + undo log | MVCC（舊版本留在資料表中，需 VACUUM） |
| 預設隔離等級 | REPEATABLE READ | READ COMMITTED |
| JSON | `JSON` 型別 | `json` / `jsonb`（可建 GIN 索引） |
| 進階型別 | 較少 | 陣列、範圍型別、自訂型別、`hstore` 等 |
| 索引種類 | B-Tree、Full-text、Spatial | B-Tree、Hash、GIN、GiST、BRIN、SP-GiST |
| DDL 交易 | 不支援（DDL 會隱式提交） | 支援，可整批 rollback |
| 擴充 | Plugin | Extension（如 PostGIS、pg_stat_statements） |
| 複寫 | Binlog 複寫、Group Replication | Streaming / Logical Replication |

## 交易與 MVCC 的差異

兩者都使用 MVCC（多版本併發控制），讓讀不擋寫、寫不擋讀，但實作方式不同：

- **MySQL InnoDB** 直接在原地更新資料列，舊版本存放在 undo log，由背景 purge 執行緒清理。
- **PostgreSQL** 更新時會寫入一筆新版本的 tuple，舊版本留在原資料表，需要靠 `VACUUM`（通常是 autovacuum）回收空間。

這也是為什麼 PostgreSQL 的維運中，**autovacuum 調校與 table bloat 監控**是很重要的一環。

## 範例：JSON 查詢

PostgreSQL 的 `jsonb` 可以建立 GIN 索引，查詢 JSON 內容效率很好：

```sql
-- PostgreSQL
CREATE TABLE events (
    id      bigserial PRIMARY KEY,
    payload jsonb NOT NULL
);

CREATE INDEX idx_events_payload ON events USING GIN (payload);

SELECT id
FROM events
WHERE payload @> '{"type": "login"}';
```

MySQL 則可以透過產生欄位（generated column）再建立索引：

```sql
-- MySQL
CREATE TABLE events (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    payload    JSON NOT NULL,
    event_type VARCHAR(32) AS (payload->>'$.type') STORED,
    INDEX idx_event_type (event_type)
);

SELECT id
FROM events
WHERE event_type = 'login';
```

## 範例：DDL 也能 rollback

在 PostgreSQL 中，結構變更可以包在交易裡，失敗就整批還原：

```sql
BEGIN;
ALTER TABLE users ADD COLUMN nickname text;
CREATE INDEX idx_users_nickname ON users (nickname);
-- 發現有問題
ROLLBACK;  -- 欄位與索引都不會被建立
```

MySQL 的 DDL 會隱式提交（implicit commit），無法這樣做，因此上線變更前更需要規劃好 migration 步驟。

## 該選哪一個？

**比較適合 MySQL 的情境**

- 以簡單 CRUD、讀多寫少為主的 Web 應用
- 團隊已熟悉 MySQL 生態（如 LAMP、各種 PHP 框架）
- 需要大量現成的託管、分庫分表或中介層方案

**比較適合 PostgreSQL 的情境**

- 需要複雜查詢、視窗函數、CTE 或報表分析
- 會用到 `jsonb`、陣列、地理資訊（PostGIS）等進階型別
- 重視資料正確性與 SQL 標準相容性

> 兩者都是非常好的資料庫，沒有絕對的優劣。最重要的是了解團隊的經驗、應用的存取模式，以及未來的維運需求。
{: .prompt-tip }

## 小結

MySQL 以簡單與普及見長，PostgreSQL 則以功能與擴充性著稱。之後的文章會分別深入介紹兩者的索引、交易隔離與效能調校，歡迎持續關注！
