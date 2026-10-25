---
title: Elasticsearch 運維 07：安全與權限管理
date: 2026-10-24 17:00:00 +0800
categories: [Elasticsearch, 安全]
tags: [elasticsearch, elasticsearch9, elasticsearch8, security, tls, rbac, api-key, certutil, audit, license]
description: 以 Elasticsearch 9.5 為主，整理預設啟用的安全性與 auto-configuration、transport / HTTP 兩層 TLS 與憑證管理、內建使用者與 elastic 密碼、角色與最小權限、API key 與服務帳號、欄位與文件層級安全、稽核日誌與授權等級，並比較 8.19 的差異。
---

Elasticsearch 8.0 起**預設開啟安全性**：沒有 TLS、沒有帳號密碼的叢集已經是過去式。本篇從憑證、帳號、角色到稽核依序整理，最後比較 8.19 的差異。

{% include elasticsearch-ops-series.md %}

## 授權等級

| 功能 | Basic（免費） | Platinum | Enterprise |
| :--- | :--- | :--- | :--- |
| TLS（transport / HTTP）、帳號密碼、RBAC、API key | ✓ | ✓ | ✓ |
| 欄位與文件層級安全（FLS / DLS） | — | ✓ | ✓ |
| 稽核日誌（audit logging） | — | ✓ | ✓ |
| LDAP / AD / SAML / OIDC / Kerberos / PKI 單一登入 | 部分（file、native） | ✓ | ✓ |
| IP filtering | ✓ | ✓ | ✓ |

> 本系列的實作都用 Basic 授權；需要 Platinum 的功能（DLS、稽核）可以用 30 天試用（`POST _license/start_trial?acknowledge=true`）在測試環境驗證，**未在本系列實測**。
{: .prompt-info }

## 安全性的自動設定（auto-configuration）

用 RPM 安裝時，套件安裝腳本會自動：

1. 產生一個 CA 與 transport 層、HTTP 層的憑證，放在 `/etc/elasticsearch/certs/`（`http_ca.crt`、`http.p12`、`transport.p12`）。
2. 把憑證的密碼存進 keystore（`/etc/elasticsearch/elasticsearch.keystore`）。
3. 在 `elasticsearch.yml` 末尾加上 `xpack.security.*` 的設定區塊。
4. 產生 `elastic` 超級使用者的密碼，**只在安裝輸出中顯示一次**。

[單節點實作]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})保留了這份自動產生的憑證。多節點叢集如果每台各自 auto-configuration，每台會有不同的 CA，彼此無法建立 transport 連線，因此有兩種做法：

| 做法 | 說明 |
| :--- | :--- |
| enrollment token | 第一台啟動後執行 `elasticsearch-create-enrollment-token -s node`，其他節點用 `elasticsearch-reconfigure-node --enrollment-token <token>` 取得同一個 CA 簽的憑證 |
| **自建 CA（certutil）** | 用 `elasticsearch-certutil` 建立 CA 並為每個節點簽發憑證，自己決定 SAN、有效期限，可以納入既有的憑證管理流程 |

[三節點 Cluster 實作]({% post_url 2026-10-24-elasticsearch-lab-02-cluster %})用的是自建 CA，正式環境比較容易控管。

## 兩層 TLS

| 層 | port | 用途 | 是否可關閉 |
| :--- | :--- | :--- | :--- |
| transport | 9300 | 節點之間的通訊 | 多節點叢集**不能關**（安全性啟用時，非 loopback 的 transport 必須 TLS，否則 bootstrap check 失敗） |
| HTTP | 9200 | REST API（用戶端、Kibana、Beats） | 可以關，但帳號密碼會以明文傳送，不建議 |

### 用 certutil 建立 CA 與節點憑證

```bash
cd /usr/share/elasticsearch
# 1. CA（PEM 格式，私鑰要妥善保存，不要放在節點上）
sudo bin/elasticsearch-certutil ca --pem --days 3650 --out /root/es-ca.zip
sudo unzip /root/es-ca.zip -d /root/es-ca          # ca/ca.crt、ca/ca.key

# 2. 每個節點的憑證：SAN 要包含主機名、FQDN 與 IP
cat > /root/instances.yml <<'YML'
instances:
  - { name: esc1, dns: [esc1, esc1.example.local], ip: [192.168.60.21] }
  - { name: esc2, dns: [esc2, esc2.example.local], ip: [192.168.60.22] }
  - { name: esc3, dns: [esc3, esc3.example.local], ip: [192.168.60.23] }
YML
sudo bin/elasticsearch-certutil cert --pem --days 825 \
  --ca-cert /root/es-ca/ca/ca.crt --ca-key /root/es-ca/ca/ca.key \
  --in /root/instances.yml --out /root/es-certs.zip
```

