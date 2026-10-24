---
title: Elasticsearch 運維 05：效能調校
date: 2026-10-24 16:40:00 +0800
categories: [Elasticsearch, 效能調校]
tags: [elasticsearch, elasticsearch9, elasticsearch8, performance, bulk, refresh, mapping, profile, cache, jvm, shard-sizing]
description: 以 Elasticsearch 9.5 為主，依「先看分片與 mapping，再看寫入、搜尋，最後才是 JVM 與 OS」的順序整理效能調校：分片大小、mapping 設計、bulk 寫入、refresh 與 translog、查詢改寫與 profile、快取、force merge、heap 與 OS 參數，並比較 8.19 的差異。
---

Elasticsearch 的效能問題，多數出在**分片規劃與 mapping**，其次是寫入與查詢的用法，最後才輪到 JVM 與參數。本篇照這個順序整理，所有參數的完整清單與預設值在[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})與 [三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %}) 兩篇實作的設定檔裡。

{% include elasticsearch-ops-series.md %}

## 第一步：分片

| 原則 | 建議 |
| :--- | :--- |
| 分片大小 | **10～50 GB**（搜尋為主取下緣、日誌為主取上緣） |
| 每個分片的文件數 | 不超過約 2 億筆 |
| 主分片數 | 依「預估總量 ÷ 目標分片大小」決定，日誌類用 rollover 控制大小，不要預先切很多 |
| 每個節點的分片數 | 越少越好；8.3 起每個分片的 heap 開銷大幅降低，舊的「每 GB heap 20 個分片」已不是硬規則，但分片太多仍會拖慢 master 與恢復速度 |

- **太多小分片**是最常見的效能問題：每個分片都是一個 Lucene index，有自己的 segment、檔案描述元、查詢時的固定開銷；查詢 1000 個 1 MB 的分片比查詢 1 個 1 GB 的分片慢很多。
- 用 `index.number_of_shards: 1` 當預設（8.x / 9.x 的預設值就是 1），只有預估會超過 50 GB 的索引才多切。
- 時序資料用 **data stream + ILM rollover**（`max_primary_shard_size: 50gb`），讓每個 backing index 自然長到合適的大小。

```console
# 找出過小的分片
GET _cat/shards?v&h=index,shard,prirep,store,docs&s=store:asc
```

## 第二步：mapping

| 問題 | 做法 |
| :--- | :--- |
| 動態 mapping 自動產生 `text` + `keyword` 兩份 | 明確定義 mapping；只用來過濾 / 聚合的字串用 `keyword`，要全文檢索才用 `text` |
| 欄位爆炸（mapping explosion） | `dynamic: strict` 或 `false`；`index.mapping.total_fields.limit` 預設 1000，不要隨便調高 |
| 數字當 ID 用 | ID、代碼類欄位用 `keyword`，`term` 查詢比 `long` 的 range 結構快 |
| 不需要搜尋的欄位 | `"index": false`；也不需要聚合排序就再加 `"doc_values": false` |
| 不需要算分 | 放在 `bool.filter` 裡（可以快取、不計算相關度） |
| 大量 nested | nested 文件在 Lucene 裡是獨立的文件，`index.mapping.nested_objects.limit` 預設 10000，能攤平就攤平 |

```console
PUT _index_template/orders
{
  "index_patterns": ["orders-*"],
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "order_id":   { "type": "keyword" },
        "status":     { "type": "keyword" },
        "amount":     { "type": "scaled_float", "scaling_factor": 100 },
        "created_at": { "type": "date" },
        "note":       { "type": "text", "analyzer": "standard" },
        "raw_payload":{ "type": "object", "enabled": false }
      }
    }
  }
}
```

中文全文檢索要裝分詞外掛（IK、smartcn 等），`standard` analyzer 會把中文切成單字，召回率高但精確度與效能都比較差。

## 第三步：寫入

### Bulk

- 一律用 `_bulk`，**每批 5～15 MB** 起測，逐步調大直到吞吐不再上升。
- 多個用戶端平行送；`write` 執行緒池回 `429` 時要退避重試。
- 文件 ID 讓 Elasticsearch 自動產生（`POST index/_doc`），自訂 ID 時每筆都要先查是否已存在。

### 大量匯入時的暫時設定

```console
PUT orders-2026.10/_settings
{ "index": { "refresh_interval": "-1", "number_of_replicas": 0 } }

# ... 匯入 ...

PUT orders-2026.10/_settings
{ "index": { "refresh_interval": null, "number_of_replicas": 1 } }
POST orders-2026.10/_refresh
```

設成 `null` 會回到預設值。匯入完成後再加副本，副本會直接複製主分片的 segment，比每份文件都在副本上重新寫一次快。

### refresh、translog 與 flush

