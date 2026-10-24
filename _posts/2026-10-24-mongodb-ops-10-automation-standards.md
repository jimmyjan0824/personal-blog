---
title: MongoDB 運維 10：自動化與規範制定
date: 2026-10-24 09:59:00 +0800
categories: [MongoDB, 自動化與規範]
tags: [mongodb, mongodb8, mongodb9, dba, ansible, kubernetes, automation, naming-convention, standards]
description: 以 MongoDB 8.0.9 為主，整理 Ansible、Kubernetes Operator、Ops Manager / Atlas 自動化、命名與資料建模規範、查詢與索引規範、運維文件化，並比較 9.0.4 對自動化腳本的影響。
---

前面九篇談的每一項工作，最後都應該走向「有規範、可重複、自動化」。本篇以 MongoDB 8.0.9 為主，整理自動化工具與開發規範，最後整理 **9.0.4 對既有腳本與規範的影響**，作為整個系列的總結。

{% include mongodb-ops-series.md %}

## 自動化工具選擇

| 工具 | 適用場景 |
| :--- | :--- |
| Ansible（`community.mongodb` collection） | VM / 實體機自建，管理安裝、設定、使用者、Replica Set |
| Kubernetes Operator | 容器化部署；MongoDB 官方 Operator 或 Percona Operator for MongoDB |
| Ops Manager / Cloud Manager | Enterprise 自建，提供自動化、監控、備份一體化 |
| Atlas + Terraform（`mongodbatlas` provider） | 託管服務，基礎架構即程式碼 |
| 自寫腳本（mongosh / Python） | 巡檢、報表、例行維護 |

## Ansible 範例

{% raw %}
```yaml
# playbook: mongodb-rs.yml
- hosts: mongodb
  become: true
  vars:
    mongodb_version: "8.0.9"
  tasks:
    - name: Install MongoDB packages (pinned)
      ansible.builtin.apt:
        name:
          - "mongodb-org-server={{ mongodb_version }}"
          - "mongodb-org-mongos={{ mongodb_version }}"
          - mongodb-mongosh
        state: present

    - name: Deploy mongod.conf
      ansible.builtin.template:
        src: mongod.conf.j2
        dest: /etc/mongod.conf
      notify: restart mongod

- hosts: mongodb[0]
  tasks:
    - name: Initiate replica set
      community.mongodb.mongodb_replicaset:
        login_host: localhost
        replica_set: rs0
        members:
          - db1.az-a:27017
          - db2.az-b:27017
          - db3.az-c:27017

    - name: Create application user
      community.mongodb.mongodb_user:
        login_user: admin
        login_password: "{{ vault_mongo_admin_pw }}"
        database: admin
        name: app_shop
        password: "{{ vault_app_shop_pw }}"
        roles:
          - { db: shop, role: readWrite }
```
{% endraw %}

密碼一律放 Ansible Vault 或外部 Secret 管理，不要寫在 repo 裡。

## 例行巡檢腳本

```javascript
// daily-check.js：mongosh --quiet -f daily-check.js
const st = rs.status();
const primary = st.members.find(m => m.stateStr === "PRIMARY");
const report = {
  version: db.version(),
  fcv: db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version,
  members: st.members.map(m => ({
    name: m.name, state: m.stateStr,
    lagSec: primary ? (primary.optimeDate - m.optimeDate) / 1000 : null
  })),
  oplogHours: (db.getReplicationInfo().timeDiff / 3600).toFixed(1),
  connections: db.serverStatus().connections
};
printjson(report);
```

輸出可以送到 Slack、存進監控資料庫，或在異常時開工單。

## 命名規範

| 對象 | 規範 | 範例 |
| :--- | :--- | :--- |
| 資料庫 | 小寫、底線分隔、依業務領域 | `shop`、`user_center` |
| Collection | 小寫、複數、底線分隔 | `orders`、`order_items` |
| 欄位 | camelCase，與應用程式一致 | `customerId`、`createdAt` |
| 索引 | 用預設名稱（`欄位_方向`），或 `idx_用途` | `customerId_1_createdAt_-1` |
| 使用者 | `用途_系統` | `app_shop`、`report_bi` |

避免：欄位名稱以 `$` 開頭或包含 `.`、在欄位名稱放動態值（例如把日期當 key）。

## 資料建模與查詢規範

1. **一起讀的資料放一起**：優先內嵌，只有在資料會無限成長或被多處共用時才拆開引用。
2. **文件大小**：單一文件遠低於 16MB 上限，陣列要有上限。
3. **每個查詢都要有索引**：上線前附上 `explain("executionStats")`，禁止 `COLLSCAN` 進正式環境。
4. **一律設定逾時**：driver 端設定 `maxTimeMS`，叢集層設定 `defaultMaxTimeMS`。
5. **寫入使用 `w: "majority"`**，讀取依需求選擇 read concern。
6. **交易要短**：一次交易修改的文件數量與時間都要有限制。
7. **禁止在正式環境使用 `$where`、無索引的 `$regex`、無條件的 `deleteMany({})`**。
8. **批次作業**：使用 `bulkWrite`，並控制批次大小與速率。

