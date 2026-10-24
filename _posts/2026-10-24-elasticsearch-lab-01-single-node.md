---
title: Elasticsearch 安裝部署 01：單節點（Elasticsearch 9.5 / Rocky Linux 9）
date: 2026-10-24 16:01:00 +0800
categories: [Elasticsearch, 安裝部署]
tags: [elasticsearch, elasticsearch9, rocky-linux, installation, elasticsearch.yml, jvm, systemd, rpm, single-node, dba]
description: 在 Rocky Linux 9 上用 Elastic 官方 RPM 套件庫安裝 Elasticsearch 9.5.5，以 systemd 管理單節點，附上包含所有效能相關參數的 elasticsearch.yml 與索引範本（每個參數標明建議值或預設值，並和全新節點的預設值逐一核對），所有輸出皆為實測結果，並比較 8.19.23 的差異。
---

[安裝部署與環境配置]({% post_url 2026-10-24-elasticsearch-ops-01-installation-config %})一篇整理了版本選擇與共通觀念，這篇開始動手做。第一篇是最基本的**單節點**，適合開發、測試或資料可以重建的小型服務；下一篇的[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %}) 建立在這篇的安裝步驟與設定檔上。

{% include elasticsearch-ops-series.md %}

{% include elasticsearch-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `es1` | 192.168.60.11 | Elasticsearch 9.5 單節點（HTTP 9200、transport 9300），`master + data + ingest` |

規劃的主機規格：16 GB RAM、8 vCPU、本機 SSD，專門跑 Elasticsearch；用途是**業務資料的搜尋與聚合**（不是日誌平台）。

> 單節點**沒有副本**（副本不能和主分片放在同一個節點），主機或磁碟壞掉就只能從快照還原。資料不能重建、或不能接受停機時，直接看[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})。
{: .prompt-tip }

## 步驟 0：OS 參數

```bash
sudo tee /etc/sysctl.d/99-elasticsearch.conf <<'CONF'
# /etc/sysctl.d/99-elasticsearch.conf
# 建議（Rocky 9 預設 65530）。Lucene 用 mmap 讀 segment，官方要求至少 262144；
# RPM 已經放了 /usr/lib/sysctl.d/elasticsearch.conf，這裡再寫一次讓設定集中、一目了然
vm.max_map_count = 262144
# 建議（預設 60）。盡量不要 swap；正式環境最好直接 swapoff -a 並移除 /etc/fstab 的 swap
vm.swappiness = 1
# 建議（預設 15，約 15 分鐘）。網路斷線時約 6 秒內就放棄重傳，讓節點離線更快被偵測（官方建議 5）
net.ipv4.tcp_retries2 = 5
CONF
sudo sysctl -p /etc/sysctl.d/99-elasticsearch.conf
```

```console
[es1]# cp /root/conf/99-elasticsearch.conf /etc/sysctl.d/99-elasticsearch.conf && sysctl -p /etc/sysctl.d/99-elasticsearch.conf
vm.max_map_count = 262144
vm.swappiness = 1
net.ipv4.tcp_retries2 = 5

[es1]# swapon --show; free -m | grep -i swap; cat /sys/kernel/mm/transparent_hugepage/enabled
NAME          TYPE  SIZE USED PRIO
/var/lib/swap file 1024M   0B   -1
Swap:           1023           0        1023
[always] madvise never
```

| 參數 | 為什麼 |
| :--- | :--- |
| `vm.max_map_count = 262144` | Lucene 用 mmap 讀 segment，每個檔案都要一段 map；太小會在分片多的時候 `OutOfMemoryError: Map failed`。RPM 已經在 `/usr/lib/sysctl.d/elasticsearch.conf` 設好，這裡集中寫一次 |
| `vm.swappiness = 1` | heap 被 swap 出去時，GC 會慢到節點被判定離線。正式主機最好直接 `swapoff -a`（**未實測**，容器共用 Docker VM 的 swap） |
| `net.ipv4.tcp_retries2 = 5` | 預設 15 次重傳約 15 分鐘才放棄，改成 5 約 6 秒，網路斷線時節點更快被偵測（官方建議值） |

- 輸出中的 THP 是 `[always]`：容器共用 Docker VM 的核心，無法在容器內調整。Elasticsearch 官方沒有要求關閉 THP，但建議設成 `madvise`，避免背景的 khugepaged 造成延遲尖峰（**未實測**）。
- 防火牆（**未實測**，容器內沒有 firewalld）：9200 只開給應用程式與 Kibana 的網段，9300 只開給叢集內的節點：

```bash
sudo firewall-cmd --permanent --new-zone=es && sudo firewall-cmd --reload
sudo firewall-cmd --permanent --zone=es --add-source=10.0.10.0/24
sudo firewall-cmd --permanent --zone=es --add-port=9200/tcp
sudo firewall-cmd --reload
```

## 步驟 1：安裝（Elastic 官方 RPM 套件庫）

```bash
sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
sudo tee /etc/yum.repos.d/elasticsearch.repo <<'REPO'
# /etc/yum.repos.d/elasticsearch.repo（Elastic 官方 RPM 套件庫，9.x）
# enabled=0：平常 dnf update 不會動到 Elasticsearch，安裝 / 升級時才用 --enablerepo=elasticsearch 明確指定
[elasticsearch]
name=Elasticsearch repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=0
autorefresh=1
type=rpm-md
REPO
sudo dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5
```

套件庫設成 `enabled=0`：平常的 `dnf update` 不會把 Elasticsearch 升上去（升級一定要依[滾動升級]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})的程序一台一台來），安裝與升級時才用 `--enablerepo` 明確指定**完整版本號**。

```console
[es1]# rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch && rpm -q gpg-pubkey --qf "%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n" | grep -i elastic
gpg-pubkey-d88e42b4-64f6fad9	Elasticsearch (Elasticsearch Signing Key) <dev_ops@elasticsearch.org> public key

[es1]# cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && dnf repolist --all | grep -i elastic
elasticsearch              Elasticsearch repository for 9.x packages    disabled

[es1]# dnf --enablerepo=elasticsearch list --showduplicates elasticsearch 2>/dev/null | tail -4
elasticsearch.aarch64                   9.5.4-1                    elasticsearch
elasticsearch.x86_64                    9.5.4-1                    elasticsearch
elasticsearch.aarch64                   9.5.5-1                    elasticsearch
elasticsearch.x86_64                    9.5.5-1                    elasticsearch

[es1]# time dnf install -y --enablerepo=elasticsearch elasticsearch-9.5.5 2>&1 | grep -vE "B/s \||^\s*$"
...
Installing:
 elasticsearch        aarch64        9.5.5-1         elasticsearch        662 M
...
Creating elasticsearch group... OK
Creating elasticsearch user... OK
  Installing       : elasticsearch-9.5.5-1.aarch64                          1/1 
  Running scriptlet: elasticsearch-9.5.5-1.aarch64                          1/1 
Failed to restart systemd-sysctl.service: Unit systemd-sysctl.service not found.
--------------------------- Security autoconfiguration information ------------------------------
Authentication and authorization are enabled.
TLS for the transport and HTTP layers is enabled and configured.
The generated password for the elastic built-in superuser is : （省略）
If this node should join an existing cluster, you can reconfigure this with
'/usr/share/elasticsearch/bin/elasticsearch-reconfigure-node --enrollment-token <token-here>'
after creating an enrollment token on your existing cluster.
...
-------------------------------------------------------------------------------------------------
### NOT starting on installation, please execute the following statements to configure elasticsearch service to start automatically using systemd
 sudo systemctl daemon-reload
 sudo systemctl enable elasticsearch.service
...
Complete!

real	1m27.323s

[es1]# rpm -qi elasticsearch | grep -E "^(Name|Version|Release|Architecture|Size|Signature)"
Name        : elasticsearch
Version     : 9.5.5
Release     : 1
Architecture: aarch64
Size        : 1063659806
Signature   : RSA/SHA512, Thu Oct  1 02:37:39 2026, Key ID d27d666cd88e42b4
```

- 套件 662 MB、安裝後 1.0 GB，**內附 JDK**（`/usr/share/elasticsearch/jdk`，OpenJDK 27），不需要另外裝 Java，也不要改用系統的 JDK。
- `Failed to restart systemd-sysctl.service` 是容器沒有 `systemd-sysctl` 造成的，實體機不會出現；我們在步驟 0 已經自己套用過 sysctl。
- **Security auto-configuration**：安裝時自動產生 CA 與憑證、開啟 TLS 與帳號驗證，並印出 `elastic` 的隨機密碼。密碼之後會重設，不需要記下來。
- RPM **不會**自動啟動、也不會 `enable` 服務，這是刻意的：設定檔改好之前不要啟動（第一次啟動就會建立叢集 UUID）。

安裝後的檔案配置：

```console
[es1]# rpm -qc elasticsearch; rpm -ql elasticsearch | grep -E "^/usr/lib/(systemd|sysctl.d|tmpfiles.d)/"
/etc/elasticsearch/elasticsearch-plugins.example.yml
/etc/elasticsearch/elasticsearch.yml
/etc/elasticsearch/jvm.options
/etc/elasticsearch/log4j2.properties
/etc/elasticsearch/role_mapping.yml
/etc/elasticsearch/roles.yml
/etc/elasticsearch/users
/etc/elasticsearch/users_roles
/etc/sysconfig/elasticsearch
/usr/lib/sysctl.d/elasticsearch.conf
/usr/lib/systemd/system/elasticsearch.service
/usr/lib/tmpfiles.d/elasticsearch.conf

[es1]# ls -la /etc/elasticsearch /etc/elasticsearch/certs
/etc/elasticsearch:
drwxr-s--- 4 root elasticsearch  4096 Oct 24 13:38 .
drwxr-x--- 2 root elasticsearch  4096 Oct 24 13:38 certs
-rw-rw---- 1 root elasticsearch  1042 Sep 30 22:16 elasticsearch-plugins.example.yml
-rw-rw---- 1 root elasticsearch   675 Oct 24 13:38 elasticsearch.keystore
-rw-rw---- 1 root elasticsearch  4048 Oct 24 13:38 elasticsearch.yml
-rw-rw---- 1 root elasticsearch  3744 Sep 30 22:16 jvm.options
drwxr-s--- 2 root elasticsearch  4096 Sep 30 22:51 jvm.options.d
-rw-rw---- 1 root elasticsearch 22998 Sep 30 22:16 log4j2.properties
...
/etc/elasticsearch/certs:
-rw-rw---- 1 root elasticsearch 10045 Oct 24 13:38 http.p12
-rw-rw---- 1 root elasticsearch  1935 Oct 24 13:38 http_ca.crt
-rw-rw---- 1 root elasticsearch  5838 Oct 24 13:38 transport.p12
```

