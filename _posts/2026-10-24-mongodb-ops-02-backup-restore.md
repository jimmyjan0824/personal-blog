---
title: MongoDB 運維 02：備份與還原
date: 2026-10-24 09:51:00 +0800
categories: [MongoDB, 備份還原]
tags: [mongodb, mongodb8, mongodb9, dba, backup, mongodump, oplog, pitr, snapshot]
description: 以 MongoDB 8.0.9 為主，整理 mongodump/mongorestore、檔案系統快照、oplog 時間點還原（PITR）、分片叢集備份與還原演練，並比較 9.0.4 的差異。
---

MongoDB 的備份看似只要一行 `mongodump`，但資料量一大、或是遇到分片叢集，就會發現「能備份」和「能在 RTO 內還原」是兩回事。本篇以 MongoDB 8.0.9 為主，整理各種備份方式與 PITR 流程，最後比較 9.0.4。

{% include mongodb-ops-series.md %}

## 備份方式總覽

| 類型 | 工具 | 優點 | 缺點 |
| :--- | :--- | :--- | :--- |
| 邏輯備份 | `mongodump` / `mongorestore` | 跨版本、可單一 collection 還原 | 大資料量時很慢，還原要重建索引 |
| 檔案系統快照 | LVM、EBS、雲端磁碟快照 | 速度快、與資料量幾乎無關 | journal 與資料要在同一個 volume，否則要先鎖 |
| 複製檔案 | `fsyncLock` + `cp`/`rsync` | 不需特殊工具 | 鎖定期間無法寫入 |
| 託管 / 企業工具 | Atlas Backup、Ops Manager、Cloud Manager | 連續備份、PITR、分片一致性 | 需付費或使用 Atlas |
| 開源工具 | Percona Backup for MongoDB（PBM） | 支援分片一致性備份與 PITR | 需另外部署 agent，版本支援需查官方矩陣 |
| 日誌 | oplog | 搭配全量備份做 PITR | 需持續保存 |

常見組合：**每日快照（或 PBM 物理備份）+ 持續 oplog 備份 + 每週邏輯備份**。

## 備份帳號

使用內建角色 `backup` 與 `restore`，不要用 `root` 跑備份：

```javascript
use admin
db.createUser({
  user: "bkuser",
  pwd: passwordPrompt(),
  roles: [ { role: "backup", db: "admin" } ]
})
db.createUser({
  user: "rsuser",
  pwd: passwordPrompt(),
  roles: [ { role: "restore", db: "admin" } ]
})
```

## 邏輯備份：mongodump / mongorestore

```bash
# 對 Replica Set 做一致性備份：--oplog 會一併記錄備份期間的 oplog
mongodump \
  --uri="mongodb://bkuser@10.0.0.12:27017/?authSource=admin&replicaSet=rs0&readPreference=secondary" \
  --oplog --gzip \
  --archive=/backup/full_$(date +%F).archive.gz

# 還原：--oplogReplay 重放備份期間的變更，達成時間點一致
mongorestore \
  --uri="mongodb://rsuser@10.0.0.21:27017/?authSource=admin" \
  --oplogReplay --gzip --drop \
  --archive=/backup/full_2026-10-24.archive.gz \
  --numParallelCollections=4 --numInsertionWorkersPerCollection=4
```

- `--oplog` 只能用於整個實例備份（不能和 `--db`、`--collection` 一起用）。
- `--readPreference=secondary` 讓備份壓力落在從節點。
- `mongodump` **不適合分片叢集的一致性備份**：它無法在各 shard 間取得同一個時間點，也不會備份正在遷移的 chunk 狀態。
- 還原只會用到索引定義，索引要重建，大 collection 的還原時間通常比備份長很多。

只還原單一 collection：

```bash
mongorestore --uri="mongodb://rsuser@10.0.0.21:27017/?authSource=admin" \
  --gzip --archive=/backup/full_2026-10-24.archive.gz \
  --nsInclude='shop.orders' --nsFrom='shop.orders' --nsTo='shop_restore.orders'
```

用 `--nsFrom`/`--nsTo` 還原到另一個名稱，確認資料後再搬回去，比直接蓋掉原 collection 安全。

## 檔案系統快照

如果 dbPath 與 journal 在**同一個 volume**，且該 volume 支援 point-in-time 快照（LVM、EBS），可以直接對運行中的 mongod 做快照，WiredTiger 的 checkpoint + journal 能保證 crash-consistent。

journal 不在同一個 volume、或使用不支援快照的儲存時，要先鎖住寫入：

```javascript
db.fsyncLock()     // flush 並阻擋寫入
// 在另一個終端做快照或 rsync
db.fsyncUnlock()
```

> 請在 **hidden secondary** 或專門的備份節點上做 `fsyncLock`，不要在 primary 上鎖。
{: .prompt-warning }

## Oplog 與時間點還原（PITR）

全量備份只能還原到備份當下；要還原到「誤刪前一秒」，需要持續備份 oplog。

### 持續備份 oplog

```bash
# 每 10 分鐘增量匯出 oplog（以上次的最後 ts 為起點）
LAST_TS='{"$timestamp":{"t":1761279600,"i":1}}'
mongodump --uri="mongodb://bkuser@10.0.0.12:27017/?authSource=admin" \
  --db=local --collection=oplog.rs \
  --query="{\"ts\": {\"\$gt\": $LAST_TS}}" \
  --out=/backup/oplog/$(date +%F_%H%M)
```

正式環境建議用 PBM、Ops Manager 或 Atlas 的連續備份，它們會自動處理 oplog 斷點與保存。

### 時間點還原步驟

