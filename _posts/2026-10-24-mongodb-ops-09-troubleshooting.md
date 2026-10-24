---
title: MongoDB 運維 09：故障排查與事件處理
date: 2026-10-24 09:58:00 +0800
categories: [MongoDB, 故障排查]
tags: [mongodb, mongodb8, mongodb9, dba, troubleshooting, currentop, replication-lag, rollback, runbook]
description: 以 MongoDB 8.0.9 為主，整理失控查詢、長交易、複製延遲、Rollback、磁碟滿、記憶體與 cache 壓力、連線風暴、選舉震盪等常見故障的處理方式與 Runbook，並比較 9.0.4 的差異。
---

事故發生時最怕兩件事：不知道從哪裡看起，以及在壓力下做出讓情況更糟的操作。本篇以 MongoDB 8.0.9 為主，整理常見故障的排查步驟，最後比較 9.0.4 的差異，其中 **9.0 多了幾個新的錯誤碼與失敗模式**，Runbook 需要同步更新。

{% include mongodb-ops-series.md %}

## 事故處理的基本流程

1. **止血**：先恢復服務（殺查詢、切換節點、限流），再查原因。
2. **保留現場**：日誌、`currentOp` 輸出、FTDC（`diagnostic.data`）先打包。
3. **定位根因**：從指標、日誌、慢查詢找出時間軸。
4. **修復與驗證**。
5. **事後檢討（Post-mortem）**：寫下時間軸、根因、改善項目，不究責個人。

## 失控查詢

```javascript
// 找出執行超過 30 秒的操作
db.currentOp({ active: true, secs_running: { $gt: 30 } }).inprog.forEach(op =>
  print(op.opid, op.secs_running, op.ns, JSON.stringify(op.command).slice(0, 200)))

// 用聚合版本，可看到其他使用者與 idle 連線
db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, idleConnections: false } },
  { $match: { secs_running: { $gt: 30 } } },
  { $project: { opid: 1, secs_running: 1, ns: 1, client: 1, appName: 1 } }
])

// 終止
db.killOp(12345)
```

止血後的長期解法：加索引、用 `setQuerySettings` 的 `reject: true` 擋掉特定 query shape、設定 `defaultMaxTimeMS`。

## 長交易與 Write Conflict

```javascript
db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, idleSessions: true } },
  { $match: { transaction: { $exists: true } } },
  { $project: { "lsid.id": 1, "transaction.timeOpenMicros": 1, client: 1 } }
])
```

- 交易預設最多存活 60 秒（`transactionLifetimeLimitSeconds`），逾時會被中止。
- 長交易會把舊版本資料留在 WiredTiger cache，造成 cache 壓力上升。
- `WriteConflict` 大量出現代表多個交易在搶同一份文件，應從資料模型或交易範圍著手。

## 複製延遲

排查順序：

1. **secondary 資源**：CPU、磁碟 IO 是否打滿（secondary 規格不能比 primary 差）。
2. **網路**：跨機房頻寬、延遲。
3. **大量寫入**：批次匯入、大型 `updateMany`、TTL 大量刪除。
4. **secondary 上的長查詢**：報表查詢與套用 oplog 搶資源。
5. **單一大交易**：一個大交易會產生大量 oplog。

```javascript
rs.printSecondaryReplicationInfo()
db.getReplicationInfo()          // oplog window 是否快要不夠
```

若 secondary 落後超出 oplog window，狀態會變成 `RECOVERING` 並需要重新 initial sync。

## Rollback

primary 在寫入還沒同步給多數成員前掛掉，重新加入時這些寫入會被 rollback，資料會被寫到 `dbPath/rollback/` 目錄下。

- 用 `w: "majority"` 可以避免已確認的寫入被 rollback。
- 用 `bsondump` 檢視 rollback 檔案，評估是否需要手動補回。

## 磁碟滿

```bash
df -h /data/mongodb
du -sh /data/mongodb/* | sort -h | tail
```

| 原因 | 處理 |
| :--- | :--- |
| 資料成長 | 擴充磁碟、歸檔、分片 |
| 刪除後未回收 | 在 secondary 執行 `compact` 或重新 initial sync，再輪替 |
| 日誌過大 | `db.adminCommand({ logRotate: 1 })` 搭配 logrotate |
| FTDC | 8.0 預設上限 200 MiB，通常不是主因 |

> 磁碟滿時 mongod 會直接關閉以保護資料。**不要手動刪除 dbPath 下的 `.wt` 檔或 journal**，那會讓整個節點無法啟動。
{: .prompt-danger }

## 記憶體與 OOM

