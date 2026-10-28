---
title: PostgreSQL 安裝部署 02：Streaming Replication（PostgreSQL 17 / Rocky Linux 9）
date: 2026-10-24 13:02:00 +0800
categories: [PostgreSQL, 安裝部署]
tags: [postgresql, postgresql17, rocky-linux, streaming-replication, replication, failover, pg_rewind, postgresql.conf, pg_hba.conf, dba]
description: 在 Rocky Linux 9 上建立 PostgreSQL 17.11 一主兩從的 Streaming Replication，使用 quorum 同步複製與 replication slot，實測同步提交、故障切換（pg_promote）、舊主庫用 pg_rewind 回歸，附上包含所有效能相關參數的 postgresql.conf 與 pg_hba.conf。
---

[Standalone]({% post_url 2026-10-24-postgresql-lab-01-standalone %}) 一篇完成了單機的安裝與設定，這篇在同樣的基礎上建立 **一主兩從的 Streaming Replication**，並實際測試同步提交、主庫當機後的切換，以及舊主庫怎麼用 `pg_rewind` 回到叢集。原理與規劃請看[高可用與災難復原]({% post_url 2026-10-24-postgresql-ops-03-ha-dr %})。

{% include postgresql-ops-series.md %}

{% include postgresql-lab-env.md %}

## 架構

| 主機 | IP | 角色（初始） | 角色（切換測試後） |
| :--- | :--- | :--- | :--- |
| `STS-DB32-1` | 192.168.0.1 | 主庫 | 從庫（pg_rewind 後回歸） |
| `STS-DB32-2` | 192.168.0.2 | 從庫（quorum 同步） | **主庫** |
| `STS-DB32-3` | 192.168.0.3 | 從庫（quorum 同步） | 從庫（改接 STS-DB32-2） |

IP 請換成自己環境的實際位址（pg_hba.conf 的複製規則也要跟著改）。後面的指令用主機名稱 `STS-DB32-1`～`STS-DB32-3` 互連，三台的 `/etc/hosts` 都要能解析（**未實測**）：

```bash
sudo tee -a /etc/hosts >/dev/null <<'HOSTS'
192.168.0.1   STS-DB32-1
192.168.0.2   STS-DB32-2
192.168.0.3   STS-DB32-3
HOSTS
```

主機名稱裡有大寫和 `-`，命名時要注意兩條規則：

- **replication slot 名稱只能用小寫英文、數字與底線**，所以 slot 名稱用 `sts_db32_1`～`sts_db32_3`，不能直接用主機名稱。
- `application_name` 可以直接用主機名稱，但寫進 `synchronous_standby_names` 時，含 `-` 的名稱要用**雙引號**括起來，例如 `"STS-DB32-2"`；比對時不分大小寫。在 postgresql.conf 裡直接寫 `'ANY 1 ("STS-DB32-1", "STS-DB32-2", "STS-DB32-3")'`，**不需要反斜線跳脫**；只有在 shell 的 `psql -c "..."` 雙引號字串裡，才要寫成 `\"` 讓 shell 把雙引號原樣傳給 psql。不加雙引號的 `ANY 1 (STS-DB32-1, ...)` 會因為 `-` 解析失敗。

```text
                  ┌──────── WAL streaming（slot: sts_db32_2）────────► STS-DB32-2
  STS-DB32-1 ─────┤
 （主庫）           └──────── WAL streaming（slot: sts_db32_3）────────► STS-DB32-3
  synchronous_standby_names = 'ANY 1 ("STS-DB32-1", "STS-DB32-2", "STS-DB32-3")'
  → 任一台從庫把 WAL fsync 到磁碟，主庫才回應 COMMIT
```

三台主機規格與 Standalone 相同（16 GB RAM、8 vCPU、SSD），三台**共用同一份** postgresql.conf 與 pg_hba.conf，任何一台當主庫時設定都一樣，切換後不必改設定檔。

## 步驟 0：三台都做

先裝 PostgreSQL 套件（和 Standalone 的「步驟 1」相同）。`postgres` 這個 OS 帳號與 `/var/lib/pgsql` 目錄是安裝 `postgresql17-server` 時才建立的，**所以一定要先裝套件**，後面的 `install -o postgres`、`sudo -u postgres` 才不會出現 `invalid user 'postgres'`：

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql17-server postgresql17-contrib

# 確認 postgres 帳號已建立
id postgres
```

三台都裝 `postgresql17-server`、`postgresql17-contrib`，但**只有主庫要 initdb**（步驟 1），從庫的資料目錄由 `pg_basebackup` 產生（步驟 3）。從庫在 `pg_basebackup` 之前不要 initdb，也不要啟動 `postgresql-17` 服務。

接著設定 OS 參數（和 Standalone 相同），並為 postgres 帳號建立 `.pgpass`，讓從庫連主庫、`pg_rewind` 連新主庫時不必在設定檔裡寫明文密碼：

```bash
sudo tee /etc/sysctl.d/99-postgresql.conf <<'CONF'
# /etc/sysctl.d/99-postgresql.conf
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
net.core.somaxconn = 1024
CONF
sudo sysctl -p /etc/sysctl.d/99-postgresql.conf

sudo install -d -o postgres -g postgres -m 700 /var/lib/pgsql/17/archive

sudo -u postgres tee /var/lib/pgsql/.pgpass >/dev/null <<'PGPASS'
*:5432:replication:replicator:ChangeMe_Repl_2026
*:5432:postgres:rewind_user:ChangeMe_Rewind_2026
PGPASS
sudo chmod 600 /var/lib/pgsql/.pgpass
```

`.pgpass` 的第三欄是資料庫名稱，複製連線要寫 `replication`。權限一定要 `600`，否則 libpq 會忽略它。

防火牆（**未實測**）：三台之間都要開 5432（從庫連主庫、切換後角色互換）。

## 步驟 1：主庫 STS-DB32-1

```bash
sudo PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" \
  /usr/pgsql-17/bin/postgresql-17-setup initdb
```

> **主庫已經照 Standalone 篇建好、正在執行？跳過上面的 initdb。** initdb 只用在全新、空的資料目錄；`postgresql-17-setup` 看到資料目錄已有資料會直接拒絕（`Data directory is not empty!`），不會清空既有資料。Standalone 篇的 initdb 參數和這裡相同（含 `--data-checksums`，`pg_rewind` 需要它），可以直接沿用。接下來只要：
>
> 1. 用下面兩段指令覆寫 `postgresql.conf` 與 `pg_hba.conf`。和 Standalone 篇的差異是 `listen_addresses`（`'*'`）、複製參數，以及 pg_hba.conf 多了複製連線與 `pg_rewind` 的規則。pg_hba.conf 是整份覆寫，Standalone 篇另外加的應用程式網段規則（例如 `192.168.0.0/24`）要一起寫進去，否則那些連線會被拒絕。
> 2. 用 `sudo systemctl restart postgresql-17` 重啟，不是 `enable --now`（服務已經在執行，`enable --now` 不會重新載入設定）。`listen_addresses`、`max_wal_senders` 等參數都要重啟才生效，reload 不夠。

接著用下面兩段指令直接覆寫 `postgresql.conf` 與 `pg_hba.conf`（`sudo -u postgres tee`，擁有者維持 `postgres`、權限維持 `600`），寫完再啟動服務。

### postgresql.conf

和 Standalone 的設定檔相比，只有兩處不同：`listen_addresses = '*'`（三台共用，來源由 pg_hba.conf 與防火牆限制），以及展開成「主庫端」「從庫端」兩段的複製參數。標記規則相同：「建議」是調整過的值，括號內是預設值；「預設」是 17.11 的編譯預設值（逐一核對過）。

```bash
sudo -u postgres tee /var/lib/pgsql/17/data/postgresql.conf >/dev/null <<'CONF'
# /var/lib/pgsql/17/data/postgresql.conf
# PostgreSQL 17 Streaming Replication（STS-DB32-1~STS-DB32-3 共用，主庫與從庫同一份）：效能與運維設定
# 和 Standalone 篇相同的參數不再改動，差異在「連線」的 listen_addresses 與「複製」兩段。
# 以「16 GB RAM、8 vCPU、SSD、專用 PostgreSQL 主機、OLTP 為主」為基準。
# 每個參數上一行的註解：標「建議」的是調整過的值（括號內是預設值）；
# 標「預設」的是 17 的預設值（在全新安裝的 PostgreSQL 17 上查 pg_settings.boot_val 逐一核對過），
# 寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始。
# 「需重啟」表示改了要 systemctl restart，其他的 systemctl reload 即可。

