---
title: MySQL 高可用實作 06：Percona Server 5.7 升級 8.0，先升從庫再主從切換（Rocky Linux 9）
date: 2026-10-25 15:30:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql57, mysql8, percona, rocky-linux, replication, gtid, upgrade, switchover, dba]
description: 在一主二從的 Percona Server 5.7.44 GTID 複製架構上，先把兩台從庫就地升級到 8.0.46，再做計畫內主從切換讓 8.0 當主庫，最後升級舊主庫。全程應用程式持續寫入，實測寫入中斷 0.67 秒、沒有遺失任何一筆資料。
---

前面五篇都是在 8.0 上從零建立架構，但實務上更常遇到的是：**線上已經有一組 5.7 的主從，要升到 8.0，而且不能停機太久**。這篇用一主二從實際走一遍業界最常用的做法：

1. 先把**從庫**一台一台就地升級到 8.0（5.7 主庫 → 8.0 從庫是官方支援的方向）。
2. 兩台從庫都是 8.0 之後，做一次**計畫內切換**，讓 8.0 的從庫變成新主庫。
3. 最後把舊主庫升級到 8.0，再以從庫身分接回新主庫。

整個過程中有一個模擬應用程式每 0.2 秒寫一筆資料，用來量測寫入中斷的時間，並在最後核對有沒有掉資料。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - 5.7 用 `ps57` 套件庫的最新版 **Percona Server 5.7.44-48.1**（5.7 已在 2023-10 EOL，這是公開套件庫的最後一版，el9 套件從 5.7.41 開始提供）；8.0 用 `ps80` 套件庫的最新版 **8.0.46-37.1**，和本系列其他篇相同。
> - 文中的指令輸出都是實際執行的結果：Rocky Linux 9.8 容器 + systemd，用 `dnf` 從 `repo.percona.com` 實際安裝與升級（MacBook Air M4 / Docker Desktop）。**Percona 5.7 沒有 aarch64 套件**，所以整組環境以 `linux/amd64` 透過 Rosetta 模擬執行，輸出的架構字樣都是 `x86_64`。
> - 驗證腳本與完整輸出在 repo 的 [`tools/mysql-upgrade-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-upgrade-lab)。
> - **沒有實測的部分**：`firewalld`、SELinux（容器內沒有），以及步驟 9 的 `CHANGE REPLICATION SOURCE` 在 db1 上的這個寫法（實測時順序不同，見文末「驗證方式與結果」）。
{: .prompt-warning }

## 架構

| 主機 | IP | 升級前 | 升級後 |
| :--- | :--- | :--- | :--- |
| `db1` | 192.168.57.11 | 5.7 Source（主庫） | 8.0 Replica |
| `db2` | 192.168.57.12 | 5.7 Replica | **8.0 Source（新主庫）** |
| `db3` | 192.168.57.13 | 5.7 Replica | 8.0 Replica |
| `app` | 192.168.57.20 | 每 0.2 秒寫一筆到主庫 | 同左 |

整體順序：

| 階段 | db1 | db2 | db3 | 複製方向 |
| :--- | :--- | :--- | :--- | :--- |
| 起始 | 5.7 主 | 5.7 從 | 5.7 從 | db1 → db2、db3 |
| 升級 db2（步驟 1~5） | 5.7 主 | **8.0 從** | 5.7 從 | db1 → db2、db3 |
| 升級 db3（步驟 6） | 5.7 主 | 8.0 從 | **8.0 從** | db1 → db2、db3 |
| 切換（步驟 7） | 5.7 唯讀、不複製 | **8.0 主** | 8.0 從 | db2 → db3 |
| 升級 db1（步驟 8） | **8.0** 唯讀、不複製 | 8.0 主 | 8.0 從 | db2 → db3 |
| db1 接回（步驟 9） | 8.0 從 | 8.0 主 | 8.0 從 | db2 → db1、db3 |

> 為什麼不直接升主庫？MySQL 只保證「**舊版主庫 → 新版從庫**」的複製，反方向（8.0 主庫 → 5.7 從庫）不支援。先升從庫，整個過程中複製方向永遠是舊 → 新；切換後舊主庫還是 5.7，**不能直接接到 8.0 新主庫**，要先升級到 8.0 再接回去。
{: .prompt-info }

## 步驟 0：5.7 起始環境

三台已經是 5.7.44 的 GTID 一主二從（建法和 [GTID 主從複製]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 相同，只是 5.7 的語法），設定放在 `/etc/my.cnf.d/`。這份是**典型的 5.7 時期設定**，故意保留了幾個 8.0 已經不認得的參數：

```ini
# /etc/my.cnf.d/replication.cnf（5.7 時期，三台共用；server_id / report_host / super_read_only 放在 server-id.cnf）
[mysqld]
bind_address             = 0.0.0.0
skip_name_resolve        = ON
character_set_server     = utf8mb4
collation_server         = utf8mb4_general_ci
sql_mode                 = ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
innodb_buffer_pool_size  = 256M
innodb_flush_log_at_trx_commit = 1

# 5.7 常見、但 8.0 已移除的設定
query_cache_type         = 0
query_cache_size         = 0

# ---- Binlog / GTID ----
log_bin                  = mysql-bin
binlog_format            = ROW
sync_binlog              = 1
expire_logs_days         = 7
gtid_mode                = ON
enforce_gtid_consistency = ON
log_slave_updates        = ON
master_info_repository   = TABLE
relay_log_info_repository = TABLE
relay_log                = relay-bin
relay_log_recovery       = ON
slave_parallel_type      = LOGICAL_CLOCK
slave_parallel_workers   = 4
slave_preserve_commit_order = ON
```

5.7 的 RPM 和 8.0 不同，`/etc/my.cnf` 是透過 alternatives 指到 `/etc/percona-server.cnf`，**本來就有** `!includedir /etc/my.cnf.d/`。這一點在升級時會出事，後面會看到：

```console
# ls -l /etc/my.cnf; readlink -f /etc/my.cnf
lrwxrwxrwx 1 root root 24 Oct 25 07:27 /etc/my.cnf -> /etc/alternatives/my.cnf
/etc/percona-server.cnf

# grep -v "^#" /etc/percona-server.cnf | grep -v "^$"
!includedir /etc/my.cnf.d/
!includedir /etc/percona-server.conf.d/
```

為了讓升級檢查有東西可以抓，主庫上建了幾張「5.7 時代」常見的表：

```sql
CREATE TABLE appdb.t_orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(100), src VARCHAR(20),
                             created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;    -- app 持續寫入這張
CREATE TABLE appdb.t_legacy (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB DEFAULT CHARSET=utf8;  -- utf8mb3
CREATE TABLE appdb.t_rank   (id INT PRIMARY KEY, `rank` INT, qty INT(10) ZEROFILL) ENGINE=InnoDB;     -- 8.0 新保留字
CREATE TABLE appdb.t_myisam (id INT PRIMARY KEY, v VARCHAR(20)) ENGINE=MyISAM;
```

帳號都是 5.7 預設的 `mysql_native_password`：

```console
[db1] mysql> SELECT user, host, plugin FROM mysql.user WHERE user IN ('repl','app','root');
+------+--------------+-----------------------+
| user | host         | plugin                |
+------+--------------+-----------------------+
| root | localhost    | mysql_native_password |
| repl | 192.168.57.% | mysql_native_password |
| app  | 192.168.57.% | mysql_native_password |
+------+--------------+-----------------------+
```

升級前三台資料一致、兩台從庫都在跑：

```console
[db2] mysql> SHOW SLAVE STATUS\G   （節錄）
                  Master_Host: db1
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
        Seconds_Behind_Master: 0
            Executed_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:1-24
                Auto_Position: 1
```

## 步驟 1：升級前檢查（MySQL Shell Upgrade Checker）

在第一台要升級的從庫 db2 上切到 ps80 套件庫，先只裝 MySQL Shell：

```bash
sudo percona-release setup -y ps80      # 會停用 ps57 套件庫，已安裝的 5.7 不受影響
sudo dnf -q --showduplicates list percona-server-server | tail -3
sudo dnf install -y percona-mysql-shell
```

```console
* Disabling all Percona Repositories
* Enabling the Percona Server for MySQL 8.0 repository
<*> All done!
percona-server-server.x86_64        8.0.44-35.1.el9         ps-80-release-x86_64
percona-server-server.x86_64        8.0.45-36.1.el9         ps-80-release-x86_64
percona-server-server.x86_64        8.0.46-37.1.el9         ps-80-release-x86_64

mysqlsh   Ver 8.0.46 for Linux on x86_64 - for MySQL 8.0.46-37 (Source distribution)
```

對 5.7 執行升級檢查，目標版本指定成要裝的 8.0.46：

```bash
mysqlsh --no-wizard -uroot -p'ChangeMe_Root_2026' --socket=/var/lib/mysql/mysql.sock \
  -- util check-for-server-upgrade --target-version=8.0.46
```

實測輸出（節錄，29 項中只列出有發現的項目）：

```console
The MySQL server at /var%2Flib%2Fmysql%2Fmysql.sock, version 5.7.44-48-log -
Percona Server (GPL), Release 48, Revision 497f936a373, will now be checked for
compatibility issues for upgrade to MySQL 8.0.46...

3) Usage of db objects with names conflicting with new reserved keywords
  Warning: The following objects have names that conflict with new reserved
    keywords. Ensure queries sent by your applications use `quotes` when
    referring to them or they will result in errors.
  appdb.t_rank.rank - Column name

4) Usage of utf8mb3 charset
  Warning: The following objects use the utf8mb3 character set. It is
    recommended to convert them to use utf8mb4 instead, for improved Unicode
    support.
  appdb.t_legacy.name - column's default character set: utf8

