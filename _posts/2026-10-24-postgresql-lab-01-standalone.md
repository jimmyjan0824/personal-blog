---
title: PostgreSQL 安裝部署 01：Standalone（PostgreSQL 17 / Rocky Linux 9）
date: 2026-10-24 13:01:00 +0800
categories: [PostgreSQL, 安裝部署]
tags: [postgresql, postgresql17, rocky-linux, installation, postgresql.conf, pg_hba.conf, systemd, pgdg, dba]
description: 在 Rocky Linux 9 上用 PGDG 套件庫安裝 PostgreSQL 17.11，以 systemd 管理單機 PostgreSQL，附上包含所有效能相關參數的 postgresql.conf（每個參數標明建議值或預設值）與 pg_hba.conf，所有輸出皆為實測結果，並比較 18.6 的預設值差異。
---

[安裝部署與環境配置]({% post_url 2026-10-24-postgresql-ops-01-installation-config %})一篇整理了版本選擇與共通觀念，這篇開始動手做。第一篇是最基本的 **Standalone（單機）**，下一篇的 [Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %}) 建立在這篇的安裝步驟與設定檔上。

{% include postgresql-ops-series.md %}

{% include postgresql-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `pg1` | 192.168.59.11 | PostgreSQL 17 Standalone（port 5432） |

規劃的主機規格：16 GB RAM、8 vCPU、SSD，專門跑 PostgreSQL；用途是 **OLTP 為主**的應用程式資料庫，連線數上限 200（更多連線用 PgBouncer）。

## 步驟 0：OS 參數

```bash
sudo tee /etc/sysctl.d/99-postgresql.conf <<'CONF'
# /etc/sysctl.d/99-postgresql.conf
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
net.core.somaxconn = 1024
CONF
sudo sysctl -p /etc/sysctl.d/99-postgresql.conf
```

```console
[pg1]# cp /root/conf/99-postgresql.conf /etc/sysctl.d/99-postgresql.conf && sysctl -p /etc/sysctl.d/99-postgresql.conf
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
net.core.somaxconn = 1024

[pg1]# cat /sys/kernel/mm/transparent_hugepage/enabled; grep -E "HugePages_Total|Hugepagesize" /proc/meminfo
[always] madvise never
HugePages_Total:       0
Hugepagesize:       2048 kB
```

| 參數 | 為什麼 |
| :--- | :--- |
| `vm.swappiness = 1` | 盡量不要 swap，資料庫行程被換出去延遲會暴增 |
| `vm.dirty_background_bytes = 64MB` | 預設以記憶體百分比計算（10%），大記憶體主機會累積數 GB 髒頁後一次寫爆 I/O，改用固定大小 |
| `vm.dirty_bytes = 512MB` | 同上，強制同步寫回的門檻 |
| `net.core.somaxconn = 1024` | 連線尖峰時的 listen backlog |

- 輸出中的 THP 是 `[always]`、`HugePages_Total: 0`：容器共用 Docker VM 的核心，無法在容器內調整。正式主機建議把 THP 設成 `never` 或 `madvise`，並依[安裝部署篇]({% post_url 2026-10-24-postgresql-ops-01-installation-config %})的方法設定 `vm.nr_hugepages` 後把 `huge_pages` 改成 `on`（**未實測**）。

  暫時關閉 THP（立即生效，重開機後會恢復；**未實測**）：

  ```bash
  cat /sys/kernel/mm/transparent_hugepage/enabled
  echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
  ```

  透過 systemd 在 PostgreSQL 啟動前關閉 THP（重開機後仍有效；**未實測**）。PGDG 套件的服務名稱是 `postgresql-17.service`，所以 `Before=` 要寫這個名稱：

  ```bash
  sudo tee /etc/systemd/system/disable-thp.service <<'UNIT'
  [Unit]
  Description=Disable Transparent Huge Pages (THP)
  DefaultDependencies=no
  After=sysinit.target local-fs.target
  Before=postgresql-17.service

  [Service]
  Type=oneshot
  ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag'

  [Install]
  WantedBy=basic.target
  UNIT

  sudo systemctl daemon-reload
  sudo systemctl enable --now disable-thp.service
  ```

- 防火牆（**未實測**，容器內沒有 firewalld）：

```bash
sudo firewall-cmd --permanent --add-service=postgresql
sudo firewall-cmd --reload
```

## 步驟 1：安裝（PGDG 套件庫）

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql17-server postgresql17-contrib
```

實測輸出（aarch64；x86_64 主機上架構字樣會是 `x86_64`）：

```console
[pg1]# dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm 2>&1 | grep -E "^Install|pgdg-redhat-repo|Complete"
pgdg-redhat-repo-latest.noarch.rpm               95 kB/s |  15 kB     00:00    
Installing:
 pgdg-redhat-repo     noarch     42.0-70.rhel9PGDG       @commandline      15 k
Install  1 Package
Installed size: 20 k
  Installing       : pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch              1/1 
  Running scriptlet: pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch              1/1 
  Verifying        : pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch              1/1 
Installed:
  pgdg-redhat-repo-42.0-70.rhel9PGDG.noarch                                     
Complete!
[pg1]# dnf -qy module disable postgresql; dnf repolist --enabled | grep -i pgdg
Importing GPG key 0xB9738825:
 Userid     : "PostgreSQL RPM Repository <pgsql-pkg-yum@lists.postgresql.org>"
 Fingerprint: B031 F89F C983 E982 6290 6B6E 177B 343B B973 8825
 From       : /etc/pki/rpm-gpg/PGDG-RPM-GPG-KEY-AARCH64-RHEL
pgdg-common PostgreSQL common RPMs for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64
pgdg14      PostgreSQL 14 for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64
pgdg15      PostgreSQL 15 for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64
pgdg16      PostgreSQL 16 for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64
pgdg17      PostgreSQL 17 for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64
pgdg18      PostgreSQL 18 for RHEL / Rocky Linux / AlmaLinux 9.8 - aarch64

[pg1]# dnf install -y postgresql17-server postgresql17-contrib 2>&1 | grep -E "^Install|^ postgresql17|Importing GPG|Fingerprint|Key imported|Complete"
Installing:
 postgresql17-contrib     aarch64   17.11-1PGDG.rhel9.8       pgdg17      709 k
 postgresql17-server      aarch64   17.11-1PGDG.rhel9.8       pgdg17      6.9 M
Installing dependencies:
 postgresql17             aarch64   17.11-1PGDG.rhel9.8       pgdg17      1.9 M
 postgresql17-libs        aarch64   17.11-1PGDG.rhel9.8       pgdg17      340 k
Installing weak dependencies:
Install  66 Packages
Installed size: 113 M
Importing GPG key 0xB9738825:
 Fingerprint: B031 F89F C983 E982 6290 6B6E 177B 343B B973 8825
Key imported successfully
Installed:
Complete!

[pg1]# rpm -q postgresql17 postgresql17-libs postgresql17-server postgresql17-contrib; rpm -qi postgresql17-server | grep -E "^(Version|Release|Signature)"
postgresql17-17.11-1PGDG.rhel9.8.aarch64
postgresql17-libs-17.11-1PGDG.rhel9.8.aarch64
postgresql17-server-17.11-1PGDG.rhel9.8.aarch64
postgresql17-contrib-17.11-1PGDG.rhel9.8.aarch64
Version     : 17.11
Release     : 1PGDG.rhel9.8
Signature   : RSA/SHA256, Tue Aug 11 21:20:36 2026, Key ID 177b343bb9738825

[pg1]# /usr/pgsql-17/bin/postgres --version; which psql; psql --version
postgres (PostgreSQL) 17.11
/usr/pgsql-17/bin/psql
psql (PostgreSQL) 17.11
```

- 第一次使用 PGDG 套件庫時會匯入 GPG 金鑰（指紋 `B031 F89F ... B973 8825`），之後安裝的套件都會驗證簽章；`rpm -qi` 的 `Signature` 欄位的 Key ID 和匯入的金鑰一致。
- `dnf -qy module disable postgresql` 第一次存取各個 pgdg 套件庫時都會匯入一次金鑰，所以出現了好幾次，屬正常現象（上面只保留第一筆）。
- 套件庫標示為 `9.8`：PGDG 依 Rocky 的 minor 版本分套件庫。**實測發現 Docker Hub 的 `rockylinux:9` 映像停在 9.3，PGDG 已經不提供 `rhel-9.3` 的套件庫，`dnf` 會因為 `repomd.xml` 404 而失敗**，所以實測改用 `rockylinux/rockylinux:9`（9.8）。實體機或 VM 只要 `dnf upgrade` 到最新的 9.x 就不會遇到。

PGDG 的編譯選項（決定了能不能用 lz4、zstd、ICU、JIT、systemd 通知）：

```console
[pg1]# /usr/pgsql-17/bin/pg_config --configure | tr " " "\n" | grep -E "with-(lz4|zstd|llvm|systemd|openssl|icu|libxml|gssapi|ldap|pam|selinux)|system-tzdata"
'--with-lz4'
'--with-zstd'
'--with-icu'
'--with-llvm'
'--with-openssl'
'--with-pam'
'--with-gssapi'
'--with-libxml'
'--with-ldap'
'--with-selinux'
'--with-systemd'
'--with-system-tzdata=/usr/share/zoneinfo'

[pg1]# id postgres; ls -ld /var/lib/pgsql /var/lib/pgsql/17 /var/lib/pgsql/17/data
uid=26(postgres) gid=26(postgres) groups=26(postgres)
drwx------ 3 postgres postgres 4096 Oct 24 07:18 /var/lib/pgsql
drwx------ 4 postgres postgres 4096 Oct 24 07:18 /var/lib/pgsql/17
drwx------ 2 postgres postgres 4096 Aug 11 19:50 /var/lib/pgsql/17/data
```

`--with-lz4` 讓設定檔裡的 `wal_compression = lz4`、`default_toast_compression = lz4` 可以使用；`--with-systemd` 讓 unit 檔可以用 `Type=notify`。

## 步驟 2：initdb

```bash
sudo PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" \
  /usr/pgsql-17/bin/postgresql-17-setup initdb
```

| 選項 | 說明 |
| :--- | :--- |
| `--data-checksums` | 資料頁檢查碼，17 預設不開（18 預設開），**initdb 後就不能直接改**（要停機用 `pg_checksums`） |
| `--locale-provider=builtin --builtin-locale=C.UTF-8` | 17 新增的內建 locale，排序規則不依賴 glibc，OS 升級時不會讓文字索引失效 |
| `--encoding=UTF8 --locale=C.UTF-8` | `lc_messages` 等也用 C.UTF-8，錯誤訊息維持英文，方便搜尋 |

```console
[pg1]# PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" /usr/pgsql-17/bin/postgresql-17-setup initdb && cat /var/lib/pgsql/17/initdb.log
Initializing database ... OK

The files belonging to this database system will be owned by user "postgres".
This user must also own the server process.

The database cluster will be initialized with this locale configuration:
  locale provider:   builtin
  default collation: C.UTF-8
  LC_COLLATE:  C.UTF-8
  LC_CTYPE:    C.UTF-8
  LC_MESSAGES: C.UTF-8
  LC_MONETARY: C.UTF-8
  LC_NUMERIC:  C.UTF-8
  LC_TIME:     C.UTF-8
The default text search configuration will be set to "english".

Data page checksums are enabled.

fixing permissions on existing directory /var/lib/pgsql/17/data ... ok
creating subdirectories ... ok
selecting dynamic shared memory implementation ... posix
selecting default "max_connections" ... 100
selecting default "shared_buffers" ... 128MB
selecting default time zone ... Etc/UTC
creating configuration files ... ok
running bootstrap script ... ok
performing post-bootstrap initialization ... ok
syncing data to disk ... ok

Success. You can now start the database server using:

    /usr/pgsql-17/bin/pg_ctl -D /var/lib/pgsql/17/data/ -l logfile start


[pg1]# runuser -u postgres -- pg_controldata /var/lib/pgsql/17/data | grep -E "pg_control version|Catalog version|checksum|Database block size|WAL block size|Bytes per WAL segment"
pg_control version number:            1700
Catalog version number:               202406281
Database block size:                  8192
WAL block size:                       8192
Bytes per WAL segment:                16777216
Data page checksum version:           1

[pg1]# ls -la /var/lib/pgsql/17/data
total 132
drwx------ 20 postgres postgres  4096 Oct 24 07:18 .
drwx------  4 postgres postgres  4096 Oct 24 07:18 ..
-rw-------  1 postgres postgres     3 Oct 24 07:18 PG_VERSION
drwx------  5 postgres postgres  4096 Oct 24 07:18 base
drwx------  2 postgres postgres  4096 Oct 24 07:18 global
drwx------  2 postgres postgres  4096 Oct 24 07:18 log
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_commit_ts
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_dynshmem
-rw-------  1 postgres postgres  5499 Oct 24 07:18 pg_hba.conf
-rw-------  1 postgres postgres  2640 Oct 24 07:18 pg_ident.conf
drwx------  4 postgres postgres  4096 Oct 24 07:18 pg_logical
drwx------  4 postgres postgres  4096 Oct 24 07:18 pg_multixact
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_notify
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_replslot
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_serial
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_snapshots
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_stat
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_stat_tmp
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_subtrans
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_tblspc
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_twophase
drwx------  4 postgres postgres  4096 Oct 24 07:18 pg_wal
drwx------  2 postgres postgres  4096 Oct 24 07:18 pg_xact
-rw-------  1 postgres postgres    88 Oct 24 07:18 postgresql.auto.conf
-rw-------  1 postgres postgres 30963 Oct 24 07:18 postgresql.conf
```

`Data page checksum version: 1` 代表 checksums 已經開啟。

## 步驟 3：設定檔

先備份 initdb 產生的設定檔，再換成下面兩個檔案：

```bash
sudo install -d -o postgres -g postgres -m 700 /var/lib/pgsql/17/archive
cd /var/lib/pgsql/17/data
sudo cp postgresql.conf postgresql.conf.initdb
sudo cp pg_hba.conf pg_hba.conf.initdb
sudo install -o postgres -g postgres -m 600 postgresql-standalone.conf postgresql.conf
sudo install -o postgres -g postgres -m 600 pg_hba-standalone.conf pg_hba.conf
```

### postgresql.conf

每個參數上一行的註解：標「建議」的是調整過的值，括號內是預設值；標「預設」的是 17 的預設值。「預設」指的是 PostgreSQL 的**編譯預設值**（`pg_settings.boot_val`），在全新安裝的 17.11 上逐一核對過（方法見文末「驗證方式與結果」）。寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。

> PGDG 的 initdb 產生的 postgresql.conf 有幾個值和編譯預設值不同：`logging_collector = on`、`log_filename = 'postgresql-%a.log'`、`log_rotation_size = 0`、`log_truncate_on_rotation = on`、`timezone` / `log_timezone = 'Etc/UTC'`。下面的設定檔是整份取代，所以這些參數都明確寫出來。
{: .prompt-info }

```ini
# /var/lib/pgsql/17/data/postgresql.conf
# PostgreSQL 17 Standalone：效能與運維設定
# 以「16 GB RAM、8 vCPU、SSD、專用 PostgreSQL 主機、OLTP 為主」為基準。
# 每個參數上一行的註解：標「建議」的是調整過的值（括號內是預設值）；
# 標「預設」的是 17 的預設值（在全新安裝的 PostgreSQL 17 上查 pg_settings.boot_val 逐一核對過），
# 寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。
# 「需重啟」表示改了要 systemctl restart，其他的 systemctl reload 即可。

#------------------------------------------------------------------------------
# 連線
#------------------------------------------------------------------------------
# 建議（預設 localhost）。只聽內網 IP 與本機，需重啟
listen_addresses = '192.168.59.11, localhost'
# 預設，需重啟
port = 5432
# 建議（預設 100）。每條連線是一個行程、約占 5~10 MB；連線需求大時前面加 PgBouncer，不要無限制調高，需重啟
max_connections = 200
# 預設。保留給 superuser 的連線，連線爆滿時 DBA 還進得去，需重啟
superuser_reserved_connections = 3
# 預設（16+）。保留給 pg_use_reserved_connections 角色（例如監控帳號）的連線，需重啟
reserved_connections = 0
# 預設（PGDG 套件的編譯預設值），需重啟
unix_socket_directories = '/run/postgresql, /tmp'
# 建議（預設 0 = 用 OS 的 7200 秒）。60 秒沒資料就送 keepalive，及早發現斷線的用戶端
tcp_keepalives_idle = 60
# 建議（預設 0 = 用 OS 的 75 秒）
tcp_keepalives_interval = 10
# 建議（預設 0 = 用 OS 的 9 次）
tcp_keepalives_count = 6
# 預設（14+）。查詢執行中定期檢查用戶端是否還在，0 = 不檢查
client_connection_check_interval = 0

#------------------------------------------------------------------------------
# 認證
#------------------------------------------------------------------------------
# 預設
authentication_timeout = 1min
# 預設。不要再用 md5（18 已標為淘汰）
password_encryption = scram-sha-256
# 預設。TLS 見安全篇
ssl = off

#------------------------------------------------------------------------------
# 記憶體
#------------------------------------------------------------------------------
# 建議（預設 128MB）。實體記憶體的 25%，其餘交給 OS page cache，需重啟
shared_buffers = 4GB
# 預設。OS 設好 vm.nr_hugepages 後建議改 on（未實測），需重啟
huge_pages = try
# 預設（0 = 用 OS 預設的 huge page 大小），需重啟
huge_page_size = 0
# 預設。每個連線的暫存表緩衝區
temp_buffers = 8MB
# 預設。沒用兩階段提交（PREPARE TRANSACTION）就維持 0，需重啟
max_prepared_transactions = 0
# 建議（預設 4MB）。每個排序 / 雜湊「節點」各自可用，一條查詢可能用好幾份，
# 估算：(RAM - shared_buffers) / (max_connections × 3)；報表類查詢用 SET work_mem 個別調高
work_mem = 16MB
# 預設。雜湊操作可用 work_mem × 2
hash_mem_multiplier = 2.0
# 建議（預設 64MB）。VACUUM、CREATE INDEX、ALTER TABLE ADD FOREIGN KEY 用，加快維護作業
maintenance_work_mem = 1GB
# 預設（-1 = 用 maintenance_work_mem）。autovacuum 每個 worker 各自可用
autovacuum_work_mem = -1
# 預設。邏輯解碼在溢出到磁碟前可用的記憶體
logical_decoding_work_mem = 64MB
# 預設，需重啟
shared_memory_type = mmap
# 預設。平行查詢用 /dev/shm，容器要調大 shm_size，需重啟
dynamic_shared_memory_type = posix
# 預設，需重啟
min_dynamic_shared_memory = 0
# 預設（17 從 256kB 調為 2MB）。VACUUM / ANALYZE 使用的環狀緩衝區，避免把 shared_buffers 洗掉
vacuum_buffer_usage_limit = 2MB

#------------------------------------------------------------------------------
# 磁碟與核心資源
#------------------------------------------------------------------------------
# 建議（預設 -1 = 不限制）。單一行程暫存檔上限，避免失控的查詢塞滿磁碟
temp_file_limit = 20GB
# 預設，需重啟
max_files_per_process = 1000

#------------------------------------------------------------------------------
# VACUUM 成本控制
#------------------------------------------------------------------------------
# 預設（0 = 手動 VACUUM 不節流）
vacuum_cost_delay = 0
# 預設
vacuum_cost_page_hit = 1
# 預設（14 起從 10 調為 2）
vacuum_cost_page_miss = 2
# 預設
vacuum_cost_page_dirty = 20
# 預設
vacuum_cost_limit = 200

#------------------------------------------------------------------------------
# 背景寫入（bgwriter）
#------------------------------------------------------------------------------
# 預設。pg_stat_bgwriter 的 maxwritten_clean 持續增加再調高 lru_maxpages
bgwriter_delay = 200ms
# 預設
bgwriter_lru_maxpages = 100
# 預設
bgwriter_lru_multiplier = 2.0
# 預設
bgwriter_flush_after = 512kB

#------------------------------------------------------------------------------
# 非同步 I/O 與平行查詢
#------------------------------------------------------------------------------
# 預設
backend_flush_after = 0
# 建議（預設 1）。SSD / NVMe 可同時處理大量 I/O，影響 bitmap heap scan 的預讀
effective_io_concurrency = 200
# 建議（預設 10）。同上，用於 VACUUM 等維護作業
maintenance_io_concurrency = 200
# 預設（17+）。一次合併讀取的最大 I/O 大小
io_combine_limit = 128kB
# 建議（預設 8）。背景行程總數上限，要容納平行查詢、邏輯複製、擴充套件的 worker，需重啟
max_worker_processes = 16
# 建議（預設 2）。單一查詢最多幾個平行 worker；OLTP 為主時 2~4
max_parallel_workers_per_gather = 4
# 建議（預設 2）。CREATE INDEX 等維護作業的平行 worker
max_parallel_maintenance_workers = 4
# 預設（8）。全系統同時可用的平行 worker，通常等於 vCPU 數
max_parallel_workers = 8
# 預設
parallel_leader_participation = on

#------------------------------------------------------------------------------
# WAL
#------------------------------------------------------------------------------
# 預設。要做 streaming replication 與 PITR 至少要 replica，需重啟
wal_level = replica
# 預設。絕對不要關，關了當機可能讓資料庫損毀
fsync = on
# 預設。off 可大幅提升寫入速度，但當機可能遺失最近的交易（不會損毀）；可以針對單一交易 SET
synchronous_commit = on
# 預設（Linux）
wal_sync_method = fdatasync
# 預設。不要關，否則部分寫入的頁面會讓資料庫損毀
full_page_writes = on
# 預設。initdb 已開 data checksums，pg_rewind 不需要再開，需重啟
wal_log_hints = off
# 建議（預設 off）。壓縮 full page image，減少 WAL 量與 I/O，CPU 多一點；lz4 比 pglz 快
wal_compression = lz4
# 預設
wal_init_zero = on
# 預設
wal_recycle = on
# 預設（-1 = shared_buffers 的 1/32，最多 16MB），需重啟
wal_buffers = -1
# 預設
wal_writer_delay = 200ms
# 預設
wal_writer_flush_after = 1MB
# 預設（不延遲）。大量小交易並行時可設 10~100 微秒做群組提交，要壓測確認
commit_delay = 0
# 預設
commit_siblings = 5

#------------------------------------------------------------------------------
# Checkpoint
#------------------------------------------------------------------------------
# 建議（預設 5min）。拉長間隔減少 full page write 與 I/O 尖峰，代價是當機復原時間變長
checkpoint_timeout = 15min
# 預設（14 起為 0.9）。把 checkpoint 的寫入分散到 90% 的間隔時間
checkpoint_completion_target = 0.9
# 預設
checkpoint_flush_after = 256kB
# 預設。WAL 量觸發的 checkpoint 間隔小於 30 秒就在日誌警告，代表 max_wal_size 太小
checkpoint_warning = 30s
# 建議（預設 1GB）。讓 checkpoint 主要由 checkpoint_timeout 觸發，而不是 WAL 量
max_wal_size = 8GB
# 建議（預設 80MB）。保留回收的 WAL 檔，減少重新建立檔案
min_wal_size = 2GB

#------------------------------------------------------------------------------
# WAL 歸檔（PITR 用，見備份篇），需重啟
#------------------------------------------------------------------------------
# 建議（預設 off）
archive_mode = on
# 建議（預設空）。正式環境請改用 pgBackRest / WAL-G 並放到另一台主機或物件儲存
archive_command = 'test ! -f /var/lib/pgsql/17/archive/%f && cp %p /var/lib/pgsql/17/archive/%f'
# 預設（0 = 不強制切換）。寫入很少時可設 5min，限制最大資料遺失時間
archive_timeout = 0

#------------------------------------------------------------------------------
# 複製（Standalone 沒有從庫時也先準備好，日後加從庫不用重啟）
#------------------------------------------------------------------------------
# 預設，需重啟
max_wal_senders = 10
# 預設，需重啟
max_replication_slots = 10
# 預設。用 replication slot 保留 WAL 時不需要另外保留
wal_keep_size = 0
# 建議（預設 -1 = 不限制）。slot 卡住時最多保留 50GB WAL，避免塞滿磁碟
max_slot_wal_keep_size = 50GB
# 預設
wal_sender_timeout = 60s
# 預設。開了每筆交易多寫一點資料，需重啟
track_commit_timestamp = off

#------------------------------------------------------------------------------
# 查詢規劃
#------------------------------------------------------------------------------
# 預設
seq_page_cost = 1.0
# 建議（預設 4.0）。SSD 隨機讀幾乎和循序讀一樣快，調低讓規劃器更願意用索引
random_page_cost = 1.1
# 預設
cpu_tuple_cost = 0.01
# 預設
cpu_index_tuple_cost = 0.005
# 預設
cpu_operator_cost = 0.0025
# 建議（預設 4GB）。告訴規劃器 OS cache + shared_buffers 大約有多大，不會實際配置記憶體；抓 RAM 的 75%
effective_cache_size = 12GB
# 預設。資料分布不均的欄位可用 ALTER TABLE ... SET STATISTICS 個別調高
default_statistics_target = 100
# 建議（預設 on）。OLTP 短查詢的 JIT 編譯成本常大於收益（PGDG 的 JIT 在另一個 postgresql17-llvmjit 套件）
jit = off
# 預設
plan_cache_mode = auto

#------------------------------------------------------------------------------
# 日誌
#------------------------------------------------------------------------------
# 預設
log_destination = 'stderr'
# 建議（預設 off）。由 PostgreSQL 自己寫檔與輪替，需重啟
logging_collector = on
# 預設（相對於 data 目錄）
log_directory = 'log'
# 建議（預設 postgresql-%Y-%m-%d_%H%M%S.log）。每天一個檔
log_filename = 'postgresql-%Y-%m-%d.log'
# 預設
log_rotation_age = 1d
# 建議（預設 10MB）。只依日期輪替，避免同一天被切成很多檔
log_rotation_size = 0
# 建議（預設 off）。同名檔案（例如改用 %a 星期幾）覆寫而不是附加
log_truncate_on_rotation = on
# 建議（預設 -1 = 不記錄）。記錄超過 1 秒的 SQL，慢查詢分析的基礎；10 ms 級的分析用 pg_stat_statements
log_min_duration_statement = 1s
# 預設（15+ 預設開）。記錄每次 checkpoint 的寫入量與耗時
log_checkpoints = on
# 預設。連線很頻繁時開啟會產生大量日誌，建議用 PgBouncer 後再開
log_connections = off
# 預設
log_disconnections = off
# 建議（預設 off）。等鎖超過 deadlock_timeout（1s）就記錄
log_lock_waits = on
# 建議（預設 -1）。記錄所有用到暫存檔的查詢，代表 work_mem 不夠
log_temp_files = 0
# 建議（預設 10min）。記錄執行超過 1 秒的 autovacuum，觀察 vacuum 是否跟得上
log_autovacuum_min_duration = 1s
# 建議（預設 '%m [%p] '）。加上使用者、資料庫、應用程式名稱與來源 IP
log_line_prefix = '%m [%p] %q%u@%d/%a %h '
# 預設。DDL 可設 ddl 留下紀錄
log_statement = 'none'
# 建議（預設 GMT）
log_timezone = 'Asia/Taipei'

#------------------------------------------------------------------------------
# 統計資訊
#------------------------------------------------------------------------------
# 預設
track_activities = on
# 預設。autovacuum 需要，不能關
track_counts = on
# 建議（預設 off）。記錄 I/O 耗時，EXPLAIN (BUFFERS) 與 pg_stat_io 才有時間；先用 pg_test_timing 確認時鐘開銷低
track_io_timing = on
# 建議（預設 off）。記錄 WAL 寫入耗時
track_wal_io_timing = on
# 建議（預設 none）。統計 PL/pgSQL 函式的呼叫次數與耗時
track_functions = 'pl'
# 建議（預設 1024）。pg_stat_activity 顯示的 SQL 長度，需重啟
track_activity_query_size = 4096
# 預設。pg_stat_statements 載入時自動計算 query id
compute_query_id = auto

#------------------------------------------------------------------------------
# 擴充套件（需安裝 postgresql17-contrib），需重啟
#------------------------------------------------------------------------------
# 建議（預設空）。SQL 執行統計，效能分析必備
shared_preload_libraries = 'pg_stat_statements'
# 預設（5000）。保留幾種 SQL 的統計
pg_stat_statements.max = 5000
# 預設。只統計最外層的 SQL
pg_stat_statements.track = top

#------------------------------------------------------------------------------
# Autovacuum
#------------------------------------------------------------------------------
# 預設。絕對不要關
autovacuum = on
# 建議（預設 3）。表多、更新多時增加 worker；成本額度由所有 worker 平分，要搭配 cost_limit 一起調，需重啟
autovacuum_max_workers = 4
# 預設
autovacuum_naptime = 1min
# 預設
autovacuum_vacuum_threshold = 50
# 建議（預設 0.2）。死 tuple 超過 5% 就 vacuum；預設 20% 對大表太晚，膨脹嚴重
autovacuum_vacuum_scale_factor = 0.05
# 預設（13+）。只有 INSERT 的表也會被 vacuum（更新 visibility map、提前凍結）
autovacuum_vacuum_insert_threshold = 1000
# 預設
autovacuum_vacuum_insert_scale_factor = 0.2
# 預設
autovacuum_analyze_threshold = 50
# 建議（預設 0.1）。統計資訊更新得更頻繁，執行計畫比較不會走歪
autovacuum_analyze_scale_factor = 0.05
# 預設。超過就強制做防止 XID 回捲的 vacuum，需重啟
autovacuum_freeze_max_age = 200000000
# 預設，需重啟
autovacuum_multixact_freeze_max_age = 400000000
# 預設（12+ 為 2ms）
autovacuum_vacuum_cost_delay = 2ms
# 建議（預設 -1 = 用 vacuum_cost_limit 的 200）。SSD 上 200 太保守，大表 vacuum 跟不上
autovacuum_vacuum_cost_limit = 2000
# 預設
vacuum_freeze_min_age = 50000000
# 預設
vacuum_freeze_table_age = 150000000
# 預設。XID 年齡超過就略過節流，全速 vacuum 避免回捲
vacuum_failsafe_age = 1600000000

#------------------------------------------------------------------------------
# 用戶端連線預設值
#------------------------------------------------------------------------------
# 預設（不限制）。建議針對應用帳號設：ALTER ROLE app SET statement_timeout = '30s'
statement_timeout = 0
# 預設。DDL 建議在 session 裡 SET lock_timeout = '3s'，避免卡住整張表
lock_timeout = 0
# 建議（預設 0）。交易開著不動 10 分鐘就斷線，避免擋住 vacuum 與持有鎖
idle_in_transaction_session_timeout = 10min
# 預設
idle_session_timeout = 0
# 預設（17+）。整個交易的時間上限
transaction_timeout = 0
# 建議（預設 pglz）。TOAST 壓縮改用 lz4，壓縮 / 解壓縮快很多
default_toast_compression = lz4
# 預設
deadlock_timeout = 1s
# 預設。standby 要 ≥ 主庫，需重啟
max_locks_per_transaction = 64

#------------------------------------------------------------------------------
# 地區與格式（initdb 會依 --locale 產生，這裡寫死）
#------------------------------------------------------------------------------
# 建議（預設 GMT）
timezone = 'Asia/Taipei'
# initdb 產生
datestyle = 'iso, mdy'
# initdb 產生。日誌維持英文方便搜尋
lc_messages = 'C.UTF-8'
# initdb 產生
lc_monetary = 'C.UTF-8'
# initdb 產生
lc_numeric = 'C.UTF-8'
# initdb 產生
lc_time = 'C.UTF-8'
# initdb 產生
default_text_search_config = 'pg_catalog.english'
```

主機規格不同時，主要調整下面這幾個，其他維持上面的值即可：

| 實體記憶體 | `shared_buffers` | `effective_cache_size` | `work_mem`（200 連線） | `maintenance_work_mem` |
| :--- | :--- | :--- | :--- | :--- |
| 8 GB | 2GB | 6GB | 8MB | 512MB |
| 16 GB | 4GB | 12GB | 16MB | 1GB |
| 32 GB | 8GB | 24GB | 32MB | 2GB |
| 64 GB | 16GB | 48GB | 64MB | 2GB |

| vCPU | `max_worker_processes` | `max_parallel_workers` | `max_parallel_workers_per_gather` | `max_parallel_maintenance_workers` |
| :--- | :--- | :--- | :--- | :--- |
| 4 | 8 | 4 | 2 | 2 |
| 8 | 16 | 8 | 4 | 4 |
| 16 | 24 | 16 | 4 | 4 |
| 32 | 40 | 32 | 8 | 8 |

- `work_mem` 的最壞情況是「連線數 × 每條查詢的排序 / 雜湊節點數 × work_mem」，表格的值以 200 條連線、OLTP 為準；連線用 PgBouncer 收斂後可以再提高。
- `shared_buffers` 超過 8 GB 時強烈建議設定 Huge Pages。
- 機械硬碟把 `random_page_cost` 改回 4、`effective_io_concurrency` 改成 2。

### pg_hba.conf

```text
# /var/lib/pgsql/17/data/pg_hba.conf（Standalone）
# 由上往下比對，第一筆符合的就用；改完 systemctl reload postgresql-17 即可生效
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# 本機 Unix socket：作業系統的 postgres 帳號免密碼（peer），其他帳號要密碼
local   all             postgres                                peer
local   all             all                                     scram-sha-256
# 本機 TCP
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# 應用程式網段（依實際網段修改），只用 scram-sha-256，不要用 trust 或 md5
host    all             all             192.168.59.0/24         scram-sha-256
# 其他來源一律拒絕（沒有符合的規則本來就會拒絕，寫出來比較清楚）
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject
```

initdb 預設產生的 pg_hba.conf 只允許本機連線，而且 `local` 對**所有帳號**都用 `peer`：

```text
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
```

換成上面的版本後，只有作業系統的 `postgres` 帳號能免密碼登入，其他帳號（包括本機）都要 SCRAM 密碼，應用網段之外一律拒絕。

```console
[pg1]# cd /var/lib/pgsql/17/data && cp postgresql.conf postgresql.conf.initdb && cp pg_hba.conf pg_hba.conf.initdb && install -o postgres -g postgres -m 600 /root/conf/postgresql-standalone.conf postgresql.conf && install -o postgres -g postgres -m 600 /root/conf/pg_hba-standalone.conf pg_hba.conf && ls -l postgresql.conf pg_hba.conf
-rw------- 1 postgres postgres  1053 Oct 24 07:18 pg_hba.conf
-rw------- 1 postgres postgres 16260 Oct 24 07:18 postgresql.conf

[pg1]# grep -Ev "^\s*(#|$)" /var/lib/pgsql/17/data/postgresql.conf | wc -l
143
```

## 步驟 4：systemd

PGDG 套件已經附上 unit 檔，不需要自己寫：

```console
[pg1]# systemctl cat postgresql-17 | grep -Ev "^\s*(#|$)"
[Unit]
Description=PostgreSQL 17 database server
Documentation=https://www.postgresql.org/docs/17/static/
After=syslog.target
After=network-online.target
[Service]
Type=notify
User=postgres
Group=postgres
Environment=PGDATA=/var/lib/pgsql/17/data/
OOMScoreAdjust=-1000
Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PG_OOM_ADJUST_VALUE=0
ExecStartPre=/usr/pgsql-17/bin/postgresql-17-check-db-dir ${PGDATA}
ExecStart=/usr/pgsql-17/bin/postgres -D ${PGDATA}
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed
KillSignal=SIGINT
Restart=on-failure
TimeoutSec=0
TimeoutStartSec=0
TimeoutStopSec=1h
[Install]
WantedBy=multi-user.target
```

| 設定 | 說明 |
| :--- | :--- |
| `Type=notify` | PostgreSQL 完成啟動（含 crash recovery）才回報 systemd |
| `OOMScoreAdjust=-1000` + `PG_OOM_ADJUST_VALUE=0` | postmaster 不會被 OOM Killer 選中，子行程恢復成 0 |
| `KillSignal=SIGINT` | `systemctl stop` 送 SIGINT，等於 `pg_ctl stop -m fast`：中止連線、做 checkpoint 後關機 |
| `TimeoutStartSec=0` | 啟動不限時間，crash recovery 可能很久 |
| `TimeoutStopSec=1h` | 關機最多等 1 小時 |
| `Restart=on-failure` | 異常結束時自動重啟 |

需要改的話用 drop-in，不要直接改 `/usr/lib/systemd/system/postgresql-17.service`（套件更新會覆蓋）：

```bash
sudo systemctl edit postgresql-17     # 產生 /etc/systemd/system/postgresql-17.service.d/override.conf
```

啟動：

```console
[pg1]# systemctl enable --now postgresql-17
Created symlink /etc/systemd/system/multi-user.target.wants/postgresql-17.service → /usr/lib/systemd/system/postgresql-17.service.

[pg1]# systemctl status postgresql-17 --no-pager | head -12
● postgresql-17.service - PostgreSQL 17 database server
     Loaded: loaded (/usr/lib/systemd/system/postgresql-17.service; enabled; preset: disabled)
     Active: active (running) since Sat 2026-10-24 07:18:36 UTC; 69ms ago
       Docs: https://www.postgresql.org/docs/17/static/
    Process: 762 ExecStartPre=/usr/pgsql-17/bin/postgresql-17-check-db-dir ${PGDATA} (code=exited, status=0/SUCCESS)
   Main PID: 767 (postgres)
      Tasks: 8 (limit: 51007)
     Memory: 120.1M (peak: 120.7M)
        CPU: 40ms
     CGroup: /docker/156c6767cb94efa79f592e0ee1ced63294b447ccfe292563c8346e2dc433ff32/system.slice/postgresql-17.service
             ├─767 /usr/pgsql-17/bin/postgres -D /var/lib/pgsql/17/data/
             ├─768 "postgres: logger "

[pg1]# ls /var/lib/pgsql/17/data/log/; cat /var/lib/pgsql/17/data/log/postgresql-*.log
postgresql-2026-10-24.log
2026-10-24 15:18:36.397 CST [767] LOG:  starting PostgreSQL 17.11 on aarch64-unknown-linux-gnu, compiled by gcc (GCC) 11.5.0 20240719 (Red Hat 11.5.0-14), 64-bit
2026-10-24 15:18:36.397 CST [767] LOG:  listening on IPv4 address "192.168.59.11", port 5432
2026-10-24 15:18:36.398 CST [767] LOG:  listening on IPv6 address "::1", port 5432
2026-10-24 15:18:36.398 CST [767] LOG:  listening on IPv4 address "127.0.0.1", port 5432
2026-10-24 15:18:36.398 CST [767] LOG:  listening on Unix socket "/run/postgresql/.s.PGSQL.5432"
2026-10-24 15:18:36.399 CST [767] LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
2026-10-24 15:18:36.400 CST [771] LOG:  database system was shut down at 2026-10-24 15:18:35 CST
2026-10-24 15:18:36.402 CST [767] LOG:  database system is ready to accept connections
```

日誌在 `$PGDATA/log/postgresql-2026-10-24.log`，時間是台北時間（`CST`）。

## 步驟 5：驗證

### 版本與關鍵參數

```console
[pg1] postgres=# SELECT version();
                                                     version                                                      
------------------------------------------------------------------------------------------------------------------
 PostgreSQL 17.11 on aarch64-unknown-linux-gnu, compiled by gcc (GCC) 11.5.0 20240719 (Red Hat 11.5.0-14), 64-bit
(1 row)


[pg1] postgres=# SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem','max_connections','wal_buffers','max_wal_size','random_page_cost','effective_io_concurrency','huge_pages','wal_compression','data_checksums','shared_preload_libraries','jit') ORDER BY name;
           name           |      setting       | unit 
--------------------------+--------------------+------
 data_checksums           | on                 | 
 effective_cache_size     | 1572864            | 8kB
 effective_io_concurrency | 200                | 
 huge_pages               | try                | 
 jit                      | off                | 
 maintenance_work_mem     | 1048576            | kB
 max_connections          | 200                | 
 max_wal_size             | 8192               | MB
 random_page_cost         | 1.1                | 
 shared_buffers           | 524288             | 8kB
 shared_preload_libraries | pg_stat_statements | 
 wal_buffers              | 2048               | 8kB
 wal_compression          | lz4                | 
 work_mem                 | 16384              | kB
(14 rows)


[pg1] postgres=# SHOW huge_pages_status;
 huge_pages_status 
-------------------
 off
(1 row)
```

- `shared_buffers` 的 `524288 × 8kB = 4GB`、`effective_cache_size` 的 `1572864 × 8kB = 12GB`。
- `wal_buffers` 的 `-1` 自動算成 `2048 × 8kB = 16MB`（shared_buffers 的 1/32，上限 16MB）。
- `huge_pages_status = off`：容器內沒有 Huge Pages，`try` 退回一般記憶體。

### 設定檔與實際值比對

```console
[pg1]# /root/bin/checkconf.sh /var/lib/pgsql/17/data/postgresql.conf
--- pg_file_settings：沒有套用或有錯誤的設定（空的代表全部套用）
 sourceline | name | setting | applied | error 
------------+------+---------+---------+-------
(0 rows)

--- 設定檔參數數量與標記
  tag   | count 
--------+-------
 initdb |     6
 建議   |    46
 預設   |    91
(3 rows)

--- 需要確認的項目（CHECK）；UNKNOWN 代表這個版本沒有這個參數
 line | tag  |          name           | setting | boot_val | unit |       source       |    result     
------+------+-------------------------+---------+----------+------+--------------------+---------------
   25 | 建議 | tcp_keepalives_idle     | 0       | 0        | s    | configuration file | CHECK
   27 | 建議 | tcp_keepalives_interval | 0       | 0        | s    | configuration file | CHECK
   29 | 建議 | tcp_keepalives_count    | 0       | 0        |      | configuration file | CHECK
  154 | 預設 | wal_buffers             | 2048    | -1       | 8kB  | override           | CHECK(source)
(4 rows)

--- 標「建議」的參數：實際值與預設值（boot_val，單位見 unit）
                name                 |                                   setting                                    |            boot_val            | unit 
-------------------------------------+------------------------------------------------------------------------------+--------------------------------+------
 listen_addresses                    | 192.168.59.11, localhost                                                     | localhost                      | 
 max_connections                     | 200                                                                          | 100                            | 
 tcp_keepalives_idle                 | 0                                                                            | 0                              | s
 tcp_keepalives_interval             | 0                                                                            | 0                              | s
 tcp_keepalives_count                | 0                                                                            | 0                              | 
 shared_buffers                      | 524288                                                                       | 16384                          | 8kB
 work_mem                            | 16384                                                                        | 4096                           | kB
 maintenance_work_mem                | 1048576                                                                      | 65536                          | kB
 temp_file_limit                     | 20971520                                                                     | -1                             | kB
 effective_io_concurrency            | 200                                                                          | 1                              | 
 maintenance_io_concurrency          | 200                                                                          | 10                             | 
 max_worker_processes                | 16                                                                           | 8                              | 
 max_parallel_workers_per_gather     | 4                                                                            | 2                              | 
 max_parallel_maintenance_workers    | 4                                                                            | 2                              | 
 wal_compression                     | lz4                                                                          | off                            | 
 checkpoint_timeout                  | 900                                                                          | 300                            | s
 max_wal_size                        | 8192                                                                         | 1024                           | MB
 min_wal_size                        | 2048                                                                         | 80                             | MB
 archive_mode                        | on                                                                           | off                            | 
 archive_command                     | test ! -f /var/lib/pgsql/17/archive/%f && cp %p /var/lib/pgsql/17/archive/%f |                                | 
 max_slot_wal_keep_size              | 51200                                                                        | -1                             | MB
 random_page_cost                    | 1.1                                                                          | 4                              | 
 effective_cache_size                | 1572864                                                                      | 524288                         | 8kB
 jit                                 | off                                                                          | on                             | 
 logging_collector                   | on                                                                           | off                            | 
 log_filename                        | postgresql-%Y-%m-%d.log                                                      | postgresql-%Y-%m-%d_%H%M%S.log | 
 log_rotation_size                   | 0                                                                            | 10240                          | kB
 log_truncate_on_rotation            | on                                                                           | off                            | 
 log_min_duration_statement          | 1000                                                                         | -1                             | ms
 log_lock_waits                      | on                                                                           | off                            | 
 log_temp_files                      | 0                                                                            | -1                             | kB
 log_autovacuum_min_duration         | 1000                                                                         | 600000                         | ms
 log_line_prefix                     | %m [%p] %q%u@%d/%a %h                                                        | %m [%p]                        | 
 log_timezone                        | Asia/Taipei                                                                  | GMT                            | 
 track_io_timing                     | on                                                                           | off                            | 
 track_wal_io_timing                 | on                                                                           | off                            | 
 track_functions                     | pl                                                                           | none                           | 
 track_activity_query_size           | 4096                                                                         | 1024                           | B
 shared_preload_libraries            | pg_stat_statements                                                           |                                | 
 autovacuum_max_workers              | 4                                                                            | 3                              | 
 autovacuum_vacuum_scale_factor      | 0.05                                                                         | 0.2                            | 
 autovacuum_analyze_scale_factor     | 0.05                                                                         | 0.1                            | 
 autovacuum_vacuum_cost_limit        | 2000                                                                         | -1                             | 
 idle_in_transaction_session_timeout | 600000                                                                       | 0                              | ms
 default_toast_compression           | lz4                                                                          | pglz                           | 
 timezone                            | Asia/Taipei                                                                  | GMT                            | 
(46 rows)
```

- `pg_file_settings` 沒有任何錯誤或未套用的設定。
- 標「預設」的 91 個參數，實際值全部等於 17.11 的編譯預設值；`wal_buffers` 的 source 是 `override`，因為 `-1` 會被自動換算，屬正常。
- 標「建議」的 46 個參數都和預設值不同（表格的最後一段）。
- `tcp_keepalives_*` 顯示 0 不是設定沒生效：檢查腳本透過 Unix socket 連線，這三個參數只對 TCP 連線有意義，socket 連線上永遠是 0。改用 TCP 連線查詢就是設定值：

```console
[pg1]# PGPASSWORD=ChangeMe_App_2026 psql -X -h 127.0.0.1 -U app -d appdb -Atc "SELECT name, setting FROM pg_settings WHERE name LIKE 'tcp_keepalives%' ORDER BY 1"
tcp_keepalives_count|6
tcp_keepalives_idle|60
tcp_keepalives_interval|10
```

### locale、帳號、認證

```console
[pg1] postgres=# SELECT datname, encoding::int, pg_encoding_to_char(encoding) AS enc, datlocprovider, datlocale, datcollate, datctype FROM pg_database ORDER BY datname;
  datname  | encoding | enc  | datlocprovider | datlocale | datcollate | datctype 
-----------+----------+------+----------------+-----------+------------+----------
 postgres  |        6 | UTF8 | b              | C.UTF-8   | C.UTF-8    | C.UTF-8
 template0 |        6 | UTF8 | b              | C.UTF-8   | C.UTF-8    | C.UTF-8
 template1 |        6 | UTF8 | b              | C.UTF-8   | C.UTF-8    | C.UTF-8
(3 rows)



======== 建立應用帳號與資料庫 ========  (2026-10-24 15:18:36)
[pg1] postgres=# CREATE ROLE app LOGIN PASSWORD 'ChangeMe_App_2026';
CREATE ROLE

[pg1] postgres=# CREATE DATABASE appdb OWNER app;
CREATE DATABASE

[pg1] appdb=# CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION

[pg1] postgres=# SELECT rolname, left(rolpassword, 14) AS pw_prefix FROM pg_authid WHERE rolname = 'app';
 rolname |   pw_prefix    
---------+----------------
 app     | SCRAM-SHA-256$
(1 row)


[pg1]# PGPASSWORD=ChangeMe_App_2026 psql -X -h 192.168.59.11 -U app -d appdb -c "SELECT current_user, inet_server_addr(), ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();"
 current_user | inet_server_addr | ssl 
--------------+------------------+-----
 app          | 192.168.59.11    | f
(1 row)


[pg1]# PGPASSWORD=wrong psql -X -h 127.0.0.1 -U app -d appdb -c "SELECT 1"; tail -2 /var/lib/pgsql/17/data/log/postgresql-*.log
psql: error: connection to server at "127.0.0.1", port 5432 failed: FATAL:  password authentication failed for user "app"
2026-10-24 15:18:37.437 CST [881] app@appdb/[unknown] 127.0.0.1 FATAL:  password authentication failed for user "app"
2026-10-24 15:18:37.437 CST [881] app@appdb/[unknown] 127.0.0.1 DETAIL:  Connection matched file "/var/lib/pgsql/17/data/pg_hba.conf" line 9: "host    all             all             127.0.0.1/32            scram-sha-256"
```

- `datlocprovider = b`（builtin）、`datlocale = C.UTF-8`。
- 密碼以 `SCRAM-SHA-256$` 開頭儲存。
- 錯誤密碼被拒絕，日誌的 `DETAIL` 會指出是 pg_hba.conf 的哪一行規則，排查連線問題很好用。

### pgbench

容器內的數字只用來確認服務正常，**不代表正式主機的效能**：

```console
[pg1]# PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -i -s 20 -q appdb 2>&1 | tail -3
vacuuming...
creating primary keys...
done in 1.14 s (drop tables 0.00 s, create tables 0.00 s, client-side generate 0.85 s, vacuum 0.06 s, primary keys 0.22 s).

[pg1]# PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -c 16 -j 4 -T 30 -P 10 appdb 2>&1 | grep -vE "^pgbench \(|^starting"
progress: 10.0 s, 13879.2 tps, lat 1.145 ms stddev 0.585, 0 failed
progress: 20.0 s, 13903.4 tps, lat 1.145 ms stddev 0.681, 0 failed
progress: 30.0 s, 13391.0 tps, lat 1.189 ms stddev 0.597, 0 failed
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 20
query mode: simple
number of clients: 16
number of threads: 4
maximum number of tries: 1
duration: 30 s
number of transactions actually processed: 411750
number of failed transactions: 0 (0.000%)
latency average = 1.159 ms
latency stddev = 0.624 ms
initial connection time = 19.023 ms
tps = 13730.092491 (without initial connection time)

[pg1]# PGPASSWORD=ChangeMe_App_2026 pgbench -h 127.0.0.1 -U app -c 16 -j 4 -T 20 -S appdb 2>&1 | grep -E "^(tps|latency average|number of transactions actually)"
number of transactions actually processed: 4169767
latency average = 0.077 ms
tps = 208635.344032 (without initial connection time)

[pg1] appdb=# SELECT left(query, 60) AS query, calls, round(mean_exec_time::numeric, 3) AS mean_ms, round(total_exec_time::numeric) AS total_ms FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;
                            query                             |  calls  | mean_ms | total_ms 
--------------------------------------------------------------+---------+---------+----------
 UPDATE pgbench_branches SET bbalance = bbalance + $1 WHERE b |  411750 |   0.189 |    77715
 SELECT abalance FROM pgbench_accounts WHERE aid = $1         | 4581517 |   0.005 |    23181
 UPDATE pgbench_tellers SET tbalance = tbalance + $1 WHERE ti |  411750 |   0.034 |    13991
 UPDATE pgbench_accounts SET abalance = abalance + $1 WHERE a |  411750 |   0.011 |     4613
 INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VA |  411750 |   0.003 |     1125
(5 rows)
```

`pg_stat_statements` 已經在收集統計，排在第一的 `UPDATE pgbench_branches` 是 TPC-B 的熱點列（scale 20 只有 20 列 branches，16 條連線搶同一批列的鎖）。

### 平行查詢

```console
[pg1] appdb=# EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM pgbench_accounts;
                                                       QUERY PLAN                                                        
-------------------------------------------------------------------------------------------------------------------------
 Finalize Aggregate (actual rows=1 loops=1)
   ->  Gather (actual rows=5 loops=1)
         Workers Planned: 4
         Workers Launched: 4
         ->  Partial Aggregate (actual rows=1 loops=5)
               ->  Parallel Index Only Scan using pgbench_accounts_pkey on pgbench_accounts (actual rows=400000 loops=5)
                     Heap Fetches: 2003501
 Planning Time: 0.160 ms
 Execution Time: 72.136 ms
(9 rows)
```

`Workers Launched: 4`，`max_parallel_workers_per_gather = 4` 生效。平行查詢用 `/dev/shm`（`dynamic_shared_memory_type = posix`），Docker 預設的 `/dev/shm` 只有 64 MB，實測環境把 `shm_size` 設成 1 GB；在 Kubernetes 上也要記得掛一個 `emptyDir`（`medium: Memory`）到 `/dev/shm`。

### 慢查詢、暫存檔、鎖等待日誌

```console
[pg1] appdb=# SELECT pg_sleep(1.2);
 pg_sleep 
----------
 
(1 row)


[pg1] appdb=# SET work_mem = '1MB'; SELECT count(*) FROM (SELECT aid FROM pgbench_accounts ORDER BY abalance, filler) t;
SET
  count  
---------
 2000000
(1 row)


[pg1]# (runuser -u postgres -- psql -X -d appdb -c "BEGIN; LOCK pgbench_branches; SELECT pg_sleep(3); COMMIT;" >/dev/null 2>&1 &) ; sleep 0.5; runuser -u postgres -- psql -X -d appdb -c "UPDATE pgbench_branches SET bbalance = bbalance WHERE bid = 1;"
UPDATE 1

[pg1]# grep -E "duration: [0-9]{4}|temporary file|still waiting|acquired" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -8
2026-10-24 15:19:31.284 CST [1023] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp1023.0", size 40574976
2026-10-24 15:19:31.284 CST [1024] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp1024.0", size 41910272
2026-10-24 15:19:31.284 CST [1025] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp1025.0", size 39034880
2026-10-24 15:19:31.289 CST [1021] postgres@appdb/psql [local] LOG:  temporary file: path "base/pgsql_tmp/pgsql_tmp1021.0", size 41549824
2026-10-24 15:19:32.904 CST [1038] postgres@appdb/psql [local] LOG:  process 1038 still waiting for RowExclusiveLock on relation 16434 of database 16385 after 1004.805 ms at character 8
2026-10-24 15:19:34.449 CST [1036] postgres@appdb/psql [local] LOG:  duration: 3068.584 ms  statement: BEGIN; LOCK pgbench_branches; SELECT pg_sleep(3); COMMIT;
2026-10-24 15:19:34.449 CST [1038] postgres@appdb/psql [local] LOG:  process 1038 acquired RowExclusiveLock on relation 16434 of database 16385 after 2550.420 ms at character 8
2026-10-24 15:19:34.453 CST [1038] postgres@appdb/psql [local] LOG:  duration: 2554.201 ms  statement: UPDATE pgbench_branches SET bbalance = bbalance WHERE bid = 1;
```

- `log_temp_files = 0`：`work_mem` 只有 1MB 時排序落到暫存檔，平行的 worker 各自寫了一個檔。
- `log_lock_waits = on`：等鎖超過 1 秒（`deadlock_timeout`）就記錄 `still waiting`，取得鎖時再記一筆 `acquired`。
- `log_min_duration_statement = 1s`：超過 1 秒的 SQL 都留下 `duration`。

### WAL 歸檔與重啟

```console
[pg1] postgres=# SELECT pg_switch_wal();
 pg_switch_wal 
---------------
 0/1AF48BA8
(1 row)


[pg1]# sleep 2; ls -l /var/lib/pgsql/17/archive | tail -3
-rw------- 1 postgres postgres 16777216 Oct 24 07:19 000000010000000000000018
-rw------- 1 postgres postgres 16777216 Oct 24 07:19 000000010000000000000019
-rw------- 1 postgres postgres 16777216 Oct 24 07:19 00000001000000000000001A

[pg1] postgres=# SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;
 archived_count |    last_archived_wal     | failed_count 
----------------+--------------------------+--------------
             26 | 00000001000000000000001A |            0
(1 row)



======== 重啟後資料仍在 ========  (2026-10-24 15:19:36)
[pg1]# systemctl restart postgresql-17 && runuser -u postgres -- psql -X -d appdb -Atc "SELECT count(*) FROM pgbench_accounts"
2000000
```

`failed_count = 0`，歸檔正常；重啟後 200 萬筆資料都在。

### 時鐘開銷

`track_io_timing = on` 會在每次 I/O 前後取時間，時鐘來源太慢時會拖慢查詢。`pg_test_timing` 確認每次只要約 16 ns：

```console
[pg1]# pg_test_timing -d 1 | head -8
Testing timing overhead for 1 second.
Per loop time including overhead: 16.40 ns
Histogram of timing durations:
  < us   % of total      count
     1     98.37334   59978441
     2      1.62394     990120
     4      0.00013         78
     8      0.00197       1201
```

### 錯誤日誌

```console
[pg1]# grep -E "WARNING|ERROR|FATAL|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log || echo "(none)"
2026-10-24 15:18:37.437 CST [881] app@appdb/[unknown] 127.0.0.1 FATAL:  password authentication failed for user "app"
```

整個測試過程只有刻意製造的密碼錯誤。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `Failed to download metadata for repo 'pgdg18'`、`repomd.xml` 404 | Docker Hub 的 `rockylinux:9` 停在 9.3，PGDG 已不提供 9.3 的套件庫 | 用 `rockylinux/rockylinux:9`；實體機 `dnf upgrade` 到最新 9.x |
| 檢查腳本顯示 `tcp_keepalives_*` 為 0 | Unix socket 連線不適用 TCP keepalive | 用 TCP 連線查詢 |
| 檢查腳本找不到 `timezone`、`datestyle` | `pg_settings` 裡的名稱是 `TimeZone`、`DateStyle`（大小寫不同；設定檔不分大小寫） | 比對時用 `lower(name)` |
| 平行查詢可能出現 `could not resize shared memory segment` | Docker / Kubernetes 的 `/dev/shm` 預設只有 64 MB | `shm_size: 1gb` 或掛記憶體型的 `emptyDir`（實測直接設大，沒有重現錯誤） |

## 驗證方式與結果

**驗證環境**

| 項目 | 內容 |
| :--- | :--- |
| 主機 | MacBook Air M4（Mac16,12），macOS 15.7.4 |
| 容器 | Docker Desktop 4.96.3（Engine 29.9.2），VM 10 CPU / 約 7.7 GB |
| 作業系統 | `rockylinux/rockylinux:9` 映像（Rocky Linux 9.8）+ systemd |
| PostgreSQL | 17.11-1PGDG.rhel9.8（比較用 18.6-1PGDG.rhel9.8），PGDG 套件庫 |
| 架構 | aarch64 |

每台主機是一個 privileged 容器，以 `/usr/sbin/init`（systemd）為 PID 1，所以 `systemctl`、`Type=notify` 都是真實流程。`pg1` 是只有 systemd 的乾淨 Rocky 9.8，步驟 0～5 全部在容器裡照文章執行。建置檔與腳本放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/postgresql-lab)：

```dockerfile
# Rocky Linux 9.8 + systemd（還沒裝 PostgreSQL）：給 pg1 現場照「步驟 1」安裝用
# 注意：Docker Hub 的 rockylinux:9 停在 9.3，PGDG 已不支援，要用 rockylinux/rockylinux:9
FROM rockylinux/rockylinux:9
RUN mkdir -p /etc/sysctl.d \
 && dnf install -y systemd procps-ng iproute hostname which less vim-minimal tzdata diffutils \
 && dnf clean all \
 && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
```

```dockerfile
# Rocky Linux 9.8 + systemd + 依「步驟 1」用 PGDG 套件庫安裝 PostgreSQL 17（Streaming Replication 節點用，尚未 initdb）
FROM pglab-rocky9-base
ARG PG_MAJOR=17
RUN dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm \
 && dnf -qy module disable postgresql \
 && dnf install -y postgresql${PG_MAJOR}-server postgresql${PG_MAJOR}-contrib \
 && dnf clean all
```

```yaml
# pg1：Standalone；pgs1~pgs3：Streaming Replication（1 主 2 從）
x-node: &node
  image: pglab-rocky9-pg17
  pull_policy: never
  privileged: true            # systemd 當 PID 1、sysctl 需要
  cgroup: host
  shm_size: "1gb"             # Docker 預設 /dev/shm 只有 64MB，平行查詢的 dynamic shared memory 會不夠
  volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw", "./conf:/root/conf:ro", "./bin:/root/bin:ro"]
  tmpfs: ["/run", "/run/lock"]
  extra_hosts:
    - "pg1:192.168.59.11"
    - "pgs1:192.168.59.21"
    - "pgs2:192.168.59.22"
    - "pgs3:192.168.59.23"
services:
  pg1:  { <<: *node, image: pglab-rocky9-base, hostname: pg1,  networks: { labnet: { ipv4_address: 192.168.59.11 } } }
  pgs1: { <<: *node, hostname: pgs1, networks: { labnet: { ipv4_address: 192.168.59.21 } } }
  pgs2: { <<: *node, hostname: pgs2, networks: { labnet: { ipv4_address: 192.168.59.22 } } }
  pgs3: { <<: *node, hostname: pgs3, networks: { labnet: { ipv4_address: 192.168.59.23 } } }
networks:
  labnet:
    ipam: { config: [ { subnet: 192.168.59.0/24 } ] }
```

想自己重現的話，把 `tools/postgresql-lab` 整個資料夾複製下來，依序執行 `./00-build.sh`、`./10-standalone.sh`（Streaming Replication 是 `20-`，17 vs 18 的補充驗證是 `30-`），輸出會記錄在 `results/`。

**設定檔的「建議 / 預設」標記怎麼驗證**：`bin/checkconf.sh` 讀取設定檔，依每個參數上一行註解的標記，和 `pg_settings` 比對。標「預設」的參數，實際值必須等於 `boot_val`（編譯預設值）；標「建議」的參數，實際值必須和 `boot_val` 不同；同時檢查 `pg_file_settings` 沒有錯誤。

**驗證項目**

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 1 安裝 | `rpm -qi`、`postgres --version`、`pg_config --configure` | 17.11、簽章 Key ID 與 PGDG 金鑰一致、有 lz4 / systemd | ✅ |
| 2 initdb | `pg_controldata`、`pg_database` | checksums 開啟、builtin locale | ✅ |
| 3 設定檔 | `checkconf.sh` | 沒有錯誤、預設值標記正確 | ✅ 預設 91 項全部一致；建議 46 項全部與預設不同（`tcp_keepalives_*` 另以 TCP 確認） |
| 4 啟動 | `systemctl status`、日誌 | `active (running)`、`ready to accept connections`、沒有 WARNING | ✅ |
| 5 認證 | SCRAM 密碼、錯誤密碼 | 正確密碼可登入、錯誤密碼被拒並記錄規則行號 | ✅ |
| 5 效能參數 | 平行查詢、pgbench | `Workers Launched: 4`、pgbench 沒有失敗交易 | ✅ |
| 5 日誌 | 慢查詢、暫存檔、鎖等待 | 三種日誌都有紀錄 | ✅ |
| 5 歸檔 | `pg_switch_wal()`、`pg_stat_archiver` | `failed_count = 0` | ✅ |
| 5 持久化 | `systemctl restart` | 資料筆數不變 | ✅ |
| 預設值 | 17.11 與 18.6 全新 initdb 後匯出 `pg_settings` | 用來標註設定檔與版本比較 | ✅ 17：384 個參數；18：404 個 |

**錯誤處理紀錄**（對應上方「實測踩到的坑」）：

- `rockylinux:9` 的 PGDG 404：第一次檢查版本時就遇到，改用 9.8 的映像後通過。
- 檢查腳本：第一次跑時 `TimeZone`、`DateStyle` 顯示 UNKNOWN，改成不分大小寫比對；`tcp_keepalives_*` 確認是連線方式造成，另外用 TCP 連線驗證。
- 容器映像沒有 `/etc/sysctl.d` 目錄，在建置檔裡補上（實體機本來就有）。

## 版本差異比較：17.11 vs 18.6

同一台 `pg1` 上另外安裝 18.6，用相同參數 initdb，**這份 17 的 postgresql.conf 在 18 上可以直接啟動**，`pg_file_settings` 沒有錯誤：

```console
[pg1]# runuser -u postgres -- /usr/pgsql-18/bin/initdb -D /var/lib/pgsql/18/data --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8 2>&1 | grep -Ev "^$"
The files belonging to this database system will be owned by user "postgres".
This user must also own the server process.
The database cluster will be initialized with this locale configuration:
  locale provider:   builtin
  default collation: C.UTF-8
  LC_COLLATE:  C.UTF-8
  LC_CTYPE:    C.UTF-8
  LC_MESSAGES: C.UTF-8
  LC_MONETARY: C.UTF-8
  LC_NUMERIC:  C.UTF-8
  LC_TIME:     C.UTF-8
The default text search configuration will be set to "english".
Data page checksums are enabled.
fixing permissions on existing directory /var/lib/pgsql/18/data ... ok
creating subdirectories ... ok
selecting dynamic shared memory implementation ... posix
selecting default "max_connections" ... 100
selecting default "shared_buffers" ... 128MB
selecting default time zone ... Etc/UTC
creating configuration files ... ok
running bootstrap script ... ok
performing post-bootstrap initialization ... ok
syncing data to disk ... ok
initdb: warning: enabling "trust" authentication for local connections
initdb: hint: You can change this by editing pg_hba.conf or using the option -A, or --auth-local and --auth-host, the next time you run initdb.
Success. You can now start the database server using:
    /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/18/data -l logfile start

[pg1]# runuser -u postgres -- /usr/pgsql-18/bin/pg_controldata /var/lib/pgsql/18/data | grep -E "pg_control version|Catalog version|checksum"
pg_control version number:            1800
Catalog version number:               202506291
Data page checksum version:           1
[pg1]# install -d -o postgres -g postgres -m 700 /var/lib/pgsql/18/archive; cd /var/lib/pgsql/18/data && sed -e "s#/var/lib/pgsql/17/#/var/lib/pgsql/18/#g" -e "s/^port = 5432/port = 5433/" -e "s/^listen_addresses = .*/listen_addresses = 'localhost'/" /root/conf/postgresql-standalone.conf > postgresql.conf && chown postgres: postgresql.conf && runuser -u postgres -- /usr/pgsql-18/bin/pg_ctl -D /var/lib/pgsql/18/data -l /var/lib/pgsql/18/startup.log -w start; cat /var/lib/pgsql/18/startup.log
waiting for server to start.... done
server started
2026-10-24 15:19:45.386 CST [1302] LOG:  redirecting log output to logging collector process
2026-10-24 15:19:45.386 CST [1302] HINT:  Future log output will appear in directory "log".

[pg1]# cat /var/lib/pgsql/18/data/log/postgresql-*.log
2026-10-24 15:19:45.386 CST [1302] LOG:  starting PostgreSQL 18.6 on aarch64-unknown-linux-gnu, compiled by gcc (GCC) 11.5.0 20240719 (Red Hat 11.5.0-14), 64-bit
2026-10-24 15:19:45.386 CST [1302] LOG:  listening on IPv6 address "::1", port 5433
2026-10-24 15:19:45.386 CST [1302] LOG:  listening on IPv4 address "127.0.0.1", port 5433
2026-10-24 15:19:45.387 CST [1302] LOG:  listening on Unix socket "/run/postgresql/.s.PGSQL.5433"
2026-10-24 15:19:45.388 CST [1302] LOG:  listening on Unix socket "/tmp/.s.PGSQL.5433"
2026-10-24 15:19:45.389 CST [1309] LOG:  database system was shut down at 2026-10-24 15:19:44 CST
2026-10-24 15:19:45.391 CST [1302] LOG:  database system is ready to accept connections
[pg1]# /root/bin/checkconf.sh /var/lib/pgsql/18/data/postgresql.conf 5433 /usr/pgsql-18/bin/psql
--- pg_file_settings：沒有套用或有錯誤的設定（空的代表全部套用）
 sourceline | name | setting | applied | error 
------------+------+---------+---------+-------
(0 rows)

--- 設定檔參數數量與標記
  tag   | count 
--------+-------
 initdb |     6
 建議   |    46
 預設   |    91
(3 rows)

--- 需要確認的項目（CHECK）；UNKNOWN 代表這個版本沒有這個參數
 line | tag  |          name           |  setting  | boot_val  | unit |       source       |    result     
------+------+-------------------------+-----------+-----------+------+--------------------+---------------
   13 | 建議 | listen_addresses        | localhost | localhost |      | configuration file | CHECK
   15 | 預設 | port                    | 5433      | 5432      |      | configuration file | CHECK
   25 | 建議 | tcp_keepalives_idle     | 0         | 0         | s    | configuration file | CHECK
   27 | 建議 | tcp_keepalives_interval | 0         | 0         | s    | configuration file | CHECK
   29 | 建議 | tcp_keepalives_count    | 0         | 0         |      | configuration file | CHECK
  154 | 預設 | wal_buffers             | 2048      | -1        | 8kB  | override           | CHECK(source)
  250 | 預設 | log_connections         | off       |           |      | configuration file | CHECK
(7 rows)
```

18 的 initdb 沒有加 `--data-checksums`，`Data page checksum version` 仍然是 `1`：**18 預設就開 checksums**（直接呼叫 initdb 而不是透過 `postgresql-18-setup`，所以多了 `trust` 認證的警告，這是 initdb 不帶 `-A` 時的固定提醒）。檢查結果中，`listen_addresses`、`port` 是為了和 17 同時執行而刻意改的；值得注意的是 `log_connections`：18 把它從布林值改成「要記錄哪些階段」的清單，預設是空字串，設定檔裡的 `off` 仍然被接受，效果相同。

兩版全新 initdb 後的 `pg_settings`（`boot_val`）比對：

| 項目 | 17.11 | 18.6 |
| :--- | :--- | :--- |
| 參數數量 | 384 | 404（新增 21、移除 1） |
| 移除 | — | `ssl_ecdh_curve`（改為 `ssl_groups`，預設 `X25519:prime256v1`，可設多個） |
| 預設值改變 | `effective_io_concurrency 1`、`maintenance_io_concurrency 10` | 兩者都改為 `16` |
| 預設值改變 | `log_connections off` | 空字串（清單型別，例如 `'receipt,authentication,authorization,setup_durations'`） |
| 新增：非同步 I/O | — | `io_method worker`、`io_workers 3`、`io_max_concurrency -1`、`io_max_combine_limit 16`（× 8kB = 128kB） |
| 新增：autovacuum / vacuum | — | `autovacuum_worker_slots 16`、`autovacuum_vacuum_max_threshold 100000000`、`vacuum_max_eager_freeze_failure_rate 0.03`、`vacuum_truncate on`、`track_cost_delay_timing off` |
| 新增：規劃器 | — | `enable_self_join_elimination on`、`enable_distinct_reordering on` |
| 新增：複製 | — | `idle_replication_slot_timeout 0`、`max_active_replication_origins 10` |
| 新增：安全 | — | `md5_password_warnings on`、`oauth_validator_libraries`、`ssl_groups`、`ssl_tls13_ciphers` |
| 新增：其他 | — | `log_lock_failures off`、`file_copy_method copy`、`extension_control_path $system`、`num_os_semaphores`（唯讀） |
| initdb 產生的 postgresql.conf | — | 多一行 `autovacuum_worker_slots = 16`，其餘和 17 完全相同 |
| initdb 的 checksums | 預設關 | **預設開** |

18 啟動後的實際值：

```console
[pg1] postgres=# SELECT name, setting FROM pg_settings WHERE name IN ('io_method','io_workers','io_combine_limit','io_max_combine_limit','effective_io_concurrency','maintenance_io_concurrency','autovacuum_worker_slots','autovacuum_vacuum_max_threshold','data_checksums','md5_password_warnings','idle_replication_slot_timeout','max_active_replication_origins','track_cost_delay_timing','log_lock_failures','vacuum_max_eager_freeze_failure_rate','vacuum_truncate','log_connections') ORDER BY name;
                 name                 |  setting  
--------------------------------------+-----------
 autovacuum_vacuum_max_threshold      | 100000000
 autovacuum_worker_slots              | 16
 data_checksums                       | on
 effective_io_concurrency             | 200
 idle_replication_slot_timeout        | 0
 io_combine_limit                     | 16
 io_max_combine_limit                 | 16
 io_method                            | worker
 io_workers                           | 3
 log_connections                      | off
 log_lock_failures                    | off
 maintenance_io_concurrency           | 200
 max_active_replication_origins       | 10
 md5_password_warnings                | on
 track_cost_delay_timing              | off
 vacuum_max_eager_freeze_failure_rate | 0.03
 vacuum_truncate                      | on
(17 rows)
```

`io_method = worker` 時，18 確實多了 3 個 I/O worker 行程（`30-extra.sh` 的輸出）：

```console
[pg1]# ps -o pid,cmd -u postgres | grep -E 'io worker' | grep -v grep
   1637 postgres: io worker 0
   1638 postgres: io worker 1
   1639 postgres: io worker 2
```

### 這份設定檔拿到 18 要改什麼

- `effective_io_concurrency`、`maintenance_io_concurrency`：維持 200（SSD），18 的預設 16 也比 17 的 1 合理很多。
- `io_method`：維持預設 `worker`；Linux 核心 5.1 以上、而且安裝的 PostgreSQL 有編入 liburing 時可以試 `io_uring`（**未實測**）。
- `autovacuum_max_workers`：18 可以不重啟就調整，上限是 `autovacuum_worker_slots`（需重啟）。
- `log_connections`：要記錄連線時改成清單寫法，例如 `'receipt,authentication,authorization'`。
- initdb：18 預設開 checksums，若要從**沒開 checksums 的 17** 用 `pg_upgrade` 升上來，新叢集要加 `--no-data-checksums`，否則 `pg_upgrade --check` 會失敗（實測輸出見[運維 01]({% post_url 2026-10-24-postgresql-ops-01-installation-config %})）。

## 小結

- Rocky 9 用 PGDG 套件庫安裝 17.11，記得 `module disable postgresql`，容器要用 9.8 以上的映像。
- initdb 時就開 `--data-checksums`、用 builtin locale。
- 最重要的建議值：`shared_buffers`、`effective_cache_size`、`work_mem`、`maintenance_work_mem`、`max_wal_size`、`checkpoint_timeout`、`random_page_cost`、`effective_io_concurrency`、`wal_compression`、`autovacuum_vacuum_cost_limit`、`shared_preload_libraries = 'pg_stat_statements'`。
- 同一份設定檔可以直接在 18 上啟動，但 I/O 相關的預設值與 `log_connections` 的型別改了。

下一篇：[Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %})，在這個基礎上加上兩台從庫、同步複製與故障切換。

### 參考資料

- [PostgreSQL Yum Repository：Rocky Linux 9](https://www.postgresql.org/download/linux/redhat/)
- [PostgreSQL 17 文件：Server Configuration](https://www.postgresql.org/docs/17/runtime-config.html)
- [PostgreSQL 17 文件：initdb](https://www.postgresql.org/docs/17/app-initdb.html)
- [PostgreSQL 17 文件：The pg_hba.conf File](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)
- [PostgreSQL 17 文件：pg_settings](https://www.postgresql.org/docs/17/view-pg-settings.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
