---
title: MySQL 運維 06：容量規劃與擴展
date: 2026-10-24 09:35:00 +0800
categories: [MySQL, 容量規劃]
tags: [mysql, mysql8, dba, capacity, partition, sharding, read-write-splitting, archive]
description: 以 MySQL 8.0 為主，整理資料成長預估、分區表、讀寫分離、分庫分表、垂直與水平擴展與歷史資料歸檔，並比較 5.7 與 8.4 LTS 的差異。
---

容量規劃要回答兩個問題：「現在的資源還能撐多久？」和「撐不住的時候要怎麼擴？」。本篇以 MySQL 8.0 為主，從量測、預估到擴展手段依序整理，最後比較 5.7 與 8.4 的差異。

{% include mysql-ops-series.md %}

## 量測：先知道現在多大

```sql
-- 各資料庫大小
SELECT table_schema,
       ROUND(SUM(data_length + index_length) / 1024 / 1024 / 1024, 2) AS size_gb
FROM information_schema.tables
GROUP BY table_schema ORDER BY size_gb DESC;

-- 前 20 大的表
SELECT table_schema, table_name, table_rows,
       ROUND(data_length / 1024 / 1024, 1)  AS data_mb,
       ROUND(index_length / 1024 / 1024, 1) AS index_mb,
       ROUND(data_free / 1024 / 1024, 1)    AS free_mb
FROM information_schema.tables
ORDER BY data_length + index_length DESC LIMIT 20;
```

> 8.0 的 `information_schema.tables` 統計值預設快取 24 小時（`information_schema_stats_expiry = 86400`）。做容量報表前可以 `SET SESSION information_schema_stats_expiry = 0;` 取得即時值。
{: .prompt-tip }

除了資料大小，還要量測：

- **磁碟**：資料檔 + binlog + relay log + undo + 暫存檔 + 備份暫存空間。
- **寫入量**：每天 binlog 產生量（`SHOW BINARY LOGS` 加總）。
- **流量**：尖峰 QPS/TPS、尖峰連線數、CPU 使用率。

## 預估：資料多久會滿

最簡單有效的方法是每天記錄一次大小，用線性回歸外推：

```sql
CREATE TABLE dba.capacity_history (
  snap_date  DATE,
  schema_name VARCHAR(64),
  table_name  VARCHAR(64),
  size_bytes  BIGINT,
  table_rows  BIGINT,
  PRIMARY KEY (snap_date, schema_name, table_name)
);
```

經驗法則：

- 磁碟使用率超過 **70%** 就要開始規劃擴容。
- 預留空間要能容納**最大那張表做一次 `ALTER TABLE` 重建**（Online DDL 需要額外一份表的空間）。
- binlog 保留天數 × 每日 binlog 量，也要算進去。

## 擴展手段，由簡到繁

```text
SQL / 索引優化
   └─► 垂直擴展（加 CPU / RAM / 換 NVMe）
         └─► 讀寫分離（加從庫）
               └─► 歷史資料歸檔 / 分區表
                     └─► 垂直分庫（依業務拆）
                           └─► 水平分表（Sharding）
```

越後面成本與複雜度越高，能用前面解決就不要跳到後面。

### 垂直擴展

最簡單也最常被低估。現在單台 MySQL 搭配 NVMe、數百 GB 記憶體，撐住數 TB 資料與上萬 QPS 並不少見。

### 讀寫分離

- 用 **ProxySQL** 或 **MySQL Router** 依規則把 `SELECT` 導向從庫。
- 要處理**複製延遲**造成的「寫完馬上讀不到」：對一致性要求高的讀取強制走主庫，或用 GTID 等待（`WAIT_FOR_EXECUTED_GTID_SET`）。

```sql
-- ProxySQL：SELECT ... FOR UPDATE 走主庫，其餘 SELECT 走從庫
INSERT INTO mysql_query_rules (rule_id, active, match_digest, destination_hostgroup, apply)
VALUES (1, 1, '^SELECT.*FOR UPDATE$', 10, 1),
       (2, 1, '^SELECT', 20, 1);
LOAD MYSQL QUERY RULES TO RUNTIME; SAVE MYSQL QUERY RULES TO DISK;
```

### 分區表（Partitioning）

適合「依時間查詢、依時間清除」的流水型資料，例如 log、訂單歷史：

```sql
CREATE TABLE access_log (
  id         BIGINT NOT NULL AUTO_INCREMENT,
  created_at DATETIME NOT NULL,
  user_id    BIGINT,
  path       VARCHAR(255),
  PRIMARY KEY (id, created_at)          -- 分區鍵必須包含在每個唯一鍵中
)
PARTITION BY RANGE COLUMNS (created_at) (
  PARTITION p202609 VALUES LESS THAN ('2026-10-01'),
  PARTITION p202610 VALUES LESS THAN ('2026-11-01'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)
);

-- 每月新增分區
ALTER TABLE access_log REORGANIZE PARTITION pmax INTO (
  PARTITION p202611 VALUES LESS THAN ('2026-12-01'),
  PARTITION pmax    VALUES LESS THAN (MAXVALUE)
);

-- 清除舊資料：瞬間完成，比 DELETE 快得多
ALTER TABLE access_log DROP PARTITION p202609;
```

