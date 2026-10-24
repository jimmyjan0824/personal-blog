---
title: Elasticsearch 運維 04：監控與告警
date: 2026-10-24 16:30:00 +0800
categories: [Elasticsearch, 監控]
tags: [elasticsearch, elasticsearch9, elasticsearch8, monitoring, cat-api, node-stats, metricbeat, elastic-agent, prometheus, alerting]
description: 以 Elasticsearch 9.5 為主，整理監控指標分層、_cluster/health、_cat 與 _nodes/stats 該看哪些欄位、Health API、慢查詢日誌、Stack Monitoring（Elastic Agent / Metricbeat）與 Prometheus exporter 架構，以及告警閾值設計，並比較 8.19 的差異。
---

監控的目的是**在使用者發現之前知道出事了，並且有足夠的資料找出原因**。Elasticsearch 的 REST API 本身就是最完整的監控介面，本篇整理該看哪些指標、怎麼收集、告警怎麼設，最後比較 8.19 的差異。

{% include elasticsearch-ops-series.md %}

## 指標分層

| 層級 | 指標 | 來源 |
| :--- | :--- | :--- |
| 叢集 | 健康狀態、未分配分片、pending tasks、master 是否穩定 | `_cluster/health`、`_health_report`、`_cluster/pending_tasks` |
| 節點 | heap 使用率、GC 次數與時間、CPU、load、磁碟用量、檔案描述元 | `_nodes/stats`、`_cat/nodes`、`_cat/allocation` |
| 執行緒池 | `write`、`search` 的 active / queue / **rejected** | `_cat/thread_pool`、`_nodes/stats/thread_pool` |
| 索引 | 寫入速率與延遲、搜尋速率與延遲、refresh / merge / flush 時間、文件數、大小 | `_stats`、`_cat/indices` |
| 斷路器 | 各 breaker 的使用量與 tripped 次數 | `_nodes/stats/breaker` |
| OS | 磁碟 I/O、網路、swap、記憶體 | node_exporter 等 |

## 叢集健康

```console
GET _cluster/health?filter_path=status,number_of_nodes,number_of_data_nodes,active_shards_percent_as_number,unassigned_shards,initializing_shards,relocating_shards,number_of_pending_tasks,task_max_waiting_in_queue_millis
```

| 欄位 | 告警建議 |
| :--- | :--- |
| `status` | `red` 立即告警；`yellow` 持續超過 10 分鐘告警（節點重啟時短暫 yellow 是正常的） |
| `number_of_nodes` | 少於預期節點數就告警 |
| `unassigned_shards` | 持續 > 0 超過延遲分配時間（預設 1 分鐘）加上復原時間 |
| `number_of_pending_tasks` / `task_max_waiting_in_queue_millis` | 長時間大於 0 代表 master 處理不過來（常見原因：分片太多、mapping 頻繁變動） |

### Health API（8.7+）

`_health_report` 不只回報 green / yellow / red，還會**指出原因與建議的處置**：

```console
GET _health_report?verbose=false
GET _health_report/shards_availability
GET _health_report/disk
```

它的指標（indicator）包括 `master_is_stable`、`shards_availability`、`disk`、`ilm`、`slm`、`shards_capacity`、`repository_integrity` 等，每個都有 `symptom` 與 `impacts`，很適合直接接到告警訊息裡。

## _cat API：人看的快速檢查

```console
GET _cat/nodes?v&h=name,node.role,master,heap.percent,ram.percent,cpu,load_1m,disk.used_percent&s=name
GET _cat/allocation?v&s=disk.percent:desc
GET _cat/indices?v&h=health,status,index,pri,rep,docs.count,store.size,pri.store.size&s=store.size:desc
GET _cat/shards?v&h=index,shard,prirep,state,docs,store,node,unassigned.reason&s=state
GET _cat/thread_pool/write,search?v&h=node_name,name,active,queue,rejected,completed
GET _cat/recovery?v&active_only=true
GET _cat/pending_tasks?v
```

`_cat` 是給人看的，欄位與格式可能隨版本調整，**程式化的監控要用 JSON 的 `_nodes/stats`、`_stats`**。

## 節點層級：_nodes/stats

