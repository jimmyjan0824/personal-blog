---
title: MySQL 高可用實作 07：Percona Server 8.0 升級 8.4 LTS，先升從庫再主從切換（Rocky Linux 9）
date: 2026-11-20 20:00:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, mysql84, percona, rocky-linux, replication, gtid, upgrade, switchover, lts, dba]
description: 8.0 已在 2026-04 結束支援。在 Percona Server 8.0.46 一主二從（GTID + 半同步 + WRITESET）上，先把從庫就地升級到 8.4.11 LTS，再做主從切換、升級舊主庫，最後把帳號換成 caching_sha2_password。全程應用程式持續寫入，實測寫入中斷 0.70 秒、沒有遺失資料。
media_subpath: /assets/img/posts/mysql-ha-lab-07
---

MySQL 8.0 的延伸支援在 **2026 年 4 月**結束，8.0.46 是最後一版。下一個落腳點是 **8.4 LTS**（Premier Support 到 2029-04）。這篇延續 [Lab 06]({% post_url 2026-10-25-mysql-ha-lab-06-upgrade-57-to-80 %}) 的做法，把**本系列 Lab 01~03 建好的 8.0 環境**（GTID、半同步、WRITESET 平行複製）滾動升級到 8.4：

1. 從庫一台一台就地升級到 8.4（舊版主庫 → 新版從庫是官方支援的方向）。
2. 計畫內切換，讓 8.4 的從庫當主庫。
3. 舊主庫升級到 8.4 再接回。
4. 把還在用 `mysql_native_password` 的帳號換掉。

