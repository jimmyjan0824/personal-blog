---
title: Elasticsearch 運維 09：故障排查與事件處理
date: 2026-10-24 17:20:00 +0800
categories: [Elasticsearch, 故障排查]
tags: [elasticsearch, elasticsearch9, elasticsearch8, troubleshooting, red-cluster, unassigned-shards, circuit-breaker, gc, hot-threads, disk-watermark, runbook]
description: 以 Elasticsearch 9.5 為主，整理叢集 red / yellow、未分配分片、磁碟水位與唯讀、heap 壓力與斷路器、GC 與節點離線、執行緒池 rejected、慢查詢、master 不穩定、mapping 爆炸、啟動失敗（bootstrap checks）等常見故障的排查步驟，以及 Runbook 與事後檢討，並比較 8.19 的差異。
---

故障發生時，最重要的是**先止血、再找原因**。Elasticsearch 的好處是它很會「說明自己為什麼不健康」：`_health_report` 與 `_cluster/allocation/explain` 多數時候會直接告訴你原因。本篇整理最常見的故障與處理步驟，最後比較 8.19 在排查工具上的差異。

{% include elasticsearch-ops-series.md %}

## 第一分鐘：看全貌

```console
GET _health_report?verbose=false
GET _cluster/health?filter_path=status,number_of_nodes,unassigned_shards,initializing_shards,relocating_shards,number_of_pending_tasks
GET _cat/nodes?v&h=name,node.role,master,heap.percent,ram.percent,cpu,load_1m,disk.used_percent
GET _cat/allocation?v&s=disk.percent:desc
GET _cat/thread_pool/write,search?v&h=node_name,name,active,queue,rejected
```

再看日誌：`/var/log/elasticsearch/<cluster.name>.log` 的 `WARN` 與 `ERROR`，以及 `journalctl -u elasticsearch`（啟動失敗時 Elasticsearch 自己的日誌可能還沒建立）。

## 叢集 red / yellow：未分配分片

```console
# 哪些分片沒分配、原因代碼
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason,node&s=state

# 叢集自己解釋原因（不帶參數會挑第一個未分配的分片）
GET _cluster/allocation/explain
```

| `unassigned.reason` / explain 的訊息 | 原因 | 處理 |
| :--- | :--- | :--- |
| `NODE_LEFT` | 節點離線 | 等待延遲分配或把節點救回來 |
| `the node is above the low watermark` | 磁碟水位 | 見下一節 |
| `a copy of this shard is already allocated to this node` | 節點數少於 1 + 副本數 | 加節點或降低副本數（例如單節點叢集） |
| `node does not match index setting [index.routing.allocation...]` | 分配過濾 / tier 設定 | 檢查索引的 `_tier_preference` 與節點角色 |
| `too many shards on node` / `cluster.max_shards_per_node` | 分片總數上限（預設每節點 1000） | 減少分片，**不要**直接調高上限 |
| `ALLOCATION_FAILED`（重試 5 次失敗） | 磁碟損壞、mapping 衝突等 | 修正原因後 `POST _cluster/reroute?retry_failed=true` |
| 主分片：`no valid shard copy` | 所有持有資料的節點都不在 | 把節點救回來；最後手段才是從快照還原或 `allocate_stale_primary` / `allocate_empty_primary`（**會遺失資料**） |

> `allocate_empty_primary` 會建立一個**空的**主分片，該分片的資料全部消失；`allocate_stale_primary` 用一份可能過期的副本當主分片，會遺失之後的寫入。兩者都要加 `accept_data_loss: true`，只有在確認資料救不回來、且有快照或來源可以重建時才使用。
{: .prompt-danger }

## 磁碟水位與唯讀

| 水位 | 預設 | 行為 |
| :--- | :--- | :--- |
| low | 85%（max_headroom 200GB） | 不再分配**新的副本**到該節點（新索引的主分片不受影響） |
| high | 90%（max_headroom 150GB） | 開始把分片搬離該節點 |
| flood_stage | 95%（max_headroom 100GB） | 該節點上有分片的索引全部加上 `index.blocks.read_only_allow_delete`，**寫入全部失敗** |

徵兆：用戶端收到 `cluster_block_exception ... [FORBIDDEN/12/index read-only / allow delete (api)]` 或 `TOO_MANY_REQUESTS/12/disk usage exceeded flood-stage watermark`。

處理：