```console
GET _nodes/stats/jvm,os,fs,thread_pool,breaker,indices?filter_path=nodes.*.name,nodes.*.jvm.mem.heap_used_percent,nodes.*.jvm.gc,nodes.*.os.cpu,nodes.*.fs.total,nodes.*.thread_pool.write,nodes.*.thread_pool.search,nodes.*.breakers
```

### JVM heap 與 GC

- `jvm.mem.heap_used_percent`：G1 GC 下會呈鋸齒狀，**看低點（GC 後的使用率）**才有意義。低點持續上升超過 75～85% 代表 heap 不夠或有記憶體壓力（fielddata、太多分片、超大的聚合）。
- `jvm.gc.collectors.old.collection_count` / `collection_time_in_millis`：G1 的 old 一般很少發生，若頻繁出現就是 heap 壓力的訊號。
- 日誌中的 `[gc][...] overhead, spent [x] collecting in the last [y]` 是 Elasticsearch 自己的 GC 監控（`JvmGcMonitorService`），出現 `WARN` 等級時要注意。

### 執行緒池的 rejected

| 執行緒池 | 用途 | rejected 代表 |
| :--- | :--- | :--- |
| `write` | bulk、index、update、delete | 寫入速度超過叢集處理能力，用戶端收到 `429 Too Many Requests` |
| `search` | 搜尋 | 查詢太重或太多 |
| `get` | GET by id | — |
| `management`、`generic` | 叢集管理 | 這些滿了通常代表叢集本身有問題 |

`rejected` 是累計值，告警要看**每分鐘的增量**。`429` 不一定是壞事（代表背壓有效），但用戶端一定要有重試與退避（官方 client 與 Logstash / Beats 都有）。

### 斷路器

```console
GET _nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers.*.estimated_size,nodes.*.breakers.*.limit_size,nodes.*.breakers.*.tripped
```

`parent` breaker 的 `tripped` 增加代表有請求因為 heap 不足而被拒絕（`circuit_breaking_exception`），比 OOM 好，但要找出是哪一類請求造成的。

## 索引層級

```console
GET _stats/indexing,search,refresh,merge,flush?filter_path=_all.total
GET orders/_stats/indexing,search?level=shards
```

算延遲要用兩次取樣的差值：`(index_time_in_millis 差) / (index_total 差)` 就是平均每份文件的寫入時間；搜尋同理用 `query_time_in_millis` 與 `query_total`。

## 慢查詢與慢寫入日誌

慢日誌是**索引層級**的設定（預設全部關閉，`-1`），建議用索引範本統一設定：

```console
PUT _component_template/slowlog
{
  "template": {
    "settings": {
      "index.search.slowlog.threshold.query.warn": "5s",
      "index.search.slowlog.threshold.query.info": "2s",
      "index.search.slowlog.threshold.fetch.warn": "1s",
      "index.indexing.slowlog.threshold.index.warn": "5s",
      "index.indexing.slowlog.threshold.index.info": "2s",
      "index.indexing.slowlog.source": "1000"
    }
  }
}
```

RPM 安裝的日誌在 `/var/log/elasticsearch/`：

| 檔案 | 內容 |
| :--- | :--- |
| `<cluster.name>.log` | 主要日誌（純文字） |
| `<cluster.name>_server.json` | 同一份內容的 JSON 格式（ECS），給 Filebeat / Elastic Agent 收 |
| `<cluster.name>_index_search_slowlog.json` | 慢查詢 |
| `<cluster.name>_index_indexing_slowlog.json` | 慢寫入 |
| `<cluster.name>_deprecation.json` | 棄用功能的使用紀錄，**升級前一定要看** |
| `gc.log` | JVM GC 日誌 |

另外 `index.search.slowlog.include.user: true`（8.x 起）可以在慢查詢日誌記錄是哪個使用者發出的查詢，追查問題來源很有用。

## 收集架構

### Stack Monitoring（Elastic Agent / Metricbeat）

官方建議的做法：**另外建一個監控叢集**，用 Elastic Agent（或 Metricbeat）的 Elasticsearch 整合收集各節點的指標，在 Kibana 的 Stack Monitoring 介面看。

```text
 正式叢集 esc1~esc3 ──(Elastic Agent / Metricbeat，xpack 模式)──► 監控叢集 ──► Kibana Stack Monitoring
          └──(Filebeat / Agent 收 *_server.json、slowlog)───────────┘
```

