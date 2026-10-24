---
title: MySQL 高可用實作 03：平行複製（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:12:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, replication, parallel-replication, writeset, dba]
description: 在 Percona Server 8.0.46 上設定多執行緒平行複製與 WRITESET 依賴追蹤，並用 mysqlslap 實測不同設定下從庫追趕延遲的時間差異。
---

從庫延遲最常見的原因是：主庫多條連線同時寫入，從庫卻只用一條執行緒依序套用。**平行複製**讓從庫用多個 worker 同時套用交易；**WRITESET** 則讓主庫在 binlog 中標記出更多「可以平行」的交易。這篇實際量測兩者的效果。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構與前置作業

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.56.11 | Source |
| `db2` | 192.168.56.12 | Replica（量測對象） |
| `db3` | 192.168.56.13 | Replica |

依 [GTID 主從複製]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 建好一主兩從。

## 原理：兩個角色各管一半

| 位置 | 參數 | 作用 |
| :--- | :--- | :--- |
| 主庫 | `binlog_transaction_dependency_tracking` | 決定 binlog 裡每筆交易的 `last_committed`，也就是「這筆交易要等哪一筆做完才能套用」 |
| 從庫 | `replica_parallel_workers` | 從庫用幾個 worker 套用 |
| 從庫 | `replica_parallel_type = LOGICAL_CLOCK` | 依 `last_committed` 判斷能否平行 |
| 從庫 | `replica_preserve_commit_order` | worker 平行執行，但提交順序與主庫一致 |

主庫依賴追蹤的兩種模式：

- **`COMMIT_ORDER`**（8.0 預設）：同一次 group commit 一起提交的交易才能平行。主庫併發低時幾乎沒有平行度。
- **`WRITESET`**：只要兩筆交易修改的資料列（主鍵 / 唯一鍵的 hash）沒有交集，就能平行。即使主庫是單一連線依序寫入，也能平行套用。

## 步驟 1：確認 8.0.46 的預設值

```console
db2# mysql -e "SELECT @@replica_parallel_workers, @@replica_parallel_type, @@replica_preserve_commit_order, @@binlog_transaction_dependency_tracking, @@transaction_write_set_extraction;"
+----------------------------+-------------------------+---------------------------------+------------------------------------------+------------------------------------+
| @@replica_parallel_workers | @@replica_parallel_type | @@replica_preserve_commit_order | @@binlog_transaction_dependency_tracking | @@transaction_write_set_extraction |
+----------------------------+-------------------------+---------------------------------+------------------------------------------+------------------------------------+
|                          4 | LOGICAL_CLOCK           |                               1 | COMMIT_ORDER                             | XXHASH64                           |
+----------------------------+-------------------------+---------------------------------+------------------------------------------+------------------------------------+
```

8.0.27 起從庫預設就是 4 個 worker 的平行複製，但**主庫的依賴追蹤仍是 `COMMIT_ORDER`**，這是 8.0 最值得調整的地方。

## 步驟 2：實測比較

### 量測方法

1. 從庫 `db2` 先 `STOP REPLICA SQL_THREAD`，讓 relay log 累積。
2. 主庫 `db1` 用 `mysqlslap` 寫入大量單筆 `INSERT`（每筆都是獨立交易）。
3. 從庫 `START REPLICA SQL_THREAD`，量測到 `WAIT_FOR_EXECUTED_GTID_SET()` 返回為止的時間，也就是**從庫追平所花的時間**。

測試表：

```sql
CREATE TABLE shop.pbench (id BIGINT AUTO_INCREMENT PRIMARY KEY, v DOUBLE);
```

量測腳本（在可以 ssh 到兩台的管理機上執行）：

```bash
#!/bin/bash
# usage: pbench.sh <從庫 workers> <主庫 tracking> ；C=並行連線數 Q=總交易數
W=$1; T=$2
ssh db1 "mysql -e \"SET GLOBAL binlog_transaction_dependency_tracking='$T'\""
ssh db2 "mysql -e 'STOP REPLICA SQL_THREAD; SET GLOBAL replica_parallel_workers=$W;'"
ssh db1 "mysqlslap --create-schema=shop --concurrency=${C:-8} --iterations=1 \
  --number-of-queries=${Q:-40000} --query='INSERT INTO shop.pbench(v) VALUES (RAND())'"
G=$(ssh db1 "mysql -NBe 'SELECT @@gtid_executed'" | tr -d '\n')
ssh db2 "mysql -e 'START REPLICA SQL_THREAD'"
S0=$(date +%s.%N)
ssh db2 "mysql -NBe \"SELECT WAIT_FOR_EXECUTED_GTID_SET('$G', 600)\"" >/dev/null
S1=$(date +%s.%N)
printf "workers=%s tracking=%s  catch-up=%.1fs\n" $W $T $(echo "$S1 - $S0" | bc)
```