| 路徑 | 用途 |
| :--- | :--- |
| `/etc/elasticsearch/elasticsearch.yml` | 主設定檔 |
| `/etc/elasticsearch/jvm.options` | JVM 參數，**不要改**；自訂的放 `jvm.options.d/*.options`，升級時才不會被覆蓋 |
| `/etc/elasticsearch/elasticsearch.keystore` | 秘密設定（憑證密碼、S3 金鑰等），用 `elasticsearch-keystore` 管理 |
| `/etc/elasticsearch/certs/` | auto-config 產生的 HTTP / transport 憑證與 HTTP CA（`http_ca.crt`，用戶端要信任它） |
| `/var/lib/elasticsearch` | 資料（`path.data`） |
| `/var/log/elasticsearch` | 日誌（`path.logs`），檔名以 `cluster.name` 開頭 |
| `/usr/share/elasticsearch/bin/` | 管理工具：`elasticsearch-reset-password`、`elasticsearch-certutil`、`elasticsearch-keystore`、`elasticsearch-node` |

RPM 產生的 `elasticsearch.yml` 和 keystore：

```console
[es1]# grep -Ev "^\s*(#|$)" /etc/elasticsearch/elasticsearch.yml
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
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
cluster.initial_master_nodes: ["es1"]
http.host: 0.0.0.0

[es1]# /usr/share/elasticsearch/bin/elasticsearch-keystore list
autoconfiguration.password_hash
cluster.state.encryption.active_password_id
cluster.state.encryption.password.autoconfigured
keystore.seed
xpack.security.http.ssl.keystore.secure_password
xpack.security.transport.ssl.keystore.secure_password
xpack.security.transport.ssl.truststore.secure_password

[es1]# /usr/share/elasticsearch/jdk/bin/java -version 2>&1; /usr/share/elasticsearch/bin/elasticsearch --version 2>/dev/null
openjdk version "27" 2026-09-15
OpenJDK Runtime Environment (build 27+35-2325)
OpenJDK 64-Bit Server VM (build 27+35-2325, mixed mode, sharing)
Version: 9.5.5, Build: rpm/48acba663b09e70b115dd879329141506c377890/2026-09-30T22:12:03.984586187Z, JVM: 27
```

- auto-config 寫了 `cluster.initial_master_nodes: ["es1"]`（多節點的 bootstrap 方式）和 `http.host: 0.0.0.0`（HTTP 聽所有介面）。單節點要改成 `discovery.type: single-node`，而且**兩者不能同時存在**（實測踩坑 2）。
- keystore 裡的 `cluster.state.encryption.*` 是 **9.5 新增**的：叢集狀態中的秘密資訊會用這把金鑰加密，`elasticsearch.yml` 裡對應的是 `cluster.state.encryption.required: true`。8.19 沒有這兩項（見文末版本比較）。
- 憑證密碼放在 keystore，不在設定檔裡。下一步的設定檔沿用這些 auto-config 憑證；叢集篇則改用自建 CA。

## 步驟 2：設定檔

先備份 RPM 的原始檔，再換成下面這份：

```bash
sudo cp -p /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml.rpm
sudo install -o root -g elasticsearch -m 660 elasticsearch.yml /etc/elasticsearch/elasticsearch.yml
sudo install -o root -g elasticsearch -m 660 heap.options /etc/elasticsearch/jvm.options.d/heap.options
sudo install -d -o elasticsearch -g elasticsearch -m 750 /mnt/es-snapshots/single
```

### elasticsearch.yml

每個參數上一行的註解標明它是**建議**值（括號內是預設值）、**預設**值，還是依環境而定的**必要**值。標「預設」的參數，是在全新安裝的 9.5.5 上用 `GET _cluster/settings?include_defaults=true` 匯出預設值後逐一比對過的（方法見文末「驗證方式與結果」），寫出來是為了讓所有會影響效能的參數一目了然。

```yaml
# /etc/elasticsearch/elasticsearch.yml
# Elasticsearch 9.5 單節點：效能與運維設定
# 以「16 GB RAM、8 vCPU、本機 SSD、專用 Elasticsearch 主機」為基準。
# 每個參數上一行的註解：
#   建議：調整過的值（括號內是預設值）
#   預設：9.5.5 的預設值（在全新安裝的 9.5.5 上用 GET _cluster/settings?include_defaults 逐一核對過），
#         寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始
#   必要：名稱、路徑、位址、憑證等依環境而定、沒有好壞之分的值
# 「動態」表示也可以用 PUT _cluster/settings 線上調整（persistent 會蓋過這個檔案），其他的改了要滾動重啟。
# 索引層級的參數（refresh、translog、merge、慢日誌等）不能寫在這裡，放在索引範本 index-template-single.yaml。

#------------------------------------------------------------------------------
# 叢集與節點
#------------------------------------------------------------------------------
# 必要（預設 elasticsearch）。同一個網段的叢集名稱不要重複，日誌檔名也用它（/var/log/elasticsearch/es-single.log）
cluster.name: es-single
# 必要（預設 = 主機名）
node.name: es1
# 建議（預設是所有角色：master、data 與各 data tier、ingest、ml、transform、remote_cluster_client）。
# 不用機器學習就不要給 ml（它會另外啟動原生行程、吃記憶體），要跨叢集搜尋再加 remote_cluster_client
node.roles: [ master, data, ingest ]

#------------------------------------------------------------------------------
# 路徑
#------------------------------------------------------------------------------
# 必要（RPM 預設）。本機 SSD；不要放 NFS。多顆磁碟用 RAID 0 / LVM 合成一個路徑（多個 path.data 已棄用）
path.data: /var/lib/elasticsearch
# 必要（RPM 預設）
path.logs: /var/log/elasticsearch
# 建議（預設空）。fs 快照儲存庫的根目錄；正式環境要放在另一台主機（NFS）或改用 S3 儲存庫
path.repo: [ "/mnt/es-snapshots" ]

#------------------------------------------------------------------------------
# 記憶體
#------------------------------------------------------------------------------
# 建議（預設 false）。啟動時把 heap 鎖在記憶體裡，不會被 swap 出去；
# 需要 systemd 的 LimitMEMLOCK=infinity（override.conf）。discovery.type: single-node 不強制 bootstrap checks，
# 沒鎖住只會在日誌留下 WARN、照樣啟動（實測），所以要用 GET _nodes?filter_path=**.mlockall 確認是 true
bootstrap.memory_lock: true

#------------------------------------------------------------------------------
# 網路
#------------------------------------------------------------------------------
# 建議（預設 _local_ = 只聽 loopback）。綁內網 IP；綁了非 loopback 位址就進入「正式模式」；
# 但 discovery.type: single-node 例外，bootstrap checks 只記錄 WARN、不會拒絕啟動
network.host: 192.168.60.11
# 建議（預設 9200-9300 = 從 9200 起找第一個可用的 port）。固定下來，避免同一台誤啟動第二個行程時悄悄綁到 9201
http.port: 9200
# 建議（預設 9300-9399）。同上，防火牆規則也比較好寫
transport.port: 9300
# 預設。單一 HTTP 請求（含 bulk）的上限，超過回 413；bulk 每批 5～15 MB 就夠了，不要調大
http.max_content_length: 100mb
# 預設（啟用 HTTPS 時預設 false）。TLS 上做壓縮有 BREACH 類攻擊的風險，維持關閉
http.compression: false
# 預設。節點之間只壓縮寫入資料（bulk 轉送給副本、復原），其他訊息不壓縮
transport.compress: indexing_data
# 預設
transport.compression_scheme: lz4
# 預設。TCP keepalive，搭配 OS 的 net.ipv4.tcp_keepalive_* 偵測半斷線的連線
network.tcp.keep_alive: true
# 預設（-1 = 用 OS 設定，Rocky 9 是 7200 秒）。前面有會切斷閒置連線的防火牆 / LB 時，設得比它的逾時短
network.tcp.keep_idle: -1
# 預設
network.tcp.no_delay: true

#------------------------------------------------------------------------------
# 叢集組成（discovery）
#------------------------------------------------------------------------------
# 必要（預設 multi-node）。單節點：自己選自己當 master、不找其他節點，也不會被其他節點加入；
# 不能和 cluster.initial_master_nodes 同時設定（auto-config 會寫 initial_master_nodes，要拿掉）
discovery.type: single-node
# 預設。沒有 master 時拒絕寫入、仍允許讀取
cluster.no_master_block: write

#------------------------------------------------------------------------------
# 分片分配與復原（全部是動態）
#------------------------------------------------------------------------------
# 預設。all / primaries / new_primaries / none；滾動重啟時暫時改成 primaries
cluster.routing.allocation.enable: all
# 預設。always / indices_primaries_active / indices_all_active
cluster.routing.allocation.allow_rebalance: always
# 預設
cluster.routing.rebalance.enable: all
# 預設。整個叢集同時進行的分片搬移數
cluster.routing.allocation.cluster_concurrent_rebalance: 2
# 預設。每個節點同時進行的復原數（進、出各自計算）
cluster.routing.allocation.node_concurrent_recoveries: 2
# 預設。節點重啟後，每個節點同時從本機資料復原的主分片數
cluster.routing.allocation.node_initial_primaries_recoveries: 4
# 預設（每個節點）。SSD + 10GbE 的環境，離峰時可以用 PUT _cluster/settings 暫時調到 200mb 加快復原 / 搬移
indices.recovery.max_bytes_per_sec: 40mb
# 預設。每個復原同時傳送的檔案區塊數
indices.recovery.max_concurrent_file_chunks: 2
# 預設。每個復原同時重播的 translog 操作批次數
indices.recovery.max_concurrent_operations: 1
# 預設。每個非 frozen 的 data 節點最多 1000 個分片（含副本），超過就不能再建索引；碰到時應該減少分片，不要調高
cluster.max_shards_per_node: 1000

#------------------------------------------------------------------------------
# 磁碟水位（全部是動態）
#------------------------------------------------------------------------------
# 預設
cluster.routing.allocation.disk.threshold_enabled: true
# 預設。超過就不再把「副本」分配到這個節點；告警要設在這之前（例如 80%）
cluster.routing.allocation.disk.watermark.low: 85%
# 預設。大磁碟時改用「剩餘空間」判斷：剩餘 200GB 以下才算超過低水位
cluster.routing.allocation.disk.watermark.low.max_headroom: 200GB
# 預設。超過就開始把分片搬離這個節點
cluster.routing.allocation.disk.watermark.high: 90%
# 預設
cluster.routing.allocation.disk.watermark.high.max_headroom: 150GB
# 預設。超過就把這個節點上的索引全部設成唯讀（read_only_allow_delete），寫入全部失敗
cluster.routing.allocation.disk.watermark.flood_stage: 95%
# 預設
cluster.routing.allocation.disk.watermark.flood_stage.max_headroom: 100GB
# 預設。多久收集一次各節點的磁碟用量
cluster.info.update.interval: 30s

#------------------------------------------------------------------------------
# 寫入緩衝與背壓
#------------------------------------------------------------------------------
# 預設。所有分片共用的寫入緩衝區（heap 的比例），寫入非常重的節點可以調到 15%～20%，需重啟
indices.memory.index_buffer_size: 10%
# 預設
indices.memory.min_index_buffer_size: 48mb
# 預設（heap 的 10%）。正在處理中的寫入資料超過這個量就回 429，保護 heap，需重啟
indexing_pressure.memory.limit: 10%

#------------------------------------------------------------------------------
# 快取
#------------------------------------------------------------------------------
# 預設（heap 的 10%）。filter 子句的結果快取，需重啟
indices.queries.cache.size: 10%
# 預設（heap 的 1%）。size: 0 的查詢（聚合）結果快取，refresh 後失效，需重啟
indices.requests.cache.size: 1%
# 建議（預設 -1 = 無上限，只受 fielddata 斷路器 40% 限制）。設上限讓舊的 fielddata 被淘汰，而不是讓查詢一直被斷路器拒絕；
# 正確的做法是不要在 text 欄位上開 fielddata，這只是保險，需重啟
indices.fielddata.cache.size: 20%

#------------------------------------------------------------------------------
# 斷路器（動態）
#------------------------------------------------------------------------------
# 預設。依 JVM 實際的 heap 用量判斷（需重啟才能改）
indices.breaker.total.use_real_memory: true
# 預設（use_real_memory 為 true 時是 95%）。所有斷路器加總的上限
indices.breaker.total.limit: 95%
# 預設
indices.breaker.fielddata.limit: 40%
# 預設。單一請求（聚合等）可用的 heap
indices.breaker.request.limit: 60%
# 預設。傳輸中的請求（HTTP、transport）可用的 heap
network.breaker.inflight_requests.limit: 100%

#------------------------------------------------------------------------------
# 執行緒池（需重啟）
#------------------------------------------------------------------------------
# 執行緒數依 CPU 自動計算（write = CPU 數、search = CPU × 3 / 2 + 1），不要手動設 size。
# 預設是偵測到的 CPU 數；容器限制了 CPU 而 JVM 偵測錯誤時才要設
#node.processors: 8
# 預設。佇列滿了回 429（rejected）；調大佇列只會讓延遲變高，不會增加處理能力
thread_pool.write.queue_size: 10000
# 預設（9.x；8.19 是 1000）
thread_pool.search.queue_size: 16000

#------------------------------------------------------------------------------
# 搜尋保護（動態）
#------------------------------------------------------------------------------
# 預設。單一查詢的聚合 bucket 上限
search.max_buckets: 65536
# 預設（-1 = 不限制）。全域的查詢逾時；各查詢可以自己帶 timeout
search.default_search_timeout: -1
# 預設。改成 false 可以禁止 script 查詢、前置萬用字元、regexp 等昂貴的查詢（會影響 Kibana 部分功能）
search.allow_expensive_queries: true
# 預設。同時開著的 scroll context 上限；深分頁請改用 search_after + PIT
search.max_open_scroll_context: 500
# 預設。scroll / PIT 的 keep_alive 上限
search.max_keep_alive: 24h

#------------------------------------------------------------------------------
# 操作保護、script（動態）
#------------------------------------------------------------------------------
# 預設。刪除索引時必須寫出完整名稱，不能用 * 或 _all
action.destructive_requires_name: true
# 預設。寫入不存在的索引時自動建立（data stream 需要）；不想讓打錯字的索引名稱被建立，就搭配 dynamic: strict 的範本
action.auto_create_index: true
# 預設。script 編譯速率上限，超過代表 script 沒有用參數化（每次都不同的 script 原始碼）
script.max_compilations_rate: 150/5m
# 預設
script.cache.max_size: 3000

#------------------------------------------------------------------------------
# 內建功能
#------------------------------------------------------------------------------
# 建議（預設 true）。不會連外的環境關掉 GeoIP 資料庫自動下載，否則會持續記錄下載失敗；需要 GeoIP 時改回 true
ingest.geoip.downloader.enabled: false
# 預設是 false，不要寫出來：這個參數已棄用，寫在設定檔裡每次啟動都會在 deprecation log 留下警告（實測）。
# 監控改用 Elastic Agent / Metricbeat 送到另一個叢集
#xpack.monitoring.collection.enabled: false
# 預設（9.x）。叢集狀態中的秘密資訊（例如 ES|QL 外部資料來源的憑證）一律加密；
# 金鑰的保護密碼在 keystore（cluster.state.encryption.password.*），RPM 的 auto-config 會自動產生
cluster.state.encryption.required: true

#------------------------------------------------------------------------------
# 安全性（沿用 RPM auto-config 產生的憑證，憑證密碼在 keystore）
#------------------------------------------------------------------------------
# 必要
xpack.security.enabled: true
# 必要（auto-config 的值）。讓 Kibana 可以用 enrollment token 設定連線
xpack.security.enrollment.enabled: true
# 必要。HTTP 層的 TLS（auto-config 產生的 http.p12，CA 是 certs/http_ca.crt）
xpack.security.http.ssl.enabled: true
# 必要
xpack.security.http.ssl.keystore.path: certs/http.p12
# 必要。單節點的 transport 層也開 TLS（auto-config 的值）
xpack.security.transport.ssl.enabled: true
# 必要（auto-config 的值；預設 full）。auto-config 的 transport 憑證沒有主機名，只驗證憑證鏈
xpack.security.transport.ssl.verification_mode: certificate
# 必要
xpack.security.transport.ssl.keystore.path: certs/transport.p12
# 必要
xpack.security.transport.ssl.truststore.path: certs/transport.p12
```