```yaml
# elasticsearch.yml
xpack.security.enabled: true
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: full        # 驗證憑證與主機名
xpack.security.transport.ssl.key: certs/esc1.key
xpack.security.transport.ssl.certificate: certs/esc1.crt
xpack.security.transport.ssl.certificate_authorities: [ certs/ca.crt ]
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: certs/esc1.key
xpack.security.http.ssl.certificate: certs/esc1.crt
xpack.security.http.ssl.certificate_authorities: [ certs/ca.crt ]
```

- `verification_mode`：`full`（驗證主機名）> `certificate`（只驗證 CA，auto-configuration 用這個）> `none`（不要用）。
- 憑證路徑是相對於 `/etc/elasticsearch`。私鑰檔權限 `640 root:elasticsearch`。
- 正式環境 HTTP 層常改用公司 CA 或公開 CA 的憑證，讓瀏覽器與用戶端不必另外信任自建 CA；transport 層繼續用自建 CA。

### 憑證更新

```console
GET _ssl/certificates
```

列出每個節點載入的憑證與到期日。**Elasticsearch 會監看憑證檔案，換檔後自動重新載入**（`resource.reload.interval.high`，預設 5 秒），不需要重啟；但換 CA 時要先讓新舊 CA 同時被信任（`certificate_authorities` 放兩個），全部節點換完再移除舊 CA。

## 內建使用者

| 使用者 | 用途 |
| :--- | :--- |
| `elastic` | 超級使用者。**只用來建立其他帳號與緊急處理**，不要給應用程式用 |
| `kibana_system` | Kibana 連線 Elasticsearch（設定方式見[Kibana 安裝與設定]({% post_url 2026-10-24-elasticsearch-lab-04-kibana %})） |
| `logstash_system`、`beats_system`、`apm_system`、`remote_monitoring_user` | 各元件的監控資料 |

```bash
# 重設密碼（-i 互動輸入；不加則隨機產生）
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -i
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system
```

`elasticsearch-reset-password` 需要叢集正常運作，它會在本機建立一個暫時的 file realm 使用者去呼叫 API。

## 角色與最小權限

```console
PUT _security/role/orders_writer
{
  "cluster": ["monitor"],
  "indices": [
    { "names": ["orders-*"], "privileges": ["create_doc", "index", "view_index_metadata"] }
  ]
}

PUT _security/role/orders_reader
{
  "indices": [
    { "names": ["orders-*"], "privileges": ["read", "view_index_metadata"] }
  ]
}

PUT _security/user/order_api
{
  "password": "ChangeMe_OrderApi_2026",
  "roles": ["orders_writer", "orders_reader"],
  "full_name": "Order API service"
}

GET _security/user/_has_privileges
```

| 常用權限 | 說明 |
| :--- | :--- |
| `read` | 搜尋、GET |
| `create_doc` | 只能新增（不能覆寫），日誌寫入用這個最安全 |
| `index` / `write` | 新增與更新 / 新增、更新、刪除 |
| `manage` | 索引層級的管理（settings、mapping、刪除） |
| `monitor`（cluster） | 唯讀的叢集狀態與統計，監控帳號用 |
| `manage_ilm`、`manage_index_templates` | 給負責維運的帳號 |

- 帳號用途分開：應用程式寫入、應用程式查詢、監控、人員唯讀、維運，各自一個角色。
- 不要給應用程式 `superuser` 或 `all`。
- 角色也可以寫在 `/etc/elasticsearch/roles.yml`（file-based），適合用設定管理工具部署，但只對該節點有效、每台都要放。

## API key 與服務帳號

**應用程式優先用 API key**，而不是帳號密碼：

```console
POST _security/api_key
{
  "name": "order-api-prod",
  "expiration": "90d",
  "role_descriptors": {
    "orders_rw": {
      "indices": [ { "names": ["orders-*"], "privileges": ["read", "create_doc"] } ]
    }
  },
  "metadata": { "owner": "order-team" }
}

# 用戶端：Authorization: ApiKey <encoded>
GET _security/api_key?name=order-api-prod
DELETE _security/api_key
{ "name": "order-api-prod" }
```

- API key 有到期日、可以個別撤銷、權限不能超過建立者。
- **Kibana、Fleet Server** 用服務帳號（service account）的 token：`elasticsearch-service-tokens create elastic/kibana kibana-token`，比 `kibana_system` 密碼更好管理。