分區不是萬靈丹：查詢條件沒帶分區鍵時，會掃描所有分區，反而更慢。

### 歷史資料歸檔

```bash
# pt-archiver：分批搬移並刪除，避免大交易
pt-archiver \
  --source h=localhost,D=shop,t=orders \
  --dest   h=archive-db,D=shop_archive,t=orders \
  --where "created_at < '2025-01-01'" \
  --limit 1000 --commit-each --sleep 0.1 --progress 10000
```

> 千萬不要直接執行 `DELETE FROM orders WHERE created_at < '2025-01-01'` 這種大範圍刪除，會產生超大交易、造成複製延遲與 undo 暴增。
{: .prompt-danger }

### 分庫分表（Sharding）

當單一主庫的寫入量撐不住時才考慮：

| 方案 | 特點 |
| :--- | :--- |
| 應用層分片 | 自己決定路由規則，最彈性但最費工 |
| ShardingSphere | Java 生態系常見，支援 JDBC 與 Proxy 模式 |
| Vitess | YouTube 開源，雲原生、支援線上重新分片 |
| 分散式 SQL（TiDB 等） | 相容 MySQL 協定，自動分片，但已不是 MySQL |

分片鍵的選擇最重要：要讓絕大多數查詢只落在一個分片，並避免資料傾斜。跨分片 JOIN、分散式交易、全域唯一 ID 都是要提前設計的問題。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 分區實作 | InnoDB 原生分區（5.7.6+），通用分區處理器仍存在但已棄用 | 只支援 InnoDB / NDB 原生分區，MyISAM 不能分區 | 同 8.0 |
| `information_schema` 統計 | 即時 | 快取（`information_schema_stats_expiry`） | 同 8.0 |
| 資料字典 | `.frm` + 檔案 | InnoDB 交易式資料字典 | 同 8.0 |
| Instant ADD COLUMN | 無 | 8.0.12+（末尾），8.0.29+（任意位置） | 有 |
| Undo 表空間 | 只能初始化時設定，truncate 預設關 | 預設 2 個獨立 undo 表空間、`innodb_undo_log_truncate` 預設 `ON`，8.0.14+ 可 `CREATE UNDO TABLESPACE` | 同 8.0 |
| Redo 容量 | 改大小需重啟 | 8.0.30+ `innodb_redo_log_capacity` 可線上調整 | 同 8.0 |
| 暫存表 | MEMORY 引擎，超過轉 MyISAM/InnoDB | TempTable 引擎，可用 mmap | `temptable_use_mmap` 預設 `OFF`，`temptable_max_ram` 依記憶體計算 |
| 讀寫分離中介 | MySQL Router 2.x | MySQL Router 8.0，8.2 起 Router 支援自動讀寫分離 | 8.4 Router 支援讀寫分離 |
| `AUTO_INCREMENT` 持久化 | 重啟後依 `MAX(id)` 重算 | 計數器寫入 redo log，重啟不回退 | 同 8.0 |
| FLOAT/DOUBLE 上的 `AUTO_INCREMENT` | 可用 | 棄用 | **移除**，升級前必須修改 |

### 容量面的升級提醒

- 5.7 升 8.0 後，**`AUTO_INCREMENT` 重啟不再回退**，以前依賴「刪除尾端資料、重啟後 ID 重用」的行為會改變。
- 8.0 的 undo truncate 預設開啟，長交易造成的 undo 膨脹在交易結束後可以被回收，5.7 則常常要重建實例才能釋放。
- 8.4 移除 FLOAT/DOUBLE 欄位上的 `AUTO_INCREMENT`，升級檢查工具會列出來。

## 小結

- 先量測、再預估，磁碟 70% 就要開始動作。
- 擴展順序：優化 → 垂直擴展 → 讀寫分離 → 歸檔/分區 → 分庫 → 分表。
- 8.0 的 instant DDL、可線上調整的 redo、undo 自動 truncate，都讓容量維運輕鬆很多。

下一篇：[安全與權限管理]({% post_url 2026-10-24-mysql-ops-07-security %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Partitioning](https://dev.mysql.com/doc/refman/8.0/en/partitioning.html)
- [MySQL 8.0 Reference Manual：Undo Tablespaces](https://dev.mysql.com/doc/refman/8.0/en/innodb-undo-tablespaces.html)
- [MySQL 8.4 Release Notes：Changes in MySQL 8.4.0](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)
