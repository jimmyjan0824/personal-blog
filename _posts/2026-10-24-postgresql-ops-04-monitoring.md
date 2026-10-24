---
title: PostgreSQL 運維 04：監控與告警
date: 2026-10-24 13:30:00 +0800
categories: [PostgreSQL, 監控]
tags: [postgresql, postgresql17, postgresql18, dba, monitoring, prometheus, grafana, pg_stat_statements, alerting]
description: 以 PostgreSQL 17 為主，整理監控指標分層、pg_stat_* 統計檢視、pg_stat_statements、wait event、Prometheus + Grafana 架構與告警閾值設計，並比較 18 的差異。
---

監控的目的是**在使用者發現之前知道出事了，並且有足夠的資料找出原因**。PostgreSQL 內建了非常完整的統計檢視（`pg_stat_*`），本篇整理該看哪些指標、怎麼收集、告警怎麼設，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 監控指標分層

| 層級 | 指標 | 來源 |
| :--- | :--- | :--- |
| 可用性 | 能否連線、是否為主庫、複製是否正常 | `pg_is_in_recovery()`、`pg_stat_replication` |
| 吞吐 | TPS（commit + rollback）、每秒查詢、讀寫 tuple 數 | `pg_stat_database` |
| 延遲 | 查詢平均 / P99 時間、慢查詢數 | `pg_stat_statements`、日誌 |
| 連線 | 總數、active、idle in transaction、等待中 | `pg_stat_activity` |
| 資源 | 快取命中率、暫存檔、checkpoint、WAL 產生量、I/O | `pg_stat_database`、`pg_stat_checkpointer`、`pg_stat_wal`、`pg_stat_io` |
| 維護 | 死 tuple、最後 vacuum 時間、XID 年齡 | `pg_stat_user_tables`、`pg_database` |
| 系統 | CPU、記憶體、磁碟空間、IOPS、延遲 | node_exporter |

## 常用的查詢

### 連線狀態

```sql
SELECT state, wait_event_type, count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

`idle in transaction` 數量多或時間長是警訊：交易開著不動，會持有鎖、擋住 vacuum。

### 快取命中率與暫存檔

```sql
SELECT datname,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       temp_files, pg_size_pretty(temp_bytes) AS temp_size,
       deadlocks, xact_commit, xact_rollback
FROM pg_stat_database WHERE datname NOT LIKE 'template%';
```

OLTP 的命中率通常應在 99% 以上。`blks_read` 只代表「不在 shared_buffers」，可能還在 OS page cache，所以命中率要配合 I/O 延遲一起看。`temp_files` 持續增加代表 `work_mem` 不夠或有查詢需要最佳化。

### Checkpoint（17 起獨立成 pg_stat_checkpointer）

```sql
SELECT num_timed, num_requested, write_time, sync_time, buffers_written
FROM pg_stat_checkpointer;
```

`num_requested`（因 WAL 量觸發）明顯多於 `num_timed`（因時間觸發），代表 `max_wal_size` 太小。

### 表的維護狀態

```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 10;
```

### XID 回捲風險

```sql
SELECT datname, age(datfrozenxid) AS xid_age,
       round(100.0 * age(datfrozenxid) / 2000000000, 1) AS pct_to_wraparound
FROM pg_database ORDER BY 2 DESC;
```

PostgreSQL 的交易 ID 是 32 位元，約 20 億就會回捲。autovacuum 會在 `autovacuum_freeze_max_age`（2 億）時強制凍結；如果長交易或失效的 replication slot 擋住它，年齡會一直上升，接近 20 億時資料庫會**拒絕寫入**。這是 PostgreSQL 最嚴重的事故之一，一定要監控。

### 複製

```sql
-- 主庫
SELECT application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_gap,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- 從庫
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

`replay_delay` 在主庫沒有寫入時也會變大（最後一筆交易是很久以前），要搭配主庫是否有寫入一起判斷；用 `pg_stat_replication.replay_lag` 比較準。

### 等待事件

```sql
-- 17 新增 pg_wait_events，可以直接查每個 wait event 的說明
SELECT a.wait_event_type, a.wait_event, count(*), w.description
FROM pg_stat_activity a
LEFT JOIN pg_wait_events w ON w.type = a.wait_event_type AND w.name = a.wait_event
WHERE a.state = 'active' AND a.wait_event IS NOT NULL
GROUP BY 1, 2, 4 ORDER BY 3 DESC;
```

`Lock` 多：鎖競爭；`IO`（`DataFileRead`）多：資料不在快取；`LWLock`（`WALWrite`）多：WAL 寫入瓶頸；`Client`（`ClientRead`）多：應用程式端慢或 idle in transaction。

## pg_stat_statements

[Standalone 實作]({% post_url 2026-10-24-postgresql-lab-01-standalone %})的設定檔已經把它放進 `shared_preload_libraries`，每個資料庫還要 `CREATE EXTENSION pg_stat_statements;`。

```sql
-- 總耗時最多的 SQL（優化優先順序）
SELECT left(query, 80) AS query, calls,
       round(total_exec_time::numeric) AS total_ms,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       rows, shared_blks_read, temp_blks_written
FROM pg_stat_statements
ORDER BY total_exec_time DESC LIMIT 10;
```