#------------------------------------------------------------------------------
# 連線
#------------------------------------------------------------------------------
# 建議（預設 localhost）。三台共用同一份設定所以用 *，由 pg_hba.conf 與防火牆限制來源，需重啟
listen_addresses = '*'
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
# 複製：主庫端（從庫也設好，切換成主庫後直接生效）
#------------------------------------------------------------------------------
# 預設。每個從庫、pg_basebackup、pg_rewind 各占一個，需重啟
max_wal_senders = 10
# 預設，需重啟
max_replication_slots = 10
# 預設。用 replication slot 保留 WAL 時不需要另外保留
wal_keep_size = 0
# 建議（預設 -1 = 不限制）。從庫掛掉時 slot 會讓主庫一直保留 WAL，最多 50GB，超過就放棄該 slot，避免主庫磁碟滿
max_slot_wal_keep_size = 50GB
# 預設。超過 60 秒沒收到從庫回應就斷線
wal_sender_timeout = 60s
# 預設。開了每筆交易多寫一點資料，需重啟
track_commit_timestamp = off
# 建議（預設空 = 全部非同步）。任一台從庫確認收到 WAL 才回應 COMMIT（quorum commit），
# 三台都列出來，任何一台當主庫時設定都一樣；從庫全部掛掉時寫入會卡住，見文章說明
synchronous_standby_names = 'ANY 1 ("STS-DB32-1", "STS-DB32-2", "STS-DB32-3")'
# 預設（17+）。邏輯複製 failover slot 用：列出的實體 slot 確認後，邏輯解碼才送出變更
synchronized_standby_slots = ''

#------------------------------------------------------------------------------
# 複製：從庫端（primary_conninfo、primary_slot_name 由 pg_basebackup -R 寫進 postgresql.auto.conf）
#------------------------------------------------------------------------------
# 預設。從庫可以接受唯讀查詢，需重啟
hot_standby = on
# 預設。從庫上的查詢和 WAL 套用衝突時，最多讓 WAL 等 30 秒再取消查詢；報表從庫可調大，但複製延遲會變大
max_standby_streaming_delay = 30s
# 預設
max_standby_archive_delay = 30s
# 預設。從庫回報接收 / 套用進度的間隔
wal_receiver_status_interval = 10s
# 建議（預設 off）。讓主庫知道從庫上還有哪些查詢在跑，減少「canceling statement due to conflict with recovery」；
# 代價是從庫的長查詢會讓主庫延後清理死 tuple
hot_standby_feedback = on
# 預設
wal_receiver_timeout = 60s
# 預設。連不上主庫時多久重試
wal_retrieve_retry_interval = 5s
# 預設。延遲套用（誤刪防護用的延遲從庫才設）
recovery_min_apply_delay = 0
# 預設。主庫切換後自動跟上新的 timeline
recovery_target_timeline = 'latest'
# 預設（17+）。從庫同步主庫的邏輯 failover slot，需要邏輯複製 failover 時才開
sync_replication_slots = off

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
CONF
```

複製相關參數的重點：

| 參數 | 值 | 說明 |
| :--- | :--- | :--- |
| `wal_level` | `replica`（預設） | 串流複製的最低要求；邏輯複製要 `logical` |
| `max_wal_senders` / `max_replication_slots` | 10（預設） | 每台從庫、每次 `pg_basebackup`、`pg_rewind` 各占一個 sender，預留足夠 |
| `max_slot_wal_keep_size` | 50GB（建議） | 從庫掛掉時 slot 會讓主庫一直保留 WAL，設上限避免主庫磁碟滿 |
| `synchronous_standby_names` | `ANY 1 ("STS-DB32-1", "STS-DB32-2", "STS-DB32-3")`（建議） | quorum commit：任一台從庫確認即可 |
| `hot_standby_feedback` | `on`（建議） | 減少從庫查詢被取消，代價是從庫長查詢會延後主庫的 vacuum |
| `recovery_target_timeline` | `latest`（預設） | 主庫切換後從庫自動跟上新 timeline |
| `wal_log_hints` | `off`（預設） | initdb 已開 data checksums，`pg_rewind` 不需要它 |

> 從庫的 `max_connections`、`max_worker_processes`、`max_wal_senders`、`max_prepared_transactions`、`max_locks_per_transaction` **必須大於或等於主庫**，否則從庫無法啟動。三台共用同一份設定檔就不會有這個問題。
{: .prompt-warning }

### pg_hba.conf

```bash
sudo -u postgres tee /var/lib/pgsql/17/data/pg_hba.conf >/dev/null <<'HBA'
# /var/lib/pgsql/17/data/pg_hba.conf（Streaming Replication，STS-DB32-1~STS-DB32-3 共用）
# 由上往下比對，第一筆符合的就用；改完 systemctl reload postgresql-17 即可生效
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# 本機 Unix socket：作業系統的 postgres 帳號免密碼（peer），其他帳號要密碼
local   all             postgres                                peer
local   all             all                                     scram-sha-256
# 本機 TCP
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# 複製連線：database 欄位要寫 replication（all 不包含複製連線），只允許三台資料庫主機
host    replication     replicator      192.168.0.1/32          scram-sha-256
host    replication     replicator      192.168.0.2/32          scram-sha-256
host    replication     replicator      192.168.0.3/32          scram-sha-256
# pg_rewind 要用一般連線連到新主庫的 postgres 資料庫
host    postgres        rewind_user     192.168.0.1/32          scram-sha-256
host    postgres        rewind_user     192.168.0.2/32          scram-sha-256
host    postgres        rewind_user     192.168.0.3/32          scram-sha-256
# 應用程式網段（依實際網段修改）
host    all             all             192.168.0.0/24          scram-sha-256
# 其他來源一律拒絕
host    all             all             0.0.0.0/0               reject
host    all             all             ::/0                    reject
HBA
```

- 複製連線的 database 欄位要寫 **`replication`**，`all` 不包含複製連線。
- 三台都列出來，因為切換後任何一台都可能是主庫。
- `pg_rewind` 用一般連線（不是複製連線）連到新主庫的 `postgres` 資料庫。

兩個設定檔寫好後啟動主庫：

```bash
sudo systemctl enable --now postgresql-17

# 主庫沿用 Standalone 篇、服務已在執行的話，改用重啟
# sudo systemctl restart postgresql-17
```

實測的啟動結果：

```console
[STS-DB32-1]# PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" /usr/pgsql-17/bin/postgresql-17-setup initdb
Initializing database ... OK


[STS-DB32-1]# systemctl enable --now postgresql-17 && systemctl is-active postgresql-17
Created symlink /etc/systemd/system/multi-user.target.wants/postgresql-17.service → /usr/lib/systemd/system/postgresql-17.service.
active
```

啟動後確認設定檔沒有錯誤、也沒有待重啟的參數（查詢方式見 [Standalone 篇「查看參數值」]({% post_url 2026-10-24-postgresql-lab-01-standalone %}#查看參數值)）：

```bash
sudo -u postgres psql -X -c "SELECT sourcefile, sourceline, name, error FROM pg_file_settings WHERE error IS NOT NULL;"
sudo -u postgres psql -X -c "SELECT name, setting FROM pg_settings WHERE pending_restart;"
```

兩個查詢都回傳 `(0 rows)` 才正確。

## 步驟 2：複製帳號與 pg_rewind 帳號

```sql
-- 還沒有從庫時，synchronous_standby_names 已經設好了，COMMIT 會一直等從庫確認而卡住，
-- 所以初始設定期間在 session 裡改成只等本機
SET synchronous_commit = local;

CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'ChangeMe_Repl_2026';

-- pg_rewind 不需要 superuser，授權這四個函式即可
CREATE ROLE rewind_user LOGIN PASSWORD 'ChangeMe_Rewind_2026';
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;
```

> **實測踩到的坑**：第一次執行時沒有 `SET synchronous_commit = local`，`CREATE ROLE` 就一直卡住不回應。原因是設定檔一開始就有 `synchronous_standby_names`，主庫等不到任何從庫確認。兩種做法：像上面一樣在初始設定期間 `SET synchronous_commit = local`，或是先把 `synchronous_standby_names` 留空，等從庫都接上再設定並 `pg_reload_conf()`。
{: .prompt-danger }

```console
[STS-DB32-1] postgres=# SET synchronous_commit = local; CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'ChangeMe_Repl_2026';
SET
CREATE ROLE