1. **先騰出空間**：刪除過期索引（`DELETE logs-2026.07.*`）、降低不重要索引的副本數、清掉 `.ds-*` 中已經沒用的資料。
2. 磁碟降到 high 水位以下後，8.x / 9.x 會**自動移除**唯讀 block；確認一下：

   ```console
   GET _all/_settings/index.blocks*?flat_settings
   # 若仍存在，手動移除
   PUT _all/_settings
   { "index.blocks.read_only_allow_delete": null }
   ```

3. 根本解法：加磁碟或節點、設 ILM / DSL 保留期限、告警設在低水位之前（見[監控與告警]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})）。

**不要用調高水位的方式解決**，那只是讓磁碟真的滿掉時更難處理。

## Heap 壓力與斷路器

徵兆：`circuit_breaking_exception: [parent] Data too large, data for [<http_request>] would be [...], which is larger than the limit of [...]`、heap 使用率長期 > 85%、old GC 頻繁。

```console
GET _nodes/stats/breaker?filter_path=nodes.*.name,nodes.*.breakers.*.estimated_size,nodes.*.breakers.*.tripped
GET _nodes/stats/indices/fielddata,query_cache,request_cache,segments?filter_path=nodes.*.name,nodes.*.indices.fielddata.memory_size_in_bytes,nodes.*.indices.segments.count
GET _cat/fielddata?v&s=size:desc
```

| 原因 | 處理 |
| :--- | :--- |
| text 欄位開了 fielddata | 改用 keyword；`POST _cache/clear?fielddata=true` 暫時止血 |
| 超大聚合（`terms` size 很大、巢狀聚合） | 改 composite 聚合；`search.max_buckets` 預設 65536 會擋下來 |
| 大量 bulk 同時湧入 | 用戶端降速、批次變小；`indexing_pressure` 會回 429 |
| 分片太多 | 合併、shrink、刪除舊索引 |
| heap 本來就太小 | 加記憶體（heap 用自動計算即可）或加節點 |

## GC 與節點離線

徵兆：日誌出現 `[gc][young/old][...] duration [...]` 的 `WARN`，或節點反覆 `node-left` / `node-join`，原因寫著 `followers check retry count exceeded`。

```bash
grep -E "\[gc\]|overhead" /var/log/elasticsearch/<cluster.name>.log | tail
grep -E "node-left|node-join|followers check|leader check" /var/log/elasticsearch/<cluster.name>.log | tail
```

- 長時間的 GC 暫停會讓節點錯過 follower check，被 master 踢出叢集；節點回來後又觸發分片復原，負載更重，形成惡性循環。
- 先確認**沒有 swap**（`free -m`、`GET _nodes/_local/process` 的 `mlockall`），再處理 heap 壓力。
- 網路不穩造成的節點離線，日誌會是 `disconnected` 而不是 GC。`net.ipv4.tcp_retries2=5` 讓斷線更快被偵測。

## 執行緒池 rejected

```console
GET _cat/thread_pool/write,search?v&h=node_name,name,active,queue,rejected,completed
GET _nodes/hot_threads?threads=5&interval=500ms
```

- `write` rejected：寫入超過處理能力。看是不是單一節點特別忙（**熱點分片**：某個索引的分片都擠在同一台），用 `_cat/shards` 確認分布；用 `index.routing.allocation.total_shards_per_node` 打散。
- `search` rejected：查詢太重。`hot_threads` 會顯示正在燒 CPU 的執行緒在做什麼（例如 `QueryPhase`、`AggregationPhase`、regex）。

## 慢查詢

```console
# 正在執行的搜尋，依時間排序
GET _tasks?actions=*search*&detailed&group_by=none
# 取消某個查詢
POST _tasks/<task_id>/_cancel
```

- 開慢查詢日誌（[監控篇]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})的 component template），找出是哪些查詢、哪個使用者。
- 用 `profile: true` 分析（[效能調校]({% post_url 2026-10-24-elasticsearch-ops-05-performance-tuning %})）。
- 保護叢集：`search.default_search_timeout`（預設不限制）、`search.allow_expensive_queries: false` 可以禁止 script、前置萬用字元等昂貴的查詢。

## 副本復原太慢、CCR 落後

**副本復原太慢**（叢集長時間 yellow，`_cat/recovery` 進度很慢）：

