---
title: Elasticsearch 安裝部署 04：Kibana 安裝與設定（Rocky Linux 9）
date: 2026-10-24 16:04:00 +0800
categories: [Elasticsearch, 安裝部署]
tags: [elasticsearch, elasticsearch9, kibana, kibana9, rpm, tls, keystore, task-manager, dba]
description: 在 Rocky Linux 9 上用官方 RPM 安裝 Kibana 9.5.5，連到三節點 Elasticsearch 叢集：自建 CA 的雙向 TLS、kibana_system 帳號、keystore 與加密金鑰、heap、附完整註解的 kibana.yml（效能參數逐一以 9.5.5 的設定 schema 核對預設值），以及節點故障、拼錯參數、改用 8.19 的實測結果，所有輸出皆為實測結果。
---

前三篇的指令都是直接打 REST API，實務上大部分的人是透過 **Kibana** 查資料、看儀表板、管理叢集（Dev Tools、Stack Management、Upgrade Assistant、告警規則都在 Kibana 裡）。這篇在[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})的 `es-prod` 旁邊加一台 Kibana 主機 `kb1`，從安裝、TLS、帳號、`kibana.yml` 到故障行為都實際跑一遍。

{% include elasticsearch-ops-series.md %}

{% include elasticsearch-lab-env.md %}

## 架構

| 主機 | IP | 角色 | 版本 |
| :--- | :--- | :--- | :--- |
| `esc1`～`esc3` | 192.168.60.21～23 | Elasticsearch 叢集 `es-prod`（master + data + ingest） | 9.5.5 |
| `kb1` | 192.168.60.51 | Kibana | 9.5.5 |

```text
 瀏覽器 ──HTTPS 5601（kb1 憑證）──► kb1 Kibana ──HTTPS 9200（驗證 CA + 主機名）──► esc1 / esc2 / esc3
                                    │ 帳號 kibana_system（密碼在 kibana-keystore）
                                    └ 設定與儀表板存在 Elasticsearch 的 .kibana* 系統索引
```

幾個先講清楚的原則：

- **版本要和 Elasticsearch 完全一樣**（major.minor 相同，patch 也建議相同）。Kibana 不能比任何一台 Elasticsearch 新；升級時先升完 Elasticsearch、最後才升 Kibana（[滾動升級]({% post_url 2026-10-24-elasticsearch-lab-03-rolling-upgrade %})）。
- **Kibana 本身沒有狀態**：data view、儀表板、告警規則、使用者的工作階段都存在 Elasticsearch 的 `.kibana*` 系統索引。所以 Kibana 主機壞了，裝一台新的、放回同一份 `kibana.yml` 與加密金鑰就好；要備份的是 Elasticsearch 的 `kibana` feature state（[備份與還原]({% post_url 2026-10-24-elasticsearch-ops-02-backup-restore %})）。
- **不要和 Elasticsearch 裝在同一台**：Kibana（Node.js）會吃掉 1～2 GB 記憶體與 CPU，和 Elasticsearch 的 heap、檔案系統快取搶資源。正式環境用一台獨立的小主機（本文以 4 GB RAM、2 vCPU 為基準），要高可用就放兩台以上、前面加負載平衡。
- 防火牆（**未實測**）：5601 只開給使用者的網段；`kb1` 只需要能連到 Elasticsearch 的 9200，不需要 9300。

## 步驟 0：Elasticsearch 這一側的準備

叢集的建置方式和[三節點 Cluster]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})相同，差別只有 `instances.yml` 多了一筆 `kb1`，讓同一個自建 CA 一起簽發 Kibana 的憑證（SAN 一樣要有主機名、FQDN 與 IP）：

```yaml
# elasticsearch-certutil cert --in 用的節點清單：SAN 包含主機名、FQDN 與 IP（verification_mode: full 會驗證主機名）
instances:
  - { name: esc1, dns: [ esc1, esc1.lab.local ], ip: [ 192.168.60.21 ] }
  - { name: esc2, dns: [ esc2, esc2.lab.local ], ip: [ 192.168.60.22 ] }
  - { name: esc3, dns: [ esc3, esc3.lab.local ], ip: [ 192.168.60.23 ] }
  - { name: esc4, dns: [ esc4, esc4.lab.local ], ip: [ 192.168.60.24 ] }
  - { name: esu1, dns: [ esu1, esu1.lab.local ], ip: [ 192.168.60.31 ] }
  - { name: esu2, dns: [ esu2, esu2.lab.local ], ip: [ 192.168.60.32 ] }
  - { name: esu3, dns: [ esu3, esu3.lab.local ], ip: [ 192.168.60.33 ] }
  - { name: esd9, dns: [ esd9, esd9.lab.local ], ip: [ 192.168.60.41 ] }
  - { name: kb1,  dns: [ kb1,  kb1.lab.local ],  ip: [ 192.168.60.51 ] }
```

`elasticsearch-certutil cert --pem --in instances.yml` 產生的 `kb1/kb1.crt`、`kb1/kb1.key` 和 `ca/ca.crt` 複製到 `kb1`。CA 的私鑰 `ca.key` **不要**複製過去。

接著在 Elasticsearch 上設定內建使用者 `kibana_system` 的密碼。這個帳號只有 Kibana 自己運作需要的權限，**不要讓 Kibana 用 `elastic` 連線**（9.x 的設定 schema 直接拒絕 `elasticsearch.username: elastic`）：

```console
[esc1] POST /_security/user/kibana_system/_password
{"password":"ChangeMe_Kibana_2026"}
{}

[esc1] GET /_security/user/kibana_system?filter_path=*.roles,*.metadata,*.enabled
{"kibana_system":{"roles":["kibana_system"],"metadata":{"_reserved":true},"enabled":true}}
```

> 也可以用 `elasticsearch-reset-password -u kibana_system -i`。另一個選擇是服務帳號 token（`elasticsearch-service-tokens create elastic/kibana kibana-token`，設定 `elasticsearch.serviceAccountToken`），不用管密碼輪替，見[安全與權限管理]({% post_url 2026-10-24-elasticsearch-ops-07-security %})；本文用 `kibana_system` 是因為它在 8.x、9.x 都通用、最多人用。
{: .prompt-tip }

使用者登入 Kibana 用的是**自己的帳號**（例如 `elastic` 或另外建立、有 `kibana_admin` 等角色的帳號），Kibana 會把使用者的 `authorization` 標頭轉給 Elasticsearch，以使用者的權限查詢；`kibana_system` 只在背景使用。

## 步驟 1：安裝

Kibana 和 Elasticsearch 用**同一個 Elastic 套件庫**（`/etc/yum.repos.d/elasticsearch.repo`，內容見[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})的步驟 1），套件名稱是 `kibana`，一樣要指定版本：

```console
[kb1]# rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch && cp /root/conf/elasticsearch.repo /etc/yum.repos.d/elasticsearch.repo && dnf install -y -q --enablerepo=elasticsearch kibana-9.5.5 2>&1 | tail -5; rpm -q kibana

Installed:
  kibana-9.5.5-1.aarch64

kibana-9.5.5-1.aarch64

[kb1]# rpm -qi kibana | grep -E "^(Version|Release|Architecture|Size)"; du -sh /usr/share/kibana; ls /usr/share/kibana/bin
Version     : 9.5.5
Release     : 1
Architecture: aarch64
Size        : 1487238393
1.8G	/usr/share/kibana
kibana
kibana-encryption-keys
kibana-health-gateway
kibana-keystore
kibana-plugin
kibana-setup
kibana-verification-code
```

