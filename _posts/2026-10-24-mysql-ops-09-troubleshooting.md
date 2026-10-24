---
title: MySQL 運維 09：故障排查與事件處理
date: 2026-10-24 09:38:00 +0800
categories: [MySQL, 故障排查]
tags: [mysql, mysql8, dba, troubleshooting, deadlock, long-transaction, replication, oom, runbook, postmortem]
description: 以 MySQL 8.0 為主，整理死鎖、長交易、連線數爆滿、主從不一致、磁碟滿、OOM 等常見故障的排查步驟，以及 Runbook 與事後檢討，並比較 5.7 與 8.4 LTS 的差異。
---

故障發生時，最重要的是**先止血、再找原因**。本篇以 MySQL 8.0 為主，整理最常見的幾種故障的排查 SQL 與處理步驟，最後比較 5.7 與 8.4 在排查工具上的差異。

{% include mysql-ops-series.md %}

## 第一分鐘：快速判斷

```sql
-- 1. 現在誰在跑？跑多久？
SELECT id, user, host, db, command, time, state, LEFT(info, 120) AS sql_text
FROM performance_schema.processlist
WHERE command <> 'Sleep' ORDER BY time DESC LIMIT 20;

-- 2. 壓力大不大？
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_running', 'Threads_connected');

-- 3. InnoDB 現況（鎖、交易、IO）
SHOW ENGINE INNODB STATUS\G
```

搭配系統指標（`top`、`iostat -x 1`、`df -h`、`free -m`）判斷瓶頸在 CPU、IO、記憶體還是鎖。

## 死鎖

InnoDB 會自動偵測死鎖並回滾其中一個交易，應用程式會收到 `ERROR 1213 (40001): Deadlock found`。

```sql
-- 看最近一次死鎖
SHOW ENGINE INNODB STATUS\G   -- 找 LATEST DETECTED DEADLOCK 段落

-- 把所有死鎖都寫進 error log，方便事後分析
SET PERSIST innodb_print_all_deadlocks = ON;
```

處理原則：

- 應用程式要能**捕捉 1213 並重試**。
- 讓所有交易以**相同順序**存取資源。
- 縮短交易、減少一次鎖定的列數；確認 `UPDATE`/`DELETE` 的 `WHERE` 有走索引，否則會鎖住大範圍。
- 在可接受的情況下改用 `READ COMMITTED`，可減少 gap lock 造成的死鎖。

## 鎖等待與長交易

```sql
-- 誰被誰擋住（8.0）
SELECT waiting_pid, waiting_query, blocking_pid, blocking_query,
       wait_age, sql_kill_blocking_connection
FROM sys.innodb_lock_waits\G

-- 執行超過 60 秒的交易
SELECT t.trx_id, t.trx_started, t.trx_state, t.trx_rows_locked, t.trx_rows_modified,
       p.id AS thread_id, p.user, p.host, LEFT(p.info, 120) AS sql_text
FROM information_schema.innodb_trx t
JOIN performance_schema.processlist p ON p.id = t.trx_mysql_thread_id
WHERE t.trx_started < NOW() - INTERVAL 60 SECOND
ORDER BY t.trx_started;
```

常見元兇是「開了交易卻忘了提交」的連線，狀態是 `Sleep`，但手上握著鎖。

```sql
KILL 12345;   -- 殺掉阻塞源
```

> KILL 一個修改了大量資料的交易，回滾可能比原本執行還久，而且期間仍持有鎖。KILL 前先看 `trx_rows_modified`。
{: .prompt-warning }

長交易還會讓 **History list length** 持續上升（undo 無法 purge），進而拖慢所有查詢：

```sql
SELECT NAME, COUNT FROM information_schema.INNODB_METRICS WHERE NAME = 'trx_rseg_history_len';
```

## 連線數爆滿

`ERROR 1040 (HY000): Too many connections`，連 DBA 也登不進去。

8.0.14 起可以設定**獨立的管理埠**，不受 `max_connections` 限制：

```ini
admin_address = 127.0.0.1
admin_port    = 33062
```

```bash
mysql -uroot -p -h127.0.0.1 -P33062
```

進去之後：

1. 看是哪個帳號 / 主機佔滿連線：`SELECT user, host, COUNT(*) FROM performance_schema.processlist GROUP BY user, host ORDER BY 3 DESC;`
2. KILL 閒置或異常連線，必要時暫時提高 `max_connections`。
3. 找根因：慢查詢導致連線堆積？應用程式連線池設定錯誤？連線洩漏？

## 主從複製中斷與不一致

```sql
SHOW REPLICA STATUS\G
-- 看 Last_IO_Error、Last_SQL_Error、Retrieved_Gtid_Set、Executed_Gtid_Set

-- 8.0 可以看到是哪個 worker、哪筆交易出錯
SELECT * FROM performance_schema.replication_applier_status_by_worker\G
```

| 錯誤 | 常見原因 | 處理 |
| :--- | :--- | :--- |
| 1062 Duplicate entry | 從庫被直接寫入 | 確認從庫有 `super_read_only=ON`；比對後決定是否跳過 |
| 1032 Can't find record | 從庫資料缺失 | 同上，並考慮重建從庫 |
| 1236 binlog 已被 purge | 從庫落後太久 | 用 Clone 或備份重建從庫 |

GTID 模式下跳過一筆交易（**確認資料可以忽略後才做**）：

```sql
STOP REPLICA;
SET GTID_NEXT = '3E11FA47-71CA-11E1-9E33-C80AA9429562:2001';
BEGIN; COMMIT;               -- 注入空交易
SET GTID_NEXT = 'AUTOMATIC';
START REPLICA;
```