- **不要把監控資料寫回被監控的叢集**：叢集出事時監控也跟著看不到。
- 舊的「內部收集」（`xpack.monitoring.collection.enabled`）已經棄用，新建置不要用。
- 監控叢集本身可以是小型的單節點或三節點，保留 7～30 天即可。

### Prometheus + Grafana

已經有 Prometheus 的團隊可以用社群的 [elasticsearch_exporter](https://github.com/prometheus-community/elasticsearch_exporter)：

```bash
elasticsearch_exporter \
  --es.uri=https://monitor:password@esc1:9200 \
  --es.ca=/etc/elasticsearch-exporter/ca.crt \
  --es.all --es.indices --es.shards --collector.snapshots
```

- 用專門的監控帳號，內建角色 `monitoring_user` 或自訂只有 `monitor` 叢集權限的角色即可（[安全篇]({% post_url 2026-10-24-elasticsearch-ops-07-security %})）。
- `--es.indices`、`--es.shards` 在索引與分片數多時會產生大量時間序列，視需要開啟。
- 9.x 的 ES\|QL 支援 PromQL、也提供 Prometheus remote-write 端點，反過來把 Prometheus 指標存進 Elasticsearch 也是一種選擇（9.5 GA）。

## 同步落後怎麼看

Elasticsearch 的「同步落後」和 MySQL、PostgreSQL 的 replication lag 不一樣，要先分清楚是哪一種：

| 類型 | 複製方式 | 會不會落後 | 看什麼 |
| :--- | :--- | :--- | :--- |
| 叢集內的副本（replica） | **同步**：寫入要等所有 in-sync 副本完成才回應 | 正常情況不會；**副本復原中**（節點重啟、重新加入、新建副本）才會落後 | `_cat/recovery`、各分片副本的 `seq_no` / `global_checkpoint` |
| CCR（跨叢集複製） | **非同步**：follower 定期向 leader 拉取操作 | 會，最像 MySQL 的 replication lag | `GET <follower>/_ccr/stats` |
| 寫入後多久搜得到 | refresh | 不算複製落後，但常被誤認 | `refresh_interval`、`index.search.idle.after` |

### 叢集內副本：seq_no 與 checkpoint

每個寫入操作在主分片上會拿到一個遞增的**序號（seq_no）**，每份分片副本維護兩個 checkpoint：

- `local_checkpoint`：這份副本已經處理完的最大連續序號。
- `global_checkpoint`：**所有 in-sync 副本**都已經處理完的序號，由主分片計算。

```console
GET _cat/shards/orders?v&h=index,shard,prirep,state,node,seq_no.max,seq_no.local_checkpoint,seq_no.global_checkpoint&s=shard,prirep
```

- 正常狀態下，同一個分片的主分片與副本三個值都相同。
- 副本在復原（`state` 是 `INITIALIZING`）時，`_cat/shards` 的 seq_no 欄位是**空的**（實測），進度要看 `_cat/recovery` 的 `translog_ops` 與 `translog_ops_percent`；復原完成、回到 `STARTED` 後三個值會和主分片一致。
- `docs` 欄是 refresh 之後的文件數，主分片與副本 refresh 的時間點不同，**短暫不一致是正常的**（實測同一個分片主副本差了 79 筆，seq_no 完全相同）；判斷有沒有同步要看 seq_no / checkpoint，不要看 `docs`。
- 節點短暫離開後回來，若中間的操作還保留在主分片上（retention lease，預設保留 `index.soft_deletes.retention_lease.period` 12 小時），只會重播缺少的操作（operation-based recovery），不必整份複製檔案；超過保留期限才會走檔案複製。

```console
# 復原進度：type（peer / existing_store / snapshot）、檔案與 translog 的完成比例
GET _cat/recovery?v&active_only=true&h=index,shard,type,stage,source_node,target_node,files_percent,bytes_percent,translog_ops,translog_ops_percent,time
```

> 叢集內**沒有**「副本落後 N 秒但仍在服務」這種狀態：副本跟不上（寫入失敗）時，主分片會把它標記為 stale 並移出 in-sync 集合，之後它必須重新復原才能再被使用。所以監控重點是**有沒有副本處於非 STARTED 狀態、復原要多久**，而不是延遲秒數。
{: .prompt-info }

### CCR：follower 落後多少

```console
GET orders-follower/_ccr/stats?filter_path=indices.shards.shard_id,indices.shards.leader_global_checkpoint,indices.shards.follower_global_checkpoint,indices.shards.leader_max_seq_no,indices.shards.follower_max_seq_no,indices.shards.time_since_last_read_millis,indices.shards.read_exceptions,indices.shards.fatal_exception
```

| 欄位 | 意義 |
| :--- | :--- |
| `follower_global_checkpoint` | follower 已經套用的序號 |
| `leader_global_checkpoint` | follower **上一次讀取時**看到的 leader checkpoint，**不是 leader 現在的值** |
| `time_since_last_read_millis` | 距離上次讀取回應多久；讀取是 long poll（`read_poll_timeout` 預設 1 分鐘），閒置時也會上升到幾秒～1 分鐘，超過數分鐘才代表連線或讀取有問題 |
| `outstanding_read_requests` | 正在進行的讀取請求數，長期等於上限（`max_outstanding_read_requests`）代表 follower 讀不夠快 |
| `read_exceptions` / `fatal_exception` | 讀取錯誤；`fatal_exception` 出現時 follow 已經停止，要手動處理 |

```console
# 整個叢集所有 follower 的狀態（auto-follow 失敗也在這裡）
GET _ccr/stats
GET orders-follower/_ccr/info
```

> **落後操作數要拿 leader 叢集「現在」的 checkpoint 來算**：`_ccr/stats` 裡的 `leader_global_checkpoint` 是 follower 上次讀到的值，follower 斷線或讀取卡住時它會停在舊值，`leader_global_checkpoint - follower_global_checkpoint` 就會一直是 0。[實測]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})切斷 follower 叢集的網路、leader 寫入 5 萬筆，這個差值仍然是 0。正確的算法是在 **leader 叢集**上查各主分片的 `seq_no.global_checkpoint`，減掉 follower 的 `follower_global_checkpoint`：
{: .prompt-warning }

