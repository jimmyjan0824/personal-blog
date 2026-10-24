---
title: Elasticsearch 運維 03：高可用與災難復原
date: 2026-10-24 16:20:00 +0800
categories: [Elasticsearch, 高可用]
tags: [elasticsearch, elasticsearch9, elasticsearch8, cluster, master-election, replica, shard-allocation, ccr, ha, dr]
description: 以 Elasticsearch 9.5 為主，整理叢集的組成與 master 選舉（voting configuration）、主分片與副本、分片分配與 awareness、節點離線後的復原流程、跨機房部署與 CCR、RPO / RTO 規劃，並比較 8.19 的差異。
---

Elasticsearch 的高可用是**內建在叢集裡的**：不需要像 MySQL、PostgreSQL 那樣另外裝 Orchestrator 或 Patroni。叢集自己選 master、自己把副本升為主分片、自己重新分配分片。本篇講原理與規劃，實際的建置與故障測試請看 [三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})。

{% include elasticsearch-ops-series.md %}

## 叢集的組成

| 名詞 | 說明 |
| :--- | :--- |
| 節點（node） | 一個 Elasticsearch 行程。一台主機通常只跑一個節點 |
| 角色（role） | `master`、`data`（或分層的 `data_hot` / `data_warm` / `data_cold` / `data_frozen` / `data_content`）、`ingest`、`ml`、`transform`、`remote_cluster_client`；**空陣列** = coordinating only |
| 叢集狀態（cluster state） | 所有索引的 mapping、settings、分片位置、範本等中繼資料，由 elected master 維護並發布給所有節點 |
| 索引（index） | 由一或多個**主分片（primary shard）**組成，每個主分片可以有 0～N 個**副本（replica）** |
| 分片（shard） | 一個 Lucene index，是資料分配與複製的最小單位 |

### master 選舉

8.0 起叢集協調（cluster coordination）使用類似 Raft 的演算法，重點是**投票組態（voting configuration）**：

- 只有 `master` 角色的節點（master-eligible）能投票、能被選為 master。
- 選出 master、發布叢集狀態都需要**投票組態中過半數**的節點同意。
- 投票組態會**自動調整**：新增或移除 master-eligible 節點時，Elasticsearch 會盡量維持奇數個投票者，讓叢集能承受最多的節點故障。

| master-eligible 節點數 | 過半數 | 可承受的故障 |
| :--- | :--- | :--- |
| 1 | 1 | 0 |
| 2 | 2（投票組態只會用其中 1 台，另一台不投票） | 0（壞的剛好是投票那台就停擺） |
| **3** | 2 | **1** |
| 5 | 3 | 2 |

> **兩台 master-eligible 節點沒有高可用**。正式環境至少 3 台 master-eligible 節點；第三台可以是只投票、不存資料的小主機（`node.roles: [ master, voting_only ]`）。7.x 以前的 `discovery.zen.minimum_master_nodes` 已經不存在，不需要（也不能）手動設定過半數。
{: .prompt-warning }

```console
# 目前的 master 與投票組態
GET _cat/master?v
GET _cluster/state?filter_path=metadata.cluster_coordination
```

### 第一次組成叢集：cluster.initial_master_nodes

`cluster.initial_master_nodes` **只在叢集第一次啟動（bootstrap）時使用**：

- 列出初始的 master-eligible 節點名稱（要和 `node.name` 一模一樣）。
- 叢集組成後就應該**從設定檔移除**；Elasticsearch 8.x / 9.x 會在叢集已經組成後還留著這個設定時記錄警告。
- 留著它最大的風險是：某天把一台節點的資料目錄清空重啟，它可能用這份清單自己 bootstrap 出**另一個新叢集**。

新節點加入既有叢集只需要 `discovery.seed_hosts`，**不要**設 `cluster.initial_master_nodes`。

## 主分片與副本

- 寫入一律先到**主分片**，再由主分片平行轉發給所有 in-sync 的副本，全部成功才回應用戶端。
- 讀取（搜尋、GET）可以由主分片或任一副本處理，副本越多可以承受越多讀取。
- 同一個分片的主分片與副本**不會**放在同一個節點上。

