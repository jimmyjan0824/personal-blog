---
title: Elasticsearch 運維 10：自動化與規範制定
date: 2026-10-24 17:30:00 +0800
categories: [Elasticsearch, 自動化]
tags: [elasticsearch, elasticsearch9, elasticsearch8, automation, ansible, eck, kubernetes, terraform, standards, naming-convention, documentation]
description: 以 Elasticsearch 9.5 為主，整理日常維運腳本、Ansible 自動化部署、ECK（Kubernetes Operator）、Terraform 管理叢集設定與範本、索引與欄位的命名規範、mapping 與查詢的開發規範，以及運維文件化，並比較 8.19 的差異。
---

前面九篇整理了 Elasticsearch 運維的各個面向，最後一篇把它們串起來：**能自動化的就自動化，不能自動化的就寫成規範與文件**。本篇最後比較 8.19 對自動化與規範的影響。

{% include elasticsearch-ops-series.md %}

## 日常維運腳本

| 工作 | 頻率 | 做法 |
| :--- | :--- | :--- |
| 健康檢查 | 每分鐘 | 監控系統（[監控篇]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})） |
| 快照 | 每 30 分鐘 / 每天 | **SLM**，不要自己寫 cron |
| 過期資料刪除 | 每天 | **ILM / data stream lifecycle**，不要用 cron + `DELETE` |
| 憑證到期檢查 | 每天 | `GET _ssl/certificates` |
| 設定漂移檢查 | 每天 | 比對 `_cluster/settings`、範本與 Git 上的版本 |
| deprecation 檢查 | 每週 | `GET _migration/deprecations` |
| 容量報表 | 每週 | `_cat/allocation`、`_cat/indices` 存成時間序列 |

一個最小的檢查腳本（用 API key，不要在腳本裡寫 `elastic` 的密碼）：

```bash
#!/usr/bin/env bash
# /usr/local/bin/es-daily-check.sh：每天的設定與憑證檢查，有異常就非 0 結束讓排程系統告警
set -euo pipefail
ES=https://esc1:9200
AUTH="Authorization: ApiKey ${ES_API_KEY:?}"
CURL=(curl -sS --fail --cacert /etc/elasticsearch-check/ca.crt -H "$AUTH")
rc=0

status=$("${CURL[@]}" "$ES/_cluster/health" | jq -r .status)
[ "$status" = green ] || { echo "cluster status: $status"; rc=1; }

# 30 天內到期的憑證
"${CURL[@]}" "$ES/_ssl/certificates" | jq -r --argjson now "$(date +%s)" \
  '.[] | select((.expiry | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) - $now < 30*86400) | "cert expiring: \(.path) \(.expiry)"' \
  | grep . && rc=1

# persistent 叢集設定與 Git 上的版本不同
"${CURL[@]}" "$ES/_cluster/settings?flat_settings" | jq -S .persistent > /tmp/persistent.json
diff -u /opt/es-config/cluster-settings.json /tmp/persistent.json || rc=1

# critical deprecation
n=$("${CURL[@]}" "$ES/_migration/deprecations" | jq '[.. | objects | select(.level? == "critical")] | length')
[ "$n" -eq 0 ] || { echo "critical deprecations: $n"; rc=1; }
exit $rc
```

## Ansible 自動化部署

把[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})與 [三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})兩篇實作的步驟寫成 role：

{% raw %}
```text
roles/elasticsearch/
├── defaults/main.yml        # es_version: 9.5.5、es_cluster_name、es_heap（留空 = 自動）
├── tasks/
│   ├── os.yml               # sysctl、swap、limits
│   ├── install.yml          # Elastic 套件庫、dnf install elasticsearch-{{ es_version }}、versionlock
│   ├── certs.yml            # 從保管庫取 CA 簽好的節點憑證
│   ├── config.yml           # elasticsearch.yml、jvm.options.d、systemd override
│   └── service.yml
├── templates/
│   ├── elasticsearch.yml.j2
│   └── heap.options.j2
└── handlers/main.yml        # restart 由 rolling-restart playbook 控制，不要直接重啟
```
{% endraw %}

重點：

