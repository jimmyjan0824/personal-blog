---
title: MongoDB 運維 05：效能調校
date: 2026-10-24 09:54:00 +0800
categories: [MongoDB, 效能調校]
tags: [mongodb, mongodb8, mongodb9, dba, performance, explain, index, query-settings]
description: 以 MongoDB 8.0.9 為主，整理 explain 執行計畫、索引設計 ESR 原則、Query Settings、defaultMaxTimeMS、WiredTiger 與連線池調校，並比較 9.0.4 的差異。
---

MongoDB 的效能問題，九成跟 MySQL 一樣出在**索引與查詢寫法**，剩下一成才是參數。本篇以 MongoDB 8.0.9 為主，整理慢查詢分析流程與 8.0 新增的 Query Settings，最後比較 9.0.4，其中 **9.0 新增的「單一操作記憶體上限」** 可能讓原本跑得動的大查詢直接失敗，升級前務必確認。

{% include mongodb-ops-series.md %}

## 調校流程

1. **找出慢查詢**：profiler、慢查詢日誌、Atlas Query Profiler / Performance Advisor。
2. **看執行計畫**：`explain("executionStats")`。
3. **修正**：加索引、改查詢、改資料模型。
4. **驗證**：比較 `totalDocsExamined`、`executionTimeMillis` 的前後差異。

## 讀懂 explain

```javascript
db.orders.find({ status: "A", customerId: 123 })
  .sort({ createdAt: -1 })
  .explain("executionStats")
```

重點欄位：

| 欄位 | 看什麼 |
| :--- | :--- |
| `winningPlan.stage` | `COLLSCAN` 是全表掃描；`IXSCAN` 才有用到索引；`EXPRESS_*` 是 8.0 的快速路徑 |
| `nReturned` | 回傳筆數 |
| `totalKeysExamined` | 掃描的索引鍵數 |
| `totalDocsExamined` | 掃描的文件數，理想情況接近 `nReturned` |
| `SORT` stage | 出現代表在記憶體排序，沒用到索引排序 |
| `executionTimeMillis` | 執行時間 |

**`totalDocsExamined / nReturned` 比值**是最直觀的指標：比值 1 很理想，比值 1000 代表掃了 1000 筆才找到 1 筆。

## 索引設計：ESR 原則

複合索引的欄位順序依照 **Equality → Sort → Range**：

```javascript
// 查詢：status = "A"、createdAt 範圍、依 amount 排序
db.orders.find({ status: "A", createdAt: { $gte: ISODate("2026-10-01") } })
  .sort({ amount: -1 })

// 索引：E（status）→ S（amount）→ R（createdAt）
db.orders.createIndex({ status: 1, amount: -1, createdAt: 1 })
```

其他原則：

- **覆蓋查詢（covered query）**：projection 只取索引中的欄位且排除 `_id`，就不需要讀文件。
- **部分索引（partial index）**：只對常查的子集合建索引，例如 `{ partialFilterExpression: { status: "A" } }`。
- **索引不是越多越好**：每個索引都會拖慢寫入、佔用 cache。用 `$indexStats` 找出沒在用的索引：

```javascript
db.orders.aggregate([{ $indexStats: {} }, { $project: { name: 1, "accesses.ops": 1 } }])
```

- 刪索引前先 **hide** 觀察一段時間，有問題可以立刻 unhide：

```javascript
db.orders.hideIndex("status_1_amount_-1")
db.orders.unhideIndex("status_1_amount_-1")
```

## Query Settings（8.0 新增）

8.0 新增 `setQuerySettings`，可以在**不改程式**的情況下，對特定 query shape 強制使用某個索引或直接拒絕執行，取代舊的 index filter（8.0 起棄用）：

```javascript
db.adminCommand({
  setQuerySettings: {
    find: "orders",
    filter: { status: "A", customerId: 123 },
    $db: "shop"
  },
  settings: {
    indexHints: {
      ns: { db: "shop", coll: "orders" },
      allowedIndexes: [ "status_1_customerId_1" ]
    }
  }
})

// 緊急情況：直接拒絕某個爛查詢
db.adminCommand({
  setQuerySettings: { find: "orders", filter: { note: { $regex: "x" } }, $db: "shop" },
  settings: { reject: true }
})

// 查看與移除
db.aggregate([{ $querySettings: {} }])
db.adminCommand({ removeQuerySettings: "<queryShapeHash>" })
```

設定以 query shape 為單位（相同結構、不同常數值視為同一個 shape），會在整個叢集生效，重啟後仍然存在。

## defaultMaxTimeMS（8.0 新增）

8.0 新增叢集參數 `defaultMaxTimeMS`，替所有沒有指定 `maxTimeMS` 的讀取操作加上預設逾時，防止失控查詢拖垮整個叢集：

```javascript
db.adminCommand({ setClusterParameter: { defaultMaxTimeMS: { readOperations: 5000 } } })
```

個別查詢仍可用 `maxTimeMS` 覆寫。

## 伺服器與連線調校

