---
title: MySQL 高可用實作 11：多來源、延遲與過濾複製，用延遲從庫救回誤刪的表（Rocky Linux 9）
date: 2026-11-20 22:00:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql84, percona, rocky-linux, replication, multi-source-replication, delayed-replication, replication-filter, gtid, dba]
description: 在 Percona Server 8.4.11 上實作三種複製的變形：兩台主庫匯流到一台的多來源複製（每個通道各自的過濾規則）、REPLICATE_IGNORE_DB 擋不住 DDL 的陷阱與 REPLICATE_WILD_IGNORE_TABLE 解法，以及落後 60 秒的延遲從庫：主庫誤刪表之後，用 START REPLICA UNTIL SQL_BEFORE_GTIDS 停在 DROP 之前，把資料救回來。
media_subpath: /assets/img/posts/mysql-ha-lab-11
---

前面幾篇的複製都是「一個主庫、資料全部照抄」。實務上還有三種常見的變形：

- **多來源複製（multi-source）**：好幾個主庫匯流到同一台，例如把各業務系統的資料集中到一台做報表。
- **過濾複製**：只複製部分資料庫或表，例如暫存用的 `tmp_report` 不要。
- **延遲複製**：從庫刻意落後主庫一段時間。主庫被誤刪資料時，延遲從庫上的資料還在，是比備份還原快很多的「後悔藥」。

