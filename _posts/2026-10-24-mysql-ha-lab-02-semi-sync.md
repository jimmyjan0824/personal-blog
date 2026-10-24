---
title: MySQL 高可用實作 02：半同步複製（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:11:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, replication, semi-sync, dba]
description: 在 GTID 主從架構上啟用 Percona Server 8.0.46 的半同步複製，實測寫入確認、從庫全斷時退化成非同步，以及從庫恢復後自動切回半同步的完整過程。
---

非同步複製在主庫當機時，可能有「客戶端已經收到 commit 成功，但從庫還沒收到」的交易。**半同步複製**讓主庫在回應客戶端之前，至少等一台從庫確認收到交易，把 RPO 降到接近 0。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.56.11 | Source |
| `db2` | 192.168.56.12 | Replica |
| `db3` | 192.168.56.13 | Replica |

半同步至少要一台從庫回應，建議兩台以上，這樣其中一台維護時，主庫不會退化成非同步。

## 前置作業：先建好 GTID 主從

三台都依照 [GTID 主從複製]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的步驟 0~7 完成安裝與複製，`db2`、`db3` 都指向 `db1`。確認狀態：

```console
db2# mysql -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running:|Last_IO_Error:"
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
                Last_IO_Error:
db3# mysql -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running:|Last_IO_Error:"
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
                Last_IO_Error:
```

## 步驟 1：為什麼用設定檔載入外掛

官方文件常見的做法是 `INSTALL PLUGIN`，但從庫已經開了 `super_read_only`，實測會直接被擋：

```console
db2# mysql -e "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';"
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

因此改用設定檔的 `plugin_load_add` 載入，好處是：

- 不受 `super_read_only` 影響。
- 每台都載入 source 與 replica 兩個外掛，日後主從互換時只要改開關，不用再裝外掛。
- 設定都在檔案裡，和其他節點比對很直覺。

> 外掛確認是 Percona 8.0.46 內建：`/usr/lib64/mysql/plugin/` 下有 `semisync_source.so`、`semisync_replica.so`，以及為了相容保留的舊名 `semisync_master.so`、`semisync_slave.so`。8.0.26 起請用新名稱。
{: .prompt-info }

## 步驟 2：設定檔（三台都放）

```ini
# /etc/my.cnf.d/semisync.cnf
[mysqld]
# 每台都載入兩個外掛，日後切換角色不用再安裝
plugin_load_add = semisync_source.so
plugin_load_add = semisync_replica.so

# 主庫角色（db1 設 ON，從庫設 OFF）
loose_rpl_semi_sync_source_enabled = ON
loose_rpl_semi_sync_source_timeout = 1000                 # 毫秒，超時退回非同步
loose_rpl_semi_sync_source_wait_for_replica_count = 1
loose_rpl_semi_sync_source_wait_point = AFTER_SYNC        # 預設值，寫出來比較清楚

# 從庫角色（db2、db3 設 ON，主庫設 OFF）
loose_rpl_semi_sync_replica_enabled = OFF
```

`db2`、`db3` 要把兩個開關反過來：

```console
db2# grep enabled /etc/my.cnf.d/semisync.cnf
loose_rpl_semi_sync_source_enabled = OFF
loose_rpl_semi_sync_replica_enabled = ON
```

`loose_` 前綴的意思是「外掛還沒載入時不要因為不認得變數而啟動失敗」。

## 步驟 3：依序重啟（先主庫，再從庫）

```bash
db1# systemctl restart mysqld
db2# systemctl restart mysqld
db3# systemctl restart mysqld
```

> 順序很重要。實測先重啟從庫、最後才重啟主庫時，從庫的 IO thread 斷線後要等 `SOURCE_CONNECT_RETRY`（預設 60 秒）才重連，這段期間 `Rpl_semi_sync_source_clients` 是 `0`：
>
> `Last_IO_Error: Error reconnecting to source 'repl@db1:3306'. This was attempt 1/86400, with a delay of 60 seconds between attempts.`
>
> 若已經發生，在從庫執行 `STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;` 就會立刻重連。
{: .prompt-warning }

## 步驟 4：確認啟用狀態

主庫 `db1`：

```console
db1# mysql -e "SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE 'rpl_semi%';"
+-----------------------+---------------+
| PLUGIN_NAME           | PLUGIN_STATUS |
+-----------------------+---------------+
| rpl_semi_sync_source  | ACTIVE        |
| rpl_semi_sync_replica | ACTIVE        |
+-----------------------+---------------+