```console
# leader 叢集：各主分片目前的 global checkpoint
GET _cat/shards/orders?h=shard,prirep,seq_no.global_checkpoint&s=shard
# follower 叢集：各分片已套用到哪裡
GET orders-follower/_ccr/stats?filter_path=indices.shards.shard_id,indices.shards.follower_global_checkpoint
# 落後操作數 = Σ(leader 主分片 global_checkpoint) - Σ(follower_global_checkpoint)，每個分片也要各自看
```

先取 follower、再取 leader，數值才不會因為取樣時間差而變成負數。CCR 的 stats 也沒有直接給「落後幾秒」，要自己換算：落後操作數 ÷ leader 的寫入速率，或在文件裡帶寫入時間戳，比較兩邊最新文件的時間。兩邊的 `_count` 受 refresh 影響（實測 follower 有時比 leader 多），不能拿來判斷落後。

實際的副本追趕過程與 CCR 落後的量測，見 [三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})的「測試 7：同步落後」。

### 寫入後多久搜得到

這不是複製落後：寫入成功後，文件要等下一次 **refresh**（預設 `1s`）才搜得到；沒有明確設定 `refresh_interval` 的索引閒置 30 秒後會暫停定期 refresh，下一次搜尋才觸發（見[效能調校]({% post_url 2026-10-24-elasticsearch-ops-05-performance-tuning %})）。`GET <index>/_doc/<id>` 是即時的（realtime），不受 refresh 影響。

## 告警閾值建議