## 欄位與文件層級安全（Platinum）

```console
PUT _security/role/orders_tw_only
{
  "indices": [
    {
      "names": ["orders-*"],
      "privileges": ["read"],
      "query": { "term": { "region": "tw" } },
      "field_security": { "grant": ["*"], "except": ["customer.id_number", "customer.phone"] }
    }
  ]
}
```

DLS 的查詢會套用在每次搜尋上，複雜的 DLS 查詢會影響效能；也會讓 request cache 失效（每個使用者看到的結果不同）。

## 稽核日誌（Platinum）

```yaml
xpack.security.audit.enabled: true
xpack.security.audit.logfile.events.include: [ access_denied, authentication_failed, connection_denied, tampered_request, run_as_denied, security_config_change ]
```

寫到 `/var/log/elasticsearch/<cluster.name>_audit.json`。預設的事件已經不少，**不要輕易加上 `access_granted`**，每個請求都會記一筆，量非常大。

## 網路層

- `network.host` 綁內網 IP，不要綁 `0.0.0.0` 後直接暴露在網際網路上。
- 防火牆只開 9200 給用戶端與 Kibana、9300 只給叢集節點之間（**未實測**，容器內沒有 firewalld）：

  ```bash
  sudo firewall-cmd --permanent --new-zone=es-cluster
  sudo firewall-cmd --permanent --zone=es-cluster --add-source=192.168.60.0/24
  sudo firewall-cmd --permanent --zone=es-cluster --add-port=9300/tcp
  sudo firewall-cmd --permanent --zone=public --add-port=9200/tcp
  sudo firewall-cmd --reload
  ```

- 不需要的功能可以停用：例如不用 ML 時不要給節點 `ml` 角色、`xpack.ml.enabled` 預設仍為 true 但沒有 ml 節點就不會執行工作。

## 版本差異比較：9.5 vs 8.19

| 項目 | 8.19 | 9.5 |
| :--- | :--- | :--- |
| 預設安全性 / auto-configuration | 有 | 相同 |
| JVM 沙箱 | Java Security Manager | **改用 entitlements**（JDK 24 起移除 Security Manager），外掛權限的宣告方式改變 |
| 內建 JDK | 依 8.19.x 版本 | 較新的 JDK（見[單節點實作]({% post_url 2026-10-24-elasticsearch-lab-01-single-node %})實測），TLS 預設的協定與加密套件跟著 JDK 走 |
| API key 管理 | 有 | 相同，另有 cross-cluster API key 更完整的支援 |
| 授權 | Basic 含 TLS、RBAC | 相同；8.16 起原始碼另提供 AGPL 授權選項 |

### 給安全設定的升級建議

- 第三方外掛（例如中文分詞）要確認有對應 9.x 的版本：Security Manager 改為 entitlements 後，舊的外掛權限宣告不再適用。
- 升級前用 `GET _ssl/certificates` 確認憑證不會在升級期間到期，也確認憑證的金鑰長度與簽章演算法符合新 JDK 的預設政策。
- 舊的 `kibana` 使用者（7.x 遺留）要改成 `kibana_system` 或服務帳號 token。

## 小結

- 8.0 起預設開安全性；多節點叢集要用同一個 CA（enrollment token 或 certutil）。
- transport 層 TLS 在多節點叢集是必要的，HTTP 層也建議開。
- `elastic` 只用來管理，應用程式用最小權限的角色，優先使用 API key。
- DLS / FLS 與稽核需要 Platinum。

下一篇：[變更管理與發布]({% post_url 2026-10-24-elasticsearch-ops-08-change-management %})。

### 參考資料

- [Elasticsearch 文件：Security](https://www.elastic.co/docs/deploy-manage/security)
- [Elasticsearch 文件：Automatic security setup](https://www.elastic.co/docs/deploy-manage/security/self-auto-setup)
- [Elasticsearch 文件：Set up basic security plus HTTPS](https://www.elastic.co/docs/deploy-manage/security/set-up-basic-security-plus-https)
- [Elasticsearch 文件：elasticsearch-certutil](https://www.elastic.co/docs/reference/elasticsearch/command-line-tools/certutil)
- [Elasticsearch 文件：Security privileges](https://www.elastic.co/docs/reference/elasticsearch/security-privileges)
- [Elasticsearch 文件：API keys](https://www.elastic.co/docs/deploy-manage/api-keys/elasticsearch-api-keys)
- [Elastic subscriptions](https://www.elastic.co/subscriptions)
