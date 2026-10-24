---
title: MySQL 高可用實作 01：GTID 主從複製（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:10:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, replication, gtid, dba]
description: 以 Percona Server for MySQL 8.0.46 在 Rocky Linux 9 上從安裝到驗證，一步步建立 GTID 主從複製，包含用 mysqldump 建立從庫、設定唯讀與計畫內切換，所有輸出皆為實測結果。
---

[高可用與災難復原]({% post_url 2026-10-24-mysql-ops-03-ha-dr %}) 一篇整理了各種 HA 架構的觀念，這個系列則是動手做：每一篇都從安裝開始，一路做到驗證成功。第一篇是所有架構的基礎，**GTID 主從複製**。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.56.11 | Source（主庫） |
| `db2` | 192.168.56.12 | Replica（從庫） |

兩台都是 Rocky Linux 9，安裝 Percona Server for MySQL 8.0.46-37.1。

## 步驟 0：主機準備（兩台都做）

讓每台主機都能用主機名互相解析。複製的設定與 `SHOW REPLICAS` 輸出都會用到主機名。

```bash
cat >> /etc/hosts <<'EOF'
192.168.56.11 db1
192.168.56.12 db2
EOF
```

開防火牆（**未實測**，容器內沒有 firewalld）：

```bash
sudo firewall-cmd --permanent --add-service=mysql     # 3306/tcp
sudo firewall-cmd --reload
```

SELinux 維持 `Enforcing` 即可，Percona 的 RPM 使用預設的 `/var/lib/mysql` 與 3306 埠，不需要額外設定。

## 步驟 1：安裝 Percona Server（兩台都做）

```bash
# 安裝 percona-release 工具並啟用 ps80 套件庫
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release setup ps80

# 安裝最新版，或指定版本
sudo dnf install -y percona-server-server
# sudo dnf install -y percona-server-server-8.0.46-37.1.el9
```

實測輸出（Rocky Linux 9 容器，aarch64；x86_64 主機上架構字樣會是 `x86_64`）：

```console
# dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
Installed:
  percona-release-1.0-34.noarch

# percona-release setup ps80
* Disabling all Percona Repositories
* Enabling the Percona Server for MySQL 8.0 repository
<*> All done!

# dnf install -y percona-server-server
Installing:
 percona-server-server     aarch64  8.0.46-37.1.el9          ps-80-release-aarch64       58 M
Install  81 Packages
Complete!

# rpm -qa | grep -E "^percona-server" | sort
percona-server-client-8.0.46-37.1.el9.aarch64
percona-server-server-8.0.46-37.1.el9.aarch64
percona-server-shared-8.0.46-37.1.el9.aarch64

# mysqld --version
/usr/sbin/mysqld  Ver 8.0.46-37 for Linux on aarch64 (Percona Server (GPL), Release 37, Revision 39e2b60e)
```

- 撰寫時 ps80 套件庫的最新版就是 8.0.46-37.1（`dnf --showduplicates list percona-server-server` 最後三版為 8.0.44、8.0.45、8.0.46）。
- Rocky 9 不像 Rocky 8 需要先 `dnf module disable mysql`，`percona-release setup ps80` 直接就能用。
- 安裝時會一併帶入 `percona-telemetry-agent`（Percona 的匿名使用統計），在沒有 SELinux 的環境會看到一行 `chcon: can't apply partial context to unlabeled file '/usr/local/percona/telemetry/ps'`，無害。

## 步驟 2：設定檔（兩台都做）

### 2-1. 先讓 mysqld 讀取 /etc/my.cnf.d

本系列把設定放在 `/etc/my.cnf.d/` 底下的獨立檔案，日後比較好維護。但**用 dnf 安裝的 Percona，`/etc/my.cnf` 沒有 `!includedir /etc/my.cnf.d` 這一行**，放進去的檔案根本不會被讀到。實測 RPM 裝好的原始檔內容：

```console
# grep -v "^#" /etc/my.cnf | grep -v "^$"
[mysqld]
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid

# rpm -qf /etc/my.cnf
percona-server-server-8.0.46-37.1.el9.aarch64
```

在**第一次啟動 mysqld 之前**補上（可重複執行，已有就不會再加）：

```bash
grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf
```

