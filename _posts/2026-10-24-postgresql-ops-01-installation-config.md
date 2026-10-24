---
title: PostgreSQL 運維 01：安裝部署與環境配置
date: 2026-10-24 13:00:00 +0800
categories: [PostgreSQL, 安裝部署]
tags: [postgresql, postgresql17, postgresql18, dba, installation, postgresql.conf, rocky-linux, pgdg]
description: 以 PostgreSQL 17 為主，整理版本與支援週期、PGDG 安裝方式、initdb 選項、OS 調校、postgresql.conf 關鍵參數與部署架構，並比較 18 的差異。
---

這是 PostgreSQL 運維系列的第一篇。本系列以 **PostgreSQL 17**（撰寫時最新為 17.11）為主，每篇最後都會比較 **18**（撰寫時最新為 18.6）的差異。安裝部署的實際操作拆成兩篇實作文：[Standalone]({% post_url 2026-10-24-postgresql-lab-01-standalone %}) 與 [Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %})，這篇負責把選型與共通觀念講清楚。

{% include postgresql-ops-series.md %}

## 版本與支援週期

PostgreSQL 每年 9 月左右發布一個大版本，每個大版本支援 **5 年**；每季（2、5、8、11 月）發布一次 minor 版本，只包含錯誤與安全修補，**不會改變行為或資料格式**。

| 大版本 | 首次發布 | 撰寫時最新 | 支援到 | 備註 |
| :--- | :--- | :--- | :--- | :--- |
| 14 | 2021-09 | 14.24 | 2026-11 | 即將停止支援，要排升級 |
| 15 | 2022-10 | 15.19 | 2027-11 | |
| 16 | 2023-09 | 16.15 | 2028-11 | |
| **17** | 2024-09 | **17.11** | 2029-11 | 本系列的主角 |
| 18 | 2025-09 | 18.6 | 2030-11 | 本系列的比較對象 |
| 19 | — | 測試中 | — | PGDG 只有 testing 套件庫，還沒有正式版 |

> 上表的「撰寫時最新」是 2026-10 在 Rocky Linux 9.8 上從 PGDG 套件庫實際查到的版本（`dnf repoquery --latest-limit=1`）。
{: .prompt-info }

**為什麼以 17 為主？** 18 推出剛滿一年，非同步 I/O、預設開 data checksums 等改動影響比較大，很多擴充套件、監控工具、託管服務也才陸續跟上。17 已經過十幾個 minor 版本的修補，是目前多數團隊上線的版本。新專案若生態系相容性沒問題，直接上 18 也很合理，兩者的差異每篇最後都會整理。

**Minor 版本一定要追**：例如 17.x 的每一季更新都含安全修補，升級只需要換套件、重啟，幾分鐘就完成。

## 安裝方式

Rocky Linux 9 上常見三種：

| 方式 | 優點 | 缺點 |
| :--- | :--- | :--- |
| Rocky AppStream 模組（`dnf module`） | 系統內建 | 版本選擇少、minor 更新跟得比較慢 |
| **PGDG 官方套件庫** | 官方社群維護，所有大版本、最新 minor 都有，含 contrib 與大量擴充套件 | 要先停用系統的 postgresql 模組 |
| 原始碼編譯 | 版本與編譯選項完全可控 | 要自己追 patch、自己寫 systemd unit |