最重要的幾個值：

| 參數 | 值 | 為什麼 |
| :--- | :--- | :--- |
| `discovery.type` | `single-node` | 單節點的正確寫法：不找其他節點、自己選自己當 master |
| `node.roles` | `[ master, data, ingest ]` | 預設是所有角色；不用機器學習就不要給 `ml`，它會另外啟動原生行程 |
| `bootstrap.memory_lock` | `true` | heap 鎖在記憶體裡不被 swap，要搭配步驟 3 的 `LimitMEMLOCK` |
| `network.host` | 內網 IP | 預設只聽 loopback；綁了 IP 才能讓其他主機連線 |
| `http.port` / `transport.port` | 固定 9200 / 9300 | 預設是範圍，同一台誤啟動第二個行程時會悄悄綁到 9201 |
| `indices.fielddata.cache.size` | `20%` | 預設無上限，只靠 40% 的斷路器擋，設上限讓舊資料被淘汰 |
| `ingest.geoip.downloader.enabled` | `false` | 不能連外的環境關掉，否則會一直記錄下載失敗 |
| `thread_pool.*`、斷路器、磁碟水位、快取 | 預設 | 寫出來是為了日後調整時知道從哪裡開始；**佇列調大不會增加處理能力** |

### heap.options

```text
# /etc/elasticsearch/jvm.options.d/heap.options
# 預設：不設定 -Xms / -Xmx，由 Elasticsearch 依節點角色與實體記憶體自動計算（官方建議多數情況使用自動值）。
#   master + data 節點、16 GB RAM → 約 8 GB（實體記憶體的 50%），-Xms = -Xmx，上限約 31 GB（compressed oops）。
#   其餘一半留給 OS page cache，Lucene 的 segment 靠它快取。
# 需要手動指定時（例如同一台主機還跑別的服務），取消下面兩行的註解，兩個值一定要相同、不超過實體記憶體的 50%：
# -Xms8g
# -Xmx8g
```

Elasticsearch 會依節點角色與實體記憶體**自動計算 heap**（master + data 節點約為實體記憶體的 50%，上限約 31 GB 以維持 compressed oops），官方建議多數情況用自動值，所以這個檔案裡沒有生效的設定，只是把規則寫下來。實測時另外放了一個只給實驗環境用的檔案：

```text
# /etc/elasticsearch/jvm.options.d/lab-heap.options
# 只用在實測環境：Docker Desktop 的 VM 約 7.7 GB 記憶體，好幾個容器共用，
# 自動計算會讓每個節點都拿到 VM 記憶體的一半，所以這裡固定為 1 GB。正式環境不要放這個檔案
-Xms1g
-Xmx1g
```

## 步驟 3：systemd override

`bootstrap.memory_lock: true` 需要允許行程鎖住記憶體。Rocky 9 的預設上限是 8 MB，RPM 的 unit 沒有設 `LimitMEMLOCK`，**要自己加 override**：

```bash
sudo mkdir -p /etc/systemd/system/elasticsearch.service.d
sudo tee /etc/systemd/system/elasticsearch.service.d/override.conf <<'CONF'
# /etc/systemd/system/elasticsearch.service.d/override.conf
# RPM 的 unit 已經設好 LimitNOFILE=65535、LimitNPROC=4096、LimitAS / LimitFSIZE=infinity、TimeoutStartSec=900
[Service]
# 建議（預設沒有設定，等於 OS 預設 8 MB）。bootstrap.memory_lock: true 需要；多節點叢集沒設會 bootstrap check 失敗、拒絕啟動，
# discovery.type: single-node 則只記錄 WARN、照樣啟動（heap 沒鎖住）
LimitMEMLOCK=infinity
CONF
sudo systemctl daemon-reload
```

### 實測踩坑 1：忘了 LimitMEMLOCK，單節點照樣啟動

先**不加** override 直接啟動，看看會發生什麼事：

```console
[es1]# systemctl start elasticsearch; systemctl is-active elasticsearch
active

[es1]# grep -E 'NativeAccess|BootstrapChecks' /var/log/elasticsearch/es-single.log | cut -c1-200
[2026-10-24T13:38:11,033][WARN ][o.e.n.NativeAccess       ] [es1] Unable to lock JVM Memory: error=12, reason=Cannot allocate memory
[2026-10-24T13:38:11,033][WARN ][o.e.n.NativeAccess       ] [es1] This can result in part of the JVM being swapped out.
[2026-10-24T13:38:11,033][WARN ][o.e.n.NativeAccess       ] [es1] Increase RLIMIT_MEMLOCK, soft limit: 8388608, hard limit: 8388608
[2026-10-24T13:38:11,033][WARN ][o.e.n.NativeAccess       ] [es1] These can be adjusted by modifying /etc/security/limits.conf, for example:
[2026-10-24T13:38:11,033][WARN ][o.e.n.NativeAccess       ] [es1] If you are logged in interactively, you will have to re-login for the new limits to take effect.
[2026-10-24T13:38:22,690][WARN ][o.e.b.BootstrapChecks    ] [es1] memory locking requested for elasticsearch process but memory is not locked; for more information see [https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks?version=9.5#bootstrap-checks-memory-lock]
```

