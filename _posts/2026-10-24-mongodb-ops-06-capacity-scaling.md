---
title: MongoDB 運維 06：容量規劃與擴展
date: 2026-10-24 09:55:00 +0800
categories: [MongoDB, 容量規劃]
tags: [mongodb, mongodb8, mongodb9, dba, sharding, shard-key, resharding, capacity, ttl]
description: 以 MongoDB 8.0.9 為主，整理資料成長預估、垂直擴展、讀取分流、分片叢集與 Shard Key 設計、moveCollection / unshardCollection / Resharding、TTL 與資料歸檔，並比較 9.0.4 的差異。
---

MongoDB 最大的賣點之一是**原生分片**，但分片也是最容易「一開始沒想清楚，之後很難回頭」的決定。本篇以 MongoDB 8.0.9 為主，整理容量評估與擴展方式，最後比較 9.0.4，其中 9.0 把**分片 metadata 從 config server 移到各 shard** 並改了移除 shard 的指令，是分片叢集升級的重點。

{% include mongodb-ops-series.md %}

## 先量測現況

```javascript
// 資料庫層級（單位 GB）
db.stats(1024 * 1024 * 1024)

// 各 collection 的資料、索引、壓縮後大小
db.getCollectionNames().forEach(c => {
  const s = db[c].stats({ scale: 1024 * 1024 });
  print(c, "data:", s.size, "MB", "storage:", s.storageSize, "MB", "index:", s.totalIndexSize, "MB");
});

// 或使用 $collStats
db.orders.aggregate([{ $collStats: { storageStats: { scale: 1048576 } } }])
```

容量規劃要追蹤的數字：

| 項目 | 說明 |
| :--- | :--- |
| 資料成長率 | 每日 / 每月 `storageSize` 增量 |
| 工作集（Working Set） | 熱資料 + 常用索引，應能放進 WiredTiger cache |
| 索引大小 | 全部索引最好能放進記憶體 |
| Oplog 需求 | 寫入量 × 想保留的時間 |
| 磁碟剩餘 | 預留 30% 以上，compact / initial sync / resync 都需要空間 |

> MongoDB 刪除資料後，空間會被 WiredTiger 重複使用，但**不會自動還給 OS**。要回收空間需要 `compact`，或重新 initial sync 該節點。
{: .prompt-tip }

## 擴展的順序

1. **查詢與索引優化**（成本最低）。
2. **垂直擴展**：加記憶體讓工作集放進 cache、換更快的磁碟。
3. **讀取分流**：把報表、分析查詢導到 secondary 或 analytics 節點。
4. **歸檔冷資料**：TTL 索引、搬到歸檔叢集或 Atlas Online Archive。
5. **分片（Sharding）**：單一 Replica Set 撐不住寫入量或資料量時才考慮。

## TTL 與歸檔

```javascript
// 90 天後自動刪除
db.events.createIndex({ createdAt: 1 }, { expireAfterSeconds: 7776000 })
```

TTL 刪除在背景每 60 秒執行一次，大量過期時會造成寫入壓力；對極大的歷史資料，**按月分 collection 再整個 drop** 通常比 TTL 有效率。

## 分片叢集

```text
App ──> mongos (多個) ──> Config Server Replica Set
                     └──> Shard 1 (Replica Set)
                     └──> Shard 2 (Replica Set)
                     └──> Shard N (Replica Set)
```

### Shard Key 的選擇

| 類型 | 適用 | 風險 |
| :--- | :--- | :--- |
| Hashed（`{ userId: "hashed" }`） | 寫入平均分散 | 範圍查詢要打到所有 shard |
| Ranged（`{ region: 1, userId: 1 }`） | 範圍查詢、Zone 分區 | 單調遞增的 key（如時間、ObjectId）會造成寫入熱點 |
| 複合 key | 兼顧分散與查詢定向 | 設計複雜 |

好的 shard key：**高基數、頻率平均、非單調遞增、大多數查詢都帶得到**。

```javascript
sh.enableSharding("shop")
sh.shardCollection("shop.orders", { customerId: "hashed" })

// 依地區做 Zone 分區（資料落地需求）
sh.addShardToZone("shard-tw", "TW")
sh.updateZoneKeyRange("shop.users", { region: "TW", userId: MinKey }, { region: "TW", userId: MaxKey }, "TW")
```

### 選錯 shard key 怎麼辦：Resharding

5.0 起可以線上更換 shard key：

```javascript
sh.reshardCollection("shop.orders", { region: 1, customerId: 1 })
```

Resharding 會複製整個 collection，官方建議每個 shard 預留至少約 1.2 倍該 collection 大小的磁碟空間；在最後的 critical section 會短暫阻擋寫入（上限由 `reshardingCriticalSectionTimeoutMillis` 控制）。

### 8.0 新增的彈性