本系列兩篇實作都用 **PGDG**：

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql       # 停用 AppStream 的 postgresql 模組，避免裝錯版本
sudo dnf install -y postgresql17-server postgresql17-contrib
```

- PGDG 的套件名稱帶大版本號（`postgresql17-*`），程式裝在 `/usr/pgsql-17/bin`，資料目錄在 `/var/lib/pgsql/17/data`，**不同大版本可以並存**，這是 `pg_upgrade` 升級的前提。
- `postgresql17-contrib` 一定要裝：`pg_stat_statements`、`amcheck`、`pgstattuple`、`pg_buffercache` 都在裡面。
- JIT 在另一個套件 `postgresql17-llvmjit`，沒裝就不能用 JIT（OLTP 為主時通常也建議關掉）。

> PGDG 的套件庫網址會帶 Rocky 的 minor 版本（例如 `rhel-9.8-aarch64`）。實測發現 Docker Hub 上的 `rockylinux:9` 映像停在 9.3，PGDG 已不支援，`dnf` 會因為 `repomd.xml` 404 而失敗。實體機或 VM 只要 `dnf upgrade` 到最新的 9.x 就沒問題；容器請改用 `rockylinux/rockylinux:9`。
{: .prompt-warning }

## initdb：有些選項事後改不了

`initdb` 建立資料庫叢集（cluster），有幾個選項**建立後就不能改**（或要停機很久才能改），一定要先想好：

| 選項 | 建議 | 說明 |
| :--- | :--- | :--- |
| `--data-checksums` | **開** | 每個資料頁加檢查碼，能及早發現磁碟或檔案系統造成的損毀，也讓 `pg_rewind` 不必另外開 `wal_log_hints`。17 預設不開，18 預設開 |
| `--encoding` | `UTF8` | 一律 UTF8 |
| `--locale-provider` | `builtin`（17+） | 17 新增的內建 locale，`C.UTF-8` 排序規則不依賴 glibc，**OS 升級時不會因為 glibc 排序規則改變而讓索引失效** |
| `--locale` | `C.UTF-8` | 中文環境不需要語系排序時用 C.UTF-8 最快；需要依語言排序再在欄位或查詢上指定 ICU collation |
| `--wal-segsize` | 預設 16 MB | 寫入量非常大時可設 64 MB，減少檔案數量 |

PGDG 用 `postgresql-17-setup initdb` 呼叫 initdb，參數透過環境變數傳入：

```bash
sudo PGSETUP_INITDB_OPTIONS="--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8" \
  /usr/pgsql-17/bin/postgresql-17-setup initdb
