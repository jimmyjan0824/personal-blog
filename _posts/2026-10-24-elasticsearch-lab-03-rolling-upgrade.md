---
title: Elasticsearch 安裝部署 03：滾動升級 8.19 → 9.5（Rocky Linux 9）
date: 2026-10-24 16:03:00 +0800
categories: [Elasticsearch, 安裝部署]
tags: [elasticsearch, elasticsearch9, elasticsearch8, upgrade, rolling-upgrade, rpm, deprecation, snapshot, cluster-state-encryption, dba]
description: 在持續寫入的狀態下，把 Elasticsearch 8.19.23 三節點叢集用 RPM 一台一台滾動升級到 9.5.5：升級前的 deprecation 與快照檢查、每台的升級步驟與耗時、升級後的驗證、9.5 新增的叢集狀態加密要補的 keystore 設定，以及實測證明無法直接降版，所有輸出皆為實測結果。
---

[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})示範了 9.5 的新叢集，但多數人手上的是 8.x 的舊叢集。這篇把一個 **8.19.23 的三節點叢集，在背景持續寫入的狀態下滾動升級到 9.5.5**，一台一台換、服務不中斷，並實際試試看升級後能不能退回 8.19。升級的規劃與變更流程見[變更管理與發布]({% post_url 2026-10-24-elasticsearch-ops-08-change-management %})。

{% include elasticsearch-ops-series.md %}

{% include elasticsearch-lab-env.md %}

## 架構與升級路徑

| 主機 | IP | 角色 | 升級前 | 升級後 |
| :--- | :--- | :--- | :--- | :--- |
| `esu1` | 192.168.60.31 | master + data + ingest | 8.19.23 | 9.5.5 |
| `esu2` | 192.168.60.32 | master + data + ingest | 8.19.23 | 9.5.5 |
| `esu3` | 192.168.60.33 | master + data + ingest | 8.19.23 | 9.5.5 |

**跨大版本的滾動升級只能從 8.19 出發**：9.5 的 `minimum_wire_compatibility_version` 是 8.19.0，比 8.19 舊的節點無法和 9.x 節點組成叢集。路徑是：

| 現在的版本 | 路徑 |
| :--- | :--- |
| 7.x | 先升到 7.17 → 滾動升級到 8.19 → 滾動升級到 9.5；7.x 建立的索引要在 8.x 時 reindex（9.x 只讀得了 8.0 以後建立的索引） |
| 8.0～8.18 | 先滾動升級到 8.19 的最新 patch → 再滾動升級到 9.5 |
| 8.19 | 直接滾動升級到 9.5（本文） |
| 9.0～9.4 | 直接滾動升級到 9.5 |

## 步驟 0：升級前的 8.19 叢集

叢集的建置方式和[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})相同（自建 CA、同一份 `elasticsearch.yml`），只有三個地方不同：

- 套件庫是 `8.x`（`baseurl=https://artifacts.elastic.co/packages/8.x/yum`），安裝 `elasticsearch-8.19.23`。
- 刪掉 `cluster.state.encryption.required`：8.19 不認得，會拒絕啟動（見[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})的版本比較）。
- `thread_pool.search.queue_size` 寫成 8.19 的預設值 `1000`：模擬「把舊版的預設值寫死在設定檔」的常見狀況。

```console
[esu1]# cat /etc/rocky-release; rpm -q elasticsearch; cat /etc/yum.repos.d/elasticsearch.repo | grep baseurl
Rocky Linux release 9.8 (Blue Onyx)
elasticsearch-8.19.23-1.aarch64
baseurl=https://artifacts.elastic.co/packages/8.x/yum

[esu1] GET /_cat/nodes?v&h=name,version,node.role,master
name version node.role master
esu2 8.19.23 dim       -
esu3 8.19.23 dim       -
esu1 8.19.23 dim       *
```

測試資料：`orders`（3 主分片、1 副本、10 萬筆），以及一個內建 `logs-*-*` 範本建立的 data stream，用來觀察升級前後新建的索引有什麼不同：