8.0 → 8.4 比 5.7 → 8.0 平順很多（不用換套件名稱、`/etc/my.cnf` 會保留），但有**三個會讓服務中斷的坑**：設定檔有 8.4 已移除的參數、`mysql_native_password` 預設停用、`SHOW SLAVE STATUS` 等舊語法被移除。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - 起點是 `ps80` 套件庫的最後一版 **Percona Server 8.0.46-37.1**，目標是 `ps-84-lts` 套件庫的 **8.4.11-12.1**；MySQL Shell 用 8.4 套件庫的 **8.4.10**。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd，用 `dnf` 從 `repo.percona.com` 安裝與升級（x86_64 Linux 主機，4 vCPU / 15 GB）。文中的圖是實測輸出的終端機截圖。
> - 驗證腳本與完整輸出在 repo 的 [`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab)（`07-*.sh`、`results/07-*.log`）。
> - **沒有實測的部分**：`firewalld`、SELinux（容器內沒有）。
{: .prompt-warning }

## 架構與順序

| 主機 | IP | 升級前 | 升級後 |
| :--- | :--- | :--- | :--- |
| `db1` | 192.168.58.11 | 8.0 Source（主庫） | 8.4 Replica |
| `db2` | 192.168.58.12 | 8.0 Replica | **8.4 Source（新主庫）** |
| `db3` | 192.168.58.13 | 8.0 Replica | 8.4 Replica |
| `app` | 192.168.58.30 | 每 0.2 秒寫一筆到主庫 | 同左 |

| 階段 | db1 | db2 | db3 | 複製方向 |
| :--- | :--- | :--- | :--- | :--- |
| 起始 | 8.0 主 | 8.0 從 | 8.0 從 | db1 → db2、db3 |
| 升級 db2（步驟 1~6） | 8.0 主 | **8.4 從** | 8.0 從 | db1 → db2、db3 |
| 升級 db3（步驟 7） | 8.0 主 | 8.4 從 | **8.4 從** | db1 → db2、db3 |
| 切換（步驟 8） | 8.0 唯讀 | **8.4 主** | 8.4 從 | db2 → db3 |
| 升級 db1、接回（步驟 9） | **8.4 從** | 8.4 主 | 8.4 從 | db2 → db1、db3 |
| 換認證外掛（步驟 10） | 8.4 從 | 8.4 主 | 8.4 從 | 同上 |

> 8.0 → 8.4 是「**LTS 跨 LTS**」，官方支援直接就地升級，也支援 8.0 主庫 → 8.4 從庫的複製；反方向（8.4 主庫 → 8.0 從庫）不支援。所以順序和 Lab 06 一樣：先升從庫、再切換、舊主庫**先升級再接回**。
{: .prompt-info }

## 步驟 0：8.0 起始環境

三台是 8.0.46 的 GTID 一主二從，設定就是本系列前幾篇的組合：[Lab 01]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的 `00-server.cnf` 與 GTID、[Lab 02]({% post_url 2026-10-24-mysql-ha-lab-02-semi-sync %}) 的半同步、[Lab 03]({% post_url 2026-10-24-mysql-ha-lab-03-parallel-replication %}) 的 WRITESET，再加上 8.0 環境非常常見的一行 `default_authentication_plugin`：

```ini
# /etc/my.cnf.d/replication.cnf（8.0 時期）
[mysqld]
bind_address             = 0.0.0.0
log_bin                  = mysql-bin
binlog_format            = ROW
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON
binlog_expire_logs_seconds = 604800
sync_binlog              = 1
relay_log                = relay-bin
relay_log_recovery       = ON
replica_parallel_workers = 8
replica_preserve_commit_order = ON
binlog_transaction_dependency_tracking = WRITESET      # Lab 03：8.0 要用 WRITESET 只能這樣設

# Lab 02：半同步（新名稱外掛）
plugin_load_add = semisync_source.so
plugin_load_add = semisync_replica.so
loose_rpl_semi_sync_source_enabled = ON
loose_rpl_semi_sync_source_timeout = 1000
loose_rpl_semi_sync_replica_enabled = ON

# 8.0 環境常見：為了舊版驅動（PHP 7.x、舊 JDBC）把新帳號預設改回 mysql_native_password
default_authentication_plugin = mysql_native_password
```

因為有 `default_authentication_plugin = mysql_native_password`，**連初始化時建立的 `root@localhost` 都是 `mysql_native_password`**，`repl`、`app` 也是：

```console
[db1] mysql> SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;
+-------------------+--------------+-----------------------+
| user              | host         | plugin                |
+-------------------+--------------+-----------------------+
| app               | 192.168.58.% | mysql_native_password |
| monitor           | 192.168.58.% | caching_sha2_password |
| percona.telemetry | localhost    | caching_sha2_password |
| repl              | 192.168.58.% | mysql_native_password |
| root              | localhost    | mysql_native_password |
+-------------------+--------------+-----------------------+
```

> `percona.telemetry` 是 Percona 8.0.3x 起內建的遙測帳號，搭配一起安裝的 `percona-telemetry-agent` 服務。不想送遙測資料可以 `systemctl disable --now percona-telemetry-agent`，詳見 Percona 文件的 Telemetry 一節。
{: .prompt-tip }

> 從庫接上主庫前先執行 `RESET MASTER`（8.4 改名為 `RESET BINARY LOGS AND GTIDS`）。初始化後改 root 密碼那一下，在從庫自己的 GTID 下產生了一筆交易，不清掉的話這筆就是 **errant transaction**，日後這台當主庫時，其他從庫會因為找不到這筆交易而複製中斷。
{: .prompt-warning }

## 步驟 1：升級前檢查（MySQL Shell 8.4 Upgrade Checker）

在第一台要升級的從庫 db2 切到 8.4 的套件庫，先只升級 MySQL Shell：

```bash
sudo percona-release setup -y ps-84-lts      # 會停用 ps80 套件庫，已安裝的 8.0 不受影響
sudo dnf -q --showduplicates list percona-server-server | tail -3
sudo dnf upgrade -y percona-mysql-shell
```

```console
percona-server-server.x86_64      8.4.10-10.1.el9       ps-84-lts-release-x86_64
percona-server-server.x86_64      8.4.11-11.1.el9       ps-84-lts-release-x86_64
percona-server-server.x86_64      8.4.11-12.1.el9       ps-84-lts-release-x86_64

mysqlsh   Ver 8.4.10 for Linux on x86_64 - for MySQL 8.4.11-11 (Source distribution)
```

這次記得加 `--config-path`（Lab 06 沒加，設定檔相關的檢查全被跳過）。第一個小坑：`--target-version` 寫 `8.4.11` 會被拒絕，因為 Shell 本身是 8.4.10，比目標還舊：

![MySQL Shell 8.4.10 對 8.4.11 顯示 not supported，建議 targetVersion=8.4](01-checker-target.png)
_`--target-version=8.4.11` 時的輸出：Shell 只認得到自己的版本，要寫成 `8.4`_

```bash
mysqlsh --no-wizard -uroot -p --socket=/var/lib/mysql/mysql.sock \
  -- util check-for-server-upgrade --target-version=8.4 --config-path=/etc/my.cnf
```

結果 **Errors: 2、Warnings: 18、Notices: 1**。兩個 Error 都是設定檔裡 8.4 已經移除的參數：

![Removed system variables：binlog_transaction_dependency_tracking](02-checker-errors.png)

![authMethodUsage 列出三個 mysql_native_password 帳號；deprecatedDefaultAuth 指出 default_authentication_plugin](03-checker-auth.png)

整理如下：

| 檢查項目 | 等級 | 內容 | 處理 |
| :--- | :--- | :--- | :--- |
| `removedSysVars` | Error | `binlog_transaction_dependency_tracking` 8.4 移除 | 從設定檔拿掉（8.4 固定用 WRITESET） |
| `deprecatedDefaultAuth` | Error | `default_authentication_plugin` 8.4 移除 | 從設定檔拿掉；要指定預設外掛改用 `authentication_policy` |
| `authMethodUsage` | Warning | `app`、`repl`、**`root@localhost`** 用 `mysql_native_password` | 8.4 預設停用此外掛，見步驟 4 |
| `sysVarsNewDefaults` | Warning | 15 個變數的預設值改變 | 見步驟 6 |
| `checkTableCommand` | （失敗） | `--super-read-only` 擋住了 `CHECK TABLE ... FOR UPGRADE` | 從庫上跑會這樣，要完整檢查就到主庫或暫時關掉 `super_read_only` 跑 |
| `invalidPrivileges` | Notice | `root` 的 `SET_USER_ID` 權限會被移除 | 沒用到就不用處理 |

> Lab 03 文中提過：`binlog_transaction_dependency_tracking` 在 8.0.35 標為棄用、8.4 移除。8.4 的 WRITESET 是內建行為，拿掉這行不會讓平行複製變差。
{: .prompt-info }

## 步驟 2：停複製、完整關機、備份（db2）

先把現在的變數值存起來，升級後可以比對預設值的變化（步驟 6）：

```bash
mysql -N -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables" > /root/vars-80.txt
```

```sql
STOP REPLICA;
SET GLOBAL innodb_fast_shutdown = 0;   -- 完整 purge 與 change buffer merge 後再關機
```

```console
[db2]# time systemctl stop mysqld; cp -a /var/lib/mysql /var/lib/mysql-8.0-backup && cp -a /etc/my.cnf.d /root/my.cnf.d-8.0 && du -sh /var/lib/mysql-8.0-backup
real	0m1.666s
337M	/var/lib/mysql-8.0-backup
```

> 8.4 第一次啟動就會把資料字典從 `80023` 升到 `80300`，**之後不能再用 8.0 開啟**。8.4 只支援同一個 LTS 系列內（8.4.x 之間）的就地降級，跨系列一律要靠升級前的備份。
{: .prompt-danger }

## 步驟 3：升級套件（db2）

8.0 和 8.4 的套件名稱相同（`percona-server-server` 等），直接 `dnf upgrade`。和 5.7 → 8.0 不同，不用先移除舊套件：

```console
[db2]# dnf upgrade -y 'percona-server-*' percona-mysql-router percona-icu-data-files
 percona-icu-data-files x86_64 8.4.11-12.1.el9   ps-84-lts-release-x86_64 2.3 M
 percona-mysql-router   x86_64 8.4.11-12.1.el9   ps-84-lts-release-x86_64 5.0 M
 percona-server-client  x86_64 8.4.11-12.1.el9   ps-84-lts-release-x86_64 3.2 M
 percona-server-server  x86_64 8.4.11-12.1.el9   ps-84-lts-release-x86_64  71 M
 percona-server-shared  x86_64 8.4.11-12.1.el9   ps-84-lts-release-x86_64 1.5 M
Complete!

[db2]# mysqld --version
/usr/sbin/mysqld  Ver 8.4.11-12 for Linux on x86_64 (Percona Server (GPL), Release 12, Revision 76aa4263)

[db2]# tail -1 /etc/my.cnf; systemctl is-enabled mysqld
!includedir /etc/my.cnf.d
enabled
```

`/etc/my.cnf`（含我們補的 `!includedir`）和 `systemctl enable` 都保留了，**Lab 06 的「my.cnf.d 失效」坑這次不會發生**。

> 只寫 `dnf upgrade percona-server-server percona-server-client` 的話，`percona-server-shared`（libperconaserverclient）和 `percona-icu-data-files` 會留在 8.0.46，用 `'percona-server-*'` 一起升比較乾淨。
{: .prompt-tip }

## 步驟 4：修正設定檔（啟動前！）

### 4-1. 移除 8.4 不認得的參數

和 Lab 06 一樣，`--validate-config` 一次只報第一個錯誤，要改一個、跑一次：

![validate-config 依序報出 binlog_transaction_dependency_tracking、default_authentication_plugin，拿掉兩行後 exit=0](04-validate-config.png)

### 4-2. 坑：拿掉 `default_authentication_plugin` 就啟動，root 登不進去

`--validate-config` 已經 `exit=0`，看起來可以啟動了。實際啟動也成功，但是：

![ERROR 1524 Plugin 'mysql_native_password' is not loaded](05-native-login-fail.png)

**8.4 的 `mysql_native_password` 外掛預設是停用的**，所有用這個外掛的帳號都會被拒絕，包含 `root@localhost`。本例的 `root` 是在 `default_authentication_plugin = mysql_native_password` 下初始化的，所以 DBA 自己也被鎖在外面；如果是主庫，`app` 帳號的所有連線都會失敗。

複製這時倒是沒事（db2 是用 `repl` 連到 **8.0** 的 db1 認證，不是在 8.4 上認證），所以光看複製狀態不會發現。

解法是先在設定檔打開它，**等所有帳號換成 `caching_sha2_password` 之後再拿掉**（步驟 10）：

```ini
# /etc/my.cnf.d/replication.cnf（升級到 8.4 後的版本）
# 和 8.0 版的差異：
#   - 拿掉 binlog_transaction_dependency_tracking（8.4 移除，固定用 WRITESET）
#   - 拿掉 default_authentication_plugin（8.4 移除，改用 authentication_policy）
#   - 暫時打開 mysql_native_password（8.4 預設停用），所有帳號改成 caching_sha2_password 後再拿掉
[mysqld]
bind_address             = 0.0.0.0
log_bin                  = mysql-bin
binlog_format            = ROW
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON
binlog_expire_logs_seconds = 604800
sync_binlog              = 1
relay_log                = relay-bin
relay_log_recovery       = ON
replica_parallel_workers = 8
replica_preserve_commit_order = ON

plugin_load_add = semisync_source.so
plugin_load_add = semisync_replica.so
loose_rpl_semi_sync_source_enabled = ON
loose_rpl_semi_sync_source_timeout = 1000
loose_rpl_semi_sync_replica_enabled = ON

mysql_native_password    = ON
```

> **一定要在第一台升級前就決定這件事**。最安全的順序是：還在 8.0 時就把帳號換成 `caching_sha2_password`（8.0 完全支援），升級時就不需要 `mysql_native_password = ON`。本篇刻意照「大多數人實際會遇到的順序」走：先升級、暫時打開、再換帳號。要注意 **MySQL 9.0 起這個外掛整個移除**，下一篇升 9.7 前一定要換完。
{: .prompt-danger }

## 步驟 5：啟動 8.4（db2）

```console
[db2]# mysqld --validate-config --user=mysql; echo "exit=$?"
[Warning] [MY-011070] [Server] 'binlog_format' is deprecated and will be removed in a future release.
exit=0

[db2]# time systemctl start mysqld; systemctl is-active mysqld
real	0m5.098s
active
```

![錯誤日誌：Data dictionary upgrading 80023 → 80300、Server upgrade from 80046 to 80411 completed](06-first-start.png)

資料字典與系統表的升級約 3 秒（本例資料量很小）。半同步外掛、`replica_parallel_workers = 8` 都還在，複製自動恢復並追上：

```console
[db2] mysql> SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME IN ('mysql_native_password','rpl_semi_sync_source','rpl_semi_sync_replica');
+-----------------------+---------------+
| PLUGIN_NAME           | PLUGIN_STATUS |
+-----------------------+---------------+
| mysql_native_password | ACTIVE        |
| rpl_semi_sync_source  | ACTIVE        |
| rpl_semi_sync_replica | ACTIVE        |
+-----------------------+---------------+

[db2] mysql> SHOW REPLICA STATUS\G   （節錄）
                  Source_Host: db1
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: 0
                Auto_Position: 1
```

> 8.0 → 8.4 不需要像 5.7 那樣改用新的半同步外掛名稱。如果你的環境還在用舊名稱 `semisync_master.so` / `semisync_slave.so`（變數 `rpl_semi_sync_master_*`），**8.4 已經移除舊外掛**，要先在 8.0 上換成新名稱（作法見 Lab 02）。
{: .prompt-warning }

### 坑：監控腳本用的舊語法被移除

8.0 時只是棄用警告，8.4 直接語法錯誤。Zabbix / Prometheus exporter 的自訂查詢、備份腳本裡用 `SHOW MASTER STATUS` 取 binlog 位置的，**升級前都要先改**：

![SHOW SLAVE STATUS、SHOW MASTER STATUS 在 8.4 報 ERROR 1064；改用 SHOW BINARY LOG STATUS](07-removed-syntax.png)

| 8.0 以前 | 8.4 |
| :--- | :--- |
| `SHOW SLAVE STATUS` | `SHOW REPLICA STATUS` |
| `SHOW MASTER STATUS` | `SHOW BINARY LOG STATUS` |
| `SHOW SLAVE HOSTS` | `SHOW REPLICAS` |
| `START / STOP SLAVE` | `START / STOP REPLICA` |
| `CHANGE MASTER TO MASTER_HOST=...` | `CHANGE REPLICATION SOURCE TO SOURCE_HOST=...` |
| `RESET MASTER` | `RESET BINARY LOGS AND GTIDS` |
| `RESET SLAVE` | `RESET REPLICA` |

## 步驟 6：8.4 改了哪些預設值

設定檔沒寫的參數會直接套用 8.4 的新預設。用步驟 2 存的變數比對同一台升級前後：

![innodb_adaptive_hash_index ON→OFF、innodb_change_buffering all→none、innodb_log_buffer_size 16M→64M 等](08-new-defaults.png)

| 變數 | 8.0.46 | 8.4.11 | 影響 |
| :--- | :--- | :--- | :--- |
| `innodb_adaptive_hash_index` | ON | **OFF** | 大量等值查詢、熱點資料的讀取可能變慢；壓測後再決定是否打開 |
| `innodb_change_buffering` | all | **none** | 次要索引多、隨機寫入多又是機械硬碟時影響較大；SSD 通常無感 |
| `innodb_log_buffer_size` | 16M | 64M | 本系列 Lab 01 早就設 64M |
| `innodb_purge_threads` | 4 | 1 | vCPU ≤ 16 時預設 1；大量刪除 / 更新時 history list 可能變長 |
| `innodb_doublewrite_pages` | 4 | 128 | — |
| `innodb_numa_interleave` | OFF | ON | — |
| `group_replication_consistency` | EVENTUAL | BEFORE_ON_PRIMARY_FAILOVER | 用 Group Replication / InnoDB Cluster 時，failover 後新主庫會先套用完積壓的交易才接受讀取 |

> Upgrade Checker 列了 15 個，這裡只出現 7 個，因為其他幾個（`innodb_buffer_pool_instances`、`innodb_page_cleaners`、`innodb_read_io_threads` 等）的新預設是依 vCPU 數或 buffer pool 大小計算，在這台 4 vCPU、buffer pool 256M 的實驗機上剛好算出相同的值。實體主機請自己跑一次比對。
{: .prompt-info }

這些預設值的改變**是官方調整過的建議值**，沒有必要全部改回 8.0 的值。實務上建議：先維持 8.4 預設上線、觀察慢查詢與 `SHOW ENGINE INNODB STATUS`，有退化再針對性調整（例如把 `innodb_adaptive_hash_index` 打開）。

## 步驟 7：升級第二台從庫（db3）

照步驟 2~5（備份 → `dnf upgrade` → 換 8.4 設定檔 → 啟動）升級 db3。此時是 **8.0 主庫 → 兩台 8.4 從庫**，三台資料一致，app 在整個從庫升級期間 **0 筆失敗**：

```console
| db1  | 8.0.46-37 |     5401 | 11430722735483 |
| db2  | 8.4.11-12 |     5401 | 11430722735483 |
| db3  | 8.4.11-12 |     5401 | 11430722735483 |

[app]# echo "OK=$(grep -c " OK " /tmp/writer.log) ERR=$(grep -c " ERR " /tmp/writer.log)"
OK=402 ERR=0
```

## 步驟 8：計畫內主從切換（db1 → db2）

流程和 [Lab 06 步驟 7]({% post_url 2026-10-25-mysql-ha-lab-06-upgrade-57-to-80 %}) 相同：

```sql
-- 1. db1：停止寫入
SET GLOBAL super_read_only = ON;
-- 2. db2、db3：等套用完 db1 的所有交易（回傳 0）
SELECT WAIT_FOR_EXECUTED_GTID_SET('<db1 的 gtid_executed>', 30);
-- 3. db2：升為主庫
STOP REPLICA; RESET REPLICA ALL;
SET PERSIST super_read_only = OFF; SET PERSIST read_only = OFF;
-- 4. 應用程式改寫 db2（VIP / DNS / Proxy）
-- 5. db3：改接 db2
STOP REPLICA;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='...', SOURCE_AUTO_POSITION=1;
START REPLICA;
```

![app 寫入紀錄：3 筆 ERROR 1290，寫入中斷 0.698 秒](09-switchover-outage.png)

**寫入中斷 0.70 秒、失敗 3 筆**（都是被 `super_read_only` 擋下、應用程式有收到錯誤的寫入）。切換後 db2 的半同步也正常運作：

```console
| Rpl_semi_sync_source_clients | 1     |
| Rpl_semi_sync_source_status  | ON    |
```

> 這時 app 帳號還是 `mysql_native_password`，能寫入 db2 是因為步驟 4-2 打開了 `mysql_native_password = ON`。**如果 db2 是照 4-1 那樣啟動的，切換的那一刻所有應用程式連線都會失敗**，這是 8.4 升級最危險的地方。
{: .prompt-danger }

## 步驟 9：舊主庫 db1 先升級再接回

db1 還是 8.0，**不能**直接接到 8.4 的 db2（新版 → 舊版不支援）。先在設定檔加 `super_read_only = ON`，照步驟 2~5 升級，再接回：

```console
[db1]# time systemctl stop mysqld
real	0m11.305s          # 主庫累積了較多 undo / change buffer，完整關機比從庫久

[db1]# time systemctl start mysqld; grep -E "Server upgrade|\[ERROR\]" /var/log/mysqld.log | tail -3
real	0m5.040s
[System] [MY-013381] [Server] Server upgrade from '80046' to '80411' started.
[System] [MY-013381] [Server] Server upgrade from '80046' to '80411' completed.
```

```sql
-- db1
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='...', SOURCE_AUTO_POSITION=1;
START REPLICA;
```

```console
[db1] mysql> SHOW REPLICA STATUS\G   （節錄）
                  Source_Host: db2
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: 0
            Executed_Gtid_Set: e3936cb3-e4e8-11f1-a3be-02dcceecbec0:1-416,
e6ef855f-e4e8-11f1-85e2-1e44fd980790:1-240

[db2] mysql> SHOW REPLICAS;
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         1 | db1  | 3306 |         2 | e3936cb3-e4e8-11f1-a3be-02dcceecbec0 |
|         3 | db3  | 3306 |         2 | ea78dfe4-e4e8-11f1-9097-ae75a9ec8c8d |
+-----------+------+------+-----------+--------------------------------------+
| Rpl_semi_sync_source_clients | 2     |
```

## 步驟 10：帳號換成 caching_sha2_password，關掉 mysql_native_password

在主庫 db2 執行，會複製到 db1、db3（密碼維持不變，只換外掛）：

```sql
ALTER USER 'app'@'192.168.58.%'  IDENTIFIED WITH caching_sha2_password BY '...';
ALTER USER 'repl'@'192.168.58.%' IDENTIFIED WITH caching_sha2_password BY '...';
ALTER USER 'root'@'localhost'    IDENTIFIED WITH caching_sha2_password BY '...';
```

app 完全沒有感覺（mysql 8.0 用戶端預設 `ssl-mode=PREFERRED`，走 TLS 1.3 傳送密碼）：

```console
[app]# tail -2 /tmp/writer.log; mysql -hdb2 -uapp -p... -e "SHOW SESSION STATUS LIKE 'Ssl_version'"
13:50:25.565 OK db2 db2
13:50:25.797 OK db2 db2
Ssl_version	TLSv1.3
```

### 坑：repl 換外掛後，從庫「下一次重連」才會失敗

`ALTER USER repl` 之後複製還是正常的，因為現有連線不受影響。等到主庫重啟（這裡用 `FLUSH PRIVILEGES` 清掉 caching_sha2 的認證快取來模擬）、從庫重連時：

![db3：Replica_IO_Running: Connecting，Authentication requires secure connection](10-repl-sha2-fail.png)

`caching_sha2_password` 第一次認證（快取裡沒有這個帳號時）必須走 TLS，或用 RSA 公鑰加密密碼。複製連線預設 `SOURCE_SSL = 0`，兩個條件都不符合。兩台從庫都加上 `GET_SOURCE_PUBLIC_KEY = 1`：

```sql
STOP REPLICA;
CHANGE REPLICATION SOURCE TO GET_SOURCE_PUBLIC_KEY = 1;   -- 或 SOURCE_SSL = 1（更建議，複製流量也一起加密）
START REPLICA;
```

```console
[db3] mysql> SHOW REPLICA STATUS\G   （節錄）
                  Source_Host: db2
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: 0
```

> 這個坑最麻煩的地方是**延遲發作**：改完帳號當下一切正常，可能幾週後主庫維護重啟，所有從庫同時斷線。改 `repl` 的外掛時，**同一個維護窗口就要把所有從庫的 `GET_SOURCE_PUBLIC_KEY` 或 `SOURCE_SSL` 設好**，並用 `STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;` 實際重連驗證。
{: .prompt-danger }

最後把 `mysql_native_password = ON` 從三台的設定檔拿掉。從庫逐台重啟確認：

```console
[db1]# sed -i '/^mysql_native_password/d' /etc/my.cnf.d/replication.cnf; systemctl restart mysqld
[db1] mysql> SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME = 'mysql_native_password';
mysql_native_password	DISABLED
```

主庫 db2 只改設定檔，等下次維護重啟時生效。

## 步驟 11：最終驗證

![OK=723 ERR=3；db1 406 + db2 317 = 723；三台 5723 筆、CRC 相同](11-final.png)

- 三台都是 **8.4.11-12**，db2 是主庫、db1 / db3 `super_read_only`，半同步 2 個 client。
- app 回報成功 **723** 筆 = 資料庫裡 `w-%` 的筆數（db1 時期 406 + db2 時期 317），**沒有「回報成功卻不見」的資料**；失敗的 3 筆都是切換時被 `super_read_only` 擋下的。
- 三台筆數（5723）與 CRC 完全相同。

## 升級完成後的待辦

- **刪除 8.0 備份**：每台的 `/var/lib/mysql-8.0-backup`（本例約 340 MB），確定不會退回再刪。
- **`binlog_format` 棄用警告**：8.4 還能用，但未來會移除；ROW 是預設值，可以從設定檔拿掉。
- **複製加密**：步驟 10 用的是 `GET_SOURCE_PUBLIC_KEY = 1`，正式環境建議改成 `SOURCE_SSL = 1`（必要時搭配 `SOURCE_SSL_VERIFY_SERVER_CERT`）。
- **監控與備份腳本**：`SHOW SLAVE STATUS` / `SHOW MASTER STATUS` 全部改掉，XtraBackup 要換成 8.4 版（`percona-xtrabackup-84`），8.0 版的 XtraBackup 無法備份 8.4。
- **新預設值**：觀察一週，特別是 `innodb_adaptive_hash_index`、`innodb_change_buffering` 有沒有造成退化。

## 實測踩到的坑

| 坑 | 現象 | 解法 |
| :--- | :--- | :--- |
| `binlog_transaction_dependency_tracking` | 8.4 起不來：`unknown variable` | 從設定檔拿掉 |
| `default_authentication_plugin` | 8.4 起不來：`unknown variable` | 拿掉；要指定請用 `authentication_policy` |
| `mysql_native_password` 預設停用 | **啟動成功但登不進去**：`ERROR 1524 Plugin 'mysql_native_password' is not loaded`，連 root 都是 | 先設 `mysql_native_password = ON`，帳號換完再拿掉 |
| 舊語法移除 | `SHOW SLAVE STATUS` / `SHOW MASTER STATUS` → `ERROR 1064` | 監控、備份腳本先改成新語法 |
| repl 換成 `caching_sha2_password` | 下次重連才失敗：`Authentication requires secure connection` | 從庫設 `GET_SOURCE_PUBLIC_KEY = 1` 或 `SOURCE_SSL = 1` |
| Upgrade Checker `--target-version=8.4.11` | `is not supported`（Shell 8.4.10 比目標新） | 寫 `--target-version=8.4` |
| Upgrade Checker 在從庫跑 | `checkTableCommand` 被 `super_read_only` 擋下 | 在主庫跑，或暫時關 `super_read_only` |
| 從庫初始化後的本機 GTID | 日後當主庫時其他從庫找不到交易 | 接主庫前 `RESET MASTER` / `RESET BINARY LOGS AND GTIDS` |

## 驗證方式與結果

用 [`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的腳本從全新容器完整跑過兩次，數字取自第二次：

```bash
./00-build.sh                   # mysqllab-ps80（8.0.46-37.1）與 mysqllab-ps84
./07-10-setup-80.sh             # 8.0 一主二從（GTID + 半同步 + WRITESET），app 開始寫入 db1
./07-20-upgrade-replicas.sh     # db2、db3 就地升級到 8.4.11（升級檢查、validate-config、native password 坑）
./07-30-switchover.sh           # db2 升為主庫、db3 改接、量測寫入中斷
./07-40-upgrade-old-primary.sh  # db1 升級後接回；帳號換 caching_sha2_password；關掉 mysql_native_password
```

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 1 升級檢查 | `util check-for-server-upgrade --config-path` | 找出設定檔與帳號的問題 | ✅ 2 錯誤、18 警告、1 提示 |
| 4 設定檔 | `mysqld --validate-config` | `exit=0` | ✅（8.0 原設定 `exit=1`，兩個 unknown variable） |
| 4-2 native password | 不開 `mysql_native_password` 啟動 | 重現登入失敗 | ✅ `ERROR 1524` |
| 5 啟動 8.4 | 錯誤日誌、`SHOW REPLICA STATUS` | `Server upgrade ... completed`、IO / SQL `Yes` | ✅ 三台都是，啟動約 5 秒 |
| 7 混合版本 | 8.0 主庫寫入，比對三台筆數與 CRC | 一致；app 0 失敗 | ✅ OK=402、ERR=0 |
| 8 切換 | `WAIT_FOR_EXECUTED_GTID_SET`、app 紀錄 | 回傳 0、寫入恢復 | ✅ 中斷 0.70 秒（第一次 0.69 秒） |
| 10 換外掛 | `FLUSH PRIVILEGES` 後從庫重連 | 重現失敗、加 `GET_SOURCE_PUBLIC_KEY` 後恢復 | ✅ |
| 11 最終 | app 成功筆數 vs 資料庫、三台 CRC | 723 = 406 + 317；CRC 相同 | ✅ 無資料遺失 |

| 動作 | 時間 |
| :--- | :--- |
| 從庫 `systemctl stop`（`innodb_fast_shutdown = 0`） | 1.2~1.7 秒 |
| 主庫 `systemctl stop`（`innodb_fast_shutdown = 0`） | 11.3 秒 |
| 8.4 第一次啟動（含資料字典升級約 3 秒） | 5.0~6.2 秒 |
| 主從切換寫入中斷 | 0.70 秒 |

## 小結

- 8.0 已 EOL，**8.4 LTS 是最直接的下一站**；流程和 5.7 → 8.0 一樣是「先升從庫、再切換、最後升舊主庫」。
- Upgrade Checker 一定要加 `--config-path`，啟動前用 `mysqld --validate-config` 跑到 `exit=0`。
- **最大的坑是 `mysql_native_password` 預設停用**：啟動成功、複製正常，但帳號全部登不進去。最好在 8.0 時就把帳號換成 `caching_sha2_password`。
- 換 `repl` 的外掛時，從庫要同時設 `GET_SOURCE_PUBLIC_KEY = 1` 或 `SOURCE_SSL = 1`，否則下次重連才爆。
- 監控與備份腳本裡的 `SHOW SLAVE STATUS` / `SHOW MASTER STATUS` 在 8.4 是語法錯誤。

下一篇：[8.4 升級 9.7 LTS 與新的日曆版號]({% post_url 2026-11-20-mysql-ha-lab-08-upgrade-84-to-97 %})。

### 參考資料

- [MySQL 8.4 Reference Manual：Upgrading MySQL](https://dev.mysql.com/doc/refman/8.4/en/upgrading.html)
- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
- [MySQL 8.4 Reference Manual：Native Pluggable Authentication](https://dev.mysql.com/doc/refman/8.4/en/native-pluggable-authentication.html)
- [MySQL 8.4 Reference Manual：Caching SHA-2 Pluggable Authentication](https://dev.mysql.com/doc/refman/8.4/en/caching-sha2-pluggable-authentication.html)
- [MySQL Shell 8.4：Upgrade Checker Utility](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-utilities-upgrade.html)
- [Percona Server for MySQL 8.4：Upgrade from 8.0 to 8.4](https://docs.percona.com/percona-server/8.4/upgrade.html)