```

> glibc 排序規則問題不是理論：RHEL 7 → 8（glibc 2.17 → 2.28）大幅改了排序規則，用 libc locale（例如 `en_US.UTF-8`）建立的文字索引在 OS 升級後變成錯的順序，必須重建。之後的 glibc 版本也可能再有小幅變動。用 `builtin` 或 `C` 就沒有這個問題。
{: .prompt-tip }

## OS 調校

```bash
# /etc/sysctl.d/99-postgresql.conf
vm.swappiness = 1                     # 盡量不要 swap
vm.dirty_background_bytes = 67108864  # 64MB 就開始背景寫回，避免累積大量髒頁後一次寫爆 I/O
vm.dirty_bytes = 536870912            # 512MB 就強制同步寫回
net.core.somaxconn = 1024
```

- **Huge Pages**：`shared_buffers` 大於 8 GB 時效益明顯（page table 變小、TLB miss 變少）。做法是先算出需要的頁數，設 `vm.nr_hugepages`，再把 `huge_pages` 改成 `on`：

  ```bash
  # PostgreSQL 停機狀態下計算（15+）
  sudo -u postgres /usr/pgsql-17/bin/postgres -D /var/lib/pgsql/17/data -C shared_memory_size_in_huge_pages
  ```

  Docker 容器共用宿主的核心，本系列實測沒有設定 huge pages（**未實測**），`huge_pages = try` 在拿不到時會退回一般記憶體。
- **Transparent Huge Pages**：建議設成 `never` 或 `madvise`，避免記憶體壓縮造成延遲尖峰。Rocky 9 可用 `tuned` 的 profile 或開機參數 `transparent_hugepage=never`。
- **`vm.overcommit_memory`**：PostgreSQL 官方文件建議 `2`（嚴格模式）避免 OOM Killer 砍掉 postmaster；但設 2 時若 `vm.overcommit_ratio` 沒算好，其他程式可能配置不到記憶體。專用主機才考慮，本系列維持預設 `0`，靠 PGDG unit 檔的 `OOMScoreAdjust=-1000` 保護 postmaster。
- **檔案系統**：XFS 或 ext4，掛載加 `noatime`。資料目錄與 WAL（`pg_wal`）可以分開放，WAL 是循序寫入、對延遲敏感。
- **防火牆**：`firewall-cmd --permanent --add-service=postgresql`（容器內沒有 firewalld，**未實測**）。

## postgresql.conf：最重要的參數

完整的設定檔（每個參數都標明建議值或預設值）在 [Standalone 實作]({% post_url 2026-10-24-postgresql-lab-01-standalone %})，這裡只列影響最大的：

| 參數 | 17 預設 | 建議（16 GB RAM、8 vCPU、SSD） | 說明 |
| :--- | :--- | :--- | :--- |
| `shared_buffers` | 128MB | RAM 的 25%（4GB） | PostgreSQL 自己的快取，其餘靠 OS page cache |
| `effective_cache_size` | 4GB | RAM 的 75%（12GB） | 只影響規劃器估算，不配置記憶體 |
| `work_mem` | 4MB | 16MB | 每個排序 / 雜湊節點各自可用，**乘上連線數與節點數**才是最壞情況 |
| `maintenance_work_mem` | 64MB | 1GB | VACUUM、建索引 |
| `max_connections` | 100 | 200，大量連線用 PgBouncer | 每條連線是一個行程 |
| `max_wal_size` | 1GB | 8GB | 讓 checkpoint 由時間觸發 |
| `checkpoint_timeout` | 5min | 15min | 減少 full page write |
| `random_page_cost` | 4.0 | 1.1 | SSD 隨機讀幾乎和循序一樣快 |
| `effective_io_concurrency` | 1 | 200 | SSD 的預讀深度（18 預設改為 16） |
| `wal_compression` | off | lz4 | 減少 WAL 量 |
| `autovacuum_vacuum_cost_limit` | -1（= 200） | 2000 | 預設對 SSD 太保守，大表 vacuum 跟不上 |
| `shared_preload_libraries` | 空 | `pg_stat_statements` | 效能分析必備 |

`work_mem` 是最常被設錯的參數。它不是「每條連線」而是「每個排序或雜湊操作」，一條複雜查詢可能同時用好幾份，平行查詢的每個 worker 也各自一份。全域設保守值，報表查詢再用 `SET work_mem = '256MB'` 個別調高。

### 依主機規格調整

| 實體記憶體 | `shared_buffers` | `effective_cache_size` | `work_mem`（200 連線） | `maintenance_work_mem` |
| :--- | :--- | :--- | :--- | :--- |
| 8 GB | 2GB | 6GB | 8MB | 512MB |
| 16 GB | 4GB | 12GB | 16MB | 1GB |
| 32 GB | 8GB | 24GB | 32MB | 2GB |
| 64 GB | 16GB | 48GB | 64MB | 2GB |

### 參數的生效方式

`pg_settings.context` 欄位說明了改完要怎麼生效：

| context | 生效方式 | 例子 |
| :--- | :--- | :--- |
| `postmaster` | 重啟 | `shared_buffers`、`max_connections`、`wal_level`、`shared_preload_libraries` |
| `sighup` | `SELECT pg_reload_conf()` 或 `systemctl reload` | `checkpoint_timeout`、`autovacuum_vacuum_cost_limit`、`log_min_duration_statement` |
| `user` / `superuser` | 也可以在 session 或角色上 `SET` | `work_mem`、`statement_timeout` |

```sql
-- 改了哪些參數還沒生效（需要重啟）
SELECT name, setting FROM pg_settings WHERE pending_restart;
-- 設定檔有沒有寫錯
SELECT sourceline, name, error FROM pg_file_settings WHERE error IS NOT NULL;
```

`ALTER SYSTEM SET` 會寫進 `postgresql.auto.conf`，優先權高於 `postgresql.conf`。團隊要先約定好用哪一種，否則常見的狀況是改了 `postgresql.conf` 卻沒生效，因為 `postgresql.auto.conf` 裡有同一個參數。

## 部署架構

| 架構 | 適用 | 實作 |
| :--- | :--- | :--- |
| Standalone | 開發、測試、可接受停機的內部系統 | [Standalone]({% post_url 2026-10-24-postgresql-lab-01-standalone %}) |
| Streaming Replication（1 主多從） | 正式環境的基本盤：讀寫分離、手動或自動切換 | [Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %}) |
| Streaming Replication + Patroni | 自動故障切換 | 見[高可用與災難復原]({% post_url 2026-10-24-postgresql-ops-03-ha-dr %}) |
| 託管服務（RDS、Aurora、Cloud SQL、AlloyDB） | 不想管主機 | 參數用 parameter group / database flags 管理，部分參數不能改 |

託管服務要注意：`shared_buffers` 等參數常是公式（例如 RDS 的 `{DBInstanceClassMemory/32768}`），而且多半不能裝任意擴充套件；`superuser` 也拿不到，改由 `rds_superuser` 之類的角色代替。

## 升級路徑

- **Minor 升級**（17.10 → 17.11）：`dnf update postgresql17*` 後重啟即可，資料格式不變。先看 release notes 有沒有「需要重建某種索引」之類的額外步驟。
- **Major 升級**（17 → 18）：資料格式不同，三種做法：

| 做法 | 停機時間 | 說明 |
| :--- | :--- | :--- |
| `pg_dump` / `pg_restore` | 最長 | 資料小時最簡單 |
| `pg_upgrade --link` | 幾分鐘 | 用 hard link 不複製資料檔；之後要 `ANALYZE`（18 起會保留統計資訊） |
| 邏輯複製 | 秒級 | 新版本建好後用邏輯複製同步，切換時只要改連線；DDL 與 sequence 要另外處理 |

> 從 17 升到 18 時要注意：**18 的 initdb 預設開 data checksums**，如果 17 的叢集沒開，`pg_upgrade` 會因為兩邊設定不一致而失敗，新叢集要用 `initdb --no-data-checksums` 建立。這也是建議 17 建置時就開 checksums 的理由之一。
{: .prompt-warning }

實測（Rocky 9.8 上的 17.11 → 18.6，17 的叢集沒開 checksums）：

```console
[pg1]# cd /tmp && runuser -u postgres -- /usr/pgsql-18/bin/pg_upgrade -b /usr/pgsql-17/bin -B /usr/pgsql-18/bin -d /tmp/pg17nock -D /tmp/pg18ck -p 50432 -P 50433 --check 2>&1 | tail -6
Performing Consistency Checks
-----------------------------
Checking cluster versions                                     ok

