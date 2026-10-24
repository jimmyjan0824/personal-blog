---
title: MySQL 運維 04：監控與告警
date: 2026-10-24 09:33:00 +0800
categories: [MySQL, 監控告警]
tags: [mysql, mysql8, dba, monitoring, performance-schema, prometheus, grafana, pmm]
description: 以 MySQL 8.0 為主，整理關鍵監控指標、Performance Schema 與 sys schema 查詢、Prometheus + Grafana / PMM 架構與告警設計，並比較 5.7 與 8.4 LTS 的差異。
---

監控的目標不是畫出漂亮的圖，而是「在使用者發現之前先知道出事，出事後能快速找到原因」。本篇以 MySQL 8.0 為主，整理該看哪些指標、去哪裡查、怎麼設告警，最後比較 5.7 與 8.4 的差異。

{% include mysql-ops-series.md %}

## 監控指標分層

| 層級 | 指標 | 來源 |
| :--- | :--- | :--- |
| 可用性 | 實例存活、可連線、`read_only` 狀態 | `mysqladmin ping`、exporter |
| 流量 | QPS、TPS、`Com_select`/`Com_insert`… | `SHOW GLOBAL STATUS` |
| 連線 | `Threads_connected`、`Threads_running`、`Aborted_connects` | `SHOW GLOBAL STATUS` |
| InnoDB | Buffer pool 命中率、髒頁比例、Row lock waits、History list length | `SHOW ENGINE INNODB STATUS`、`information_schema.INNODB_METRICS` |
| 複製 | 延遲、IO/SQL thread 狀態、半同步狀態 | `SHOW REPLICA STATUS`、`performance_schema.replication_*` |
| 慢查詢 | 慢查詢數量、Top SQL | slow log、`sys.statements_with_runtimes_in_95th_percentile` |
| 系統 | CPU、記憶體、磁碟使用率、IOPS、IO latency | node_exporter |

### 幾個一定要算的值

```sql
-- QPS / TPS：取兩次差值除以間隔
SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Questions', 'Com_commit', 'Com_rollback', 'Uptime');

-- Buffer pool 命中率（應 > 99%）
SELECT 1 - (
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests')
) AS hit_ratio;

-- 正在執行的執行緒數（比連線數更能反映壓力）
SHOW GLOBAL STATUS LIKE 'Threads_running';
```

> `Threads_connected` 高不一定有問題（可能只是連線池閒置），但 `Threads_running` 持續超過 CPU 核心數，通常代表有慢查詢或鎖等待在堆積。
{: .prompt-tip }

## Performance Schema 與 sys schema

8.0 的 Performance Schema 預設開啟，`sys` schema 則把它包裝成好讀的 view。

```sql
-- 最耗時的 SQL（依總延遲排序）
SELECT query, exec_count, total_latency, avg_latency, rows_examined_avg
FROM sys.statement_analysis
ORDER BY total_latency DESC LIMIT 10;

-- 全表掃描的 SQL
SELECT * FROM sys.statements_with_full_table_scans LIMIT 10;

-- 沒被用過的索引
SELECT * FROM sys.schema_unused_indexes WHERE object_schema = 'shop';

-- 目前誰在等鎖、被誰擋住
SELECT * FROM sys.innodb_lock_waits\G

-- 每個帳號 / 主機的連線與流量
SELECT * FROM sys.user_summary;
SELECT * FROM sys.host_summary;
```

8.0 的鎖資訊來源換了：`information_schema.INNODB_LOCKS`、`INNODB_LOCK_WAITS` 已移除，改用 `performance_schema.data_locks` 與 `data_lock_waits`：

```sql
SELECT ENGINE_TRANSACTION_ID, OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks;
```

### 複製延遲

`Seconds_Behind_Source` 在 IO thread 卡住時可能顯示 0，不完全可靠。8.0 可以從 Performance Schema 精確計算每筆交易的延遲：

```sql
SELECT CHANNEL_NAME,
       TIMESTAMPDIFF(MICROSECOND,
         LAST_APPLIED_TRANSACTION_ORIGINAL_COMMIT_TIMESTAMP,
         LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP) / 1000000 AS lag_seconds
FROM performance_schema.replication_applier_status_by_worker;
```

更穩健的做法是用 `pt-heartbeat`：主庫每秒寫入時間戳，從庫讀出來算差值。

### Error Log 也能用 SQL 查

8.0.22 起，error log 可以直接從 `performance_schema.error_log` 查詢：

```sql
SELECT LOGGED, PRIO, ERROR_CODE, DATA
FROM performance_schema.error_log
WHERE PRIO IN ('Error', 'Warning')
ORDER BY LOGGED DESC LIMIT 20;
```

## 監控架構

### Prometheus + Grafana

