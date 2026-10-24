---
title: MongoDB 運維 07：安全與權限管理
date: 2026-10-24 09:56:00 +0800
categories: [MongoDB, 安全權限]
tags: [mongodb, mongodb8, mongodb9, dba, security, rbac, tls, audit, queryable-encryption]
description: 以 MongoDB 8.0.9 為主，整理認證機制、RBAC 最小權限、TLS、靜態加密、CSFLE 與 Queryable Encryption、審計日誌與網路防護，並比較 9.0.4 的差異。
---

「MongoDB 沒設密碼被勒索」曾經是資安新聞的常客。雖然現在的預設值已經安全很多（預設只綁 localhost），但認證、權限、加密、審計，每一項都還是要 DBA 自己把關。本篇以 MongoDB 8.0.9 為主，最後比較 9.0.4。

{% include mongodb-ops-series.md %}

## 安全檢查清單

| 層面 | 做法 |
| :--- | :--- |
| 網路 | `bindIp` 只綁內網、防火牆 / Security Group 白名單、不對外開 27017 |
| 認證 | 開啟 `authorization`，叢集內部用 keyFile 或 x.509 |
| 授權 | RBAC 最小權限，應用程式帳號只給需要的資料庫 |
| 傳輸加密 | TLS（`requireTLS`） |
| 靜態加密 | Enterprise 的 Encryption at Rest、或磁碟層加密 |
| 欄位加密 | CSFLE / Queryable Encryption |
| 審計 | Enterprise 審計日誌（Community 可考慮 Percona Server for MongoDB） |
| 修補 | 追最新 patch，訂閱官方安全公告 |

## 認證

```yaml
security:
  authorization: enabled
  clusterAuthMode: x509          # 或 keyFile
setParameter:
  authenticationMechanisms: SCRAM-SHA-256
```

| 機制 | 版本 | 說明 |
| :--- | :--- | :--- |
| SCRAM-SHA-256 | 全部 | 預設推薦 |
| SCRAM-SHA-1 | 全部 | 舊 driver 相容用，建議停用 |
| x.509 | 全部 | 憑證認證，適合服務間與叢集內部 |
| LDAP | Enterprise | **8.0 起棄用**，8.x 期間仍可用 |
| Kerberos | Enterprise | 企業 AD 環境 |
| OIDC（Workload / Workforce Identity Federation） | Enterprise / Atlas | 整合 IdP |

## RBAC：最小權限

```javascript
use admin

// 應用程式：只能讀寫 shop
db.createUser({
  user: "app_shop", pwd: passwordPrompt(),
  roles: [ { role: "readWrite", db: "shop" } ]
})

// 報表：唯讀
db.createUser({
  user: "report", pwd: passwordPrompt(),
  roles: [ { role: "read", db: "shop" } ]
})

// 自訂角色：只能對 orders 做查詢與更新，不能刪除
db.createRole({
  role: "ordersOperator",
  privileges: [
    { resource: { db: "shop", collection: "orders" }, actions: [ "find", "update" ] }
  ],
  roles: []
})
```

原則：

- **不要讓應用程式使用 `root`、`dbOwner`、`userAdminAnyDatabase`**。
- 監控用 `clusterMonitor`、備份用 `backup` / `restore`。
- 定期盤點：`db.getUsers()`、`db.getRoles({ showPrivileges: true })`。
- 8.0 的 `directShardOperations` 角色只在 shard 維護時臨時授予，誤用可能造成資料損毀。

## TLS

```yaml
net:
  tls:
    mode: requireTLS
    certificateKeyFile: /etc/mongodb/tls/server.pem
    CAFile: /etc/mongodb/tls/ca.pem
    disabledProtocols: TLS1_0,TLS1_1
```

連線字串加上 `tls=true`。憑證到期是常見的事故來源，要把憑證到期日納入監控。

## 靜態加密與欄位加密

**Encryption at Rest（Enterprise）**：WiredTiger 層加密資料檔，金鑰建議放在 KMIP 伺服器：

```yaml
security:
  enableEncryption: true
  kmip:
    serverName: kmip.example.com
    port: 5696
    serverCAFile: /etc/mongodb/kmip/ca.pem
    clientCertificateFile: /etc/mongodb/kmip/client.pem
```

**欄位層級加密**：

| 方案 | 特性 |
| :--- | :--- |
| CSFLE（Client-Side Field Level Encryption） | 用戶端加密；deterministic 加密才能做等值查詢 |
| Queryable Encryption（QE） | 用戶端加密、伺服器端可直接查詢密文；8.0 支援等值與**範圍查詢** |

