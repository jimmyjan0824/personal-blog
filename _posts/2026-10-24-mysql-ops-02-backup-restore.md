---
title: MySQL 運維 02：備份與還原
date: 2026-10-24 09:31:00 +0800
categories: [MySQL, 備份還原]
tags: [mysql, mysql8, dba, backup, xtrabackup, mysqldump, binlog, pitr]
description: 以 MySQL 8.0 為主，整理邏輯備份、物理備份、Clone Plugin、binlog 歸檔與 PITR 時間點還原，並比較 5.7 與 8.4 LTS 的差異。
---

備份是 DBA 最基本、也最不能出錯的工作。一個沒有驗證過的備份，等於沒有備份。本篇整理 MySQL 8.0 的備份工具與還原流程，最後比較 5.7 與 8.4 的差異。

{% include mysql-ops-series.md %}

## 備份的分類

| 類型 | 工具 | 優點 | 缺點 |
| :--- | :--- | :--- | :--- |
| 邏輯備份 | `mysqldump`、MySQL Shell Dump Utility | 跨版本、跨平台、可單表還原 | 大資料量時備份與還原都慢 |
| 物理備份 | Percona XtraBackup、MySQL Enterprise Backup | 速度快、支援增量 | 需相同大版本、檔案大 |
| 快照 | LVM / 雲端磁碟快照 | 幾乎瞬間完成 | 需搭配鎖或 crash-safe 設定 |
| 複製 | Clone Plugin | 線上複製整個實例 | 不是長期保存的備份 |
| 日誌 | Binlog 歸檔 | 搭配全量備份做 PITR | 需持續保存 |

一般正式環境的組合是：**每日全量物理備份 + 持續 binlog 歸檔 + 定期邏輯備份**。

## 邏輯備份

### mysqldump

```bash
mysqldump -uroot -p \
  --single-transaction \
  --source-data=2 \
  --routines --triggers --events \
  --set-gtid-purged=ON \
  --all-databases | zstd > full_$(date +%F).sql.zst
```

- `--single-transaction`：用 InnoDB 一致性快照，不鎖表。
- `--source-data=2`：以註解形式記錄 binlog 位置（8.0.26+ 的新名稱，舊名 `--master-data`）。

`--single-transaction` 只對 InnoDB 有效；若還有 MyISAM 表，備份期間對它們的寫入會造成不一致。

### MySQL Shell Dump Utility（推薦）

MySQL Shell 8.0.21 起提供 `util.dumpInstance()`、`util.dumpSchemas()`，支援多執行緒、壓縮與分塊，速度遠超 `mysqldump`：

```bash
mysqlsh root@localhost -- util dump-instance /backup/dump_2026-10-24 \
  --threads=8 --compression=zstd

# 還原
mysqlsh root@target -- util load-dump /backup/dump_2026-10-24 \
  --threads=8 --ignoreVersion=false
```

`util.loadDump()` 還原時可以 `deferTableIndexes`（先載資料、後建索引），大幅縮短還原時間。

## 物理備份：Percona XtraBackup

XtraBackup 的版本要對應 MySQL 大版本：

| MySQL | XtraBackup |
| :--- | :--- |
| 5.7 | 2.4 |
| 8.0 | 8.0.x |
| 8.4 | 8.4.x |

```bash
# 全量備份
xtrabackup --backup --user=bkuser --password=*** \
  --target-dir=/backup/full --parallel=4

# 增量備份（以全量為基準）
xtrabackup --backup --user=bkuser --password=*** \
  --target-dir=/backup/inc1 --incremental-basedir=/backup/full

# 還原：prepare -> copy-back
xtrabackup --prepare --apply-log-only --target-dir=/backup/full
xtrabackup --prepare --target-dir=/backup/full --incremental-dir=/backup/inc1
systemctl stop mysqld
xtrabackup --copy-back --target-dir=/backup/full
chown -R mysql:mysql /data/mysql
```

8.0 新增 `LOCK INSTANCE FOR BACKUP` 與 `BACKUP_ADMIN` 權限，XtraBackup 8.0 會利用它在備份期間阻擋 DDL，而不必用 `FLUSH TABLES WITH READ LOCK` 鎖住整個實例。

備份帳號最小權限：

```sql
CREATE USER 'bkuser'@'localhost' IDENTIFIED BY '***';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bkuser'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'bkuser'@'localhost';
```

## Clone Plugin（8.0.17+）

Clone Plugin 可以把整個 InnoDB 實例線上複製到另一台，最常用在「快速建一台新從庫」：