- **版本要釘住**：`dnf install elasticsearch-9.5.5` + `dnf versionlock`，避免 `dnf update` 不小心把整個叢集升級。官方套件庫設定 `enabled=0`、安裝時才 `--enablerepo` 也是同樣的目的。
- **不要用 handler 直接重啟**：elasticsearch.yml 變更後要走滾動重啟（`serial: 1`，每台等 green），寫成獨立的 playbook。
- `cluster.initial_master_nodes` 只在第一次建置的 playbook 裡出現，日常的 template 不要帶。
- 官方的 `elastic.elasticsearch` Ansible role 已不再積極維護，多數團隊自己寫 role。

{% raw %}
```yaml
# rolling-restart.yml
- hosts: es_cluster
  serial: 1
  order: sorted          # master 放最後：用 inventory 排序控制
  tasks:
    - uri: { url: "https://{{ inventory_hostname }}:9200/_cluster/settings", method: PUT, body_format: json,
             body: { persistent: { cluster.routing.allocation.enable: primaries } }, ca_path: /etc/es/ca.crt,
             headers: { Authorization: "ApiKey {{ es_api_key }}" } }
    - systemd: { name: elasticsearch, state: restarted }
    - uri: { url: "https://{{ inventory_hostname }}:9200/_cluster/settings", method: PUT, body_format: json,
             body: { persistent: { cluster.routing.allocation.enable: null } }, ca_path: /etc/es/ca.crt,
             headers: { Authorization: "ApiKey {{ es_api_key }}" } }
    - uri: { url: "https://{{ inventory_hostname }}:9200/_cluster/health?wait_for_status=green&timeout=10m", ca_path: /etc/es/ca.crt,
             headers: { Authorization: "ApiKey {{ es_api_key }}" }, timeout: 660 }
```
{% endraw %}

## ECK：Kubernetes 上的 Elasticsearch

[Elastic Cloud on Kubernetes（ECK）](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s)是官方的 Operator，負責：

- 憑證（自動產生並輪替 transport / HTTP 憑證）、`elastic` 密碼。
- 滾動升級與設定變更（改 `version` 欄位就會依正確的順序升級）。
- 節點的增減與分片排空。

```yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata: { name: prod }
spec:
  version: 9.5.5
  nodeSets:
    - name: default
      count: 3
      config:
        node.roles: [ master, data, ingest ]
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources: { requests: { memory: 16Gi, cpu: 4 }, limits: { memory: 16Gi } }
      volumeClaimTemplates:
        - metadata: { name: elasticsearch-data }
          spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 1Ti } }, storageClassName: fast-ssd }
```

- 容器的 memory limit 要設，heap 會依 limit 自動計算。
- `vm.max_map_count` 要在節點層級設定（DaemonSet 或節點映像），或用 `node.store.allow_mmap: false`（效能較差）。
- 用本機 SSD 的 StorageClass；跨可用區的網路磁碟延遲較高。

## Terraform：管理叢集內的設定

叢集**內部**的設定（ILM、範本、角色、SLM、叢集設定）也應該是程式碼：

```hcl
resource "elasticstack_elasticsearch_index_lifecycle" "app_logs" {
  name = "app-logs-policy"
  hot {
    rollover { max_primary_shard_size = "50gb", max_age = "1d" }
  }
  delete {
    min_age = "180d"
    delete {}
  }
}

resource "elasticstack_elasticsearch_snapshot_lifecycle" "nightly" {
  name          = "nightly"
  schedule      = "0 30 17 * * ?"   # UTC 17:30 = 台北 01:30
  snapshot_name = "<nightly-{now/d}>"
  repository    = "nfs_repo"
  expire_after  = "30d"
  min_count     = 7
}
```