| 原因 | 處理 |
| :--- | :--- |
| 頻寬限制 | `indices.recovery.max_bytes_per_sec` 預設每節點 40mb，離峰時暫時調高 |
| 同時復原的數量限制 | `cluster.routing.allocation.node_concurrent_recoveries` 預設 2 |
| 離線太久，超過 retention lease（12 小時） | 只能走檔案複製，時間取決於分片大小；計畫性停機盡量短 |
| 副本一直失敗重來 | `_cluster/allocation/explain` 看 `unassigned_info.last_allocation_status` 與錯誤訊息 |

**CCR 落後持續增加**：

```console
GET orders-follower/_ccr/stats?filter_path=indices.shards.shard_id,indices.shards.leader_global_checkpoint,indices.shards.follower_global_checkpoint,indices.shards.outstanding_read_requests,indices.shards.read_exceptions,indices.shards.fatal_exception,indices.shards.time_since_last_read_millis
GET _remote/info
```

- 先用 leader 叢集的 `GET _cat/shards/<leader>?h=shard,prirep,seq_no.global_checkpoint` 對照 follower 的 `follower_global_checkpoint`，**逐個分片**看：`_ccr/stats` 的 `leader_global_checkpoint` 是舊值，不能單獨拿來算落後；也可能只有一個分片卡住（[實測]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})網路恢復後，有一次其他分片 5 秒內追上，一個分片停了約 200 秒才重試成功，日誌只有一行 `background management of retention lease ... failed while following`）。
- `_remote/info` 的 `connected: false`：兩個叢集之間的 9300 不通、憑證不互信，或 `cluster.remote.<名稱>.seeds` 寫錯。
- `outstanding_read_requests` 一直頂在上限：follower 讀不夠快，調高 `max_read_request_operation_count`、`max_outstanding_read_requests`（`_ccr/pause_follow` 後用 `_ccr/resume_follow` 帶新參數）。
- 有 `fatal_exception`：follow 已停止，常見原因是 leader 的歷史操作已被清掉（follower 離線超過 leader 的 retention lease），只能刪掉 follower 重新 `_ccr/follow`。

## master 不穩定、叢集沒有 master

徵兆：`master_not_discovered_exception`、`_cat/master` 沒有回應、`_health_report` 的 `master_is_stable` 是 red。

```console
GET _health_report/master_is_stable?verbose=true
```

```bash
grep -E "master not discovered|ClusterFormationFailureHelper" /var/log/elasticsearch/<cluster.name>.log | tail -3
```

`ClusterFormationFailureHelper` 的訊息會列出：這台節點發現了哪些節點、投票組態需要哪些節點、還差幾票。常見原因：

| 原因 | 處理 |
| :--- | :--- |
| 過半數的 master-eligible 節點離線 | 把它們救回來（[三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})有停兩台的實測） |
| `discovery.seed_hosts` 寫錯、防火牆擋 9300 | 修正設定 / 防火牆 |
| `cluster.name` 不一致 | 統一名稱 |
| 某台節點資料目錄被清空，用 `cluster.initial_master_nodes` 自己 bootstrap 成新叢集 | 停掉它、清空資料目錄、移除 `initial_master_nodes` 後重新加入 |
| 叢集狀態太大，發布逾時 | 減少分片與 mapping 欄位數 |

## mapping 爆炸

徵兆：`Limit of total fields [1000] has been exceeded`、master 的 pending tasks 很多（每個新欄位都要更新叢集狀態）。

- 原因通常是把使用者輸入的 key 當欄位名（例如 `attributes.<任意字串>`）。
- 改用 `flattened` 型別，或 `dynamic: false` 不索引未知欄位、只保留在 `_source`。
- 不要直接調高 `index.mapping.total_fields.limit`；真的需要時，9.x / 8.x 也可以設 `index.mapping.total_fields.ignore_dynamic_beyond_limit: true` 讓超過的動態欄位被忽略而不是整份文件失敗。

## 啟動失敗

```bash
sudo journalctl -u elasticsearch --no-pager | tail -50
sudo tail -50 /var/log/elasticsearch/<cluster.name>.log
```

