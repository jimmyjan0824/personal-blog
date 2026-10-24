---
title: MongoDB 運維 04：監控與告警
date: 2026-10-24 09:53:00 +0800
categories: [MongoDB, 監控告警]
tags: [mongodb, mongodb8, mongodb9, dba, monitoring, serverstatus, prometheus, grafana, ftdc]
description: 以 MongoDB 8.0.9 為主，整理 serverStatus 核心指標、複製延遲、慢查詢日誌、FTDC、Prometheus + Grafana / PMM 監控與告警閾值，並比較 9.0.4 的差異。
---

監控的目的不是畫出漂亮的儀表板，而是「在使用者發現之前，先知道出事了」。本篇以 MongoDB 8.0.9 為主，整理該看哪些指標、怎麼收、閾值怎麼設，最後比較 9.0.4，其中 **9.0 有幾個 serverStatus 指標改名**，升級時會直接影響儀表板與告警。

{% include mongodb-ops-series.md %}

## 指標從哪裡來

| 來源 | 內容 | 用途 |
| :--- | :--- | :--- |
| `db.serverStatus()` | 連線、操作數、WiredTiger、佇列、記憶體 | 主要監控來源 |
| `rs.status()` | 成員狀態、optime | 複製延遲、成員健康 |
| `db.currentOp()` / `$currentOp` | 正在執行的操作 | 即時排查 |
| Profiler / 慢查詢日誌 | 慢操作細節 | 效能分析 |
| FTDC（`diagnostic.data`） | 每秒自動收集的診斷資料 | 事後分析、提供給官方支援 |
| `mongostat` / `mongotop` | 命令列即時觀察 | 臨時排查 |

## 核心指標

```javascript
const s = db.serverStatus();

// 1. 連線
s.connections                     // current、available、totalCreated

// 2. 吞吐量
s.opcounters                      // insert、query、update、delete、getmore、command
s.opcountersRepl                  // secondary 套用的操作數

// 3. 執行佇列（8.0 起由 wiredTiger.concurrentTransactions 改名）
s.queues.execution                // read / write 的 out、available、totalTickets

// 4. WiredTiger cache
const c = s.wiredTiger.cache;
c["bytes currently in the cache"] / c["maximum bytes configured"]   // cache 使用率
c["tracked dirty bytes in the cache"]                              // 髒頁

// 5. 斷言與錯誤
s.asserts
```

複製延遲：

```javascript
const st = rs.status();
const primary = st.members.find(m => m.stateStr === "PRIMARY");
st.members.filter(m => m.stateStr === "SECONDARY").forEach(m =>
  print(m.name, (primary.optimeDate - m.optimeDate) / 1000, "sec"));
```

## 告警閾值建議

| 指標 | 警告 | 嚴重 | 說明 |
| :--- | :--- | :--- | :--- |
| 節點存活 | — | 任一成員不是 PRIMARY/SECONDARY | 包含 RECOVERING、ROLLBACK |
| 沒有 primary | — | 持續 > 30 秒 | 無法寫入 |
| 複製延遲 | > 30 秒 | > 300 秒 | 依業務容忍度調整 |
| Oplog window | < 24 小時 | < 6 小時 | 太小會導致從節點需要重新 initial sync |
| 連線數 / 上限 | > 70% | > 90% | 常見於連線池設定錯誤 |
| WiredTiger cache 使用率 | > 90% | dirty > 20% | 達到 eviction 門檻時應用執行緒會被拉去做 eviction |
| 執行佇列等待 | 持續有排隊 | 排隊持續上升 | `queues.execution.*.out` 接近 `totalTickets` |
| 磁碟使用率 | > 75% | > 85% | MongoDB 刪資料不一定會還空間給 OS |
| 慢查詢數量 | 基線的 2 倍 | 基線的 5 倍 | 搭配 profiler 分析 |
| 選舉次數 | 非計畫性選舉 | 短時間多次 | 可能網路不穩或節點過載 |

## Prometheus + Grafana

自建最常見的方案是 **Percona mongodb_exporter + Prometheus + Grafana**，或直接用 **PMM（Percona Monitoring and Management）**。

```bash
# 監控帳號：clusterMonitor + read local
mongosh admin --eval '
db.createUser({
  user: "exporter", pwd: passwordPrompt(),
  roles: [ { role: "clusterMonitor", db: "admin" }, { role: "read", db: "local" } ]
})'

mongodb_exporter --mongodb.uri="mongodb://exporter:***@127.0.0.1:27017/admin" \
  --collect-all --compatible-mode
```

告警規則範例（指標名稱依 exporter 版本可能不同，請以實際輸出為準）：

```yaml
groups:
  - name: mongodb
    rules:
      - alert: MongoDBDown
        expr: mongodb_up == 0
        for: 1m
        labels: { severity: critical }
```