套件安裝後佔 1.8 GB（內附 Node.js v24.21.0，不需要另外裝 Node）。RPM 建立的目錄與 systemd unit：

```console
[kb1]# ls -la /etc/kibana /var/lib/kibana /var/log/kibana; id kibana
/etc/kibana:
-rw-rw---- 1 root kibana  130 Oct 25 06:13 kibana.keystore
-rw-rw---- 1 root kibana 8076 Sep 30 12:18 kibana.yml
-rw-rw-r-- 1 root kibana  384 Sep 30 12:18 node.options

/var/lib/kibana:
drwxr-s--- 2 kibana kibana 4096 Sep 30 12:23 .

/var/log/kibana:
drwxr-s--- 2 kibana kibana 4096 Sep 30 12:23 .
uid=998(kibana) gid=998(kibana) groups=998(kibana)

[kb1]# systemctl cat kibana | grep -vE "^\s*$"
# /usr/lib/systemd/system/kibana.service
[Unit]
Description=Kibana
Documentation=https://www.elastic.co
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
User=kibana
Group=kibana
PrivateTmp=true
Environment=KBN_HOME=/usr/share/kibana
Environment=KBN_PATH_CONF=/etc/kibana
EnvironmentFile=-/etc/default/kibana
EnvironmentFile=-/etc/sysconfig/kibana
ExecStart=/usr/share/kibana/bin/kibana
Restart=on-failure
RestartSec=3
StartLimitBurst=3
StartLimitInterval=60
WorkingDirectory=/usr/share/kibana
StandardOutput=journal
StandardError=inherit
[Install]
WantedBy=multi-user.target
```

和 Elasticsearch 不同的地方：

- **沒有 security auto-config**：Elasticsearch 的 RPM 會自動產生憑證與密碼，Kibana 不會。8.x 起有 enrollment token（`kibana-setup --enrollment-token`）可以自動設定，但它是給「單節點、auto-config 憑證」用的；自建 CA 的叢集照下面手動設定比較清楚。
- **keystore 已經建好**（`/etc/kibana/kibana.keystore`，空的），不需要 `kibana-keystore create`。
- `Restart=on-failure`、`StartLimitBurst=3`：設定檔錯誤時 systemd 會重試 3 次（每次間隔約 6 秒）後放棄，狀態變成 `failed`。
- 不需要調整 OS 參數（`vm.max_map_count`、memlock、檔案數都是 Elasticsearch 才需要的）。

RPM 原本的 `kibana.yml` 只有日誌與 pid 檔兩項設定，其他全是註解：

```console
[kb1]# grep -vE "^\s*(#|$)" /etc/kibana/kibana.yml
logging:
  appenders:
    file:
      type: file
      fileName: /var/log/kibana/kibana.log
      layout:
        type: json
  root:
    appenders:
      - default
      - file
pid.file: /run/kibana/kibana.pid
```

## 步驟 2：憑證

```console
[kb1]# mkdir -p /etc/kibana/certs && install -o root -g kibana -m 640 /mnt/es-snapshots/.dist/es-certs/kb1/kb1.crt /etc/kibana/certs/kb1.crt && install -o root -g kibana -m 640 /mnt/es-snapshots/.dist/es-certs/kb1/kb1.key /etc/kibana/certs/kb1.key && install -o root -g kibana -m 644 /mnt/es-snapshots/.dist/ca/ca.crt /etc/kibana/certs/ca.crt && ls -l /etc/kibana/certs && openssl x509 -in /etc/kibana/certs/kb1.crt -noout -subject -ext subjectAltName
-rw-r--r-- 1 root kibana 1224 Oct 25 06:13 ca.crt
-rw-r----- 1 root kibana 1192 Oct 25 06:13 kb1.crt
-rw-r----- 1 root kibana 1675 Oct 25 06:13 kb1.key
subject=CN=kb1
X509v3 Subject Alternative Name: 
    DNS:kb1, DNS:kb1.lab.local, IP Address:192.168.60.51
```

- `ca.crt` 有兩個用途：Kibana 用它驗證 Elasticsearch 的憑證（`elasticsearch.ssl.certificateAuthorities`），使用者的電腦也要信任它，瀏覽器才不會出現憑證警告。
- `kb1.crt` / `kb1.key` 是瀏覽器連到 Kibana 用的（`server.ssl.*`）。正式環境如果使用者很多，這張通常改用公司內部 CA 或公開 CA 簽的憑證，不一定要和 Elasticsearch 同一個 CA。
- 私鑰權限 `640 root:kibana`：Kibana 以 `kibana` 使用者執行，讀得到、改不了。

## 步驟 3：kibana.yml

以下是完整的 `/etc/kibana/kibana.yml`，取代 RPM 原本的檔案。每個參數上一行的註解標明它是**建議**（調整過的值，括號內是預設值）、**預設**（9.5.5 的預設值，寫出來讓設定一目了然）還是**必要**（名稱、位址、憑證等依環境而定的值）。

