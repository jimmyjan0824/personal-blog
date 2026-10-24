---
title: Elasticsearch 運維 08：變更管理與發布
date: 2026-10-24 17:10:00 +0800
categories: [Elasticsearch, 變更管理]
tags: [elasticsearch, elasticsearch9, elasticsearch8, mapping, reindex, alias, index-template, rolling-restart, upgrade, change-management]
description: 以 Elasticsearch 9.5 為主，整理變更的分類與流程、哪些 mapping 與 settings 可以線上改、用 alias + reindex 做零停機的 mapping 變更、index template 與 component template 的版本控管、叢集設定變更、滾動重啟與滾動升級的步驟與回滾方案，並比較 8.19 的差異。
---

Elasticsearch 的變更有一個和關聯式資料庫很不一樣的特性：**已經存在的欄位 mapping 幾乎不能改**。要改型別就要建新索引、重新寫入資料。所以變更管理的核心是兩件事：**用 alias 隔開應用程式與實體索引**，以及**用範本管理新索引的長相**。本篇最後比較 8.19 的差異。

{% include elasticsearch-ops-series.md %}

## 變更的分類

| 類型 | 例子 | 風險 | 做法 |
| :--- | :--- | :--- | :--- |
| 動態設定 | `number_of_replicas`、`refresh_interval`、叢集層級的 allocation 設定 | 低 | API 直接改，記錄在變更單 |
| 新增欄位 | mapping 加一個新欄位 | 低 | `PUT index/_mapping`，舊文件沒有這個欄位 |
| 改欄位型別 / analyzer | `text` → `keyword`、換分詞器 | **高** | 新索引 + reindex + 切換 alias |
| 靜態設定 | 主分片數、`index.codec`、`index.sort.*` | 高 | 新索引（或 split / shrink） |
| 節點設定（elasticsearch.yml、JVM） | heap、`path.*`、thread pool | 中 | 滾動重啟 |
| 版本升級 | 9.5.4 → 9.5.5、8.19 → 9.5 | 中～高 | 滾動升級 |

## 哪些可以線上改

```console
# 動態的索引設定
PUT orders/_settings
{ "index": { "number_of_replicas": 2, "refresh_interval": "5s" } }

# 新增欄位（不能改既有欄位）
PUT orders/_mapping
{ "properties": { "coupon_code": { "type": "keyword" } } }

# 既有欄位：只能改少數參數（例如 ignore_above、新增 multi-field）
PUT orders/_mapping
{ "properties": { "status": { "type": "keyword", "ignore_above": 256, "fields": { "text": { "type": "text" } } } } }
POST orders/_update_by_query?conflicts=proceed&slices=auto   # 讓舊文件也建立新的 multi-field
```

靜態的索引設定（例如 analyzer 定義）要先 `_close` 索引才能改，期間索引不能讀寫，正式環境盡量避免。

## 零停機的 mapping 變更：alias + reindex

應用程式**一律透過 alias 存取**，實體索引名稱帶版本號：

```console
# 現況：orders（alias）→ orders-v1
# 1. 用新的 mapping 建 orders-v2（可以先關 refresh、副本 0 加快 reindex）
PUT orders-v2
{
  "settings": { "number_of_shards": 3, "number_of_replicas": 0, "refresh_interval": "-1" },
  "mappings": { "properties": { "order_id": { "type": "keyword" }, "amount": { "type": "scaled_float", "scaling_factor": 100 } } }
}

# 2. reindex（大量資料用 slices 平行、wait_for_completion=false 背景執行）
POST _reindex?slices=auto&wait_for_completion=false
{ "source": { "index": "orders-v1" }, "dest": { "index": "orders-v2", "op_type": "create" } }
GET _tasks?actions=*reindex&detailed

# 3. 恢復設定、補上 reindex 期間的新資料（依 updated_at 再跑一次增量 reindex）
PUT orders-v2/_settings
{ "index": { "number_of_replicas": 1, "refresh_interval": null } }

# 4. 原子性地切換 alias
POST _aliases
{
  "actions": [
    { "remove": { "index": "orders-v1", "alias": "orders" } },
    { "add":    { "index": "orders-v2", "alias": "orders", "is_write_index": true } }
  ]
}
```