> 漏掉這一步不會有任何啟動錯誤，但設定全部沒生效。實測照做到後面才一連串出錯：
>
> - `@@server_id` 兩台都是 `1`、`@@gtid_mode` 是 `OFF`，binlog 檔名是預設的 `binlog.000001` 而不是 `mysql-bin`。
> - `mysqldump --set-gtid-purged=ON` → `Error: Server has GTIDs disabled.`
> - `CHANGE REPLICATION SOURCE TO` → `ERROR 1777 (HY000) at line 1: CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION = 1 cannot be executed because @@GLOBAL.GTID_MODE = OFF.`
> - `WAIT_FOR_EXECUTED_GTID_SET()` → `ERROR 3062 (HY000) at line 1: Cannot use WAIT_FOR_EXECUTED_GTID_SET when GTID_MODE = OFF.`
>
> Percona 官方 Docker 映像的 `/etc/my.cnf` 有這一行（是映像自己加的），所以只用官方映像測試的話不會發現。另一個做法是把設定直接寫進 `/etc/my.cnf` 的 `[mysqld]` 區段。
{: .prompt-danger }

### 2-2. 效能與運維基礎設定

這份設定和複製無關，但每台 MySQL 都應該有，本系列其他篇也共用同一份。基準是「**16 GB RAM、8 vCPU、SSD、專用資料庫主機**」。註解標「建議」的是調整過的值；標「預設」的是 8.0.46 的預設值（在全新安裝的 Percona 8.0.46 上用 `performance_schema.global_variables` 逐一查過），寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。

