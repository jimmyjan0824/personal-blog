---
title: Elasticsearch 運維 06：容量規劃與擴展
date: 2026-10-24 16:50:00 +0800
categories: [Elasticsearch, 容量規劃]
tags: [elasticsearch, elasticsearch9, elasticsearch8, capacity, shard-sizing, ilm, data-stream, data-tiers, rollover, scaling]
description: 以 Elasticsearch 9.5 為主，整理容量量測與成長預估、磁碟用量的組成、分片與節點數的估算、data stream 與 ILM / data stream lifecycle、hot / warm / cold / frozen 分層、水平擴展與分片重新分配，以及 split / shrink，並比較 8.19 的差異。
---

容量規劃要回答兩個問題：**現在多大、多久會滿**，以及**滿了之後怎麼辦**。Elasticsearch 的好處是水平擴展很直接（加節點，分片自動搬過去），難處是**主分片數建立後不能改**，所以要在一開始就把資料的生命週期想清楚。本篇最後比較 8.19 的差異。

{% include elasticsearch-ops-series.md %}

## 量測現況

```console
GET _cat/allocation?v&h=node,shards,disk.indices,disk.used,disk.avail,disk.total,disk.percent&s=node
GET _cat/indices?v&h=index,pri,rep,docs.count,store.size,pri.store.size&s=pri.store.size:desc
GET _cluster/stats?filter_path=indices.count,indices.shards.total,indices.docs.count,indices.store.size_in_bytes,nodes.count
```

每天記錄一次 `pri.store.size`（主分片大小）與 `docs.count`，就能算出成長率。日誌類資料看「每天新增多少」，業務資料看「總量成長率」。

## 磁碟用量的組成

```text
需要的磁碟 = 原始資料 × 膨脹係數 × (1 + 副本數) ÷ (1 - 預留比例)
```

| 項目 | 估算 |
| :--- | :--- |
| 膨脹係數 | 一般 JSON 文件約 **1.0～1.5 倍**（倒排索引 + doc values + `_source`）；logsdb 模式（9.x 日誌預設）可降到約 0.3～0.5 倍；實際值請用一天的樣本資料量測 |
| 副本 | `number_of_replicas: 1` → 2 倍 |
| 預留比例 | 至少 **15%**（低水位 85%），再加上 merge 暫時需要的空間與一台節點故障時的重新分配空間 |

**一台節點故障時，剩下的節點要能放下它的分片**。3 台 data 節點各 1 TB，可用的其實只有約 `3 TB × 85% × 2/3 ≈ 1.7 TB`（含副本），換算主分片資料約 850 GB。

## 分片與節點數

1. 估算總主分片資料量（含未來 12～18 個月成長）。
2. 依 10～50 GB 決定主分片數。
3. 主分片數 × (1 + 副本數) = 總分片數。
4. 依每台 data 節點的磁碟與記憶體決定節點數：

| data 節點規格 | 適合的資料量（主 + 副本） | 說明 |
| :--- | :--- | :--- |
| 16 GB RAM / 8 GB heap | 約 0.5～1 TB | 搜尋為主、延遲要求高時資料量取下緣（讓更多 segment 留在 page cache） |
| 64 GB RAM / 31 GB heap | 約 2～6 TB | 日誌為主 |
| frozen tier | 可達數十 TB | 資料在快照儲存庫，本機只有快取 |

這裡的「記憶體 : 磁碟」比例（搜尋類約 1:16～1:64、日誌類約 1:100 以上）是業界常見的起點，**最後一定要用實際資料與查詢做壓測**（Rally）。

## Data stream 與 rollover

時序資料（日誌、事件、指標）應該用 **data stream**：

```console
PUT _index_template/app-logs
{
  "index_patterns": ["app-logs-*"],
  "data_stream": {},
  "priority": 200,
  "template": {
    "settings": { "index.lifecycle.name": "app-logs-policy" }
  }
}

POST app-logs-web/_doc
{ "@timestamp": "2026-10-24T08:00:00Z", "message": "hello" }

GET _data_stream/app-logs-web
```

- data stream 背後是一連串的 `.ds-app-logs-web-2026.10.24-000001` backing index，寫入一律進最新的那個。
- **rollover** 在達到條件時建立新的 backing index：主分片數不用一開始就決定很多，每個 backing index 都長到合適的大小。
- data stream 只能 append；更新與刪除要用 `_update_by_query` / `_delete_by_query` 或直接對 backing index 操作。

## ILM 與 data stream lifecycle

### ILM（Index Lifecycle Management）

```console
PUT _ilm/policy/app-logs-policy
{
  "policy": {
    "phases": {
      "hot":    { "actions": { "rollover": { "max_primary_shard_size": "50gb", "max_age": "1d" } } },
      "warm":   { "min_age": "7d",  "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 } } },
      "cold":   { "min_age": "30d", "actions": { "searchable_snapshot": { "snapshot_repository": "s3_repo" } } },
      "delete": { "min_age": "180d", "actions": { "delete": {} } }
    }
  }
}

GET app-logs-*/_ilm/explain?only_errors=true
```

- `min_age` 從 **rollover 的時間**開始算（不是索引建立時間）。
- ILM 每 `indices.lifecycle.poll_interval`（預設 10 分鐘）檢查一次，不會即時執行。
- `searchable_snapshot` 在 cold phase 需要 Enterprise 授權；Basic 授權可以用 `allocate` 把索引搬到便宜的節點、再 `delete`。

