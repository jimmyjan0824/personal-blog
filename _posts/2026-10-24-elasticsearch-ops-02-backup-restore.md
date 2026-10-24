---
title: Elasticsearch 運維 02：備份與還原
date: 2026-10-24 16:10:00 +0800
categories: [Elasticsearch, 備份還原]
tags: [elasticsearch, elasticsearch9, elasticsearch8, backup, snapshot, restore, slm, s3, searchable-snapshot]
description: 以 Elasticsearch 9.5 為主，整理快照（snapshot）的原理與增量機制、快照儲存庫的種類與設定、SLM 自動排程與保留、還原的各種情境、跨叢集與跨版本還原的限制，以及還原演練，並比較 8.19 的差異。
---

副本（replica）擋得住節點故障，擋不住 `DELETE /orders` 或寫錯的 `_update_by_query`，因為誤刪會立刻套用到所有副本。Elasticsearch 唯一官方支援的備份方式是**快照（snapshot）**。本篇以 Elasticsearch 9.5 為主，最後比較 8.19 的差異。

{% include elasticsearch-ops-series.md %}

## 快照是什麼

| 項目 | 說明 |
| :--- | :--- |
| 單位 | 整個叢集或指定的索引 / data stream，加上叢集狀態（範本、ILM 政策、使用者等，可選） |
| 存放位置 | **快照儲存庫（repository）**：共用檔案系統、S3、GCS、Azure、HDFS 等 |
| 增量 | 以 Lucene **segment 檔**為單位去重：segment 已經在儲存庫裡就不再複製 |
| 一致性 | 每個 shard 在快照開始時的狀態；**不保證跨索引的時間點一致** |
| 對服務的影響 | 線上進行，不鎖寫入；會占用磁碟讀取與網路頻寬 |

> **不要用複製資料目錄（`path.data`）的方式備份**。Elasticsearch 官方明確不支援檔案層級備份：資料目錄複製出來的 segment 與 translog 不一定一致，還原時很可能讀不起來，或在不知情的情況下遺失資料。磁碟快照（LVM、EBS snapshot）也有一樣的問題，除非整個叢集同時停機。
{: .prompt-danger }

### 增量是怎麼做到的

Lucene 的 segment 寫入後**不會再修改**（只會被合併成新的 segment 後刪除），所以快照只要比對「這個 segment 是否已經在儲存庫裡」：

- 第一次快照：複製所有 segment。
- 之後的快照：只複製新產生的 segment。
- 刪除某一份快照時，只刪除**沒有被其他快照引用**的檔案。

因此「每小時一次快照、保留 7 天」的成本並不是 168 份全量，而是一份全量加上這段時間的新 segment。要注意的是 **force merge 會產生全新的大 segment**，下一份快照會變得很大；只對不再寫入的舊索引做 force merge。

## 快照儲存庫

| 類型 | 套件 | 適用 |
| :--- | :--- | :--- |
| `fs`（共用檔案系統） | 內建 | 地端，**所有 master 與 data 節點都要掛載同一個 NFS 路徑** |
| `s3` | 內建（8.0 起 repository-s3 已併入） | AWS S3 或相容 S3 的物件儲存（MinIO、Ceph RGW） |
| `gcs` / `azure` | 內建 | Google Cloud Storage、Azure Blob |
| `url` | 內建 | 唯讀，從 HTTP / file URL 還原 |
| `source` | 內建 | 只存 `_source`，約省一半空間，但還原後要 reindex 才能搜尋 |

### 共用檔案系統（fs）

```yaml
# elasticsearch.yml（每個 master 與 data 節點都要設，需重啟）
path.repo: ["/mnt/es-snapshots"]
```

```console
PUT _snapshot/nfs_repo
{
  "type": "fs",
  "settings": {
    "location": "/mnt/es-snapshots/prod",
    "compress": true,
    "max_snapshot_bytes_per_sec": "200mb",
    "max_restore_bytes_per_sec": "0"
  }
}

POST _snapshot/nfs_repo/_verify
```

- 掛載點的擁有者要是 `elasticsearch` 使用者（RPM 安裝時 uid 不固定，NFS 要用相同的 uid / gid 或設 `all_squash`）。
- `_verify` 會讓每個節點都試寫一個檔案，任何一台沒掛載或沒權限就會失敗，這個步驟一定要做。
- `max_snapshot_bytes_per_sec` 在 8.x / 9.x 預設是 `40mb`（每個節點），快照跑太久可以調高，但要留頻寬給線上流量。
- `compress` 只壓縮中繼資料（mapping、settings），segment 本身已經是壓縮過的格式。

[三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})用的就是 `fs` 儲存庫，所有節點掛載同一個 Docker volume。

### S3

```bash
# 金鑰放在 keystore，不要寫在 elasticsearch.yml；每個節點都要加，再 reload
sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add s3.client.default.access_key
sudo /usr/share/elasticsearch/bin/elasticsearch-keystore add s3.client.default.secret_key
```

```console
POST _nodes/reload_secure_settings

PUT _snapshot/s3_repo
{
  "type": "s3",
  "settings": {
    "bucket": "es-prod-snapshots",
    "base_path": "cluster-a",
    "storage_class": "standard_ia"
  }
}
```