db1# mysql -e "SHOW GLOBAL VARIABLES LIKE 'rpl_semi_sync_source%';"
+---------------------------------------------+------------+
| Variable_name                               | Value      |
+---------------------------------------------+------------+
| rpl_semi_sync_source_enabled                | ON         |
| rpl_semi_sync_source_timeout                | 1000       |
| rpl_semi_sync_source_trace_level            | 32         |
| rpl_semi_sync_source_wait_for_replica_count | 1          |
| rpl_semi_sync_source_wait_no_replica        | ON         |
| rpl_semi_sync_source_wait_point             | AFTER_SYNC |
+---------------------------------------------+------------+

db1# mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Rpl_semi_sync_source_clients','Rpl_semi_sync_source_status','Rpl_semi_sync_source_yes_tx','Rpl_semi_sync_source_no_tx');"
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 2     |
| Rpl_semi_sync_source_no_tx   | 0     |
| Rpl_semi_sync_source_status  | ON    |
| Rpl_semi_sync_source_yes_tx  | 0     |
+------------------------------+-------+
```

從庫 `db2`（`db3` 相同）：

```console
db2# mysql -e "SELECT @@hostname, @@rpl_semi_sync_replica_enabled, @@rpl_semi_sync_source_enabled; SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_replica_status';"
+------------+---------------------------------+--------------------------------+
| @@hostname | @@rpl_semi_sync_replica_enabled | @@rpl_semi_sync_source_enabled |
+------------+---------------------------------+--------------------------------+
| db2        |                               1 |                              0 |
+------------+---------------------------------+--------------------------------+
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_replica_status | ON    |
+------------------------------+-------+
```

重點指標：

| 狀態變數 | 意義 |
| :--- | :--- |
| `Rpl_semi_sync_source_status` | `ON` 才是半同步，`OFF` 代表已退化成非同步 |
| `Rpl_semi_sync_source_clients` | 目前有幾台半同步從庫連著 |
| `Rpl_semi_sync_source_yes_tx` | 有收到從庫確認的交易數 |
| `Rpl_semi_sync_source_no_tx` | 沒等到確認、以非同步提交的交易數 |

## 步驟 5：驗證寫入有等從庫確認

```console
db1# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('ssd', 3290);"
db1# mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Rpl_semi_sync_source_clients','Rpl_semi_sync_source_status','Rpl_semi_sync_source_yes_tx','Rpl_semi_sync_source_no_tx','Rpl_semi_sync_source_tx_avg_wait_time');"
+---------------------------------------+-------+
| Variable_name                         | Value |
+---------------------------------------+-------+
| Rpl_semi_sync_source_clients          | 2     |
| Rpl_semi_sync_source_no_tx            | 0     |
| Rpl_semi_sync_source_status           | ON    |
| Rpl_semi_sync_source_tx_avg_wait_time | 591   |
| Rpl_semi_sync_source_yes_tx           | 1     |
+---------------------------------------+-------+
```

`yes_tx` 變成 1，平均等待從庫確認 591 微秒，這就是半同步多出來的延遲，主要取決於主從之間的網路 RTT。

## 步驟 6：故障演練

### 停掉一台從庫：仍是半同步

`wait_for_replica_count = 1`，只要還有一台從庫回應就好：

```console
db2# mysql -e "STOP REPLICA IO_THREAD"

db1# time mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('nas', 9990);"
real	0m0.013s