假設 `2026-10-24 14:03:15`（UTC+8）有人執行了錯誤的 `db.orders.deleteMany({})`：

```bash
# 1. 在新機器還原最近一次全量備份（含 --oplogReplay）
# 2. 找到誤操作的 oplog 時間戳記
mongosh --quiet --eval '
  db.getSiblingDB("local").oplog.rs.find(
    { ns: "shop.orders", op: "d" }
  ).sort({ $natural: 1 }).limit(1)'

# 3. 把增量 oplog 整理成 oplog.bson，放進一個只有它的目錄
mkdir -p /restore/oplog && cp /backup/oplog/.../local/oplog.rs.bson /restore/oplog/oplog.bson

# 4. 重放到誤操作之前（--oplogLimit 為「不包含」該時間點）
mongorestore --uri="mongodb://rsuser@10.0.0.21:27017/?authSource=admin" \
  --oplogReplay --oplogLimit=1761285795:1 /restore/oplog
```

`--oplogLimit` 的格式是 `<epoch 秒>[:序號]`，重放會停在該時間點之前。

> 正式還原請先還原到**獨立的新實例**，確認資料正確後再決定切換，或只把被刪的資料補回原庫。
{: .prompt-warning }

## 分片叢集備份

分片叢集要取得一致性備份，必須同時考慮 config server 與所有 shard：

1. `sh.stopBalancer()`，確認沒有 chunk 遷移。
2. 備份 config server（`config` 資料庫）。
3. 在同一時間點對每個 shard 做快照，或使用支援分片一致性的工具（PBM、Ops Manager、Atlas）。
4. `sh.startBalancer()`。

自建環境強烈建議使用 PBM 或 Ops Manager，手動協調多個 shard 的快照時間點很容易出錯。

## 備份策略與還原演練

- **3-2-1 原則**：3 份副本、2 種媒介、1 份異地。
- **加密**：備份檔包含所有資料，上傳物件儲存前要加密。注意 `mongodump` **不會解密** CSFLE / Queryable Encryption 欄位，備份出來仍是密文，金鑰（Key Vault）也要另外備份。
- **定期演練**：每月至少一次自動還原到測試環境，記錄實際 RTO，並驗證筆數與抽樣資料。
- **監控**：備份成功與否、備份大小是否異常、oplog 備份是否中斷、oplog window 是否足夠。

## 版本差異比較：8.0.9 vs 9.0.4

| 項目 | 8.0.9 | 9.0.4 | 備註 |
| :--- | :--- | :--- | :--- |
| Database Tools 支援 | 100.x 皆支援 8.0 | **需 Database Tools 100.18.0 以上**（2026-08 起支援 9.0） | 目前 100.19.1 支援 4.2～9.0 |
| 時間序列集合儲存 | 以 view + `system.buckets` 實作 | 改為單一 namespace 的壓縮 bucket，不再是 view | 備份腳本若直接處理 `system.buckets.*` 要重新檢查 |
| 升級時的 `mongodump --oplog` | — | Tools 100.18.0 起，遇到 `upgradeDowngradeViewlessTimeseries` oplog 會讓 `--oplog` 備份失敗（TOOLS-4309） | 建議不要在備份窗口內調整 FCV |
| 非時間序列的 `system.buckets` 集合 | 8.0.4 以前需在升級前處理 | 升 9.0 前需改名或刪除（8.0.5+ 可延後到升級後處理） | 見 8.0 相容性文件 |
| 跨資料庫 `renameCollection` | Replica Set 上提早釋放來源鎖，並發寫入可能遺失 | 全程鎖住來源與目標 collection | 用 rename 做還原切換時要注意阻塞 |
| QE 加密資料 | range 查詢 GA | prefix/suffix/substring 查詢 GA，與 8.2 Preview 格式不相容 | Preview 資料無法用 `mongodump` 解密轉換 |
| SERVER-131805 | 受影響（8.0.34 修正） | 9.0 release notes 未列為已知問題 | 跨 DB rename 在 stepdown 後可能刪掉目標 |
| Atlas / EA 備份新功能 | — | Atlas 可還原單一 DB / Collection；EA 支援直寫 S3 與不可變 PITR 鏈 | 屬於平台功能，與 server 版本一起推出 |

### 給備份流程的升級建議

1. 先把所有備份主機上的 Database Tools 升到 100.18.0 以上，再升級 server。
2. 時間序列集合在 9.0 改變儲存方式，升級後務必跑一次完整的備份 + 還原演練。
3. 使用 PBM 的環境，升級前先確認 PBM 版本是否已支援 9.0。

## 小結

- `mongodump` 適合小資料量與單一 collection 還原，大型或分片環境請用快照或 PBM / Ops Manager。
- PITR 的關鍵是 **oplog 不能斷**，而且 oplog window 要大於全量備份間隔。
- 升 9.0 前，先升 Database Tools，並重新驗證時間序列集合的還原。

下一篇：[高可用與災難復原]({% post_url 2026-10-24-mongodb-ops-03-ha-dr %})。

### 參考資料

- [Backup Methods for a Self-Managed Deployment](https://www.mongodb.com/docs/manual/core/backups/)
- [mongodump Compatibility and Installation](https://www.mongodb.com/docs/database-tools/mongodump/mongodump-compatibility-and-installation/)
- [Database Tools 100.18.0 Changelog](https://www.mongodb.com/docs/database-tools/release-notes/dbtools-100.18.0-changelog/)
- [Compatibility Changes in MongoDB 8.0](https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/)
- [Compatibility Changes in MongoDB 9.0](https://www.mongodb.com/docs/manual/release-notes/9.0-compatibility/)
