---
title: MySQL 高可用實作 12：XtraBackup 全量 + 增量備份與 binlog 時間點復原（Rocky Linux 9）
date: 2026-11-20 22:30:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql84, percona, rocky-linux, xtrabackup, backup, incremental-backup, pitr, binlog, gtid, dba]
description: 高可用不等於有備份：誤刪資料會立刻複製到所有從庫。在 Percona Server 8.4.11 上用 Percona XtraBackup 8.4 做線上全量 + 兩次增量備份（應用程式持續寫入），誤刪表之後在另一台 prepare、copy-back，再用 mysqlbinlog --exclude-gtids 重放 binlog、只跳過 DROP 那一筆，資料和誤刪前完全一致。
media_subpath: /assets/img/posts/mysql-ha-lab-12
---

這個系列前面都在處理「機器掛掉」：主從、半同步、Group Replication、ReplicaSet、ClusterSet。但有一類事故是高可用架構完全擋不住的：**有人下錯指令**。`DROP TABLE`、少了 `WHERE` 的 `DELETE`，會在幾毫秒內複製到所有從庫、所有機房。

[上一篇]({% post_url 2026-11-20-mysql-ha-lab-11-multisource-delayed-filter %})用延遲從庫救回誤刪的表，但前提是要在延遲時間內發現。最後一道防線還是**備份 + binlog 時間點復原（PITR）**：

