---
title: PostgreSQL 運維 03：高可用與災難復原
date: 2026-10-24 13:20:00 +0800
categories: [PostgreSQL, 高可用]
tags: [postgresql, postgresql17, postgresql18, dba, replication, streaming-replication, patroni, failover, ha, dr]
description: 以 PostgreSQL 17 為主，整理 Streaming Replication 原理、同步複製與 quorum commit、replication slot、故障切換與 pg_rewind、Patroni 自動切換、邏輯複製與 17 的 failover slot、跨機房與 RPO / RTO 規劃，並比較 18 的差異。
---

PostgreSQL 的高可用建立在 **WAL 串流複製（Streaming Replication）** 上：從庫持續接收主庫的 WAL 並重播，是一份物理上完全相同的副本。本篇講原理與規劃，實際的建置、切換與 `pg_rewind` 測試請看 [Streaming Replication 實作]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %})。

{% include postgresql-ops-series.md %}

## 先定義 RPO 與 RTO

| 架構 | RPO（可能遺失的資料） | RTO（停機時間） |
| :--- | :--- | :--- |
| Standalone + 每日備份 | 最多 1 天 | 還原時間，可能數小時 |
| Standalone + WAL 歸檔（PITR） | `archive_timeout` 內（例如 5 分鐘） | 還原 + 重播 WAL |
| 非同步複製 + 手動切換 | 複製延遲內的交易（通常 < 1 秒） | 發現 + 人工判斷 + promote，數分鐘到數十分鐘 |
| 同步複製（quorum）+ Patroni | 0（已確認的交易不會遺失） | 約 10～30 秒 |

## Streaming Replication 原理

```text
主庫                                   從庫
 backend 寫入 WAL ──► walsender ──TCP──► walreceiver ──► 寫入 pg_wal
                                                         │
                                                  startup 行程重播 WAL
                                                         │
                                                  唯讀查詢（hot_standby）
```

- 從庫透過 `pg_basebackup` 複製一份主庫的資料目錄，再從那個位置開始接收 WAL。
- 從庫的資料目錄有 `standby.signal`，連線資訊寫在 `primary_conninfo`。
- 複製是**整個叢集**：所有資料庫、所有資料表，不能挑。要挑表請用邏輯複製。
- 主從的**大版本必須相同**、CPU 架構相同；minor 版本可以不同（升級時先升從庫）。

### 同步等級

`synchronous_commit` 決定 COMMIT 要等到哪一步才回應用戶端（只有設了 `synchronous_standby_names` 時，`remote_*` 與 `on` 才會等從庫）：

| 設定 | 等到 | 主庫當機時 | 效能 |
| :--- | :--- | :--- | :--- |
| `off` | 不等本機 fsync | 可能遺失本機最近的交易 | 最快 |
| `local` | 本機 WAL fsync | 從庫可能沒收到 | |
| `remote_write` | 從庫收到並寫入 OS（未 fsync） | 主從同時斷電才會遺失 | |
| `on`（預設） | 從庫 fsync | 已確認的交易不會遺失 | |
| `remote_apply` | 從庫已重播，查詢看得到 | 同上，且讀從庫一定讀得到剛寫的 | 最慢 |

`synchronous_commit` 可以在交易層級調整：重要的訂單用 `on`，記錄瀏覽紀錄的交易 `SET LOCAL synchronous_commit = off`。

### Quorum commit

```ini
# 任 1 台確認即可（quorum），比 FIRST 1 更能容忍單一從庫故障或變慢
synchronous_standby_names = 'ANY 1 (pgs1, pgs2, pgs3)'
```

名稱對應的是從庫連線的 `application_name`。實測中要特別注意兩件事：

1. **從庫全部掛掉時，主庫的 COMMIT 會卡住**，直到有從庫回來。這是同步複製的本質，不是 bug。
2. 卡住的 COMMIT 被取消（`pg_cancel_backend` 或用戶端逾時）時，PostgreSQL 會回 `WARNING: canceling wait for synchronous replication ... The transaction has already committed locally`，**交易其實已經在主庫提交**，只是還沒複製出去。應用程式不能把這種情況當成失敗重試。

