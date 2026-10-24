---
title: Elasticsearch 運維 01：安裝部署與環境配置
date: 2026-10-24 16:00:00 +0800
categories: [Elasticsearch, 安裝部署]
tags: [elasticsearch, elasticsearch9, elasticsearch8, installation, elasticsearch.yml, jvm, rocky-linux, rpm, cluster]
description: 以 Elasticsearch 9.5 為主，整理版本與支援週期、RPM 套件庫安裝與檔案配置、security auto-configuration、JVM heap、OS 調校、elasticsearch.yml 的關鍵參數與生效方式、節點角色與部署架構、升級路徑，並以實測的預設值比較 8.19 的差異。
---

這是 Elasticsearch 運維系列的第一篇。本系列以 **Elasticsearch 9.5**（撰寫時最新為 9.5.5）為主，每篇最後都會比較仍在支援中的 **8.19**（撰寫時最新為 8.19.23）。安裝部署的實際操作拆成三篇實作文：[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})、[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %}) 與 [滾動升級 8.19 → 9.5]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})，這篇負責把選型與共通觀念講清楚。

{% include elasticsearch-ops-series.md %}

## 版本與支援週期

Elasticsearch 的 minor 版本大約每 3 個月一個，**每個 minor 只維護到下下個 minor 推出為止**（大約半年），所以要追的是 minor，而不只是 patch。每個大版本的最後一個 minor（8.x 是 8.19）會延長維護，給還沒升級的環境緩衝。

| 版本 | 首次發布 | 撰寫時最新 | 狀態 | 備註 |
| :--- | :--- | :--- | :--- | :--- |
| 7.17 | 2022-02 | 7.17.29 | 已於 2026-01 停止支援 | 還在 7.x 的要先升 8.19 |
| **8.19** | 2025-07 | **8.19.23** | 支援到 2027-07 | 8.x 的最後一個 minor，本系列的比較對象 |
| 9.3 | 2026-02 | 9.3.8 | 已於 2026-08 停止支援 | |
| 9.4 | 2026-05 | 9.4.8 | 支援中 | |
| **9.5** | 2026-08 | **9.5.5** | 支援中 | 本系列的主角 |

> 支援日期依 Elastic 官方的產品生命週期表（撰寫時查詢）；「撰寫時最新」是 2026-10 從 Elastic 官方 RPM 套件庫實際安裝到的版本。
{: .prompt-info }

**為什麼以 9.5 為主？** 9.x 已經推出一年半，9.5 是目前最新、支援期最長的 minor；8.19 雖然支援到 2027 年，但只會有修補，新功能（logsdb 預設、欄式儲存、新的 merge 與 codec）都在 9.x。**還在 8.x 的環境要先升到 8.19**，才能滾動升級到 9.x。

## 安裝方式

| 方式 | 優點 | 缺點 |
| :--- | :--- | :--- |
| **Elastic 官方 RPM 套件庫** | systemd unit、目錄結構、使用者都準備好；`dnf` 升級 | 大版本是不同的套件庫（`8.x` / `9.x`） |
| tar.gz | 不需要 root、可以並存多個版本 | systemd、使用者、目錄都要自己處理 |
| Docker 映像 | 容器化部署 | 要另外處理 `vm.max_map_count`、資料 volume、記憶體限制 |
| ECK（Kubernetes Operator） | 憑證、滾動升級自動化 | 需要 Kubernetes |
| Elastic Cloud | 不用管主機 | 參數與外掛受限 |

本系列三篇實作都用 **RPM 套件庫**，安裝在 Rocky Linux 9.8 上：

```bash
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
sudo tee /etc/yum.repos.d/elasticsearch.repo <<'REPO'
[elasticsearch]
name=Elasticsearch repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=0
autorefresh=1
type=rpm-md
REPO
# enabled=0：平常的 dnf update 不會動到 Elasticsearch，安裝 / 升級時明確指定版本
sudo dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5
```

RPM 安裝後的檔案配置：