9) Usage of obsolete sql_mode flags
  Notice: The following DB objects have obsolete options persisted for
    sql_mode, which will be cleared during upgrade to 8.0.
  global system variable sql_mode - defined using obsolete NO_AUTO_CREATE_USER
    option

15) Removed system variables for error logging to the system log configuration
  To run this check requires full path to MySQL server configuration file to be specified at 'configPath' key of options dictionary
16) Removed system variables
  To run this check requires full path to MySQL server configuration file to be specified at 'configPath' key of options dictionary
17) System variables with new default values
  To run this check requires full path to MySQL server configuration file to be specified at 'configPath' key of options dictionary

22) New default authentication plugin considerations
  Warning: The new default authentication plugin 'caching_sha2_password' offers
    more secure password hashing than previously used 'mysql_native_password'
  ...
    If you are using replication please take time to understand how the
    authentication plugin changes may impact you.

Errors:   0
Warnings: 3
Notices:  1

NOTE: No fatal errors were found that would prevent an upgrade, but some potential issues were detected. Please ensure that the reported issues are not significant before upgrading.
```

怎麼解讀：

| 項目 | 意思 | 處理 |
| :--- | :--- | :--- |
| `t_rank.rank` 保留字 | 8.0.2 起 `RANK` 是保留字，SQL 裡沒加反引號會語法錯誤 | 資料庫本身升級沒問題，要改的是**應用程式的 SQL**，升級前先 grep 程式碼 |
| `utf8mb3` | 舊的 `utf8` 在 8.0 叫 `utf8mb3` 且已棄用 | 不影響升級，之後排時間轉 `utf8mb4` |
| `NO_AUTO_CREATE_USER` | 8.0 移除這個 sql_mode | 資料裡存的會自動清掉，但**設定檔裡的不會**（見步驟 4） |
| `caching_sha2_password` | 8.0 新帳號預設用新的認證外掛 | 升級後舊帳號維持 `mysql_native_password`，見文末「後續」 |

> **第 15~17 項其實沒有檢查**。這三項要讀設定檔，沒給 `configPath` 就直接跳過，所以 `query_cache_*`、`expire_logs_days` 這些 8.0 已移除的參數**完全沒被抓出來**。要檢查設定檔可以加 `--config-path=/etc/my.cnf`；但更可靠的是步驟 4 的 `mysqld --validate-config`，它是 8.0 的 mysqld 自己讀一遍設定。
>
> 另外 MyISAM 表和 `INT(10) ZEROFILL` 也沒有被列出來（它們在 8.0 都還能用，只是棄用）。
{: .prompt-warning }

## 步驟 2：從庫停複製、完整關機、備份（db2）

```sql
-- db2
STOP SLAVE;
SET GLOBAL innodb_fast_shutdown = 0;   -- 完整關機：purge、change buffer merge 都做完，就地升級前官方建議
```

```console
[db2]# time systemctl stop mysqld; tail -3 /var/log/mysqld.log
real	0m2.175s
2026-10-25T07:52:48.748544Z 0 [Note] Shutting down plugin 'binlog'
2026-10-25T07:52:48.751571Z 0 [Note] /usr/sbin/mysqld: Shutdown complete
```

**一定要先備份**。8.0 第一次啟動會把資料目錄升級成新的資料字典格式，**之後不能再用 5.7 開啟，也沒有官方的降版方法**。唯一的退路就是這份備份（或用 5.7 從主庫重建一台）：

```bash
cp -a /var/lib/mysql /var/lib/mysql-5.7-backup
cp -a /etc/my.cnf.d  /root/my.cnf.d-5.7
```

```console
# du -sh /var/lib/mysql-5.7-backup
123M	/var/lib/mysql-5.7-backup
```

> 實際環境資料量大時，用 LVM / 雲端磁碟快照或 Percona XtraBackup 會比 `cp -a` 快很多。從庫停著的這段時間只是複製延遲，主庫照常服務，所以不用趕。
{: .prompt-tip }

## 步驟 3：移除 5.7、安裝 8.0（db2）

5.7 和 8.0 的套件名稱不同（`Percona-Server-*-57` vs `percona-server-*`），會互相衝突，要先移除 5.7。**移除套件不會刪資料目錄**：

```bash
sudo dnf remove -y "Percona-Server-*-57"
sudo dnf install -y percona-server-server percona-server-client
```

```console
Removing:
 Percona-Server-client-57   x86_64  5.7.44-48.1.el9          @ps-57-release-x86_64   34 M
 Percona-Server-server-57   x86_64  5.7.44-48.1.el9          @ps-57-release-x86_64  102 M
 Percona-Server-shared-57   x86_64  5.7.44-48.1.el9          @ps-57-release-x86_64  3.9 M
