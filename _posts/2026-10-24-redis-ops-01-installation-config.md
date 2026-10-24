---
title: Redis 運維 01：安裝部署與環境配置
date: 2026-10-24 11:00:00 +0800
categories: [Redis, 安裝部署]
tags: [redis, redis7, redis8, dba, installation, redis.conf, rocky-linux]
description: 以 Redis 7.4.11 為主，整理版本與授權選擇、安裝方式、OS 調校、redis.conf 關鍵參數與三種部署架構，並比較 8.x（8.10.2）的差異。
---

這是 Redis 運維系列的第一篇。本系列以 **Redis 7.4.11**（撰寫時 7.x 的最新版）為主，每篇最後都會比較 **8.x**（撰寫時最新為 8.10.2）的差異。安裝部署的實際操作拆成三篇實作文：[Standalone]({% post_url 2026-10-24-redis-lab-01-standalone %})、[Sentinel]({% post_url 2026-10-24-redis-lab-02-sentinel %})、[Cluster]({% post_url 2026-10-24-redis-lab-03-cluster %})，這篇負責把選型與共通觀念講清楚。

{% include redis-ops-series.md %}

## 版本與授權

Redis 在 2024 年之後改過兩次授權，選版本前一定要先看清楚：

| 版本線 | 撰寫時最新 | 授權 | 備註 |
| :--- | :--- | :--- | :--- |
| 7.2 | 7.2.16 | **BSD-3-Clause** | 最後一個 BSD 授權的版本線，Valkey 就是從 7.2.4 分支出去的 |
| 7.4 | 7.4.11（2026-08-17） | RSALv2 / SSPLv1 二選一 | 本系列的主角。新增 Hash 欄位過期（`HEXPIRE` 等） |
| 8.x | 8.10.2（2026-09-17） | RSALv2 / SSPLv1 / **AGPLv3** 三選一 | 改名 Redis Open Source，內建 JSON、搜尋、時序、機率型資料結構 |

> RSALv2 與 SSPLv1 都不是 OSI 認可的開源授權，主要限制是「不能拿 Redis 做成託管服務賣給別人」。一般公司自用、搭配自家產品使用都不受影響。若公司法務只接受 OSI 授權，可選 7.2.x（BSD）、8.x 的 AGPLv3 選項，或改用 Valkey。
{: .prompt-warning }

7.4 和 7.2 仍持續有安全修補（7.4.9～7.4.11 都是 `SECURITY` 等級，修正了多個可能導致遠端執行程式碼的漏洞），**跑 7.4 就要追到最新的 patch 版本**。

## 安裝方式

Rocky Linux 9 上常見三種：

| 方式 | 優點 | 缺點 |
| :--- | :--- | :--- |
| Rocky AppStream 的 `redis` 套件 | `dnf install` 最簡單 | 版本由發行版決定，通常落後上游很多 |
| Redis 官方 RPM（`packages.redis.io`） | 官方維護，含 systemd 與 SELinux 設定 | 從 8.0 才開始提供，沒有 7.4 |
| **原始碼編譯** | 版本完全可控、可同時裝多版本 | 要自己寫 systemd unit、自己追 patch |

要用 7.4.11，原始碼編譯是最直接的方式，本系列的三篇實作都用這個方法：

```bash
sudo dnf install -y gcc make tar gzip systemd-devel
curl -fsSLO https://download.redis.io/releases/redis-7.4.11.tar.gz
tar xzf redis-7.4.11.tar.gz && cd redis-7.4.11
make -j"$(nproc)" USE_SYSTEMD=yes     # 連結 libsystemd，才能用 Type=notify
sudo make install                      # 安裝到 /usr/local/bin
```

- `USE_SYSTEMD=yes`：讓 Redis 在載入完資料後才通知 systemd「啟動完成」，搭配 `supervised systemd` 與 unit 檔的 `Type=notify`。
- 要用 TLS 的話再加 `BUILD_TLS=yes`，並先 `dnf install openssl-devel`（本系列實作沒有啟用 TLS）。
- 7.4 的 `make` 只編譯核心；8.x 要編譯內建的 JSON、搜尋等模組需要另外加 `BUILD_WITH_MODULES=yes`，相依套件多很多。