| 參數 | 預設 | 說明 |
| :--- | :--- | :--- |
| `index.refresh_interval` | `1s` | 多久讓新文件可以被搜尋到。日誌類可以設 `30s`，大幅降低 segment 數與 merge 壓力 |
| `index.search.idle.after` | `30s` | 沒有設定 `refresh_interval` 的索引，若這段時間沒有搜尋就暫停定期 refresh，直到下一次搜尋 |
| `index.translog.durability` | `request` | 每個請求 fsync translog。改成 `async` 可提升寫入，但當機會遺失最多 `sync_interval` 的資料 |
| `index.translog.flush_threshold_size` | `10gb`（8.x 起） | translog 累積多少就 flush（Lucene commit） |
| `indices.memory.index_buffer_size` | 節點 heap 的 `10%` | 所有分片共用的寫入緩衝區，寫入很重的節點可以調到 15～20% |

> `index.search.idle.after` 是很多人不知道的行為：沒有明確設定 `refresh_interval` 的索引，在沒人查詢時根本不 refresh，第一次查詢會**等 refresh 完才回應**。需要穩定查詢延遲的索引，明確設定 `refresh_interval: 1s` 就不會進入 search idle。
{: .prompt-info }

### Ingest pipeline 與 coordinating

- 複雜的 ingest pipeline（grok、script）很吃 CPU，量大時放專用的 ingest 節點，或在 Logstash / Agent 端先處理。
- 大量 bulk 的 coordinating 工作（拆分、轉送）也會消耗記憶體，`indexing_pressure.memory.limit` 預設是 heap 的 10%，超過就回 `429`。

## 第四步：搜尋

### 先量測：profile 與慢日誌

```console
GET orders-*/_search
{
  "profile": true,
  "query": { "bool": { "filter": [ { "term": { "status": "paid" } }, { "range": { "created_at": { "gte": "now-7d" } } } ] } }
}
```

`profile` 會列出每個分片、每個查詢子句的耗時（`create_weight`、`next_doc`、`score` 等），在 Kibana 的 Search Profiler 看比較直觀。

### 查詢改寫

| 慢的寫法 | 改寫 |
| :--- | :--- |
| `query_string` / `wildcard` 開頭是 `*`（`*abc`） | 用 `wildcard` 欄位型別、n-gram，或重新設計需求 |
| 不需要相關度卻放在 `must` | 放到 `filter`，可以被 query cache 快取 |
| `from` + `size` 深分頁（超過 `index.max_result_window` 10000） | `search_after` + PIT（point in time） |
| 大量 `terms` 聚合的 `size` 設很大 | 改用 `composite` 聚合分頁取回 |
| script 查詢 / script 排序 | 在寫入時算好存成欄位（runtime field 適合探索，不適合高頻查詢） |
| 每次查詢 `track_total_hits: true` | 預設只精確計數到 10000，維持預設即可 |
| `range` 查詢用 `now`（毫秒） | 用 `now/m` 之類的捨入，讓 request cache 能命中 |

### 快取

| 快取 | 範圍 | 預設大小 | 說明 |
| :--- | :--- | :--- | :--- |
| Node query cache | filter 子句的結果 | heap 的 `10%`（`indices.queries.cache.size`） | 只快取在大 segment 上、被重複使用的 filter |
| Shard request cache | `size: 0` 的查詢結果（聚合） | heap 的 `1%`（`indices.requests.cache.size`） | refresh 後失效，適合不常變動的索引與儀表板 |
| Fielddata | `text` 欄位的聚合 / 排序 | 無上限（受 fielddata 斷路器 40% 限制） | **不要在 text 欄位上開 fielddata**，改用 keyword |
| OS page cache | segment 檔 | 剩下的實體記憶體 | **最重要的快取**：heap 不要超過 RAM 的一半 |

### Force merge

不再寫入的索引（例如昨天以前的日誌）可以合併成 1 個 segment，查詢更快、占用更少：

```console
POST logs-2026.10.23/_forcemerge?max_num_segments=1
```

**不要對還在寫入的索引做 force merge**：會產生超大的 segment，之後的刪除與更新會讓它留下大量的已刪除文件，又很難再被合併掉。ILM 的 warm phase 可以自動做這件事。

## 第五步：JVM 與 OS

### Heap

| 原則 | 說明 |
| :--- | :--- |
| 大小 | 8.x / 9.x 預設**依節點角色與實體記憶體自動計算**，官方建議多數情況用預設值 |
| 手動設定 | `-Xms` 與 `-Xmx` 相同；不超過實體記憶體的 50%；不超過約 **31 GB**（compressed oops 的門檻） |
| GC | 內建 JDK 預設 G1GC，不要自己換 |
| 確認 | `GET _nodes/_local/jvm` 的 `using_compressed_ordinary_object_pointers` 要是 `true` |

### OS

