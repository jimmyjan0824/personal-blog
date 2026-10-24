---
title: MongoDB 運維 03：高可用與災難復原
date: 2026-10-24 09:52:00 +0800
categories: [MongoDB, 高可用與災難復原]
tags: [mongodb, mongodb8, mongodb9, dba, replica-set, election, write-concern, initial-sync]
description: 以 MongoDB 8.0.9 為主，整理 Replica Set 架構、選舉與故障切換、Write/Read Concern、延遲節點、跨機房部署與 RPO/RTO 規劃，並比較 9.0.4 的差異。
---

MongoDB 的高可用是內建的：Replica Set 會自動選舉、自動故障切換，不需要像 MySQL 那樣額外架 Orchestrator 或 MHA。但「內建」不代表「不用設計」，成員配置、Write Concern 與跨機房拓撲決定了你真正的 RPO / RTO。

{% include mongodb-ops-series.md %}

## 先定義 RPO 與 RTO

| 架構 | RPO | RTO | 備註 |
| :--- | :--- | :--- | :--- |
| 單機 + 備份 | 上次備份 / oplog 備份 | 小時級 | 只適合開發環境 |
| 3 節點 Replica Set，`w: "majority"` | 0（已確認的寫入不會遺失） | 秒級（預設選舉逾時 10 秒） | 正式環境基本款 |
| 跨 3 個機房 / AZ 的 Replica Set | 0 | 秒級 | 可承受單一機房故障 |
| 主站 + 異地 hidden / DR 節點 | 秒級 | 分鐘級（需人工 reconfig） | 異地備援 |

## Replica Set 基本架構

```javascript
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "db1.az-a:27017", priority: 2 },
    { _id: 1, host: "db2.az-b:27017", priority: 1 },
    { _id: 2, host: "db3.az-c:27017", priority: 1 },
    // 延遲節點：防誤刪，不參與選主、對應用程式隱藏
    { _id: 3, host: "db4.dr:27017", priority: 0, hidden: true,
      secondaryDelaySecs: 3600, votes: 0 }
  ],
  settings: { electionTimeoutMillis: 10000, chainingAllowed: true }
})
```

設計原則：

- **投票成員保持奇數**，最多 7 個投票成員（整個 Replica Set 最多 50 個成員）。
- **避免 Arbiter**：PSA（Primary-Secondary-Arbiter）架構在一台 secondary 掛掉時，`majority` 寫入會卡住，且 majority commit point 無法推進，造成 WiredTiger cache 壓力。能用三個資料節點就不要用 Arbiter。
- **priority** 決定誰優先當 primary，可把 primary 固定在主機房。
- **延遲節點**一定要 `priority: 0` + `hidden: true`，否則可能被選成 primary。

常用檢查指令：

```javascript
rs.status()                              // 各成員狀態、optime、健康度
rs.conf()                                // 目前設定
rs.printSecondaryReplicationInfo()       // 各從節點落後時間
db.getReplicationInfo()                  // oplog 大小與時間窗口
```

## 選舉與故障切換

- primary 與多數成員失聯超過 `electionTimeoutMillis`（預設 10 秒）就會觸發選舉。
- 選舉期間無法寫入，driver 的 **retryable writes**（預設開啟）會在新 primary 選出後自動重試一次。
- 計畫性維護用 `rs.stepDown()`，比直接關機切換更快、更乾淨：

```javascript
rs.stepDown(60, 10)   // 60 秒內不得再當選；最多等 10 秒讓 secondary 追上
```

## Write Concern 與 Read Concern

| 設定 | 意義 | 建議 |
| :--- | :--- | :--- |
| `w: 1` | primary 寫入即回應 | 可能在故障切換時被 rollback |
| `w: "majority"` | 多數成員確認 | 5.0 起的預設值（PSA 架構除外），RPO = 0 |
| `j: true` | 寫入 journal 才回應 | 搭配 majority 使用 |
| `readConcern: "majority"` | 只讀已被多數確認的資料 | 避免讀到會被 rollback 的資料 |
| `readConcern: "linearizable"` | 最嚴格，只能讀 primary | 延遲最高，只用在必要的地方 |

> 8.0 的行為變更：`w: "majority"` 改為「多數成員**寫入** oplog」就回應，不再等到「**套用**」。寫入延遲因此下降；如果應用程式在寫入後立刻到 secondary 讀資料，請用 causal consistency session 確保讀得到自己的寫入。
{: .prompt-tip }

## Initial Sync 與重建節點

新節點或落後太久（超出 oplog window）的節點需要 initial sync：