```yaml
# /etc/kibana/kibana.yml
# Kibana 9.5 連線三節點叢集 es-prod（esc1~esc3）：效能與運維設定
# 以「獨立一台 4 GB RAM、2 vCPU 的 Kibana 主機，前面沒有反向代理，使用者直接以 HTTPS 連 5601」為基準。
# 每個參數上一行的註解：
#   建議：調整過的值（括號內是預設值）
#   預設：9.5.5 的預設值（Kibana 沒有 include_defaults 這類 API，預設值是從 9.5.5 安裝目錄裡各外掛的設定 schema 核對的，
#         方法見文章「驗證方式與結果」），寫出來是為了讓設定一目了然，日後要調整時知道從哪裡開始
#   必要：名稱、路徑、位址、憑證等依環境而定、沒有好壞之分的值
# Kibana 的設定 schema 是嚴格的：拼錯或不存在的參數會讓 Kibana 拒絕啟動（FATAL），不會被默默忽略。
# 密碼與加密金鑰不寫在這裡，放在 kibana-keystore（/etc/kibana/kibana.keystore）：
#   elasticsearch.password、xpack.encryptedSavedObjects.encryptionKey、xpack.reporting.encryptionKey、xpack.security.encryptionKey
# 改了這個檔案都要 systemctl restart kibana（沒有線上調整）。

#------------------------------------------------------------------------------
# 伺服器
#------------------------------------------------------------------------------
# 必要（預設 kibana 主機名）。顯示在 /api/status 與監控畫面，多台 Kibana 時用來分辨
server.name: kb1
# 建議（預設 localhost = 只聽 loopback，別台連不進來）。綁內網 IP
server.host: "192.168.60.51"
# 預設
server.port: 5601
# 建議（預設不設定，啟動時會 WARN）。使用者在瀏覽器實際輸入的網址；告警通知、報表、分享連結裡的網址都用它
server.publicBaseUrl: "https://kb1:5601"
# 預設（1 MB）。單一請求 body 的上限；匯入大型儀表板會撞到的是下面的 savedObjects.maxImportPayloadBytes，不是這個
server.maxPayload: 1048576
# 預設（毫秒）。keep-alive 連線閒置多久後關閉
server.keepaliveTimeout: 120000
# 預設（毫秒）。socket 無活動多久後關閉
server.socketTimeout: 120000
# 預設。收到 SIGTERM 後，等進行中的請求完成的上限，systemctl stop / restart 最多會等這麼久
server.shutdownTimeout: "30s"
# 預設。回應以 gzip 壓縮（瀏覽器下載的 JS bundle 很大，不要關）
server.compression.enabled: true
# 預設。brotli 壓縮率較好但較吃 CPU
server.compression.brotli.enabled: false
# 建議（預設 http1）。HTTP/2 讓瀏覽器在一條連線上多工載入大量 bundle 與 API 請求，需要 server.ssl.enabled: true
server.protocol: http2
# 必要。瀏覽器到 Kibana 的 HTTPS
server.ssl.enabled: true
# 必要。用同一個自建 CA 簽的 kb1 憑證（SAN 含 kb1、kb1.lab.local、192.168.60.51）
server.ssl.certificate: /etc/kibana/certs/kb1.crt
# 必要
server.ssl.key: /etc/kibana/certs/kb1.key
# 預設。9.x 預設就只接受 TLS 1.2 / 1.3（TLS 1 / 1.1 要明確加進來才會接受）
server.ssl.supportedProtocols: [ "TLSv1.2", "TLSv1.3" ]

#------------------------------------------------------------------------------
# 連線 Elasticsearch
#------------------------------------------------------------------------------
# 建議（預設 [http://localhost:9200]）。列出所有協調用的節點；Kibana 輪流送出請求，連不上的節點會暫時跳過
elasticsearch.hosts: [ "https://esc1:9200", "https://esc2:9200", "https://esc3:9200" ]
# 必要。Kibana 自己的服務帳號（內建使用者 kibana_system），密碼放 keystore 的 elasticsearch.password
elasticsearch.username: "kibana_system"
# 必要。簽發 Elasticsearch HTTP 憑證的 CA
elasticsearch.ssl.certificateAuthorities: [ "/etc/kibana/certs/ca.crt" ]
# 預設。full = 驗證憑證鏈 + 主機名要在 SAN 裡（所以 hosts 要用憑證上有的名稱）
elasticsearch.ssl.verificationMode: full
# 預設（毫秒）。Kibana 等 Elasticsearch 回應的上限；大範圍的儀表板查詢超過就顯示逾時。要調大時先查慢的是哪個查詢
elasticsearch.requestTimeout: 30000
# 預設（毫秒）。每個分片的查詢逾時（送給 Elasticsearch 的 timeout 參數），0 = 不限
elasticsearch.shardTimeout: 30000
# 預設（毫秒）。啟動時檢查 Elasticsearch 版本相容性的間隔
elasticsearch.healthCheck.delay: 2500
# 預設。對每個 Elasticsearch 節點最多開幾條 socket（8.x 起預設 800；舊文件寫的 Infinity 在 9.5 會因型別錯誤拒絕啟動）
elasticsearch.maxSockets: 800
# 預設。最多保留幾條閒置 socket
elasticsearch.maxIdleSockets: 256
# 預設。閒置 socket 多久後關閉
elasticsearch.idleSocketTimeout: "60s"
# 預設。請求與回應不壓縮；Kibana 和 Elasticsearch 在同一個內網時壓縮只會多耗 CPU
elasticsearch.compression: false
# 預設。不在啟動時自動探索節點：sniff 會拿 Elasticsearch 回報的 publish_address（IP）去連，
# 和 verificationMode: full + 憑證主機名搭配容易出錯，也會把請求送到 master-only 節點
elasticsearch.sniffOnStart: false
# 預設。不定期重新探索
elasticsearch.sniffInterval: false
# 預設。連線失敗時不重新探索
elasticsearch.sniffOnConnectionFault: false
# 預設。轉送給 Elasticsearch 的使用者請求標頭（使用者以自己的身分查詢）
elasticsearch.requestHeadersWhitelist: [ "authorization", "es-client-authentication" ]

#------------------------------------------------------------------------------
# 儲存物件（儀表板、視覺化、data view 等，存在 .kibana* 系統索引）
#------------------------------------------------------------------------------
# 預設（26214400 = 25 MB）。匯入 ndjson 檔案的大小上限
savedObjects.maxImportPayloadBytes: 26214400
# 預設。單次匯入 / 匯出的物件數上限
savedObjects.maxImportExportSize: 10000

#------------------------------------------------------------------------------
# 登入工作階段
#------------------------------------------------------------------------------
# 建議（預設 3d）。閒置多久後要重新登入；預設 3 天對共用電腦太長，改成一個工作天
xpack.security.session.idleTimeout: "8h"
# 預設。不論是否閒置，登入後最長多久要重新登入
xpack.security.session.lifespan: "30d"
# 預設。多久清一次 .kibana_security_session 索引裡過期的 session
xpack.security.session.cleanupInterval: "1h"

#------------------------------------------------------------------------------
# 背景工作（告警規則、報表、遙測等都由 Task Manager 執行）
#------------------------------------------------------------------------------
# 預設。每台 Kibana 同時執行的工作量上限；規則很多、/api/task_manager/_health 顯示積壓時才調大（或加一台 Kibana）
xpack.task_manager.capacity: 10
# 預設（毫秒）。多久向 .kibana_task_manager 索引領一次工作；9.x 的預設領取方式 claim_strategy: mget 搭配 500，
# 舊版（update_by_query）才是 3000，照舊文章改成 3000 會讓排程工作延遲
xpack.task_manager.poll_interval: 500
# 預設。告警規則最短的執行間隔；enforce 預設 false，比這更短的規則只會出現警告、仍可建立，要強制擋下需另設 enforce: true
xpack.alerting.rules.minimumScheduleInterval.value: "1m"

#------------------------------------------------------------------------------
# 報表（CSV 匯出）
#------------------------------------------------------------------------------
# 預設（250 MB）。產生的 CSV 檔大小上限
xpack.reporting.csv.maxSizeBytes: 262144000
# 預設。CSV 匯出時每批向 Elasticsearch 取幾筆
xpack.reporting.csv.scroll.size: 500
# 預設。每批 scroll / point-in-time 的保留時間
xpack.reporting.csv.scroll.duration: "120s"
# 預設。一個報表工作的執行上限
xpack.reporting.queue.timeout: "4m"

#------------------------------------------------------------------------------
# 搜尋列的自動完成（輸入欄位值時的建議，每次按鍵都會對 Elasticsearch 查詢）
#------------------------------------------------------------------------------
# 預設（毫秒）。自動完成查詢的逾時
unifiedSearch.autocomplete.valueSuggestions.timeout: 1000
# 預設。每個分片最多掃描幾筆就停止（資料量大時自動完成仍然很快）
unifiedSearch.autocomplete.valueSuggestions.terminateAfter: 100000

#------------------------------------------------------------------------------
# 運維
#------------------------------------------------------------------------------
# 預設（毫秒）。收集 Kibana 本身指標（event loop delay、heap、請求數）的間隔，/api/status 的 metrics 來自這裡
ops.interval: 5000
# 建議（預設 true）。內網主機不往外回傳使用資料
telemetry.optIn: false
# 建議（預設 true）。不讓使用者在畫面上把 telemetry 打開
telemetry.allowChangingOptInStatus: false
# 建議（預設 true）。不從外部網站抓新聞（內網連不出去時，畫面會一直等）
newsfeed.enabled: false
# 預設。介面語言（內建 en、zh-CN、ja-JP、fr-FR、de-DE，沒有繁體中文）
i18n.defaultLocale: "en"
# 必要（RPM 預設）
path.data: /var/lib/kibana
# 必要（RPM 預設）
pid.file: /run/kibana/kibana.pid

#------------------------------------------------------------------------------
# 日誌
#------------------------------------------------------------------------------
# 建議（RPM 預設是 type: file，檔案會無限長大）。改成依大小輪替：每個 256 MB、保留 10 個，JSON 格式
logging:
  appenders:
    file:
      type: rolling-file
      fileName: /var/log/kibana/kibana.log
      policy:
        type: size-limit
        size: 256mb
      strategy:
        type: numeric
        max: 10
      layout:
        type: json
  root:
    appenders: [ default, file ]
    # 預設
    level: info
```