## OS 調校

Redis 對 OS 的要求不多，但這幾項沒做，啟動日誌就會出現警告：

```bash
# /etc/sysctl.d/99-redis.conf
vm.overcommit_memory = 1      # BGSAVE / AOF rewrite 要 fork，沒設可能 fork 失敗：Can't save in background: fork: Cannot allocate memory
net.core.somaxconn = 1024     # 要 ≥ redis.conf 的 tcp-backlog（511）
vm.swappiness = 1             # 盡量不要 swap，Redis 被 swap 出去延遲會暴增
```

- **Transparent Huge Pages**：Redis 6.2 起預設 `disable-thp yes`，會自己對行程關掉 THP，不必再改系統設定。
- **檔案描述符**：`maxclients` 預設 10000，Redis 需要 `maxclients + 32` 個 fd。用 systemd 啟動時在 unit 檔設 `LimitNOFILE=65535`。
- **記憶體**：持久化會 fork 子行程，寫入多時 copy-on-write 可能讓記憶體瞬間增加一倍。`maxmemory` 不要設滿，開持久化時抓實體記憶體的 60%～65%。

## redis.conf 的寫法

Redis 的設定檔有一個很容易踩到的坑：**不支援行尾註解**。

```ini
port 6379   # 預設        ← 錯：Redis 會把「#」「預設」當成參數，啟動失敗
# 預設
port 6379                 ← 對：註解要獨立一行
```

實際啟動時的錯誤（Rocky Linux 9 實測）：

```console
[rc1]# printf "port 6390                                   # 預設\n" > /tmp/bad.conf; cat /tmp/bad.conf; redis-server /tmp/bad.conf; echo "exit=$?"
port 6390                                   # 預設

*** FATAL CONFIG FILE ERROR (Redis 7.4.11) ***
Reading the configuration file, at line 1
>>> 'port 6390                                   # 預設'
wrong number of arguments
exit=1
```

三篇實作文的設定檔都是「註解在上、參數在下」的寫法，每個參數都標明「建議」或「預設」。

## 最重要的幾個參數

| 參數 | 7.4 預設 | 建議 | 說明 |
| :--- | :--- | :--- | :--- |
| `maxmemory` | `0`（不限制） | 實體記憶體 60%～65% | 不設的話，記憶體用完會被 OOM Killer 殺掉 |
| `maxmemory-policy` | `noeviction` | 快取：`allkeys-lru`；資料庫：`noeviction` | 記憶體滿時的淘汰策略 |
| `appendonly` | `no` | `yes` | RDB + AOF 一起開，當機最多遺失約 1 秒 |
| `lazyfree-lazy-*` | 全部 `no` | 全部 `yes` | 刪除大 key 改在背景執行緒釋放，避免主執行緒卡住 |
| `io-threads` | `1` | 8 核心設 4 | 網路 I/O 多執行緒，4 核心以下維持 1 |
| `repl-backlog-size` | `1mb` | `256mb` 起 | 太小會讓從庫斷線後只能全量同步 |
| `slowlog-max-len` | `128` | `1024` | 保留更多慢查詢紀錄 |
| `latency-monitor-threshold` | `0` | `100` | 開啟延遲事件監控 |

完整的設定檔（所有影響效能的參數、建議值與預設值）請看三篇實作文。

## 三種部署架構

| 架構 | 節點數 | 高可用 | 擴展寫入 | 用戶端要求 | 適用情境 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Standalone | 1 | 無 | 無 | 一般連線 | 開發、測試、可以接受停機的快取 |
| Sentinel | 1 主 N 從 + 3 Sentinel | 自動切換 | 無（只有一個主庫） | 要支援 Sentinel 探索主庫 | 資料量放得進一台機器、需要 HA |
| Cluster | 至少 3 主 3 從 | 自動切換 | 有（16384 個 slot 分散到多個主庫） | 要支援 Cluster（處理 MOVED / ASK） | 資料量或寫入量超過一台機器 |