Atlas 則有內建告警，也可以串接 Datadog、PagerDuty 等。

## 慢查詢日誌與 Profiler

```javascript
// 只記錄超過 100ms 的操作，取樣 100%
db.setProfilingLevel(1, { slowms: 100, sampleRate: 1.0 })

// 查詢 profiler
db.system.profile.find({ millis: { $gt: 500 } }).sort({ ts: -1 }).limit(10)
```

8.0 起，Profiler 與慢查詢日誌改用 **`workingMillis`**（實際工作時間，不含排隊等待）判斷是否為慢操作，`durationMillis` 則是總時間。兩者差距大，代表時間花在**排隊**而非執行，應該看的是佇列與資源，而不是索引。

## FTDC

mongod 會自動把診斷資料寫到 `dbPath/diagnostic.data`，預設上限 8.0 是 200 MiB。出事後打包給官方支援，或用 `keyhole`、t2 等工具解析。不要關掉它，也不要在磁碟規劃時忽略它。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| 慢查詢判斷 | `workingMillis`（8.0 起） | 同 8.0 | |
| 慢查詢日誌 spill 資訊 | — | 依 stage 輸出 `sortSpills`、`sortSpilledBytes` 等 | 8.1 起 |
| 「執行中」的慢查詢 | 只有結束後才記錄 | 超過 `slowOpInProgressThreshold` 時記錄一次（`--defaultSlowInProgMS`） | 8.3 起，能抓到還沒跑完的長查詢 |
| 記憶體追蹤 | — | `$currentOp`、profiler、慢查詢日誌新增 `inUseTrackedMemBytes`、`peakTrackedMemBytes` | 8.3 起 |
| Query stats | 只涵蓋讀取類指令 | **預設以 1% 取樣啟用**，並涵蓋 `insert`/`update`/`delete` | 9.0；參數 `internalQueryStatsSampleRate`、`internalQueryStatsWriteCmdSampleRate` |
| `$queryStats` 輸出 | 基本 metrics | 新增 `metrics.cursor`、`queryExec`、`queryPlanner`、`writes` | 9.0；`keyHash` 會因 `allowPartialResults` 而改變 |
| 連線建立指標 | — | `connections.queuedForEstablishment`、`connections.establishmentRateLimit`、TLS / 認證耗時 | 8.2 起 |
| `serverStatus` 精簡輸出 | — | `serverStatus({ none: 1, ... })` 只取需要的區段 | 8.3 起，降低監控開銷 |
| 鎖競爭 | — | `lockContentionMetrics: 1` | 8.3 起 |
| 記憶體上限失敗 | — | `metrics.query.operationsFailedDueToMemoryLimit`、`peakMemoryUsageOperation` | 9.0 |
| Change stream 指標 | 少 | `metrics.changeStreams.cursor.open.total`、`.pinned`、`.lifespan` 等 | 9.0 |
| **指標改名** | `shardingStatistics.databaseVersionUpdateCounters`、`metrics.changeStreams.showExpandedEvents` | 改為 `shardingStatistics.databaseShardingMetadataStatistics`、`metrics.changeStreams.option.showExpandedEvents` | 9.0，**儀表板與告警要同步修改** |
| 移除的欄位 | `serverStatus` 有 `service` 欄位 | 移除 | 8.3 起 |
| FTDC 目錄上限 | 200 MiB | 500 MiB | 8.3 起 |
| Atlas 觀測 | — | 原生 OpenTelemetry 串接、重新設計的 Metrics UI | 9.0 同期推出的 Atlas 功能 |

### 給監控系統的升級建議

1. 升級前在測試環境用 9.0 跑一次 exporter，比對指標名稱差異，更新 Grafana 與告警規則。
2. 9.0 的 query stats 預設開啟，若有自己解析 `$queryStats` 的工具，注意 `keyHash` 的變化。
3. 規劃磁碟時多留 300 MiB 給 FTDC。

## 小結

- 先盯住五件事：**成員狀態、複製延遲、oplog window、cache 壓力、佇列等待**。
- `workingMillis` 與 `durationMillis` 的差距，是判斷「慢在執行還是慢在排隊」的好線索。
- 9.0 的監控能力大幅加強，但有指標改名，升級時別讓告警悄悄失效。

下一篇：[效能調校]({% post_url 2026-10-24-mongodb-ops-05-performance-tuning %})。

### 參考資料

- [serverStatus](https://www.mongodb.com/docs/manual/reference/command/serverStatus/)
- [Database Profiler](https://www.mongodb.com/docs/manual/tutorial/manage-the-database-profiler/)
- [Release Notes for MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
- [Percona mongodb_exporter](https://github.com/percona/mongodb_exporter)