| 告警 | 條件 | 等級 |
| :--- | :--- | :--- |
| 叢集 red | `status == red` 持續 1 分鐘 | Critical |
| 叢集 yellow | `status == yellow` 持續 10 分鐘 | Warning |
| 節點數減少 | `number_of_nodes < 預期` 持續 2 分鐘 | Critical |
| 磁碟用量 | > 80% Warning、> 85%（低水位）Critical | 見下方說明 |
| heap | GC 後使用率 > 85% 持續 10 分鐘 | Warning |
| old GC | 每分鐘 old GC 時間 > 5 秒 | Warning |
| 寫入 rejected | `write` rejected 每分鐘增量 > 0，持續 5 分鐘 | Warning |
| 搜尋延遲 | 平均查詢延遲 > SLO | Warning |
| pending tasks | `number_of_pending_tasks > 50` 持續 5 分鐘 | Warning |
| 快照失敗 | SLM `snapshots_failed` 增加 | Warning |
| 憑證到期 | `GET _ssl/certificates` 的 `expiry` < 30 天 | Warning |
| 副本復原過久 | 有分片 `INITIALIZING` 超過 30 分鐘，或 `_cat/recovery` 進度長時間不動 | Warning |
| CCR 落後 | 落後操作數（以 leader 叢集的 checkpoint 計算）持續上升 10 分鐘，或任一分片 `time_since_last_read_millis` > 5 分鐘 | Warning |
| CCR 停止 | 任何 follower 出現 `fatal_exception`，或 `_ccr/stats` 的 `number_of_failed_follow_indices` > 0 | Critical |

> **磁碟告警一定要早於低水位**：低水位（預設 85%）時叢集不再把新的副本分配到該節點；高水位（90%）開始把分片搬走；**flood stage（95%）會把該節點上所有分片所屬的索引設成唯讀**（`index.blocks.read_only_allow_delete`），寫入全部失敗。8.x / 9.x 在磁碟降回高水位以下時會自動解除唯讀，但這段時間的寫入已經失敗了。
{: .prompt-warning }

另外大容量磁碟要注意 **max_headroom**：預設低 / 高 / flood 的保留空間上限是 200GB / 150GB / 100GB，在 10TB 的磁碟上，低水位實際是「剩餘 200GB」而不是「剩餘 15%」。告警用百分比或剩餘空間要和這個行為一致。

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| Health API（`_health_report`） | 有 | 相同，指標更多 |
| 內部收集（`xpack.monitoring.collection.enabled`） | 已棄用 | 已棄用，使用 Elastic Agent / Metricbeat |
| 日誌格式 | 純文字 + ECS JSON | 相同 |
| ES\|QL 與 PromQL | ES\|QL GA，無 PromQL | ES\|QL 原生支援 PromQL 與 Prometheus remote-write（9.5 GA） |
| `_cat` API | 相同 | 欄位大致相同，程式化監控仍建議用 JSON API |
| 查詢日誌 | 只有索引層級的慢日誌 | 新增叢集層級的 query log（`elasticsearch.querylog.*`，預設關閉），可依門檻記錄查詢與發出查詢的使用者 |
| 健康指標 | — | 新增 `cluster_state_encryption` 等指標 |

### 給監控的升級建議

- 升級前看 `<cluster.name>_deprecation.json` 與 `GET _migration/deprecations`，清掉所有棄用設定。
- 自己寫的監控腳本若解析 `_cat` 的文字輸出，升級後要重新驗證。
- 監控叢集的版本要**大於或等於**被監控的叢集，先升監控叢集。

## 小結

- `_cluster/health` 看整體、`_health_report` 看原因、`_nodes/stats` 看細節。
- 重點指標：heap 低點、old GC、`write` / `search` rejected、磁碟水位、未分配分片。
- 同步落後：叢集內副本看復原狀態與 checkpoint，CCR 看 leader 叢集**現在的** checkpoint 與 follower checkpoint 的差距（`_ccr/stats` 裡的 leader 值是舊的）。
- 慢日誌用索引範本統一開啟，deprecation 日誌升級前一定要看。
- 監控資料送到另一個叢集或 Prometheus，不要寫回被監控的叢集。

下一篇：[效能調校]({% post_url 2026-10-24-elasticsearch-ops-05-performance-tuning %})。

### 參考資料

- [Elasticsearch 文件：Cluster health API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-health)
- [Elasticsearch 文件：Health API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-health-report)
- [Elasticsearch 文件：Nodes stats API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-stats)
- [Elasticsearch 文件：Slow log](https://www.elastic.co/docs/reference/elasticsearch/index-settings/slow-log)
- [Elasticsearch 文件：Stack Monitoring](https://www.elastic.co/docs/deploy-manage/monitor/stack-monitoring)
- [Elasticsearch 文件：Disk-based shard allocation](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/cluster-level-shard-allocation-routing-settings#disk-based-shard-allocation)
- [prometheus-community/elasticsearch_exporter](https://github.com/prometheus-community/elasticsearch_exporter)