[STS-DB32-1] postgres=# SET synchronous_commit = local; CREATE ROLE rewind_user LOGIN PASSWORD 'ChangeMe_Rewind_2026';
SET
CREATE ROLE

[STS-DB32-1] postgres=# SET synchronous_commit = local; GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO rewind_user; GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO rewind_user;
SET
GRANT
GRANT
GRANT
GRANT

[STS-DB32-1] postgres=# SET synchronous_commit = local; CREATE TABLE t_repl (id bigserial PRIMARY KEY, note text, node text DEFAULT inet_server_addr()::text, ts timestamptz DEFAULT now()); INSERT INTO t_repl(note) VALUES ('before-standby');
SET
CREATE TABLE
INSERT 0 1
```

## 步驟 3：從庫 pg_basebackup（STS-DB32-2、STS-DB32-3）

`pg_basebackup` 只接受**不存在或空的**資料目錄，否則會出現 `directory "/var/lib/pgsql/17/data" exists but is not empty`。如果這台從庫曾經 initdb 過、啟動過服務，或之前跑過一次失敗的 `pg_basebackup`，要先停掉服務、清空資料目錄：

> **以下清空指令只能在從庫（STS-DB32-2、STS-DB32-3）上執行，絕對不要在主庫 STS-DB32-1 上執行**，會把主庫的資料全部刪掉。執行前先用 `hostname` 確認所在主機。
{: .prompt-danger }

```bash
# 只在從庫執行！先確認主機名稱
hostname

# 停止服務（沒啟動過也沒關係）
sudo systemctl stop postgresql-17

# 清空資料目錄內的所有檔案（含隱藏檔），保留目錄本身與其擁有者 postgres、權限 700
sudo -u postgres find /var/lib/pgsql/17/data -mindepth 1 -delete

# 確認已清空：輸出 0 才正確
sudo ls -A /var/lib/pgsql/17/data | wc -l
```

如果之前的 `pg_basebackup` 已經在主庫建立了 slot（例如做到一半失敗），再次執行 `-C -S sts_db32_2` 會出現 `replication slot "sts_db32_2" already exists`。先在**主庫**確認並刪除這個沒在使用的 slot：

```bash
# 在主庫 STS-DB32-1 執行

# 1. 列出主庫上所有 replication slot：active = t 表示正在被從庫使用，f 表示沒有連線在用
sudo -u postgres psql -X -c "SELECT slot_name, active FROM pg_replication_slots;"

# 2. 刪除 sts_db32_2（只能刪 active = f 的 slot；正在使用中的 slot 會報錯 is active for PID）
#    要刪 STS-DB32-3 的 slot，把 sts_db32_2 換成 sts_db32_3
sudo -u postgres psql -X -c "SELECT pg_drop_replication_slot('sts_db32_2');"

# 3. 確認已刪除：回傳 (0 rows) 才正確
sudo -u postgres psql -X -c "SELECT slot_name FROM pg_replication_slots WHERE slot_name = 'sts_db32_2';"
```

刪除時的輸出如下，`pg_drop_replication_slot` 回傳空白一列表示成功：

```console
 pg_drop_replication_slot 
--------------------------
 
(1 row)
```

slot 刪掉之後，回到從庫清空資料目錄，再重新執行 `pg_basebackup`。

資料目錄清空後再執行 `pg_basebackup`：

```bash
# 在 STS-DB32-2 上以 postgres 執行（STS-DB32-3 把 STS-DB32-2 換成 STS-DB32-3）
sudo -iu postgres /usr/pgsql-17/bin/pg_basebackup \
  -d 'host=STS-DB32-1 user=replicator application_name=STS-DB32-2' \
  -D /var/lib/pgsql/17/data -X stream -c fast -R -C -S sts_db32_2 -P
sudo systemctl enable --now postgresql-17
```

> `pg_basebackup` 要以 **postgres** 身分執行（上面的 `sudo -iu postgres`）。下方實測輸出的提示字元 `$` 代表 postgres 使用者、`#` 代表 root。如果直接用 root 執行，會遇到兩個問題：
>
> 1. **要求輸入 replicator 密碼**：密碼放在 postgres 家目錄的 `/var/lib/pgsql/.pgpass`，root 執行時不會讀它。輸入步驟 2 設定的 replicator 密碼即可繼續。若用 postgres 執行還是要求密碼，檢查 `.pgpass` 是否為 postgres 擁有、權限 `600`。
> 2. **資料目錄的檔案變成 root 擁有**：postgresql-17 服務以 postgres 身分執行，會啟動失敗。啟動服務前要先修正擁有者與權限（見下方指令）。
{: .prompt-warning }

```bash
# 只有以 root 執行 pg_basebackup 時才需要：啟動服務前把資料目錄改回 postgres 擁有、權限 700
sudo chown -R postgres:postgres /var/lib/pgsql/17/data
sudo chmod 700 /var/lib/pgsql/17/data
sudo systemctl enable --now postgresql-17
```

| 選項 | 說明 |
| :--- | :--- |
| `-d '... application_name=STS-DB32-2'` | 連線字串裡的 `application_name` 會寫進 `primary_conninfo`，要和 `synchronous_standby_names` 的名稱對應 |
| `-X stream` | 備份期間的 WAL 同時串流過來，備份本身就是一致的 |
| `-c fast` | 立刻觸發 checkpoint，不等排程 |
| `-R` | 產生 `standby.signal`，並把 `primary_conninfo` 寫進 `postgresql.auto.conf` |
| `-C -S sts_db32_2` | 在主庫建立名為 `sts_db32_2` 的 replication slot，並寫入 `primary_slot_name` |

```console
[STS-DB32-2]# ls -A /var/lib/pgsql/17/data | wc -l
0

[STS-DB32-2]$ time /usr/pgsql-17/bin/pg_basebackup -d 'host=STS-DB32-1 user=replicator application_name=STS-DB32-2' -D /var/lib/pgsql/17/data -X stream -c fast -R -C -S sts_db32_2 -P 2>&1 | tail -2
23165/23165 kB (100%), 0/1 tablespace
23165/23165 kB (100%), 1/1 tablespace

real	0m0.146s
user	0m0.008s
sys	0m0.042s

[STS-DB32-2]# cat /var/lib/pgsql/17/data/postgresql.auto.conf; ls /var/lib/pgsql/17/data/standby.signal
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'user=replicator passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=STS-DB32-1 port=5432 application_name=STS-DB32-2 sslmode=prefer sslnegotiation=postgres sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'
primary_slot_name = 'sts_db32_2'
/var/lib/pgsql/17/data/standby.signal

[STS-DB32-2]# systemctl enable --now postgresql-17 && systemctl is-active postgresql-17
Created symlink /etc/systemd/system/multi-user.target.wants/postgresql-17.service → /usr/lib/systemd/system/postgresql-17.service.
active

[STS-DB32-3]# ls -A /var/lib/pgsql/17/data | wc -l
0

[STS-DB32-3]$ time /usr/pgsql-17/bin/pg_basebackup -d 'host=STS-DB32-1 user=replicator application_name=STS-DB32-3' -D /var/lib/pgsql/17/data -X stream -c fast -R -C -S sts_db32_3 -P 2>&1 | tail -2
23167/23167 kB (100%), 0/1 tablespace
23167/23167 kB (100%), 1/1 tablespace

real	0m0.392s
user	0m0.014s
sys	0m0.049s

[STS-DB32-3]# cat /var/lib/pgsql/17/data/postgresql.auto.conf; ls /var/lib/pgsql/17/data/standby.signal
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'user=replicator passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=STS-DB32-1 port=5432 application_name=STS-DB32-3 sslmode=prefer sslnegotiation=postgres sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'
primary_slot_name = 'sts_db32_3'
/var/lib/pgsql/17/data/standby.signal

[STS-DB32-3]# systemctl enable --now postgresql-17 && systemctl is-active postgresql-17
Created symlink /etc/systemd/system/multi-user.target.wants/postgresql-17.service → /usr/lib/systemd/system/postgresql-17.service.
active

[STS-DB32-2]# sleep 2; grep -hE "standby|streaming|consistent|redo" /var/lib/pgsql/17/data/log/postgresql-*.log
2026-10-24 15:33:39.185 CST [158] LOG:  checkpoint complete: wrote 71 buffers (0.0%); 0 WAL file(s) added, 0 removed, 1 recycled; write=0.004 s, sync=0.010 s, total=0.025 s; sync files=54, longest=0.001 s, average=0.001 s; distance=9042 kB, estimate=9042 kB; lsn=0/2000080, redo lsn=0/2000028
2026-10-24 15:33:39.195 CST [206] replicator@[unknown]/STS-DB32-2 192.168.0.2 LOG:  standby "STS-DB32-2" is now a candidate for quorum synchronous standby
2026-10-24 15:33:39.528 CST [101] LOG:  starting backup recovery with redo LSN 0/2000028, checkpoint LSN 0/2000080, on timeline ID 1
2026-10-24 15:33:39.528 CST [101] LOG:  entering standby mode
2026-10-24 15:33:39.529 CST [101] LOG:  redo starts at 0/2000028
2026-10-24 15:33:39.530 CST [101] LOG:  completed backup recovery with redo LSN 0/2000028 and end LSN 0/2000120
2026-10-24 15:33:39.530 CST [101] LOG:  consistent recovery state reached at 0/2000120
2026-10-24 15:33:39.535 CST [102] LOG:  started streaming WAL from primary at 0/3000000 on timeline 1
```