- 在 AWS 上優先用 **EC2 instance profile / IRSA**，就不必在 keystore 放金鑰。
- MinIO 等相容服務要在 `elasticsearch.yml` 設 `s3.client.default.endpoint`，以及 `s3.client.default.path_style_access: true`。
- 物件儲存可以開 **版本控制 + Object Lock** 防止勒索軟體刪除快照，但要用 bucket 的 lifecycle 規則清理舊版本，否則容量只增不減。

> 一個儲存庫**只能有一個叢集有寫入權**。其他叢集（例如 DR 叢集）註冊同一個儲存庫時要設 `"readonly": true`，兩個叢集同時寫入會讓儲存庫的中繼資料毀損。
{: .prompt-warning }

## 手動快照

```console
# 快照名稱可以用日期運算式，URL 中要 encode（<prod-snap-{now/d}> → %3Cprod-snap-%7Bnow%2Fd%7D%3E）
PUT _snapshot/nfs_repo/%3Cprod-snap-%7Bnow%2Fd%7D%3E?wait_for_completion=false
{
  "indices": "orders-*,customers",
  "include_global_state": false,
  "feature_states": ["none"],
  "metadata": { "taken_by": "jimmy", "reason": "before mapping change" }
}

GET _snapshot/nfs_repo/_current
GET _snapshot/nfs_repo/*?verbose=false
GET _snapshot/nfs_repo/prod-snap-2026.10.24/_status
```

- `include_global_state`：是否包含叢集層級的設定、範本、ILM 政策。整個叢集的定期快照建議包含；針對單一索引的變更前快照不需要。
- `feature_states`：系統索引（安全性、Watcher、Kibana 等）的快照與還原要透過 feature state 處理，不能直接當成一般索引還原。
- `wait_for_completion=false`：大型快照會跑很久，用 `_status` 追進度即可。
- 同一時間每個儲存庫只能有有限的快照在進行（預設 `snapshot.max_concurrent_operations: 1000` 個操作），一般不會碰到。

## SLM：自動排程與保留

Snapshot Lifecycle Management（SLM）在 Basic 授權就可以用：

```console
PUT _slm/policy/nightly
{
  "schedule": "0 30 1 * * ?",
  "name": "<nightly-{now/d}>",
  "repository": "nfs_repo",
  "config": {
    "indices": "*",
    "include_global_state": true,
    "feature_states": ["security", "kibana"]
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 7,
    "max_count": 60
  }
}

POST _slm/policy/nightly/_execute
GET _slm/policy/nightly?human
GET _slm/stats
```

- `schedule` 是 cron 格式（秒 分 時 日 月 週），時區是 **UTC**。上例是 UTC 01:30（台北 09:30），要換算成離峰時段。
- `retention` 由另一個排程（`slm.retention_schedule`，預設 UTC 每天 01:30）執行，**`min_count` 保證就算快照都過期也至少留幾份**，避免叢集故障一段時間後把好的快照全刪光。
- 監控 `GET _slm/stats` 的 `snapshots_failed`，或對 `.slm-history-*` 索引設告警。
- 常見的組合：**每 30 分鐘一份、保留 2 天** + **每天一份、保留 30 天**，兩個 policy 寫進同一個儲存庫，增量機制讓空間成本很低。

## 還原

```console
# 1. 先看快照裡有什麼
GET _snapshot/nfs_repo/nightly-2026.10.24?verbose=true

# 2. 還原成新名稱，不影響線上的索引
POST _snapshot/nfs_repo/nightly-2026.10.24/_restore
{
  "indices": "orders-2026.10",
  "rename_pattern": "(.+)",
  "rename_replacement": "restored-$1",
  "include_aliases": false,
  "index_settings": { "index.number_of_replicas": 0 },
  "ignore_index_settings": ["index.refresh_interval"]
}

GET _cat/recovery/restored-*?v&active_only=true
```

| 情境 | 做法 |
| :--- | :--- |
| 誤刪一個索引 | 直接還原（同名索引已不存在） |
| 資料被改壞，但索引還在服務 | 還原成新名稱 → 比對 → 用 alias 切換或 `_reindex` 回去 |
| 索引存在且要覆蓋 | 先 `POST orders/_close` 或刪除，再還原（open 狀態的同名索引不能還原） |
| 整個叢集重建 | 新叢集註冊同一個儲存庫（可設 readonly），`include_global_state: true` + 需要的 `feature_states` |
| 搬到另一個叢集 | 目標叢集註冊同一個儲存庫（readonly），還原需要的索引 |

- 還原時把 `number_of_replicas` 設 0，主分片還原完成後再調回 1，總時間比較短。
- 還原速度受 `indices.recovery.max_bytes_per_sec`（預設 40mb，每個節點）與 `max_restore_bytes_per_sec` 限制，大量還原時可以暫時調高。
- **data stream** 還原時要還原整個 data stream（含 backing indices），不要只挑某幾個 `.ds-*` 索引。

### 跨版本還原的限制