幾個重點：

- **Kibana 的設定 schema 是嚴格的**：拼錯、不存在、型別錯誤的參數都會讓 Kibana 拒絕啟動（見測試 3），和 Elasticsearch 一樣不會默默忽略。網路上舊文章常見的 `elasticsearch.maxSockets: Infinity` 在 9.5 會直接 FATAL（YAML 把 `Infinity` 讀成字串），預設值其實是 800。
- **舊版的參數名稱與預設值**：`i18n.locale` 在 9.x 改名為 `i18n.defaultLocale`，`elasticsearch.pingTimeout` 已經不再使用，舊名稱只會記一筆 deprecation 警告；Task Manager 在 9.x 改用 `mget` 領取工作，`poll_interval` 的預設值從 3000 變成 500。**從舊版複製過來的 `kibana.yml` 要逐項重新核對**，不要把舊的預設值寫死。
- 真正需要調整的效能參數其實不多：`server.protocol: http2`（瀏覽器載入大量 bundle 時差異最明顯）、heap、日誌輪替；其餘大多是預設值。Kibana 慢的時候，十之八九是背後的 Elasticsearch 查詢慢（大範圍的時間區間、高基數的 terms 聚合），先看[效能調校]({% post_url 2026-10-24-elasticsearch-ops-05-performance-tuning %})的慢日誌與 profile，而不是調大 `requestTimeout`。
- `elasticsearch.hosts` 列出全部三台：Kibana 會輪流送出請求、跳過連不上的節點（測試 2）。大型叢集可以改指向 2～3 台專用的 coordinating-only 節點。sniff 系列維持關閉。

## 步驟 4：keystore 與加密金鑰

密碼與加密金鑰放在 `kibana-keystore`，不要寫在 `kibana.yml`：

```console
[kb1]# cd /usr/share/kibana && echo 'ChangeMe_Kibana_2026' | bin/kibana-keystore add elasticsearch.password --stdin && bin/kibana-keystore list
elasticsearch.password
```

Kibana 有三把加密金鑰，沒有設定時每次啟動都會**隨機產生**一把，重新啟動後就對不上：

| 參數 | 用途 | 沒設的後果 |
| :--- | :--- | :--- |
| `xpack.encryptedSavedObjects.encryptionKey` | 加密告警規則、連接器（connector）的密碼與 API key | 重新啟動後告警規則無法執行、連接器要重新輸入密碼 |
| `xpack.security.encryptionKey` | 加密使用者的工作階段 cookie | 重新啟動後所有人被登出；多台 Kibana 之間無法共用登入狀態 |
| `xpack.reporting.encryptionKey` | 加密報表工作裡的使用者憑證 | 重新啟動前排入的報表會失敗 |

用 `kibana-encryption-keys generate` 產生（輸出的 64 字元金鑰這裡省略），逐一加到 keystore：

```console
[kb1]# cd /usr/share/kibana && bin/kibana-encryption-keys generate -q
xpack.encryptedSavedObjects.encryptionKey: <隨機 64 字元，輸出省略>
xpack.reporting.encryptionKey: <隨機 64 字元，輸出省略>
xpack.security.encryptionKey: <隨機 64 字元，輸出省略>

[kb1]# cd /usr/share/kibana && grep -E "^xpack\.[a-zA-Z.]+encryptionKey: " /root/kb-keys.txt | while IFS=": " read -r key val; do echo "$val" | tr -d "\r" | bin/kibana-keystore add "$key" --stdin -x >/dev/null && echo "added $key"; done; bin/kibana-keystore list; ls -l /etc/kibana/kibana.keystore; rm -f /root/kb-keys.txt
added xpack.encryptedSavedObjects.encryptionKey
added xpack.reporting.encryptionKey
added xpack.security.encryptionKey
elasticsearch.password
xpack.encryptedSavedObjects.encryptionKey
xpack.reporting.encryptionKey
xpack.security.encryptionKey
-rw-rw---- 1 root kibana 602 Oct 25 06:13 /etc/kibana/kibana.keystore
```

> **加密金鑰要另外備份**（放在密碼管理系統）。Kibana 主機重建時要放回同一組金鑰，否則 `.kibana*` 索引裡已加密的連接器密碼、告警規則的 API key 就解不開了；多台 Kibana 必須用**同一組**金鑰。金鑰不能直接換掉，要輪替時先把舊金鑰放到 `xpack.encryptedSavedObjects.keyRotation.decryptionOnlyKeys`。
{: .prompt-warning }

## 步驟 5：heap（node.options）

Kibana 是 Node.js 程式，記憶體上限由 V8 的 `--max-old-space-size` 決定，寫在 `/etc/kibana/node.options`。在 RPM 原本的內容最後加上：

```text
# 附加到 /etc/kibana/node.options 的最後（RPM 原本的內容保留）
# 建議（預設由 Node.js 依機器記憶體決定，實測 7.9 GB 的機器是 2240 MB）。Kibana（Node.js）的 V8 heap 上限，單位 MB；
# 4 GB 的 Kibana 主機給 2 GB，其餘留給 OS 與 Node.js heap 以外的記憶體。heap 用完時 Kibana 會直接當掉重啟
--max-old-space-size=2048
```

```console
[kb1]# cat /etc/kibana/node.options
## Node command line options
## See `node --help` and `node --v8-options` for available options
## Please note you should specify one option per line

## max size of old space in megabytes
#--max-old-space-size=4096

## do not terminate process on unhandled promise rejection
 --unhandled-rejections=warn

## restore < Node 16 default DNS lookup behavior
--dns-result-order=ipv4first

# 實測環境（Docker VM 記憶體有限），文章的設定是 2048
--max-old-space-size=1024
```

- 不設定時由 Node.js 依機器記憶體決定（實測在 7.9 GB 的機器上是 2240 MB），和 Elasticsearch 的 heap 一樣，**明確寫出來**比較好掌握。
- 啟動後 Kibana 本身就用掉約 750 MB heap、整個服務約 1.2 GB 記憶體（見下方 `systemctl status` 與 `/api/status`），所以低於 1 GB 會很危險；heap 用完時 Kibana 會直接 crash，由 systemd 重新啟動。
- RPM 升級時，改過的 `node.options` 會保留，新版的檔案另存為 `node.options.rpmnew`（下方 8.19 對照的降版也是如此）。

## 步驟 6：啟動

```console
[kb1]# systemctl daemon-reload && systemctl enable -q kibana && systemctl start kibana && systemctl is-active kibana
active

（Kibana available：等了 16 秒）
第一次啟動到 available：16 秒
[kb1]# systemctl status kibana --no-pager | head -12
● kibana.service - Kibana
     Loaded: loaded (/usr/lib/systemd/system/kibana.service; enabled; preset: disabled)
     Active: active (running) since Sun 2026-10-25 06:13:57 UTC; 15s ago
       Docs: https://www.elastic.co
   Main PID: 365 (MainThread)
      Tasks: 11 (limit: 51007)
     Memory: 1.2G (peak: 1.2G)
        CPU: 23.595s

[kb1]# ss -ltnp | grep 5601
LISTEN 0      511    192.168.60.51:5601       0.0.0.0:*    users:(("MainThread",pid=365,fd=21))
```

