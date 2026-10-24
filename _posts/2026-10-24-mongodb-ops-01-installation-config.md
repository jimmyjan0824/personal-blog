---
title: MongoDB 運維 01：安裝部署與環境配置
date: 2026-10-24 09:50:00 +0800
categories: [MongoDB, 安裝部署]
tags: [mongodb, mongodb8, mongodb9, dba, installation, wiredtiger, tcmalloc, thp]
description: 以 MongoDB 8.0.9 為主，整理版本選型、套件安裝、mongod.conf 關鍵設定、OS 與儲存層調校（THP、TCMalloc、XFS）、容器與雲端部署，並比較 9.0.4 的差異。
---

MongoDB 的安裝本身只要幾分鐘，但「OS 沒調好」造成的效能問題，往往要花幾天才查得出來。本篇以 **MongoDB 8.0.9** 為主，整理從版本選型到上線前檢查的流程，最後與 **9.0.4** 比較。

{% include mongodb-ops-series.md %}

## 先搞懂版本號：Major 與 Minor 發布

MongoDB 從 8.x 開始有兩種發布線：

| 類型 | 版本 | 說明 |
| :--- | :--- | :--- |
| Major release | 8.0、9.0 | 每年一次，可能包含不相容變更，支援 5 年 |
| Minor release | 8.1、8.2、8.3 | 介於兩個 Major 之間、節奏較快；8.1 只在 Atlas，**8.2 起**才開放自建（Community / Enterprise） |
| Patch release | 8.0.9、9.0.4 | 只有修正，同一個 release series 內升級即可 |

本系列以 8.0.9 為主、比較 9.0.4。要注意的是：**9.0 的 release notes 是以 8.3 為基準撰寫的**，所以從 8.0 直接升 9.0 時，8.1～8.3 加入的變更也會一起帶進來。本系列的比較表會標註每個變更最早出現在哪個版本（例如「8.2 起」）。

官方支援週期（Enterprise Advanced / Atlas Dedicated）：

| 版本 | 發布 | EOL |
| :--- | :--- | :--- |
| 7.0 | 2023-08 | 2027-08-31 |
| 8.0 | 2024-10 | 2029-10-31 |
| 9.0 | 2026-09-28（9.0.0 GA） | 2031-10-31 |

> 8.0.9 發布於 2025 年 5 月，之後 8.0 系列又出了 20 幾個 patch（截至 2026-10-13 最新為 **8.0.34**），其中包含多個 CVE 修正。若決定留在 8.0，請至少升到最新的 8.0.x，而不是停在 8.0.9。
{: .prompt-warning }

## 選擇版本：Community 還是 Enterprise

| 功能 | Community | Enterprise |
| :--- | :--- | :--- |
| Replica Set / Sharding | 有 | 有 |
| 靜態資料加密（Encryption at Rest） | 無 | 有（支援 KMIP） |
| 審計日誌（Audit Log） | 無 | 有 |
| LDAP / Kerberos 認證 | 無 | 有 |
| File copy based initial sync | 無 | 有 |
| In-Memory 儲存引擎 | 無 | 有 |

正式環境若有合規需求（審計、加密），通常會選 Enterprise、Atlas，或 Percona Server for MongoDB。

## 安裝（以 Ubuntu 22.04 為例）

```bash
# 匯入 GPG key 與官方套件庫
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/8.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

sudo apt-get update

# 鎖定版本，避免 apt upgrade 時被意外升級
sudo apt-get install -y mongodb-org=8.0.9 mongodb-org-database=8.0.9 \
  mongodb-org-server=8.0.9 mongodb-org-mongos=8.0.9 mongodb-mongosh mongodb-org-tools
sudo apt-mark hold mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos
```

`mongodump`、`mongorestore` 等工具屬於 **MongoDB Database Tools**，版本號（100.x）與 Server 分開；`mongosh` 也是獨立版本。

## mongod.conf 關鍵設定

```yaml
storage:
  dbPath: /data/mongodb
  wiredTiger:
    engineConfig:
      cacheSizeGB: 24          # 預設為 max(50% × (RAM − 1GB), 0.256GB)
      journalCompressor: snappy
    collectionConfig:
      blockCompressor: zstd    # 預設 snappy，zstd 壓縮率較高
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
  logRotate: reopen            # 搭配 logrotate 使用
net:
  port: 27017
  bindIp: 127.0.0.1,10.0.0.11  # 不要用 0.0.0.0
  maxIncomingConnections: 20000
security:
  authorization: enabled
  keyFile: /etc/mongodb/keyfile
replication:
  replSetName: rs0
  oplogSizeMB: 51200
operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 100
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
```