```console
[esu1] POST /logs-app-default/_doc?refresh=wait_for&filter_path=result,_index
{"@timestamp":"2026-10-24T08:00:00Z","message":"before upgrade","host":{"name":"web1"}}
{"_index":".ds-logs-app-default-2026.10.24-000001","result":"created"}

[esu1] GET /.ds-logs-app-default-*/_settings/index.mode,index.version.created?flat_settings&include_defaults&filter_path=*.settings,*.defaults.index\.mode&pretty
{
  ".ds-logs-app-default-2026.10.24-000001" : {
    "settings" : {
      "index.version.created" : "8537000"
    },
    "defaults" : {
      "index.mode" : "standard"
    }
  }
}

[esu1] GET /_cat/indices/orders?v&h=health,index,pri,rep,docs.count,store.size
health index  pri rep docs.count store.size
green  orders   3   1     100000     12.3mb
```

## 步驟 1：升級前檢查

### Deprecation API

**升級前一定要先看 `_migration/deprecations`**，`critical` 的項目不處理，升級後可能啟動失敗：

```console
[esu1] GET /_migration/deprecations?pretty
{
  "cluster_settings" : [ ],
  "node_settings" : [
    {
      "level" : "warning",
      "message" : "setting [xpack.monitoring.collection.enabled] is deprecated and will be removed after 8.0",
      "url" : "https://ela.st/es-deprecation-7-monitoring-settings",
      "details" : "the setting [xpack.monitoring.collection.enabled] is currently set to [false], remove this setting (nodes impacted: [esu1, esu3, esu2])",
      "resolve_during_rolling_upgrade" : false
    }
  ],
  "ml_settings" : [ ],
  "ilm_policies" : { },
  "data_streams" : { },
  "index_settings" : { },
  "templates" : { }
}
```

實測時的設定檔還有 `xpack.monitoring.collection.enabled: false`，這裡被抓出來；只是 `warning`，不擋升級，但升級後會變成 `critical`（步驟 3）。這也是本系列設定檔最後把這一行改成註解的原因。`index_settings` 是空的：沒有 7.x 建立的索引，不需要 reindex。

Kibana 的 **Upgrade Assistant** 顯示的就是這個 API 的結果，有 Kibana 的話用它比較好讀。

### 系統索引

```console
[esu1] GET /_migration/system_features?filter_path=migration_status,features.feature_name,features.migration_status&pretty
{
  "features" : [
    { "feature_name" : "async_search", "migration_status" : "NO_MIGRATION_NEEDED" },
    { "feature_name" : "enrich", "migration_status" : "NO_MIGRATION_NEEDED" },
    ...
    { "feature_name" : "security", "migration_status" : "NO_MIGRATION_NEEDED" },
    ...
    { "feature_name" : "watcher", "migration_status" : "NO_MIGRATION_NEEDED" }
  ],
  "migration_status" : "NO_MIGRATION_NEEDED"
}
```

從 7.x 升上來的叢集，這裡可能會是 `MIGRATION_NEEDED`，要先 `POST _migration/system_features` 讓系統索引升級。

### 升級前的快照

**這是唯一的退路**（步驟 5 會證明不能降版），所以一定要做，而且要包含 global state：

```console
[esu1] PUT /_snapshot/upgrade_repo
{"type":"fs","settings":{"location":"/mnt/es-snapshots/upgrade"}}
{"acknowledged":true}

[esu1] PUT /_snapshot/upgrade_repo/before-9.5.5?wait_for_completion=true&filter_path=snapshot.snapshot,snapshot.version,snapshot.state,snapshot.shards
{"indices":"*","include_global_state":true}
{"snapshot":{"snapshot":"before-9.5.5","version":"8.19.9-8.19.23","state":"SUCCESS","shards":{"total":7,"failed":0,"successful":7}}}
```

### 其他要先確認的

這些在實測環境沒有，正式環境升級前要逐項確認（**未實測**）：