| 方式 | 版本 | 說明 |
| :--- | :--- | :--- |
| Logical（預設） | Community / Enterprise | 複製所有資料再重建索引，資料大時很慢 |
| File copy based | **僅 Enterprise** | 直接複製資料檔，速度快很多 |
| 快照還原 + 追 oplog | 皆可 | 用快照建好資料目錄再加入 Replica Set，最快 |

```javascript
// Enterprise：在新節點的設定檔指定
// setParameter:
//   initialSyncMethod: fileCopyBased
```

## 跨機房部署

- **三機房各一個投票節點**：任何一個機房斷線都能維持多數，是最推薦的拓撲。
- **只有兩個機房**：主機房放 2 票、備機房放 1 票；主機房整個斷線時需要人工 `rs.reconfig({...}, { force: true })` 在備機房強制恢復，RTO 會變成分鐘級。
- 使用 **tag set** 搭配 read preference，讓各區應用程式讀取最近的 secondary。
- 定期做**切換演練**：stepDown、關掉整個 AZ、拔網路，確認應用程式的重連與重試真的有效。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| `w: "majority"` 確認時機 | 寫入 oplog 即確認（8.0 起） | 同 8.0 | 7.0 以前要等套用 |
| Initial sync 進度觀測 | `replSetGetStatus` 的 `initialSyncStatus` 基本欄位 | 新增 `initialSyncStatus.phase`、`totalAttempts`、`bytesPerSecond` 及各次嘗試的 `phaseDurations` | 9.0，logical initial sync |
| Initial sync 建索引記憶體 | 8.0.9 沒有獨立參數 | 預設 RAM 的 10%（200MB～16GB），可用 `initialSyncIndexBuildMemoryPercentage` 等參數調整 | 8.2 起；也回補到 8.0.13 |
| Targeted mirrored reads | 只能隨機鏡像給 secondary | 可用 `mirrorReads.targetedMirroring` 指定 tag 節點（含 hidden）預熱 cache | 8.2 起，適合預熱 DR 節點 |
| Hedged reads | 棄用（`nearest` 預設不再 hedge） | 仍為棄用 | 8.0 起 |
| 過載時的 server selection | — | `overloadAwareServerSelectionEnabled`（opt-in），重試時避開回報過載的成員 | 8.3 起 |
| Oplog 抓取觀測 | — | `metrics.repl.network.oplogFetcherLagSeconds`、`oplogGetMoresProcessed`、`metrics.repl.network.bytesSent` | 8.3 / 9.0 |
| Change stream 與選舉 | — | 用 `primary`/`secondary` read preference 開的 change stream，在角色改變後 `getMore` 回傳可續傳錯誤 `11602` | 符合規範的 driver 會自動續傳；自寫 `getMore` 迴圈要處理 |
| 升 FCV 時的 reconfig | — | `setFeatureCompatibilityVersion: "9.0"` 會隱含執行 `replSetReconfig` 加入 `term` 欄位 | 不要在 initial sync 進行中升 FCV |
| 已知問題 | — | SERVER-133518：9.0.0～9.0.2 的 shard 在 step-up 時可能卡住（**9.0.4 已修正**） | 這是選 9.0.4 而非 9.0.0 的重要理由 |
| 已知問題 | — | SERVER-136961：不正常關機後重啟做 file copy based initial sync 會反覆 crash（8.3.0 起，尚未修正） | 暫時改用 `initialSyncMethod: logical` |

### 給 HA 架構的升級建議

1. 9.0 一定要用 **9.0.4 以上**，避開 SERVER-133518 的 step-up 卡住問題。
2. Enterprise 使用 file copy based initial sync 的環境，先把 `initialSyncMethod` 改回 `logical`，直到 SERVER-136961 修正。
3. 有自己實作 change stream `getMore` 迴圈的程式，要加上錯誤碼 `11602` 的續傳處理。

## 小結

- MongoDB 的 HA 是內建的，但**拓撲設計**（奇數投票、避免 Arbiter、跨三個 AZ）才是 RTO 的關鍵。
- `w: "majority"` 是 RPO = 0 的前提，8.0 起它的延遲也更低了。
- 9.0 主要強化 initial sync 與複製的可觀測性，但也有幾個仍未修正的已知問題要避開。

下一篇：[監控與告警]({% post_url 2026-10-24-mongodb-ops-04-monitoring %})。

### 參考資料

- [Replication](https://www.mongodb.com/docs/manual/replication/)
- [Compatibility Changes in MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
- [Release Notes for MongoDB 8.2](https://www.mongodb.com/docs/v8.2/release-notes/8.2/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