1. 用 XtraBackup 定期做實體備份（全量 + 增量），線上進行、不鎖表。
2. binlog 持續保留（或另外備份到別的地方）。
3. 出事時：還原最近一次備份，再重放備份之後的 binlog，**跳過出事的那一筆**，停在任何想要的時間點。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - Percona Server **8.4.11-12.1**、Percona XtraBackup **8.4.0-7.1**（`ps-84-lts`、`pxb-84-lts` 套件庫）。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd（x86_64，4 vCPU / 15 GB）。文中的圖是實測輸出的終端機截圖。
> - 資料量很小（5000 多筆、備份 75 MB），時間只能看相對關係，不能當成實際環境的備份速度。
> - 驗證腳本與完整輸出：[`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的 `12-xtrabackup-pitr.sh`、`results/12-xtrabackup-pitr.log`。
{: .prompt-warning }

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.58.11 | 正式環境的主庫，在這台做備份 |
| `db2` | 192.168.58.12 | 還原用的主機（不在原本的主庫上還原，避免把現場也弄壞） |
| `app` | 192.168.58.30 | 每 0.2 秒寫一筆到 `db1` |

設定檔和前幾篇一樣（`00-server.cnf` + `replication.cnf`），重點是 **binlog 開著、GTID 開著**，PITR 全靠 binlog。

## 步驟 0：版本

![Percona Server 8.4.11 與 XtraBackup 8.4.0-7](01-version.png)

XtraBackup 是直接讀 InnoDB 資料檔和 redo log 的實體備份工具，所以**版本要對應伺服器**：8.4 的伺服器用 `percona-xtrabackup-84`。8.4.0 的 XtraBackup 備份 8.4.11 正常完成、沒有任何版本警告，因為 LTS 系列內原則上只修 bug、不改 redo log 和資料字典格式（反過來說，Innovation 版每一版都可能改，XtraBackup 要跟著換版本）。升級伺服器主版本時要記得一起換（[Lab 08]({% post_url 2026-11-20-mysql-ha-lab-08-upgrade-84-to-97 %}) 提過，`percona-xtrabackup-84` 不會跟著伺服器升到 9.7）。

## 步驟 1：備份帳號

只給備份需要的權限，帳號限定 `localhost`（XtraBackup 要讀本機的資料檔，本來就只能在資料庫主機上執行）：

```sql
CREATE USER 'bkp'@'localhost' IDENTIFIED BY '...';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO 'bkp'@'localhost';
GRANT SELECT ON performance_schema.replication_group_members TO 'bkp'@'localhost';
```

`BACKUP_ADMIN` 讓 XtraBackup 可以用 `LOCK INSTANCE FOR BACKUP`：只擋 DDL，不擋一般的讀寫。`performance_schema.log_status` 用來在一致的時間點同時拿到 binlog 位置、GTID 和 redo LSN。

## 步驟 2：全量備份

`app` 持續每 0.2 秒寫一筆，同時在 `db1` 做全量備份：

```bash
xtrabackup --user=bkp --password=... --backup --target-dir=/backup/full
```

![全量備份：3.9 秒完成，記錄 binlog 位置與 GTID](02-full.png)

- `Using server version 8.4.11-12`、`completed OK!`：3.9 秒完成。備份期間 `app` 32 筆寫入全部成功，沒有被擋。
- **`xtrabackup_binlog_info`** 是 PITR 的起點：`mysql-bin.000003`、位置 `198`、GTID `…:1-32`，代表這份備份包含了 1~32 號交易。
- `xtrabackup_checkpoints` 記錄 LSN 範圍，增量備份靠它知道「從哪裡開始」。

## 步驟 3：增量備份

每隔 10 秒做一次增量，`inc1` 以全量為基準，`inc2` 以 `inc1` 為基準：

```bash
xtrabackup --user=bkp --password=... --backup --target-dir=/backup/inc1 --incremental-basedir=/backup/full
xtrabackup --user=bkp --password=... --backup --target-dir=/backup/inc2 --incremental-basedir=/backup/inc1
```

![兩次增量備份：4.1 MB、5.2 MB，比全量的 75 MB 小很多](03-incremental.png)

增量備份只複製 LSN 比基準新的頁面，所以只有 4~5 MB（全量 75 MB）。實際環境的資料量越大、每天變動的比例越小，差距越明顯；常見的排程是每週一次全量、每天一次增量。

> 三份備份的 `to_lsn` 都是 19394767，看起來像「沒有東西可以備份」，其實不是。`to_lsn` 是 checkpoint LSN，閒置程度高的伺服器上 InnoDB 不一定會推進 checkpoint；實際的資料範圍要看 `last_lsn`，增量備份也會把 redo log 一起帶走。兩份增量都包含新的交易（`inc2` 的 binlog 位置已經到 GTID `1-155`），還原結果也證明資料是完整的。
{: .prompt-info }

## 步驟 4：事故：誤刪表

增量備份之後又寫了 8 秒，然後有人刪了表；刪除之後還有其他正常的交易（建立 `t_audit`、寫兩筆），復原時要保留：

```sql
DROP TABLE appdb.t_orders;
CREATE TABLE appdb.t_audit (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(50));
INSERT INTO appdb.t_audit (msg) VALUES ('after-drop-1'), ('after-drop-2');
```

![誤刪前 5190 筆；從 binlog 找出 DROP TABLE 的 GTID :202](04-drop.png)

誤刪前 `t_orders` 有 **5190 筆**，GTID 到 `:201`。用 `mysqlbinlog` 找出 `DROP TABLE` 的 GTID 是 **`:202`**。之後 `app` 的寫入都失敗（`ERROR 1146 Table 'appdb.t_orders' doesn't exist`）。

## 步驟 5：把備份和 binlog 複製到還原主機

```bash
# db1：先切換 binlog，讓目前寫入中的檔案關閉，所有事件都落在已經關閉的檔案裡
mysql -e "FLUSH BINARY LOGS"
# 備份目錄 + 所有 binlog → db2:/backup（實務上用 rsync / scp，或從備份儲存取回）
```

實務上 binlog 不能只放在主庫上：主機整台壞掉時 binlog 也沒了。常見做法是用 `mysqlbinlog --read-from-remote-server --raw --stop-never` 在另一台持續拉 binlog，或定期把關閉的 binlog 同步到物件儲存。

## 步驟 6：prepare

XtraBackup 複製下來的資料檔是「備份期間各個時間點的頁面」，不一致；**prepare** 會套用 redo log，讓它變成某個時間點一致的狀態。有增量時順序很重要：

```bash
xtrabackup --prepare --apply-log-only --target-dir=/backup/full
xtrabackup --prepare --apply-log-only --target-dir=/backup/full --incremental-dir=/backup/inc1
xtrabackup --prepare                  --target-dir=/backup/full --incremental-dir=/backup/inc2   # 最後一次不加 --apply-log-only
```

![prepare：全量 → inc1 → inc2，最後一次才 rollback](05-prepare.png)

- **`--apply-log-only`**：只做 redo（roll forward），不 rollback 未完成的交易。這些交易可能在下一份增量裡才 commit，提早 rollback 就接不上了。
- 最後一份增量不加 `--apply-log-only`，這時才 rollback，備份狀態變成 `full-prepared`。
- prepare 之後 `/backup/full` 的 `xtrabackup_binlog_info` 變成 `inc2` 的位置：`mysql-bin.000005`、`198`、GTID `1-155`，這就是 PITR 的起點。

## 步驟 7：還原到 db2

```bash
systemctl stop mysqld
rm -rf /var/lib/mysql/*                      # copy-back 要求資料目錄是空的
xtrabackup --copy-back --target-dir=/backup/full
chown -R mysql:mysql /var/lib/mysql          # copy-back 以 root 執行，檔案擁有者要改回來
systemctl start mysqld
```

![copy-back 後啟動：資料停在 inc2 備份當下，5144 筆](06-copy-back.png)

啟動後 `gtid_executed` 是 `1-155`，和備份記錄的一致；`t_orders` 有 5144 筆（備份當下的資料）。root 密碼是 `db1` 的，因為 `mysql` 系統資料庫也是從備份還原的。

## 步驟 8：PITR：重放 binlog、跳過 DROP

從備份記錄的位置開始，重放之後所有的 binlog，用 `--exclude-gtids` 排除 DROP 那一筆：

```bash
cd /backup/binlog
FILES=$(ls mysql-bin.0* | awk -v f=mysql-bin.000005 '$0>=f')     # 從備份的那個 binlog 檔開始
mysqlbinlog --no-defaults --start-position=198 \
  --exclude-gtids='e1080b64-e4ee-11f1-bbc2-22f8774ce1b6:202' $FILES | mysql
```

![PITR：5190 筆全部回來，t_audit 也保留，GTID 只缺 :202](07-pitr.png)

- `t_orders` **5190 筆**，和誤刪前完全一樣；DROP 之後的 `t_audit` 兩筆也在。
- `gtid_executed` 是 **`1-201:203-204`**：202 號（DROP）被跳過，其他交易都保留原本的 GTID。

幾個細節：

- `--start-position` 只套用在**第一個**檔案，後面的檔案從頭開始讀，這正是我們要的。
- 開了 GTID 也可以不用位置，改成 `--exclude-gtids='<uuid>:1-155,<uuid>:202'`，已經在備份裡的交易就會被跳過；用位置比較直觀，兩種都可以。
- **不要用 `--skip-gtids`**：它會拿掉 GTID，重放的交易變成 `db2` 自己的新 GTID，之後就無法和原本的拓撲對上。
- 想停在某個時間點而不是跳過某一筆，用 `--stop-datetime` 或 `--include-gtids` / `--stop-position`。
- 如果之後要把 `db2` 接回原本的複製拓撲（例如當 `db1` 的從庫），它會發現自己缺 `:202` 並且去拉，**DROP 會被重新套用**。這時要先在 `db2` 用空交易補上 `:202`（`SET GTID_NEXT='…:202'; BEGIN; COMMIT;`），或者乾脆讓 `db2` 成為新的主庫、其他節點重建。

## 驗證

![比對：5190 筆；app 回報成功的 190 筆全部都在](08-final.png)

`app` 共回報 190 筆寫入成功，`db2` 上 `note LIKE 'w-%'` 的筆數也是 190：所有在誤刪前 commit 的寫入一筆都沒少。總筆數 5190 和誤刪前的 `db1` 相同。

## 實測遇到的坑與注意事項

| 項目 | 現象 / 風險 | 說明 / 解法 |
| :--- | :--- | :--- |
| 從庫不是備份 | DROP 立刻複製到所有從庫 | 一定要有備份 + binlog；延遲從庫只能救延遲時間內的事故 |
| XtraBackup 版本 | 主版本不對無法備份 | 8.4 伺服器用 `percona-xtrabackup-84`；伺服器升主版本時一起換 |
| `to_lsn` 沒變 | 三份備份的 `to_lsn` 一樣 | 那是 checkpoint LSN；看 `last_lsn` 與還原結果 |
| 增量 prepare | 中間某次忘了 `--apply-log-only` | 之後的增量就套不上，只能重來；只有最後一次不加 |
| copy-back | 資料目錄非空會拒絕；檔案擁有者是 root | 先清空；完成後 `chown -R mysql:mysql` |
| binlog 只在主庫上 | 主機壞掉時 binlog 一起消失 | 用 `mysqlbinlog --read-from-remote-server --stop-never` 或同步到其他儲存 |
| `--skip-gtids` | 重放後 GTID 全變成新的 | 不要用；用 `--exclude-gtids` 跳過特定交易 |
| GTID 空洞 | `db2` 接回原拓撲時會重新拉 `:202`（DROP） | 先用空交易補上，或讓 `db2` 當新的主庫 |

## 驗證方式與結果

```bash
./12-xtrabackup-pitr.sh   # 全量 + 兩次增量（app 持續寫入）→ 誤刪 → 在 db2 prepare、copy-back → binlog PITR → 比對
```

| 步驟 | 怎麼驗證 | 結果 |
| :--- | :--- | :--- |
| 2 全量 | `completed OK!`、app 紀錄 | ✅ 3.9 秒、75 MB，備份期間寫入 0 失敗 |
| 3 增量 | `xtrabackup_checkpoints`、大小 | ✅ 4.1 MB、5.2 MB |
| 6 prepare | `backup_type` | ✅ `full-prepared`，起點 `mysql-bin.000005:198`、GTID `1-155` |
| 7 還原 | `gtid_executed`、筆數 | ✅ `1-155`、5144 筆 |
| 8 PITR | 筆數、`t_audit`、`gtid_executed` | ✅ 5190 筆、`t_audit` 保留、`1-201:203-204` |
| 比對 | app 成功筆數 vs 資料庫 | ✅ 190 筆全在 |

## 小結

- 高可用處理的是「機器壞掉」，**備份 + binlog** 處理的是「人做錯事」，兩者缺一不可。
- XtraBackup：線上、不鎖表的實體備份；全量 + 增量，prepare 時**只有最後一次不加 `--apply-log-only`**。
- PITR 的起點是 `xtrabackup_binlog_info`；用 `mysqlbinlog --exclude-gtids` 精準跳過出事的那一筆，其他交易（包括事故之後的正常交易）都保留。
- 備份要定期**實際還原演練**，像這篇一樣在另一台還原、比對筆數，才知道備份真的能用。

這個系列到這裡告一段落：從 [Lab 01]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的 GTID 主從，到 Group Replication、InnoDB Cluster / ReplicaSet / ClusterSet、版本升級，最後是備份與時間點復原。

### 參考資料

- [Percona XtraBackup 8.4 文件](https://docs.percona.com/percona-xtrabackup/8.4/)
- [Percona XtraBackup 8.4：Create an incremental backup](https://docs.percona.com/percona-xtrabackup/8.4/create-incremental-backup.html)
- [Percona XtraBackup 8.4：Prepare an incremental backup](https://docs.percona.com/percona-xtrabackup/8.4/prepare-incremental-backup.html)
- [MySQL 8.4 Reference Manual：Point-in-Time Recovery Using Binary Log](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery-binlog.html)
- [MySQL 8.4 Reference Manual：mysqlbinlog](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html)