```ini
# /etc/my.cnf.d/00-server.cnf
# 效能與運維基礎設定（Percona Server for MySQL 8.0.46）
# 以「16 GB RAM、8 vCPU、SSD、專用資料庫主機」為基準。
# 標「建議」的是調整過的值；標「預設」的是 8.0.46 的預設值，寫出來是為了讓設定一目了然。
[mysqld]

# ==================== 基本 ====================
character_set_server      = utf8mb4             # 預設。8.0 起預設就是 utf8mb4
collation_server          = utf8mb4_0900_ai_ci  # 預設
lower_case_table_names    = 0                   # 預設。只能在初始化資料目錄前決定，之後不能改
log_timestamps            = SYSTEM              # 建議（預設 UTC）。錯誤日誌改用主機時區，對照系統日誌比較方便
skip_name_resolve         = ON                  # 建議（預設 OFF）。不做 DNS 反查，避免 DNS 慢或故障拖垮連線；帳號的 host 要用 IP 或網段
sql_mode                  = ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION  # 預設，維持嚴格模式

# ==================== 連線 ====================
max_connections           = 500                 # 建議（預設 151）。依應用程式連線池總數 ×1.2 估算，不是越大越好，每條連線都會吃記憶體
max_connect_errors        = 100000              # 建議（預設 100）。避免網路抖動或健康檢查讓某台應用主機被封鎖（Host is blocked）
thread_cache_size         = 64                  # 建議（預設自動算出 9）。重複使用執行緒，降低短連線建立成本
wait_timeout              = 28800               # 預設（8 小時）。要比連線池的 maxLifetime 長，否則應用會拿到已被斷開的連線
interactive_timeout       = 28800               # 預設
max_allowed_packet        = 64M                 # 預設。從庫要大於等於主庫，否則大交易複製會中斷
# thread_handling         = pool-of-threads     # Percona 執行緒池（預設 one-thread-per-connection）。連線數上千時再考慮開啟

# ==================== 表快取 ====================
table_open_cache          = 4000                # 預設。Opened_tables 持續增加時再調大
table_definition_cache    = 2000                # 預設
table_open_cache_instances = 16                 # 預設
# open_files_limit 受 systemd 的 LimitNOFILE（Percona RPM 設為 10000）限制，表很多時用 systemctl edit mysqld 調高

# ==================== 每條連線的緩衝區 ====================
# 每條連線（甚至每個查詢）各自配置，設太大在連線多時會吃光記憶體。維持預設，個別慢查詢用 SET SESSION 調整
sort_buffer_size          = 256K                # 預設
join_buffer_size          = 256K                # 預設
read_buffer_size          = 128K                # 預設
read_rnd_buffer_size      = 256K                # 預設

# ==================== 記憶體內暫存表 ====================
tmp_table_size            = 64M                 # 建議（預設 16M）。GROUP BY / ORDER BY 的暫存表超過此值會轉到磁碟
max_heap_table_size       = 64M                 # 建議（預設 16M）。和 tmp_table_size 設一樣
temptable_max_ram         = 1G                  # 預設。TempTable 引擎所有暫存表合計可用的記憶體上限

# ==================== InnoDB：記憶體 ====================
innodb_buffer_pool_size   = 10G                 # 建議（預設 128M）。專用主機設實體記憶體的 60~70%，這是影響效能最大的參數
innodb_buffer_pool_instances = 8                # 建議（預設：buffer pool < 1G 時為 1）。降低 buffer pool mutex 競爭
innodb_buffer_pool_dump_at_shutdown = ON        # 預設。關機時記錄熱資料頁
innodb_buffer_pool_load_at_startup  = ON        # 預設。開機後自動預熱，重啟後效能恢復較快
innodb_log_buffer_size    = 64M                 # 建議（預設 16M）。大交易或寫入量大時減少 redo 寫盤次數

# ==================== InnoDB：Redo log 與落盤 ====================
innodb_redo_log_capacity  = 2G                  # 建議（預設 100M）。太小會頻繁 checkpoint 造成寫入卡頓；約抓尖峰 1 小時的 redo 量
innodb_flush_log_at_trx_commit = 1              # 預設。每次 commit 都落盤，HA 環境必須是 1，否則主庫當機會遺失交易
innodb_flush_method       = O_DIRECT            # 建議（預設 fsync）。資料檔繞過 OS cache，避免和 buffer pool 重複快取
innodb_use_fdatasync      = ON                  # 建議（預設 OFF）。用 fdatasync 取代 fsync，少一次 metadata 寫入
innodb_doublewrite        = ON                  # 預設。防止寫到一半的資料頁損毀，不要關

# ==================== InnoDB：I/O ====================
innodb_io_capacity        = 2000                # 建議（預設 200）。背景刷髒頁的 IOPS，SSD 設 2000 左右，傳統硬碟維持 200
innodb_io_capacity_max    = 4000                # 建議（預設 2000）。刷髒頁落後時的上限，約為 io_capacity 的 2 倍
innodb_flush_neighbors    = 0                   # 預設。SSD 不需要順便刷相鄰頁
innodb_read_io_threads    = 4                   # 預設
innodb_write_io_threads   = 4                   # 預設
innodb_page_cleaners      = 4                   # 預設（實際值不超過 buffer_pool_instances）
innodb_purge_threads      = 4                   # 預設
innodb_lru_scan_depth     = 1024                # 預設

# ==================== InnoDB：交易、鎖與其他 ====================
innodb_file_per_table     = ON                  # 預設。每張表一個 .ibd，DROP / TRUNCATE 才能釋放空間
innodb_open_files         = 4000                # 預設
innodb_lock_wait_timeout  = 50                  # 預設（秒）。OLTP 可依應用調低，讓鎖等待早點失敗
innodb_deadlock_detect    = ON                  # 預設
innodb_print_all_deadlocks = ON                 # 建議（預設 OFF）。每次死結都寫進錯誤日誌，事後才查得到
innodb_autoinc_lock_mode  = 2                   # 預設。搭配 ROW 格式 binlog 最快
innodb_adaptive_hash_index = ON                 # 預設。若 SHOW ENGINE INNODB STATUS 看到大量 AHI 等待再關閉
innodb_stats_persistent   = ON                  # 預設
innodb_temp_data_file_path = ibtmp1:12M:autoextend:max:10G  # 建議（預設不設上限）。避免失控的查詢把全域暫存表空間撐爆磁碟
innodb_undo_log_truncate  = ON                  # 預設
innodb_max_undo_log_size  = 1G                  # 預設
transaction_isolation     = REPEATABLE-READ     # 預設

# ==================== 慢查詢日誌 ====================
slow_query_log            = ON                  # 建議（預設 OFF）
slow_query_log_file       = /var/lib/mysql/slow.log
long_query_time           = 1                   # 建議（預設 10 秒）。OLTP 可再降到 0.5
log_slow_extra            = ON                  # 建議（預設 OFF）。多記錄 Rows_examined、Bytes_sent 等欄位
log_queries_not_using_indexes = OFF             # 預設。開了日誌量會暴增，只在排查時暫時開

# ==================== 監控 ====================
performance_schema        = ON                  # 預設。監控、sys schema 都靠它，不要關
```

主機規格不同時，主要調整下面這幾個，其他維持上面的值即可：

| 實體記憶體 | `innodb_buffer_pool_size` | `innodb_buffer_pool_instances` | `innodb_redo_log_capacity` |
| :--- | :--- | :--- | :--- |
| 8 GB | 5G | 4 | 1G |
| 16 GB | 10G | 8 | 2G |
| 32 GB | 22G | 8 | 4G |
| 64 GB | 46G | 8 | 8G |
| 128 GB | 96G | 16 | 16G |

| 磁碟 | `innodb_io_capacity` | `innodb_io_capacity_max` |
| :--- | :--- | :--- |
| 傳統硬碟 | 200 | 2000 |
| SATA SSD | 2000 | 4000 |
| NVMe SSD | 5000~10000 | 20000 |