事後用 `pt-table-checksum` 檢查一致性，用 `pt-table-sync` 修正，或直接用 Clone Plugin 重建從庫。

## 磁碟滿

磁碟滿時 MySQL 會卡住等待空間，寫入全部停住。

```bash
du -sh /data/mysql/* | sort -h | tail
```

常見佔用來源與處理：

| 來源 | 處理 |
| :--- | :--- |
| binlog | `PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;`（**先確認從庫已收到**），調整 `binlog_expire_logs_seconds` |
| relay log | 確認複製正常，relay log 會自動清除 |
| undo 表空間 | 先處理長交易；8.0 會自動 truncate |
| 暫存檔 / `#sql` 殘留檔 | 找出產生大暫存表的 SQL |
| 慢查詢 log / general log | 輪替並壓縮，general log 不要在正式環境長期開啟 |

> 不要直接 `rm` binlog 檔案，會造成 `mysql-bin.index` 與實際檔案不一致。請一律使用 `PURGE BINARY LOGS`。
{: .prompt-danger }

## OOM（記憶體不足）

`dmesg | grep -i oom` 看到 mysqld 被 OOM Killer 殺掉時：

```sql
-- 8.0 預設已啟用 memory instrument，可以看各模組記憶體使用
SELECT event_name, current_alloc
FROM sys.memory_global_by_current_bytes LIMIT 15;

-- 各執行緒記憶體使用
SELECT thread_id, user, current_allocated
FROM sys.memory_by_thread_by_current_bytes LIMIT 10;
```

常見原因：

- `innodb_buffer_pool_size` 設太大，沒有預留給 OS 與連線。
- 連線數多 × 每連線 buffer（`sort_buffer_size`、`join_buffer_size`、`read_rnd_buffer_size`）。
- 大量記憶體暫存表（`tmp_table_size`、`temptable_max_ram`）。
- 8.0.28 起可以設定 `global_connection_memory_limit` 與 `connection_memory_limit`，限制連線記憶體上限。

## Runbook 與事後檢討

### Runbook 範本

```markdown
## 告警：複製延遲 > 30 秒

1. 確認範圍：單台從庫還是全部？
2. 檢查 SHOW REPLICA STATUS 的 SQL thread 是否在跑大交易
3. 檢查從庫 IO：iostat -x 1
4. 若為大交易：等待或通知開發，評估是否把讀流量切離該從庫
5. 若為 IO 瓶頸：調整 innodb_flush_log_at_trx_commit=2（僅從庫，暫時）
6. 回報：在事件頻道更新狀態
```

### Post-mortem

事故結束後一週內完成，**對事不對人**：

1. **時間軸**：何時發生、何時發現、何時止血、何時恢復。
2. **影響範圍**：多少使用者、多少交易、停機多久。
3. **根本原因**：用 5 Whys 往下挖。
4. **改進項目**：每一項都要有負責人與期限，例如「新增長交易告警」「更新 Runbook」。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 鎖資訊 | `information_schema.INNODB_LOCKS` | `performance_schema.data_locks` | 同 8.0 |
| `sys.innodb_lock_waits` | 有（底層用 I_S） | 有（底層用 P_S） | 同 8.0 |
| 管理埠 | 無，只能靠 `SUPER` 的一條保留連線 | 8.0.14+ `admin_port` | 有 |
| 連線數滿時登入 | 需 `SUPER` | `CONNECTION_ADMIN` | 同 8.0 |
| 連線記憶體上限 | 無 | 8.0.28+ `connection_memory_limit`、`global_connection_memory_limit` | 有 |
| Error log 查詢 | 讀檔 | 8.0.22+ `performance_schema.error_log` | 同 8.0 |
| Undo 自動 truncate | 預設關閉 | 預設開啟 | 預設開啟 |
| 複製錯誤細節 | 較少 | `replication_applier_status_by_worker` 提供失敗交易 GTID 與時間戳 | 同 8.0 |
| 跳過錯誤語法 | `SET GLOBAL sql_slave_skip_counter`（非 GTID） | `sql_replica_skip_counter`（8.0.26+） | 使用 `sql_replica_skip_counter`；GTID 模式請用空交易 |
| 狀態查詢 | `SHOW SLAVE STATUS` | `SHOW REPLICA STATUS` | 只有 `SHOW REPLICA STATUS` |
| 重置主庫 | `RESET MASTER` | `RESET MASTER` | `RESET BINARY LOGS AND GTIDS` |
| `FLUSH HOSTS`（解除 host blocked） | 可用 | 棄用 | **移除**，改 `TRUNCATE TABLE performance_schema.host_cache` |

> 8.4 移除舊語法後，**Runbook 裡的指令也要同步更新**。最糟的情況是事故當下照著 Runbook 執行 `SHOW SLAVE STATUS` 卻得到語法錯誤。
{: .prompt-warning }

## 小結

- 先止血：找出阻塞源、釋放連線、清出空間。
- 8.0 的 `sys` schema、`data_locks`、`admin_port`、`error_log` 讓排查快很多。
- 每次事故都要產出 Runbook 更新與 Post-mortem，避免同樣的問題再發生。

下一篇：[自動化與規範制定]({% post_url 2026-10-24-mysql-ops-10-automation-standards %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Deadlocks in InnoDB](https://dev.mysql.com/doc/refman/8.0/en/innodb-deadlocks.html)
- [MySQL 8.0 Reference Manual：Connection Management](https://dev.mysql.com/doc/refman/8.0/en/connection-management.html)
- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