- `pg_basebackup` 也會把主庫的 postgresql.conf 與 pg_hba.conf 一起複製過來，三台的設定檔自然一致。
- `primary_conninfo` 裡的 `passfile` 指向 `.pgpass`，沒有明文密碼。
- 主庫的日誌（上面混在一起的那幾行是 STS-DB32-1 透過 basebackup 複製過來的日誌）出現 `standby "STS-DB32-2" is now a candidate for quorum synchronous standby`。

## 步驟 4：驗證複製狀態

```console
[STS-DB32-1] postgres=# SELECT application_name, client_addr, state, sync_state, sync_priority, sent_lsn, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication ORDER BY application_name;
 application_name | client_addr |   state   | sync_state | sync_priority | sent_lsn  | replay_lsn |    write_lag    |    flush_lag    |   replay_lag    
------------------+-------------+-----------+------------+---------------+-----------+------------+-----------------+-----------------+-----------------
 STS-DB32-2       | 192.168.0.2 | streaming | quorum     |             1 | 0/4000000 | 0/4000000  | 00:00:00.007641 | 00:00:00.007641 | 00:00:00.000833
 STS-DB32-3       | 192.168.0.3 | streaming | quorum     |             1 | 0/4000000 | 0/4000000  | 00:00:00.000123 | 00:00:00.000123 | 00:00:00.000123
(2 rows)


[STS-DB32-1] postgres=# SELECT slot_name, slot_type, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots ORDER BY slot_name;
 slot_name  | slot_type | active | restart_lsn | wal_status | safe_wal_size 
------------+-----------+--------+-------------+------------+---------------
 sts_db32_2 | physical  | t      | 0/4000000   | reserved   |   53703868416
 sts_db32_3 | physical  | t      | 0/4000000   | reserved   |   53703868416
(2 rows)


[STS-DB32-2] postgres=# SELECT pg_is_in_recovery(), status, sender_host, slot_name, received_tli, flushed_lsn FROM pg_stat_wal_receiver;
 pg_is_in_recovery |  status   | sender_host | slot_name  | received_tli | flushed_lsn 
-------------------+-----------+-------------+------------+--------------+-------------
 t                 | streaming | STS-DB32-1  | sts_db32_2 |            1 | 0/4000000
(1 row)


[STS-DB32-2] postgres=# SHOW synchronous_standby_names;
            synchronous_standby_names             
--------------------------------------------------
 ANY 1 ("STS-DB32-1", "STS-DB32-2", "STS-DB32-3")
(1 row)
```

- `sync_state = quorum`：兩台都是 quorum 同步候選，任一台確認即可。
- `replay_lag` 不到 1 ms。
- `safe_wal_size` 約 50 GB，就是 `max_slot_wal_keep_size` 的上限。
- 從庫上 `SHOW synchronous_standby_names` 也是同一個值，切換成主庫後直接生效。

### sync_state 顯示 async 怎麼辦

`sync_state = async` 表示主庫認為這台從庫**不在** `synchronous_standby_names` 名單裡。最常見的原因是主庫的 `synchronous_standby_names` 是空的，例如主庫沿用 Standalone 篇的設定，沒有覆寫成本篇的 postgresql.conf。在主庫依序檢查：

```bash
# 1. 目前生效的值：空白就是全部非同步
sudo -u postgres psql -X -c "SHOW synchronous_standby_names;"

# 2. 值從哪裡來：postgresql.auto.conf（ALTER SYSTEM 寫的）會蓋過 postgresql.conf
sudo -u postgres psql -X -c "SELECT name, setting, sourcefile, sourceline FROM pg_settings WHERE name = 'synchronous_standby_names';"

# 3. 設定檔有沒有語法錯誤（有錯的那行不會生效）
sudo -u postgres psql -X -c "SELECT sourcefile, sourceline, name, error FROM pg_file_settings WHERE error IS NOT NULL;"

# 4. 從庫實際用的 application_name（要和名單裡的名稱相同，不分大小寫）
sudo -u postgres psql -X -c "SELECT application_name, sync_state FROM pg_stat_replication;"
```

值是空的就補上設定。`synchronous_standby_names` **reload 就會生效，不用重啟**：

```bash
sudo -u postgres psql -X -c "ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 (\"STS-DB32-1\", \"STS-DB32-2\", \"STS-DB32-3\")';"
sudo -u postgres psql -X -c "SELECT pg_reload_conf();"
sudo -u postgres psql -X -c "SELECT application_name, sync_state FROM pg_stat_replication;"
```

`ALTER SYSTEM` 會寫進 `postgresql.auto.conf`；也可以改 postgresql.conf 那一行後執行 `pg_reload_conf()`，效果相同。名稱含 `-` 一定要加雙引號，少了雙引號整行會解析失敗，從庫就會維持 async。

## 測試 1、2：主庫寫入、從庫唯讀

```console
[STS-DB32-1] postgres=# INSERT INTO t_repl(note) SELECT 'row-' || g FROM generate_series(1, 1000) g; SELECT count(*) FROM t_repl;
INSERT 0 1000
 count 
-------
  1001
(1 row)


[STS-DB32-2] postgres=# SELECT count(*) FROM t_repl;
 count 
-------
  1001
(1 row)


[STS-DB32-3] postgres=# SELECT count(*) FROM t_repl;
 count 
-------
  1001
(1 row)



======== 測試 2：從庫是唯讀 ========  (2026-10-24 15:33:43)
[STS-DB32-2] postgres=# INSERT INTO t_repl(note) VALUES ('write-on-standby');
ERROR:  cannot execute INSERT in a read-only transaction
```

## 測試 3：quorum 同步提交

先停一台從庫，寫入照常；兩台都停，COMMIT 就會卡在 `SyncRep`，直到有一台回來：

```console
[STS-DB32-2]# systemctl stop postgresql-17

[STS-DB32-1] postgres=# INSERT INTO t_repl(note) VALUES ('STS-DB32-2-down');
INSERT 0 1

[STS-DB32-1] postgres=# SELECT application_name, state, sync_state FROM pg_stat_replication;
 application_name |   state   | sync_state 
------------------+-----------+------------
 STS-DB32-3       | streaming | quorum
(1 row)


[STS-DB32-3]# systemctl stop postgresql-17

[STS-DB32-1] postgres=# INSERT INTO t_repl(note) VALUES ('both-down')    （背景執行）

[STS-DB32-1]# sleep 3; cat /tmp/bg.out; echo "(還沒有輸出 = COMMIT 卡住)"
(還沒有輸出 = COMMIT 卡住)

[STS-DB32-1] postgres=# SELECT pid, state, wait_event_type, wait_event, now() - query_start AS waiting, left(query, 50) AS query FROM pg_stat_activity WHERE wait_event = 'SyncRep';
 pid | state  | wait_event_type | wait_event |     waiting     |                     query                     
-----+--------+-----------------+------------+-----------------+-----------------------------------------------
 257 | active | IPC             | SyncRep    | 00:00:03.209372 | INSERT INTO t_repl(note) VALUES ('both-down')
(1 row)


[STS-DB32-3]# systemctl start postgresql-17; sleep 2

[STS-DB32-1]# sleep 1; cat /tmp/bg.out
INSERT 0 1
```

卡住的 COMMIT 如果被取消（`pg_cancel_backend`、應用程式逾時），會收到 WARNING，但**交易其實已經在主庫提交**：