- `innodb_buffer_pool_size` 必須是 `innodb_buffer_pool_chunk_size`（預設 128M）× `innodb_buffer_pool_instances` 的整數倍，不是的話 MySQL 會自動往上進位。上表的值都符合。
- 主機上還跑其他服務（應用程式、監控 agent）時，buffer pool 要再扣掉它們用的記憶體。
- `max_connections` 依應用程式實際的連線池大小設定，和主機規格無關。

> `innodb_redo_log_capacity = 2G` 第一次啟動時就會在 `/var/lib/mysql/#innodb_redo/` 建出約 2 GB 的檔案（實測 `du -sh` 為 2.1G），磁碟空間要預留。
{: .prompt-info }

### 2-3. 複製設定

```ini
# /etc/my.cnf.d/gtid.cnf
# 複製相關設定
[mysqld]
server_id                = 1          # 每台不同：db1=1、db2=2
report_host              = db1        # 每台填自己的主機名
bind_address             = 0.0.0.0

# ---- Binlog 與 GTID ----
log_bin                  = mysql-bin
binlog_format            = ROW        # 預設。8.0.34 起此參數標為棄用（見下方說明）
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON         # 預設。從庫也寫 binlog，切換成主庫後其他從庫才接得上
binlog_expire_logs_seconds = 604800   # 建議（預設 30 天）。保留 7 天，至少要涵蓋兩次完整備份的間隔
sync_binlog              = 1          # 預設。每次 commit 都把 binlog 落盤，HA 環境必須是 1
binlog_row_image         = FULL       # 預設。MINIMAL 可縮小 binlog，但資料修復與 CDC 工具會少資訊
binlog_cache_size        = 32K        # 預設。Binlog_cache_disk_use 持續增加時再調大
max_binlog_size          = 1G         # 預設
# binlog_space_limit     = 50G        # Percona 專屬（預設 0 = 不限制）：binlog 總量上限，防止塞滿磁碟

# ---- 從庫 ----
relay_log                = relay-bin
relay_log_recovery       = ON         # 建議（預設 OFF）。從庫當機重啟後丟棄可能損毀的 relay log，從主庫重抓
replica_parallel_workers = 4          # 預設。調整方式見「平行複製」篇
replica_preserve_commit_order = ON    # 預設
```

`db2` 把 `server_id` 改成 `2`、`report_host` 改成 `db2`。

> 8.0.34 起 `binlog_format` 標為棄用，啟動時錯誤日誌會出現 `[Warning] [MY-011070] [Server] 'binlog_format' is deprecated and will be removed in a future release.`。8.0 的預設值本來就是 `ROW`，寫出來只是讓設定一目了然，不寫也可以。
{: .prompt-info }

> 從庫的 `read_only` / `super_read_only` **先不要寫進設定檔**。第一次啟動時 root 密碼是過期的，必須先 `ALTER USER`，而 `super_read_only=ON` 會把這個動作擋掉：
>
> `ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement`
>
> 這是實測踩到的。唯讀在步驟 7 用 `SET PERSIST` 開啟即可。
{: .prompt-danger }

## 步驟 3：啟動並設定 root 密碼（兩台都做）

```bash
sudo systemctl enable --now mysqld
sudo grep 'temporary password' /var/log/mysqld.log
```

```console
Created symlink /etc/systemd/system/mysql.service → /usr/lib/systemd/system/mysqld.service.
Created symlink /etc/systemd/system/multi-user.target.wants/mysqld.service → /usr/lib/systemd/system/mysqld.service.
● mysqld.service - MySQL Server
     Loaded: loaded (/usr/lib/systemd/system/mysqld.service; enabled; preset: enabled)
     Active: active (running) since Sat 2026-10-24 03:43:21 UTC; 15ms ago
2026-10-24T03:43:18.343242Z 6 [Note] [MY-010454] [Server] A temporary password is generated for root@localhost: K6cruSwt(u5g
```

第一次啟動時，systemd 的 `ExecStartPre=/usr/bin/mysqld_pre_systemd` 會初始化資料目錄並產生臨時密碼。用臨時密碼登入後立刻改掉：

```bash
mysql -uroot -p --connect-expired-password \
  -e "ALTER USER root@localhost IDENTIFIED BY 'Root#Pass2026';"
```

為了後面操作方便，把密碼放進 `/root/.my.cnf`：

```bash
cat > /root/.my.cnf <<'EOF'
[client]
user=root
password="Root#Pass2026"
EOF
chmod 600 /root/.my.cnf
```

> 選項檔裡 `#` 是註解符號。密碼含 `#` 時**一定要加引號**，否則會被截成 `Root`，結果是 `ERROR 1045 (28000): Access denied`。這也是實測踩到的。
{: .prompt-warning }