Removed "/etc/systemd/system/multi-user.target.wants/mysqld.service".
Removed "/etc/systemd/system/mysql.service".
Complete!

# ls -l /etc/my.cnf*
/etc/my.cnf.d:
-rw-r--r-- 1 root root 1114 Oct 25 07:51 replication.cnf
-rw-r--r-- 1 root root   64 Oct 25 07:51 server-id.cnf

/etc/my.cnf.d_backup-20261025-0752:
-rw-r--r-- 1 root root 1114 Oct 25 07:51 replication.cnf
-rw-r--r-- 1 root root   64 Oct 25 07:51 server-id.cnf

# ls /var/lib/mysql | head -3
appdb
auto.cnf
ca-key.pem

Installing:
 percona-server-client     x86_64  8.0.46-37.1.el9          ps-80-release-x86_64      3.1 M
 percona-server-server     x86_64  8.0.46-37.1.el9          ps-80-release-x86_64       59 M
 percona-server-shared     x86_64  8.0.46-37.1.el9          ps-80-release-x86_64      1.5 M
Complete!

# mysqld --version
/usr/sbin/mysqld  Ver 8.0.46-37 for Linux on x86_64 (Percona Server (GPL), Release 37, Revision 39e2b60e)
```

觀察到的幾件事：

- 移除 5.7 會一併刪掉 `/etc/my.cnf`（alternatives 的連結）和 systemd 的 enable 連結；`/etc/my.cnf.d` 保留，另外自動備份一份 `/etc/my.cnf.d_backup-日期`。
- 安裝 8.0 會**重新 enable** `mysqld.service`，但不會啟動。
- 8.0 放了一個全新的 `/etc/my.cnf`，**內容不一樣了**：

```console
# grep -v "^#" /etc/my.cnf | grep -v "^$"
[mysqld]
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

## 步驟 4：修正設定檔（啟動前！）

### 4-1. 坑 1：8.0 的 my.cnf 沒有 includedir

和 [GTID 篇]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 提過的一樣，8.0 RPM 的 `/etc/my.cnf` 沒有 `!includedir /etc/my.cnf.d`。5.7 時期能用的設定，升級後**完全不會被讀到**。用 `my_print_defaults` 確認 mysqld 實際會讀到哪些參數：

```console
# my_print_defaults mysqld
--datadir=/var/lib/mysql
--socket=/var/lib/mysql/mysql.sock
--log-error=/var/log/mysqld.log
--pid-file=/var/run/mysqld/mysqld.pid
```

`server_id`、`gtid_mode`、`log_bin`、`super_read_only` 全都不見了。這時候直接啟動的話，從庫會變成 `server_id = 1`（和主庫一樣！）、GTID 關閉、可以寫入，複製一啟動就出錯，而且資料目錄已經被升級成 8.0 格式，回不去了。

> 這是整個升級過程中最危險的一步：**不會有任何錯誤訊息**，mysqld 照樣啟動成功。啟動前務必先跑 `my_print_defaults mysqld` 確認。
{: .prompt-danger }