| `number_of_replicas` | 可承受的 data 節點故障 | 磁碟用量 |
| :--- | :--- | :--- |
| 0 | 0（壞一台就遺失資料） | 1 倍 |
| **1** | 1 | 2 倍 |
| 2 | 2 | 3 倍 |

`index.number_of_replicas` 可以隨時調整（dynamic），不像主分片數建立後就不能改（只能 split / shrink / reindex）。

### 寫入的持久性

| 參數 | 預設 | 說明 |
| :--- | :--- | :--- |
| `index.translog.durability` | `request` | 每個寫入請求回應前都把 translog fsync 到磁碟（主分片與副本都是）。改成 `async` 會每 `sync_interval` 才 fsync，**當機時最多遺失這段時間的資料** |
| `index.translog.sync_interval` | `5s` | `async` 時的 fsync 間隔 |
| `wait_for_active_shards` | `1`（只要主分片） | 寫入前至少要有幾個 active 的分片副本，設 `all` 可避免只剩主分片時還寫入，但可用性會下降 |

> Elasticsearch 的副本複製是**同步的**（寫入要等 in-sync 副本完成），但它保護的是「節點故障」而不是「誤操作」。誤刪請靠[快照]({% post_url 2026-10-24-elasticsearch-ops-02-backup-restore %})。
{: .prompt-info }

## 節點離線後會發生什麼

以三節點、`number_of_replicas: 1` 為例，esc2 當機：

1. **偵測**：master 對每個節點做 follower check（預設每 1 秒、逾時 10 秒、連續 3 次失敗），約 30 秒判定 esc2 離線（[三節點實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})用 `docker pause` 模擬主機無回應，實測 33～34 秒）。行程整個結束時 TCP 連線會立刻斷，通常更快被移除（未實測）。如果 esc2 是 master，其他節點用 leader check 偵測，再重新選舉。
2. **副本升為主分片**：esc2 上的主分片，由其他節點上的 in-sync 副本立刻升為主分片，寫入很快就恢復。此時叢集是 **yellow**（有副本未分配）。
3. **延遲分配**：esc2 原本的副本**不會立刻**在其他節點重建，而是等 `index.unassigned.node_left.delayed_timeout`（預設 1 分鐘）。重開機或短暫的網路中斷，節點回來後只要補上差異，不必整份複製。
4. **重建副本**：超過延遲時間後，在剩下的節點上從主分片複製出新的副本，完成後回到 **green**。

節點在延遲時間內回來時，它的副本只要補上離線期間的操作（operation-based recovery）：主分片用 retention lease 保留這些操作（預設 12 小時），副本的 `local_checkpoint` 追上主分片的 `seq_no.max` 後就回到 in-sync。追趕的過程可以用 `GET _cat/shards?h=index,shard,prirep,state,seq_no.max,seq_no.local_checkpoint,seq_no.global_checkpoint` 觀察。

```console
# 為什麼有分片沒分配
GET _cluster/allocation/explain
{ "index": "orders", "shard": 0, "primary": false }

# 調高延遲分配時間（例如預期主機重開機要 5 分鐘）
PUT _all/_settings
{ "settings": { "index.unassigned.node_left.delayed_timeout": "5m" } }
```

### 叢集健康狀態

| 狀態 | 意義 | 處理 |
| :--- | :--- | :--- |
| green | 所有主分片與副本都已分配 | — |
| yellow | 所有主分片都在，有副本未分配 | 服務正常，但再壞一台就可能遺失資料；查 `allocation/explain` |
| red | 至少一個主分片未分配 | 該索引部分資料無法讀寫，立即處理 |

> 單節點叢集只要有 `number_of_replicas: 1` 的索引就永遠是 yellow，因為副本不能和主分片放在同一個節點。單節點環境請把副本設 0（[單節點實作]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})用索引範本處理）。
{: .prompt-tip }

## 分片分配：awareness 與過濾

### 跨機架 / 機房的 awareness

```yaml
# elasticsearch.yml
node.attr.zone: zone-a        # 每台依實際位置設 zone-a / zone-b / zone-c
cluster.routing.allocation.awareness.attributes: zone
```