幾個常見誤區：

- **cacheSizeGB 不是越大越好**：WiredTiger cache 之外，OS 檔案快取、連線、排序與聚合也都需要記憶體。官方建議不要調高超過預設值。
- **容器內一定要明確設定 cache**：mongod 會以主機 RAM 計算預設值，容器記憶體上限較小時會 OOM。可用 `db.hostInfo().system.memLimitMB` 確認 mongod 看到的上限。
- **oplog 大小**：建議至少能保留 24～72 小時的寫入量，太小會讓從節點一落後就需要重新 initial sync。

## OS 與儲存層調校

### Transparent Huge Pages（THP）：8.0 起要「開啟」

這是 8.0 最容易被忽略的變更。7.0（含）以前官方要求**關閉** THP；**8.0 起改用新版 TCMalloc（per-CPU cache），官方改為建議開啟**：

| 設定 | 路徑 | 8.0 / 9.0 建議值 |
| :--- | :--- | :--- |
| THP | `/sys/kernel/mm/transparent_hugepage/enabled` | `always` |
| defrag | `/sys/kernel/mm/transparent_hugepage/defrag` | `defer+madvise` |
| khugepaged | `/sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none` | `0` |
| overcommit | `/proc/sys/vm/overcommit_memory` | `1` |

用 systemd 在 `mongod` 啟動前設定：

```ini
# /etc/systemd/system/enable-transparent-huge-pages.service
[Unit]
Description=Enable Transparent Hugepages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo always > /sys/kernel/mm/transparent_hugepage/enabled && echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag && echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none && echo 1 > /proc/sys/vm/overcommit_memory'

[Install]
WantedBy=basic.target
```

RHEL 系統若有 `tuned`，記得建立自訂 profile（`transparent_hugepages=always`），否則開機後會被 tuned 改回去。

> 新版 TCMalloc 只用在 Linux x86_64 與 ARM64。PPC64LE、s390x 仍用舊版 TCMalloc，這兩個架構**仍應關閉 THP**。
{: .prompt-tip }

### TCMalloc per-CPU cache 與 rseq

per-CPU cache 需要 Restartable Sequences（rseq）。較新的 glibc 會先註冊 rseq，導致 TCMalloc 退回 per-thread cache。解法是在 mongod 的環境變數加上：

```bash
# /etc/default/mongod 或 systemd override
GLIBC_TUNABLES=glibc.pthread.rseq=0
```

驗證：

```javascript
const t = db.serverStatus().tcmalloc;
printjson({ usingPerCPUCaches: t.usingPerCPUCaches, cpu_free: t.tcmalloc.cpu_free });
// usingPerCPUCaches 應為 true，cpu_free 應大於 0
```

若仍為 false，請確認 kernel 在 4.18 以上。

### 其他 OS 建議

| 項目 | 建議值 |
| :--- | :--- |
| 檔案系統 | **XFS**（EXT4 可用但可能有效能問題） |
| `vm.swappiness` | `1`（或 `0`） |
| 磁碟 readahead | 8～32 個 sector |
| NUMA | `vm.zone_reclaim_mode=0`，用 `numactl --interleave=all` 啟動，停用 `numad` |
| ulimit | `nofile`、`nproc` 至少 64000 |
| 時間同步 | chrony / NTP，各節點時間要一致 |
| mount 選項 | `noatime` |

> **Linux kernel 6.19～7.0.13 與 MongoDB 內建的 TCMalloc 不相容**，官方文件說明 mongod 偵測到這些 kernel 會直接拒絕啟動，需升到 7.0.14 以上。這條同時出現在 8.0 與 9.0 的文件中，挑選 OS 映像時要特別注意。
{: .prompt-danger }

## 容器與雲端部署