| 路徑 | 內容 |
| :--- | :--- |
| `/usr/share/elasticsearch` | 程式、內建 JDK（`jdk/`）、`bin/` 下的工具（`elasticsearch-certutil`、`elasticsearch-reset-password`、`elasticsearch-keystore` 等） |
| `/etc/elasticsearch` | `elasticsearch.yml`、`jvm.options`、`jvm.options.d/`、`log4j2.properties`、`elasticsearch.keystore`、`certs/` |
| `/var/lib/elasticsearch` | 資料（`path.data`） |
| `/var/log/elasticsearch` | 日誌（`path.logs`），檔名以 `cluster.name` 開頭 |
| `/usr/lib/systemd/system/elasticsearch.service` | systemd unit：`LimitNOFILE=65535`、`LimitNPROC=4096`、`TimeoutStartSec=900` |
| `/usr/lib/sysctl.d/elasticsearch.conf` | `vm.max_map_count=262144` |

- 套件內建 JDK（9.5.5 與 8.19.23 都是 **OpenJDK 27**），**不需要另外裝 Java**，也不建議換成系統的 JDK。
- 安裝時**不會**自動啟動，也不會 `enable`，要自己 `systemctl enable --now elasticsearch`。

### 安裝時的 security auto-configuration

8.0 起 RPM 安裝時會自動設定安全性：產生 CA 與 transport / HTTP 憑證（`/etc/elasticsearch/certs/`）、把憑證密碼與 elastic 密碼的雜湊存進 keystore，並在 `elasticsearch.yml` 末尾加上：

```yaml
xpack.security.enabled: true
xpack.security.enrollment.enabled: true
xpack.security.http.ssl:
  enabled: true
  keystore.path: certs/http.p12
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: certs/transport.p12
  truststore.path: certs/transport.p12
cluster.initial_master_nodes: ["<主機名>"]
http.host: 0.0.0.0
```

`elastic` 的密碼只在安裝輸出中顯示一次，忘記的話用 `elasticsearch-reset-password -u elastic` 重設。9.5 另外會在 keystore 自動產生 **叢集狀態加密** 的密碼（`cluster.state.encryption.password.autoconfigured`），從 8.19 升級上來的節點則要自己加（見[滾動升級實作]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})）。

多節點叢集不能讓每台各自 auto-configuration（每台會有不同的 CA），要用 enrollment token 或自建 CA，詳見[安全與權限管理]({% post_url 2026-10-24-elasticsearch-ops-07-security %})。

## JVM heap

```text
# /etc/elasticsearch/jvm.options.d/heap.options
# 預設不設定：依節點角色與實體記憶體自動計算
```

8.x / 9.x 會**依節點角色與實體記憶體自動計算 heap**，官方建議多數情況直接用自動值：

| 原則 | 說明 |
| :--- | :--- |
| 自動值 | master + data 節點約為實體記憶體的 **50%**，`-Xms` = `-Xmx`，上限約 31 GB |
| 手動設定 | 放在 `jvm.options.d/*.options`（不要改 `jvm.options`，升級時會被覆蓋成 `.rpmnew`），兩個值相同、不超過 RAM 的 50% |
| compressed oops | heap 超過約 31 GB 會失去 compressed oops，實際可用的物件空間反而變少 |
| 其餘記憶體 | 留給 OS page cache，Lucene 的 segment 靠它快取 |

實測在 7.7 GB 的 Docker VM 上，9.5.5 自動算出 `-Xms3967m -Xmx3967m`（約 50%），並且帶 `-XX:+AlwaysPreTouch`（啟動時就把 heap 實際配置下來）。

## OS 調校

```bash
# /etc/sysctl.d/99-elasticsearch.conf
vm.max_map_count = 262144     # Lucene 用 mmap，RPM 已內建，這裡集中寫一次
vm.swappiness = 1             # 盡量不 swap
net.ipv4.tcp_retries2 = 5     # 網路斷線時更快放棄重傳，節點離線更快被偵測（預設 15，約 15 分鐘）
```

