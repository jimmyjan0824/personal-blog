---
title: MongoDB 運維 08：變更管理與發布
date: 2026-10-24 09:57:00 +0800
categories: [MongoDB, 變更管理]
tags: [mongodb, mongodb8, mongodb9, dba, schema-validation, index-build, fcv, upgrade, migration]
description: 以 MongoDB 8.0.9 為主，整理 Schema Validation、線上建索引、collection 變更、Schema 版本控管、FCV 與滾動升級（8.0 → 9.0）及回滾方案，並比較 9.0.4 的差異。
---

MongoDB 常被說是「schemaless」，但這不代表沒有 schema 變更，只是變更從資料庫移到了應用程式和資料本身。本篇以 MongoDB 8.0.9 為主，整理 schema 驗證、索引變更、版本控管與升級流程，並完整走一次 **8.0 → 9.0 的滾動升級**。

{% include mongodb-ops-series.md %}

## 變更的種類與風險

| 變更 | 風險 | 做法 |
| :--- | :--- | :--- |
| 新增欄位 | 低 | 應用程式向下相容即可 |
| 欄位改名 / 改型別 | 高 | 雙寫 → 背景回填 → 切換讀取 → 移除舊欄位 |
| 新增索引 | 中 | 建索引期間增加 IO 與 cache 壓力 |
| 刪除索引 | 中 | 先 `hideIndex` 觀察，再刪 |
| Schema validation | 中 | 先 `warn`、`moderate`，再 `error`、`strict` |
| Shard key 變更 | 高 | `reshardCollection`，需大量磁碟與時間 |
| 版本升級 | 高 | 滾動升級 + FCV 分段 |

## Schema Validation

```javascript
db.runCommand({
  collMod: "orders",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: [ "customerId", "status", "createdAt" ],
      properties: {
        customerId: { bsonType: "long" },
        status: { enum: [ "pending", "paid", "shipped", "cancelled" ] },
        amount: { bsonType: "decimal", minimum: 0 },
        createdAt: { bsonType: "date" }
      }
    }
  },
  validationLevel: "moderate",   // 只檢查新增與「原本就合法」的文件
  validationAction: "warn"       // 先只記 log，不擋寫入
})
```

導入順序：`warn` + `moderate` 觀察日誌 → 修正不合規的舊資料 → 改為 `error` + `strict`。

## 線上建索引

4.4 起建索引不再長時間鎖住 collection，並且在 Replica Set 上**同時**在所有資料節點建立：

```javascript
db.orders.createIndex(
  { customerId: 1, createdAt: -1 },
  { name: "customerId_1_createdAt_-1", commitQuorum: "votingMembers" }
)

// 觀察進度
db.currentOp({ "command.createIndexes": { $exists: true } })
```

超大 collection 若怕影響線上，可以用**滾動建索引**：一台一台把 secondary 以 standalone 模式啟動建索引，再 stepDown primary 處理最後一台。

## Schema 版本控管

MongoDB 沒有 DDL，但「索引、validator、資料回填」仍需版本控管：

| 工具 | 說明 |
| :--- | :--- |
| migrate-mongo（Node.js） | 輕量、以 up/down 腳本管理 |
| Mongock（Java） | 與 Spring 整合 |
| Liquibase MongoDB extension | 已用 Liquibase 管 RDBMS 的團隊可共用流程 |

```javascript
// migrate-mongo 範例：migrations/20261024-add-orders-index.js
module.exports = {
  async up(db) {
    await db.collection("orders").createIndex({ customerId: 1, createdAt: -1 });
  },
  async down(db) {
    await db.collection("orders").dropIndex("customerId_1_createdAt_-1");
  }
};
```

所有變更都要：**PR 審核 → 測試環境驗證 → 離峰執行 → 有回滾腳本**。

## 版本升級：8.0 → 9.0 滾動升級（Replica Set）

### 升級前

1. 先把 8.0 升到最新 patch（8.0.9 → 8.0.34）。
2. 閱讀 [9.0 相容性變更](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)，確認 driver 支援 9.0。
3. 確認 FCV 為 `8.0`，且沒有成員在 `ROLLBACK` / `RECOVERING`：

```javascript
db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 })
// { featureCompatibilityVersion: { version: "8.0" } }
db.adminCommand({ replSetGetStatus: 1 })
```

4. 先備份，並在 staging 完整演練一次。