定期（例如每天）把結果存起來後 `SELECT pg_stat_statements_reset();`，才能比較不同時段的差異。監控系統通常會自動算增量。

## 監控架構

| 方案 | 說明 |
| :--- | :--- |
| **Prometheus + postgres_exporter + Grafana** | 最常見。postgres_exporter 內建常用指標，也可以自訂查詢 |
| pgwatch | 專為 PostgreSQL 設計，內建大量儀表板，可存到 PostgreSQL / TimescaleDB 或 Prometheus |
| PMM（Percona Monitoring and Management） | 同時監控 MySQL、PostgreSQL、MongoDB，含 Query Analytics |
| Zabbix | 已有 Zabbix 的環境用官方 PostgreSQL 範本 |
| 雲端 | RDS Performance Insights、Cloud SQL Query Insights |

監控帳號用內建角色，不要用 superuser：

```sql
CREATE ROLE monitor LOGIN PASSWORD '...';
GRANT pg_monitor TO monitor;   -- 可讀所有 pg_stat_* 與 pg_stat_statements 的完整 SQL
```

## 告警設計

| 指標 | 警告 | 嚴重 | 說明 |
| :--- | :--- | :--- | :--- |
| 服務可用 | — | 連不上 | 立刻處理 |
| 連線數 / `max_connections` | > 70% | > 90% | 連線池設定或連線洩漏 |
| `idle in transaction` 最長時間 | > 5 分鐘 | > 30 分鐘 | 擋 vacuum、持有鎖 |
| 最長執行中查詢 | > 5 分鐘 | > 30 分鐘 | 依業務調整 |
| 複製延遲（replay_lag） | > 30 秒 | > 5 分鐘 | |
| 從庫斷線 / `pg_stat_replication` 少一台 | — | 是 | |
| 非 active 的 replication slot | 存在 | 保留 WAL > 10GB | 會塞滿磁碟 |
| `pg_stat_archiver.failed_count` 增加 | 是 | 持續 10 分鐘 | PITR 斷了 |
| XID 年齡 | > 5 億 | > 10 億 | 回捲風險 |
| 磁碟使用率 | > 75% | > 90% | 資料與 WAL 分開看 |
| 死鎖數（每 5 分鐘） | > 0 | > 10 | |
| 快取命中率 | < 95% | < 90% | OLTP |

告警要附上**處理步驟的連結**（Runbook），見[故障排查與事件處理]({% post_url 2026-10-24-postgresql-ops-09-troubleshooting %})。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| Checkpoint 統計 | `pg_stat_checkpointer`（從 `pg_stat_bgwriter` 拆出來） | 新增 `num_done`、`slru_written` 欄位 |
| `pg_stat_io` | 以區塊數計（`op_bytes` 欄位表示每次操作的大小），沒有 WAL | 新增 `read_bytes`、`write_bytes`、`extend_bytes`，移除 `op_bytes`，並納入 WAL I/O |
| 每個連線的 I/O / WAL 統計 | 無 | `pg_stat_get_backend_io()`、`pg_stat_get_backend_wal()` |
| Vacuum 耗時 | 只有次數與最後時間 | `pg_stat_all_tables` 新增 `total_vacuum_time` 等累積時間；`track_cost_delay_timing` 記錄節流等待 |
| EXPLAIN ANALYZE | 要自己加 `BUFFERS` | 預設就顯示 BUFFERS |
| 連線日誌 | `log_connections` 只有 on / off | 可選擇記錄哪些階段（例如認證、授權、各階段耗時） |
| 鎖失敗日誌 | 無 | `log_lock_failures`：`NOWAIT` 等取鎖失敗時記錄 |
| Wait event 說明 | 新增 `pg_wait_events` | 沿用 |

### 給監控的升級建議

- 從 16 以前升級的環境，`pg_stat_bgwriter` 的 checkpoint 欄位在 17 已經移到 `pg_stat_checkpointer`，自訂查詢與 Grafana 儀表板要先改。
- 18 的 `pg_stat_io` 移除了 `op_bytes`，用到它的自訂查詢會出錯；postgres_exporter 要升到支援 18 的版本。

上表的欄位差異、`pg_wait_events`、EXPLAIN 預設 BUFFERS，都在 Rocky 9.8 上的 17.11 / 18.6 實際查過（腳本 `tools/postgresql-lab/30-extra.sh`）。

## 小結

- 先監控可用性、連線、複製、XID 年齡、磁碟，這幾個出事最嚴重。
- `pg_stat_statements` 是效能分析的基礎。
- 監控帳號用 `pg_monitor` 角色，告警附 Runbook。

下一篇：[效能調校]({% post_url 2026-10-24-postgresql-ops-05-performance-tuning %})。

### 參考資料

- [PostgreSQL 17 文件：The Cumulative Statistics System](https://www.postgresql.org/docs/17/monitoring-stats.html)
- [PostgreSQL 17 文件：pg_stat_statements](https://www.postgresql.org/docs/17/pgstatstatements.html)
- [PostgreSQL 17 文件：Routine Vacuuming（Preventing Transaction ID Wraparound Failures）](https://www.postgresql.org/docs/17/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)
- [prometheus-community/postgres_exporter](https://github.com/prometheus-community/postgres_exporter)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