補上 includedir：

```bash
grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf
```

### 4-2. 坑 2：5.7 的參數 8.0 不認得

8.0.16 起 mysqld 有 `--validate-config`，**不啟動服務、只檢查設定檔**，升級時非常好用。直接拿 5.7 的設定去檢查：

```console
# mysqld --validate-config --user=mysql; echo "exit=$?"
[Warning] [MY-011068] [Server] The syntax 'expire-logs-days' is deprecated and will be removed in a future release. Please use binlog_expire_logs_seconds instead.
[ERROR] [MY-000077] [Server] /usr/sbin/mysqld: Error while setting value 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION' to 'sql_mode'.
[ERROR] [MY-010119] [Server] Aborting
exit=1
```

> `--validate-config` **遇到第一個錯誤就停**。這裡只報了 `sql_mode`，後面的 `query_cache_type` / `query_cache_size`（8.0 已移除，同樣會讓 mysqld 起不來）根本沒有被檢查到。所以要「改一個、再跑一次」，直到 `exit=0`，或是一次把下表的參數全部處理掉。
{: .prompt-warning }

5.7 → 8.0 設定檔要改的地方：

| 5.7 | 8.0 | 不改的後果 |
| :--- | :--- | :--- |
| `sql_mode` 含 `NO_AUTO_CREATE_USER` | 拿掉 | **起不來** |
| `query_cache_type`、`query_cache_size` | 刪除（Query Cache 已移除） | **起不來** |
| `expire_logs_days = 7` | `binlog_expire_logs_seconds = 604800` | 棄用警告；兩個都設定時以 `binlog_expire_logs_seconds` 為準 |
| `master_info_repository`、`relay_log_info_repository` | 刪除（8.0 預設就是 `TABLE`） | 棄用警告 |
| `log_slave_updates`、`slave_parallel_*`、`slave_preserve_commit_order` | `log_replica_updates`、`replica_parallel_*`、`replica_preserve_commit_order` | 舊名稱 8.0 還認得，但已棄用 |
| `collation_server = utf8mb4_general_ci` | 建議**先保留** | 8.0 預設是 `utf8mb4_0900_ai_ci`，混合版本期間改了會讓新舊表排序規則不一致 |

改好的 8.0 版：

```ini
# /etc/my.cnf.d/replication.cnf（升級到 Percona Server 8.0 後）
[mysqld]
bind_address             = 0.0.0.0
skip_name_resolve        = ON
character_set_server     = utf8mb4
collation_server         = utf8mb4_general_ci   # 保留 5.7 的排序規則，升級後新建的表與舊表一致
sql_mode                 = ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
innodb_buffer_pool_size  = 256M
innodb_flush_log_at_trx_commit = 1

# ---- Binlog / GTID ----
log_bin                  = mysql-bin
binlog_format            = ROW
sync_binlog              = 1
binlog_expire_logs_seconds = 604800
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON
relay_log                = relay-bin
relay_log_recovery       = ON
replica_parallel_type    = LOGICAL_CLOCK
replica_parallel_workers = 4
replica_preserve_commit_order = ON
```

再檢查一次，只剩棄用警告：

```console
# mysqld --validate-config --user=mysql; echo "exit=$?"
[Warning] [MY-011070] [Server] 'binlog_format' is deprecated and will be removed in a future release.
[Warning] [MY-011069] [Server] The syntax '--replica-parallel-type' is deprecated and will be removed in a future release.
[Warning] [MY-010097] [Server] Insecure configuration for --secure-log-path: Current value does not restrict location of generated files. Consider setting it to a valid, non-empty path.
exit=0
```

## 步驟 5：啟動 8.0，自動升級資料目錄（db2）

8.0.16 起**不需要再跑 `mysql_upgrade`**，第一次啟動時 mysqld 會自己升級資料字典與系統表：

```console
# time systemctl start mysqld; systemctl is-active mysqld
real	0m3.852s
active

# grep -E "upgrad|ready for connections|\[ERROR\]" /var/log/mysqld.log | tail -5
2026-10-25T07:53:20.413896Z 1 [System] [MY-011012] [Server] Starting upgrade of data directory.
2026-10-25T07:53:21.644089Z 5 [System] [MY-013381] [Server] Server upgrade from '50700' to '80046' started.
2026-10-25T07:53:23.676577Z 5 [System] [MY-013381] [Server] Server upgrade from '50700' to '80046' completed.
2026-10-25T07:53:23.783693Z 0 [System] [MY-010931] [Server] /usr/sbin/mysqld: ready for connections. Version: '8.0.46-37'  socket: '/var/lib/mysql/mysql.sock'  port: 3306  Percona Server (GPL), Release 37, Revision 39e2b60e.
```

設定都有生效，`super_read_only` 也還在：

```console
[db2] mysql> SELECT @@hostname, @@server_id, @@version, @@gtid_mode, @@super_read_only, @@collation_server, @@replica_parallel_workers\G
                @@hostname: db2
               @@server_id: 2
                 @@version: 8.0.46-37
               @@gtid_mode: ON
         @@super_read_only: 1
        @@collation_server: utf8mb4_general_ci
@@replica_parallel_workers: 4
```

**複製自己就恢復了**（`STOP SLAVE` 不會被記住，沒設 `skip_replica_start` 時 mysqld 啟動就會開始複製），而且從停機前的 GTID 位置接續追上主庫：

```console
[db2] mysql> SHOW SLAVE STATUS\G   （節錄）
                  Master_Host: db1
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
        Seconds_Behind_Master: 0
           Retrieved_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:225-346
            Executed_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:1-346
                Auto_Position: 1
```

> 如果想在啟動後先檢查一輪再開始複製，就在設定檔加 `skip_replica_start = ON`，確認沒問題後手動 `START REPLICA`，再把這行拿掉。
{: .prompt-tip }