第一次啟動時，Kibana 在 Elasticsearch 上建立自己的系統索引（saved objects migration），從 `kibana.log` 可以看到整個過程：

```console
[kb1]# grep -oE "\"message\":\"[^\"]{0,240}" /var/log/kibana/kibana.log | sed "s/\"message\":\"//" | grep -iE "http server running|starting|kibana is now|deprecat|warn|elasticsearch|migrat|ready|config" | head -40
Kibana is starting
Kibana process configured with roles: [background_tasks, ui]
http server running at https://192.168.60.51:5601
Telemetry collection is disabled. For more information on telemetry settings, refer to https://www.elastic.co/docs/reference/kibana/configuration-reference/telemetry-settings.
Registering Cases Templates V2 Migration Task
Successfully connected to Elasticsearch after waiting for 569 milliseconds
Waiting until all Elasticsearch nodes are compatible with Kibana before starting saved objects migrations...
Starting saved objects migrations
[.kibana_analytics] CREATE_NEW_TARGET -> CHECK_VERSION_INDEX_READY_ACTIONS. took: 541ms.
（中略）
[.kibana] Migration completed after 951ms
[.kibana_ingest] Migration completed after 1021ms
[.kibana_task_manager] Migration completed after 1107ms
[.kibana_usage_counters] Migration completed after 1129ms
```

- `configured with roles: [background_tasks, ui]`：一台 Kibana 同時服務使用者（ui）與執行背景工作（告警、報表）。Kibana 很多台時可以用 `node.roles` 分開，本文不需要。
- 先檢查**所有 Elasticsearch 節點的版本都相容**才開始 migration，這就是「Kibana 不能比 Elasticsearch 新」的檢查點。
- **沒有任何設定相關的 deprecation 警告**：改用 `i18n.defaultLocale`、拿掉 `elasticsearch.pingTimeout` 之後就乾淨了。

啟動時的 WARN / ERROR 都和本文的設定無關（基本授權沒有 AI Assistant、某些外掛的索引第一次啟動還不存在），可以忽略：

```console
[kb1]# grep -E "\"log\":\{\"level\":\"(WARN|ERROR|FATAL)\"" /var/log/kibana/kibana.log | grep -oE "\"logger\":\"[^\"]+\"|\"message\":\"[^\"]{0,200}" | paste - - | sort | uniq -c | sort -rn | head -20
      1 "message":"Error rolling over workflows data stream .workflows-events: index_not_found_exception（後略）	"logger":"plugins.workflowsExecutionEngine.data-stream-rollover"
      1 "message":"Error initializing AI assistant resources: Platinum, Enterprise or trial license needed	"logger":"plugins.elasticAssistant.service"
      1 "message":"Could not check status of cases:cases_incremental_id_assignment, will continue scheduling it.	"logger":"plugins.cases.incremental_id_task"
      1 "message":"Agent builder failed to register sample data links for logstsdb	"logger":"plugins.agentBuilder"
```

## 步驟 7：驗證

### 狀態

`/api/status` 是 Kibana 的健康檢查端點，負載平衡的 health check 也用它：

```console
[kb1] GET /api/status
（jq：{name, version: .version.number, overall: .status.overall, core: .status.core}）
{
  "name": "kb1",
  "version": "9.5.5",
  "overall": {
    "level": "available",
    "summary": "All services and plugins are available"
  },
  "core": {
    "elasticsearch": {
      "level": "available",
      "summary": "Elasticsearch is available",
      "meta": {
        "warningNodes": [],
        "incompatibleNodes": []
      }
    },
    "savedObjects": {
      "level": "available",
      "summary": "SavedObjects service has completed migrations and is available",
      "meta": {
        "migratedIndices": {
          "migrated": 0,
          "skipped": 0,
          "patched": 8
        }
      }
    }
  }
}

[kb1] GET /api/status
（jq：.metrics | {last_updated, collection_interval_in_millis, process: {memory: .process.memory.heap, event_loop_delay: .process.event_loop_delay, uptime_ms: .process.uptime_in_millis}, os_load: .os.load, requests: .requests, response_times: .response_times, concurrent_connections}）
{
  "last_updated": "2026-10-25T06:14:12.662Z",
  "collection_interval_in_millis": 5000,
  "process": {
    "memory": {
      "total_in_bytes": 980303872,
      "used_in_bytes": 753167848,
      "size_limit": 1275068416
    },
    "event_loop_delay": 1465.909247,
    "uptime_ms": 14851.942672
  },
  "os_load": {
    "1m": 1.29,
    "5m": 1.33,
    "15m": 1.06
  },
  ...
}
```

- `metrics` 每 `ops.interval`（5 秒）更新一次。要監控的是 **heap 使用率**（`used_in_bytes / size_limit`）與 **event loop delay**。event loop delay 是 Node.js 的「排隊時間」，平常應該是個位數到數十毫秒；這裡的 1465 ms 是剛啟動、正在做 migration 的時候，持續偏高代表 Kibana 的 CPU 不夠。
- `size_limit` 1275068416 bytes ≈ 1216 MB，就是 `--max-old-space-size=1024` 再加上 V8 的其他 heap 空間，證明 `node.options` 有生效。

沒有帶帳號的請求只會拿到整體狀態（`status.allowAnonymous` 預設 `false`，細節要登入才看得到），剛好適合給負載平衡的 health check 用：

```console
[kb1]# curl -sS -w '\nHTTP %{http_code}\n' --cacert /etc/kibana/certs/ca.crt https://kb1:5601/api/status | cut -c1-300
{"status":{"overall":{"level":"available"}}}
HTTP 200
```

### TLS 與 HTTP/2

```console
[kb1]# curl -sS -o /dev/null -w 'http_version=%{http_version}\n' --http2 --cacert /etc/kibana/certs/ca.crt -u 'elastic:ChangeMe_Elastic_2026' https://kb1:5601/api/status; for v in 1.1 1.2 1.3; do printf 'TLSv%s: ' $v; openssl s_client -connect kb1:5601 -CAfile /etc/kibana/certs/ca.crt -tls${v/./_} -cipher 'DEFAULT:@SECLEVEL=0' </dev/null 2>&1 | grep -q 'Cipher is (NONE)' && echo rejected || echo ok; done
http_version=2
TLSv1.1: rejected
TLSv1.2: ok
TLSv1.3: ok
```

HTTP/2 生效；TLS 1.1 被 Kibana 拒絕（`server.ssl.supportedProtocols` 的預設值就只有 1.2 / 1.3）。

### Kibana 在 Elasticsearch 上建立的系統索引

```console
[esc1] GET /_cat/indices/.kibana*,.kibana_task_manager*,.kibana_security_session*?v&h=index,health,pri,rep,docs.count,store.size&expand_wildcards=all&s=index
index                                      health pri rep docs.count store.size
.kibana-siem-rule-migrations-integrations  green    1   1          0       454b
.kibana-siem-rule-migrations-prebuiltrules green    1   1          0       454b
.kibana_9.5.5_001                          green    1   1          4      8.9kb
.kibana_alerting_cases_9.5.5_001           green    1   1          1       454b
.kibana_analytics_9.5.5_001                green    1   1          5       454b
.kibana_ingest_9.5.5_001                   green    1   1          1       454b
.kibana_locks-000001                       green    1   1          3     25.5kb
.kibana_search_solution_9.5.5_001          green    1   1          0       454b
.kibana_security_session_1                 green    1   1          0       454b
.kibana_security_solution_9.5.5_001        green    1   1          3       454b
.kibana_task_manager_9.5.5_001             green    1   1         61     50.3kb
.kibana_usage_counters_9.5.5_001           green    1   1          6       454b


[esc1] GET /_cat/aliases/.kibana*?v&h=alias,index&expand_wildcards=all&s=alias
alias                           index
.kibana                         .kibana_9.5.5_001
.kibana_9.5.5                   .kibana_9.5.5_001
.kibana_analytics               .kibana_analytics_9.5.5_001
（中略）
.kibana_task_manager            .kibana_task_manager_9.5.5_001
.kibana_task_manager_9.5.5      .kibana_task_manager_9.5.5_001
```

