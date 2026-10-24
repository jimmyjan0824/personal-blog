---
title: MySQL 運維 01：安裝部署與環境配置
date: 2026-10-24 09:30:00 +0800
categories: [MySQL, 安裝部署]
tags: [mysql, mysql8, dba, installation, my.cnf, innodb]
description: 以 MySQL 8.0 為主，整理版本選型、安裝、my.cnf 關鍵參數、OS 與儲存層設定、雲端部署，並比較 5.7 與 8.4 LTS 的差異。
---

這是 MySQL 運維系列的第一篇。資料庫上線前的版本選型與基礎配置，決定了後面所有運維工作的難易度。本篇以 **MySQL 8.0** 為主軸，並在最後比較 5.7 與 8.4 LTS 的差異。

{% include mysql-ops-series.md %}

## 先搞清楚版本與支援週期

| 版本 | 發布 | Premier Support 結束 | Extended Support 結束（EOL） |
| :--- | :--- | :--- | :--- |
| 5.7 | 2015-10 | 2020-10 | **2023-10-31（已 EOL）** |
| 8.0 | 2018-04 | 2025-04 | **2026-04-30（已 EOL）** |
| 8.4 LTS | 2024-04 | 2029-04 | 2032-04 |

> 截至 2026 年 10 月，**8.0 已經結束官方支援**，不會再有社群版的安全更新。目前線上仍大量跑著 8.0，所以本系列以 8.0 為主，但每篇都會點出升級到 8.4 LTS 時要注意的地方。新專案建議直接選 8.4 LTS（或更新的 LTS）。
{: .prompt-warning }

從 8.0.34 開始，Oracle 改成 **Innovation + LTS** 的發布模型：

- **LTS（如 8.4）**：約兩年一版，只修 bug 與安全問題，不改行為，適合正式環境。
- **Innovation（如 9.x 非 LTS 版）**：每季發布，會加新功能也會移除舊功能，適合想嚐鮮的環境。

## 安裝方式

正式環境最常見的三種：

```bash
# 1. 官方 APT/YUM Repository（推薦，方便小版本升級）
sudo dpkg -i mysql-apt-config_*.deb   # 選擇 8.0 或 8.4
sudo apt update && sudo apt install mysql-server

# 2. Generic Binary（tar.gz），適合多實例、自訂路徑
tar xf mysql-8.0.*-linux-glibc2.28-x86_64.tar.xz -C /usr/local
/usr/local/mysql/bin/mysqld --initialize --user=mysql --datadir=/data/mysql

# 3. 容器
docker run -d --name mysql80 -e MYSQL_ROOT_PASSWORD=*** \
  -v /data/mysql:/var/lib/mysql mysql:8.0
```

`--initialize` 會產生一組隨機 root 密碼寫在 error log；`--initialize-insecure` 則產生空密碼，只適合測試環境。

## my.cnf 核心參數

以下是一台 32 GB 記憶體、SSD、專用資料庫主機的 8.0 起手式：

```ini
[mysqld]
# 基本
server_id                       = 1
port                            = 3306
datadir                         = /data/mysql
socket                          = /var/run/mysqld/mysqld.sock
character_set_server            = utf8mb4
collation_server                = utf8mb4_0900_ai_ci
default_time_zone               = '+08:00'
max_connections                 = 1000
skip_name_resolve               = ON

# InnoDB 記憶體
innodb_buffer_pool_size         = 22G      # 約 RAM 的 60%~75%
innodb_buffer_pool_instances    = 8

# InnoDB Redo（8.0.30+ 用 innodb_redo_log_capacity）
innodb_redo_log_capacity        = 4G
innodb_log_buffer_size          = 64M

# InnoDB IO
innodb_flush_method             = O_DIRECT
innodb_io_capacity              = 2000
innodb_io_capacity_max          = 4000
innodb_flush_log_at_trx_commit  = 1        # 雙 1：最安全
sync_binlog                     = 1

# Binlog / 複製
log_bin                         = mysql-bin
binlog_format                   = ROW
binlog_expire_logs_seconds      = 604800   # 7 天
gtid_mode                       = ON
enforce_gtid_consistency        = ON

# 日誌
slow_query_log                  = ON
long_query_time                 = 1
log_error_verbosity             = 2
```

幾個重點：

- **`innodb_buffer_pool_size`**：最重要的參數。專用主機給 RAM 的 60%~75%，記得扣掉連線緩衝（`sort_buffer_size`、`join_buffer_size` 等是每條連線各自分配的）。8.0 可以線上調整，不用重啟。
- **`innodb_dedicated_server = ON`**（8.0.3+）：讓 MySQL 依照主機記憶體自動計算 buffer pool 與 redo log 大小，適合「一台機器只跑一個 MySQL」的情境。
- **`innodb_redo_log_capacity`**（8.0.30+）：取代舊的 `innodb_log_file_size` × `innodb_log_files_in_group`，而且可以線上動態調整。
- **雙 1**（`innodb_flush_log_at_trx_commit=1` + `sync_binlog=1`）：保證交易不丟失，正式環境的預設選擇。

### SET PERSIST：不用再手動改 my.cnf

8.0 新增 `SET PERSIST`，修改會寫進 `datadir/mysqld-auto.cnf`，重啟後仍有效：

```sql
SET PERSIST max_connections = 2000;
SET PERSIST_ONLY innodb_log_buffer_size = 67108864;  -- 唯讀參數，下次重啟生效
RESET PERSIST max_connections;                      -- 移除持久化設定

SELECT * FROM performance_schema.persisted_variables;
```