確認設定生效：

```console
# mysql -e "select @@hostname,@@server_id,@@server_uuid,@@version,@@version_comment,@@gtid_mode,@@enforce_gtid_consistency,@@log_bin,@@binlog_format\G"
*************************** 1. row ***************************
                @@hostname: db1
               @@server_id: 1
             @@server_uuid: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e
                 @@version: 8.0.46-37
         @@version_comment: Percona Server (GPL), Release 37, Revision 39e2b60e
               @@gtid_mode: ON
@@enforce_gtid_consistency: ON
                 @@log_bin: 1
           @@binlog_format: ROW
```

確認效能設定也生效（16 GB 主機的值）：

```console
# mysql -e "SELECT @@innodb_buffer_pool_size/1024/1024/1024 AS bp_gb, @@innodb_buffer_pool_instances AS bp_inst, @@innodb_redo_log_capacity/1024/1024/1024 AS redo_gb, @@innodb_flush_method, @@innodb_io_capacity, @@innodb_io_capacity_max, @@innodb_page_cleaners, @@max_connections, @@skip_name_resolve, @@tmp_table_size/1024/1024 AS tmp_mb, @@slow_query_log, @@long_query_time, @@log_timestamps, @@innodb_temp_data_file_path, @@open_files_limit\G"
*************************** 1. row ***************************
                       bp_gb: 10.000000000000
                     bp_inst: 8
                     redo_gb: 2.000000000000
       @@innodb_flush_method: O_DIRECT
        @@innodb_io_capacity: 2000
    @@innodb_io_capacity_max: 4000
      @@innodb_page_cleaners: 4
           @@max_connections: 500
         @@skip_name_resolve: 1
                      tmp_mb: 64.00000000
            @@slow_query_log: 1
           @@long_query_time: 1.000000
            @@log_timestamps: SYSTEM
@@innodb_temp_data_file_path: ibtmp1:12M:autoextend:max:10G
          @@open_files_limit: 10000
```

慢查詢日誌也確認一下（`log_slow_extra = ON` 會多出 `Rows_examined`、`Bytes_sent`、`Created_tmp_disk_tables` 等欄位）：

```console
# mysql -e "SELECT SLEEP(1.2)" > /dev/null; tail -4 /var/lib/mysql/slow.log
# User@Host: root[root] @ localhost []  Id:    13
# Query_time: 1.200331  Lock_time: 0.000000 Rows_sent: 1  Rows_examined: 1 Thread_id: 13 Errno: 0 Killed: 0 Bytes_received: 24 Bytes_sent: 58 Read_first: 0 Read_last: 0 Read_key: 0 Read_next: 0 Read_prev: 0 Read_rnd: 0 Read_rnd_next: 0 Sort_merge_passes: 0 Sort_range_count: 0 Sort_rows: 0 Sort_scan_count: 0 Created_tmp_disk_tables: 0 Created_tmp_tables: 0 Start: 2026-10-24T05:20:31.216667-00:00 End: 2026-10-24T05:20:32.416998-00:00 Schema:  Rows_affected: 0
SET timestamp=1792819231;
SELECT SLEEP(1.2);
```

啟動時錯誤日誌另外會有兩行 Warning，都可以忽略：`Insecure configuration for --secure-log-path`（Percona 專屬參數，未設定時的提醒）與 `CA certificate ca.pem is self signed`（安裝時自動產生的自簽憑證）。

## 步驟 4：主庫建立複製帳號（db1）

```sql
CREATE USER 'repl'@'192.168.56.%' IDENTIFIED BY 'Repl#Pass2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.56.%';

-- 示範用的業務資料
CREATE DATABASE shop;
CREATE TABLE shop.orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  item VARCHAR(50),
  amount DECIMAL(10,2),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO shop.orders (item, amount) VALUES ('keyboard', 1290), ('mouse', 590), ('monitor', 6990);

SHOW MASTER STATUS;
```

```console
+------------------+----------+--------------+------------------+------------------------------------------+
| File             | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set                        |
+------------------+----------+--------------+------------------+------------------------------------------+
| mysql-bin.000002 |     1884 |              |                  | 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 |
+------------------+----------+--------------+------------------+------------------------------------------+
```

## 步驟 5：用 mysqldump 建立從庫資料

主庫上已經有資料時，要先把資料搬到從庫。資料量小用 `mysqldump`，大的建議用 XtraBackup（見 [備份與還原]({% post_url 2026-10-24-mysql-ops-02-backup-restore %})）。

在 `db1` 匯出：