```sql
-- 兩邊都安裝
INSTALL PLUGIN clone SONAME 'mysql_clone.so';

-- 在接收端執行
SET GLOBAL clone_valid_donor_list = '10.0.0.1:3306';
CLONE INSTANCE FROM 'clone_user'@'10.0.0.1':3306 IDENTIFIED BY '***';

-- 查看進度
SELECT STAGE, STATE, END_TIME FROM performance_schema.clone_progress;
```

完成後接收端會自動重啟，搭配 GTID 可以直接 `CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1` 接上複製。

## Binlog 歸檔與 PITR

全量備份只能還原到「備份當下」。要還原到「誤刪之前的那一秒」，就需要 binlog。

### 持續歸檔 binlog

```bash
# 用 mysqlbinlog 遠端即時拉取 binlog
mysqlbinlog --read-from-remote-server --host=10.0.0.1 --user=repl -p \
  --raw --stop-never --result-file=/archive/binlog/ mysql-bin.000001
```

### 時間點還原步驟

假設有人在 `2026-10-24 14:03:15` 執行了錯誤的 `DELETE`：

```bash
# 1. 還原最近一次全量備份到新實例
# 2. 找出全量備份對應的 GTID（xtrabackup_binlog_info）
cat /backup/full/xtrabackup_binlog_info

# 3. 找出誤操作的 GTID
mysqlbinlog --base64-output=decode-rows -vv mysql-bin.000123 | grep -B5 'DELETE FROM `orders`'

# 4. 重放到誤操作前，跳過那筆交易
mysqlbinlog --skip-gtids=false \
  --exclude-gtids='3E11FA47-71CA-11E1-9E33-C80AA9429562:1001' \
  mysql-bin.000120 mysql-bin.000121 mysql-bin.000122 mysql-bin.000123 \
  | mysql -uroot -p
```

也可以用 `--stop-datetime='2026-10-24 14:03:14'` 依時間截止，但用 GTID 會更精確。

> 正式還原時，請先還原到一台**獨立的新實例**，確認資料正確後再決定是切換過去，還是只撈出被刪除的資料補回原庫。
{: .prompt-warning }

## 備份策略與還原演練

- **3-2-1 原則**：3 份副本、2 種媒介、1 份異地。
- **加密與壓縮**：備份檔包含所有資料，必須加密後再上傳物件儲存。
- **定期還原演練**：每月至少一次，自動化還原到測試機並跑資料檢查，記錄實際 RTO。
- **監控**：備份任務是否成功、備份大小是否異常、binlog 歸檔是否中斷。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| Binlog 預設 | **關閉** | **預設開啟** | 預設開啟 |
| Binlog 過期參數 | `expire_logs_days` | `binlog_expire_logs_seconds`（預設 30 天），`expire_logs_days` 棄用 | `expire_logs_days` **移除** |
| `mysqlpump` | 有 | 8.0.34 起棄用 | **移除** |
| MySQL Shell Dump | 可對 5.7 匯出 | 完整支援 | 完整支援 |
| Clone Plugin | 無 | 8.0.17+ | 有 |
| 備份鎖 | 僅 `FLUSH TABLES WITH READ LOCK` | `LOCK INSTANCE FOR BACKUP`、`BACKUP_ADMIN` | 同 8.0 |
| Binlog 壓縮 | 無 | 8.0.20+ `binlog_transaction_compression` | 有 |
| `mysqldump` 輸出相容舊版 | — | — | 新增 `--output-as-version` |
| XtraBackup 版本 | 2.4 | 8.0 | 8.4 |
| 資料字典 | `.frm` 檔 | 存在 InnoDB 系統表空間，不再有 `.frm` | 同 8.0 |

從 5.7 升上來最常踩到的雷：

1. **XtraBackup 2.4 不能備份 8.0**，升級後要同步換備份工具版本。
2. 8.0 預設開 binlog，若磁碟沒規劃，binlog 可能吃滿空間。
3. 原本用 `mysqlpump` 的備份腳本，在 8.4 會直接失敗。
4. 8.0.x 小版本之間 redo log 格式也有變動（例如 8.0.30），XtraBackup 要用不低於 MySQL 的版本。

## 小結

- 物理備份負責「快」，邏輯備份負責「彈性」，binlog 負責「精準」。
- 8.0 起可以用 Clone Plugin 快速建立從庫，用 MySQL Shell Dump 取代 `mysqldump`/`mysqlpump`。
- 沒有演練過的還原流程，在事故當下一定會出問題。

下一篇：[高可用與災難復原]({% post_url 2026-10-24-mysql-ops-03-ha-dr %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Backup and Recovery](https://dev.mysql.com/doc/refman/8.0/en/backup-and-recovery.html)
- [MySQL 8.0 Reference Manual：The Clone Plugin](https://dev.mysql.com/doc/refman/8.0/en/clone-plugin.html)
- [MySQL 8.4 Release Notes：Changes in MySQL 8.4.0](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)