選擇的原則很簡單：**一台放得下就用 Sentinel**，放不下或寫入量超過單機上限才上 Cluster。Cluster 帶來的限制（多 key 指令要在同一個 slot、只能用 db 0、Lua 腳本的 key 要在同一個 slot）對應用程式的影響不小。

## 雲端託管（ElastiCache、Memorystore、Azure Cache）

託管服務省去了安裝與 HA 的工作，但要注意：

- 多數雲端服務的 Redis 相容引擎已轉向 Valkey，版本號與 Redis 不同步，功能也可能有差異。
- `CONFIG`、`DEBUG` 等指令通常被停用，參數只能透過參數群組修改。
- 備份、監控、容量規劃與 key 設計仍然要自己負責。

## 版本差異比較：7.4.11 vs 8.10.2

下表是兩個版本不帶設定檔啟動後，用 `CONFIG GET *` 比對出來的差異（7.4.11 有 202 個參數，8.10.2 有 228 個），以及升級時最需要注意的行為變更：

| 項目 | 7.4.11 | 8.10.2 |
| :--- | :--- | :--- |
| 名稱與授權 | Redis Community Edition，RSALv2 / SSPLv1 | Redis Open Source，多了 AGPLv3 |
| 內建模組 | 無（要另外裝 Redis Stack） | 內建 JSON、搜尋、時序、Bloom 等（二進位發行版；原始碼要 `BUILD_WITH_MODULES=yes`） |
| I/O 多執行緒 | 只處理寫回，`io-threads-do-reads` 決定是否處理讀取 | 新實作，讀寫都用執行緒；`io-threads-do-reads` 已移除（設定檔裡有也會被忽略） |
| RDB 格式版本 | 12 | 15（8.6 起逐版提高）。**8.6 以上產生的 RDB 不能載回 7.4** |
| 淘汰策略 | 8 種 | 多了 `volatile-lrm`、`allkeys-lrm`（8.6，依「最近修改」淘汰） |
| 新增參數（節錄） | — | `replica-full-sync-buffer-limit`、`lookahead`、`slowlog-entry-max-argc`、`cluster-slot-stats-enabled`、`hash-*-template-entries`、`backupdirname` |
| 叢集安全 | — | 8.10.2 起，未啟用 `tls-cluster` 的叢集節點啟動時會警告 Cluster Bus 未驗證（`cluster-bus-port-protected-mode`） |
| Lazy Free 預設 | `no` | 仍是 `no`（不像 Valkey 8 改成 `yes`），要自己開 |

> 從 7.4 升到 8.x 可以直接用複製或持久化檔升級，但**不能回退**：8.6 以上的 RDB 版本 7.4 讀不了。升級前務必保留一份 7.4 產生的 RDB，並先在從庫上驗證。
{: .prompt-tip }

## 小結

- 7.4 是 RSALv2 / SSPL 授權，需要 OSI 授權時選 7.2（BSD）或 8.x 的 AGPLv3。
- 7.4.11 在 Rocky 9 上用原始碼編譯安裝，`USE_SYSTEMD=yes` 搭配 `Type=notify`。
- OS 至少要設 `vm.overcommit_memory = 1` 與 `somaxconn`。
- redis.conf **不支援行尾註解**。
- 一台放得下用 Sentinel，放不下才用 Cluster。

接下來是三篇實作：[Standalone]({% post_url 2026-10-24-redis-lab-01-standalone %}) → [Sentinel]({% post_url 2026-10-24-redis-lab-02-sentinel %}) → [Cluster]({% post_url 2026-10-24-redis-lab-03-cluster %})。之後是[備份與還原]({% post_url 2026-10-24-redis-ops-02-backup-restore %})。

### 參考資料

- [Redis：Install Redis from source](https://redis.io/docs/latest/operate/oss_and_stack/install/build-stack/)
- [Redis：Licenses](https://redis.io/legal/licenses/)
- [Redis 7.4 release notes（GitHub）](https://github.com/redis/redis/blob/7.4/00-RELEASENOTES)
- [Redis 8.10 release notes（GitHub）](https://github.com/redis/redis/blob/8.10/00-RELEASENOTES)
- [Redis administration（OS 設定建議）](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/)
