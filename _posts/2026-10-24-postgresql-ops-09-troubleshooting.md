---
title: PostgreSQL 運維 09：故障排查與事件處理
date: 2026-10-24 14:20:00 +0800
categories: [PostgreSQL, 故障排查]
tags: [postgresql, postgresql17, postgresql18, dba, troubleshooting, deadlock, long-transaction, replication, wraparound, runbook, postmortem]
description: 以 PostgreSQL 17 為主，整理鎖阻塞、死鎖、長交易、連線數爆滿、複製延遲與 slot 累積、磁碟滿、XID 回捲、OOM、資料損毀等常見故障的排查步驟，以及 Runbook 與事後檢討，並比較 18 的差異。
---

故障發生時，最重要的是**先止血、再找原因**。本篇以 PostgreSQL 17 為主，整理最常見的故障的排查 SQL 與處理步驟，最後比較 18 在排查工具上的差異。

{% include postgresql-ops-series.md %}

## 第一分鐘：快速判斷

```sql
-- 1. 現在誰在跑？跑多久？在等什麼？
SELECT pid, usename, datname, client_addr, state,
       wait_event_type, wait_event,
       now() - xact_start AS xact_age, now() - query_start AS query_age,
       left(query, 100) AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND state <> 'idle'
ORDER BY xact_start NULLS LAST LIMIT 20;

-- 2. 連線狀態分布
SELECT state, count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1;

-- 3. 誰擋住誰
SELECT pid, pg_blocking_pids(pid) AS blocked_by, wait_event, left(query, 80) AS query
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;
```

搭配系統指標（`top`、`iostat -x 1`、`df -h`、`free -m`）與日誌（`/var/lib/pgsql/17/data/log/`）判斷瓶頸在 CPU、I/O、記憶體還是鎖。

### 取消與中止

```sql
SELECT pg_cancel_backend(12345);     -- 取消目前的查詢，連線保留（先用這個）
SELECT pg_terminate_backend(12345);  -- 中止整條連線，交易回滾
```

## 鎖阻塞

最常見的情境是**鎖佇列**：一個長交易持有鎖，一個 DDL 在等它，後面所有查詢都排在 DDL 後面（詳見[變更管理]({% post_url 2026-10-24-postgresql-ops-08-change-management %})）。

```sql
-- 找出阻塞鏈的源頭：自己沒被擋、但擋住別人的連線
SELECT a.pid, a.usename, a.state, now() - a.xact_start AS xact_age, left(a.query, 100) AS query
FROM pg_stat_activity a
WHERE a.pid IN (SELECT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity)
  AND cardinality(pg_blocking_pids(a.pid)) = 0;
```

處理：確認源頭是什麼（常是 `idle in transaction` 的應用程式連線，或忘記關的手動交易）後 `pg_terminate_backend`。長期解法是 `idle_in_transaction_session_timeout` 與 DDL 的 `lock_timeout`。

設定 `log_lock_waits = on` 後，等鎖超過 `deadlock_timeout`（1 秒）就會在日誌留下紀錄，事後可以查：

```text
LOG:  process 4321 still waiting for RowExclusiveLock on relation 16420 of database 16384 after 1000.123 ms
DETAIL:  Process holding the lock: 4300. Wait queue: 4321.
```

## 死鎖

PostgreSQL 等鎖超過 `deadlock_timeout` 時會檢查死鎖，發現就中止其中一個交易：

```text
ERROR:  deadlock detected
DETAIL:  Process 4321 waits for ShareLock on transaction 1001; blocked by process 4300.
         Process 4300 waits for ShareLock on transaction 1002; blocked by process 4321.
```

處理原則：

- 應用程式要能**捕捉 SQLSTATE `40P01` 並重試**。
- 所有交易以**相同順序**存取資源（例如依主鍵排序後再更新）。
- 縮短交易；批次更新拆小。
- 外鍵欄位要有索引，否則刪除父表的列時會掃描子表、持有較多的鎖。

## 長交易與 idle in transaction

長交易的危害不只是持有鎖：它讓**所有表**的 VACUUM 都無法清理它開始之後產生的死 tuple，時間一長就是全庫膨脹，甚至 XID 回捲。

```sql
-- 擋住 vacuum 的「最老」的東西：交易、prepared transaction、replication slot
SELECT 'xact' AS kind, pid::text AS id, age(backend_xmin) AS xmin_age, now() - xact_start AS age
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
UNION ALL
SELECT 'prepared', gid, age(transaction), now() - prepared FROM pg_prepared_xacts
UNION ALL
SELECT 'slot', slot_name, age(xmin), NULL FROM pg_replication_slots WHERE xmin IS NOT NULL
ORDER BY xmin_age DESC NULLS LAST LIMIT 10;
```