服務是 `active`，只在日誌留下 WARN。原因是 **`discovery.type: single-node` 不強制執行 bootstrap checks**：多節點叢集（綁了非 loopback 位址又沒有 `single-node`）這個檢查不過會**拒絕啟動**，單節點則只記錄警告。也就是說，單節點忘了設 `LimitMEMLOCK` 時沒有任何東西會擋下來，heap 就這樣沒鎖住在跑，**一定要用 API 確認 `mlockall: true`**（步驟 5）。

提示中的 `/etc/security/limits.conf` 對 systemd 服務**沒有作用**（只影響 PAM 登入的 session），要用 override 的 `LimitMEMLOCK`。加了 override 之後：

```console
[es1]# systemctl cat elasticsearch | grep -Ev "^\s*(#|$)"
[Unit]
Description=Elasticsearch
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target
[Service]
Type=notify
NotifyAccess=all
RuntimeDirectory=elasticsearch
PrivateTmp=true
Environment=ES_HOME=/usr/share/elasticsearch
Environment=ES_PATH_CONF=/etc/elasticsearch
Environment=PID_DIR=/run/elasticsearch
Environment=ES_SD_NOTIFY=true
EnvironmentFile=-/etc/sysconfig/elasticsearch
WorkingDirectory=/usr/share/elasticsearch
User=elasticsearch
Group=elasticsearch
ExecStart=/usr/share/elasticsearch/bin/systemd-entrypoint -p ${PID_DIR}/elasticsearch.pid --quiet
StandardOutput=journal
StandardError=inherit
LimitNOFILE=65535
LimitNPROC=4096
LimitAS=infinity
LimitFSIZE=infinity
TimeoutStopSec=0
KillSignal=SIGTERM
KillMode=process
SendSIGKILL=no
SuccessExitStatus=143
TimeoutStartSec=900
[Install]
WantedBy=multi-user.target
[Service]
LimitMEMLOCK=infinity
```

RPM 的 unit 已經處理好檔案描述元（65535）、行程數（4096）、`Type=notify`（啟動完成才回報 active）與 `TimeoutStartSec=900`（大量分片的節點啟動很慢），**不要整份複製 unit 檔來改**，只用 override 補上缺的。

### 實測踩坑 2～4：設定錯誤一律拒絕啟動

和 bootstrap checks 不同，**設定檔本身有錯，不論單節點或叢集都會拒絕啟動**。在正確的設定檔後面各加一行錯誤設定，三種都失敗：

```console
[es1]# echo 'cluster.initial_master_nodes: ["es1"]' >> /etc/elasticsearch/elasticsearch.yml
[es1]# systemctl start elasticsearch; systemctl is-active elasticsearch
Job for elasticsearch.service failed because the control process exited with error code.
See "systemctl status elasticsearch.service" and "journalctl -xeu elasticsearch.service" for details.
failed
[es1]# journalctl -u elasticsearch --no-pager -n 40 | grep ERROR | tail -1
Oct 24 13:39:11 es1 systemd-entrypoint[694]: ERROR: Elasticsearch did not exit normally - check the logs at /var/log/elasticsearch/es-single.log
[es1]# grep -A1 'fatal exception' /var/log/elasticsearch/es-single.log | grep Exception | tail -1
java.lang.IllegalArgumentException: setting [cluster.initial_master_nodes] is not allowed when [discovery.type] is set to [single-node]
```

| 踩坑 | 加上的設定 | 錯誤訊息 |
| :--- | :--- | :--- |
| 2：沿用 auto-config 的 `initial_master_nodes` | `cluster.initial_master_nodes: ["es1"]` | `setting [cluster.initial_master_nodes] is not allowed when [discovery.type] is set to [single-node]` |
| 3：9.x 已移除的設定 | `cluster.routing.allocation.disk.watermark.enable_for_single_data_node: true` | `unknown setting [cluster.routing.allocation.disk.watermark.enable_for_single_data_node] did you mean any of [cluster.routing.allocation.disk.watermark.flood_stage.frozen, cluster.routing.allocation.disk.watermark.flood_stage]?` |
| 4：設定名稱打錯 | `indices.memory.index_buffer_sizes: 10%` | `unknown setting [indices.memory.index_buffer_sizes] did you mean any of [indices.memory.index_buffer_size, indices.memory.max_index_buffer_size, indices.memory.min_index_buffer_size]?` |

- `journalctl` 只會顯示 `Elasticsearch did not exit normally`，**真正的原因在 `/var/log/elasticsearch/<cluster.name>.log`** 的 `fatal exception while booting Elasticsearch` 下一行。
- 踩坑 3 的 `enable_for_single_data_node` 在 8.x 是單節點常見的設定（7.x 時代為了讓單節點也套用高水位），9.0 已移除；從 8.x 搬設定檔過來時要拿掉。

## 步驟 4：啟動

```console
[es1]# time systemctl enable --now elasticsearch; systemctl status elasticsearch --no-pager | head -12
Created symlink /etc/systemd/system/multi-user.target.wants/elasticsearch.service → /usr/lib/systemd/system/elasticsearch.service.

real	0m7.549s
● elasticsearch.service - Elasticsearch
     Loaded: loaded (/usr/lib/systemd/system/elasticsearch.service; enabled; preset: disabled)
    Drop-In: /etc/systemd/system/elasticsearch.service.d
             └─override.conf
     Active: active (running) since Sat 2026-10-24 13:39:28 UTC; 4ms ago
       Docs: https://www.elastic.co
   Main PID: 1101 (server-launcher)
      Tasks: 68 (limit: 51007)
     Memory: 1.5G (peak: 1.5G)
        CPU: 19.385s

[es1]# grep -E 'heap size|publish_address|started|license' /var/log/elasticsearch/es-single.log | tail -5 | cut -c1-200
[2026-10-24T13:39:25,061][INFO ][o.e.e.NodeEnvironment    ] [es1] heap size [1gb], compressed ordinary object pointers [true]
[2026-10-24T13:39:28,638][INFO ][o.e.t.TransportService   ] [es1] publish_address {192.168.60.11:9300}, bound_addresses {192.168.60.11:9300}
[2026-10-24T13:39:28,869][INFO ][o.e.h.AbstractHttpServerTransport] [es1] publish_address {192.168.60.11:9200}, bound_addresses {192.168.60.11:9200}
[2026-10-24T13:39:28,870][INFO ][o.e.n.Node               ] [es1] started {es1}{kJIxUfY_TDCLLhP-qJWblg}{DnKqwHqXToqnNhTQyectoA}{es1}{192.168.60.11}{192.168.60.11:9300}{dim}{9.5.5}{8000099-9111000}{...}
[2026-10-24T13:39:28,872][INFO ][o.e.x.w.AbstractLicenseCheckingWriteLoadForecaster] [es1] license state changed, now [valid]

[es1]# cat /proc/$(pgrep -f org.elasticsearch.bootstrap.Elasticsearch | head -1)/limits | grep -E "open files|processes|locked memory|address space"
Max processes             4096                 4096                 processes 
Max open files            65535                65535                files     
Max locked memory         unlimited            unlimited            bytes     
Max address space         unlimited            unlimited            bytes     

[es1]# ls -l /var/log/elasticsearch/
-rw-r--r-- 1 elasticsearch elasticsearch 221640 Oct 24 13:39 es-single.log
-rw-r--r-- 1 elasticsearch elasticsearch      0 Oct 24 13:38 es-single_audit.json
-rw-r--r-- 1 elasticsearch elasticsearch   5204 Oct 24 13:39 es-single_deprecation.json
-rw-r--r-- 1 elasticsearch elasticsearch      0 Oct 24 13:38 es-single_esql_querylog.json
-rw-r--r-- 1 elasticsearch elasticsearch      0 Oct 24 13:38 es-single_index_indexing_slowlog.json
-rw-r--r-- 1 elasticsearch elasticsearch      0 Oct 24 13:38 es-single_index_search_slowlog.json
-rw-r--r-- 1 elasticsearch elasticsearch      0 Oct 24 13:38 es-single_querylog.json
-rw-r--r-- 1 elasticsearch elasticsearch 561519 Oct 24 13:39 es-single_server.json
-rw-r--r-- 1 elasticsearch elasticsearch  54345 Oct 24 13:39 gc.log
...
```

- `systemctl enable --now` 約 7.5 秒回來，`Type=notify` 會等到節點真的啟動完成才回報 `active`。
- `Max locked memory unlimited`：override 生效。
- 日誌檔以 `cluster.name` 命名：`es-single.log`（純文字）與 `es-single_server.json`（同內容的 JSON，給 Filebeat / Elastic Agent 收）、`_deprecation.json`（**升級前一定要看**）、兩個慢日誌、`gc.log`。

## 步驟 5：帳號與驗證

### elastic 密碼與應用程式帳號

```console
[es1]# /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s
（輸出的隨機密碼省略，長度 20）

[es1] POST /_security/user/elastic/_password
{"password":"ChangeMe_Elastic_2026"}
{}

[es1] PUT /_security/role/orders_rw
{"cluster":["monitor"],"indices":[{"names":["orders*"],"privileges":["read","create_doc","index","view_index_metadata"]}]}
{"role":{"created":true}}

[es1] PUT /_security/user/app
{"password":"ChangeMe_App_2026","roles":["orders_rw"],"full_name":"Order application"}
{"created":true}
```

- `elastic` 是超級使用者，只給 DBA 緊急使用；應用程式一律用**最小權限**的角色與帳號（或 API key，見[安全與權限管理]({% post_url 2026-10-24-elasticsearch-ops-07-security %})）。
- `-b -s`：不詢問、只輸出密碼，方便寫進自動化流程（密碼要直接存進密碼管理工具，不要留在 shell history）。

權限與 TLS 的檢查：

```console
[es1]# curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:ChangeMe_App_2026 -X POST "https://es1:9200/orders/_doc?refresh=wait_for" -H "Content-Type: application/json" -d '{"order_id":"ORD-TEST-1","status":"paid","amount":100,"created_at":"2026-10-24T08:00:00Z"}'
{"_index":"orders","_id":"cU4jbqEB2bGJOJ4sYe6h","_version":1,"result":"created","_shards":{"total":1,"successful":1,"failed":0},"_seq_no":0,"_primary_term":1}

[es1]# curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:ChangeMe_App_2026 -X DELETE "https://es1:9200/orders" | jq -c ".error | {type, reason}"
{"type":"security_exception","reason":"action [indices:admin/delete] is unauthorized for user [app] with effective roles [orders_rw] on indices [orders], this action is granted by the index privileges [delete_index,manage,all]"}

[es1]# curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u app:wrong "https://es1:9200/" | jq -c ".error | {type, reason}"
{"type":"security_exception","reason":"unable to authenticate user [app] for REST request [/]"}

[es1]# curl -sS -o /dev/null -w "http://es1:9200/ → %{http_code}\n" http://es1:9200/; curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -o /dev/null -w "https://es1:9200/（不帶帳號）→ %{http_code}\n" https://es1:9200/
curl: (52) Empty reply from server
http://es1:9200/ → 000
https://es1:9200/（不帶帳號）→ 401
```