升級後的狀態：帳號維持 `mysql_native_password`，`utf8` 的表現在顯示成 `utf8mb3`，MyISAM 表還是 MyISAM（升級不會自動轉換）：

```console
[db2] mysql> SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='appdb' ORDER BY 1;
+------------+--------+--------------------+
| TABLE_NAME | ENGINE | TABLE_COLLATION    |
+------------+--------+--------------------+
| t_legacy   | InnoDB | utf8mb3_general_ci |
| t_myisam   | MyISAM | utf8mb4_general_ci |
| t_orders   | InnoDB | utf8mb4_general_ci |
| t_rank     | InnoDB | utf8mb4_general_ci |
+------------+--------+--------------------+
```

比對資料：先讓從庫追上主庫目前的 `gtid_executed`，再比較筆數與內容雜湊：

```sql
-- 從庫：等到套用完主庫的 GTID 集合，回傳 0 表示已追上
SELECT WAIT_FOR_EXECUTED_GTID_SET('<主庫的 @@GLOBAL.gtid_executed>', 60);
-- 每台都跑
SELECT @@hostname, @@version, COUNT(*), SUM(CRC32(CONCAT_WS('#', id, note, src))) FROM appdb.t_orders;
```

```console
| db1  | 5.7.44-48-log |     5334 | 11441917755799 |
| db2  | 8.0.46-37     |     5334 | 11441917755799 |
```

5.7 主庫 → 8.0 從庫，資料一致。

## 步驟 6：升級第二台從庫（db3）

db3 照步驟 2~5 再做一次（升級檢查做一次就夠了）。實測時間幾乎一樣：關機 2.2 秒、8.0 第一次啟動 3.8 秒，從停複製到恢復複製約 38 秒，大部分花在 `dnf`。

兩台從庫都升完後，**主庫 db1 仍是 5.7、兩台從庫都是 8.0**，資料一致：

```console
| db1  | 5.7.44-48-log |     5586 | 11978139672461 |
| db2  | 8.0.46-37     |     5586 | 11978139672461 |
| db3  | 8.0.46-37     |     5586 | 11978139672461 |
```

這段期間 app 一直在寫 db1，**沒有任何一筆失敗**：

```console
[app]# echo "OK=$(grep -c OK /tmp/writer.log) ERR=$(grep -c ERR /tmp/writer.log)"
OK=586 ERR=0
```

> 混合版本的狀態可以撐一段時間（例如觀察 8.0 從庫上的查詢效能、把讀流量先切一部分過去），這正是「先升從庫」的好處：**主庫完全不受影響，隨時可以停手**。8.0 從庫有問題的話，從 5.7 主庫重建一台 5.7 從庫即可。
{: .prompt-tip }

## 步驟 7：計畫內主從切換（db1 → db2）

和 [GTID 篇的 Switchover]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 流程相同，差別在舊主庫是 5.7、新主庫是 8.0。

切換前確認兩台從庫都沒有延遲：

```console
[db2] mysql> SHOW SLAVE STATUS\G   （節錄）
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
        Seconds_Behind_Master: 0
            Executed_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:1-601
```

**1. 舊主庫停止寫入**（從這一刻開始，app 的寫入會失敗）：

```console
[db1] mysql> SET GLOBAL super_read_only = ON; SELECT @@GLOBAL.gtid_executed\G
@@GLOBAL.gtid_executed: dce89f70-d048-11f1-9b4c-82a31f054add:1-603
```

**2. 等兩台從庫套用完舊主庫的所有交易**：

```console
[db2] mysql> SELECT WAIT_FOR_EXECUTED_GTID_SET('dce89f70-d048-11f1-9b4c-82a31f054add:1-603', 30) AS waited;
+--------+
| waited |
+--------+
|      0 |
+--------+
```

db3 同樣回傳 `0`。

**3. db2 升為主庫**：

```sql
-- db2
STOP REPLICA;
RESET REPLICA ALL;
SET PERSIST super_read_only = OFF;
SET PERSIST read_only = OFF;
```

設定檔裡的 `super_read_only = ON` 也要拿掉（`SET PERSIST` 寫在 `mysqld-auto.cnf`，雖然優先順序比 `/etc/my.cnf.d` 高，但兩邊不一致日後很容易搞混）：

```console
[db2]# sed -i '/super_read_only/d' /etc/my.cnf.d/server-id.cnf; cat /var/lib/mysql/mysqld-auto.cnf
{"Version": 2, "mysql_dynamic_variables": {"read_only": {"Value": "OFF", ...}, "super_read_only": {"Value": "OFF", ...}}}
```

**4. 應用程式改寫 db2**（實務上是切 VIP、DNS 或 ProxySQL / HAProxy 的後端）。

**5. db3 改接 db2**，GTID 自動定位，不需要找 binlog 位置：

```sql
-- db3
STOP REPLICA;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='ChangeMe_Repl_2026', SOURCE_AUTO_POSITION=1;
START REPLICA;
```

```console
[db3] mysql> SHOW SLAVE STATUS\G   （節錄）
                  Master_Host: db2
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
        Seconds_Behind_Master: 0
            Executed_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:1-603,
df5e7840-d048-11f1-9a41-56e611d96467:1-16
                Auto_Position: 1

[db2] mysql> SHOW REPLICAS;
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         3 | db3  | 3306 |         2 | e1d68439-d048-11f1-9a4a-b21f06a1499f |
+-----------+------+------+-----------+--------------------------------------+
```

`Executed_Gtid_Set` 多了一段 `df5e7840-...`，就是 db2 當主庫後產生的交易。