### 升級步驟

```javascript
// 1. 逐台升級 secondary：關機 → 換 9.0 binary → 啟動 → 等回到 SECONDARY
db.adminCommand({ shutdown: 1 })

// 2. primary 讓位
rs.stepDown()

// 3. 升級原 primary

// 4. Burn-in 一段時間後，再開啟 9.0 的不相容功能
db.adminCommand({ setFeatureCompatibilityVersion: "9.0", confirm: true })
```

分片叢集的順序是：**停 balancer → config server → 各 shard → mongos → 開 balancer → 升 FCV**。

### 回滾方案

- **還沒升 FCV**：直接把 binary 換回 8.0 即可。
- **已升 FCV 9.0**：要先把 FCV 降回 `8.0`（並移除不相容的資料，例如用了新 `$convert` 轉換的 view），再換回 8.0 binary。官方只支援降一版（9.0 → 8.0）。

這也是為什麼官方強調 **binary 升級與 FCV 升級要分開、中間要有 burn-in 期**。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| Validation level | `off`、`moderate`、`strict` | 新增 **`constraint`**：所有寫入都套用規則，且保證所有既有文件都符合 | 9.0 |
| `$group` 空欄位名稱 | 允許 | accumulator 的欄位名稱為空字串時回傳錯誤 | 9.0 |
| 時間序列集合 | 不能 `renameCollection` | 可以 `renameCollection`；`timeField` 不可用 `$` 開頭 | 9.0 / 8.3 |
| 跨資料庫 `renameCollection` | 提早釋放來源鎖 | 全程持有來源與目標的排他鎖，期間 DDL 與寫入被阻擋 | 9.0 |
| `listIndexes` 輸出 | 不顯示 simple collation | FCV 9.0 時會出現 `collation: { locale: "simple" }` | SERVER-89953：Mongoose `syncIndexes()` 可能誤刪重建索引，需 Mongoose 9.10.4 / 8.24.5 以上 |
| 多鍵索引變化 | — | 查詢執行中欄位變成 multikey 時可能回傳 `QueryKilledError`，需重試 | 9.0 |
| `2dsphere` 索引版本 | 預設 v3 | 預設 **v4**；要降 FCV 到 8.3 以下需先刪除 v4 索引 | 8.3 起 |
| Index filter | 棄用，改用 `setQuerySettings` | 同 8.0 | |
| 升級路徑 | 7.0 → 8.0 | 8.0 或 8.3 → 9.0 | |
| 降級 | 8.0 → 7.0 | 9.0 → 8.0（只能一版） | 8.3 起 |
| FCV 升級 | `confirm: true` 必填（7.0 起） | 同；升到 9.0 時會隱含 `replSetReconfig`，分片叢集會搬移 metadata | 9.0 |
| 不相容功能（降級前需移除） | — | 例如 view 中使用 `$convert` 把 object 轉為 `binData` | 9.0 |
| `validate` 指令 | `full: true` 會自動檢查 BSON 合規 | 不再自動啟用 `checkBSONConformance`；改為檢查文件不超過 16MB；輸出有界並去重 | 8.3 / 9.0 |

### 給變更流程的升級建議

1. 使用 Mongoose 的專案，升 9.0 前先升 Mongoose，且不要在啟動時自動 `syncIndexes()`，改用 `diffIndexes()` 預覽。
2. 用 `constraint` validation level 取代「`strict` + 手動掃描舊資料」的流程。
3. 有用跨資料庫 `renameCollection` 做切換的腳本，要評估 9.0 全程鎖定帶來的寫入阻塞。

## 小結

- Schemaless 不代表不用管 schema：用 validator 守門、用 migration 工具管版本。
- 索引變更先 hide 再刪；大型索引考慮滾動建立。
- 升級永遠分兩段：**先換 binary、burn-in、再升 FCV**，回滾才有退路。

下一篇：[故障排查與事件處理]({% post_url 2026-10-24-mongodb-ops-09-troubleshooting %})。

### 參考資料

- [Schema Validation](https://www.mongodb.com/docs/manual/core/schema-validation/)
- [Index Builds on Populated Collections](https://www.mongodb.com/docs/manual/core/index-creation/)
- [Upgrade a Replica Set from 8.0 to 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-from-8.0-replica-set/)
- [Upgrade a Sharded Cluster to 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-upgrade-sharded-cluster/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