用 `http://` 連 HTTPS 的 port 只會得到 `Empty reply from server`，不是 HTTP 錯誤碼；應用程式連不上時先確認是不是協定寫錯。

### 版本、節點、記憶體

```console
[es1] GET /
{
  "name" : "es1",
  "cluster_name" : "es-single",
  "cluster_uuid" : "VnTmTuzpRC2If37EW7g_TQ",
  "version" : {
    "number" : "9.5.5",
    "build_flavor" : "default",
    "build_type" : "rpm",
    "build_hash" : "48acba663b09e70b115dd879329141506c377890",
    "build_date" : "2026-09-30T22:12:03.984586187Z",
    "build_snapshot" : false,
    "lucene_version" : "10.5.1",
    "minimum_wire_compatibility_version" : "8.19.0",
    "minimum_index_compatibility_version" : "8.0.0"
  },
  "tagline" : "You Know, for Search"
}

[es1] GET /_cat/nodes?v&h=name,ip,version,node.role,master,heap.max,ram.max,cpu,disk.total
name ip            version node.role master heap.max ram.max cpu disk.total
es1  192.168.60.11 9.5.5   dim       *           1gb   7.7gb  16    452.1gb

[es1] GET /_cluster/health?pretty
{
  "cluster_name" : "es-single",
  "status" : "green",
  "number_of_nodes" : 1,
  "number_of_data_nodes" : 1,
  "active_primary_shards" : 1,
  "active_shards" : 1,
  "unassigned_shards" : 0,
  ...
}

[es1] GET /_nodes/_local/process?filter_path=nodes.*.process.mlockall&pretty
{
  "nodes" : {
    "kJIxUfY_TDCLLhP-qJWblg" : {
      "process" : {
        "mlockall" : true
      }
    }
  }
}
```

- `minimum_wire_compatibility_version: 8.19.0`：9.5 的叢集只接受 8.19 以上的節點加入，**滾動升級一定要先到 8.19**。`minimum_index_compatibility_version: 8.0.0`：7.x 建立的索引要先 reindex 才能升到 9.x。
- `node.role` 的 `dim` = data、ingest、master；`*` 表示它是 master。
- **`mlockall: true`** 才代表 heap 真的鎖住了，踩坑 1 的狀態下這裡會是 `false`。

```console
[es1] GET /_nodes/_local/jvm?filter_path=nodes.*.jvm.version,nodes.*.jvm.mem,nodes.*.jvm.gc_collectors,nodes.*.jvm.using_compressed_ordinary_object_pointers&pretty
{
  "nodes" : {
    "kJIxUfY_TDCLLhP-qJWblg" : {
      "jvm" : {
        "version" : "27",
        "mem" : {
          "heap_init_in_bytes" : 1073741824,
          "heap_max_in_bytes" : 1073741824,
          "non_heap_init_in_bytes" : 7667712,
          "non_heap_max_in_bytes" : 0,
          "direct_max_in_bytes" : 536870912
        },
        "gc_collectors" : [
          "G1 Young Generation",
          "G1 Concurrent GC",
          "G1 Old Generation"
        ],
        "using_compressed_ordinary_object_pointers" : "true"
      }
    }
  }
}
```

JVM 啟動參數裡和效能有關的（節錄自 `input_arguments`）：

```text
-XX:+AlwaysPreTouch                 # 啟動時就把整個 heap 實際配置下來，執行中不會再跟 OS 要記憶體
-XX:+UseG1GC                        # G1 GC
-Xms1g -Xmx1g                       # 來自 lab-heap.options（正式環境由自動計算決定）
-XX:MaxDirectMemorySize=536870912   # 自動設為 heap 的一半（Netty、Lucene 的 direct buffer）
-XX:G1HeapRegionSize=4m -XX:G1IHOP=30 -XX:G1ReservePercent=15
-XX:+HeapDumpOnOutOfMemoryError -XX:+ExitOnOutOfMemoryError
-Xlog:gc*,gc+age=trace,safepoint:file=gc.log:utctime,level,pid,tags:filecount=32,filesize=64m
```

`AlwaysPreTouch` 是步驟 4 的 `systemctl status` 顯示 `Memory: 1.5G` 的原因：heap 1 GB 一啟動就全部碰過，再加上 direct memory 與其他 JVM 開銷。**主機的記憶體規劃要以 heap 的約 1.5 倍估算行程本身**，剩下的才是 page cache。

### 執行緒池

```console
[es1] GET /_cat/thread_pool?v&h=name,type,size,queue_size&s=name
name                                   type    size queue_size
analyze                                fixed      1         16
...
force_merge                            fixed      1         -1
get                                    fixed     16       1000
...
search                                 fixed     16      16000
search_coordination                    fixed      5       1000
...
write                                  fixed     10      10000
write_coordination                     fixed     10      10000
```

執行緒數依 CPU 自動計算：`write` = CPU 數（10）、`search` = `CPU × 3 / 2 + 1`（16）。容器看得到 Docker VM 的 10 顆 CPU，正式主機 8 vCPU 時會是 8 與 13。`write_coordination` 是 9.x 新增的（協調節點轉送 bulk 用），`search_throttled` 隨 frozen 索引一起移除了。

### 設定檔與實際值比對

`bin/checkconf.py` 讀設定檔，依每個參數上一行註解的標記和節點的實際值、全新節點的預設值比對：標「預設」的，實際值必須等於預設值；標「建議」的，實際值必須和預設值不同。

```console
[es1]# python3 /root/bin/checkconf.py /etc/elasticsearch/elasticsearch.yml /root/results/defaults-node-9.5.5.txt /root/results/actual-node-es1.json
--- 設定檔參數數量與標記
建議	8
必要	13
預設	48
--- 需要確認的項目（CHECK / UNKNOWN；UNKNOWN 代表預設值清單裡沒有這個參數，例如沒有預設值的路徑、清單型設定）
line	tag	setting	file	default	actual	result
--- 標「建議」的參數：設定值與預設值
node.roles	[ master, data, ingest ]	(預設 ["data","data_cold","data_content","data_frozen","data_hot","data_warm","ingest","master","ml","remote_cluster_client","transform"])
path.repo	[ "/mnt/es-snapshots" ]	(預設 [])
bootstrap.memory_lock	true	(預設 false)
network.host	192.168.60.11	(預設 [])
http.port	9200	(預設 9200-9300)
transport.port	9300	(預設 9300-9399)
indices.fielddata.cache.size	20%	(預設 -1b)
ingest.geoip.downloader.enabled	false	(預設 true)
--- 共 69 個參數，ok 69 個
```

69 個參數全部符合標記，沒有 CHECK。實測時設定檔裡還有一行 `xpack.monitoring.collection.enabled: false`（預設值），因為它在 deprecation log 留下警告（見「實測踩到的坑」），文中的設定檔已改成註解，所以現在是 68 個。

## 步驟 6：索引範本

`elasticsearch.yml` **不能放索引層級的設定**（refresh、translog、merge、慢日誌等），寫進去會啟動失敗。這些用 **component template** 統一套到所有業務索引，範本用 YAML 送出（`Content-Type: application/yaml`），註解會被忽略，所以檔案本身就是文件：