兩者的金鑰都在用戶端，DBA 和伺服器都看不到明文，適合身分證號、病歷等高敏感欄位。

## 審計日誌（Enterprise）

```yaml
auditLog:
  destination: file
  format: JSON
  path: /var/log/mongodb/audit.json
  schema: OCSF        # 8.0 新增；預設為 mongo
  filter: '{ atype: { $in: [ "authenticate", "createUser", "dropUser", "grantRolesToUser", "dropCollection", "dropDatabase" ] } }'
```

8.0 新增 **OCSF** 格式，可直接匯入支援 OCSF 的 SIEM。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| Queryable Encryption | 等值、範圍查詢 GA | 新增 **prefix / suffix / substring 查詢 GA** | 9.0；與 8.2 Public Preview 的格式不相容 |
| QE Preview 查詢類型 | — | `prefixPreview`、`suffixPreview`、`substringPreview` 移除 | 9.0；需重建加密 collection |
| `mongocryptd` | 支援 | **棄用**，改用 Automatic Encryption Shared Library（crypt_shared） | 9.0 |
| LDAP | 棄用但可用 | 仍可用；新增 `useInternalAuthzForX509`，讓 x.509 使用者在設定 LDAP 授權時改用內部授權 | 9.0 相容性文件未列出移除 |
| `usersInfo` | — | 新增 `authenticatedMechanism` 欄位 | 9.0 |
| 審計日誌 | OCSF 格式（8.0 起）；8.1 起記錄經負載平衡器的原始 IP | 新增 `directRemote`（mongo schema）/ `direct_endpoint`（OCSF），記錄實際 TCP 對端 | 9.0，搭配 PROXY protocol 時更好追蹤 |
| FIPS 模式 | 可同時啟用 SCRAM-SHA-1 | **SCRAM-SHA-1 不可與 `--tlsFIPSMode` 並用** | 8.3 起 |
| 認證前連線保護 | — | `preAuthMaximumMessageSizeBytes`、`capMemoryConsumptionForPreAuthBuffers` 等 | 8.3 起，降低未認證連線的 DoS 風險 |
| 連線建立速率限制 | — | `ingressConnectionEstablishmentRateLimiterEnabled` 等參數 | 8.2 起，防連線風暴 |
| Windows TLS 1.3 | 不支援 | 支援 | SERVER-79980（也回補到 8.0.34、8.3.7） |
| 安全修補 | 8.0.9 修正 CVE-2025-6714（mongos 透過 HAProxy 時可能拒絕新連線） | 9.0.1 修正 CVE-2026-89099；9.0.4 修正 5 個 CVE | 8.0.9 之後仍有 CVE-2025-12657（8.0.10）、CVE-2025-10061（8.0.12）等修正 |

> 安全上最重要的一點：**停在 8.0.9 本身就是風險**。8.0.9 之後陸續修正的 CVE 包括 KMIP 回應處理（CVE-2025-12657）與 `$group` 查詢造成 crash（CVE-2025-10061）。不論是否升 9.0，都應先升到最新的 8.0.x。
{: .prompt-danger }

### 給安全設定的升級建議

1. 用過 8.2 / 8.3 QE Preview 的環境，升 9.0 前必須建立新的加密 collection 並搬移資料。
2. 把 `mongocryptd` 換成 crypt_shared library。
3. 啟用 FIPS 的環境，先確認沒有任何帳號或 driver 依賴 SCRAM-SHA-1。
4. LDAP 雖仍可用，但已棄用，長期應規劃轉向 OIDC 或 x.509。

## 小結

- 安全的基本功：**內網、認證、最小權限、TLS、追 patch**，缺一不可。
- 高敏感欄位用 Queryable Encryption，讓伺服器與 DBA 都看不到明文。
- 9.0 的 QE 支援部分比對查詢，是加密資料可用性的一大進步，但 Preview 用戶需要搬資料。

下一篇：[變更管理與發布]({% post_url 2026-10-24-mongodb-ops-08-change-management %})。

### 參考資料

- [Security Checklist for Self-Managed Deployments](https://www.mongodb.com/docs/manual/administration/security-checklist/)
- [Queryable Encryption](https://www.mongodb.com/docs/manual/core/queryable-encryption/)
- [Release Notes for MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
- [Compatibility Changes in MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