- **用戶端相容性**：9.x 的伺服器接受 8.x 的 REST client（相容模式），但應用程式的 client 函式庫最好在升級後也跟著升；Logstash、Beats、Elastic Agent、Kibana 的版本相容性看官方的 [Product compatibility](https://www.elastic.co/support/matrix#matrix_compatibility)。
- **Kibana**：Kibana 要在 Elasticsearch 全部升級完之後再升，版本不能比 Elasticsearch 新；Kibana 第一次啟動就會 migrate `.kibana*` 索引，同樣不能降版（實測見[Kibana 安裝與設定]({% post_url 2026-10-24-elasticsearch-lab-04-kibana %})）。
- **外掛**：每台節點的外掛要在啟動 9.5 之前換成 9.5 的版本，否則啟動失敗。
- **CCR**：有 follower 叢集時先升 follower（DR）叢集，再升 leader。
- **磁碟空間**：升級期間副本可能重新分配，每台至少留到低水位以下。

## 步驟 2：滾動升級

**順序：非 master 的節點先，目前的 master 最後**。master 最後換，整個升級過程只會發生一次 master 切換；先換 master 的話，新 master 是 8.19 的節點，9.5 的節點加入後可能又要換一次。

每台節點的步驟：

```bash
# 1. 只允許主分片分配：這台停機時，副本不要搬到其他節點
curl ... -X PUT "https://<另一台>:9200/_cluster/settings" -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
# 2. flush：讓重新啟動後的復原只需要很少的操作
curl ... -X POST "https://<另一台>:9200/_flush"
# 3. 停止、換套件庫、升級
sudo systemctl stop elasticsearch
sudo cp elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo     # 9.x 的套件庫
sudo dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5
# 4. 啟動
sudo systemctl daemon-reload && sudo systemctl start elasticsearch
# 5. 等它重新加入叢集，恢復分配，等 green
curl ... -X PUT "https://<另一台>:9200/_cluster/settings" -d '{"persistent":{"cluster.routing.allocation.enable":null}}'
curl ... "https://<另一台>:9200/_cluster/health?wait_for_status=green&timeout=10m"
```

背景同時有一個程式每 0.5～1 秒寫入一筆，寫入的目標節點會避開正在升級的那台（和應用程式透過負載平衡器連線的效果相同）。

### 第一台：esu2

```console
master=esu1，升級順序：esu2 esu3 esu1

[esu2] PUT /_cluster/settings
{"persistent":{"cluster.routing.allocation.enable":"primaries"}}
{"acknowledged":true,"persistent":{"cluster":{"routing":{"allocation":{"enable":"primaries"}}}},"transient":{}}

[esu2] POST /_flush?filter_path=_shards
{"_shards":{"total":8,"successful":8,"failed":0}}

[esu2]# systemctl stop elasticsearch && echo stopped
stopped

[esu2]# cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && time dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 2>&1 | grep -vE "B/s \||^\s*$" | tail -25
Upgrade  1 Package
Total download size: 662 M
Downloading Packages:
...
Running transaction
  Preparing        :                                                        1/1 
  Running scriptlet: elasticsearch-9.5.5-1.aarch64                          1/2 
  Upgrading        : elasticsearch-9.5.5-1.aarch64                          1/2 
  Running scriptlet: elasticsearch-9.5.5-1.aarch64                          1/2 
Failed to restart systemd-sysctl.service: Unit systemd-sysctl.service not found.
  Running scriptlet: elasticsearch-8.19.23-1.aarch64                        2/2 
  Cleanup          : elasticsearch-8.19.23-1.aarch64                        2/2 
...
Upgraded:
  elasticsearch-9.5.5-1.aarch64                                                 
Complete!

real	2m10.675s

[esu2]# rpm -q elasticsearch; ls /etc/elasticsearch/ | grep -E "rpmnew|rpmsave" || echo "(no .rpmnew / .rpmsave)"
elasticsearch-9.5.5-1.aarch64
(no .rpmnew / .rpmsave)

[esu2]# systemctl daemon-reload && time systemctl start elasticsearch && systemctl is-active elasticsearch

real	0m12.483s
active

（esu2 重新加入：等了 0 秒）
[esu1] GET /_cat/nodes?v&h=name,version,master&s=name
name version master
esu1 8.19.23 *
esu2 9.5.5   -
esu3 8.19.23 -

[esu1] PUT /_cluster/settings
{"persistent":{"cluster.routing.allocation.enable":null}}
{"acknowledged":true,"persistent":{},"transient":{}}

（green：等了 1 秒）
esu2：178 秒
```

- `dnf install` 指定 9.5.5 就是升級（`Upgrade 1 Package`）。**用 `install` 加完整版本號，不要用 `dnf update`**，才不會不小心升到別的版本。
- `(no .rpmnew / .rpmsave)`：我們改過的 `elasticsearch.yml`、`jvm.options.d/` 被保留，RPM 也沒有另外放新版的範例檔。Elastic 的 RPM 把設定檔標成 `%config(noreplace)`，改過的檔案不會被覆蓋。
- 升級後**不需要改任何設定**就能以 9.5.5 啟動：8.19 版的設定檔裡沒有 9.x 移除的參數（若有 `enable_for_single_data_node`、frozen 索引相關設定，要先拿掉）。
- 混合版本期間 9.5 的節點加入 8.19 的 master 沒有問題，副本也分配回來了（`green` 等了 1 秒）。

### 第二、三台

```console
[esu1] GET /_cat/nodes?v&h=name,version,master&s=name
name version master
esu1 8.19.23 *
esu2 9.5.5   -
esu3 9.5.5   -
（green：等了 1 秒）
esu3：150 秒

======== 升級 esu1（寫入改送 esu2） ========
...
[esu1]# ... time dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 ...
real	3m14.192s
...
[esu2] GET /_cat/nodes?v&h=name,version,master&s=name
name version master
esu1 9.5.5   -
esu2 9.5.5   -
esu3 9.5.5   *
（green：等了 1 秒）
esu1：211 秒
```

master esu1 停機時，剩下的兩台 9.5.5 節點選出 esu3 當新 master。各台耗時（兩次實測）：

| 節點 | 第 1 次 | 第 2 次 | 其中 `dnf install` | `systemctl start` |
| :--- | :--- | :--- | :--- | :--- |
| 第一台（非 master） | 196 秒 | 178 秒 | 2m10s～3m14s | 11.2～12.6 秒 |
| 第二台（非 master） | 139 秒 | 150 秒 | | |
| 第三台（master） | 205 秒 | 211 秒 | | |

**時間幾乎都花在下載 662 MB 的套件**。正式環境應該先在每台執行 `dnf install --downloadonly`（或架內部的套件鏡像），停機時只剩安裝與啟動，每台可以縮短到 1 分鐘以內（**未實測**）。重新加入、恢復分配到 green 都在 1 秒內：停機前 flush 過、停機時間短，副本只要補幾筆操作。

## 步驟 3：升級後的驗證

```console
[esu1] GET /_cat/nodes?v&h=name,version,node.role,master&s=name
name version node.role master
esu1 9.5.5   dim       -
esu2 9.5.5   dim       -
esu3 9.5.5   dim       *

[esu1] GET /?filter_path=version.number,version.lucene_version,version.minimum_wire_compatibility_version,version.minimum_index_compatibility_version&pretty
{
  "version" : {
    "number" : "9.5.5",
    "lucene_version" : "10.5.1",
    "minimum_wire_compatibility_version" : "8.19.0",
    "minimum_index_compatibility_version" : "8.0.0"
  }
}

[esu1] GET /_cluster/health?filter_path=status,number_of_nodes,active_shards,unassigned_shards
{"status":"green","number_of_nodes":3,"active_shards":16,"unassigned_shards":0}

背景寫入：共      845 次，HTTP 狀態統計：
 845 201

[esu1] POST /orders/_refresh
{"_shards":{"total":6,"successful":6,"failed":0}}

[esu1] GET /orders/_count
{"count":100845,"_shards":{"total":3,"successful":3,"skipped":0,"failed":0}}
```

**升級期間 845 次寫入全部成功**（`HTTP 201`，兩次實測分別是 841 次與 845 次，都沒有失敗），寫入之間的間隔最長 1 秒，`orders` 的文件數正好是 10 萬 + 845 筆，沒有遺失。

### 既有索引與新索引

```console
[esu1] GET /orders/_settings/index.version.created,index.version.compatibility?flat_settings&include_defaults&filter_path=*.settings,*.defaults&pretty
{
  "orders" : {
    "settings" : {
      "index.version.created" : "8537000"
    },
    "defaults" : {
      "index.version.compatibility" : "8537000"
    }
  }
}

[esu1] GET /_migration/deprecations?filter_path=cluster_settings,node_settings,index_settings&pretty
{
  "cluster_settings" : [ ],
  "node_settings" : [
    {
      "level" : "critical",
      "message" : "Setting [xpack.monitoring.collection.enabled] is deprecated",
      "url" : "https://ela.st/es-10-legacy-monitoring-removal",
      "details" : "Remove the [xpack.monitoring.collection.enabled] setting. This setting will be removed in 10.0. (nodes impacted: [esu3, esu2, esu1])",
      "resolve_during_rolling_upgrade" : false
    }
  ],
  "index_settings" : {
    "orders" : [
      {
        "level" : "critical",
        "message" : "Old index with a compatibility version < 9.0",
        "url" : "https://ela.st/es-deprecation-9-index-version",
        "details" : "This index has version: 8.19.9-8.19.22",
        "resolve_during_rolling_upgrade" : false,
        "_meta" : {
          "reindex_required" : true
        }
      }
    ]
  }
}
```

- 升級**不會改寫既有的索引**：`orders` 還是 8.x 建立的格式（`index.version.created: 8537000`），9.5 照樣讀寫。
- 升級後的 deprecation API 已經在看**下一個大版本（10.0）**：8.x 建立的索引被標成 `critical`、`reindex_required: true`，意思是 **10.0 之前要 reindex**（或讓 ILM 自然滾動、舊索引過期刪除），9.x 期間不用急。`xpack.monitoring.collection.enabled` 也從 warning 升為 critical：10.0 會移除，到時候還留在設定檔裡就會啟動失敗。

data stream 滾動（rollover）之後，新的 backing index 才是 9.x 的格式：

```console
[esu1] POST /logs-app-default/_rollover?filter_path=old_index,new_index,rolled_over
{"old_index":".ds-logs-app-default-2026.10.24-000001","new_index":".ds-logs-app-default-2026.10.24-000002","rolled_over":true}

[esu1] GET /.ds-logs-app-default-*/_settings/index.mode,index.version.created?flat_settings&include_defaults&filter_path=*.settings,*.defaults.index\.mode&pretty
{
  ".ds-logs-app-default-2026.10.24-000002" : {
    "settings" : {
      "index.version.created" : "9111000"
    },
    "defaults" : {
      "index.mode" : "standard"
    }
  },
  ".ds-logs-app-default-2026.10.24-000001" : {
    "settings" : {
      "index.version.created" : "8537000"
    },
    "defaults" : {
      "index.mode" : "standard"
    }
  }
}
```

新的 backing index 仍然是 `standard` 模式：9.x 全新叢集的 `cluster.logsdb.enabled` 預設是 `true`（`logs-*-*` 用 LogsDB），但**從 8.x 升級上來的叢集會維持原本的行為**，不會在升級後突然改變日誌索引的格式。要改用 LogsDB 要自己設 `cluster.logsdb.enabled: true`，先在測試環境確認寫入的 CPU 負擔。

### 設定檔裡寫死的舊預設值

8.19 的設定檔寫了 `thread_pool.search.queue_size: 1000`，升級後設定檔原封不動，這個值**照樣生效**：9.5 的預設是 16000，但明確寫在設定檔的值優先。這就是「把預設值寫進設定檔」的代價，**升級後要對照新版本的預設值重新檢查一次**，用的是和本系列相同的方法（`GET _cluster/settings?include_defaults=true` 比對）。本系列的叢集設定檔標「預設（9.x；8.19 是 1000）」，升級完就該改成 16000 或直接拿掉。

## 步驟 4：叢集狀態加密（9.5 新增）

9.5 的 `cluster.state.encryption.required` 預設是 `true`：叢集狀態裡的秘密資訊要加密，金鑰的保護密碼放在 keystore。**全新安裝時 RPM 的 auto-config 會自動產生密碼，從 8.x 升級上來的節點不會**：

```console
[esu1]# /usr/share/elasticsearch/bin/elasticsearch-keystore list
autoconfiguration.password_hash
keystore.seed

[esu1] GET /_health_report/cluster_state_encryption?pretty
{
  "cluster_name" : "es-upgrade",
  "indicators" : {
    "cluster_state_encryption" : {
      "status" : "green",
      "symptom" : "Cluster state encryption is not configured.",
      "details" : {
        "encryption_required" : true,
        "state" : "disabled",
        "active_password_id" : "(unset)"
      }
    }
  }
}
```

`encryption_required: true` 但 `state: disabled`，**health report 卻是 green**：叢集狀態裡目前沒有需要加密的秘密，所以不算異常，但之後一旦用到需要加密的功能（例如 ES|QL 外部資料來源的憑證）就會失敗。不要被 green 騙了，升級後就補上。

每台節點各自加密碼（隨機產生、每台不同），再線上重新載入，**不需要重啟**：

```bash
openssl rand -base64 32 | tr -d "\n" | sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add -x -f cluster.state.encryption.password.v1
printf v1 | sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add -x -f cluster.state.encryption.active_password_id
```

```console
[esu1]# ... && /usr/share/elasticsearch/bin/elasticsearch-keystore list | grep cluster.state
cluster.state.encryption.active_password_id
cluster.state.encryption.password.v1
（esu2、esu3 相同）

[esu1] POST /_nodes/reload_secure_settings?filter_path=_nodes,nodes.*.name,nodes.*.reload_exception&pretty
{
  "_nodes" : {
    "total" : 3,
    "successful" : 3,
    "failed" : 0
  },
  "nodes" : {
    "N-xrmlphSWu6jDAmm0HCtA" : { "name" : "esu1" },
    "p58d_6NgRDq-xJ7mOQ5nEg" : { "name" : "esu2" },
    "UxP7q-LLRM6VqWEJcyMT-g" : { "name" : "esu3" }
  }
}

[esu1] GET /_health_report/cluster_state_encryption?pretty
{
  "cluster_name" : "es-upgrade",
  "indicators" : {
    "cluster_state_encryption" : {
      "status" : "green",
      "symptom" : "Cluster state encryption is healthy.",
      "details" : {
        "metadata_password_id" : "v1",
        "key_count" : 1,
        "active_key_id" : "pq57PrpwRZOMuTFoNhAe0g",
        "active_password_id" : "v1",
        "encryption_required" : true,
        "state" : "ready"
      }
    }
  }
}
```

- `-x` 從標準輸入讀值、`-f` 覆寫已存在的項目。密碼的 ID（這裡是 `v1`）日後輪替時可以換成 `v2`，舊的密碼要留到確認切換完成。
- 三台的密碼都不同，叢集照樣 `ready`：這個密碼保護的是**每個節點自己的**金鑰副本，不需要在節點之間同步。
- keystore 的密碼項目要納入設定管理與備份；遺失了要怎麼處理見官方文件的 [Cluster state encryption key](https://www.elastic.co/docs/reference/elasticsearch/cluster-state-encryption-key)。

## 步驟 5：能不能降版？

把 esu1 裝回 8.19.23 試試看。注意要先把剛剛加的 `cluster.state.encryption.*` 從 keystore 移除，否則 8.19 會先因為不認得這兩個 secure setting 而失敗（`unknown secure setting [cluster.state.encryption.active_password_id]`），看不到真正的原因：

```console
[esu2] PUT /_cluster/settings
{"persistent":{"cluster.routing.allocation.enable":"primaries"}}

[esu1]# systemctl stop elasticsearch && for k in cluster.state.encryption.password.v1 cluster.state.encryption.active_password_id; do /usr/share/elasticsearch/bin/elasticsearch-keystore remove $k; done && cp /root/conf/elasticsearch-8.repo /etc/yum.repos.d/elasticsearch.repo && dnf downgrade -y --enablerepo=elasticsearch elasticsearch-8.19.23 2>&1 | grep -E "Downgrad|Complete|Error" | head -5; rpm -q elasticsearch
Downgrading:
Downgrade  1 Package
  Downgrading      : elasticsearch-8.19.23-1.aarch64                        1/2 
Downgraded:
Complete!
elasticsearch-8.19.23-1.aarch64

[esu1]# systemctl start elasticsearch; systemctl is-active elasticsearch
Job for elasticsearch.service failed because the control process exited with error code.
See "systemctl status elasticsearch.service" and "journalctl -xeu elasticsearch.service" for details.
failed
[esu1]# grep -A1 'fatal exception' /var/log/elasticsearch/es-upgrade.log | grep Exception | tail -1
java.lang.IllegalArgumentException: indexCreatedVersionMajor is in the future: 10
```

套件可以降回去，**但 8.19 讀不了資料目錄**：9.5 第一次啟動時就用 Lucene 10 改寫了節點的 metadata（`/var/lib/elasticsearch/_state/`，錯誤訊息還附帶一個 `CorruptIndexException ... _state/segments_*`），8.19 內建的 Lucene 9.12 看不懂。叢集裡的其他兩台 9.5.5 也不會接受 8.19 的節點加入（wire compatibility 只能往前）。

結論：**Elasticsearch 的升級是單向的**，不論單一節點或整個叢集，都沒有原地降版這回事。升級失敗時的退路只有：

1. 另外準備一個 8.19 的空叢集（或清空資料目錄後重灌 8.19）。
2. 從升級前的快照（本文的 `before-9.5.5`）還原。9.5 之後才寫入的資料會遺失，要靠應用程式重送或從來源重建。

所以**升級前的快照是必要步驟**，而且要在測試環境先完整演練過一次升級（包括應用程式），正式環境才不會用到這條退路。

實測最後把 esu1 重新裝回 9.5.5、補回 keystore 的密碼，它就以原本的資料重新加入叢集（`esu1 9.5.5`、green）。

## 混合版本期間的現象

升級進行到一半（有 8.19 也有 9.5）時，日誌裡會出現一些 WARN，三台都升完就消失，不用處理：

| 訊息 | 原因 |
| :--- | :--- |
| `error adding index template [logs-elasticsearch.querylog@mappings] for [stack] ... MapperParsingException: Failed to parse mapping: unknown parameter [preserve_leaf_arrays] on mapper [params] of type [flattened]` | 9.5 的節點想安裝新版的內建範本，但 master 還是 8.19，不認得新的 mapping 參數 |
| `ElasticInferenceServiceAuthorizationHandler Failed to revoke access to default inference endpoint IDs ... ClusterBlockException` | 節點啟動時叢集狀態還沒準備好，之後會重試 |
| `marking unavailable shards as stale` | 節點停機時寫入的分片，它的副本被移出 in-sync 集合，重新加入後補上差異（正常的滾動升級行為） |
| `master not discovered or elected yet ... have only discovered non-quorum` | 降版測試時 esu1 停機、master 切換的那幾秒 |

要注意的反而是**混合版本不要停留太久**：混合期間 9.x 的新功能不能用、內建範本無法更新，而且新建的索引如果主分片落在 9.5 節點上，它的副本就不能分配到 8.19 的節點（新版格式的分片不能複製到舊版節點）。本文的實測沒有新建索引，所以沒有遇到副本分配不出去的情況。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| 降版後啟動失敗：`indexCreatedVersionMajor is in the future: 10` | 9.5 已經用 Lucene 10 改寫資料目錄的 metadata | 不能降版，只能從升級前的快照還原到 8.19 叢集 |
| 降版後啟動失敗：`unknown secure setting [cluster.state.encryption.active_password_id]` | 8.19 不認得 9.5 的 keystore 項目 | 這只是先被擋下，移除後還是會遇到上一列的錯誤 |
| 升級後 health report 是 green，但 `Cluster state encryption is not configured.` | 升級上來的節點沒有 auto-config，keystore 沒有加密密碼 | 每台加密碼、`reload_secure_settings` |
| 升級後 deprecation API 出現 `critical` 的 `Old index with a compatibility version < 9.0` | 已經在檢查 10.0 的相容性 | 10.0 之前 reindex 或讓舊索引過期 |
| 升級後搜尋佇列還是 1000 | 設定檔寫死了 8.19 的預設值 | 升級後重新比對預設值，拿掉舊版的預設值 |
| 每台升級 2.5～3.5 分鐘 | 停機後才下載 662 MB 的套件 | 事先 `dnf install --downloadonly` |
| 容器內：`Failed to restart systemd-sysctl.service`、`/usr/lib/systemd/systemd-sysctl: No such file or directory` | RPM 的 scriptlet 要重新載入 sysctl，容器沒有這個服務 | 實體機不會出現；不影響升級 |

## 驗證方式與結果

驗證環境、建置檔與 `compose.yaml` 和[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})相同，esu1～esu3 使用已安裝 8.19.23 的 `eslab-rocky9-es8` 映像。執行 `./30-rolling-upgrade.sh`，輸出記錄在 `results/30-rolling-upgrade.log`，背景寫入的每一筆結果在 `results/30-writer.log`。

| 項目 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 升級前檢查 | `_migration/deprecations`、`system_features`、快照 | 沒有 critical、`NO_MIGRATION_NEEDED`、快照 `SUCCESS` | ✅（1 個 warning） |
| 滾動升級 | 依序升級三台、master 最後 | 每台重新加入、green | ✅ 每台 139～211 秒 |
| 服務不中斷 | 背景每 0.5～1 秒寫入一筆 | 全部 HTTP 201 | ✅ 845 / 845（第一次 841 / 841） |
| 資料完整 | 升級後 `_count` | 10 萬 + 寫入次數 | ✅ 100845 |
| 設定檔 | `.rpmnew` / `.rpmsave`、啟動 | 設定檔保留、不需修改就能啟動 | ✅ |
| 叢集狀態加密 | health report | 補密碼後 `state: ready` | ✅ 不需重啟 |
| 降版 | `dnf downgrade` 後啟動 | 記錄結果 | ✅ 確認無法降版 |

**錯誤處理紀錄**：

- 第一次的降版測試看到的是 `unknown secure setting`，查出是前一步加進 keystore 的 9.5 項目造成的；腳本改成降版前先移除，再手動與完整重跑各確認一次，得到真正的錯誤 `indexCreatedVersionMajor is in the future: 10`。
- 背景寫入透過 `docker exec` 執行，實際的寫入間隔約 0.64 秒，不是腳本設定的 0.5 秒。

## 版本差異比較：升級時要注意的 8.19 → 9.5 變更

| 項目 | 8.19 | 9.5 | 升級時要做什麼 |
| :--- | :--- | :--- | :--- |
| 節點相容性 | 7.17 以上 | 8.19 以上 | 從 8.19 出發 |
| 索引相容性 | 7.0 以後建立的索引 | 8.0 以後建立的索引 | 7.x 的索引在升級前 reindex |
| Lucene | 9.12.2 | 10.5.1 | 不能降版，升級前一定要快照 |
| 叢集狀態加密 | 無 | 預設 required，keystore 要有密碼 | 升級後每台補密碼 |
| 搜尋佇列預設 | 1000 | 16000 | 設定檔寫死舊值的要重新評估 |
| merge policy 預設 | floor 2mb、每層 10 個、一次 10 個 | 16mb、8 個、16 個 | 寫在範本裡的舊值會保留 |
| `cluster.logsdb.enabled` | false | 全新叢集 true | 升級上來的叢集維持原行為 |
| frozen 索引、`search_throttled` 執行緒池、`enable_for_single_data_node` | 有 | 移除 | 設定檔有寫的要先拿掉，否則無法啟動 |
| `xpack.monitoring.collection.enabled` | warning | critical（10.0 移除） | 改用 Elastic Agent / Metricbeat，拿掉設定 |
| 8.x 建立的索引 | — | deprecation critical、`reindex_required` | 10.0 之前處理 |

## 小結

- 跨大版本的滾動升級要從 **8.19** 出發；先看 deprecation API、確認系統索引、**做快照**。
- 非 master 先、master 最後；每台 `allocation.enable: primaries` → flush → 停止 → `dnf install` 指定版本 → 啟動 → 恢復分配 → 等 green。
- 實測三台、背景持續寫入：845 次寫入全部成功、資料沒有遺失，每台 2.5～3.5 分鐘，時間幾乎都花在下載套件。
- RPM 升級會保留改過的設定檔，8.19 的設定檔不改也能以 9.5 啟動；但寫死的舊預設值會跟著留下來。
- 升級上來的節點要自己在 keystore 補**叢集狀態加密**的密碼，health report 的 green 不代表已經設定好。
- **Elasticsearch 不能降版**：9.5 第一次啟動就改寫了資料目錄，退路只有升級前的快照。

下一篇：[Kibana 安裝與設定]({% post_url 2026-10-24-elasticsearch-lab-04-kibana %})，在三節點叢集旁加一台 Kibana 9.5.5，含完整的 kibana.yml 與故障測試。

### 參考資料

- [Elastic Docs：Upgrade Elasticsearch](https://www.elastic.co/docs/deploy-manage/upgrade/deployment-or-cluster/elasticsearch)
- [Elastic Docs：Prepare to upgrade](https://www.elastic.co/docs/deploy-manage/upgrade/prepare-to-upgrade)
- [Elastic Docs：Deprecation info API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-migration-deprecations)
- [Elastic Docs：Cluster state encryption key](https://www.elastic.co/docs/reference/elasticsearch/cluster-state-encryption-key)
- [Elastic Docs：Breaking changes（9.x）](https://www.elastic.co/docs/release-notes/elasticsearch/breaking-changes)
- [Elastic：Product compatibility matrix](https://www.elastic.co/support/matrix#matrix_compatibility)