```bash
mysqldump --all-databases --single-transaction --triggers --routines --events \
  --source-data=2 --set-gtid-purged=ON --flush-privileges > /root/full.sql
```

```console
# grep -n -E "^SET @@GLOBAL.GTID_PURGED|^-- CHANGE MASTER|FLUSH PRIV" /root/full.sql
36:SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6';
42:-- CHANGE MASTER TO MASTER_LOG_FILE='mysql-bin.000002', MASTER_LOG_POS=1884;
1098:/*! FLUSH PRIVILEGES */;
```

- `--set-gtid-purged=ON`：檔案裡會寫入 `GTID_PURGED`，從庫匯入後就知道「這些交易已經有了」，接上複製時只會拉後面的交易。
- `--flush-privileges`：**一定要加**。`--all-databases` 會把 `mysql.user` 一起匯入，但匯入的是資料表內容，記憶體裡的權限不會更新。實測沒加這個參數時，從庫上的 `repl` 帳號看得到但不能登入，等到做切換時才會出錯：`Host 'db1' is not allowed to connect to this MySQL server`。
- 8.0.46 的 `mysqldump` 註解裡仍是舊語法 `CHANGE MASTER TO`，用 GTID 自動定位時用不到這行，看看就好。

把檔案複製到 `db2`，**先 `RESET MASTER` 再匯入**：

```console
# mysql -e "SELECT @@gtid_executed"
+----------------------------------------+
| @@gtid_executed                        |
+----------------------------------------+
| 0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589:1 |
+----------------------------------------+

# mysql -e "RESET MASTER"
# mysql < /root/full.sql
# mysql -e "SELECT @@gtid_executed, @@gtid_purged"
+------------------------------------------+------------------------------------------+
| @@gtid_executed                          | @@gtid_purged                            |
+------------------------------------------+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 | 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 |
+------------------------------------------+------------------------------------------+
```

注意 `db2` 匯入前已經有一筆自己的 GTID（`0f1ea8d1...:1`），那是步驟 3 的 `ALTER USER` 產生的。8.0 的 dump 檔用 `'+'` 語法附加 `GTID_PURGED`，**不清掉也不會報錯**，但這筆只存在從庫的交易會變成 errant transaction，日後切換主庫時可能出問題。所以匯入前一律 `RESET MASTER`。

> 匯入 `mysql` 系統庫後，`db2` 的 root 密碼會變成和 `db1` 一樣。
{: .prompt-info }

## 步驟 6：設定複製（db2）

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'db1',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = 'Repl#Pass2026',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_SSL = 1;

START REPLICA;
```

> 少了 `SOURCE_SSL = 1` 會連不上。8.0 預設認證外掛是 `caching_sha2_password`，實測錯誤如下：
>
> `Last_IO_Error: Error connecting to source 'repl@db1:3306'. ... Message: Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.`
>
> 8.0 安裝時會自動產生自簽憑證，所以直接開 `SOURCE_SSL = 1` 就能用。若不想走 SSL，改用 `GET_SOURCE_PUBLIC_KEY = 1`。
{: .prompt-danger }

```console
# mysql -e "SHOW REPLICA STATUS\G"
                  Source_Host: db1
                  Source_User: repl
                  Source_Port: 3306
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
           Source_SSL_Allowed: Yes
        Seconds_Behind_Source: 0
                Last_IO_Error:
               Last_SQL_Error:
    Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
           Retrieved_Gtid_Set:
            Executed_Gtid_Set: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6
                Auto_Position: 1
```

`Replica_IO_Running` 與 `Replica_SQL_Running` 都是 `Yes`，複製就建立好了。

## 步驟 7：從庫設為唯讀（db2）

```sql
SET PERSIST read_only = ON;
SET PERSIST super_read_only = ON;
```

`SET PERSIST` 會寫進 `/var/lib/mysql/mysqld-auto.cnf`，重啟後依然有效。

## 步驟 8：驗證

在 `db1` 寫入一筆：

```console
# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('headset', 2490); SELECT @@gtid_executed; SHOW REPLICAS;"
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         2 | db2  | 3306 |         1 | 0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589 |
+-----------+------+------+-----------+--------------------------------------+
```

在 `db2` 查詢，資料與 GTID 集合都一致：

```console
# mysql -e "SELECT id,item,amount FROM shop.orders; SELECT @@gtid_executed;"
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
|  4 | headset  | 2490.00 |
+----+----------+---------+
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
```

從庫寫入會被擋下：

```console
# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('should-fail', 1);"
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

## 步驟 9：計畫內切換（Switchover）

GTID 最大的好處是切換時不用找 binlog 檔名與位置。以下把主庫從 `db1` 換到 `db2`。