```console
[STS-DB32-3]# systemctl stop postgresql-17

[STS-DB32-1] postgres=# INSERT INTO t_repl(note) VALUES ('cancelled-wait')    （背景執行）

[STS-DB32-1]# sleep 2

[STS-DB32-1] postgres=# SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';
 pg_cancel_backend 
-------------------
 t
(1 row)


[STS-DB32-1]# sleep 1; cat /tmp/bg.out
WARNING:  canceling wait for synchronous replication due to user request
DETAIL:  The transaction has already committed locally, but might not have been replicated to the standby.
INSERT 0 1

[STS-DB32-1] postgres=# SELECT id, note FROM t_repl WHERE note IN ('both-down', 'cancelled-wait');
  id  |      note      
------+----------------
 1003 | both-down
 1004 | cancelled-wait
(2 rows)


[STS-DB32-2]# systemctl start postgresql-17

[STS-DB32-3]# systemctl start postgresql-17; sleep 3

[STS-DB32-1] postgres=# SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY 1;
 application_name |   state   | sync_state 
------------------+-----------+------------
 STS-DB32-2       | streaming | quorum
 STS-DB32-3       | streaming | quorum
(2 rows)
```

> 這代表「COMMIT 逾時或被取消」不等於「交易失敗」。應用程式不能把它當成失敗直接重試，否則可能重複寫入；要用業務上的唯一鍵（訂單號等）確保冪等。
{: .prompt-warning }

## 測試 4：寫入壓力下的複製延遲

```console
[STS-DB32-1]$ /usr/pgsql-17/bin/pgbench -i -s 10 -q postgres 2>&1 | tail -1
done in 0.86 s (drop tables 0.00 s, create tables 0.00 s, client-side generate 0.65 s, vacuum 0.04 s, primary keys 0.16 s).

[STS-DB32-1]$ (/usr/pgsql-17/bin/pgbench -c 8 -j 4 -T 20 postgres > /tmp/pgbench.out 2>&1 &); for i in 1 2 3 4; do sleep 4; psql -X -Atc "SELECT now()::time(0), application_name, sync_state, pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_bytes, replay_lag FROM pg_stat_replication ORDER BY 2"; done; sleep 6; grep -E "^(tps|latency average|number of transactions actually)" /tmp/pgbench.out
15:34:02|STS-DB32-2|quorum|3752|00:00:00.00054
15:34:02|STS-DB32-3|quorum|6024|00:00:00.000797
15:34:06|STS-DB32-2|quorum|1608|00:00:00.000811
15:34:06|STS-DB32-3|quorum|1264|00:00:00.000517
15:34:10|STS-DB32-2|quorum|1704|00:00:00.000345
15:34:10|STS-DB32-3|quorum|1704|00:00:00.000457
15:34:14|STS-DB32-2|quorum|1176|00:00:00.000691
15:34:14|STS-DB32-3|quorum|1000|00:00:00.000879
number of transactions actually processed: 107745
latency average = 1.485 ms
tps = 5387.207172 (without initial connection time)

[STS-DB32-1] postgres=# SELECT 'STS-DB32-1' AS node, sum(abalance) AS sum_abalance, (SELECT count(*) FROM pgbench_history) AS history FROM pgbench_accounts;
 node       | sum_abalance | history 
------------+--------------+---------
 STS-DB32-1 |        85837 |  107745
(1 row)


[STS-DB32-2] postgres=# SELECT 'STS-DB32-2' AS node, sum(abalance) AS sum_abalance, (SELECT count(*) FROM pgbench_history) AS history FROM pgbench_accounts;
 node       | sum_abalance | history 
------------+--------------+---------
 STS-DB32-2 |        85837 |  107745
(1 row)


[STS-DB32-3] postgres=# SELECT 'STS-DB32-3' AS node, sum(abalance) AS sum_abalance, (SELECT count(*) FROM pgbench_history) AS history FROM pgbench_accounts;
 node       | sum_abalance | history 
------------+--------------+---------
 STS-DB32-3 |        85837 |  107745
(1 row)
```

- 壓測期間 `replay_lag` 都在 1 ms 以內，落後的 WAL 只有幾 KB。
- 同樣的容器環境，Standalone 的 pgbench（16 連線、scale 20）約 13,700 tps，這裡（8 連線、scale 10、同步複製）約 5,400 tps。兩者條件不同，不能直接相減，但同步複製每次 COMMIT 都要多等一次網路往返與從庫 fsync，寫入延遲一定會增加，容器數字**不代表正式主機**。
- 三台的 `sum(abalance)` 與 `pgbench_history` 筆數完全一致。

## 測試 5：故障切換

模擬主庫當機（實測環境用 `docker compose kill` 停掉 STS-DB32-1，等於直接斷電），手動提升 STS-DB32-2：

```console
[STS-DB32-1] postgres=# INSERT INTO t_repl(note) VALUES ('last-before-crash'); SELECT count(*), pg_current_wal_lsn() FROM t_repl;
INSERT 0 1
 count | pg_current_wal_lsn 
-------+--------------------
  1005 | 0/E9A6000
(1 row)


# 主機端：date '+%F %T'; docker compose kill STS-DB32-1
2026-10-24 15:34:20
 Container postgresql-lab-STS-DB32-1-1 Killing 
 Container postgresql-lab-STS-DB32-1-1 Killed 

[STS-DB32-2]# sleep 3; grep -hE "terminat|could not|FATAL" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -3
		This probably means the server terminated abnormally
2026-10-24 15:34:20.583 CST [173] FATAL:  could not connect to the primary server: connection to server at "STS-DB32-1" (192.168.0.1), port 5432 failed: server closed the connection unexpectedly
		This probably means the server terminated abnormally
```

### 提升前：挑 WAL 最新的那台

quorum commit 只保證「至少一台」收到，提升前要比較所有從庫收到的位置，提升最新的那台：

```console
[STS-DB32-2] postgres=# SELECT 'STS-DB32-2' AS node, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();
 node       | pg_last_wal_receive_lsn | pg_last_wal_replay_lsn | pg_last_xact_replay_timestamp 
------------+-------------------------+------------------------+-------------------------------
 STS-DB32-2 | 0/E9A63D8               | 0/E9A63D8              | 2026-10-24 15:34:20.508913+08
(1 row)


[STS-DB32-3] postgres=# SELECT 'STS-DB32-3' AS node, pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();
 node       | pg_last_wal_receive_lsn | pg_last_wal_replay_lsn | pg_last_xact_replay_timestamp 
------------+-------------------------+------------------------+-------------------------------
 STS-DB32-3 | 0/E9A63D8               | 0/E9A63D8              | 2026-10-24 15:34:20.508913+08
(1 row)
```

兩台都是 `0/E9A63D8`，提升 STS-DB32-2：

```console
# 主機端：date '+%F %T.%N' | cut -c1-23
2026-10-24 15:34:24.010

[STS-DB32-2] postgres=# SELECT pg_promote(wait => true, wait_seconds => 60);
 pg_promote 
------------
 t
(1 row)


# 主機端：date '+%F %T.%N' | cut -c1-23
2026-10-24 15:34:24.189

[STS-DB32-2] postgres=# SELECT pg_is_in_recovery(), pg_walfile_name(pg_current_wal_lsn()) AS walfile, count(*) FROM t_repl;
 pg_is_in_recovery |         walfile          | count 
-------------------+--------------------------+-------
 f                 | 00000002000000000000000E |  1005
(1 row)


[STS-DB32-2]# grep -hE "promote|selected new timeline|archive recovery complete|ready to accept" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4; ls /var/lib/pgsql/17/data/pg_wal/*.history
2026-10-24 15:34:24.074 CST [161] LOG:  received promote request
2026-10-24 15:34:24.077 CST [161] LOG:  selected new timeline ID: 2
2026-10-24 15:34:24.092 CST [161] LOG:  archive recovery complete
2026-10-24 15:34:24.099 CST [157] LOG:  database system is ready to accept connections
/var/lib/pgsql/17/data/pg_wal/00000002.history
```

- `pg_promote()` 從送出到完成約 **0.18 秒**（主機端時間 `.010` → `.189`，包含 `docker compose exec` 本身的時間）。實際的停機時間還要加上「發現主庫掛了」與「判斷、隔離舊主庫」的時間，手動處理通常是數分鐘。
- WAL 檔名開頭變成 `00000002`：新的 timeline 2，`00000002.history` 記錄了從 timeline 1 分岔的位置。
- `count = 1005`，主庫當機前最後一筆 `last-before-crash` 也在。