> 複製帳號 `repl` 是在 5.7 建的，升級後仍是 `mysql_native_password`，所以 db3 接 db2 不需要 SSL。若複製帳號是在 8.0 新建的（預設 `caching_sha2_password`），沒有 SSL 時要加 `GET_SOURCE_PUBLIC_KEY = 1` 或 `SOURCE_SSL = 1`，否則會報 `Authentication requires secure connection`。
{: .prompt-info }

### 寫入中斷時間

app 的紀錄：

```console
07:54:57.120 ERR db1 ERROR 1290 (HY000) at line 1: The MySQL server is running with the --read-only option so it cannot execute this statement
07:54:57.445 ERR db1 ERROR 1290 (HY000) at line 1: The MySQL server is running with the --read-only option so it cannot execute this statement
07:54:57.786 OK db2

first ERR=07:54:57.120  first OK on db2=07:54:57.786
寫入中斷秒數: 0.666
```

**寫入中斷 0.67 秒、失敗 2 筆**（另一次完整重跑是 1.04 秒、3 筆）。app 在模擬環境下每秒大約只寫 3 筆，所以精確度約 0.3 秒。這是手動一行一行下指令的時間，寫成腳本或交給 Orchestrator 之類的工具會更短；實際環境的瓶頸通常是 VIP / DNS 生效的時間。

切換後 db2、db3 資料一致：

```console
| db2  | 8.0.46-37 |     5607 | 12023439752639 |
| db3  | 8.0.46-37 |     5607 | 12023439752639 |
```

## 步驟 8：先把舊主庫 db1 升級到 8.0

切換後 db1 還是 5.7，而且已經是 `super_read_only`，沒有任何複製。**不要**把它直接接成 db2 的從庫：

> MySQL 不支援 8.0 主庫複製到 5.7 從庫。就算一時沒出錯，也只是剛好沒碰到不相容的地方，例如：
>
> - 8.0 預設排序規則 `utf8mb4_0900_ai_ci`（編號 255）5.7 不認得，帶到這個排序規則的事件會讓 5.7 從庫的 SQL 執行緒停掉。
> - 8.0 新建的帳號預設用 `caching_sha2_password`，5.7 從庫的複製連線認證不過。
> - 8.0 才有的語法（視窗函數、CTE、`INVISIBLE` 索引等）或新的 binlog 事件，5.7 解析不了。
>
> 這些錯誤有可能在接上去幾個小時、幾天後才出現，到時候 5.7 從庫已經和主庫不一致。
{: .prompt-danger }

所以順序是：**db1 先升級到 8.0，再接回 db2**。db1 不複製的這段時間，db2 產生的交易都留在 db2 的 binlog 裡，等 db1 接回去時用 GTID 自動補上；只要 `binlog_expire_logs_seconds`（本例 7 天）比 db1 升級的時間長就沒問題。

設定檔先加上 `super_read_only = ON`，避免升級重啟後 db1 變成可寫、被誤寫入產生多餘的 GTID：

```console
[db1]# printf 'super_read_only = ON\n' >> /etc/my.cnf.d/server-id.cnf; cat /etc/my.cnf.d/server-id.cnf
[mysqld]
server_id   = 1
report_host = db1
super_read_only = ON
```

接著照步驟 2~5 升級（`innodb_fast_shutdown = 0` 關機 → 備份 → 換套件 → 補 includedir 與 8.0 設定 → `--validate-config` → 啟動）。實測：

```console
[db1]# time systemctl stop mysqld
real	0m2.287s

[db1]# du -sh /var/lib/mysql-5.7-backup
187M	/var/lib/mysql-5.7-backup

[db1]# time systemctl start mysqld
real	0m3.924s

2026-10-25T07:56:31.444537Z 1 [System] [MY-011012] [Server] Starting upgrade of data directory.
2026-10-25T07:56:32.726364Z 5 [System] [MY-013381] [Server] Server upgrade from '50700' to '80046' started.
2026-10-25T07:56:34.779445Z 5 [System] [MY-013381] [Server] Server upgrade from '50700' to '80046' completed.

[db1] mysql> SELECT @@hostname, @@server_id, @@version, @@gtid_mode, @@super_read_only, @@collation_server\G
                @@hostname: db1
               @@server_id: 1
                 @@version: 8.0.46-37
               @@gtid_mode: ON
         @@super_read_only: 1
        @@collation_server: utf8mb4_general_ci
```

> **退路要在切換前就準備好**。db1 一旦用 8.0 啟動就回不去 5.7，所以「切換後發現 8.0 有問題、退回 5.7」不能指望舊主庫。要保留退路，就在切換前做好 5.7 的完整備份（例如步驟 7 前對 db1 做一次 XtraBackup 或磁碟快照），或另外留一台不升級的 5.7 節點；但要注意，切換後在 8.0 上寫入的資料沒辦法用複製帶回 5.7，退回時這段資料要另外處理。
{: .prompt-warning }

## 步驟 9：db1 接回新主庫 db2

db1 已經是 8.0，用 8.0 語法接到 db2，GTID 自動定位會從 db1 缺少的第一個交易開始補：

```sql
-- db1
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='ChangeMe_Repl_2026', SOURCE_AUTO_POSITION=1;
START REPLICA;
```

```console
[db1] mysql> SHOW SLAVE STATUS\G   （節錄）
                  Master_Host: db2
             Slave_IO_Running: Yes
            Slave_SQL_Running: Yes
        Seconds_Behind_Master: 0
            Executed_Gtid_Set: dce89f70-d048-11f1-9b4c-82a31f054add:1-603,
df5e7840-d048-11f1-9a41-56e611d96467:1-301
                Auto_Position: 1
```

`dce89f70-...:1-603` 是 db1 自己當主庫時的交易，`df5e7840-...:1-301` 是 db2 當主庫後的交易，全部都補上了。db2 在這段期間建的表（`t_after_switch`）也出現在 db1：