## Replication Slot

沒有 slot 時，主庫的 WAL 用完就回收，從庫斷線太久就追不回來，只能重建。Slot 讓主庫**保留從庫還沒收到的 WAL**：

```sql
SELECT slot_name, active, wal_status, safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```

代價是：從庫掛掉而 slot 還在，主庫會一直累積 WAL 直到磁碟滿。所以一定要設 `max_slot_wal_keep_size`（例如 50GB），超過就讓 slot 失效（`wal_status = lost`），保護主庫；並監控 `inactive` 的 slot。

## 故障切換

PostgreSQL 本身**沒有自動切換**，只提供 promote 的機制：

```sql
-- 在要提升的從庫上執行（12+）
SELECT pg_promote();
```

手動切換的步驟（實作篇有完整的實測輸出）：

1. 確認主庫真的掛了，並**隔離它**（關機、拔網路、或在負載平衡器移除），避免腦裂。
2. 比較各從庫的 `pg_last_wal_receive_lsn()`，提升**收到最多 WAL** 的那台。用 quorum commit 時，已確認的交易可能只在其中一台從庫上。
3. `pg_promote()`，新主庫切換到新的 timeline（例如 1 → 2）。
4. 在新主庫上替其他從庫建立 slot，其他從庫把 `primary_conninfo` 改指向新主庫，`recovery_target_timeline = 'latest'`（預設）會自動跟上新 timeline。
5. 應用程式改連新主庫（DNS、VIP、或連線字串列出多台主機加上 `target_session_attrs=read-write`）。

### 舊主庫回歸：pg_rewind

舊主庫在當機前可能已經寫入一些 WAL 沒有傳出去，它的 timeline 和新主庫**分岔**了，直接當從庫啟動會出現：

```text
LOG:  new timeline 2 forked off current database system timeline 1 before current recovery point 0/F0000A0
FATAL:  could not start WAL streaming: ERROR:  requested starting point 0/F000000 on timeline 1 is not in this server's history
DETAIL:  This server's history forked from timeline 1 at 0/E9A63D8.
```

`pg_rewind` 會找出分岔點，只把分岔後被改過的區塊從新主庫抓回來，比重新 `pg_basebackup` 快很多。前提是**開了 data checksums 或 `wal_log_hints = on`**。實作篇還踩到兩個容易忽略的地方：`pg_rewind` 會把新主庫的 `postgresql.auto.conf` 複製過來（`primary_conninfo` 變成錯的），而且不會建立 `standby.signal`；資料目錄下的 `log/` 也會被覆蓋，舊主庫自己的日誌會不見。

> 舊主庫的 PostgreSQL 如果設成開機自動啟動，機器一恢復就會以**主庫**身分起來，應用程式若還連得到它就會發生腦裂。手動切換的環境要嘛停用自動啟動，要嘛確保網路層已經隔離；這正是需要 Patroni 這類工具的理由。
{: .prompt-danger }

## Patroni：自動故障切換

| 方案 | 說明 |
| :--- | :--- |
| **Patroni** + etcd / Consul | 事實上的標準。用分散式鎖決定誰是主庫，自動切換、自動 `pg_rewind`、管理設定，搭配 HAProxy 或 vip-manager 讓用戶端找到主庫 |
| repmgr | 較早期的方案，功能較少，社群活躍度下降 |
| pg_auto_failover | 架構簡單（monitor 節點 + 主從），適合小規模 |
| 託管服務 | RDS Multi-AZ、Aurora、Cloud SQL HA，不需要自己管 |

Patroni 的典型架構：3 台 etcd（可以和資料庫主機共用，但最好分開）+ 2～3 台 PostgreSQL + 2 台 HAProxy。HAProxy 用 Patroni 的 REST API（`/primary`、`/replica`）做健康檢查，把寫入導到主庫、讀取導到從庫。

## 邏輯複製

邏輯複製以資料表為單位、可跨大版本，用途和串流複製不同：

| 用途 | 說明 |
| :--- | :--- |
| 大版本升級 | 新版本訂閱舊版本，追上後切換，停機只有幾秒 |
| 部分資料同步 | 只複製某些表到報表庫或其他系統 |
| CDC | Debezium 等工具讀取邏輯解碼的變更送進 Kafka |