8.0 讓「分片」不再是一條單行道：

```javascript
// 把未分片的 collection 搬到指定 shard
db.adminCommand({ moveCollection: "shop.logs", toShard: "shard02" })

// 把已分片的 collection 取消分片，集中到某個 shard
sh.unshardCollection("shop.coupons", "shard01")

// Config shard：讓 config server 同時存放應用資料，小叢集可省下一組機器
db.adminCommand({ transitionFromDedicatedConfigServer: 1 })
```

### 分片維運重點

- `sh.status()`、`db.collection.getShardDistribution()` 檢查資料分布。
- `$shardedDataDistribution` 檢查各 shard 資料量與孤兒文件（8.0 起取代 `cleanupOrphaned`）。
- balancer 預設全天執行，可設定 `activeWindow` 避開尖峰。
- 8.0 起直接連到 shard 執行大部分指令會被拒絕，必須透過 `mongos`，或授予維護用的 `directShardOperations` 角色。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| 分片 metadata | 集中在 config server | **FCV 升到 9.0 時，metadata 從 config server 移到各 shard** | 9.0；metadata 多時 FCV 升級會很慢，期間 split/merge/遷移被阻擋 |
| 移除 shard | `removeShard`（反覆執行直到完成） | `startShardDraining` → `shardDrainingStatus` → `commitShardRemoval`；可用 `stopShardDraining` 取消；`removeShard` 棄用 | 8.3 起；mongosh 有 `sh.shardDrainingStatus()` |
| Config shard 轉換 | `transitionFromDedicatedConfigServer` / `transitionToDedicatedConfigServer` | 新增 `startTransitionToDedicatedConfigServer` 等可觀測、可中止的流程，與 `sh.getTransitionToDedicatedConfigServerStatus()` | 8.3 起 |
| Replica Set 轉分片 | 需先建立 dedicated config server | 可用 `--replicaSetConfigShardMaintenanceMode` 搭配 `--configsvr` 直接把 primary 轉為 embedded config shard | 8.3 起 |
| DDL 與 `applyOps` | 可在 shard 上執行（受 `directShardOperations` 限制） | **只能透過 `mongos`** | 8.3 起 |
| 孤兒文件清理延遲 | `orphanCleanupDelaySecs` 預設 900 秒 | 預設 3600 秒 | 8.2 起，遷移後磁碟回收會變慢 |
| Secondary 長查詢與遷移 | 可能默默漏讀文件 | `terminateSecondaryReadsOnOrphanCleanup`（預設 true）會終止受影響的讀取 | 8.2 起，報表查詢可能被中斷 |
| Shard key 索引 | — | 複合 wildcard 索引不能當 shard key 索引 | 8.2.2 起 |
| 時間序列集合 | view + `system.buckets` | 單一 namespace；可 `renameCollection`；`refineCollectionShardKey` 只接受邏輯欄位名 | 9.0 / 8.3 |
| `checkMetadataConsistency` | 基本檢查 | 新增多種不一致類型與 `performStrictChunkChecksIfBelowThreshold` | 9.0 |
| WiredTiger cache 設定 | `cacheSizeGB` | 另可用 `cacheSizePct` | 8.2 起 |
| 已知問題 | SERVER-92236（chunk 遷移取消來源）已於 8.0.9 修正 | SERVER-136226：各節點至少開 `ShardingTaskExecutorPoolMinSize` 條連線到每個 config server，可能耗盡其連線 | 9.0 尚未修正；升級前若該值 > 1，先把 `ShardingTaskExecutorPoolMinSizeForConfigServers` 設為 1 |

### 給分片叢集的升級建議

1. 升級前先跑 `checkMetadataConsistency`，修好不一致再升級。
2. 預先設定 `ShardingTaskExecutorPoolMinSizeForConfigServers: 1`，避開 SERVER-136226。
3. FCV 升到 9.0 時會搬移 metadata，請安排在離峰時段，並預期 balancer 與 chunk 操作會暫停。
4. 自動化腳本中的 `removeShard` 改用新的 draining 指令。

## 小結

- 分片前先把查詢、索引、垂直擴展、歸檔都做過一輪。
- Shard key 的原則：高基數、平均分布、非單調遞增、查詢帶得到；選錯了可以用 resharding 修，但代價不小。
- 9.0 在分片管理上更細緻，也把 metadata 下放到 shard，升級的 FCV 步驟需要特別規劃。

下一篇：[安全與權限管理]({% post_url 2026-10-24-mongodb-ops-07-security %})。

### 參考資料

- [Sharding](https://www.mongodb.com/docs/manual/sharding/)
- [Choose a Shard Key](https://www.mongodb.com/docs/manual/core/sharding-choose-a-shard-key/)
- [Release Notes for MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Upgrade a Sharded Cluster to 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-sharded-cluster/)