```text
mysqld ──► mysqld_exporter ──► Prometheus ──► Grafana
                                    │
                                    └──► Alertmanager ──► Slack / PagerDuty / 電話
```

exporter 帳號只需要最小權限：

```sql
CREATE USER 'exporter'@'localhost' IDENTIFIED BY '***' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'localhost';
```

### PMM（Percona Monitoring and Management）

PMM 是「Prometheus 類時序資料庫 + Grafana + Query Analytics」的整合包，裝 agent 就能看到慢查詢分析，很適合中小團隊快速上手。

### Zabbix

已經有 Zabbix 的團隊可以直接用官方 MySQL template，但 SQL 層級的分析能力比較弱，通常會再搭配 PMM 或 slow log 分析工具。

## 告警設計

| 告警 | 建議閾值 | 等級 |
| :--- | :--- | :--- |
| 實例無法連線 | 連續 3 次（約 30 秒） | P1 |
| 複製中斷（IO/SQL thread 停止） | 立即 | P1 |
| 複製延遲 | > 30 秒持續 5 分鐘 | P2 |
| 半同步退化為非同步 | 立即 | P2 |
| 磁碟使用率 | > 80% 警告、> 90% 緊急 | P2 / P1 |
| `Threads_running` | > CPU 核數 × 2 持續 3 分鐘 | P2 |
| 連線數 | > `max_connections` × 80% | P2 |
| 長交易 | 執行 > 10 分鐘 | P3 |
| 死鎖次數 | 突增 | P3 |
| 備份失敗 | 立即 | P2 |

原則：

- **每個告警都要能行動**：收到後知道要查什麼、做什麼，並連結到對應 Runbook。
- **避免告警疲勞**：用持續時間過濾抖動，非緊急的告警白天再處理。
- **建立值班流程**：P1 要電話叫醒、P2 上班時間處理、P3 放週報檢討。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 鎖資訊 | `information_schema.INNODB_LOCKS`/`INNODB_LOCK_WAITS` | **移除**，改用 `performance_schema.data_locks`/`data_lock_waits` | 同 8.0 |
| `sys` schema | 5.7.7+ 內建 | 內建，view 更多 | 同 8.0 |
| Error log 查詢 | 只能讀檔 | 8.0.22+ `performance_schema.error_log` | 同 8.0 |
| 複製延遲細節 | `Seconds_Behind_Master` | 新增原始 commit 時間戳，可精算每筆交易延遲 | 同 8.0 |
| 複製狀態語法 | `SHOW SLAVE STATUS` | `SHOW REPLICA STATUS`（8.0.22+） | 舊語法**移除** |
| 狀態欄位名稱 | `Seconds_Behind_Master`、`Slave_IO_Running` | 新語法下為 `Seconds_Behind_Source`、`Replica_IO_Running` | 只有新名稱 |
| `SHOW PROCESSLIST` 實作 | 需全域 mutex | 8.0.22+ 可用 `performance_schema_show_processlist` 走 Performance Schema，降低開銷 | 同 8.0 |
| `FLUSH HOSTS` | 可用 | 8.0.23 起棄用 | **移除**，改用 `TRUNCATE TABLE performance_schema.host_cache` |
| `INFORMATION_SCHEMA.TABLESPACES` | 有 | 棄用 | **移除** |
| `information_schema` 統計 | 即時計算 | 有快取，受 `information_schema_stats_expiry`（預設 86400 秒）影響 | 同 8.0 |

> 從 5.7 升到 8.0 後，`information_schema.TABLES` 的 `TABLE_ROWS`、`DATA_LENGTH` 預設會快取一天。如果容量監控看到數字不動，可以把 `information_schema_stats_expiry` 設為 0，或先執行 `ANALYZE TABLE`。
{: .prompt-warning }

升級到 8.4 時，監控面要特別檢查：

1. exporter 與自寫腳本是否還在用 `SHOW SLAVE STATUS`（新版 `mysqld_exporter` 已支援新語法）。
2. Dashboard 的欄位名稱是否從 `*_Master`、`Slave_*` 改成 `*_Source`、`Replica_*`。
3. 清理 host cache 的腳本是否還在用 `FLUSH HOSTS`。

## 小結

- 盯 `Threads_running`、複製延遲、磁碟、長交易，比盯 CPU 更能早期發現問題。
- 8.0 的 Performance Schema + sys schema 已經足以回答大部分「現在誰在慢」的問題。
- 告警要分級、要能行動、要有值班流程。

下一篇：[效能調校]({% post_url 2026-10-24-mysql-ops-05-performance-tuning %})。

### 參考資料

- [MySQL 8.0 Reference Manual：MySQL Performance Schema](https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html)
- [MySQL 8.0 Reference Manual：MySQL sys Schema](https://dev.mysql.com/doc/refman/8.0/en/sys-schema.html)
- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