```console
[db1] mysql> SELECT TABLE_NAME, ENGINE, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='appdb' ORDER BY 1;
+----------------+--------+--------------------+
| TABLE_NAME     | ENGINE | TABLE_COLLATION    |
+----------------+--------+--------------------+
| t_after_switch | InnoDB | utf8mb4_general_ci |
| t_legacy       | InnoDB | utf8mb3_general_ci |
| t_myisam       | MyISAM | utf8mb4_general_ci |
| t_orders       | InnoDB | utf8mb4_general_ci |
| t_rank         | InnoDB | utf8mb4_general_ci |
+----------------+--------+--------------------+
```

## 步驟 10：最終驗證

三台都是 8.0.46，db2 是主庫、db1 / db3 唯讀：

```console
| db1        | 8.0.46-37 |           1 |                 1 |
| db2        | 8.0.46-37 |           0 |                 0 |
| db3        | 8.0.46-37 |           1 |                 1 |

[db2] mysql> SHOW REPLICAS;
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         1 | db1  | 3306 |         2 | dce89f70-d048-11f1-9b4c-82a31f054add |
|         3 | db3  | 3306 |         2 | e1d68439-d048-11f1-9a4a-b21f06a1499f |
+-----------+------+------+-----------+--------------------------------------+
```

停止 app，核對**每一筆回報成功的寫入都在資料庫裡**：

```console
[app]# echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"
OK=892 ERR=2
      2 db1 ERROR 1290 (HY000) at line 1: The MySQL server is running with the --read-only option so it cannot execute this statement

[db2] mysql> SELECT src, COUNT(*) FROM appdb.t_orders WHERE note LIKE 'w-%' GROUP BY src;
+------+----------+
| src  | COUNT(*) |
+------+----------+
| db1  |      589 |
| db2  |      303 |
+------+----------+
```

589 + 303 = 892，和 app 記錄的成功筆數完全相同；失敗的 2 筆都是切換時被 `super_read_only` 擋下的（應用程式收到錯誤，可以重試），沒有「回報成功卻不見」的資料。三台最後的筆數與雜湊：

```console
| db2  | 8.0.46-37 |     5892 | 12618375119959 |
| db1  | 8.0.46-37 |     5892 | 12618375119959 |
| db3  | 8.0.46-37 |     5892 | 12618375119959 |
```

## 升級完成後的待辦

升級本身不會幫你處理這些，確定穩定（通常觀察幾天到一週）後再排：

- **刪除 5.7 備份**：每台的 `/var/lib/mysql-5.7-backup`（本例 123~187 MB）。確定不會再退回 5.7 才刪。
- **認證外掛**：現有帳號都還是 `mysql_native_password`，8.0 新帳號預設是 `caching_sha2_password`。確認所有用戶端驅動都支援後，逐步 `ALTER USER ... IDENTIFIED WITH caching_sha2_password`。MySQL 8.4 預設已停用 `mysql_native_password`，之後升 8.4 前一定要處理。
- **`utf8mb3` 與排序規則**：`t_legacy` 轉 `utf8mb4`；`collation_server` 要不要改成 `utf8mb4_0900_ai_ci` 是另一個決定（排序與比較結果會變），不要跟版本升級綁在一起。
- **MyISAM**：轉成 InnoDB，否則 crash-safe 複製與 Clone 都沒辦法涵蓋它。
- **應用程式的保留字**：`rank` 這類欄位在 SQL 裡要加反引號，可以參考 [變更管理]({% post_url 2026-10-24-mysql-ops-08-change-management %}) 的版本差異表。
- **設定檔**：把 `binlog_format` 等棄用參數整理掉，並套用 [GTID 篇]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的 8.0 完整設定（`00-server.cnf`）。

## 實測踩到的坑

| 坑 | 現象 | 解法 |
| :--- | :--- | :--- |
| 8.0 的 `/etc/my.cnf` 沒有 `!includedir` | 不報錯，但 `my.cnf.d` 的設定全部失效；直接啟動會讓從庫 `server_id` 變成 1、GTID 關閉 | 啟動前補 `!includedir /etc/my.cnf.d`，用 `my_print_defaults mysqld` 確認 |
| 5.7 的 `sql_mode`、`query_cache_*` | 8.0 起不來：`Error while setting value ... to 'sql_mode'` | 啟動前用 `mysqld --validate-config` 反覆檢查到 `exit=0` |
| Upgrade Checker 沒檢查設定檔 | 第 15~17 項顯示 `requires full path to MySQL server configuration file`，`query_cache_*` 沒被抓出來 | 加 `--config-path`，或以 `--validate-config` 為準 |
| `--validate-config` 遇到第一個錯誤就停 | 只報 `sql_mode`，沒報 `query_cache_type` | 改一個、跑一次，直到 `exit=0` |
| 8.0 第一次啟動後無法回到 5.7 | 資料字典已升級 | 升級前備份資料目錄；從庫出問題就從主庫重建 |
| （實驗環境）Docker Desktop 上 5.7 初始化被 OOM kill | `mysqld --initialize` 吃到 7 GB | 見下方說明，實體主機不會遇到 |

> **實驗環境才有的問題**：第一次用 systemd 啟動 5.7 時，`mysqld_pre_systemd` 執行的 `mysqld --initialize` 被 OOM kill（吃到約 7 GB）。原因是 Docker Desktop VM 的 `fs.nr_open` 高達 1073741816，容器內 systemd 的 nofile 上限也跟著這麼大；而 Percona 5.7 的 `mysqld.service` 有 `PermissionsStartOnly=true`，systemd 252 不會把 unit 的 `LimitNOFILE=5000` 套用到 `ExecStartPre`，5.7 依開檔上限配置記憶體就爆了。實驗腳本在容器啟動後用 `prlimit --pid 1 --nofile=1048576:1048576` 把上限降回 Rocky 9 實體主機的預設值解決。實體主機若曾經把 `fs.nr_open` 調得非常大，也可能遇到同樣的事。
{: .prompt-info }