**1. 舊主庫停止寫入（db1）**

```console
# mysql -e "SET PERSIST read_only=ON; SET PERSIST super_read_only=ON; SELECT @@gtid_executed;"
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
```

**2. 等新主庫追上（db2）**：回傳 `0` 代表在逾時（10 秒）內已套用完上面的 GTID 集合。

```console
# mysql -e "SELECT WAIT_FOR_EXECUTED_GTID_SET('0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7', 10) AS caught_up;"
+-----------+
| caught_up |
+-----------+
|         0 |
+-----------+
```

**3. 提升新主庫（db2）**

```console
# mysql -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SELECT @@read_only, @@super_read_only;"
+-------------+-------------------+
| @@read_only | @@super_read_only |
+-------------+-------------------+
|           0 |                 0 |
+-------------+-------------------+
```

**4. 舊主庫改成從庫（db1）**

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'db2', SOURCE_PORT = 3306,
  SOURCE_USER = 'repl', SOURCE_PASSWORD = 'Repl#Pass2026',
  SOURCE_AUTO_POSITION = 1, SOURCE_SSL = 1;
START REPLICA;
```

```console
                  Source_Host: db2
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
                Last_IO_Error:
            Executed_Gtid_Set: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7
                Auto_Position: 1
```

**5. 驗證**：在新主庫 `db2` 寫入，`db1` 收得到，GTID 集合多了 `db2` 的 UUID。

```console
db2# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('webcam', 1890);"
db1# mysql -e "SELECT id,item,amount FROM shop.orders; SELECT @@gtid_executed;"
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
|  4 | headset  | 2490.00 |
|  5 | webcam   | 1890.00 |
+----+----------+---------+
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7,
0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589:1 |
+------------------------------------------+
```

切換完成後，記得把應用程式的連線（DNS、VIP 或 ProxySQL）指向新主庫。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `gtid_mode` 是 `OFF`、`ERROR 1777`、`Server has GTIDs disabled` | dnf 版 `/etc/my.cnf` 沒有 `!includedir`，`/etc/my.cnf.d/` 的設定沒被讀到 | 第一次啟動前補上 `!includedir /etc/my.cnf.d` |
| 改 root 密碼出現 `ERROR 1290 ... --super-read-only` | 設定檔先開了 `super_read_only` | 唯讀等密碼改完再用 `SET PERSIST` 開 |
| `.my.cnf` 設好密碼仍 `Access denied` | 密碼含 `#` 被當成註解 | `password="..."` 加引號 |
| `Authentication requires secure connection` | `caching_sha2_password` 需要 SSL 或公鑰 | `SOURCE_SSL = 1` 或 `GET_SOURCE_PUBLIC_KEY = 1` |
| 切換時 `Host 'db1' is not allowed to connect` | 匯入 `mysql.user` 後沒有 flush | `mysqldump` 加 `--flush-privileges` |
| 從庫多一筆自己的 GTID | 初始化時 `ALTER USER` 寫了 binlog | 匯入前 `RESET MASTER` |

## 驗證方式與結果

**驗證環境**

| 項目 | 環境 A（主要） | 環境 B |
| :--- | :--- | :--- |
| 主機 | MacBook Air M4，macOS 15.7 | Linux 雲端主機 |
| 容器 | Docker Desktop 4.96，`rockylinux:9` + systemd | Docker 29，`percona/percona-server:8.0.46-37.1`（RHEL 9 UBI）+ systemd |
| Percona 安裝方式 | 照步驟 1 用 `dnf` 從 `repo.percona.com` 安裝 | 映像內建同版本 el9 RPM |
| 架構 | aarch64 | x86_64 |

兩台節點各是一個 privileged 容器，以 `/usr/sbin/init`（systemd）為 PID 1，所以 `systemctl enable --now mysqld`、`mysqld_pre_systemd` 產生臨時密碼都是真實流程。節點之間用固定 IP 的 Docker 網路（192.168.56.0/24）並設好主機名。每篇開始前都 `docker compose down && docker compose up -d`，從全新的主機開始照文章操作。

環境 A 的建置檔如下，想自己重現的話，把兩個檔案放在同一個資料夾執行 `docker compose build && docker compose up -d`，再用 `docker compose exec db1 bash` 進入節點，從步驟 2 開始做（步驟 0 的 hosts 由 compose 設定，步驟 1 在 build 時完成）。