| 項目 | 建議 |
| :--- | :--- |
| WiredTiger cache | 維持預設；資料熱區放不進 cache 時優先加記憶體或分片 |
| 壓縮 | collection 用 `zstd` 換取更小的 IO 與磁碟用量 |
| 連線池 | driver 端設定 `maxPoolSize`，不要每個請求開新連線；總連線數 = 應用實例數 × maxPoolSize |
| 讀取分流 | 分析型查詢用 `secondary` 或專用的 analytics 節點（tag set） |
| 大量寫入 | 用 `bulkWrite`；8.0 新增可跨多個 collection 的 `bulkWrite` 指令 |
| 長交易 | 交易越短越好；預設 `transactionLifetimeLimitSeconds` 為 60 秒 |

## 資料模型才是根本

- 一起讀的資料放在一起（內嵌），避免大量 `$lookup`。
- 避免**無限成長的陣列**與接近 16MB 上限的大文件。
- 熱點計數器、時間序列資料考慮 bucket pattern 或時間序列集合。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| 官方效能宣稱 | 相較 7.0 讀取吞吐最高 +36% | 相較 8.0：find-one 最高快 35%、update-one 快 30%、交易吞吐 +20% | 皆為官方內部測試，實際依工作負載而定 |
| Plan 選擇 | Multi-planning | **Cost-Based Ranker（CBR）作為 multi-planning 的後援，為預設** | 8.3（8.3.3 起）；explain 與 serverStatus 有 `cbr` 相關指標 |
| **單一操作記憶體上限** | 無整體上限（只有 stage 級別的限制，如 `$group`、`$sort` 100MB） | 單一查詢上限為 1GB 或伺服器記憶體 20% 取大者；超過回傳 `ExceededMemoryLimit`（146）或 `QueryExceededMemoryLimitNoDiskUseAllowed`（292） | 9.0；`internalQueryMaxMemoryUsageBytesPerOperation` 可調 |
| 單一運算式記憶體 | — | `internalQueryMaxSingleExpressionMemoryUsageBytes`（預設 100MB） | 9.0 |
| Query Settings | `setQuerySettings`（叢集層級） | 另可在 `find`/`aggregate`/`distinct` 指令中直接帶 `querySettings` | 9.0；同 shape 的叢集設定優先 |
| 單一 shape 逾時 | 只能用 `defaultMaxTimeMS` 或在程式指定 | `setQuerySettings` 可設定 per-shape `maxTimeMS` | 9.0，需 FCV 9.0 |
| Query knobs | — | `queryKnobs` 可針對單一 query shape 覆寫內部參數 | 9.0，需 FCV 9.0 |
| 多文件交易上限 | 無 | `maxConcurrentMultiDocumentTransactions`（預設 10000），超過回傳 `TooManyOpenTransactions` | 9.0 |
| Cache 壓力處理 | — | `cachePressureQueryPeriodMilliseconds`：偵測到 cache 壓力時中止最舊的交易 | 8.3 起 |
| `$text` 的 `TextOr` | 無上限 | 限制 100MB，`allowDiskUse: true` 時可 spill | 8.3 起 |
| `$where` / `$function` / `$accumulator` | 棄用 | **取消棄用**，改在 WASM 沙箱執行；本地時間運算一律以 UTC 計算 | 9.0；有用到本地時區的 JS 函式結果會改變 |
| 執行佇列 | 預設不限制 ingress | 8.2 起有連線建立速率限制、8.3 起有 deprioritizable 佇列 | 搭配 Atlas 的 Intelligent Workload Management |

### 給效能調校的升級建議

1. 升級前用 9.0 測試環境重跑大型聚合、報表查詢，確認不會撞到新的**單一操作記憶體上限**；必要時加上 `allowDiskUse: true` 或拆分查詢。
2. 原本用 index filter 的地方，在 8.0 就改成 `setQuerySettings`。
3. 有使用 `$where` / `$function` 處理日期的程式，改用聚合運算子並明確指定 `timezone`。

## 小結

- 先看 `totalDocsExamined / nReturned`，再依 ESR 原則設計索引。
- 8.0 的 `setQuerySettings` 和 `defaultMaxTimeMS` 是 DBA 不改程式就能止血的兩大工具。
- 9.0 更快，但也更「嚴格」：記憶體上限與交易上限都是新的失敗模式。

下一篇：[容量規劃與擴展]({% post_url 2026-10-24-mongodb-ops-06-capacity-scaling %})。

### 參考資料

- [Explain Results](https://www.mongodb.com/docs/manual/reference/explain-results/)
- [The ESR (Equality, Sort, Range) Guideline](https://www.mongodb.com/docs/manual/tutorial/equality-sort-range-guideline/)
- [setQuerySettings](https://www.mongodb.com/docs/manual/reference/command/setQuerySettings/)
- [defaultMaxTimeMS](https://www.mongodb.com/docs/manual/reference/cluster-parameters/defaultMaxTimeMS/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [MongoDB 9.0: This Is What a Database Should Be](https://www.mongodb.com/company/blog/product-release-announcements/mongodb-9-0-this-is-what-a-database-should-be)