### Data stream lifecycle（DSL）

8.14 起 GA，比 ILM 簡單：只描述「保留多久」，rollover、merge 由 Elasticsearch 自動處理。

```console
PUT _data_stream/app-logs-web/_lifecycle
{ "data_retention": "30d" }
```

只需要「保留 N 天後刪除」的資料用 DSL；需要分層搬移、shrink、searchable snapshot 的用 ILM。

## 資料分層（data tiers）

| 層 | 角色 | 硬體 | 資料 |
| :--- | :--- | :--- | :--- |
| hot | `data_hot` | 最快的 NVMe、較多 CPU | 正在寫入、最常查詢 |
| warm | `data_warm` | 大容量 SSD / HDD | 不再寫入、偶爾查詢 |
| cold | `data_cold` | 大容量、可搭配 searchable snapshot（fully mounted） | 很少查詢 |
| frozen | `data_frozen` | 小磁碟當快取，資料在物件儲存（partially mounted） | 保留用、幾乎不查 |
| content | `data_content` | — | 非時序資料（商品、使用者），不參與 ILM 分層 |

節點設 `node.roles: [ data ]` 等於同時具備所有 tier；只有一種硬體時就這樣設，不需要分層。

## 水平擴展

### 加 data 節點

新節點設好相同的 `cluster.name`、`discovery.seed_hosts` 與憑證後啟動，master 就會開始把分片搬過去（[三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})有加入第 4 台的實測）。搬移速度由下列參數控制：

| 參數 | 預設 | 說明 |
| :--- | :--- | :--- |
| `cluster.routing.allocation.cluster_concurrent_rebalance` | 2 | 整個叢集同時搬移的分片數 |
| `cluster.routing.allocation.node_concurrent_recoveries` | 2 | 每個節點同時進行的復原（進 / 出） |
| `indices.recovery.max_bytes_per_sec` | 40mb | 每個節點的復原頻寬上限 |

離峰時段可以暫時調高，搬完再改回：

```console
PUT _cluster/settings
{ "persistent": { "indices.recovery.max_bytes_per_sec": "200mb", "cluster.routing.allocation.node_concurrent_recoveries": 4 } }
```

### 主分片數不夠時

| 做法 | 條件 | 說明 |
| :--- | :--- | :--- |
| `_split` | 新的分片數是原本的倍數；索引要先設唯讀 | 用 hard link，很快 |
| `_shrink` | 新的分片數是原本的因數；所有主分片要先集中到同一個節點 | 用於 warm phase 減少分片 |
| `_reindex` | 無 | 最彈性也最慢，可以同時改 mapping |
| rollover | data stream / alias | 不改舊索引，只讓新的 backing index 用新的分片數 |

```console
PUT orders/_settings
{ "index.blocks.write": true }
POST orders/_split/orders-v2
{ "settings": { "index.number_of_shards": 6 } }
```

### 讀取擴展

搜尋量大時可以增加副本數（`number_of_replicas: 2`），每多一份副本就多一組可以處理搜尋的分片，但寫入成本與磁碟也同步增加。

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| 日誌的儲存空間 | logsdb 要手動開 | `logs-*-*` 預設 logsdb，膨脹係數明顯下降 |
| 時序指標 | TSDS | TSDS + 9.5 的 ES95 codec（官方宣稱每筆樣本約 3 bytes） |
| 欄式儲存 | 無 | Columnar 模式（9.5 技術預覽） |
| Failure store（寫入失敗的文件另存） | 技術預覽 | GA（9.1 起），mapping 錯誤的文件不會直接遺失 |
| ILM / DSL / 資料分層 | 有 | 相同 |
| 7.x 建立的索引 | 可以讀寫 | 只能唯讀，要寫入必須在 8.x 先 reindex |

### 給容量規劃的升級建議

- 升級到 9.x 後，日誌類資料的容量估算要用新的膨脹係數重新量測，可能省下不少磁碟。
- 升級前用 `GET _migration/deprecations` 找出 7.x 建立的索引，安排 reindex 或讓 ILM 自然刪除。
- frozen / searchable snapshot 的儲存庫版本要跟著叢集升級前的快照相容性規則走（見[備份與還原]({% post_url 2026-10-24-elasticsearch-ops-02-backup-restore %})）。

## 小結

- 磁碟估算要算膨脹係數、副本、15% 預留，以及一台節點故障時的重新分配空間。
- 時序資料用 data stream + ILM（或 DSL），用 rollover 控制分片大小。
- 加節點是最直接的擴展方式，搬移速度由 recovery 參數控制。
- 主分片不夠時用 split、太多時用 shrink，最彈性的是 reindex。

下一篇：[安全與權限管理]({% post_url 2026-10-24-elasticsearch-ops-07-security %})。

### 參考資料

- [Elasticsearch 文件：Size your shards](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/size-shards)
- [Elasticsearch 文件：Data streams](https://www.elastic.co/docs/manage-data/data-store/data-streams)
- [Elasticsearch 文件：Index lifecycle management](https://www.elastic.co/docs/manage-data/lifecycle/index-lifecycle-management)
- [Elasticsearch 文件：Data stream lifecycle](https://www.elastic.co/docs/manage-data/lifecycle/data-stream)
- [Elasticsearch 文件：Data tiers](https://www.elastic.co/docs/manage-data/lifecycle/data-tiers)
- [Elasticsearch 文件：Split index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-split)