db1# mysql -e "SHOW GLOBAL STATUS WHERE ..."
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 1     |
| Rpl_semi_sync_source_no_tx   | 0     |
| Rpl_semi_sync_source_status  | ON    |
| Rpl_semi_sync_source_yes_tx  | 2     |
+------------------------------+-------+
```

### 兩台從庫都停：等滿 timeout 後退化成非同步

```console
db3# mysql -e "STOP REPLICA IO_THREAD"

db1# time mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('ups', 4990);"
real	0m1.015s

db1# mysql -e "SHOW GLOBAL STATUS WHERE ..."
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 0     |
| Rpl_semi_sync_source_no_tx   | 1     |
| Rpl_semi_sync_source_status  | OFF   |
| Rpl_semi_sync_source_yes_tx  | 2     |
+------------------------------+-------+
```

這筆 `INSERT` 花了 1.015 秒，正好是 `rpl_semi_sync_source_timeout = 1000` 毫秒。等不到確認後主庫照樣提交（`no_tx` +1），並把 `Rpl_semi_sync_source_status` 切成 `OFF`。錯誤日誌：

```console
db1# grep -i semi /var/log/mysqld.log | tail -2
2026-10-24T03:46:11.908586Z 10 [ERROR] [MY-011161] [Repl] Semi-sync source failed on net_flush() before waiting for replica reply.
2026-10-24T03:46:12.908561Z 16 [Warning] [MY-011153] [Repl] Timeout waiting for reply of binlog (file: mysql-bin.000003, pos: 1121), semi-sync up to file mysql-bin.000003, position 813.
```

### 從庫恢復：自動切回半同步

```console
db2# mysql -e "START REPLICA IO_THREAD"
db3# mysql -e "START REPLICA IO_THREAD"

db1# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('router', 2990);"
db1# mysql -e "SHOW GLOBAL STATUS WHERE ..."
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 2     |
| Rpl_semi_sync_source_no_tx   | 1     |
| Rpl_semi_sync_source_status  | ON    |
| Rpl_semi_sync_source_yes_tx  | 3     |
+------------------------------+-------+
```

從庫追上後狀態自動回到 `ON`，非同步期間的交易也都補齊了：

```console
db2# mysql -e "SELECT id,item,amount FROM shop.orders;"
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
|  4 | ssd      | 3290.00 |
|  5 | nas      | 9990.00 |
|  6 | ups      | 4990.00 |
|  7 | router   | 2990.00 |
+----+----------+---------+
```

## 參數怎麼選

- **`rpl_semi_sync_source_timeout`**：這是「可用性 vs 資料安全」的取捨。設得短（1 秒），從庫全掛時寫入只卡 1 秒就退化；設得很長（例如 `4294967295`），等於寧可停寫也不要遺失資料。
- **`rpl_semi_sync_source_wait_for_replica_count`**：一主兩從時設 `1`，壞一台仍是半同步。若設 `2`，任何一台從庫維護都會讓主庫退化。
- **`rpl_semi_sync_source_wait_point`**：保持預設 `AFTER_SYNC`（lossless）。`AFTER_COMMIT` 會在等待期間讓其他連線看到尚未複製出去的資料。

## 監控建議

退化成非同步時**不會有任何錯誤回給應用程式**，一定要監控：

```sql
-- 這兩個值任一不對就告警
SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Rpl_semi_sync_source_status', 'Rpl_semi_sync_source_clients');
```

- `Rpl_semi_sync_source_status = OFF` → 告警。
- `Rpl_semi_sync_source_clients < 預期台數` → 告警。
- `Rpl_semi_sync_source_no_tx` 持續增加 → 有交易沒受到保護。

## 主從互換時

因為每台都載入了兩個外掛，切換主庫（流程見 [GTID 篇的 Switchover]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %})）時只要順便互換開關。以下是實測把主庫從 `db1` 切到 `db2`：

```sql
-- db2（新主庫）：STOP REPLICA; RESET REPLICA ALL; 關閉唯讀之後
SET PERSIST rpl_semi_sync_replica_enabled = OFF;
SET PERSIST rpl_semi_sync_source_enabled = ON;