這三個功能都是原生的複製選項，不需要 MySQL Shell，但各有一些手冊沒寫在顯眼地方的坑，這篇都實際踩一次。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - Percona Server **8.4.11-12.1**（`ps-84-lts` 套件庫），GTID + ROW 格式。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd（x86_64，4 vCPU / 15 GB）。文中的圖是實測輸出的終端機截圖。
> - 驗證腳本與完整輸出：[`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的 `11-multisource-delayed-filter.sh`、`results/11-multisource-delayed-filter.log`。
{: .prompt-warning }

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.58.11 | 主庫 A：`sales` 資料庫 |
| `db2` | 192.168.58.12 | 主庫 B：`inventory`、`tmp_report` 資料庫 |
| `db3` | 192.168.58.13 | 多來源從庫：通道 `ch_sales`（← db1）、`ch_inv`（← db2，不要 `tmp_report`） |
| `db4` | 192.168.58.14 | 延遲從庫：← db1，`SOURCE_DELAY = 60` |

四台都是 [Lab 09]({% post_url 2026-11-20-mysql-ha-lab-09-innodb-replicaset %}) 的 `00-server.cnf` + `replication.cnf`（GTID、`binlog_format` 預設 ROW），`server_id` 各不同。

## 步驟 1：兩台主庫各自建立資料

```sql
-- db1、db2 都建立複製帳號
CREATE USER 'repl'@'192.168.58.%' IDENTIFIED BY '...';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.58.%';

-- db1
CREATE DATABASE sales;
CREATE TABLE sales.orders (id INT AUTO_INCREMENT PRIMARY KEY, customer VARCHAR(30), amount DECIMAL(10,2), created_at DATETIME DEFAULT NOW());
INSERT INTO sales.orders (customer, amount) VALUES ('alice', 120.00), ('bob', 75.50), ('carol', 300.00);

-- db2
CREATE DATABASE inventory;
CREATE TABLE inventory.stock (sku VARCHAR(20) PRIMARY KEY, qty INT);
INSERT INTO inventory.stock VALUES ('A-001', 50), ('B-002', 8), ('C-003', 0);
CREATE DATABASE tmp_report;
CREATE TABLE tmp_report.daily (d DATE PRIMARY KEY, total INT);
INSERT INTO tmp_report.daily VALUES (CURDATE(), 58);
```

兩台各自有自己的 `server_uuid`，GTID 不會互相衝突：`db1` 是 `1b1f9ada…:1-6`、`db2` 是 `1de44f85…:1-9`。

## 步驟 2：db3 建立兩個通道

多來源複製就是在 `CHANGE REPLICATION SOURCE` 和 `START REPLICA` 後面加上 `FOR CHANNEL`。過濾規則也可以只套用在某個通道：

```sql
RESET BINARY LOGS AND GTIDS;   -- 清掉 db3 自己的 GTID，避免 errant GTID
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='...',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1 FOR CHANNEL 'ch_sales';
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='...',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1 FOR CHANNEL 'ch_inv';
CHANGE REPLICATION FILTER REPLICATE_IGNORE_DB = (tmp_report) FOR CHANNEL 'ch_inv';
START REPLICA FOR CHANNEL 'ch_sales';
START REPLICA FOR CHANNEL 'ch_inv';
SET PERSIST super_read_only = ON;
```

![db3 的兩個通道，以及只套用在 ch_inv 的過濾規則](01-channels.png)

`performance_schema.replication_applier_filters` 列出每個通道目前生效的過濾規則；`COUNTER` 是被這條規則擋掉的次數，之後很好用。

### 坑 1：兩台主庫的同名帳號

`ch_sales` 正常，但 `ch_inv` 的 SQL 執行緒馬上停了：

![ch_inv 停在 Error 1396：CREATE USER 'repl' 失敗](02-user-collision.png)

原因：`db1` 和 `db2` 都執行過 `CREATE USER 'repl'`，而且這兩筆都寫進了 binlog。`ch_sales` 先把 `db1` 的帳號建好了，`ch_inv` 再套用 `db2` 的同一個 `CREATE USER` 就失敗（`Error 1396`）。多來源匯流時，**所有來源共用同一個 `mysql` 系統資料庫**，帳號、權限這類全域物件很容易撞在一起。

這筆交易的效果 `db3` 已經有了，可以安全地用空交易跳過。GTID 從 `replication_applier_status_by_worker` 的錯誤訊息裡拿：

```sql
STOP REPLICA FOR CHANNEL 'ch_inv';
SET GLOBAL super_read_only = OFF;
SET GTID_NEXT = '1de44f85-e4f0-11f1-9d02-3aa3db226f89:2'; BEGIN; COMMIT; SET GTID_NEXT = 'AUTOMATIC';
SET GLOBAL super_read_only = ON;
START REPLICA FOR CHANNEL 'ch_inv';
```

更好的做法是事先避免：在其中一台主庫建立帳號時先 `SET sql_log_bin = 0`（不寫 binlog），或乾脆讓各來源用不同名稱的複製帳號。

### 坑 2：REPLICATE_IGNORE_DB 擋不住 CREATE TABLE tmp_report.daily

跳過帳號之後，`ch_inv` 又停了，這次是 `Unknown database 'tmp_report'`：

![跳過 CREATE USER 之後，ch_inv 又停在 Error 1049](03-skip-gtid.png)

`CREATE DATABASE tmp_report` 有被擋掉（所以 `db3` 上沒有這個資料庫），但下一筆 `CREATE TABLE tmp_report.daily` 沒有被擋，執行時當然找不到資料庫。看 `db2` 的 binlog：

![db2 binlog：CREATE TABLE 是在沒有 USE 的情況下執行的](04-binlog.png)

`REPLICATE_IGNORE_DB` 的判斷規則是：

- **ROW 格式的 DML**（INSERT / UPDATE / DELETE）：看被修改的表實際屬於哪個資料庫。
- **DDL**（CREATE TABLE、ALTER、DROP…）不管 `binlog_format` 是什麼，一律以 statement 寫進 binlog，判斷時看的是**預設資料庫**（`USE` 的那個），不是語句裡寫的 `tmp_report.daily`。這裡的 `CREATE TABLE` 沒有預設資料庫（`Default database: ''`），就不會被擋。

反過來也一樣危險：如果有人 `USE tmp_report;` 之後改了 `inventory` 的表結構，那筆 DDL 反而會被擋掉，`db3` 的表結構就和來源不一樣了。

### 解法：改用 REPLICATE_WILD_IGNORE_TABLE

表層級的過濾（`REPLICATE_WILD_IGNORE_TABLE`、`REPLICATE_IGNORE_TABLE`）不管預設資料庫，DDL 也依語句裡實際的「庫名.表名」判斷：

```sql
STOP REPLICA FOR CHANNEL 'ch_inv';
CHANGE REPLICATION FILTER REPLICATE_IGNORE_DB = (), REPLICATE_WILD_IGNORE_TABLE = ('tmp_report.%') FOR CHANNEL 'ch_inv';
START REPLICA FOR CHANNEL 'ch_inv';
```

![改用 REPLICATE_WILD_IGNORE_TABLE 後，ch_inv 自己恢復](05-wild-ignore.png)

不需要再跳過任何交易：重新啟動後，原本出錯的 `CREATE TABLE tmp_report.daily` 和後面的 `INSERT INTO tmp_report.daily` 都被新規則擋掉（`COUNTER = 3`），`ch_inv` 追到最新。

`CHANGE REPLICATION FILTER` 只存在記憶體，**重啟就消失**。要寫進設定檔，格式是「通道名稱:規則」：

```ini
# /etc/my.cnf.d/filters.cnf
[mysqld]
replicate-wild-ignore-table = ch_inv:tmp_report.%
```

## 步驟 3：兩邊同時寫入

`db1` 新增一筆訂單；`db2` 扣庫存、寫 `tmp_report`，再從 `inventory` 這個預設資料庫建立 `tmp_report.weekly`（就是坑 2 說的「反過來」的情況）：

```sql
-- db1
INSERT INTO sales.orders (customer, amount) VALUES ('dave', 42.00);
-- db2
UPDATE inventory.stock SET qty = qty - 1 WHERE sku = 'A-001';
INSERT INTO tmp_report.daily VALUES (CURDATE() - INTERVAL 1 DAY, 61);
USE inventory; CREATE TABLE tmp_report.weekly (w INT PRIMARY KEY);
INSERT INTO inventory.stock VALUES ('D-004', 12);
```

![兩邊的資料都到了 db3，tmp_report 全部被擋掉](06-both-writes.png)

`sales` 和 `inventory` 的變更都到了 `db3`；`tmp_report` 的 INSERT 和 DDL 都被擋掉，計數器從 3 變成 5，`db3` 上仍然沒有 `tmp_report`。

## 步驟 4：延遲從庫

`db4` 只從 `db1` 複製，`SOURCE_DELAY = 60`：

```sql
RESET BINARY LOGS AND GTIDS;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db1', SOURCE_USER='repl', SOURCE_PASSWORD='...',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_DELAY=60;
START REPLICA;
SET PERSIST super_read_only = ON;
```

等 65 秒讓它追上前面的資料（4 筆訂單），然後在 `db1` 再寫兩筆（erin、frank）：

![延遲從庫：IO 執行緒已經收到，SQL 執行緒還要等 58 秒才套用](07-delay.png)

延遲複製的運作方式：IO 執行緒照常即時把 binlog 拉回來（`Retrieved_Gtid_Set` 已經到 `:8`），SQL 執行緒則等到「交易在主庫 commit 的時間 + 60 秒」才套用（`Executed_Gtid_Set` 還停在 `:7`，`SQL_Remaining_Delay: 58`）。所以 `db4` 只有 4 筆、`db1` 有 6 筆。

## 步驟 5：事故：主庫誤刪表

```sql
-- db1
DROP TABLE sales.orders;
```

`DROP` 馬上複製到 `db3`，那裡的 `sales.orders` 也沒了（`ERROR 1146`）。一般的從庫在這種事故裡完全幫不上忙。

## 步驟 6：讓延遲從庫停在 DROP 之前

在 60 秒內：先停住 `db4` 的 SQL 執行緒，從 `db1` 的 binlog 找出 `DROP` 的 GTID，再讓 SQL 執行緒套用到它**之前**為止：

```sql
-- db4
STOP REPLICA SQL_THREAD;
```

```bash
# db1：找出 DROP TABLE 的 GTID
mysqlbinlog --no-defaults -v $(ls /var/lib/mysql/mysql-bin.0* | tail -1) | grep -B12 'DROP TABLE' | grep -E 'GTID_NEXT|DROP TABLE'
# SET @@SESSION.GTID_NEXT= '1b1f9ada-e4f0-11f1-bec6-f26a568cd969:9'/*!*/;
# DROP TABLE `sales`.`orders` /* generated by server */
```

```sql
-- db4
START REPLICA SQL_THREAD UNTIL SQL_BEFORE_GTIDS = '1b1f9ada-e4f0-11f1-bec6-f26a568cd969:9';
```

### 坑 3：UNTIL 一樣要等 SOURCE_DELAY

![UNTIL 之後，SQL 執行緒還在等延遲，erin、frank 還沒套用](08-until-delay.png)

`START REPLICA ... UNTIL` 不會取消延遲：SQL 執行緒還在等 `SQL_Remaining_Delay: 53`，`Executed_Gtid_Set` 停在 `:1-7`，erin、frank 那筆（`:8`）還沒套用。這時候就匯出資料，會少掉 DROP 之前最後一分鐘的交易。

先把延遲歸零，再套用到 DROP 之前：

```sql
STOP REPLICA SQL_THREAD;
CHANGE REPLICATION SOURCE TO SOURCE_DELAY = 0;
START REPLICA SQL_THREAD UNTIL SQL_BEFORE_GTIDS = '1b1f9ada-e4f0-11f1-bec6-f26a568cd969:9';
```

![延遲歸零後，SQL 執行緒套用到 :8 就停下，6 筆都在](09-until-fixed.png)

`Replica_SQL_Running: No`（到達 UNTIL 條件自動停止）、`Executed_Gtid_Set` 是 `:1-8`，6 筆訂單都在，而且 `DROP`（`:9`）沒有被套用。

## 步驟 7：把表匯回主庫

```bash
# db4
mysqldump --set-gtid-purged=OFF --single-transaction sales orders > /root/orders.sql
# 複製到 db1 之後
mysql sales < /root/orders.sql
```

![從延遲從庫匯出 sales.orders，匯回 db1，db3 也跟著恢復](10-restore.png)

- `--set-gtid-purged=OFF`：dump 裡不要帶 `SET @@GLOBAL.gtid_purged`，在 `db1` 匯入時就是一般的新交易，會產生 `db1` 自己的 GTID，並照常複製給 `db3`、`db4`。
- `db1` 6 筆全部救回，`db3` 透過 `ch_sales` 也回到 6 筆。

最後恢復 `db4` 的延遲複製：

```sql
CHANGE REPLICATION SOURCE TO SOURCE_DELAY = 60;
START REPLICA SQL_THREAD;
```

`db4` 之後會依序套用 `DROP`（`:9`）和匯回的資料，60 秒後和 `db1` 一致。

> 延遲從庫只能救「延遲時間內發現」的事故。60 秒是實驗用的；實務上常設 1~24 小時，配合監控告警的反應時間。超過延遲時間才發現，就只能靠 [XtraBackup + binlog PITR]({% post_url 2026-11-20-mysql-ha-lab-12-xtrabackup-pitr %})。
{: .prompt-tip }

## 實測遇到的坑

| 項目 | 現象 | 說明 / 解法 |
| :--- | :--- | :--- |
| 多來源同名帳號 | `ch_inv` 停在 `Error 1396 CREATE USER failed` | 所有來源共用 `mysql` 系統庫；用空交易跳過，或建帳號時 `SET sql_log_bin = 0` |
| `REPLICATE_IGNORE_DB` 與 DDL | `CREATE TABLE tmp_report.daily` 沒被擋，`Error 1049` | DDL 依「預設資料庫」判斷；改用 `REPLICATE_WILD_IGNORE_TABLE` |
| 過濾規則重啟消失 | `CHANGE REPLICATION FILTER` 只在記憶體 | 寫進設定檔：`replicate-wild-ignore-table = ch_inv:tmp_report.%` |
| `UNTIL` + 延遲 | SQL 執行緒仍等 `SOURCE_DELAY`，最後幾筆交易沒套用 | 先 `SOURCE_DELAY = 0`，再 `START REPLICA SQL_THREAD UNTIL ...` |
| 一般從庫 | 誤刪的 `DROP` 立刻複製 | 從庫不是備份；需要延遲從庫或 PITR |

## 驗證方式與結果

```bash
./11-multisource-delayed-filter.sh   # 多來源 + 過濾、兩個坑、延遲從庫救回誤刪的表
```

| 步驟 | 怎麼驗證 | 結果 |
| :--- | :--- | :--- |
| 2 多來源 | `replication_connection_status` | ✅ 兩個通道都連上 |
| 2 坑 1 | `replication_applier_status_by_worker` | ⚠️ `ch_inv` Error 1396，空交易跳過後恢復 |
| 2 坑 2 | 同上、`db2` binlog | ⚠️ Error 1049；改 `REPLICATE_WILD_IGNORE_TABLE` 後恢復 |
| 3 同時寫入 | `db3` 資料、過濾計數器 | ✅ `sales`、`inventory` 都到；`tmp_report` 全部被擋（計數 5） |
| 4 延遲 | `SQL_Delay`、`SQL_Remaining_Delay` | ✅ 60 秒延遲生效 |
| 6 停在 DROP 前 | `Executed_Gtid_Set`、資料 | ⚠️ 延遲未歸零時少 2 筆；歸零後 6 筆都在 |
| 7 匯回 | `db1`、`db3` 筆數 | ✅ 6 筆全部救回 |

## 小結

- 多來源複製：每個來源一個通道，GTID 各自獨立；注意帳號這類共用的全域物件。
- 過濾複製：**優先用表層級的 `REPLICATE_WILD_*_TABLE`**，資料庫層級的規則對 DDL 看的是預設資料庫，容易出錯；規則要寫進設定檔。
- 延遲從庫是誤刪資料最快的復原手段：`STOP REPLICA SQL_THREAD` → 找出 DROP 的 GTID → **`SOURCE_DELAY = 0`** → `UNTIL SQL_BEFORE_GTIDS` → 匯出、匯回。

下一篇：[XtraBackup 全量 + 增量備份與 PITR]({% post_url 2026-11-20-mysql-ha-lab-12-xtrabackup-pitr %})。

### 參考資料

- [MySQL 8.4 Reference Manual：MySQL Multi-Source Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-multi-source.html)
- [MySQL 8.4 Reference Manual：Evaluation of Database-Level Replication and Binary Logging Options](https://dev.mysql.com/doc/refman/8.4/en/replication-rules-db-options.html)
- [MySQL 8.4 Reference Manual：CHANGE REPLICATION FILTER Statement](https://dev.mysql.com/doc/refman/8.4/en/change-replication-filter.html)
- [MySQL 8.4 Reference Manual：Delayed Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-delayed.html)
- [MySQL 8.4 Reference Manual：START REPLICA Statement](https://dev.mysql.com/doc/refman/8.4/en/start-replica.html)