用 Elastic 官方的 [`elastic/elasticstack` provider](https://registry.terraform.io/providers/elastic/elasticstack/latest)。沒有 Terraform 時，至少把 JSON / YAML 放 Git，用 CI 呼叫 API 套用。

## 命名規範

| 物件 | 規範 | 例子 |
| :--- | :--- | :--- |
| 叢集 | `<用途>-<環境>` | `search-prod`、`logs-stg` |
| 節點 | 主機名 | `esc1` |
| 索引（業務資料） | `<領域>-<實體>-v<版本>`，應用程式透過 alias 存取 | `shop-orders-v3` ← alias `shop-orders` |
| data stream | 依 Elastic 的 `<type>-<dataset>-<namespace>` | `logs-nginx.access-prod` |
| 範本 | 和索引 pattern 對應，component template 依用途命名 | `shop-orders`、`base-settings`、`slowlog` |
| ILM 政策 | `<資料類型>-<保留>` | `logs-180d` |
| 角色 | `<資源>_<權限>` | `shop_orders_reader` |
| API key | `<服務>-<環境>` + `metadata.owner` | `order-api-prod` |

- 索引名稱一律小寫，不用 `_` 開頭（系統保留），不用 `.` 開頭（隱藏索引 / 系統索引）。
- **不要把日期以外的變動值放進索引名稱**（例如客戶 ID），會產生大量小索引。

## 開發規範

給應用程式團隊的規範，放在 code review checklist 裡：

1. **明確定義 mapping**，`dynamic: strict`；新增欄位走變更流程。
2. 字串欄位先想清楚是 `keyword`（過濾、聚合、排序）還是 `text`（全文檢索），或兩者（multi-field）。
3. 過濾條件放 `bool.filter`；不要在 `text` 欄位上聚合。
4. 不用 `from` + `size` 做深分頁，用 `search_after` + PIT。
5. 不要在查詢中用 script、前置萬用字元、`query_string` 接受使用者輸入（語法錯誤或惡意輸入會讓查詢失敗或很慢）。
6. 寫入用 bulk，處理 `429` 的退避重試；`refresh=wait_for` 只在真的需要「寫完立刻查得到」時使用，**不要用 `refresh=true`**。
7. 應用程式用 API key、最小權限；透過 alias 存取索引。
8. 用官方 client，設定多個節點位址與逾時。

## 運維文件化

| 文件 | 內容 |
| :--- | :--- |
| 架構圖 | 節點、角色、IP、機房 / zone、負載平衡、Kibana、資料來源 |
| 設定基準 | elasticsearch.yml、JVM、OS 參數，每個值為什麼這樣設（本系列實作篇的設定檔就是範本） |
| 索引清單 | 每個索引 / data stream 的用途、負責團隊、保留期限、ILM 政策 |
| Runbook | [故障排查篇]({% post_url 2026-10-24-elasticsearch-ops-09-troubleshooting %})的每一類故障 |
| 變更紀錄 | 每次變更的變更單、執行時間、結果 |
| 還原演練紀錄 | 每月一次，實際花費時間 |
| 升級紀錄 | 版本、日期、遇到的問題 |

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| ECK | 支援 8.x | 支援 9.x（先升級 ECK operator，再改 `spec.version`） |
| Terraform provider | 支援 | 支援；新的資源（例如 failure store 設定）需要新版 provider |
| 官方 client | 8.x client | **9.x client**（API 相容性：9.x client 可連 9.x 叢集，8.x 叢集要用 8.x client；跨版本時開 compatibility mode） |
| data stream 命名 | `<type>-<dataset>-<namespace>` | 相同；`logs-*-*` 預設 logsdb |
| 套件庫 | `packages/8.x/yum` | `packages/9.x/yum`（大版本是不同的 repo，升級時要換） |

### 給自動化的升級建議

- Ansible role 的套件庫網址、版本變數、`versionlock` 要一起改，並先在測試環境跑一次完整的部署與滾動升級。
- 應用程式的 client 要排在叢集升級**之後**再升到 9.x client；升級期間用相容模式。
- 自己寫的監控與維運腳本，在 9.x 測試叢集上跑過一次（`_cluster/reroute`、bulk 格式、錯誤 JSON 格式的改變）。

## 小結

- 快照用 SLM、保留期限用 ILM / DSL，不要自己寫 cron 刪資料。
- 部署用 Ansible（或 ECK），版本釘住；重啟一律走滾動重啟的 playbook。
- 叢集內部的設定（範本、ILM、角色）也是程式碼，放 Git、用 Terraform 或 CI 套用。
- 命名、mapping、查詢都要有規範，寫進 code review checklist。

這是 Elasticsearch 運維系列的最後一篇。實作的部分請看[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})、[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})、[滾動升級 8.19 → 9.5]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})、[Kibana 安裝與設定]({% post_url 2026-10-24-elasticsearch-lab-04-kibana %})。

### 參考資料

- [Elastic Cloud on Kubernetes](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s)
- [Terraform provider：elastic/elasticstack](https://registry.terraform.io/providers/elastic/elasticstack/latest)
- [Elasticsearch 文件：Install Elasticsearch with RPM](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-rpm)
- [Elastic Common Schema / data stream naming scheme](https://www.elastic.co/docs/reference/fleet/data-streams#data-streams-naming-scheme)
- [Elasticsearch clients](https://www.elastic.co/docs/reference/elasticsearch/clients)