-- db1（舊主庫降為從庫）：在 START REPLICA 之前先切開關
SET PERSIST rpl_semi_sync_source_enabled = OFF;
SET PERSIST rpl_semi_sync_replica_enabled = ON;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='Repl#Pass2026',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1;
START REPLICA;

-- db3：只要換來源，其他設定沿用
STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2'; START REPLICA;
```

在新主庫寫一筆後確認：

```console
db2# mysql -e "SHOW GLOBAL STATUS WHERE ..."
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 2     |
| Rpl_semi_sync_source_no_tx   | 0     |
| Rpl_semi_sync_source_status  | ON    |
| Rpl_semi_sync_source_yes_tx  | 1     |
+------------------------------+-------+
db1# mysql -NBe "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_replica_status'"
Rpl_semi_sync_replica_status	ON
db3# mysql -NBe "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_replica_status'"
Rpl_semi_sync_replica_status	ON
```

`SET PERSIST` 會覆蓋設定檔的值（寫在 `mysqld-auto.cnf`），記得也把 `semisync.cnf` 改成一致，避免日後有人看設定檔誤判角色。

## 驗證方式與結果

驗證環境與 [GTID 篇的「驗證方式與結果」]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 相同：環境 A 是 Rocky Linux 9 容器 + systemd、用 dnf 安裝（Mac M4 / aarch64），環境 B 是 Percona 官方映像 + systemd（x86_64）。每次從全新的三台主機開始，先照 GTID 篇建好一主兩從，再做本篇。

| 步驟 | 怎麼驗證 | 判定通過的條件 | 環境 A | 環境 B |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 在 `super_read_only` 的從庫 `INSTALL PLUGIN` | 回 `ERROR 1290`（證明要改用設定檔） | ✅ | ✅ |
| 2~4 | `information_schema.PLUGINS`、`SHOW GLOBAL VARIABLES/STATUS` | 外掛 `ACTIVE`、`source_status=ON`、`clients=2`、從庫 `replica_status=ON` | ✅ | ✅ |
| 5 | 寫入前後比對 `Rpl_semi_sync_source_yes_tx` | `yes_tx` +1 | ✅ 平均等待 190 µs | ✅ 591 µs |
| 6 停一台 | `STOP REPLICA IO_THREAD` 後寫入並計時 | 不延遲、`status` 仍 `ON` | ✅ 0.004 s | ✅ 0.013 s |
| 6 停兩台 | 同上 | 延遲約等於 timeout、`status=OFF`、`no_tx` +1、錯誤日誌出現 MY-011161 / MY-011153 | ✅ 1.008 s | ✅ 1.015 s |
| 6 恢復 | `START REPLICA IO_THREAD` 後寫入 | `status` 回到 `ON`、從庫資料 7 筆齊全 | ✅ | ✅ |
| 主從互換 | 依 GTID 篇步驟 9 切換並互換開關 | 新主庫 `clients=2`、兩台從庫 `replica_status=ON` | ✅ | ✅ |

**錯誤處理紀錄**：`INSTALL PLUGIN` 被 `super_read_only` 擋下（兩個環境都重現），改用 `plugin_load_add`；「先重啟從庫、後重啟主庫」造成從庫要等 60 秒才重連，是在環境 B 遇到，改成先重啟主庫後解決。

## 小結

- 從庫有 `super_read_only` 時，用 `plugin_load_add` 載入外掛比 `INSTALL PLUGIN` 好用。
- 重啟順序：先主庫、再從庫。
- 實測確認：一台從庫停掉仍維持半同步；全部停掉時寫入卡住 `timeout` 後退化，從庫恢復後自動回到半同步。
- 退化不會報錯，必須監控 `Rpl_semi_sync_source_status`。

下一篇：[平行複製]({% post_url 2026-10-24-mysql-ha-lab-03-parallel-replication %})，解決從庫追不上主庫的延遲問題。

### 參考資料

- [MySQL 8.0 Reference Manual：Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.0/en/replication-semisync.html)
- [MySQL 8.0 Reference Manual：Semisynchronous Replication Monitoring](https://dev.mysql.com/doc/refman/8.0/en/replication-semisync-monitoring.html)