| 項目 | 建議 |
| :--- | :--- |
| swap | **關閉**（`swapoff -a`、移除 `/etc/fstab` 的 swap），再加上 `bootstrap.memory_lock: true` 雙重保險 |
| `LimitMEMLOCK` | `memory_lock` 需要 systemd override 設 `LimitMEMLOCK=infinity`；多節點叢集沒設會 bootstrap check 失敗、拒絕啟動，單節點（`discovery.type: single-node`）只記一筆 WARN、heap 沒鎖住照樣啟動 |
| 檔案描述元 / 行程數 | RPM 的 unit 已設 65535 / 4096 |
| 磁碟 | 本機 SSD / NVMe，XFS 或 ext4、`noatime`；**不要把 `path.data` 放 NFS** |
| Transparent Huge Pages | Elasticsearch 沒有特別要求，維持 Rocky 9 預設即可（JVM 預設不使用 THP） |
| 防火牆 | 9200 開給用戶端與 Kibana，9300 只開給叢集節點（**未實測**，容器內沒有 firewalld） |

### Bootstrap checks

`network.host` 綁定非 loopback 位址時，Elasticsearch 進入**正式模式**，啟動時強制檢查 heap 大小一致、檔案描述元、`vm.max_map_count`、memory lock、discovery 設定等，任何一項不過就**拒絕啟動**。這是刻意的設計：寧可起不來，也不要帶著危險的設定上線。

例外是 `discovery.type: single-node`：單節點**不強制** bootstrap checks，檢查不過只在日誌留下 WARN。[單節點實作]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})實測 `memory_lock: true` 卻沒設 `LimitMEMLOCK`，服務照樣是 `active`，只多了一行 `memory locking requested for elasticsearch process but memory is not locked`，所以單節點要自己用 `GET _nodes?filter_path=**.mlockall` 確認。同一篇也實際踩了 `initial_master_nodes`、已移除設定、設定名稱打錯三種啟動失敗：**設定檔有錯，不論單節點或叢集都會拒絕啟動**。

## elasticsearch.yml：最重要的參數

完整的設定檔（每個參數都標明建議值或預設值，並和 9.5.5 全新安裝的預設值逐一核對過）在[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})與 [三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %}) 兩篇實作，這裡只列影響最大的：

| 參數 | 9.5 預設 | 建議（16 GB RAM、8 vCPU、SSD） | 說明 |
| :--- | :--- | :--- | :--- |
| `cluster.name` | `elasticsearch` | 依用途命名 | 同網段不要重複 |
| `node.roles` | 全部角色 | 小叢集 `[ master, data, ingest ]` | 不用 ML 就不要給 `ml` |
| `network.host` | `_local_` | 內網 IP | 綁了就進入正式模式 |
| `http.port` / `transport.port` | `9200-9300` / `9300-9399` | 固定 `9200` / `9300` | 避免誤啟動第二個行程時悄悄換 port |
| `discovery.seed_hosts` | 空 | 所有 master-eligible 節點 | 單節點改用 `discovery.type: single-node` |
| `cluster.initial_master_nodes` | 空 | 第一次 bootstrap 時列出，**之後移除** | 見[高可用篇]({% post_url 2026-10-24-elasticsearch-ops-03-ha-dr %}) |
| `bootstrap.memory_lock` | false | true | 搭配 `LimitMEMLOCK=infinity` |
| `path.repo` | 空 | 快照儲存庫路徑 | `fs` 儲存庫需要 |
| `indices.memory.index_buffer_size` | 10% | 10%（寫入很重時 15～20%） | 所有分片共用的寫入緩衝 |
| `indices.fielddata.cache.size` | 無上限 | 20% | 保險，正確做法是不要在 text 欄位開 fielddata |
| `indices.recovery.max_bytes_per_sec` | 40mb | 40mb，離峰時暫時調高 | 復原 / 搬移頻寬 |
| 磁碟水位 low / high / flood | 85% / 90% / 95% | 預設，告警設在 80% | flood stage 會讓索引唯讀 |
| `ingest.geoip.downloader.enabled` | true | 不連外的環境設 false | 否則持續記錄下載失敗 |