- `_aliases` 裡的多個動作是**原子性**的，應用程式不會看到中間狀態。
- reindex 期間仍有寫入時，要嘛應用程式暫時雙寫兩個索引，要嘛 reindex 後再依時間戳做一次增量補齊，最後短暫停寫切換。
- 保留 `orders-v1` 一段時間當回滾方案（alias 切回去即可），確認沒問題再刪除。

## 範本的版本控管

```console
PUT _component_template/orders-mappings
{
  "version": 3,
  "_meta": { "change": "CHG-2026-1024", "owner": "order-team" },
  "template": { "mappings": { "dynamic": "strict", "properties": { "order_id": { "type": "keyword" } } } }
}

PUT _component_template/base-settings
{ "version": 5, "template": { "settings": { "index.number_of_replicas": 1, "index.refresh_interval": "1s" } } }

PUT _index_template/orders
{
  "index_patterns": ["orders-*"],
  "composed_of": ["base-settings", "orders-mappings"],
  "priority": 200,
  "version": 3
}

# 套用前先模擬：新索引最後會長什麼樣子
POST _index_template/_simulate_index/orders-v3
```

- 範本只影響**之後新建立**的索引，不會改動既有索引。
- `priority` 要高於內建範本（內建的 `logs`、`metrics` 等是 100），否則同名 pattern 可能套到內建範本。
- 範本 JSON（或 YAML）放 Git，用 CI 套用，`version` 與 `_meta` 記錄變更單號。

## 叢集設定變更

```console
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.disk.watermark.low": "80%" } }

# 移除（回到 elasticsearch.yml 或預設值）
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.disk.watermark.low": null } }

GET _cluster/settings?flat_settings
```

優先順序：**transient（已棄用）> persistent > elasticsearch.yml > 預設值**。和 PostgreSQL 的 `postgresql.auto.conf` 一樣，`persistent` 設定會蓋過設定檔，團隊要約定好動態設定用 API、並記錄在變更單；排查時先看 `_cluster/settings` 有沒有覆蓋。

## 滾動重啟

改 elasticsearch.yml 或 JVM 參數、OS 修補時，一次重啟一台：

```console
# 1. 只允許主分片分配，避免重啟期間大量複製副本
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": "primaries" } }

# 2. （可選）flush，加速重啟後的復原
POST _flush
```

```bash
# 3. 重啟一台
sudo systemctl restart elasticsearch
```

```console
# 4. 等節點回來
GET _cat/nodes?v

# 5. 恢復分配，等到 green 再處理下一台
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": null } }
GET _cluster/health?wait_for_status=green&timeout=10m
```

- master-eligible 節點**最後**重啟，目前的 elected master 放在最後一台，減少重新選舉的次數。
- 每台都等 green 再進行下一台。yellow 狀態下重啟另一台，可能剛好讓某個分片只剩 0 份。
- [三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})有完整的實測輸出。

## 滾動升級

| 升級 | 方式 |
| :--- | :--- |
| patch（9.5.4 → 9.5.5） | 滾動升級 |
| minor（9.4 → 9.5） | 滾動升級 |
| major（8.x → 9.x） | **先升到 8.19**，處理完所有 deprecation 後滾動升級到 9.x |

升級前的檢查清單：

1. `GET _migration/deprecations` 與 Kibana 的 Upgrade Assistant，**清到沒有 critical**。
2. 7.x 建立的索引：reindex 或刪除（9.x 只能唯讀）。
3. 完整快照一份（`include_global_state: true`），這是**唯一的回滾方式**。
4. 外掛、Kibana、Logstash、Beats、各語言 client 的相容版本。
5. 先在測試叢集用正式資料的快照演練一次。