### 其他從庫改接新主庫

新主庫沒有舊主庫的 replication slot（實體 slot 不會複製到從庫），要先建立，再把 STS-DB32-3 的 `primary_conninfo` 改指向 STS-DB32-2：

```sql
-- STS-DB32-2（新主庫）
SELECT pg_create_physical_replication_slot('sts_db32_3');
SELECT pg_create_physical_replication_slot('sts_db32_1');   -- 給之後回歸的舊主庫

-- STS-DB32-3：primary_conninfo 可以 reload 生效（13+），不用重啟
ALTER SYSTEM SET primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-3';
SELECT pg_reload_conf();
```

```console
[STS-DB32-2] postgres=# SELECT pg_create_physical_replication_slot('sts_db32_3'); SELECT pg_create_physical_replication_slot('sts_db32_1');
 pg_create_physical_replication_slot 
-------------------------------------
 (sts_db32_3,)
(1 row)

 pg_create_physical_replication_slot 
-------------------------------------
 (sts_db32_1,)
(1 row)


[STS-DB32-3] postgres=# ALTER SYSTEM SET primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-3';
ALTER SYSTEM

[STS-DB32-3] postgres=# SELECT pg_reload_conf();
 pg_reload_conf 
----------------
 t
(1 row)


[STS-DB32-3]# sleep 4; grep -hE "timeline|streaming|primary_conninfo" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4
2026-10-24 15:34:24.565 CST [190] LOG:  started streaming WAL from primary at 0/E000000 on timeline 1
2026-10-24 15:34:24.568 CST [190] DETAIL:  End of WAL reached on timeline 1 at 0/E9A63D8.
2026-10-24 15:34:24.568 CST [156] LOG:  new target timeline is 2
2026-10-24 15:34:24.568 CST [190] LOG:  restarted WAL streaming at 0/E000000 on timeline 2

[STS-DB32-3] postgres=# SELECT status, sender_host, received_tli, flushed_lsn FROM pg_stat_wal_receiver;
  status   | sender_host | received_tli | flushed_lsn 
-----------+-------------+--------------+-------------
 streaming | STS-DB32-2  |            2 | 0/E9A70B8
(1 row)


[STS-DB32-2] postgres=# INSERT INTO t_repl(note) VALUES ('after-failover'); SELECT application_name, state, sync_state FROM pg_stat_replication;
INSERT 0 1
 application_name |   state   | sync_state 
------------------+-----------+------------
 STS-DB32-3       | streaming | quorum
(1 row)


[STS-DB32-3] postgres=# SELECT count(*), max(note) FILTER (WHERE id = (SELECT max(id) FROM t_repl)) AS last_note FROM t_repl;
 count |   last_note    
-------+----------------
  1006 | after-failover
(1 row)
```

`new target timeline is 2`：STS-DB32-3 自動跟上新的 timeline（`recovery_target_timeline = 'latest'`）。新主庫的寫入透過 quorum 同步到 STS-DB32-3。

> **實測踩到的坑**：第一次把 `ALTER SYSTEM ...; SELECT pg_reload_conf();` 放在同一個 `psql -c` 裡執行，得到 `ERROR: ALTER SYSTEM cannot run inside a transaction block`。`psql -c` 帶多個語句時會包成一個隱含交易，而 `ALTER SYSTEM` 不能在交易裡執行；結果 STS-DB32-3 沒有改接，STS-DB32-2 上的同步寫入就卡住了。分成兩次執行即可。
{: .prompt-danger }

新主庫 STS-DB32-2 的 `postgresql.auto.conf` 裡還留著當從庫時的 `primary_conninfo`（指向 STS-DB32-1）與 `primary_slot_name`。沒有 `standby.signal` 時這兩個參數不會作用，但建議清掉，避免日後誤會：

```sql
-- STS-DB32-2
ALTER SYSTEM RESET primary_conninfo;
ALTER SYSTEM RESET primary_slot_name;
SELECT pg_reload_conf();
```

## 測試 6：舊主庫回歸

### 舊主庫自己起來了：腦裂

STS-DB32-1 的機器恢復後，systemd 照設定自動啟動 PostgreSQL，而且是以**主庫**身分：

```console
# 主機端：docker compose start STS-DB32-1
 Container postgresql-lab-STS-DB32-1-1 Starting 
 Container postgresql-lab-STS-DB32-1-1 Started 

[STS-DB32-1]# sleep 5; systemctl is-active postgresql-17
active

[STS-DB32-1] postgres=# SELECT pg_is_in_recovery(), pg_walfile_name(pg_current_wal_lsn()) AS walfile;
 pg_is_in_recovery |         walfile          
-------------------+--------------------------
 f                 | 00000001000000000000000E
(1 row)


[STS-DB32-1] postgres=# INSERT INTO t_repl(note) VALUES ('split-brain')    （背景執行）

[STS-DB32-1]# sleep 2

[STS-DB32-1] postgres=# SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep';
 pg_cancel_backend 
-------------------
 t
(1 row)


[STS-DB32-1]# sleep 1; cat /tmp/bg.out
WARNING:  canceling wait for synchronous replication due to user request
DETAIL:  The transaction has already committed locally, but might not have been replicated to the standby.
INSERT 0 1

[STS-DB32-1] postgres=# SELECT id, note FROM t_repl ORDER BY id DESC LIMIT 2;
  id  |       note        
------+-------------------
 1025 | split-brain
 1005 | last-before-crash
(2 rows)
```

- `pg_is_in_recovery = f`，WAL 還在 timeline 1：現在有兩台主庫。
- STS-DB32-1 自己的 `synchronous_standby_names` 沒有任何從庫連上，寫入卡在 `SyncRep`，看起來好像有保護；但只要取消等待，**這筆 `split-brain` 就已經在 STS-DB32-1 上提交了**（id 從 1005 跳到 1025：sequence 會預先把後面 32 個值記進 WAL，當機重啟後從記錄的位置繼續，所以會跳號）。
- 如果應用程式還連得到 STS-DB32-1（DNS、連線池沒更新），就會有資料寫進錯誤的主庫。這就是為什麼切換的第一步是**隔離舊主庫**，也是 Patroni 這類工具存在的理由。

> 手動切換的環境，建議在主庫掛掉後先處理開機自動啟動：機器恢復前就 `systemctl disable postgresql-17`（或在網路層隔離），確認要當從庫再啟動。
{: .prompt-danger }

### 直接當從庫啟動：失敗

```console
[STS-DB32-1]# systemctl stop postgresql-17 && runuser -u postgres -- touch /var/lib/pgsql/17/data/standby.signal && printf "%s\n" "primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-1'" "primary_slot_name = 'sts_db32_1'" >> /var/lib/pgsql/17/data/postgresql.auto.conf && cat /var/lib/pgsql/17/data/postgresql.auto.conf && systemctl start postgresql-17; sleep 5; systemctl is-active postgresql-17
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-1'
primary_slot_name = 'sts_db32_1'
active

[STS-DB32-1]# grep -hE "FATAL|forked|not a child|timeline" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -4
2026-10-24 15:34:37.953 CST [114] LOG:  new timeline 2 forked off current database system timeline 1 before current recovery point 0/F0000A0
2026-10-24 15:34:42.964 CST [118] FATAL:  could not start WAL streaming: ERROR:  requested starting point 0/F000000 on timeline 1 is not in this server's history
	DETAIL:  This server's history forked from timeline 1 at 0/E9A63D8.
2026-10-24 15:34:42.964 CST [114] LOG:  new timeline 2 forked off current database system timeline 1 before current recovery point 0/F0000A0
```

STS-DB32-1 在 timeline 1 上多寫了東西（WAL 位置 `0/F0000A0`），而 STS-DB32-2 是在 `0/E9A63D8` 就分岔到 timeline 2，STS-DB32-1 沒辦法接上去：`requested starting point 0/F000000 on timeline 1 is not in this server's history`。

### pg_rewind

```bash
sudo systemctl stop postgresql-17
# -n 先試跑，不會改任何檔案
sudo -iu postgres /usr/pgsql-17/bin/pg_rewind -D /var/lib/pgsql/17/data --source-server='host=STS-DB32-2 user=rewind_user dbname=postgres' -n -P
sudo -iu postgres /usr/pgsql-17/bin/pg_rewind -D /var/lib/pgsql/17/data --source-server='host=STS-DB32-2 user=rewind_user dbname=postgres' -P
```