- **Docker**：官方映像 `mongo:8.0.9`。一定要掛載 volume、明確設定 `--wiredTigerCacheSizeGB`、不要把 keyFile 打包進映像。
- **Kubernetes**：用 Operator（MongoDB 官方或 Percona Operator）管理 Replica Set，不要自己用 StatefulSet 硬刻選舉與成員管理。
- **Atlas**：版本升級、備份、監控都託管，但要注意 Atlas 的 Auto Upgrade 版本線會跟著 Minor release 走。

## 上線前檢查清單

1. `mongod --version` 與規劃版本一致，套件已 `apt-mark hold`。
2. THP、rseq、swappiness、ulimit 都已生效（重開機後再檢查一次）。
3. 啟動日誌沒有 `** WARNING:` 開頭的警告（mongosh 登入時也會顯示 startup warnings）。
4. 已啟用認證與 keyFile / x.509，`bindIp` 只開內網。
5. 監控與備份都已接上（見後續篇章）。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| 發布線 | Major（8.0 系列） | Major（9.0 系列） | 9.0 起 EA 改為「Major + 每年一次 x.5 Feature Update」 |
| EOL | 2029-10-31 | 2031-10-31 | 依官方 Support Policy |
| 升級路徑 | 7.0 → 8.0 | **8.0 或 8.3 → 9.0**（可直接從 8.0 升） | 7.0 以前要先升到最新 8.0 |
| 降級 | 8.0 → 7.0 | 9.0 → 8.0（只能降回前一版） | 8.3 起只能降到前一個 minor/major |
| THP / TCMalloc | 開啟 THP、新版 TCMalloc | 同 8.0 | 7.0 以前才是關閉 THP |
| WiredTiger cache 設定方式 | 只有 `cacheSizeGB` | 另有 `cacheSizePct` / `--wiredTigerCacheSizePct`（8.2 起，最高 80%） | 百分比設定對容器較友善 |
| zstd 壓縮等級 | 0 以上 | `zstdCompressionLevel` 可設負值（-7～22，8.2 起） | 負值犧牲壓縮率換速度 |
| FTDC 目錄上限 | 200 MiB | 500 MiB（8.3 起） | `diagnosticDataCollectionDirectorySizeMB`，磁碟要留空間 |
| BSON 驗證 | 依 `net.wireObjectCheck` | 一律驗證所有輸入 BSON；`wireObjectCheck`、`--objcheck` 棄用 | 9.0 |
| Server 端 JavaScript | SpiderMonkey | 改為 WASM 引擎；**ppc64le 版本不含 JS 引擎** | `$where`、`$function`、`mapReduce` 受影響 |
| 新平台 | — | 9.0.4 新增 Ubuntu 26.04 支援 | SERVER-131625 |
| 已知 CVE | 8.0.9 之後還有多個 CVE 修正（如 CVE-2025-12657 於 8.0.10 修正） | 9.0.4 修正 5 個 CVE | 兩邊都應追最新 patch |

### 從 8.0 規劃升 9.0 的建議

1. 先把 8.0 升到最新 patch（8.0.34），再升 9.0，減少已知問題。
2. 確認 FCV 為 `8.0`，詳見 [變更管理篇]({% post_url 2026-10-24-mongodb-ops-08-change-management %}) 的升級流程。
3. 如果有 ppc64le 主機並使用 `$where` / `$function` / `mapReduce`，升級前必須改寫成聚合管線。
4. 升級後觀察一段時間（burn-in）再把 FCV 升到 `9.0`。

## 小結

- 8.0 最大的環境變更是 **THP 改為開啟**，從 7.0 升級的機器務必重新檢查 OS 設定。
- 8.0.9 不是 8.0 的最後一版，正式環境應追到最新 8.0.x。
- 9.0 可以從 8.0 直接升級，但會一次帶入 8.1～9.0 的所有變更。

下一篇：[備份與還原]({% post_url 2026-10-24-mongodb-ops-02-backup-restore %})。

### 參考資料

- [MongoDB Release Notes for 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
- [MongoDB Release Notes for 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [TCMalloc Performance Optimization for a Self-Managed Deployment](https://www.mongodb.com/docs/manual/administration/tcmalloc-performance/)
- [Production Notes for Self-Managed Deployments](https://www.mongodb.com/docs/manual/administration/production-notes/)
- [MongoDB Versions and Upgrade Paths](https://www.mongodb.com/docs/mongodb-versions/)
- [MongoDB Support Policy: Lifecycles](https://www.mongodb.com/legal/support-policy/lifecycles/)