> 實測時是用 `docker exec` 取代 `ssh`，其餘相同。`replica_parallel_workers` 可以線上調整，但要先停 SQL thread，改完再啟動才生效。
{: .prompt-info }

### 結果一：主庫 8 條連線併發寫入（40,000 筆）

```console
workers=1 tracking=COMMIT_ORDER  catch-up=51.9s
workers=8 tracking=COMMIT_ORDER  catch-up=21.4s
workers=8 tracking=WRITESET      catch-up=21.7s
```

### 結果二：主庫單一連線依序寫入（10,000 筆）

```console
workers=1 tracking=COMMIT_ORDER  catch-up=12.5s
workers=8 tracking=COMMIT_ORDER  catch-up=15.0s
workers=8 tracking=WRITESET      catch-up=5.2s
```

| 情境 | 單執行緒 | 8 workers + COMMIT_ORDER | 8 workers + WRITESET |
| :--- | ---: | ---: | ---: |
| 主庫 8 連線併發 | 51.9 秒 | 21.4 秒 | 21.7 秒 |
| 主庫單一連線 | 12.5 秒 | 15.0 秒 | **5.2 秒** |

解讀：

- 主庫本身併發高時，`COMMIT_ORDER` 的 group commit 已經有足夠平行度，加 worker 就能把追趕時間砍到四成左右，`WRITESET` 沒有額外好處。
- 主庫是**單一連線**（批次作業、ETL、單執行緒的應用）時，`COMMIT_ORDER` 下每筆交易都依賴前一筆，開 8 個 worker 反而因為協調成本更慢（12.5 → 15.0 秒）；改成 `WRITESET` 後降到 5.2 秒。
- 這是同一台實體機上的容器測試，絕對數字沒有參考價值，請看相對差異。

## 步驟 3：從 binlog 看差異

主庫單一連線寫 5 筆，用 `mysqlbinlog` 看 `last_committed` 與 `sequence_number`：

`COMMIT_ORDER`：每筆的 `last_committed` 都是前一筆，必須依序套用。

```console
db1# F=$(mysql -NBe "SHOW MASTER STATUS" | cut -f1)
db1# mysqlbinlog /var/lib/mysql/$F | grep -o "last_committed=[0-9]*.*sequence_number=[0-9]*" | tail -5
last_committed=0	sequence_number=1
last_committed=1	sequence_number=2
last_committed=2	sequence_number=3
last_committed=3	sequence_number=4
last_committed=4	sequence_number=5
```

`WRITESET`：第 2~5 筆的 `last_committed` 都是 1，代表它們彼此不衝突，可以同時套用。

```console
db1# F=$(mysql -NBe "SHOW MASTER STATUS" | cut -f1)
db1# mysqlbinlog /var/lib/mysql/$F | grep -o "last_committed=[0-9]*.*sequence_number=[0-9]*" | tail -5
last_committed=0	sequence_number=1
last_committed=1	sequence_number=2
last_committed=1	sequence_number=3
last_committed=1	sequence_number=4
last_committed=1	sequence_number=5
```

## 步驟 4：寫入設定檔（三台都放）

```ini
# /etc/my.cnf.d/parallel.cnf
[mysqld]
# ---- 主庫端：讓 binlog 標記出更多可平行的交易 ----
binlog_transaction_dependency_tracking = WRITESET   # 8.0.35 起標為棄用，8.4 移除（固定為 WRITESET）

# ---- 從庫端：多執行緒套用 ----
replica_parallel_workers       = 8                  # 8.0.27+ 預設 4
replica_preserve_commit_order  = ON                 # 8.0.27+ 預設值，保持提交順序與主庫一致
```

三台都放同一份，因為任何一台都可能在切換後變成主庫。重啟後確認：