| 錯誤訊息 | 原因 | 處理 |
| :--- | :--- | :--- |
| `max virtual memory areas vm.max_map_count [65530] is too low` | sysctl | `vm.max_map_count=262144`（RPM 已內建，容器或自訂映像可能沒套用） |
| `memory locking requested for elasticsearch process but memory is not locked` | `bootstrap.memory_lock: true` 但 systemd 沒有 `LimitMEMLOCK=infinity`（多節點會拒絕啟動，單節點只是 WARN） | 加 systemd override |
| `unknown setting [xxx]` | 設定名稱打錯或該版本已移除 | 修正 elasticsearch.yml（升級時最常見） |
| `the default discovery settings are unsuitable for production use` | 綁了非 loopback 位址卻沒設 discovery | 設 `discovery.seed_hosts` 或 `discovery.type: single-node` |
| `setting [cluster.initial_master_nodes] is not allowed when [discovery.type] is set to [single-node]` | 兩者同時存在 | 單節點移除 `initial_master_nodes` |
| `Transport SSL must be enabled if security is enabled` | 多節點叢集沒開 transport TLS | 設定 transport TLS |
| `failed to obtain node locks` | 已經有另一個行程在用這個資料目錄 | 確認沒有殘留的 java 行程 |
| systemd 顯示 `start operation timed out` | 啟動太慢（大量分片、慢磁碟） | 看日誌確認是否還在啟動中；必要時調高 `TimeoutStartSec` |

正式模式（綁定非 loopback 位址）下，這些 **bootstrap checks** 失敗會直接拒絕啟動，這是刻意的設計：寧可起不來，也不要帶著危險的設定上線。但 `discovery.type: single-node` 例外：bootstrap checks 只記 WARN、照樣啟動（[單節點實作]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})實測），單節點要主動檢查日誌裡的 `BootstrapChecks` WARN。設定錯誤（不認得的參數、互相衝突的參數）則不論單節點或叢集都會拒絕啟動。

## Runbook 與事後檢討

每一類故障都要有 Runbook：

| 欄位 | 內容 |
| :--- | :--- |
| 觸發條件 | 哪個告警 |
| 影響 | 寫入失敗？查詢變慢？哪些服務受影響 |
| 第一步 | 先看什麼（上面的「第一分鐘」） |
| 止血 | 例如刪過期索引、取消查詢、暫停 bulk 來源 |
| 根因調查 | 日誌、`allocation/explain`、`hot_threads` |
| 升級條件 | 多久沒解決要找誰 |

事後檢討（postmortem）記錄時間軸、根本原因、為什麼告警沒有更早發現、後續改善項目與負責人，**對事不對人**。

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| `_health_report` | 有 | 相同，指標與建議更多 |
| `_cluster/reroute` | 回應包含叢集狀態 | 不再回傳叢集狀態（腳本若解析回應要修改） |
| 錯誤回應的 JSON 格式 | 部分 API 不一致 | 9.0 起統一格式 |
| `unknown setting` 啟動失敗 | — | 升級後最常見：例如 `cluster.routing.allocation.disk.watermark.enable_for_single_data_node` 已移除 |
| 7.x 建立的索引 | 可以寫入 | 只能唯讀，寫入會被 block 擋下 |

### 給排查的升級建議

- 把 Runbook 裡的指令在 9.x 測試叢集跑一次，特別是解析 API 回應的腳本。
- 升級後的第一週多看 `<cluster.name>_deprecation.json` 與 WARN 日誌。

## 小結

- 先看 `_health_report` 與 `_cluster/allocation/explain`，多數問題它們會直接說明原因。
- 磁碟 flood stage 會讓索引唯讀，先騰空間；不要靠調高水位解決。
- heap 壓力、GC、節點離線常常是同一個問題的不同面向。
- `allocate_empty_primary` / `unsafe-bootstrap` 是會遺失資料的最後手段。

下一篇：[自動化與規範制定]({% post_url 2026-10-24-elasticsearch-ops-10-automation-standards %})。

### 參考資料

- [Elasticsearch 文件：Troubleshoot](https://www.elastic.co/docs/troubleshoot/elasticsearch)
- [Elasticsearch 文件：Red or yellow cluster health status](https://www.elastic.co/docs/troubleshoot/elasticsearch/red-yellow-cluster-status)
- [Elasticsearch 文件：Fix watermark errors](https://www.elastic.co/docs/troubleshoot/elasticsearch/fix-watermark-errors)
- [Elasticsearch 文件：Circuit breaker errors](https://www.elastic.co/docs/troubleshoot/elasticsearch/circuit-breaker-errors)
- [Elasticsearch 文件：Troubleshooting discovery](https://www.elastic.co/docs/troubleshoot/elasticsearch/discovery-troubleshooting)
- [Elasticsearch 文件：Bootstrap checks](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks)