- 索引名稱帶著**版本號**（`_9.5.5_001`），Kibana 透過不帶版本的別名讀寫。升級 Kibana 時 migration 會建立新版本的索引、搬移別名，這也是 Kibana 不能降版的原因（見下方的 8.19 對照）。
- 全部都是 1 主分片 + 1 副本，green。這些是系統索引，**不要手動修改或刪除**；備份用快照的 `kibana` feature state。

Kibana 和每台 Elasticsearch 都維持幾十條 keep-alive 連線（`elasticsearch.maxSockets` 的上限是每台 800）：

```console
[esc1] GET /_nodes/stats/http?filter_path=nodes.*.name,nodes.*.http.current_open,nodes.*.http.total_opened&pretty
{
  "nodes" : {
    "-ACzG1zdS0qb7BBXcLvxhQ" : { "name" : "esc1", "http" : { "current_open" : 49, "total_opened" : 71 } },
    "vPxXdnxKRfmUW7crFcOZ5A" : { "name" : "esc3", "http" : { "current_open" : 46, "total_opened" : 46 } },
    "05i5USx2St26-BK-CK1iDQ" : { "name" : "esc2", "http" : { "current_open" : 47, "total_opened" : 47 } }
  }
}
```

三台的連線數平均分配，證明 `elasticsearch.hosts` 的三台都有在用。

### Task Manager

告警規則、報表、遙測等背景工作都由 Task Manager 執行，`/api/task_manager/_health` 會顯示**實際生效的設定**與容量估計：

```console
[kb1] GET /api/task_manager/_health
（jq：{status, last_update, configuration: .stats.configuration.value, runtime_status: .stats.runtime.status, capacity_estimation: .stats.capacity_estimation.value, workload_overdue: .stats.workload.value.overdue}）
{
  "status": "OK",
  "last_update": "2026-10-25T06:14:17.230Z",
  "configuration": {
    "request_capacity": 1000,
    "monitored_aggregated_stats_refresh_rate": 60000,
    "monitored_stats_running_average_window": 50,
    "monitored_task_execution_thresholds": {
      "custom": {},
      "default": {
        "error_threshold": 90,
        "warn_threshold": 80
      }
    },
    "claim_strategy": "mget",
    "poll_interval": 500,
    "capacity": {
      "config": 10,
      "as_workers": 10,
      "as_cost": 20
    }
  },
  "runtime_status": "OK",
  "capacity_estimation": {
    "observed": {
      "observed_kibana_instances": 1,
      "max_throughput_per_minute_per_kibana": 1200,
      "max_throughput_per_minute": 1200,
      "minutes_to_drain_overdue": 37,
      "avg_recurring_required_throughput_per_minute": 19,
      "avg_recurring_required_throughput_per_minute_per_kibana": 19,
      "avg_required_throughput_per_minute": 67,
      "avg_required_throughput_per_minute_per_kibana": 67
    },
    "proposed": {
      "provisioned_kibana": 2,
      "min_required_kibana": 1,
      "avg_recurring_required_throughput_per_minute_per_kibana": 10,
      "avg_required_throughput_per_minute_per_kibana": 34
    }
  },
  "workload_overdue": 37
}
```

- `claim_strategy: mget`、`poll_interval: 500`、`capacity.config: 10`：和 `kibana.yml` 寫的一致，也證明 9.5 的 `poll_interval` 預設是 500，不是舊文件寫的 3000。
- `workload_overdue: 37`：剛啟動時第一次排程的工作一起到期，屬於正常現象；平常持續不為 0、`capacity_estimation` 的 `min_required_kibana` 大於現有台數時，才需要調大 `capacity` 或加一台 Kibana。這個 API 適合接到監控（[監控與告警]({% post_url 2026-10-24-elasticsearch-ops-04-monitoring %})）。

### 建立 data view 與查詢

```console
[kb1] POST /api/data_views/data_view
{"data_view":{"title":"orders*","name":"orders","timeFieldName":"created_at"}}
（jq：{id: .data_view.id, title: .data_view.title, timeFieldName: .data_view.timeFieldName, fields: (.data_view.fields | length)}）
{
  "id": "41adc2f5-3be8-4db8-a5d9-2b7f17ae6b64",
  "title": "orders*",
  "timeFieldName": "created_at",
  "fields": 14
}

[kb1] POST /api/console/proxy?path=%2Forders%2F_count&method=GET
{
  "count": 50000,
  "_shards": {
    "total": 3,
    "successful": 3,
    "skipped": 0,
    "failed": 0
  }
}

[kb1] GET /api/saved_objects/_find?type=index-pattern&fields=title
（jq：{total, saved_objects: [.saved_objects[] | {id, type, title: .attributes.title, namespaces}]}）
{
  "total": 1,
  "saved_objects": [
    {
      "id": "41adc2f5-3be8-4db8-a5d9-2b7f17ae6b64",
      "type": "index-pattern",
      "title": "orders*",
      "namespaces": [
        "default"
      ]
    }
  ]
}
```

- Kibana 的 REST API 都要帶 `kbn-xsrf` 標頭（任意值），否則寫入類的請求會被拒絕。
- `/api/console/proxy` 是 Dev Tools Console 背後的 API；9.x 對這類內部 API 多了限制，從外部呼叫時要再帶 `x-elastic-internal-origin: kibana`，否則回 400。一般操作直接用瀏覽器的 Dev Tools 就好。
- data view 存成 saved object（型別仍叫 `index-pattern`），放在 `.kibana_analytics` 索引裡。

## 測試

### 測試 1：重新啟動所需時間

```console
[kb1]# systemctl restart kibana && echo restarted
restarted

（Kibana available：等了 14 秒）
systemctl restart 到 available：16 秒
```

已經有 `.kibana*` 索引時 migration 幾乎不用時間（`patched`），重新啟動約 16 秒，和第一次啟動差不多。改 `kibana.yml` 的維護窗口抓 1 分鐘就夠；要完全不中斷就放兩台 Kibana、輪流重啟。

### 測試 2：Elasticsearch 節點故障

停掉 `elasticsearch.hosts` 的第一台 `esc1`，每 5 秒透過 Kibana 查一次：

```console
[esc1]# systemctl stop elasticsearch && echo stopped
stopped

第 1 次：overall=available，透過 Kibana 查 orders/_count=50000，442 ms
第 2 次：overall=available，透過 Kibana 查 orders/_count=50000，244 ms
第 3 次：overall=available，透過 Kibana 查 orders/_count=50000，288 ms
第 4 次：overall=available，透過 Kibana 查 orders/_count=50000，241 ms
第 5 次：overall=available，透過 Kibana 查 orders/_count=50000，235 ms
第 6 次：overall=available，透過 Kibana 查 orders/_count=50000，207 ms
```