設定後，同一個分片的主分片與副本會**盡量分散到不同 zone**。若還要求「某個 zone 整個掛掉時，不要把該 zone 的副本全部擠到剩下的 zone」，再加上 forced awareness：

```yaml
cluster.routing.allocation.awareness.force.zone.values: [ zone-a, zone-b, zone-c ]
```

forced awareness 會讓叢集在一個 zone 失效時維持 yellow，而不是把副本塞爆剩下的節點，代價是失效期間少一份副本。

### 撤除節點（排空）

```console
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.exclude._name": "esc3" } }

GET _cat/shards?v&h=index,shard,prirep,state,node&s=node
# esc3 上的分片都搬走後才停機；完成後記得清掉 exclude
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.exclude._name": null } }
```

如果撤除的是 master-eligible 節點，還要先把它從投票組態排除：

```console
POST _cluster/voting_config_exclusions?node_names=esc3
# 節點移除完成後
DELETE _cluster/voting_config_exclusions
```

## 架構規劃

| 規模 | 建議架構 |
| :--- | :--- |
| 開發、測試 | 單節點，副本 0 |
| 小型正式環境 | **3 個節點，全部是 `master` + `data` + `ingest`**，副本 1 |
| 中型 | 3 台**專用 master**（小規格）+ N 台 data，必要時加 coordinating 節點承接大量查詢與聚合 |
| 大型 / 日誌 | 專用 master + hot / warm / cold（frozen）分層 data 節點，搭配 ILM 與 searchable snapshots |

- **專用 master 的時機**：data 節點超過 5～6 台、或 data 節點經常 GC 壓力大時。master 負責維護叢集狀態，被 data 的負載拖慢會造成整個叢集不穩定。
- 專用 master 不需要大記憶體，但要**低延遲的磁碟**（叢集狀態每次變更都要寫入磁碟）。
- 不要讓 coordinating 節點變成新的單點：前面放負載平衡，或讓用戶端（官方 client）設定多個節點並開 sniffing。

## 跨機房與災難復原

### 一個叢集跨兩個機房：不建議

兩個機房的 master-eligible 節點無論怎麼分配，都有一邊少於過半數；**少的那一邊斷線時就整個停擺**。要跨機房就要有**三個**機房（第三個可以只放一台 `voting_only` 節點），且機房之間的延遲要低（官方建議同城、毫秒等級）。

### Cross-Cluster Replication（CCR）

需要 Platinum 以上授權。遠端叢集上建立 **follower index**，持續從 leader index 拉取操作：

{% raw %}
```console
# 在 DR 叢集上
PUT _cluster/settings
{ "persistent": { "cluster.remote.prod.seeds": ["10.0.1.21:9300", "10.0.1.22:9300"] } }

PUT /orders-follower/_ccr/follow
{ "remote_cluster": "prod", "leader_index": "orders" }

# 自動跟隨新建立的索引（例如每天新的日誌索引）
PUT /_ccr/auto_follow/logs
{ "remote_cluster": "prod", "leader_index_patterns": ["logs-*"], "follow_index_pattern": "{{leader_index}}" }
```
{% endraw %}

- 非同步複製：RPO 通常是秒級，視網路與寫入量而定。落後量用 leader 叢集主分片的 `global_checkpoint` 減掉 follower 的 `follower_global_checkpoint` 監控（`_ccr/stats` 裡的 `leader_global_checkpoint` 是 follower 上次讀到的舊值，斷線時不會變；[監控與告警]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})的「同步落後怎麼看」）。
- follower index 是唯讀的；切換時要 `POST /orders-follower/_ccr/pause_follow` → `_close` → `_ccr/unfollow` → `_open`，再把應用程式導向 DR 叢集。
- 不能自動回切，原本的 leader 要重新以 follower 身分同步回來。

### 沒有 CCR 時：快照 + 雙寫

| 做法 | RPO | RTO | 說明 |
| :--- | :--- | :--- | :--- |
| 快照還原到 DR 叢集 | 快照間隔（例如 30 分鐘） | 還原時間（資料量決定） | DR 叢集以 readonly 註冊同一個儲存庫 |
| 應用程式 / Kafka 雙寫兩個叢集 | 接近 0 | 切換 DNS 的時間 | 兩邊資料一致性要靠應用程式處理 |
| 從來源資料庫重建（reindex from source） | — | 很長 | 搜尋資料常常是衍生資料，最後手段 |