- 容器內沒設定 `cacheSizeGB`，mongod 以主機記憶體計算 cache，最常導致 OOM Kill。
- 確認 THP、TCMalloc per-CPU cache 是否如預期（見[安裝篇]({% post_url 2026-10-24-mongodb-ops-01-installation-config %})）。
- 大型 `$group`、`$sort` 沒有索引支援、又沒開 `allowDiskUse`。
- 連線數暴增，每條連線都會佔用記憶體。

## 連線風暴

症狀：連線數瞬間暴增、認證變慢、CPU 飆高。常見原因是應用程式重啟時大量建立連線、連線池設定過大、或 driver 沒有共用 `MongoClient`。

處理：限制 `maxPoolSize`、設定 `net.maxIncomingConnections`、在應用端加上重試的指數退避。

## 選舉震盪

```bash
grep -E "Starting an election|transition to PRIMARY|stepping down" /var/log/mongodb/mongod.log
```

常見原因：網路抖動、節點過載導致 heartbeat 逾時、時間不同步、VM 被暫停（live migration）。

## Runbook 範本

```markdown
## [事件名稱] 例：Replica Set 沒有 primary
- 告警條件：rs.status() 無 PRIMARY 超過 30 秒
- 影響：所有寫入失敗
- 檢查：rs.status()、各節點 mongod.log、網路連通、磁碟
- 止血：恢復多數成員連線；若機房整個失聯且確認無法恢復 → 主管核准後 force reconfig
- 驗證：寫入恢復、複製延遲歸零
- 通知：#db-oncall、事件頻道
```

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| 單一查詢記憶體超限 | 只有 stage 級別錯誤 | 新錯誤：`ExceededMemoryLimit`（146）、`QueryExceededMemoryLimitNoDiskUseAllowed`（292），日誌 `Query exceeded the memory limit`（code 12932700） | 9.0；Runbook 要加入此錯誤的處理 |
| 交易數量上限 | 無 | 超過 `maxConcurrentMultiDocumentTransactions` 回傳 `TooManyOpenTransactions` | 9.0 |
| Cache 壓力 | 需手動找出並中止長交易 | `cachePressureQueryPeriodMilliseconds` 偵測到壓力時自動中止最舊交易 | 8.3 起 |
| 查詢記憶體觀測 | — | `$currentOp` 有 `inUseTrackedMemBytes`、`peakTrackedMemBytes` | 8.3 起，排查 OOM 很有用 |
| 2dsphere 錯誤碼 | 斷言碼 `16755` 等 | `GeoKeyExtractionFailed`（510）、`GeoKeyExtractionFailedTimeseries`（511），並在 `writeErrors[].errInfo` 附上失敗欄位 | 9.0；依錯誤碼判斷的程式要更新 |
| 超大 upsert 錯誤碼 | `17419` / `17420` | `BSONObjectTooLarge`（10334） | 8.3 起 |
| Write conflict 觀測 | — | `metrics.operation.writeConflictRetryLimitHit` | 9.0 |
| 跨資料庫 rename 資料遺失 | SERVER-131805 影響 8.0.0～8.0.33 | — | 8.0 請升到 8.0.34 |
| `$group` crash（CVE-2025-10061） | 受影響（8.0.12 修正） | — | |
| Shard step-up 卡住 | — | SERVER-133518 影響 9.0.0～9.0.2，**9.0.4 已修正** | |
| Config server 連線耗盡 | — | SERVER-136226（尚未修正），升級前調整 `ShardingTaskExecutorPoolMinSizeForConfigServers` | |
| File copy initial sync 反覆 crash | — | SERVER-136961（尚未修正），改用 logical initial sync | Enterprise |
| Linux kernel 6.19～7.0.13 | mongod 拒絕啟動 | 同 | 兩版文件都有此限制 |

### 給 Runbook 的升級建議

1. 在 Runbook 中加入 9.0 的新錯誤碼（146、292、510、511、`TooManyOpenTransactions`），並說明處理方式。
2. 監控 `inUseTrackedMemBytes`，可以在 OOM 之前抓到吃記憶體的查詢。
3. 9.0 的已知問題清單（SERVER-136226、SERVER-136961）要列入升級檢查表，並追蹤後續 patch。

## 小結

- 先止血、再保留現場、最後找根因；不要在壓力下刪檔案。
- `currentOp` + `killOp` + `setQuerySettings` 是處理失控查詢的三板斧。
- 9.0 多了記憶體與交易上限，這些「新的失敗」要提早寫進 Runbook。

下一篇：[自動化與規範制定]({% post_url 2026-10-24-mongodb-ops-10-automation-standards %})。

### 參考資料

- [currentOp](https://www.mongodb.com/docs/manual/reference/command/currentOp/)
- [Rollbacks During Replica Set Failover](https://www.mongodb.com/docs/manual/core/replica-set-rollbacks/)
- [Release Notes for MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