```dockerfile
# Dockerfile：Rocky Linux 9 + systemd + 從 repo.percona.com 安裝 Percona
FROM rockylinux:9
# 固定版本時用 --build-arg PS_VER=-8.0.46-37.1.el9
ARG PS_VER=""
RUN dnf install -y systemd procps-ng iproute hostname which less vim-minimal bc \
 && dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm \
 && percona-release setup -y ps80 \
 && dnf install -y percona-server-server${PS_VER} percona-server-client${PS_VER} \
                   percona-mysql-shell percona-mysql-router \
 && dnf clean all
RUN systemctl mask systemd-logind.service getty.target console-getty.service \
 && (systemctl disable mysqld mysqlrouter 2>/dev/null; true)
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
```

```yaml
# compose.yaml：db1~db3 與 router 四台「主機」
x-node: &node
  image: rocky9-percona80
  privileged: true            # systemd 當 PID 1 需要
  cgroup: host
  volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw"]
  tmpfs: ["/run", "/run/lock"]
  extra_hosts:
    - "db1:192.168.56.11"
    - "db2:192.168.56.12"
    - "db3:192.168.56.13"
    - "router:192.168.56.20"
services:
  db1:    { <<: *node, build: ., hostname: db1,    networks: { labnet: { ipv4_address: 192.168.56.11 } } }
  db2:    { <<: *node, hostname: db2,    networks: { labnet: { ipv4_address: 192.168.56.12 } } }
  db3:    { <<: *node, hostname: db3,    networks: { labnet: { ipv4_address: 192.168.56.13 } } }
  router: { <<: *node, hostname: router, networks: { labnet: { ipv4_address: 192.168.56.20 } } }
networks:
  labnet:
    ipam: { config: [ { subnet: 192.168.56.0/24 } ] }
```

**驗證項目**

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 1 安裝 | `rpm -qa`、`mysqld --version` | 8.0.46-37.1 | ✅ A、B |
| 2~3 設定與啟動 | `SELECT @@server_id, @@gtid_mode ...` | 各台 `server_id` 不同、`gtid_mode=ON` | ✅ A（補 includedir 後）、B |
| 2-2 效能設定 | 套用後啟動，查詢各參數；觸發一筆慢查詢 | 服務正常啟動、錯誤日誌無 `[ERROR]`、參數值與設定檔一致、`slow.log` 有記錄 | ✅ B（另在 Group Replication、InnoDB Cluster 三節點上套用同一份設定，叢集建立正常） |
| 5 建從庫 | `grep GTID_PURGED full.sql`；匯入後比對 `gtid_executed` | 從庫 `gtid_executed` = 主庫 dump 時的集合 | ✅ A、B |
| 6 建立複製 | `SHOW REPLICA STATUS\G` | IO / SQL 都 `Yes`、`Last_*_Error` 空白 | ✅ A、B |
| 8 資料同步 | 主庫寫入後到從庫查詢、比對 `gtid_executed` | 資料與 GTID 集合一致；從庫寫入回 `ERROR 1290` | ✅ A、B |
| 9 Switchover | `WAIT_FOR_EXECUTED_GTID_SET()`、反向複製後在新主庫寫入 | 回傳 `0`；舊主庫收到新主庫的交易 | ✅ A、B |

**錯誤處理紀錄**（對應上方「實測踩到的坑」）：

- 缺 `!includedir`：環境 A 遇到（環境 B 的官方映像已有這行），補上後重做全部通過。
- `.my.cnf` 密碼沒加引號、少 `SOURCE_SSL = 1`：兩個環境都重現，錯誤訊息與文中相同。
- `super_read_only` 擋 `ALTER USER`、缺 `--flush-privileges`、從庫多一筆 GTID：環境 B 遇到並處理。

## 小結

- dnf 安裝後先補 `!includedir /etc/my.cnf.d`，否則 `/etc/my.cnf.d/` 的設定都不會生效。
- 8.0 建複製一律用 GTID + `SOURCE_AUTO_POSITION = 1`，切換只要比對 GTID 集合。
- 建從庫前先 `RESET MASTER`，dump 時加 `--set-gtid-purged=ON --flush-privileges`。
- 從庫用 `SET PERSIST super_read_only = ON` 防止誤寫。

下一篇：[半同步複製]({% post_url 2026-10-24-mysql-ha-lab-02-semi-sync %})，在這個 GTID 架構上把 RPO 降到接近 0。

### 參考資料

- [Percona Server for MySQL 8.0：Install from Percona Software repository (YUM)](https://docs.percona.com/percona-server/8.0/yum-repo.html)
- [MySQL 8.0 Reference Manual：Setting Up Replication Using GTIDs](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-howto.html)
- [MySQL 8.0 Reference Manual：CHANGE REPLICATION SOURCE TO Statement](https://dev.mysql.com/doc/refman/8.0/en/change-replication-source-to.html)