索引層級的參數（`refresh_interval`、translog、merge、慢日誌、`unassigned.node_left.delayed_timeout`）**不能寫在 `elasticsearch.yml`**，本系列用 component template 統一套用（實作篇的 `index-template.yaml`，以 YAML 格式送進 API，註解可以保留在版本控制裡）。

### 參數的生效方式

| 類型 | 生效方式 | 例子 |
| :--- | :--- | :--- |
| static（節點） | 改 `elasticsearch.yml` 後**滾動重啟** | `path.*`、`network.host`、`node.roles`、thread pool、cache 大小 |
| dynamic（叢集） | `PUT _cluster/settings`（persistent），也可以寫在 `elasticsearch.yml` 當預設 | 磁碟水位、allocation、recovery 頻寬、斷路器 |
| 索引 dynamic | `PUT <index>/_settings` | `number_of_replicas`、`refresh_interval`、慢日誌 |
| 索引 static | 只在建立時指定，或 `_close` 後修改 | `number_of_shards`、`codec`、analyzer |
| secure settings | `elasticsearch-keystore`；部分可 `POST _nodes/reload_secure_settings` | S3 金鑰、憑證密碼 |

```console
# 叢集層級的實際生效值（含預設值）
GET _cluster/settings?include_defaults=true&flat_settings=true
# 只看被 API 覆蓋的
GET _cluster/settings?flat_settings
```

**`persistent` 叢集設定會蓋過 `elasticsearch.yml`**。和 PostgreSQL 的 `postgresql.auto.conf` 一樣，常見的狀況是改了設定檔卻沒生效，因為 `_cluster/settings` 裡有同一個參數。另外，Elasticsearch **不認得的設定一律拒絕啟動**（包含打錯字與新版已移除的設定），這點比 MySQL、PostgreSQL 嚴格得多。

## 部署架構

| 架構 | 適用 | 實作 |
| :--- | :--- | :--- |
| 單節點 | 開發、測試、可以從來源重建的小型服務 | [單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %}) |
| 三節點（master + data + ingest） | 小型正式環境的基本盤：承受 1 台故障 | [三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %}) |
| 專用 master + data（+ coordinating） | data 節點 5～6 台以上 | 見[高可用與災難復原]({% post_url 2026-10-24-elasticsearch-ops-03-ha-dr %}) |
| hot / warm / cold / frozen 分層 | 大量日誌、長期保留 | 見[容量規劃與擴展]({% post_url 2026-10-24-elasticsearch-ops-06-capacity-scaling %}) |
| 託管（Elastic Cloud、ECK） | 不想管主機 / 已有 Kubernetes | 見[自動化與規範制定]({% post_url 2026-10-24-elasticsearch-ops-10-automation-standards %}) |

## 升級路徑

| 升級 | 做法 |
| :--- | :--- |
| patch（9.5.4 → 9.5.5） | 滾動升級，一台一台換套件、重啟 |
| minor（9.4 → 9.5） | 滾動升級 |
| major（8.x → 9.x） | **先升到 8.19**、清掉所有 critical deprecation、處理 7.x 建立的索引，再滾動升級 |
| 7.x → 9.x | 不能直接升：7.17 → 8.19 → 9.x |

- 9.5.5 回報的相容性：`minimum_wire_compatibility_version` **8.19.0**（混合版本的叢集只能有 8.19 與 9.x 節點）、`minimum_index_compatibility_version` **8.0.0**（7.x 建立的索引只能唯讀）。
- **不能降版**：新版本的節點改寫了資料目錄後，舊版本就讀不起來，回滾只能從升級前的快照還原。
- RPM 升級時 `elasticsearch.yml`、`jvm.options` 是設定檔（`%config(noreplace)`），**不會被覆蓋**，新版的範本會另存成 `.rpmnew`。