```console
[STS-DB32-1]# systemctl stop postgresql-17; systemctl is-active postgresql-17
inactive

[STS-DB32-1]$ /usr/pgsql-17/bin/pg_controldata /var/lib/pgsql/17/data | grep -E 'cluster state|TimeLineID'
Database cluster state:               shut down in recovery
Latest checkpoint's TimeLineID:       1
Latest checkpoint's PrevTimeLineID:   1

[STS-DB32-1]$ /usr/pgsql-17/bin/pg_rewind -D /var/lib/pgsql/17/data --source-server='host=STS-DB32-2 user=rewind_user dbname=postgres' -n -P 2>&1 | tail -6
pg_rewind: need to copy 383 MB (total source directory size is 402 MB)
     0/392784 kB (0%) copied
392784/392784 kB (100%) copied
pg_rewind: creating backup label and updating control file
pg_rewind: syncing target data directory
pg_rewind: Done!

[STS-DB32-1]$ time /usr/pgsql-17/bin/pg_rewind -D /var/lib/pgsql/17/data --source-server='host=STS-DB32-2 user=rewind_user dbname=postgres' -P 2>&1 | tail -6
     0/392784 kB (0%) copied
154446/392784 kB (39%) copied
392784/392784 kB (100%) copied
pg_rewind: creating backup label and updating control file
pg_rewind: syncing target data directory
pg_rewind: Done!

real	0m0.531s
user	0m0.131s
sys	0m0.130s

[STS-DB32-1]# ls /var/lib/pgsql/17/data/standby.signal 2>&1; cat /var/lib/pgsql/17/data/postgresql.auto.conf
ls: cannot access '/var/lib/pgsql/17/data/standby.signal': No such file or directory
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'user=replicator passfile=''/var/lib/pgsql/.pgpass'' channel_binding=prefer host=STS-DB32-1 port=5432 application_name=STS-DB32-2 sslmode=prefer sslnegotiation=postgres sslcompression=0 sslcertmode=allow sslsni=1 ssl_min_protocol_version=TLSv1.2 gssencmode=prefer krbsrvname=postgres gssdelegation=0 target_session_attrs=any load_balance_hosts=disable'
primary_slot_name = 'sts_db32_2'
```

`pg_rewind` 的前提是目標乾淨關機（`shut down` 或 `shut down in recovery`）且開了 data checksums 或 `wal_log_hints`。這次要複製 383 MB（整個目錄 402 MB），因為 pgbench 的表在分岔後被大量更新過；寫入少的環境複製量會小很多（**沒有另外量測**）。

**pg_rewind 完成後還沒結束**，有兩件事要自己處理：

1. **`postgresql.auto.conf` 被換成新主庫的版本**：上面的輸出可以看到，內容變成 STS-DB32-2 當從庫時的 `primary_conninfo`（`host=STS-DB32-1 ... application_name=STS-DB32-2`）與 `primary_slot_name = 'sts_db32_2'`。如果直接啟動，STS-DB32-1 會用錯誤的名稱去連一台不存在的主庫。
2. **沒有 `standby.signal`**：直接啟動會變成第二台主庫。

```bash
sudo -u postgres touch /var/lib/pgsql/17/data/standby.signal
sudo -u postgres tee /var/lib/pgsql/17/data/postgresql.auto.conf <<'CONF'
primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-1'
primary_slot_name = 'sts_db32_1'
CONF
sudo systemctl start postgresql-17
```

> `pg_rewind -R` 可以自動寫 `standby.signal` 與 `primary_conninfo`，但它用的是 `--source-server` 的連線資訊（這裡是 `rewind_user`、一般連線），不能拿來做複製連線，所以實測選擇手動寫。
{: .prompt-tip }

```console
[STS-DB32-1]# runuser -u postgres -- touch /var/lib/pgsql/17/data/standby.signal; printf "%s\n" "primary_conninfo = 'host=STS-DB32-2 user=replicator application_name=STS-DB32-1'" "primary_slot_name = 'sts_db32_1'" > /var/lib/pgsql/17/data/postgresql.auto.conf; chown postgres: /var/lib/pgsql/17/data/postgresql.auto.conf; systemctl start postgresql-17; sleep 5; systemctl is-active postgresql-17
active

[STS-DB32-1]# grep -hE "redo|consistent|streaming|timeline" /var/lib/pgsql/17/data/log/postgresql-*.log | tail -5
2026-10-24 15:34:44.516 CST [184] LOG:  starting backup recovery with redo LSN 0/3000028, checkpoint LSN 0/3000080, on timeline ID 1
2026-10-24 15:34:44.517 CST [184] LOG:  redo starts at 0/3000028
2026-10-24 15:34:44.517 CST [184] LOG:  completed backup recovery with redo LSN 0/3000028 and end LSN 0/3000120
2026-10-24 15:34:44.837 CST [184] LOG:  consistent recovery state reached at 0/E9AABE8
2026-10-24 15:34:44.846 CST [185] LOG:  started streaming WAL from primary at 0/E000000 on timeline 2

[STS-DB32-1] postgres=# SELECT pg_is_in_recovery(), status, sender_host, received_tli FROM pg_stat_wal_receiver;
 pg_is_in_recovery |  status   | sender_host | received_tli 
-------------------+-----------+-------------+--------------
 t                 | streaming | STS-DB32-2  |            2
(1 row)


[STS-DB32-2] postgres=# SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication ORDER BY 1;
 application_name |   state   | sync_state |   replay_lag    
------------------+-----------+------------+-----------------
 STS-DB32-1       | streaming | quorum     | 00:00:00.0001
 STS-DB32-3       | streaming | quorum     | 00:00:00.000318
(2 rows)


[STS-DB32-1] postgres=# SELECT 'STS-DB32-1' AS node, count(*), count(*) FILTER (WHERE note = 'split-brain') AS split_brain_rows, max(id) FROM t_repl;
 node       | count | split_brain_rows | max  
------------+-------+------------------+------
 STS-DB32-1 |  1006 |                0 | 1025
(1 row)


[STS-DB32-2] postgres=# SELECT 'STS-DB32-2' AS node, count(*), count(*) FILTER (WHERE note = 'split-brain') AS split_brain_rows, max(id) FROM t_repl;
 node       | count | split_brain_rows | max  
------------+-------+------------------+------
 STS-DB32-2 |  1006 |                0 | 1025
(1 row)


[STS-DB32-3] postgres=# SELECT 'STS-DB32-3' AS node, count(*), count(*) FILTER (WHERE note = 'split-brain') AS split_brain_rows, max(id) FROM t_repl;
 node       | count | split_brain_rows | max  
------------+-------+------------------+------
 STS-DB32-3 |  1006 |                0 | 1025
(1 row)
```

- STS-DB32-1 回到叢集，以從庫身分接上 STS-DB32-2，timeline 2，`sync_state = quorum`。
- 三台都是 1006 筆，`split_brain_rows = 0`：**STS-DB32-1 在腦裂期間寫入的那筆被 pg_rewind 丟掉了**。真實環境若腦裂期間有業務寫入，要在 rewind 之前先把那些資料匯出比對。

### pg_rewind 會覆蓋日誌

最後的錯誤日誌摘要：

```console
[STS-DB32-1]# grep -hcE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log; grep -hE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log | sed -E "s/^[0-9-]+ [0-9:.]+ CST \[[0-9]+\] //" | sort | uniq -c | sort -rn | head -12
7
      3 replicator@[unknown]/STS-DB32-1 192.168.0.1 ERROR:  requested starting point 0/F000000 on timeline 1 is not in this server's history
      1 postgres@postgres/psql [local] ERROR:  cannot execute INSERT in a read-only transaction
      1 FATAL:  terminating walreceiver process due to administrator command
      1 FATAL:  could not receive data from WAL stream: server closed the connection unexpectedly
      1 FATAL:  could not connect to the primary server: connection to server at "STS-DB32-1" (192.168.0.1), port 5432 failed: server closed the connection unexpectedly

[STS-DB32-2]# grep -hcE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log; grep -hE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log | sed -E "s/^[0-9-]+ [0-9:.]+ CST \[[0-9]+\] //" | sort | uniq -c | sort -rn | head -12
7
      3 replicator@[unknown]/STS-DB32-1 192.168.0.1 ERROR:  requested starting point 0/F000000 on timeline 1 is not in this server's history
      1 postgres@postgres/psql [local] ERROR:  cannot execute INSERT in a read-only transaction
      1 FATAL:  terminating walreceiver process due to administrator command
      1 FATAL:  could not receive data from WAL stream: server closed the connection unexpectedly
      1 FATAL:  could not connect to the primary server: connection to server at "STS-DB32-1" (192.168.0.1), port 5432 failed: server closed the connection unexpectedly

[STS-DB32-3]# grep -hcE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log; grep -hE "ERROR|FATAL|WARNING|PANIC" /var/lib/pgsql/17/data/log/postgresql-*.log | sed -E "s/^[0-9-]+ [0-9:.]+ CST \[[0-9]+\] //" | sort | uniq -c | sort -rn | head -12
4
      2 FATAL:  terminating walreceiver process due to administrator command
      1 FATAL:  could not receive data from WAL stream: server closed the connection unexpectedly
      1 FATAL:  could not connect to the primary server: connection to server at "STS-DB32-1" (192.168.0.1), port 5432 failed: server closed the connection unexpectedly
```