很多團隊把 Elasticsearch 當成**可以重建的衍生資料**（真正的資料在 MySQL / PostgreSQL），這時 DR 的重點是「重建要多久」，用快照把 RTO 縮短。

## RPO / RTO 規劃

| 故障 | 機制 | RPO | RTO |
| :--- | :--- | :--- | :--- |
| 單一 data 節點故障 | 副本升為主分片 | 0 | 主機無回應時約 30～35 秒（偵測時間，實測 33～34 秒）；這段時間寫到該節點分片的請求會等待 |
| master 節點故障 | 重新選舉 | 0 | 偵測約 33 秒 + 選舉；舊 master 只是無回應（沒斷線）時，新 master 第一次發布叢集狀態要等 `cluster.publish.timeout`（30 秒），實測共約 63 秒 |
| 過半數 master 故障 | 無法自動恢復 | 0（資料還在） | 修好節點的時間；**不要**輕易用 `elasticsearch-node unsafe-bootstrap`。期間寫入回 503（no master block），讀取只回存活節點上的分片；存活節點上沒有 `.security` 的副本時，連登入都失敗（401） |
| 誤刪 / 誤改資料 | 快照 | 快照間隔 | 還原時間 |
| 整個機房 | CCR 或快照 | 秒級 / 快照間隔 | 切換時間 / 還原時間 |

> `elasticsearch-node unsafe-bootstrap` 與 `detach-cluster` 是在**過半數 master 永久遺失**時的最後手段，可能遺失資料或造成叢集狀態不一致。執行前一定要先確認那些節點真的回不來了。
{: .prompt-danger }

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| 叢集協調、投票組態 | 8.0 起的演算法 | 相同 |
| 分片平衡 | desired balance allocator（8.6+） | 相同，9.0 提高了平衡器的最小門檻（減少不必要的分片搬移） |
| `discovery.type` | `single-node` 與 `multi-node` | 移除舊的（legacy）值，只接受 `single-node` / `multi-node` |
| `cluster.routing.allocation.disk.watermark.enable_for_single_data_node` | 已棄用 | **移除**（設定檔留著會無法啟動） |
| `_cluster/reroute` 回應 | 預設回傳叢集狀態 | 不再回傳叢集狀態 |
| CCR 版本相容 | leader / follower 版本要相容 | 相同，滾動升級時**先升 follower 叢集** |

### 給 HA 架構的升級建議

- 滾動升級前確認所有索引至少有 1 份副本，否則重啟節點期間該索引會變 red。
- 有 CCR 時先升級 follower（DR）叢集，再升級 leader，因為新版本可以跟隨舊版本，反過來不行。
- 設定檔裡若還有 `enable_for_single_data_node`，升級前先移除。

## 小結

- 至少 3 台 master-eligible 節點，叢集才能承受 1 台故障；兩台沒有高可用。
- `cluster.initial_master_nodes` 只在第一次 bootstrap 時用，組成後移除。
- 副本 1 份可承受 1 台 data 節點故障；節點離線後先升副本，再延遲重建。
- 跨機房不要用兩個機房組一個叢集，改用 CCR 或快照。

下一篇：[監控與告警]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})。

### 參考資料

- [Elasticsearch 文件：Discovery and cluster formation](https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation)
- [Elasticsearch 文件：Voting configurations](https://www.elastic.co/docs/deploy-manage/distributed-architecture/discovery-cluster-formation/modules-discovery-voting)
- [Elasticsearch 文件：Cluster-level shard allocation and routing settings](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference/cluster-level-shard-allocation-routing-settings)
- [Elasticsearch 文件：Delaying allocation when a node leaves](https://www.elastic.co/docs/deploy-manage/distributed-architecture/shard-allocation-relocation-recovery/delaying-allocation-when-node-leaves)
- [Elasticsearch 文件：Cross-cluster replication](https://www.elastic.co/docs/deploy-manage/tools/cross-cluster-replication)
- [Elasticsearch release notes：breaking changes](https://www.elastic.co/docs/release-notes/elasticsearch/breaking-changes)