old cluster does not use data checksums but the new one does
Failure, exiting
```

18 的新叢集改用 `initdb --no-data-checksums` 建立後，`pg_upgrade --check` 就回報 `*Clusters are compatible*`。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| initdb data checksums | 預設不開 | **預設開**（`--no-data-checksums` 可關） |
| 非同步 I/O | 無（17 先引入 streaming I/O 介面與 `io_combine_limit`） | `io_method`（預設 `worker`，可選 `io_uring`、`sync`）、`io_workers` |
| `effective_io_concurrency` / `maintenance_io_concurrency` 預設 | 1 / 10 | 16 / 16 |
| autovacuum worker | `autovacuum_max_workers` 改了要重啟 | 新增 `autovacuum_worker_slots`，`autovacuum_max_workers` 可以 reload 調整 |
| `pg_upgrade` | 升級後統計資訊歸零，要先 `ANALYZE` 才能正常服務 | 保留統計資訊；新增 `--swap` 模式 |
| 密碼 | md5 可用 | md5 標為淘汰，使用時會警告（`md5_password_warnings`） |
| 認證 | 無 OAuth | 新增 OAuth 2.0 認證 |
| `log_connections` | on / off | 改為清單（要記錄哪些階段），預設空字串；`off` 仍可使用 |
| TLS 曲線 | `ssl_ecdh_curve` | 移除，改為 `ssl_groups`（可設多個，預設 `X25519:prime256v1`） |
| 參數數量（全新 initdb 後的 `pg_settings`） | 384 | 404 |

18 在全新 initdb 後 `pg_settings` 的完整預設值差異，見 [Standalone 實作]({% post_url 2026-10-24-postgresql-lab-01-standalone %})文末的實測比較。

### 給新建置的建議

- 版本：17 或 18 都可以，**17 建置時就開 checksums、用 builtin locale**，日後升 18 最順。
- 一律用 PGDG 套件，裝 contrib，minor 版本每季追。
- 用 PgBouncer 管理連線，`max_connections` 不要無限制調高。

## 小結

- PostgreSQL 每個大版本支援 5 年，minor 版本每季更新，一定要追。
- initdb 時決定 checksums、encoding、locale，事後很難改。
- 最重要的參數：`shared_buffers`、`effective_cache_size`、`work_mem`、`maintenance_work_mem`、`max_wal_size`、`random_page_cost`、`autovacuum_vacuum_cost_limit`。

下一篇是兩篇實作：[Standalone]({% post_url 2026-10-24-postgresql-lab-01-standalone %})、[Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %})。

### 參考資料

- [PostgreSQL Versioning Policy](https://www.postgresql.org/support/versioning/)
- [PostgreSQL Yum Repository](https://yum.postgresql.org/)
- [PostgreSQL 17 文件：Server Configuration](https://www.postgresql.org/docs/17/runtime-config.html)
- [PostgreSQL 17 文件：initdb](https://www.postgresql.org/docs/17/app-initdb.html)
- [PostgreSQL 17 文件：Managing Kernel Resources](https://www.postgresql.org/docs/17/kernel-resources.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