Kibana 的狀態一直是 `available`，查詢全部成功、沒有任何錯誤日誌：Kibana 的 Elasticsearch client 把連不上的節點標記為 dead、改送其他節點，節點恢復後自動再加回來。**`elasticsearch.hosts` 一定要列出多台**，只寫一台就等於讓 Kibana 綁在那台上。

接著把三台 Elasticsearch 全部停掉：

```console
[kb1] GET /api/status
（jq：{overall: .status.overall, elasticsearch: .status.core.elasticsearch}）
{
  "overall": {
    "level": "critical"
  },
  "elasticsearch": null
}

[kb1]# curl -sS -o /dev/null -w '%{http_code}\n' --cacert /etc/kibana/certs/ca.crt -u 'elastic:ChangeMe_Elastic_2026' https://kb1:5601/api/status; systemctl is-active kibana
503
active

（Kibana available：等了 41 秒）
Elasticsearch 重新啟動後 Kibana 恢復 available：41 秒（含叢集組成）
```

- Elasticsearch 全部不在時，`/api/status` 回 **HTTP 503**、`critical`，但 **Kibana 行程不會結束**，不需要人工重啟；Elasticsearch 回來後自己恢復（這次 41 秒，前一次 22 秒，大部分是叢集組成的時間）。
- 所以負載平衡用 `/api/status` 的 HTTP 狀態碼做 health check 就對了：503 會把這台 Kibana 摘掉。

### 測試 3：拼錯參數

在 `kibana.yml` 加一行拼錯的 `elasticsearch.requestTimout`（少了 `e`）：

```console
[kb1]# cp /etc/kibana/kibana.yml /root/kibana.yml.bak && echo "elasticsearch.requestTimout: 60000" >> /etc/kibana/kibana.yml && systemctl restart kibana; sleep 20; systemctl is-active kibana; journalctl -u kibana --no-pager --since -25s | grep -E "FATAL" | cut -c1-300 | head -3
failed
Oct 25 06:16:41 kb1 kibana[985]:  FATAL  Error: [config validation of [elasticsearch].requestTimout]: Additional properties are not allowed ('requestTimout' was unexpected)
Oct 25 06:16:48 kb1 kibana[1007]:  FATAL  Error: [config validation of [elasticsearch].requestTimout]: Additional properties are not allowed ('requestTimout' was unexpected)
Oct 25 06:16:54 kb1 kibana[1028]:  FATAL  Error: [config validation of [elasticsearch].requestTimout]: Additional properties are not allowed ('requestTimout' was unexpected)
```

- 拼錯的參數讓 Kibana **拒絕啟動**，systemd 每隔約 6 秒重試，最後放棄（`failed`）。錯誤訊息要看 journal（`journalctl -u kibana`）。
- 錯誤訊息有兩種：已知區塊裡不存在的參數是 `Additional properties are not allowed`，整個區塊都不存在（例如 8.x 不認得的 `i18n.defaultLocale`）是 `definition for this key is missing`；型別錯誤（`maxSockets: Infinity`）是 `expected value of type [number] but got [string]`。
- 修好之後先 `systemctl reset-failed kibana` 清掉失敗狀態再啟動。**改 `kibana.yml` 後一定要看 `systemctl is-active` 與 journal**，不要以為 restart 指令沒有報錯就是成功了。

## 對照：同一份 kibana.yml 放到 Kibana 8.19.23

Elasticsearch 維持 9.5.5，把 Kibana 降到 8.19.23（模擬「Kibana 升級後想退回」或「版本裝錯」）：

```console
[kb1]# systemctl stop kibana && cp /root/conf/elasticsearch-8.repo /etc/yum.repos.d/elasticsearch.repo && dnf downgrade -y -q --enablerepo=elasticsearch kibana-8.19.23 2>&1 | tail -3; rpm -q kibana; ls /etc/kibana; diff -q /root/conf/kibana.yml /etc/kibana/kibana.yml && echo "kibana.yml 保留"
Downgraded:
  kibana-8.19.23-1.aarch64

kibana-8.19.23-1.aarch64
certs
kibana.keystore
kibana.yml
kibana.yml.rpm
kibana.yml.rpmnew
node.options
node.options.rpmnew
kibana.yml 保留

[kb1]# S=$(date "+%F %T"); systemctl start kibana; sleep 60; systemctl is-active kibana; journalctl -u kibana --no-pager --since "$S" | grep -E "FATAL" | cut -c1-400 | head -3
failed
Oct 25 06:19:32 kb1 kibana[1221]:  FATAL  Error: [config validation of [i18n].defaultLocale]: definition for this key is missing
```

第一關是**設定檔**：8.19 不認得 9.x 的 `i18n.defaultLocale`。換回 8.x 的名稱 `i18n.locale` 再啟動：

```console
[kb1]# sed -i "s/^i18n.defaultLocale:/i18n.locale:/" /etc/kibana/kibana.yml && grep -n "^i18n" /etc/kibana/kibana.yml; systemctl reset-failed kibana; S=$(date "+%F %T"); systemctl start kibana; sleep 60; systemctl is-active kibana; journalctl -u kibana --no-pager --since "$S" | grep -E "FATAL" | cut -c1-400 | head -3
144:i18n.locale: "en"
failed
Oct 25 06:20:35 kb1 kibana[1298]: [2026-10-25T06:20:35.495+00:00][INFO ][savedobjects-service] [.kibana_task_manager] INIT -> FATAL. took: 10ms.
Oct 25 06:20:35 kb1 kibana[1298]: [2026-10-25T06:20:35.496+00:00][FATAL][root] Reason: Unable to complete saved object migrations for the [.kibana_task_manager] index: The .kibana_task_manager alias is pointing to a newer version of Kibana: v9.5.5
```

第二關是**資料**：`.kibana*` 的別名已經指向 9.5.5 的索引，8.19 拒絕使用。結論：

- 除了 `i18n.defaultLocale`，本文 `kibana.yml` 的其他參數 8.19 都認得（設定檔驗證只擋下這一個）。
- **Kibana 和 Elasticsearch 一樣不能降版**：新版 Kibana 第一次啟動就把 `.kibana*` 索引 migrate 到新版本。要退回只能從升級前的快照還原 `kibana` feature state，所以**升級 Kibana 前也要先做快照**。
- RPM 降版 / 升級時，改過的 `kibana.yml`、`node.options` 會保留，新版的預設檔另存為 `.rpmnew`。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `FATAL ... [elasticsearch].maxSockets]: expected value of type [number] but got [string]` | 照舊文件寫了 `maxSockets: Infinity`，YAML 把它讀成字串 | 9.5 的預設值是 800，寫數字或不寫 |
| 啟動時 deprecation：`"elasticsearch.pingTimeout" is deprecated and no longer used` | 9.x 不再使用 pingTimeout | 拿掉，用 `requestTimeout` |
| 啟動時 deprecation：`"i18n.locale" has been replaced by "i18n.defaultLocale"` | 9.x 改名 | 改用新名稱；但 8.x 不認得新名稱 |
| `poll_interval` 照舊文件寫 3000，排程工作延遲 | 9.x 改用 `mget` 領取工作，預設 500 | 不要寫死舊版的預設值 |
| `/api/console/proxy` 回 400 `exists but is not available with the current configuration` | 9.x 限制外部呼叫內部 API | 加 `x-elastic-internal-origin: kibana` 標頭，或改用瀏覽器的 Dev Tools |
| 不帶帳號的 `/api/status` 回 200 而不是 401 | 只回整體狀態，細節要登入 | 正好拿來當 health check |
| 容器內的 `openssl s_client -tls1_1` 一律失敗，看不出是誰拒絕 | Rocky 9 的 crypto policy 讓 openssl **用戶端**本身就不送 TLS 1.1 | 測試時加 `-cipher 'DEFAULT:@SECLEVEL=0'`，才能確認是 Kibana 拒絕 |
| 降到 8.19 後 FATAL：`alias is pointing to a newer version of Kibana: v9.5.5` | `.kibana*` 已經 migrate 到 9.5.5 | 不能降版，只能從快照還原 `kibana` feature state |