STS-DB32-1 和 STS-DB32-2 的摘要**一模一樣**，因為 `log_directory = 'log'` 在資料目錄底下，`pg_rewind` 把它也換成了 STS-DB32-2 的版本，**STS-DB32-1 自己當機前後的日誌不見了**。事故調查需要這些日誌，所以：

- 執行 `pg_rewind` 前先備份 `$PGDATA/log`，或
- 把 `log_directory` 設到資料目錄外面（例如 `/var/log/postgresql`，要先建立目錄並給 postgres 權限）。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| 初始設定時 `CREATE ROLE` 卡住不回應 | `synchronous_standby_names` 已設定但還沒有從庫 | 初始設定期間 `SET synchronous_commit = local`，或先留空等從庫接上再設 |
| `ALTER SYSTEM cannot run inside a transaction block` | `psql -c` 帶多個語句時是一個隱含交易 | `ALTER SYSTEM` 單獨執行 |
| 舊主庫開機後自己變成主庫 | systemd 設定開機自動啟動 | 切換後先 disable 或網路隔離 |
| 舊主庫當從庫啟動：`requested starting point ... is not in this server's history` | timeline 分岔 | `pg_rewind` |
| pg_rewind 後連錯主庫、或變成第二台主庫 | `postgresql.auto.conf` 被換成來源的版本，且沒有 `standby.signal` | rewind 後重寫兩者 |
| pg_rewind 後舊主庫的日誌不見 | `log` 目錄在資料目錄裡，被一起覆蓋 | 先備份，或把 `log_directory` 移出資料目錄 |
| 腦裂期間的寫入消失 | pg_rewind 以新主庫為準 | rewind 前先匯出比對 |

## 驗證方式與結果

驗證環境、建置檔與 compose 檔和 Standalone 篇相同（放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/postgresql-lab)），`STS-DB32-1`～`STS-DB32-3` 使用已安裝 PostgreSQL 17.11（尚未 initdb）的 `pglab-rocky9-pg17` 映像。測試腳本 `tools/postgresql-lab/20-streaming.sh` 整份約 1 分 20 秒跑完，完整輸出在 `results/20-streaming.log`。

| 測試 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 設定檔 | `checkconf.sh` | 沒有錯誤、預設值標記正確 | ✅ 預設 101 項、建議 48 項 |
| 建立從庫 | `pg_basebackup -R -C -S` | 兩台 `streaming`、`sync_state = quorum` | ✅ |
| 資料複製 | 主庫寫 1000 筆 | 從庫筆數相同 | ✅ |
| 從庫唯讀 | 從庫 INSERT | `read-only transaction` 錯誤 | ✅ |
| quorum：一台從庫停 | 主庫寫入 | 立即成功 | ✅ |
| quorum：兩台都停 | 主庫寫入 | 卡在 `SyncRep`，從庫回來後完成 | ✅ |
| 取消同步等待 | `pg_cancel_backend` | WARNING 且交易已提交 | ✅ |
| 寫入壓力 | pgbench 20 秒 | 三台資料一致、replay_lag < 1 ms | ✅ |
| 故障切換 | kill 主庫、`pg_promote()` | 新 timeline、資料不遺失 | ✅ 0.18 秒、1005 筆 |
| 從庫改接 | `ALTER SYSTEM` + reload | STS-DB32-3 跟上 timeline 2 | ✅ |
| 舊主庫直接當從庫 | standby.signal | 失敗（timeline 分岔） | ✅ 如預期失敗 |
| pg_rewind | rewind 後啟動 | 接上新主庫、三台一致、腦裂寫入被丟棄 | ✅ 0.53 秒 |

**錯誤處理紀錄**：

- 初始設定卡在 `SyncRep`：加上 `SET synchronous_commit = local` 後通過（見步驟 2）。
- `ALTER SYSTEM` 與 `pg_reload_conf()` 寫在同一個 `psql -c`：拆成兩次後通過（見測試 5）。
- 兩者都是第一次執行腳本時遇到，修正後整份腳本重跑，上面的輸出都是重跑的結果。

**沒有實測的部分**：18 的 Streaming Replication（只在 Standalone 篇比較了 18 的預設值）、跨機房網路延遲、Patroni 自動切換、firewalld 與 SELinux。

## 版本差異比較：17 vs 18

以下根據 18 的 release notes 與 Standalone 篇實測的 `pg_settings` 差異整理，**18 的複製流程本身沒有實測**：

| 項目 | 17.11 | 18.6 |
| :--- | :--- | :--- |
| 建立從庫的流程 | `pg_basebackup -R -C -S` | 相同 |
| 閒置的 replication slot | 只能用 `max_slot_wal_keep_size` 以容量限制 | 新增 `idle_replication_slot_timeout`（預設 0 = 不限），閒置超過時間就讓 slot 失效 |
| 邏輯複製來源上限 | 共用 `max_replication_slots` | 新增 `max_active_replication_origins`（預設 10） |
| 邏輯複製 failover slot | 17 新增 `sync_replication_slots`、`synchronized_standby_slots` | 沿用 |
| 訂閱端預設 `streaming` | `off` | `parallel` |
| `pg_rewind` 前提 | checksums 或 `wal_log_hints` | 相同；但 18 的 initdb **預設開 checksums**，忘記開的機會少很多 |
| 監控 | `pg_stat_replication`、`pg_stat_wal_receiver` | 相同；`pg_stat_io` 納入 WAL 的 I/O |
| 主從版本 | 必須同大版本 | 必須同大版本，17 的從庫不能接 18 的主庫 |

這份 postgresql.conf 拿到 18 可以直接用（Standalone 篇已實測 17 的設定檔在 18 上啟動沒有錯誤），可以考慮再加上 `idle_replication_slot_timeout`（例如 `1d`），和 `max_slot_wal_keep_size` 一起從時間與容量兩邊保護主庫。

## 小結

- 從庫用 `pg_basebackup -R -C -S`，`application_name` 要和 `synchronous_standby_names` 對應。
- quorum 同步：從庫全掛時 COMMIT 會卡住；取消等待時交易其實已提交。
- 切換順序：隔離舊主庫 → 挑 LSN 最新的從庫 `pg_promote()` → 新主庫建 slot → 其他從庫改接。
- 舊主庫用 `pg_rewind` 回歸，之後要重寫 `postgresql.auto.conf` 與 `standby.signal`，並注意它會覆蓋資料目錄下的日誌。
- 正式環境的自動切換交給 Patroni，見[高可用與災難復原]({% post_url 2026-10-24-postgresql-ops-03-ha-dr %})。

下一篇：[備份與還原]({% post_url 2026-10-24-postgresql-ops-02-backup-restore %})。

### 參考資料

- [PostgreSQL 17 文件：Log-Shipping Standby Servers](https://www.postgresql.org/docs/17/warm-standby.html)
- [PostgreSQL 17 文件：Synchronous Replication](https://www.postgresql.org/docs/17/warm-standby.html#SYNCHRONOUS-REPLICATION)
- [PostgreSQL 17 文件：pg_basebackup](https://www.postgresql.org/docs/17/app-pgbasebackup.html)
- [PostgreSQL 17 文件：pg_rewind](https://www.postgresql.org/docs/17/app-pgrewind.html)
- [PostgreSQL 17 文件：Replication 參數](https://www.postgresql.org/docs/17/runtime-config-replication.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