| 項目 | 建議 | 原因 |
| :--- | :--- | :--- |
| swap | **關閉**（或 `vm.swappiness=1` + `bootstrap.memory_lock: true`） | heap 被 swap 出去時 GC 會慢到節點被判定離線 |
| `vm.max_map_count` | 至少 `262144`（RPM 已內建 `/usr/lib/sysctl.d/elasticsearch.conf`） | Lucene 用 mmap 讀 segment |
| 檔案描述元 | 65535（RPM 的 systemd unit 已設定） | 每個 segment 檔都要一個 |
| `net.ipv4.tcp_retries2` | `5` | 網路斷線時更快偵測，避免節點離線偵測卡 15 分鐘 |
| 磁碟 | 本機 SSD / NVMe；**不要用 NFS 放 `path.data`** | Lucene 對延遲非常敏感 |
| 檔案系統 | XFS 或 ext4，`noatime` | — |
| 預讀 | SSD 的 readahead 設 128 KB 以下 | 過大的 readahead 會浪費 page cache |

## 調校的優先順序

1. 分片大小與數量合理（10～50 GB、沒有大量小分片）。
2. mapping 明確，沒有欄位爆炸、沒有 text 欄位的 fielddata。
3. 寫入用 bulk，匯入時暫時關 refresh 與副本；日誌類 `refresh_interval: 30s`。
4. 查詢把過濾條件放 `filter`，避免深分頁、前置萬用字元與 script。
5. heap 用自動計算、不超過 RAM 的一半，關 swap。
6. 最後才調 thread pool、breaker 等進階參數（多數情況不該動）。

> 不要調高 `thread_pool.write.queue_size` 或 `thread_pool.search.queue_size` 來「解決」rejected：佇列變長只會讓延遲變高、heap 用量變大，真正的處理能力沒有改變。rejected 的解法是降低請求量、改善查詢，或加節點。
{: .prompt-warning }

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| Lucene | 9.x | **10.x**（新的 segment 格式、I/O 平行化等） |
| 日誌類 data stream（`logs-*-*`） | logsdb 模式要手動開 | **9.0 起預設 logsdb**：以 host / 時間排序、更好的壓縮，儲存空間明顯下降 |
| 時序索引 codec | — | 9.5 起新的時序索引預設 ES95 doc values codec，merge 預設更積極 |
| 欄式儲存 | 無 | 9.5 技術預覽：Columnar 模式（不建倒排索引、欄式儲存），日誌專用的 Columnar Logs |
| 向量搜尋 | HNSW、int8 / BBQ 量化 | BBQ 成為新向量索引的主流預設，9.5 新增 VectorDB index mode 與 DiskBBQ 自動校正 |
| merge policy 預設（`floor_segment` / `segments_per_tier` / `max_merge_at_once`） | 2mb / 10 / 10 | **16mb / 8 / 16**（實測），小 segment 更早被合併 |
| `thread_pool.search.queue_size` | 1000 | **16000**（實測） |
| Heap 自動計算 | 有 | 相同（實測 7.7 GB 的主機都算出約 50%） |

### 給效能調校的升級建議

- 升級到 9.x 後，`logs-*-*` 的新 backing index 會改用 logsdb，查詢行為不變，但 `_source` 可能是合成的（synthetic source，視授權而定），依賴 `_source` 原樣格式（欄位順序、空白）的程式要測試。
- 新的 codec 只套用在**升級後新建立**的索引，舊索引要等 rollover 或 reindex。
- 從 8.19 帶過來的 `elasticsearch.yml` 若明確寫了 `thread_pool.search.queue_size: 1000`，升級後仍是 1000，不會變成 9.x 的 16000；索引範本裡寫死的 merge policy 也一樣。
- 效能測試用 [Rally](https://github.com/elastic/rally) 在新舊版本跑同一組 track 比較，不要只看單一查詢。

## 小結

- 先處理分片（10～50 GB）與 mapping，這兩個是效能問題的大宗。
- 寫入用 bulk，日誌類 refresh 拉長；查詢條件放 filter，避免深分頁。
- heap 用預設的自動計算、不超過 RAM 一半，剩下的留給 page cache；關 swap。
- 不要用加大佇列的方式處理 rejected。

下一篇：[容量規劃與擴展]({% post_url 2026-10-24-elasticsearch-ops-06-capacity-scaling %})。

### 參考資料

- [Elasticsearch 文件：Tune for indexing speed](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/indexing-speed)
- [Elasticsearch 文件：Tune for search speed](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/search-speed)
- [Elasticsearch 文件：Size your shards](https://www.elastic.co/docs/deploy-manage/production-guidance/optimize-performance/size-shards)
- [Elasticsearch 文件：Advanced configuration（JVM heap）](https://www.elastic.co/docs/reference/elasticsearch/jvm-settings)
- [Elasticsearch 文件：Important system configuration](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/important-system-configuration)
- [Elastic 9.5 新功能](https://www.elastic.co/blog/whats-new-elastic-9-5-0)
- [elastic/rally](https://github.com/elastic/rally)