```yaml
# PUT _component_template/base-settings（Content-Type: application/yaml，註解會被忽略）
# 索引層級的效能與運維設定：elasticsearch.yml 不能放索引設定，統一用 component template 套到所有業務索引。
# 以「單節點、業務資料（非日誌）、搜尋與寫入並重」為基準。
# 標記規則和 elasticsearch.yml 相同：建議 = 調整過的值（括號內是預設值）；預設 = 9.5.5 的預設值
# （在全新的 9.5.5 上用 GET <index>/_settings?include_defaults 逐一核對過）。
# 「動態」表示建立後也可以 PUT <index>/_settings 修改；其他的只在建立索引時生效。
version: 1
_meta:
  description: "base index settings for business indices (es-single)"
template:
  settings:
    #--------------------------------------------------------------------------
    # 分片與副本
    #--------------------------------------------------------------------------
    # 預設。主分片數建立後不能改（只能 split / shrink / reindex）；每個分片 10～50 GB，預估會超過再在建立時指定
    index.number_of_shards: 1
    # 建議（預設 1），動態。單節點放不了副本（副本不能和主分片在同一個節點），設 1 會讓叢集永遠是 yellow
    index.number_of_replicas: 0
    # 預設，動態。不要自動依節點數調整副本（auto_expand_replicas 會忽略部分分配規則）
    index.auto_expand_replicas: false
    # 預設，動態（-1 = 不限制）。熱點索引的分片擠在同一台時，設成「主分片數 × (1 + 副本數) ÷ 節點數」再加 1
    index.routing.allocation.total_shards_per_node: -1
    # 預設，動態。寫入前只要求主分片 active；設 all 會在副本不在時拒絕寫入（可用性下降）
    index.write.wait_for_active_shards: 1
    # 預設，動態。分片分配失敗的重試次數，用完要 POST _cluster/reroute?retry_failed=true
    index.allocation.max_retries: 5

    #--------------------------------------------------------------------------
    # refresh 與 translog
    #--------------------------------------------------------------------------
    # 預設是不設定（= 1s，而且索引閒置 index.search.idle.after 後暫停 refresh，下一次搜尋時才 refresh）。
    # 明確寫 1s 會關掉 search idle 的行為；日誌類資料建議 30s；大量匯入時暫時設 -1
    #index.refresh_interval: 1s
    # 預設，動態。沒設 refresh_interval 的索引，30 秒沒有搜尋就暫停定期 refresh
    index.search.idle.after: 30s
    # 預設，動態。每個寫入請求回應前都把 translog fsync 到磁碟；async 會在當機時遺失最多 sync_interval 的資料
    index.translog.durability: request
    # 預設，動態。durability 為 async 時的 fsync 間隔（也是 request 模式下背景 fsync 的間隔）
    index.translog.sync_interval: 5s
    # 預設，動態。translog 累積到這個大小就 flush（Lucene commit）
    index.translog.flush_threshold_size: 10gb
    # 預設，動態。距離上次 flush 超過這個時間也會 flush
    index.translog.flush_threshold_age: 1m

    #--------------------------------------------------------------------------
    # merge 與儲存（9.x 調整過 merge policy 的預設值，8.19 的值見文章）
    #--------------------------------------------------------------------------
    # 預設。default = LZ4；日誌、歸檔類索引建議 best_compression（DEFLATE，省 15%～25% 空間、寫入稍慢），建立時才能設
    index.codec: default
    # 預設，動態。小於這個大小的 segment 一律視為這個大小來挑選合併對象（8.19 是 2mb）
    index.merge.policy.floor_segment: 16mb
    # 預設，動態。每一層允許的 segment 數（8.19 是 10.0）
    index.merge.policy.segments_per_tier: 8.0
    # 預設，動態。一次合併最多幾個 segment（8.19 是 10）
    index.merge.policy.max_merge_at_once: 16
    # 預設，動態。已刪除文件超過 segment 的 20% 時優先合併
    index.merge.policy.deletes_pct_allowed: 20.0
    # 預設，動態。merge 太多時自動降低寫入的 merge 速度，避免 I/O 被 merge 吃光
    index.merge.scheduler.auto_throttle: true
    # 預設。啟動時不檢查分片檔案（checksum 會讓大分片啟動很慢；懷疑損毀時才暫時設 checksum）
    index.shard.check_on_startup: false

    #--------------------------------------------------------------------------
    # mapping 保護（動態）
    #--------------------------------------------------------------------------
    # 預設。欄位總數上限（含 multi-field、object）；超過代表 mapping 設計有問題（mapping explosion），不要隨便調高
    index.mapping.total_fields.limit: 1000
    # 預設。物件巢狀深度上限
    index.mapping.depth.limit: 20
    # 預設（9.x；8.19 是 50）。nested 欄位數上限
    index.mapping.nested_fields.limit: 100
    # 預設。單一文件中 nested 物件總數上限
    index.mapping.nested_objects.limit: 10000
    # 預設。不自動轉型（"5" 不會被當成數字 5 寫進 integer 欄位）
    index.mapping.coerce: false
    # 預設。格式錯誤的值讓整份文件寫入失敗，而不是悄悄忽略
    index.mapping.ignore_malformed: false

    #--------------------------------------------------------------------------
    # 查詢保護與快取（動態）
    #--------------------------------------------------------------------------
    # 預設。from + size 的上限；深分頁用 search_after + PIT，不要調高
    index.max_result_window: 10000
    # 預設。inner_hits、top_hits 的 from + size 上限
    index.max_inner_result_window: 100
    # 預設。terms 查詢的詞數上限
    index.max_terms_count: 65536
    # 預設。regexp 查詢的長度上限
    index.max_regex_length: 1000
    # 預設。refresh=wait_for 同時等待的請求上限，超過的請求會被強制 refresh
    index.max_refresh_listeners: 1000
    # 預設。node query cache（filter 結果）
    index.queries.cache.enabled: true
    # 預設。shard request cache（size: 0 的聚合結果）
    index.requests.cache.enable: true

    #--------------------------------------------------------------------------
    # 慢日誌（預設全部 -1 = 關閉；寫到 /var/log/elasticsearch/<cluster.name>_index_*_slowlog.json）
    #--------------------------------------------------------------------------
    # 建議（預設 -1），動態。查詢階段超過 5 秒記 WARN
    index.search.slowlog.threshold.query.warn: 5s
    # 建議（預設 -1），動態
    index.search.slowlog.threshold.query.info: 2s
    # 建議（預設 -1），動態。fetch 階段（取回 _source）
    index.search.slowlog.threshold.fetch.warn: 1s
    # 建議（預設 -1），動態
    index.search.slowlog.threshold.fetch.info: 500ms
    # 建議（預設 false），動態。記錄是哪個使用者 / API key 發出的查詢
    index.search.slowlog.include.user: true
    # 建議（預設 -1），動態
    index.indexing.slowlog.threshold.index.warn: 5s
    # 建議（預設 -1），動態
    index.indexing.slowlog.threshold.index.info: 2s
    # 預設，動態。慢寫入日誌記錄 _source 的前 1000 個字元
    index.indexing.slowlog.source: 1000
    # 建議（預設 false），動態
    index.indexing.slowlog.include.user: true
```

```bash
curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u elastic \
  -X PUT "https://es1:9200/_component_template/base-settings" \
  -H 'Content-Type: application/yaml' --data-binary @index-template-single.yaml
curl -sS --cacert /etc/elasticsearch/certs/http_ca.crt -u elastic \
  -X PUT "https://es1:9200/_index_template/apps" -H 'Content-Type: application/json' \
  -d '{"index_patterns":["orders*","app-*"],"composed_of":["base-settings"],"priority":200,"version":1}'
```

用 `_simulate_index` 確認新索引會拿到哪些設定（節錄）：

```console
[es1] POST /_index_template/_simulate_index/orders?filter_path=template.settings&pretty
{
  "template" : {
    "settings" : {
      "index" : {
        ...
        "translog" : {
          "flush_threshold_age" : "1m",
          "flush_threshold_size" : "10gb",
          "sync_interval" : "5s",
          "durability" : "request"
        },
        "number_of_replicas" : "0",
        "search" : {
          "slowlog" : {
            "include" : { "user" : "true" },
            "threshold" : {
              "fetch" : { "warn" : "1s", "info" : "500ms" },
              "query" : { "warn" : "5s", "info" : "2s" }
            }
          },
          "idle" : { "after" : "30s" }
        },
        "number_of_shards" : "1",
        "merge" : {
          "scheduler" : { "auto_throttle" : "true" },
          "policy" : {
            "max_merge_at_once" : "16",
            "segments_per_tier" : "8.0",
            "floor_segment" : "16mb",
            "deletes_pct_allowed" : "20.0"
          }
        },
        ...
      }
    }
  }
}

[es1]# python3 /root/bin/checkconf.py /root/conf/index-template-single.yaml /root/results/defaults-index-9.5.5.txt /root/results/actual-index-es1.json
--- 設定檔參數數量與標記
建議	9
預設	31
...
--- 共 40 個參數，ok 40 個
```

- `number_of_replicas: 0` 是單節點**唯一**的正確值：設 1 的話副本永遠分配不出去，叢集永遠是 yellow。
- `refresh_interval` 刻意不寫：不設定時預設 1 秒，而且索引 30 秒沒有搜尋就暫停 refresh（search idle），寫入多、查詢少的索引會省很多資源；**明確寫 `1s` 反而會關掉這個行為**。

## 步驟 7：功能驗證

### bulk 寫入與 segment

```console
[es1]# /root/bin/gen-orders.sh 300000 > /tmp/orders.ndjson; ls -lh /tmp/orders.ndjson
-rw-r--r-- 1 root root 65M Oct 24 13:39 /tmp/orders.ndjson

[es1]# ES_PW=... /root/bin/bulk-load.sh es1 orders /tmp/orders.ndjson 5000
docs=300000 batches=60 failed=0 seconds=3.6 docs/s=83850

[es1] GET /_cat/indices/orders?v&h=health,index,pri,rep,docs.count,store.size,pri.store.size
health index  pri rep docs.count store.size pri.store.size
green  orders   1   0     300001     34.6mb         34.6mb

[es1] GET /_cat/segments/orders?v&h=shard,segment,docs.count,size,committed,searchable
shard segment docs.count   size committed searchable
0     _0               1  5.7kb false     true
0     _1           50000  5.8mb false     true
0     _2          125000 14.4mb false     true
0     _3          125000 14.3mb false     true
```

- 每批 5000 筆（約 1 MB），30 萬筆 3.6 秒、0 筆失敗（容器環境的數字，只用來確認服務正常）。bulk 每批抓 **5～15 MB**，失敗時看回應裡每一筆的 `status`，429 代表寫入佇列或 indexing pressure 滿了，要退避重送。
- segment 都是 `committed: false`：資料已經可以搜尋（refresh 過），但還沒有 Lucene commit（flush），當機時靠 translog 重播。`index.translog.durability: request` 保證每個回應成功的請求都已經 fsync 到 translog。

### 查詢與快取

```console
[es1] POST /orders/_search?filter_path=took,hits.total,aggregations&pretty
{"size":0,"query":{"bool":{"filter":[{"term":{"status":"paid"}},{"range":{"created_at":{"gte":"2026-07-01","lt":"2026-10-01"}}}]}},"aggs":{"by_region":{"terms":{"field":"region"},"aggs":{"revenue":{"sum":{"field":"amount"}}}}}}
{
  "took" : 71,
  "hits" : {
    "total" : {
      "value" : 10000,
      "relation" : "gte"
    }
  },
  "aggregations" : {
    "by_region" : {
      "buckets" : [
        { "key" : "us", "doc_count" : 2987, "revenue" : { "value" : 3035533.84 } },
        { "key" : "jp", "doc_count" : 2974, "revenue" : { "value" : 3023182.25 } },
        ...
      ]
    }
  }
}

[es1] GET /_nodes/stats/indices/query_cache,request_cache?filter_path=nodes.*.indices.query_cache.memory_size_in_bytes,nodes.*.indices.query_cache.hit_count,nodes.*.indices.request_cache&pretty
{
  "nodes" : {
    "kJIxUfY_TDCLLhP-qJWblg" : {
      "indices" : {
        "query_cache" : { "memory_size_in_bytes" : 0, "hit_count" : 0 },
        "request_cache" : { "memory_size_in_bytes" : 840, "evictions" : 0, "hit_count" : 0, "miss_count" : 1 }
      }
    }
  }
}
```

- `hits.total` 顯示 `10000 / gte`：預設只精確計算到 1 萬筆（`track_total_hits`），需要精確總數時才加 `"track_total_hits": true`，代價是查詢變慢。
- `size: 0` 的聚合結果進了 **request cache**（`miss_count: 1`，下一次相同查詢就會命中）；filter 子句的 query cache 只會快取在夠大的 segment 上、而且被重複使用的 filter，第一次查詢不會進去。

### 慢查詢日誌

把門檻暫時設成 0ms 確認慢日誌有在寫，確認完一定要改回來：

```console
[es1] PUT /orders/_settings
{"index.search.slowlog.threshold.query.info":"0ms"}
{"acknowledged":true}

[es1] POST /orders/_search?filter_path=took
{"size":0,"query":{"wildcard":{"customer_id":{"value":"*99"}}}}
{"took":24}

[es1]# tail -1 /var/log/elasticsearch/es-single_index_search_slowlog.json | jq -c '{"@timestamp", "log.level", "elasticsearch.slowlog.took", "elasticsearch.slowlog.source", "user.name"}'
{"@timestamp":"2026-10-24T13:39:41.065Z","log.level":"INFO","elasticsearch.slowlog.took":"16.5ms","elasticsearch.slowlog.source":"{\\\"size\\\":0,\\\"query\\\":{\\\"wildcard\\\":{\\\"customer_id\\\":{\\\"wildcard\\\":\\\"*99\\\",\\\"boost\\\":1.0}}}}","user.name":"elastic"}

[es1] PUT /orders/_settings
{"index.search.slowlog.threshold.query.info":null}
{"acknowledged":true}
```

`include.user: true` 讓慢日誌帶上 `user.name`，查出是哪個應用程式帳號發的慢查詢。設成 `null` 是回到範本的值（2s），不是關閉。

### 快照