## 驗證方式與結果

用 [`tools/mysql-upgrade-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-upgrade-lab) 的腳本在 MacBook Air M4（Docker Desktop 4.96.3、VM 10 CPU / 7.7 GiB、Rosetta 模擬 amd64）上從全新容器完整跑過兩次，數字取自第二次：

```bash
./00-build.sh               # Rocky 9.8 + systemd + Percona Server 5.7.44-48.1（linux/amd64）
./10-setup-57.sh            # 5.7 一主二從（GTID），app 開始每 0.2 秒寫入 db1
./20-upgrade-replicas.sh    # db2、db3 依序就地升級到 8.0.46-37.1
./30-switchover.sh          # db2 升為主庫、db3 改接 db2、量測寫入中斷
./40-upgrade-old-primary.sh # db1 升級到 8.0，核對 app 每一筆成功寫入
```

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 1 升級檢查 | `util check-for-server-upgrade` | `Errors: 0` | ✅ 0 錯誤、3 警告、1 提示 |
| 4 設定檔 | `my_print_defaults`、`mysqld --validate-config` | 讀得到 `my.cnf.d`、`exit=0` | ✅（5.7 原設定 `exit=1`，如文中所示） |
| 5 啟動 8.0 | 錯誤日誌、`@@version`、`SHOW SLAVE STATUS` | `Server upgrade ... completed`、無 `[ERROR]`、IO / SQL `Yes` | ✅ 三台都是，啟動約 3.9 秒 |
| 6 混合版本 | 5.7 主庫寫入，比對三台筆數與 CRC | 完全一致；app 寫入 0 失敗 | ✅ OK=586、ERR=0 |
| 7 切換 | `WAIT_FOR_EXECUTED_GTID_SET`、db3 改接、app 紀錄 | 回傳 `0`、db3 無延遲、寫入恢復 | ✅ 中斷 0.67 秒（另一次 1.04 秒） |
| 8~9 舊主庫升級、接回 | 錯誤日誌、`SHOW SLAVE STATUS`、`Executed_Gtid_Set` | 升級完成無 `[ERROR]`；IO / SQL `Yes`、補齊 db2 的交易 | ✅（實測順序不同，見下方說明） |
| 10 最終 | 三台筆數與 CRC、app 成功筆數 vs 資料庫筆數 | 一致；892 = 589 + 303 | ✅ 無資料遺失 |

> **步驟 8、9 的實測順序和文中不同**：實測腳本（`30-switchover.sh`、`40-upgrade-old-primary.sh`）是在切換後先讓 5.7 的 db1 用 `CHANGE MASTER TO` 暫時接到 8.0 的 db2，再就地升級 db1。8.0 → 5.7 的複製官方不支援，所以文中改成「先升級 db1、再接回 db2」的正確順序，沒有重跑。文中步驟 8、9 的輸出取自那次實測（關機、升級、啟動的輸出與順序無關；最後的 `SHOW SLAVE STATUS`、GTID 集合與表清單是 db1 升級後接著 db2 的最終狀態），步驟 9 的 `CHANGE REPLICATION SOURCE TO` 在 db1 上沒有以這個順序實際執行過，但與步驟 7 在 db3 上執行的是同一個指令。實測中 5.7 的 db1 跟著 db2 時沒有出錯，那是因為 `collation_server` 固定成 `utf8mb4_general_ci`、複製帳號是 `mysql_native_password`，屬於運氣，不代表可以這樣做。
{: .prompt-info }

每一步的耗時：

| 動作 | 時間 |
| :--- | :--- |
| `systemctl stop`（`innodb_fast_shutdown = 0`） | 2.2~2.3 秒 |
| 8.0 第一次啟動（含資料目錄升級，其中升級本身約 2 秒） | 3.8~3.9 秒 |
| 單台從停複製到恢復複製 | 約 37~38 秒（主要是 `dnf remove` / `install`） |
| 主從切換寫入中斷 | 0.67 秒 / 1.04 秒 |

資料量很小（每台 120~190 MB），實際環境的關機時間（完整 purge）、備份時間與升級時間都會隨資料量和表的數量增加，但**主庫在從庫升級期間完全不受影響**這一點不變。

## 小結

- 5.7 → 8.0 的主從架構：**先升從庫、再切換、最後升舊主庫**，複製方向始終是舊版 → 新版。
- 升級前跑 MySQL Shell Upgrade Checker，但它預設不檢查設定檔；**啟動前一定要用 `my_print_defaults` 和 `mysqld --validate-config` 檢查**。
- Percona 8.0 的 `/etc/my.cnf` 沒有 `!includedir /etc/my.cnf.d`，這是升級最容易出事、而且不會報錯的地方。
- 8.0 第一次啟動就會升級資料目錄、回不去 5.7，**每台升級前都要備份**。
- 實測從庫升級期間應用程式 0 失敗，切換寫入中斷不到 1 秒，最終沒有遺失任何一筆成功寫入。

### 參考資料

- [Percona Server for MySQL 8.0：Upgrade from 5.7 to 8.0](https://docs.percona.com/percona-server/8.0/upgrade.html)
- [MySQL 8.0 Reference Manual：Upgrading MySQL](https://dev.mysql.com/doc/refman/8.0/en/upgrading.html)
- [MySQL 8.0 Reference Manual：Replication Compatibility Between MySQL Versions](https://dev.mysql.com/doc/refman/8.0/en/replication-compatibility.html)
- [MySQL Shell 8.0：Upgrade Checker Utility](https://dev.mysql.com/doc/mysql-shell/8.0/en/mysql-shell-utilities-upgrade.html)
- [MySQL 8.0 Reference Manual：Server Configuration Validation](https://dev.mysql.com/doc/refman/8.0/en/server-configuration-validation.html)