完整的實測過程（背景持續寫入、混合版本期間的分片分配限制、降版失敗的錯誤訊息）見[滾動升級實作]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})。

## 版本差異比較：9.5 vs 8.19

以下是在 Rocky Linux 9.8 上全新安裝 9.5.5 與 8.19.23、用 `include_defaults` 匯出所有預設值後比較的結果：

| 項目 | 8.19.23 | 9.5.5 |
| :--- | :--- | :--- |
| Lucene | 9.12.2 | **10.5.1** |
| 內建 JDK | OpenJDK 27 | OpenJDK 27 |
| 可以加入的節點版本（wire） | 7.17.0 以上 | **8.19.0** 以上 |
| 可以讀取的索引版本 | 7.0.0 以上 | **8.0.0** 以上（7.x 只能唯讀） |
| 節點層級設定數（含預設值） | 850 | 1058 |
| 索引層級設定數 | 184 | 224 |
| `thread_pool.search.queue_size` | 1000 | **16000** |
| merge policy（`floor_segment` / `segments_per_tier` / `max_merge_at_once`） | 2mb / 10 / 10 | **16mb / 8 / 16** |
| `index.mapping.nested_fields.limit` | 50 | 100 |
| `cluster.logsdb.enabled`（`logs-*-*` 預設 logsdb） | false | **true** |
| 叢集狀態加密（`cluster.state.encryption.required`） | 無 | true，keystore 多了自動產生的密碼 |
| 新的執行緒池 | — | `write_coordination`、`system_write_coordination` 等 |
| 移除的設定 | — | `cluster.routing.allocation.disk.watermark.enable_for_single_data_node`、`index.frozen`、`index.search.throttled`、`tracing.apm.*` 等 |
| `jvm.options` | — | 多了 `-Dorg.apache.lucene.store.defaultReadAdvice=normal` 與 Arrow 相關的 `--add-opens` |

完整的差異清單在實測環境的 `results/defaults-diff-*-8-9.txt`（節點 247 筆、索引 57 筆、執行緒池 9 筆）。

### 給新建置的建議

- 新建置直接上 **9.5**；還在 8.x 的環境先升 8.19，排好 9.x 的升級計畫。
- 一律用官方 RPM 套件庫並釘住版本（`enabled=0` + 明確版本號，或 `dnf versionlock`）。
- heap 用自動值、關 swap、`memory_lock: true`；設定檔以本系列實作篇的版本為起點。
- 從 8.19 帶過來的設定檔要檢查：明確寫死的舊預設值（例如 `thread_pool.search.queue_size: 1000`）升級後**不會**自動變成新的預設值。

## 小結

- 追的是 minor 版本（每個 minor 只維護約半年）；8.x 的環境先升到 8.19。
- RPM 安裝自帶 JDK、systemd unit 與 security auto-configuration；多節點叢集要統一 CA。
- heap 用自動值（約 RAM 的 50%），其餘留給 page cache；關 swap、鎖記憶體。
- Elasticsearch 不認得的設定一律拒絕啟動，`persistent` 叢集設定會蓋過設定檔。

下一篇是三篇實作：[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})、[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})、[滾動升級 8.19 → 9.5]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})。

### 參考資料

- [Elastic Product End of Life Dates](https://www.elastic.co/support/eol)
- [endoflife.date：Elasticsearch](https://endoflife.date/elasticsearch)
- [Elasticsearch 文件：Install Elasticsearch with RPM](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-rpm)
- [Elasticsearch 文件：Important system configuration](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/important-system-configuration)
- [Elasticsearch 文件：Bootstrap checks](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks)
- [Elasticsearch 文件：JVM settings](https://www.elastic.co/docs/reference/elasticsearch/jvm-settings)
- [Elasticsearch 文件：Cluster state encryption key](https://www.elastic.co/docs/reference/elasticsearch/cluster-state-encryption-key)
- [Elasticsearch release notes](https://www.elastic.co/docs/release-notes/elasticsearch)