```console
# systemctl restart mysqld
# mysql -e "SELECT @@binlog_transaction_dependency_tracking, @@transaction_write_set_extraction, @@replica_parallel_type, @@replica_parallel_workers, @@replica_preserve_commit_order"
+------------------------------------------+------------------------------------+-------------------------+----------------------------+---------------------------------+
| @@binlog_transaction_dependency_tracking | @@transaction_write_set_extraction | @@replica_parallel_type | @@replica_parallel_workers | @@replica_preserve_commit_order |
+------------------------------------------+------------------------------------+-------------------------+----------------------------+---------------------------------+
| WRITESET                                 | XXHASH64                           | LOGICAL_CLOCK           |                          8 |                               1 |
+------------------------------------------+------------------------------------+-------------------------+----------------------------+---------------------------------+
```

啟動時錯誤日誌會有一行棄用警告，**這是預期的**，8.0 要用 WRITESET 只能這樣設定：

```console
[Warning] [MY-011069] [Server] The syntax '--binlog-transaction-dependency-tracking' is deprecated and will be removed in a future release.
```

> 不要把 `replica_parallel_type`、`transaction_write_set_extraction` 寫進設定檔。它們的預設值已經是 `LOGICAL_CLOCK` 與 `XXHASH64`，實測寫進去只會在啟動時多出兩行同樣的棄用警告。
{: .prompt-tip }

## 步驟 5：監控 worker

```console
db2# mysql -e "SELECT WORKER_ID, THREAD_ID, SERVICE_STATE, LAST_APPLIED_TRANSACTION FROM performance_schema.replication_applier_status_by_worker;"
+-----------+-----------+---------------+---------------------------------------------+
| WORKER_ID | THREAD_ID | SERVICE_STATE | LAST_APPLIED_TRANSACTION                    |
+-----------+-----------+---------------+---------------------------------------------+
|         1 |        52 | ON            | 77d6e3a1-cf5a-11f1-89a8-125528ca53ca:150012 |
|         2 |        53 | ON            | 77d6e3a1-cf5a-11f1-89a8-125528ca53ca:150013 |
|         3 |        54 | ON            | 77d6e3a1-cf5a-11f1-89a8-125528ca53ca:150014 |
|         4 |        55 | ON            | 77d6e3a1-cf5a-11f1-89a8-125528ca53ca:150015 |
|         5 |        56 | ON            |                                             |
|         6 |        57 | ON            |                                             |
|         7 |        58 | ON            |                                             |
|         8 |        59 | ON            |                                             |
+-----------+-----------+---------------+---------------------------------------------+
```

- 只有前幾個 worker 有 `LAST_APPLIED_TRANSACTION`，代表目前負載用不到 8 個，可以不用再加。
- 某個 worker 有 `LAST_ERROR_MESSAGE` 時，複製會停下來，要看這張表才知道是哪筆交易出錯。

## worker 要開幾個

- 從 CPU 核心數的一半開始，通常 4~16 之間。
- 觀察上面的表，若所有 worker 都很忙且延遲仍在增加，再往上加。
- worker 開太多不會變快，反而增加協調成本（結果二的 `COMMIT_ORDER` 就是例子）。

## 平行複製解決不了的延遲

- **大交易**：一筆刪除一千萬列的交易只能由一個 worker 執行，要從應用端拆小。
- **沒有主鍵的表**：ROW 格式下從庫要全表掃描才找得到資料列，而且 WRITESET 無法判斷衝突。所有表都應該有主鍵。
- **DDL**：DDL 會讓所有 worker 等它做完。

## 小結

- 8.0.27+ 的從庫預設已平行（4 workers），但主庫要手動設 `binlog_transaction_dependency_tracking = WRITESET` 才能發揮效果。
- 實測主庫單連線寫入時，WRITESET + 8 workers 讓追趕時間從 12.5 秒降到 5.2 秒；只加 worker 不改 WRITESET 反而變慢。
- 升級 8.4 後此參數移除、固定為 WRITESET，記得把設定檔裡這行拿掉。

下一篇：[Group Replication]({% post_url 2026-10-24-mysql-ha-lab-04-group-replication %})，讓叢集自己選主。

### 參考資料

- [MySQL 8.0 Reference Manual：replica_parallel_workers](https://dev.mysql.com/doc/refman/8.0/en/replication-options-replica.html#sysvar_replica_parallel_workers)
- [MySQL 8.0 Reference Manual：binlog_transaction_dependency_tracking](https://dev.mysql.com/doc/refman/8.0/en/replication-options-binary-log.html#sysvar_binlog_transaction_dependency_tracking)