> `mysqld-auto.cnf` 的優先順序高於 my.cnf。排查「改了 my.cnf 怎麼沒生效」時，記得先看這個檔案。
{: .prompt-tip }

## OS 與儲存層

```bash
# 降低 swap 傾向（不要設 0，避免 OOM Killer 直接出手）
echo 'vm.swappiness = 1' >> /etc/sysctl.d/99-mysql.conf

# 關閉 Transparent Huge Pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# 檔案描述符上限（systemd）
# /etc/systemd/system/mysqld.service.d/override.conf
[Service]
LimitNOFILE = 65535
```

- **檔案系統**：XFS 或 ext4，掛載加 `noatime`。
- **IO Scheduler**：NVMe 用 `none`，SATA SSD 用 `mq-deadline`。
- **RAID**：RAID 10 優先；有 RAID 卡的話開啟 BBU write-back cache。
- **NUMA**：多 socket 機器開啟 `innodb_numa_interleave=ON`，避免記憶體分配不均導致 swap。

## 雲端託管（RDS / Cloud SQL）

託管服務幫你處理了安裝、OS、備份與 HA，但有幾點要注意：

- 拿不到 `SUPER` 權限，部分參數只能透過 Parameter Group 修改。
- 大版本升級（如 8.0 → 8.4）通常要自己發起，雲廠商對 EOL 版本會收取延長支援費用（例如 AWS RDS Extended Support）。
- 仍然要自己負責 SQL、索引、Schema 設計與容量規劃。

## 升級路徑與檢查

MySQL **只支援相鄰大版本的就地升級**：

```text
5.7  ──►  8.0  ──►  8.4 LTS
   （不能 5.7 直接跳 8.4）
```

升級前一定要用 MySQL Shell 的升級檢查工具：

```bash
mysqlsh -- util checkForServerUpgrade root@localhost:3306 --target-version=8.4.0
```

它會檢查保留字衝突、已移除的參數、不相容的認證外掛、`utf8mb3` 使用狀況等。從 8.0.16 開始，伺服器啟動時會自動升級系統表，不再需要執行 `mysql_upgrade`。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 預設字元集 | `latin1` | `utf8mb4`（`utf8mb4_0900_ai_ci`） | 同 8.0 |
| 資料字典 | `.frm` 檔案 | 交易式資料字典（InnoDB） | 同 8.0 |
| Query Cache | 有（預設關） | **移除** | 移除 |
| Redo Log 參數 | `innodb_log_file_size` | 8.0.30+ `innodb_redo_log_capacity` | 只建議用 `innodb_redo_log_capacity` |
| 持久化參數 | 無 | `SET PERSIST` | 同 8.0 |
| 預設認證外掛 | `mysql_native_password` | `caching_sha2_password` | 同 8.0，且 `mysql_native_password` **預設停用** |
| 認證預設參數 | `default_authentication_plugin` | `default_authentication_plugin` | **移除**，改用 `authentication_policy` |
| 升級系統表 | 手動 `mysql_upgrade` | 8.0.16+ 自動 | `mysql_upgrade` **移除** |
| Binlog 過期 | `expire_logs_days` | `binlog_expire_logs_seconds` | `expire_logs_days` **移除** |

### 8.4 的 InnoDB 預設值大改

8.4 調整了一批 InnoDB 預設值，讓它更貼近現代硬體（SSD、多核心）。從 8.0 升到 8.4 時，若 my.cnf 沒有明確指定，行為就會改變：

| 參數 | 8.0 預設 | 8.4 預設 |
| :--- | :--- | :--- |
| `innodb_io_capacity` | 200 | 10000 |
| `innodb_log_buffer_size` | 16 MB | 64 MB |
| `innodb_flush_method`（Linux） | `fsync` | `O_DIRECT`（若支援） |
| `innodb_change_buffering` | `all` | `none` |
| `innodb_adaptive_hash_index` | `ON` | `OFF` |
| `innodb_numa_interleave` | `OFF` | `ON` |
| `innodb_use_fdatasync` | `OFF` | `ON` |
| `innodb_doublewrite_pages` | 4 | 128 |
| `innodb_buffer_pool_instances` | 8（< 1 GB 時為 1） | 依 buffer pool 大小與 CPU 數自動計算 |
| `temptable_max_ram` | 1 GB | 總記憶體 3%（1~4 GB） |

> 建議做法：升級前把 8.0 實際生效的值（`SHOW GLOBAL VARIABLES`）匯出，逐項決定要「沿用舊值」還是「接受新預設」，不要讓預設值變更在正式環境悄悄改變效能特性。
{: .prompt-tip }

## 小結

- 新專案選 LTS；8.0 已 EOL，應規劃升級到 8.4。
- 最重要的幾個參數：`innodb_buffer_pool_size`、`innodb_redo_log_capacity`、雙 1、`binlog_expire_logs_seconds`。
- 善用 `SET PERSIST`，但要記得 `mysqld-auto.cnf` 的存在。
- 升級只能逐版進行，並先跑 `util.checkForServerUpgrade`。

下一篇：[備份與還原]({% post_url 2026-10-24-mysql-ops-02-backup-restore %})。

### 參考資料

- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
- [MySQL 8.4 Release Notes：Changes in MySQL 8.4.0](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)
- [endoflife.date：MySQL](https://endoflife.date/mysql)