17 補上了邏輯複製最大的缺口：**failover slot**。以前主庫切換後，邏輯複製的 slot 不會出現在新主庫，訂閱端只能重建。17 起建立 subscription 時加 `failover = true`，從庫設 `sync_replication_slots = on`，slot 就會同步到從庫，切換後可以繼續。另外 17 新增 `pg_createsubscriber`，可以把一台物理從庫直接轉成邏輯複製的訂閱端，省去初始複製大量資料的時間。

## 跨機房與災難復原

- **同城雙機房**：主庫與同步從庫放不同機房；Patroni 的 etcd 放三個地點（或 2 + 1 仲裁點），避免單一機房斷線就失去多數決。
- **異地 DR**：異地放一台**非同步**從庫（跨城延遲會拖慢同步提交），災難時手動 promote。Patroni 可以設 `nofailover` 標籤讓它不參與自動切換。
- **延遲從庫**：`recovery_min_apply_delay = '1h'` 的從庫，誤刪後一小時內可以從它把資料撈回來。
- **備份仍是最後一道防線**：`DROP TABLE` 會立刻複製到所有從庫，HA 救不了，只能靠 [備份與 PITR]({% post_url 2026-10-24-postgresql-ops-02-backup-restore %})。

### DR 演練

至少每季做一次計畫內切換（switchover），驗證：切換時間、應用程式是否自動重連、監控與告警是否正確、舊主庫是否能用 `pg_rewind` 回歸。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| 邏輯複製 failover slot | 新增 `failover` 選項、`sync_replication_slots`、`synchronized_standby_slots` | 沿用 |
| `pg_createsubscriber` | 新增 | 新增 `--all` 等選項，一次處理所有資料庫 |
| 閒置 slot | 只能靠 `max_slot_wal_keep_size` 以容量限制 | 新增 `idle_replication_slot_timeout`，閒置超過時間就讓 slot 失效 |
| 邏輯複製衝突 | 只在日誌 | `pg_stat_subscription_stats` 記錄各類衝突次數 |
| 邏輯複製 stored generated column | 不能複製 | 可以複製 |
| 訂閱 `streaming` 預設 | `off` | `parallel`（大交易用平行套用） |
| 複製來源上限 | 共用 `max_replication_slots` | 新增 `max_active_replication_origins` |
| 物理串流複製本身 | — | 機制沒有大改，主從仍必須同大版本 |

### 給 HA 架構的升級建議

- 串流複製不能跨大版本，17 → 18 要用 `pg_upgrade`（整組主從一起升，從庫用 rsync 方式或重建）或邏輯複製。
- 升級前確認 Patroni、pgBackRest、監控 exporter 的版本支援 18。
- 18 的 `idle_replication_slot_timeout` 可以和 `max_slot_wal_keep_size` 一起用，從時間與容量兩邊保護主庫。

## 小結

- 串流複製是物理、整叢集、同大版本；邏輯複製以表為單位、可跨版本。
- 同步複製用 `ANY 1 (...)` quorum，並理解「取消等待 ≠ 交易沒提交」。
- Slot 一定要搭配 `max_slot_wal_keep_size`。
- 手動切換的重點是隔離舊主庫、挑 LSN 最新的從庫、用 `pg_rewind` 讓舊主庫回歸；正式環境用 Patroni。

下一篇：[監控與告警]({% post_url 2026-10-24-postgresql-ops-04-monitoring %})。

### 參考資料

- [PostgreSQL 17 文件：High Availability, Load Balancing, and Replication](https://www.postgresql.org/docs/17/high-availability.html)
- [PostgreSQL 17 文件：Synchronous Replication](https://www.postgresql.org/docs/17/warm-standby.html#SYNCHRONOUS-REPLICATION)
- [PostgreSQL 17 文件：pg_rewind](https://www.postgresql.org/docs/17/app-pgrewind.html)
- [PostgreSQL 17 文件：Logical Replication Failover](https://www.postgresql.org/docs/17/logical-replication-failover.html)
- [Patroni documentation](https://patroni.readthedocs.io/)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