```console
[es1] PUT /_snapshot/local_repo
{"type":"fs","settings":{"location":"/mnt/es-snapshots/single"}}
{"acknowledged":true}

[es1] POST /_snapshot/local_repo/_verify?pretty
{
  "nodes" : {
    "kJIxUfY_TDCLLhP-qJWblg" : {
      "name" : "es1"
    }
  }
}

[es1] PUT /_snapshot/local_repo/snap-1?wait_for_completion=true&filter_path=snapshot.state,snapshot.indices,snapshot.shards,snapshot.duration_in_millis
{"indices":"orders","include_global_state":false}
{"snapshot":{"indices":["orders"],"state":"SUCCESS","duration_in_millis":1008,"shards":{"total":1,"failed":0,"successful":1}}}
```

`location` 必須在 `path.repo` 底下。單節點的快照放在同一台主機上**只能防誤刪，不能防主機故障**，正式環境要放到另一台主機（NFS）或 S3 等物件儲存，排程與保留用 SLM（見[備份與還原]({% post_url 2026-10-24-elasticsearch-ops-02-backup-restore %})）。

### 重啟後資料仍在

```console
[es1]# time systemctl restart elasticsearch

real	0m14.258s

（重啟後 .security 索引可用、可以登入：等了 1 秒）
[es1] GET /_cat/indices/orders?v&h=health,index,docs.count,store.size
health index  docs.count store.size
green  orders     300001     34.6mb
```

`systemctl restart` 回來之後，馬上送請求可能會拿到 **503**：

```text
[ERROR][o.e.x.s.a.e.ReservedRealm] [es1] failed to retrieve password hash for reserved user [elastic]
[WARN ][r.suppressed             ] [es1] path: /_cluster/health, params: {}, status: 503
```

帳號資料在 `.security` 系統索引裡，節點啟動後這個分片還在復原時，**連 `elastic` 都無法登入**。監控與部署腳本在重啟後要重試，等到 `_cluster/health` 回 200 再繼續。

### 錯誤日誌

```console
[es1]# grep -E '\]\[(WARN|ERROR)' /var/log/elasticsearch/es-single.log | cut -c1-160 | sort -u -k3
...
[WARN ][o.e.g.CuVSGPUSupport     ] [es1] GPU based vector indexing is not supported on this platform; cuvs-java supports only x86
[WARN ][stderr                   ] [es1] SLF4J(W): No SLF4J providers were found.
[WARN ][i.o.usage                ] [es1] OpenTelemetry API usage issue detected. ...
[WARN ][o.e.x.s.a.RealmsAuthenticator] [es1] Authentication to realm default_native failed - Password authentication failed for app

[es1]# jq -r ".message" /var/log/elasticsearch/es-single_deprecation.json | sort | uniq -c | sort -rn | head -4
      6 [xpack.monitoring.collection.enabled] setting was deprecated in Elasticsearch and will be removed in a future release. See the breaking changes documentation for the next major version.
      1 Parameter [default_metric] is deprecated and will be removed in a future version
      1 Index [.reindexed-v8-ml-anomalies-*] name begins with a dot (.), which is deprecated, and will not be allowed in a future Elasticsearch version.
      1 Index [.logs-elasticsearch.deprecation-default] name begins with a dot (.), which is deprecated, and will not be allowed in a future Elasticsearch version.
```

- 9.5.5 在 aarch64 上每次啟動都會有幾行可以忽略的 WARN：`CuVSGPUSupport`（GPU 向量索引只支援 x86）、`SLF4J`、`OpenTelemetry API usage issue`，journal 裡還有一行 `WARNING: Unknown module: org.apache.arrow.memory.core specified to --add-opens`（來自內建的 `jvm.options`）。
- 第一次啟動時會有幾十行 `IndexTemplateRegistry ... error adding ...`，是節點剛建立叢集、還沒準備好時安裝內建範本失敗；之後的啟動都沒有再出現。
- `Authentication to realm default_native failed` 是前面故意用錯誤密碼測試留下的。
- deprecation log 的 `xpack.monitoring.collection.enabled` 是設定檔造成的，處理方式見下一節；後三行是內建的系統索引與功能，不用處理。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `memory_lock: true` 但 `mlockall: false`，服務照樣 active | systemd 沒有 `LimitMEMLOCK=infinity`；`single-node` 不強制 bootstrap checks，只記 WARN | 加 override，並用 `_nodes?filter_path=**.mlockall` 確認 |
| `setting [cluster.initial_master_nodes] is not allowed when [discovery.type] is set to [single-node]` | auto-config 寫了 `initial_master_nodes`，又加了 `discovery.type: single-node` | 用本文的設定檔整份取代 RPM 的設定檔 |
| `unknown setting [...enable_for_single_data_node]` | 9.0 移除的設定，常見於從 8.x 搬過來的設定檔 | 刪除這一行 |
| `unknown setting [...] did you mean any of [...]` | 設定名稱打錯，Elasticsearch 不認得的設定一律拒絕啟動 | 依錯誤訊息的建議修正 |
| `journalctl` 只顯示 `Elasticsearch did not exit normally` | 真正的原因寫在 Elasticsearch 自己的日誌 | 看 `/var/log/elasticsearch/<cluster.name>.log` 的 `fatal exception` 下一行 |
| 重啟後 API 回 503、`failed to retrieve password hash for reserved user [elastic]` | `.security` 索引還在復原 | 重試直到 health 回 200 |
| deprecation log 每次啟動都有 `[xpack.monitoring.collection.enabled] setting was deprecated` | 即使寫的是預設值 `false`，只要出現在設定檔就會警告 | 不要寫這一行（本文設定檔已改成註解），監控改用 Elastic Agent / Metricbeat |
| 容器內：`curl: (60) SSL: no alternative certificate subject name matches target host name` | 映像在 `docker build` 時就跑了 auto-config，憑證的 SAN 是建置容器的名稱 | 實驗腳本改用 `localhost` 驗證憑證；實體機在主機上安裝不會有這個問題 |

## 驗證方式與結果

**驗證環境**

| 項目 | 內容 |
| :--- | :--- |
| 主機 | MacBook Air M4，macOS 15.7.4，24 GB RAM |
| 容器 | Docker Desktop 4.96.3（Engine 29.9.2），VM 10 CPU / 約 7.7 GB |
| 作業系統 | `rockylinux/rockylinux:9` 映像（Rocky Linux 9.8）+ systemd |
| Elasticsearch | 9.5.5-1（比較用 8.19.23-1），Elastic 官方 RPM 套件庫，內附 OpenJDK 27 |
| 架構 | aarch64 |

每台主機是一個 privileged 容器，以 `/usr/sbin/init`（systemd）為 PID 1，所以 `systemctl`、`Type=notify`、`LimitMEMLOCK` 都是真實流程。`es1` 是只有 systemd 的乾淨 Rocky 9.8，步驟 0～7 全部在容器裡照文章執行。建置檔與腳本放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/elasticsearch-lab)：

```dockerfile
# Rocky Linux 9 + systemd（還沒裝 Elasticsearch）：給 es1 現場照「步驟 1」安裝用
# 注意：Docker Hub 的 rockylinux:9 停在 9.3，要用 rockylinux/rockylinux:9
FROM rockylinux/rockylinux:9
RUN mkdir -p /etc/sysctl.d \
 && dnf install -y systemd procps-ng iproute hostname which less vim-minimal tzdata diffutils jq openssl python3 \
 && dnf clean all \
 && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
```

```dockerfile
# Rocky Linux 9 + systemd + 依「步驟 1」用 Elastic 官方 RPM 套件庫安裝 Elasticsearch（叢集節點用，尚未啟動）
# ES_MAJOR=9 / ES_VERSION=9.5.5 或 ES_MAJOR=8 / ES_VERSION=8.19.23
FROM eslab-rocky9-base
ARG ES_MAJOR=9
ARG ES_VERSION=9.5.5
RUN rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch \
 && printf '[elasticsearch]\nname=Elasticsearch repository for %s.x packages\nbaseurl=https://artifacts.elastic.co/packages/%s.x/yum\ngpgcheck=1\ngpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch\nenabled=0\nautorefresh=1\ntype=rpm-md\n' $ES_MAJOR $ES_MAJOR > /etc/yum.repos.d/elasticsearch.repo \
 && dnf install -y --enablerepo=elasticsearch elasticsearch-$ES_VERSION \
 && dnf clean all
```

```yaml
# es1：單節點；esc1~esc3（+esc4 擴充）：三節點叢集；esu1~esu3：8.19 → 9.5 滾動升級；esd9 / esd8：預設值對照
x-node: &node
  image: eslab-rocky9-es9
  pull_policy: never
  privileged: true            # systemd 當 PID 1、sysctl、mlockall 需要
  # memlock 設成 8 MB（實機 Rocky 9 的預設）：Docker Desktop 的容器預設是 unlimited，systemd 服務會繼承而讓
  # memory_lock 踩坑重現不出來；和實機一樣要靠 systemd 的 LimitMEMLOCK=infinity 才能鎖住 heap
  ulimits: { memlock: 8388608 }
  cgroup: host
  volumes: ["/sys/fs/cgroup:/sys/fs/cgroup:rw", "./conf:/root/conf:ro", "./bin:/root/bin:ro", "./results:/root/results:ro", "snap:/mnt/es-snapshots"]
  tmpfs: ["/run", "/run/lock"]
  extra_hosts:
    - "es1:192.168.60.11"
    - "esc1:192.168.60.21"
    - "esc2:192.168.60.22"
    - "esc3:192.168.60.23"
    - "esc4:192.168.60.24"
    - "esu1:192.168.60.31"
    - "esu2:192.168.60.32"
    - "esu3:192.168.60.33"
    - "esd9:192.168.60.41"
services:
  es1:  { <<: *node, image: eslab-rocky9-base, hostname: es1,  networks: { labnet: { ipv4_address: 192.168.60.11 } } }
  esc1: { <<: *node, hostname: esc1, networks: { labnet: { ipv4_address: 192.168.60.21 } } }
  esc2: { <<: *node, hostname: esc2, networks: { labnet: { ipv4_address: 192.168.60.22 } } }
  esc3: { <<: *node, hostname: esc3, networks: { labnet: { ipv4_address: 192.168.60.23 } } }
  esc4: { <<: *node, hostname: esc4, networks: { labnet: { ipv4_address: 192.168.60.24 } } }
  esu1: { <<: *node, image: eslab-rocky9-es8, hostname: esu1, networks: { labnet: { ipv4_address: 192.168.60.31 } } }
  esu2: { <<: *node, image: eslab-rocky9-es8, hostname: esu2, networks: { labnet: { ipv4_address: 192.168.60.32 } } }
  esu3: { <<: *node, image: eslab-rocky9-es8, hostname: esu3, networks: { labnet: { ipv4_address: 192.168.60.33 } } }
  esd9: { <<: *node, hostname: esd9, networks: { labnet: { ipv4_address: 192.168.60.41 } } }
  esd8: { <<: *node, image: eslab-rocky9-es8, hostname: esd8, networks: { labnet: { ipv4_address: 192.168.60.42 } } }
networks:
  labnet:
    ipam: { config: [ { subnet: 192.168.60.0/24 } ] }
volumes:
  snap: {}
```