`hot_standby_feedback = on` 的從庫上的長查詢也會讓主庫的 `backend_xmin` 停住，在主庫的 `pg_stat_replication.backend_xmin` 看得到。

## 連線數爆滿

```text
FATAL:  sorry, too many clients already
FATAL:  remaining connection slots are reserved for roles with the SUPERUSER attribute
```

1. 用保留連線登入（`superuser_reserved_connections`，或 16+ 的 `reserved_connections` 給 `pg_use_reserved_connections` 角色）。
2. 看是哪個應用、哪個狀態占用：

```sql
SELECT usename, application_name, client_addr, state, count(*)
FROM pg_stat_activity GROUP BY 1, 2, 3, 4 ORDER BY 5 DESC LIMIT 10;
```

3. `idle` 很多：應用程式連線池設太大或沒有歸還；`idle in transaction` 很多：程式沒有 commit / rollback；`active` 很多且在等鎖：先處理鎖。
4. 長期解法：PgBouncer、每個帳號設 `CONNECTION LIMIT`。**不要直接把 `max_connections` 調大**，那只是把問題延後並增加記憶體風險。

## 複製延遲與 slot 累積

```sql
-- 主庫：每台從庫落後多少
SELECT application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)) AS send_gap,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_gap,
       replay_lag
FROM pg_stat_replication;
```

| 現象 | 原因 | 處理 |
| :--- | :--- | :--- |
| `send_gap` 大 | 網路頻寬或主庫 walsender 跟不上 | 檢查網路；大量寫入（批次匯入）時暫時性的 |
| `replay_gap` 大、從庫 `startup` 行程 CPU 100% | 從庫單執行緒重播跟不上 | 換更快的從庫、降低主庫的大批次寫入 |
| `replay_gap` 大、從庫有長查詢 | 查詢與重播衝突，WAL 在等查詢（`max_standby_streaming_delay`） | 取消長查詢，或把報表移到專用從庫 |
| `pg_stat_replication` 沒有某台從庫 | 從庫掛了或網路斷了 | 看從庫日誌；**同時檢查 slot 保留的 WAL** |

```sql
-- 不在用的 slot 保留了多少 WAL
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots ORDER BY restart_lsn;

-- 確認那台從庫不會回來了，才刪除
SELECT pg_drop_replication_slot('pgs3');
```

## 磁碟滿

| 位置 | 檢查 | 處理 |
| :--- | :--- | :--- |
| `pg_wal` | `du -sh $PGDATA/pg_wal` | 找原因：slot 保留、歸檔失敗（`pg_stat_archiver.failed_count`）、`wal_keep_size` 太大。**絕對不要手動刪 pg_wal 裡的檔案** |
| 資料 | 最大的表與索引 | 刪除舊資料（`DROP` 分區最快）、`pg_repack` |
| 日誌 | `$PGDATA/log` | 清舊日誌，檢查是否有大量錯誤訊息洗版 |
| 暫存檔 | `$PGDATA/base/pgsql_tmp` | 找出大型排序查詢並取消；設 `temp_file_limit` |

資料目錄所在的磁碟滿時，PostgreSQL 寫不進 WAL 會 `PANIC` 停機；清出空間後重啟就會自動做 crash recovery。若是 `pg_wal` 塞滿而又清不出空間，可以把資料目錄暫時搬到更大的磁碟，或擴充磁碟後再啟動。

## XID 回捲

日誌開始出現：

```text
WARNING:  database "appdb" must be vacuumed within 39985967 transactions
```

再不處理，最後會：

```text
ERROR:  database is not accepting commands that assign new transaction IDs to avoid wraparound data loss in database "appdb"
```

處理順序：

1. 找出擋住凍結的東西（上面「長交易」那段的查詢）：長交易、prepared transaction、失效的 slot，先清掉。
2. 找出年齡最大的表，手動 `VACUUM (FREEZE, VERBOSE)`；`vacuum_failsafe_age` 已經會讓 autovacuum 全速執行。
3. 不需要進入單人模式：VACUUM 不需要分配新的交易 ID，一般連線就能執行，官方文件從 16 起也改為不建議使用單人模式。

預防：監控 `age(datfrozenxid)`（[監控篇]({% post_url 2026-10-24-postgresql-ops-04-monitoring %})），超過 5 億就要查。

## OOM（記憶體不足）