升級順序：**data 節點先、master-eligible 最後**（新版本的 master 不能接受舊版本 data 節點加入，反過來可以）。分層架構則是 frozen → cold → warm → hot → master。每台的步驟和滾動重啟相同，只是把 `systemctl restart` 換成：

```bash
sudo systemctl stop elasticsearch
sudo dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5
sudo systemctl daemon-reload
sudo systemctl start elasticsearch
```

實際的 8.19.23 → 9.5.5 三節點滾動升級過程、混合版本期間的行為，見 [滾動升級實作]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})。

> **Elasticsearch 不能降版**。新版本的節點一旦改寫了資料目錄的中繼資料，舊版本就讀不起來。升級失敗的回滾方式只有：用舊版本建立新叢集，從升級前的快照還原。所以升級前的快照與演練不能省。
{: .prompt-danger }

## 變更流程

1. **變更單**：內容、影響範圍、執行步驟、驗證方式、回滾方案。
2. **測試環境演練**：用正式資料的快照還原到測試叢集，實際跑一次，記錄時間。
3. **變更前快照**：mapping 變更、`_update_by_query`、`_delete_by_query`、升級前都要做。
4. **執行**：離峰時段；長時間的 reindex 用 `wait_for_completion=false`，用 `_tasks` 追蹤，必要時 `_tasks/<id>/_cancel`、`_reindex/<id>/_rethrottle`。
5. **驗證**：文件數、關鍵查詢、叢集 green、慢日誌沒有異常。
6. **回滾**：alias 切回舊索引；設定改回；升級則從快照重建。

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| 升級路徑 | 7.17 → 8.x | **8.19 → 9.x**（其他 8.x 要先升到 8.19） |
| 7.x 建立的索引 | 可以讀寫 | 只能唯讀（`index.blocks.write`），要寫入必須先在 8.x reindex |
| transient 叢集設定 | 已棄用 | 已棄用，一律用 persistent |
| bulk API | 寬鬆的動作解析 | 9.0 起動作行的解析更嚴格，格式不標準的 NDJSON 會被拒絕 |
| alias API 的 `local` 參數 | 已棄用 | 移除 |
| `_cluster/reroute` 回應 | 預設回傳叢集狀態 | 不再回傳 |

### 給變更管理的升級建議

- 升級前把自己寫的維運腳本跑一次 9.x 測試叢集：`_cluster/reroute`、alias API、bulk 的格式最常出問題。
- deprecation 日誌（`<cluster.name>_deprecation.json`）在 8.19 上至少觀察一週，找出應用程式還在用的棄用 API。

## 小結

- 應用程式一律透過 alias 存取，mapping 改型別用 reindex + 原子切換 alias。
- 範本（component + index template）放 Git、帶 version，只影響新索引。
- 節點設定用滾動重啟；每台等 green 再進行下一台，master 最後。
- 大版本升級先到 8.19、清完 deprecation、做好快照；不能降版。

下一篇：[故障排查與事件處理]({% post_url 2026-10-24-elasticsearch-ops-09-troubleshooting %})。

### 參考資料

- [Elasticsearch 文件：Aliases](https://www.elastic.co/docs/manage-data/data-store/aliases)
- [Elasticsearch 文件：Reindex API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-reindex)
- [Elasticsearch 文件：Templates](https://www.elastic.co/docs/manage-data/data-store/templates)
- [Elasticsearch 文件：Full-cluster restart and rolling restart](https://www.elastic.co/docs/deploy-manage/maintenance/start-stop-services/full-cluster-restart-rolling-restart-procedures)
- [Elasticsearch 文件：Upgrade your deployment](https://www.elastic.co/docs/deploy-manage/upgrade/deployment-or-cluster)
- [Elasticsearch release notes：breaking changes](https://www.elastic.co/docs/release-notes/elasticsearch/breaking-changes)