| 快照建立的版本 | 可以還原到 |
| :--- | :--- |
| 8.x 建立的索引 | 8.x、9.x |
| 7.x 建立的索引 | 8.x；9.x 只能以**唯讀**方式還原（archive / read-only 相容），要能寫入必須在 8.x 先 reindex |
| 9.x 建立的索引 | 只能 9.x（**不能還原到舊版本**） |

> 規則的重點是「**索引是哪一版建立的**」，不是「快照是哪一版做的」。在 8.19 上做的快照，裡面若有 7.x 建立、從來沒 reindex 過的索引，還原到 9.x 時就會受限。升級前用 Upgrade Assistant（或 `GET _migration/deprecations`）找出這些索引。
{: .prompt-warning }

## Searchable Snapshots

Enterprise 授權的功能：索引直接掛在快照儲存庫上提供搜尋，搭配 ILM 的 cold / frozen tier，**本機只需要很小的快取**，適合「要保留很久、很少查」的日誌。它同時也是備份（資料本來就在儲存庫裡），但要注意：

- 儲存庫被刪除或損毀，對應的 searchable snapshot 索引就不能用了。
- 這類索引的儲存庫不能在快照還在使用時刪除快照（Elasticsearch 會阻擋）。

## 備份策略與還原演練

| 項目 | 建議 |
| :--- | :--- |
| 頻率 | 每 30 分鐘～1 小時一份（增量，成本低）+ 每天一份 |
| 保留 | 每小時的保留 2～3 天、每天的保留 30 天；`min_count` 至少 5 |
| 叢集狀態 | 每天的那份 `include_global_state: true`，含 `security` 等 feature state |
| 異地 | 儲存庫放在叢集以外的地方（物件儲存、另一機房的 NFS）；DR 叢集以 readonly 註冊 |
| 變更前 | 改 mapping、跑 `_update_by_query`、升級前手動做一份 |
| 還原演練 | **每月**還原到測試叢集，量測實際還原時間（RTO） |

演練時要驗證：

1. 文件化的還原步驟照做就能完成，包括儲存庫註冊與 keystore 金鑰。
2. 還原後 `GET _cat/indices?v` 文件數與預期相符，`_cluster/health` 為 green。
3. 應用程式的關鍵查詢可以執行，alias 與 index template 都在。
4. 實際花了多久，是否符合 RTO；還原速度主要卡在儲存庫的讀取頻寬與 `indices.recovery.max_bytes_per_sec`。

> 只有快照、沒有其他備份來源時，**快照儲存庫就是單點**。物件儲存開版本控制、NFS 另外做檔案層級的複製（儲存庫裡的檔案本身是可以安全複製的，因為它們寫入後不會再改），讓儲存庫本身也有第二份。
{: .prompt-tip }

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| 快照 API 與儲存庫類型 | `fs`、`s3`、`gcs`、`azure`、`url`、`source`，SLM | 相同，API 相容 |
| 還原 7.x 建立的索引 | 可以（完整讀寫） | 只能唯讀還原；要寫入請先在 8.x reindex |
| 9.x 建立的索引還原到 8.x | — | 不行，快照只能往新版本還原 |
| 儲存庫分析（`_analyze`） | 有 | 9.5 起額外驗證儲存庫是否正確阻擋覆寫特定的快照物件，第三方 S3 相容儲存不合規時會在分析時報錯 |
| Reindex from remote 遷移 | 自管叢集可用 | 自管叢集相同；另外有 Elastic Cloud 搬到 Serverless 的託管方案（9.5 GA） |

### 給備份策略的升級建議

- 從 8.19 升 9.5 前做一份完整快照（`include_global_state: true`），這份快照**只能還原回 8.19**，是升級失敗時唯一的退路：9.x 一旦啟動並改寫叢集狀態，就不能降版。
- 先清掉 7.x 建立的索引（reindex 或刪除），否則升級後它們只剩唯讀。
- 第三方 S3 相容儲存先在測試叢集跑一次 `POST _snapshot/<repo>/_analyze`，確認 9.5 的檢查會通過。

## 小結

- 快照是唯一官方支援的備份方式，以 segment 為單位增量，成本比想像中低。
- 儲存庫要讓所有 master 與 data 節點都能存取，只有一個叢集可以寫入。
- 用 SLM 排程與保留，`min_count` 防止故障期間把好的快照刪光。
- 跨版本還原看的是索引建立的版本：只能往新版本還原，最多相差一個大版本。
- 每月還原演練，驗證 RTO。

下一篇：[高可用與災難復原]({% post_url 2026-10-24-elasticsearch-ops-03-ha-dr %})。

### 參考資料

- [Elasticsearch 文件：Snapshot and restore](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore)
- [Elasticsearch 文件：Shared file system repository](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/shared-file-system-repository)
- [Elasticsearch 文件：S3 repository](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/s3-repository)
- [Elasticsearch 文件：Create a snapshot / SLM](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/create-snapshots)
- [Elasticsearch 文件：Snapshot compatibility](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore#snapshot-compatibility)
- [Elasticsearch release notes](https://www.elastic.co/docs/release-notes/elasticsearch)