## 運維文件化

- **架構文件**：拓撲、版本、參數、各節點用途（含 hidden / delayed 節點）。
- **Runbook**：每一種告警對應一份處理步驟（見[故障排查篇]({% post_url 2026-10-24-mongodb-ops-09-troubleshooting %})）。
- **變更紀錄**：每次變更的 PR、執行時間、執行者、結果。
- **演練紀錄**：備份還原、故障切換的實際 RTO。

## 版本差異比較：8.0.9 vs 9.0.4（對自動化與規範的影響）

| 項目 | 8.0.9 | 9.0.4 | 對腳本 / 規範的影響 |
| :--- | :--- | :--- | :--- |
| 發布模型 | Major + Minor（8.1～8.3） | Major + 每年一次 **x.5 Feature Update**；EA 只會收到 Feature Update | 升級規劃改以年為單位 |
| 移除 shard | `removeShard` | `startShardDraining` / `shardDrainingStatus` / `commitShardRemoval` | 縮容腳本要改寫（8.3 起） |
| DDL 執行位置 | 可在 shard 上執行（受角色限制） | 只能透過 `mongos` | 直接連 shard 的維護腳本會失敗（8.3 起） |
| 監控指標名稱 | `databaseVersionUpdateCounters`、`changeStreams.showExpandedEvents` | 改名為 `databaseShardingMetadataStatistics`、`changeStreams.option.showExpandedEvents` | exporter / 巡檢腳本要更新 |
| Server 端 JavaScript | SpiderMonkey，已棄用 | WASM 引擎、取消棄用；日期以 UTC 計算；ppc64le 不可用 | 有用到本地時區的腳本結果會變 |
| 錯誤碼 | 2dsphere `16755`；upsert 過大 `17419`/`17420` | `510`/`511`；`10334` | 依錯誤碼判斷的重試邏輯要更新 |
| FIPS + SCRAM-SHA-1 | 可並用 | 不可並用 | 帳號佈建腳本只用 SCRAM-SHA-256（8.3 起） |
| `mongocryptd` | 支援 | 棄用 | 部署腳本改裝 crypt_shared |
| Database Tools | 100.x | 需 100.18.0 以上 | 備份主機的工具版本要一起升級 |
| Mongoose 等 ODM | — | FCV 9.0 的 `listIndexes` 多了 simple collation | Mongoose 9.10.4 / 8.24.5 以上，避免啟動時 `syncIndexes()` |
| Validation level | `strict` / `moderate` | 新增 `constraint` | 規範可改為新 collection 一律 `constraint` |

### 給自動化腳本的升級建議

1. 在 CI 中用 9.0 容器跑一次所有運維腳本與 migration，提早抓出指令與指標名稱的差異。
2. 腳本中依版本判斷：`db.version()` 與 FCV 都要檢查，因為「binary 已升 9.0、FCV 仍為 8.0」是升級過程中的正常狀態。
3. Ansible `community.mongodb` 與 Operator 升到支援 9.0 的版本後，再開始升級資料庫。

## 系列總結

這十篇從安裝、備份、高可用、監控、效能、容量、安全、變更、排障到自動化，整理了 MongoDB 8.0 運維的主要面向。幾個貫穿全系列的重點：

- **8.0.9 不是終點**：8.0 系列已出到 8.0.34，之後還修了多個 CVE 與資料正確性問題，至少要追到最新 patch。
- **8.0 最容易忽略的變更**：THP 改為開啟、`w: "majority"` 確認時機改變、直連 shard 受限、`workingMillis`。
- **9.0 的升級重點**：可從 8.0 直接升級，但會一次帶入 8.1～9.0 的變更；包括**單一操作記憶體上限**、**分片 metadata 下放到 shard**、**指標改名**、**QE Preview 格式不相容**，以及數個尚未修正的已知問題。
- 9.0 一定要選 **9.0.4 以上**，避開 9.0.0～9.0.2 的 step-up 卡住問題。
- 所有運維工作的最終形態，都是「有文件、可重複、自動化、可審計」。

感謝閱讀，有任何問題歡迎到 [GitHub](https://github.com/jimmyjan0824) 與我交流。

### 參考資料

- [Ansible community.mongodb collection](https://docs.ansible.com/ansible/latest/collections/community/mongodb/index.html)
- [MongoDB Versions and Upgrade Paths](https://www.mongodb.com/docs/mongodb-versions/)
- [Release Notes for MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
- [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
- [Release Notes for MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0/)