## 驗證方式與結果

驗證環境、建置檔與 `compose.yaml` 和[單節點]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})相同，`kb1` 使用還沒安裝任何 Elastic 套件的 `eslab-rocky9-base` 映像，現場照步驟 1 安裝。執行 `./50-kibana.sh`，輸出記錄在 `results/50-kibana.log`。

**預設值怎麼核對的**：Elasticsearch 可以用 `GET _cluster/settings?include_defaults` 列出所有預設值，Kibana 沒有這種 API。所以改用兩個方法：

1. `bin/kibana-defaults.js` 在 `kb1` 上用 Kibana 內附的 Node.js，載入 `/usr/share/kibana` 裡各模組的設定 schema（`@kbn/config-schema` 物件），對空的設定 `validate({})`，取得 9.5.5 實際套用的預設值，一共 811 項（`results/kibana-defaults-9.5.5.txt`）。核心的 `server.*`、`elasticsearch.*`、`savedObjects.*`、`ops.*`、`i18n.*` 都由此直接取得。
2. 外掛的設定（`xpack.*`、`telemetry.*`、`newsfeed.*`、`unifiedSearch.*`）與 `path.data` 等，在安裝目錄的原始碼裡逐一找到 schema 定義核對。`kibana.yml` 每一個參數的預設值與來源檔案列在 `results/kibana-defaults-check.txt`。

另外，Kibana 的 schema 會拒絕不存在的參數（測試 3），所以「能啟動、而且沒有 deprecation 警告」本身就證明了每個參數名稱都是 9.5.5 認得的；Task Manager 的設定也由 `/api/task_manager/_health` 回報的實際值再確認一次。

| 項目 | 怎麼驗證 | 判定通過的條件 | 結果 |
| :--- | :--- | :--- | :--- |
| 安裝 | `dnf install kibana-9.5.5` | 套件與 systemd unit 就緒 | ✅ |
| 設定檔 | 啟動、journal、`kibana.log` | 沒有 FATAL、沒有設定相關的 deprecation | ✅（修正 7 處後） |
| 預設值 | schema `validate({})` + 原始碼 | 標「預設」的值 = 9.5.5 預設值 | ✅ 54 項逐一核對 |
| TLS | `curl --http2`、`openssl s_client` | HTTP/2、TLS 1.2 / 1.3 可用、1.1 被拒 | ✅ |
| 連線 | `/api/status`、`_nodes/stats/http` | `available`、三台都有連線 | ✅ |
| 功能 | data view、Console 查詢、saved objects | 建立與查詢成功 | ✅ |
| Task Manager | `/api/task_manager/_health` | `OK`、設定值與 `kibana.yml` 相同 | ✅ |
| 啟動時間 | 計時到 `available` | 記錄 | ✅ 第一次 16 秒、重啟 16 秒 |
| 節點故障 | 停 `esc1` | Kibana 維持 `available`、查詢成功 | ✅ 6 / 6 |
| 全部故障 | 停 3 台 | 503、行程不結束、自動恢復 | ✅ 41 秒恢復 |
| 拼錯參數 | 加一行錯字 | 拒絕啟動並指出參數 | ✅ |
| 8.19 對照 | `dnf downgrade kibana-8.19.23` | 記錄結果 | ✅ 確認無法降版 |

**錯誤處理紀錄**：

- 第一次執行時 Kibana 拒絕啟動（`maxSockets: Infinity` 型別錯誤）；以 9.5.5 的 schema 逐一核對整份 `kibana.yml`，修正了 7 處（`maxSockets`、`pingTimeout`、`i18n.locale`、`poll_interval`、`csv.scroll.duration` 的值與名稱，`session.idleTimeout`、`ssl.supportedProtocols` 的標記），之後完整重跑兩次。
- 第二次執行時發現兩個測試腳本的問題：TLS 版本檢查一律顯示 ok（grep 到錯誤的行），以及 Console proxy 回 400 讓故障測試的查詢結果是空的；修正後第三次完整重跑，本文的輸出都來自第三次。
- 第三次的數字和第二次相近：第一次啟動 16 秒（第二次 15 秒）、重啟 16 秒（15 秒）、全部故障後恢復 41 秒（22 秒）。

## 版本差異比較：8.19 → 9.5 的 Kibana

| 項目 | 8.19 | 9.5 | 要做什麼 |
| :--- | :--- | :--- | :--- |
| 介面語言參數 | `i18n.locale` | `i18n.defaultLocale`（舊名稱仍可用但有 deprecation） | 升級後改名；8.x 不認得新名稱 |
| `elasticsearch.pingTimeout` | 有作用 | 不再使用（deprecation） | 拿掉 |
| Task Manager 領取方式 | `update_by_query`（`poll_interval` 預設 3000） | `mget`（`poll_interval` 預設 500） | 拿掉設定檔裡寫死的 3000 |
| 內部 API（`/api/console/proxy` 等） | 外部可直接呼叫 | 要 `x-elastic-internal-origin` 標頭 | 自動化腳本改用公開 API |
| `.kibana*` 索引 | `_8.19.23_001` | `_9.5.5_001` | 升級前快照；不能降版 |
| 版本相容 | 只能連 8.19 的 Elasticsearch | 只能連 9.5 的 Elasticsearch | Elasticsearch 全部升完才升 Kibana |

## 小結

- Kibana 和 Elasticsearch 用同一個套件庫，`dnf install kibana-<版本>`，**版本和 Elasticsearch 一樣**，最後才升級。
- 連線用 `kibana_system`（或服務帳號 token），密碼放 `kibana-keystore`；**三把加密金鑰**一定要設定、另外備份，多台 Kibana 共用同一組。
- TLS 兩段都開：瀏覽器 → Kibana 用 `server.ssl.*`（加上 `server.protocol: http2`），Kibana → Elasticsearch 用 CA 驗證 + `verificationMode: full`。
- `elasticsearch.hosts` 列出多台：實測停掉一台完全無感；全部停掉時 `/api/status` 回 503、Elasticsearch 回來後自動恢復。
- `kibana.yml` 的 schema 是嚴格的，拼錯就不能啟動；**舊版文件的參數名稱與預設值在 9.5 已經變了**（`maxSockets`、`i18n.locale`、`pingTimeout`、`poll_interval`），要逐項核對。
- heap 用 `node.options` 的 `--max-old-space-size` 明確設定；監控 `/api/status` 的 heap 與 event loop delay、`/api/task_manager/_health`。
- **Kibana 也不能降版**：第一次啟動就 migrate 了 `.kibana*` 索引，升級前要快照。

### 參考資料

- [Elastic Docs：Install Kibana with RPM](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-kibana-with-rpm)
- [Elastic Docs：Kibana configuration reference](https://www.elastic.co/docs/reference/kibana/configuration-reference)
- [Elastic Docs：Upgrade Kibana](https://www.elastic.co/docs/deploy-manage/upgrade/deployment-or-cluster/kibana)
- [Elastic：Product compatibility matrix](https://www.elastic.co/support/matrix#matrix_compatibility)