- `ulimits: { memlock: 8388608 }`：Docker Desktop 的容器預設 memlock 是 unlimited，systemd 服務會繼承下來，讓踩坑 1 重現不出來；設成 8 MB 才和實體的 Rocky 9 一樣，要靠 `LimitMEMLOCK=infinity` 才鎖得住。
- 想自己重現的話，把 `tools/elasticsearch-lab` 整個資料夾複製下來，依序執行 `./00-build.sh`、`./05-defaults.sh`、`./10-single-node.sh`（叢集是 `20-`、滾動升級是 `30-`、同步落後是 `40-`），輸出會記錄在 `results/`。

**設定檔的「建議 / 預設」標記怎麼驗證**：`05-defaults.sh` 在全新的 9.5.5 與 8.19.23 節點上（RPM 原始設定）用 `GET _cluster/settings?include_defaults=true&flat_settings=true` 匯出所有節點設定的預設值（9.5.5 共 1058 個、8.19.23 共 850 個），用 `GET <index>/_settings?include_defaults=true` 匯出索引設定的預設值（224 / 184 個）。`bin/checkconf.py` 讀設定檔，依每個參數上一行註解的標記比對：標「預設」的，設定值必須等於預設值、節點的實際值也要相同；標「建議」的，設定值必須和預設值不同。數值會先正規化（`1s` = `1000ms`、`100mb` = `104857600b`），再比較。

**驗證項目**

| 步驟 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 0 OS 參數 | `sysctl -p` | 三個值都套用 | ✅ |
| 1 安裝 | `rpm -qi`、`elasticsearch --version` | 9.5.5、簽章 Key ID 與 Elastic 金鑰一致、內附 JDK 27 | ✅ |
| 2 設定檔 | `checkconf.py` | 沒有 CHECK / UNKNOWN | ✅ 69 個參數全部符合（建議 8 / 必要 13 / 預設 48） |
| 3 memory lock | 先不加 override 啟動，再加 override | 沒加時 WARN、加了 `mlockall: true` | ✅（沒加時**沒有**拒絕啟動，見踩坑 1） |
| 3 錯誤設定 | 三種錯誤設定各啟動一次 | 都拒絕啟動，日誌有明確原因 | ✅ |
| 4 啟動 | `systemctl status`、`/proc/<pid>/limits` | active、locked memory unlimited | ✅ 7.5 秒 |
| 5 帳號 | 正確 / 錯誤密碼、越權操作、`http://` | 只有正確密碼與授權的操作成功 | ✅ |
| 6 索引範本 | `_simulate_index`、`checkconf.py` | 範本的值都套用 | ✅ 40 個參數全部符合 |
| 7 寫入 / 查詢 | bulk 30 萬筆、聚合查詢 | 0 筆失敗、結果正確 | ✅ 3.6 秒 |
| 7 慢日誌 | 門檻設 0ms | 慢日誌有紀錄、含 `user.name` | ✅ |
| 7 快照 | `_verify`、建立快照 | `SUCCESS` | ✅ 約 1 秒 |
| 7 持久化 | `systemctl restart` | 文件數不變 | ✅ 14.3 秒 |
| 8.19 比較 | 同一份設定檔放到 8.19.23 | 記錄需要修改的地方 | ✅ 見下一節 |

**錯誤處理紀錄**（對應上方「實測踩到的坑」）：

- 第一次跑踩坑 1 時，容器的 memlock 是 unlimited，`mlockall` 直接成功、什麼都沒發生；查出是 Docker Desktop 的預設值，在 compose 加上 `ulimits` 後才重現實體機的行為。也是這次才確認 **single-node 不會因為 memory lock 拒絕啟動**，原本的文章寫錯了，已修正。
- 實驗腳本第一版在踩坑 1 之後沒有 `systemctl stop`，服務意外啟動成功後，後面三個踩坑的 `systemctl start` 都變成沒有作用（顯示 `active`）；加上 stop 後三個踩坑都如預期失敗。
- 重啟後馬上查詢拿到 503，加上「等到 health 回 200」的步驟。
- 容器內的 auto-config 憑證問題見上表最後一列。

## 版本差異比較：9.5.5 vs 8.19.23

同一份 `elasticsearch.yml`（只改 `node.name` 與 IP）放到 8.19.23 的 `esd8` 上，**第一次啟動失敗**：

```console
[esd8]# systemctl start elasticsearch; systemctl is-active elasticsearch
Job for elasticsearch.service failed because the control process exited with error code.
failed
[esd8]# grep -E "setting \[" /var/log/elasticsearch/es-single.log | head -1
java.lang.IllegalArgumentException: unknown setting [cluster.state.encryption.required] please check that any required plugins are installed, or check the breaking changes documentation for removed settings
```

刪掉 `cluster.state.encryption.required` 這一行後就能啟動（7.0 秒），`checkconf.py` 對 8.19.23 的預設值比對，只有一個參數不符：

```console
[esd8] GET /?filter_path=version.number,version.lucene_version
{
  "version" : {
    "number" : "8.19.23",
    "lucene_version" : "9.12.2"
  }
}

[esd8]# python3 /root/bin/checkconf.py /etc/elasticsearch/elasticsearch.yml /root/results/defaults-node-8.19.23.txt /root/results/actual-node-esd8.json
--- 設定檔參數數量與標記
建議	8
必要	13
預設	47
--- 需要確認的項目（CHECK / UNKNOWN；...）
line	tag	setting	file	default	actual	result
161	預設	thread_pool.search.queue_size	16000	1000	16000	CHECK
...
--- 共 68 個參數，ok 67 個
```

`thread_pool.search.queue_size: 16000` 是 9.x 的預設值，在 8.19 上等於把搜尋佇列從 1000 調大 16 倍。

**和這份設定檔有關的預設值差異**（兩個版本全新節點匯出的預設值比對；節點設定共 247 行不同、索引設定 57 行、執行緒池 9 行，這裡只列和效能、運維有關的）：

| 參數 | 8.19.23 | 9.5.5 | 影響 |
| :--- | :--- | :--- | :--- |
| `cluster.state.encryption.required` | 不存在 | `true` | 9.5 新增，8.19 寫了會拒絕啟動 |
| `thread_pool.search.queue_size` | 1000 | 16000 | 9.x 的搜尋佇列大很多，尖峰時比較少 429，但排隊的延遲會變長 |
| `thread_pool.search_throttled` | size 1 / queue 100 | 移除 | 隨 frozen 索引移除 |
| `thread_pool.write_coordination` | 不存在 | size = CPU 數 / queue 10000 | 9.x 新增，協調節點的 bulk 轉送獨立成一個池 |
| `thread_pool.esql_worker.queue_size` | 1000 | 3984 | ES\|QL 的工作佇列 |
| `index.merge.policy.floor_segment` | 2mb | 16mb | 9.x 更積極合併小 segment，segment 數比較少 |
| `index.merge.policy.segments_per_tier` | 10.0 | 8.0 | 同上 |
| `index.merge.policy.max_merge_at_once` | 10 | 16 | 同上 |
| `index.merge.scheduler.max_thread_count` | 4 | 5 | 依 CPU 數計算的公式改了（同一台 10 CPU 的 VM） |
| `index.mapping.nested_fields.limit` | 50 | 100 | |
| `index.mapping.nested_parents.limit`、`array_objects.limit` | 不存在 | 50 / 50000 | 9.x 新增的 mapping 保護 |
| `index.frozen`、`index.search.throttled` | false | 移除 | |
| `cluster.logsdb.enabled` | false | true | 9.x 的 `logs-*-*` data stream 預設用 LogsDB 模式（省空間，但寫入多一點 CPU） |
| `rest.incremental_bulk` | false | true | 9.x 的 bulk 請求邊收邊處理，降低大 bulk 對 heap 的衝擊 |
| `health.shards_availability.replica_unassigned_buffer_time` | 3s | 25s | 9.x 的 health API 對短暫未分配的副本比較寬容 |

### 這份設定檔拿到 8.19 要改什麼

- 刪除 `cluster.state.encryption.required`（8.19 不認得，會拒絕啟動）。
- `thread_pool.search.queue_size` 改成 8.19 的預設 1000，或直接不寫。
- 索引範本裡標「9.x 預設」的 merge policy 與 `nested_fields.limit`，在 8.19 上會變成「調整過的值」：想維持 8.19 行為就改回 `2mb` / `10.0` / `10` / `50`。
- 反過來，8.19 的設定檔要搬到 9.5，先看 deprecation log，並移除 `enable_for_single_data_node`（踩坑 3）、`index.frozen` 相關設定，詳見[滾動升級 8.19 → 9.5]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})。

## 小結

- Rocky 9 用 Elastic 官方 RPM 套件庫安裝，套件庫設 `enabled=0`、安裝時指定完整版本；內附 JDK，不需要另外裝 Java。
- RPM 的 auto-config 會產生憑證與 `initial_master_nodes`；單節點用 `discovery.type: single-node` 取代，兩者不能並存。
- `memory_lock: true` 一定要配 systemd 的 `LimitMEMLOCK=infinity`。**單節點不強制 bootstrap checks，忘了設也照樣啟動**，要用 `mlockall` 確認。
- 設定錯誤（不認得、衝突的參數）一律拒絕啟動，原因看 Elasticsearch 自己的日誌，不是 journal。
- `elasticsearch.yml` 只放節點層級設定，索引層級的 refresh、translog、merge、慢日誌放 component template；單節點的副本數一定是 0。
- 同一份設定檔在 8.19 上要拿掉 `cluster.state.encryption.required`，搜尋佇列的「預設值」也不一樣。

下一篇：[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})，改用自建 CA 的憑證、組成三節點叢集，並實測節點故障、master 故障、失去過半數、滾動重啟、快照還原與擴充節點。

### 參考資料

- [Elastic Docs：Install Elasticsearch with RPM](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-with-rpm)
- [Elastic Docs：Important system configuration](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/important-system-configuration)
- [Elastic Docs：Bootstrap checks](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/bootstrap-checks)
- [Elastic Docs：Set JVM options](https://www.elastic.co/docs/reference/elasticsearch/jvm-settings)
- [Elastic Docs：Elasticsearch configuration reference](https://www.elastic.co/docs/reference/elasticsearch/configuration-reference)
- [Elastic Docs：Index settings](https://www.elastic.co/docs/reference/elasticsearch/index-settings)
- [Elasticsearch 9.5 Release Notes](https://www.elastic.co/docs/release-notes/elasticsearch)