```text
LOG:  server process (PID 4321) was terminated by signal 9: Killed
LOG:  terminating any other active server processes
```

任何一個 backend 被 OOM Killer 砍掉，postmaster 會**中止所有連線並做 crash recovery**，對服務來說就是一次重啟。

- `dmesg -T | grep -i oom` 確認是 OOM Killer。
- 原因多半是 `work_mem` × 連線數 × 節點數超過記憶體，或連線數太多。
- PGDG 的 unit 檔已經設 `OOMScoreAdjust=-1000` 保護 postmaster，子行程則恢復成 0。
- 解法：降低 `work_mem`、用 PgBouncer 限制實際連線數；專用主機可以考慮 `vm.overcommit_memory = 2`（記憶體不夠時讓配置失敗並回錯誤，而不是被砍）。

## 資料損毀

```text
ERROR:  invalid page in block 1234 of relation base/16384/16420
WARNING:  page verification failed, calculated checksum 12345 but expected 54321
```

1. **先備份現況**（整個資料目錄），任何修復嘗試前都要有退路。
2. 用 `amcheck` 確認範圍：`pg_amcheck -d appdb --heapallindexed`。
3. 只是索引壞了：`REINDEX INDEX CONCURRENTLY`。
4. 資料頁壞了：從從庫（若從庫沒壞）或備份還原。最後手段是 `zero_damaged_pages = on`（會**遺失**該頁資料）。
5. 找根本原因：磁碟、RAID 控制器、記憶體、檔案系統。開了 data checksums 才能及早發現。

## Runbook 與事後檢討

每種告警都應該有一份 Runbook，例如：

### 告警：複製延遲 > 30 秒

1. 在主庫查 `pg_stat_replication`，確認是哪台、`send_gap` 還是 `replay_gap`。
2. `replay_gap` 大：在從庫查是否有長查詢衝突（`pg_stat_database_conflicts`），必要時取消。
3. 主庫是否在跑大批次（`pg_stat_activity`、WAL 產生速度）？是的話通知負責人、評估是否暫停。
4. 15 分鐘內沒改善：升級到值班 DBA；從庫是讀取來源的話，先把讀流量導回其他從庫。

事後檢討（Post-mortem）至少包含：

1. **時間軸**：何時發生、何時發現、何時止血、何時恢復。
2. **影響範圍**：多少使用者、多少交易、停機多久。
3. **根本原因**：用 5 Whys 往下挖。
4. **改進項目**：每一項都要有負責人與期限。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| 鎖相關日誌 | `log_lock_waits` | 新增 `log_lock_failures`：`NOWAIT`、`SKIP LOCKED` 等拿不到鎖時記錄 |
| 閒置 slot | 只能靠 `max_slot_wal_keep_size` | `idle_replication_slot_timeout` 讓閒置太久的 slot 自動失效 |
| 連線日誌 | `log_connections` on / off | 可以選擇記錄哪些階段與耗時，排查連線慢更方便 |
| Wait event 說明 | `pg_wait_events` 檢視（17 新增） | 沿用 |
| VACUUM 節流等待 | 看不到 | `track_cost_delay_timing` 記錄 vacuum 因節流而睡眠的時間 |
| `pg_upgrade` 後的效能事故 | 統計資訊歸零，升級後立刻上線常導致執行計畫錯誤 | 保留統計資訊，降低這類事故 |
| data checksums | 預設不開，損毀可能到讀取錯誤時才發現 | 預設開 |

> Runbook 裡的查詢要跟著版本更新。例如從 16 以前升上來的環境，checkpoint 相關的監控查詢在 17 要改查 `pg_stat_checkpointer`，否則事故當下會得到「欄位不存在」的錯誤。
{: .prompt-warning }

## 小結

- 先止血：找出阻塞源、清長交易、釋放連線、清出空間。
- 長交易、`idle in transaction`、失效 slot 是許多事故的共同根源。
- 絕對不要手動刪 `pg_wal`；資料損毀時先備份現況。
- 每次事故都要產出 Runbook 更新與 Post-mortem。

下一篇：[自動化與規範制定]({% post_url 2026-10-24-postgresql-ops-10-automation-standards %})。

### 參考資料

- [PostgreSQL 17 文件：Viewing Locks](https://www.postgresql.org/docs/17/view-pg-locks.html)
- [PostgreSQL 17 文件：Server Signaling Functions](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL)
- [PostgreSQL 17 文件：Preventing Transaction ID Wraparound Failures](https://www.postgresql.org/docs/17/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND)
- [PostgreSQL 17 文件：amcheck](https://www.postgresql.org/docs/17/amcheck.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
