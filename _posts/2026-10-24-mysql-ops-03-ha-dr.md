---
title: MySQL 運維 03：高可用與災難復原
date: 2026-10-24 09:32:00 +0800
categories: [MySQL, 高可用與災難復原]
tags: [mysql, mysql8, dba, replication, gtid, semi-sync, group-replication, innodb-cluster]
description: 以 MySQL 8.0 為主，整理 GTID 主從複製、半同步、平行複製、Group Replication、InnoDB Cluster 與 RPO/RTO 規劃，並比較 5.7 與 8.4 LTS 的差異。
---

高可用（HA）解決的是「機器壞了服務還能不能跑」，災難復原（DR）解決的是「整個機房沒了資料還在不在」。本篇以 MySQL 8.0 為主，整理常見的複製架構與故障切換，最後比較 5.7 與 8.4 的差異，其中 **8.4 移除舊的 MASTER/SLAVE 語法** 是升級時影響最大的一項。

{% include mysql-ops-series.md %}

## 先定義 RPO 與 RTO

- **RPO（Recovery Point Objective）**：最多能接受遺失多少資料。
- **RTO（Recovery Time Objective）**：最多能接受停機多久。

| 架構 | RPO | RTO | 備註 |
| :--- | :--- | :--- | :--- |
| 非同步複製 + 手動切換 | 秒級（可能遺失） | 分鐘~小時 | 最簡單 |
| 半同步複製 + Orchestrator | 接近 0 | 秒~分鐘 | 常見的自建方案 |
| Group Replication / InnoDB Cluster | 0 | 秒級 | 官方方案，需 3 節點以上 |
| 跨機房 ClusterSet / 非同步 DR | 秒級 | 分鐘 | 異地備援 |

## GTID 主從複製

8.0 建議一律使用 GTID，切換與重建從庫都簡單很多。

```ini
# 主從都要
gtid_mode                = ON
enforce_gtid_consistency = ON
log_bin                  = mysql-bin
log_replica_updates      = ON      # 8.0 預設已開啟
binlog_format            = ROW
```

```sql
-- 主庫：建立複製帳號
CREATE USER 'repl'@'10.0.0.%' IDENTIFIED BY '***';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'10.0.0.%';

-- 從庫：8.0.23+ 新語法
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '10.0.0.1',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = '***',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_SSL = 1,
  GET_SOURCE_PUBLIC_KEY = 1;

START REPLICA;
SHOW REPLICA STATUS\G
```

> 8.0 預設認證外掛是 `caching_sha2_password`。複製帳號若不走 SSL，從庫要設定 `GET_SOURCE_PUBLIC_KEY = 1`，否則會連不上主庫。
{: .prompt-tip }

> 注意：權限名稱 `REPLICATION SLAVE` 至今（包含 8.4）都沒有改名，改名的是 SQL 語句與系統變數。
{: .prompt-info }

## 半同步複製

半同步保證：主庫 commit 回應客戶端前，至少有一台從庫已收到並寫入 relay log。

```sql
-- 主庫（8.0.26+ 新外掛名稱）
INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';
SET PERSIST rpl_semi_sync_source_enabled = ON;
SET PERSIST rpl_semi_sync_source_timeout = 1000;   -- 毫秒，超時退回非同步
SET PERSIST rpl_semi_sync_source_wait_for_replica_count = 1;

-- 從庫
INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';
SET PERSIST rpl_semi_sync_replica_enabled = ON;
STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;
```

`rpl_semi_sync_source_wait_point` 預設為 `AFTER_SYNC`（lossless semi-sync），主庫 crash 後切換也不會出現「客戶端看到 commit，但從庫沒有」的幻讀。

要監控 `Rpl_semi_sync_source_status`：若變成 `OFF`，代表已經退化成非同步複製。

## 平行複製：降低延遲

```ini
replica_parallel_type          = LOGICAL_CLOCK
replica_parallel_workers       = 8
replica_preserve_commit_order  = ON
binlog_transaction_dependency_tracking = WRITESET   # 僅 8.0，8.4 已移除且固定為 WRITESET
```

8.0.27 起，`replica_parallel_workers` 預設 4、`replica_parallel_type` 預設 `LOGICAL_CLOCK`、`replica_preserve_commit_order` 預設 `ON`，也就是平行複製預設開啟。

## Group Replication 與 InnoDB Cluster

Group Replication（MGR）基於 Paxos 協定，提交前需多數節點同意，能做到 RPO = 0 與自動選主。官方把它包裝成 **InnoDB Cluster**：

- **MySQL Group Replication**：資料層，3~9 節點。
- **MySQL Router**：自動把流量導向目前的 Primary。
- **MySQL Shell AdminAPI**：建立、管理叢集。

```javascript
// mysqlsh
dba.configureInstance('root@db1:3306')
var cluster = dba.createCluster('prodCluster')
cluster.addInstance('root@db2:3306', {recoveryMethod: 'clone'})
cluster.addInstance('root@db3:3306', {recoveryMethod: 'clone'})
cluster.status()
```

使用 MGR 的限制：

- 每張表必須有主鍵（或非 NULL 唯一鍵）。
- 只支援 InnoDB。
- 對網路延遲敏感，節點最好在同一區域內。
- 大交易會拖累整個群組，要用 `group_replication_transaction_size_limit` 限制。

### 其他官方拓樸

- **InnoDB ReplicaSet**（8.0.19+）：基於非同步複製，用 AdminAPI 管理，手動切換。
- **InnoDB ClusterSet**（8.0.27+）：多個 InnoDB Cluster 之間用非同步複製串起來，做跨機房 DR。

## 第三方方案

- **Orchestrator**：拓樸偵測與自動故障切換，搭配 GTID 與半同步最常見。
- **ProxySQL**：讀寫分離、連線池、故障時自動調整後端。
- **MHA**：老牌方案，已多年未維護，不建議新專案使用。

## 災難復原演練

1. 異地至少要有一份**持續複製**的實例 + 一份**離線備份**。
2. 定期演練 Switchover（計畫內切換）與 Failover（故障切換），記錄真實的 RTO。
3. 切換後檢查：應用程式連線字串、DNS/VIP、`read_only`/`super_read_only`、複製方向、備份任務是否跟著換主。
4. 用 `pt-table-checksum` 定期檢查主從資料一致性。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 複製語法 | `CHANGE MASTER TO`、`START SLAVE`、`SHOW SLAVE STATUS` | 8.0.22/8.0.23 新增 `REPLICA`/`SOURCE` 語法，舊語法棄用 | **舊語法全部移除** |
| 主庫狀態 | `SHOW MASTER STATUS` | 同 5.7（8.2 才新增新語法） | 只能用 `SHOW BINARY LOG STATUS` |
| 重置 binlog | `RESET MASTER` | 同 5.7 | `RESET BINARY LOGS AND GTIDS` |
| 半同步外掛 | `rpl_semi_sync_master`/`slave` | 8.0.26+ 新增 `rpl_semi_sync_source`/`replica` | 舊外掛仍可用但已棄用 |
| `log_slave_updates` 預設 | `OFF` | `ON`（並改名 `log_replica_updates`） | `ON` |
| 平行複製預設 | 關閉 | 8.0.27+ 預設開啟（4 workers） | 開啟 |
| 依賴追蹤 | 5.7.22+ 可設 `WRITESET`（預設 `COMMIT_ORDER`） | 預設 `COMMIT_ORDER`，建議設 `WRITESET` | `binlog_transaction_dependency_tracking` **移除**，固定 WRITESET |
| MGR | 5.7.17+ 推出，較不成熟 | 大幅改進，支援 Clone 補資料 | 更穩定，可在 8.4 系列內混版本 |
| MGR `group_replication_consistency` 預設 | — | `EVENTUAL` | `BEFORE_ON_PRIMARY_FAILOVER` |
| MGR `group_replication_exit_state_action` 預設 | `ABORT_SERVER` | `READ_ONLY` | `OFFLINE_MODE` |
| `SOURCE_RETRY_COUNT` 預設 | 86400 | 86400 | 10 |
| 舊命名變數 | `master_info_repository` 等 | 棄用 | `--master-info-repository`、`--relay-log-info-repository` **移除** |
| GTID 標籤 | 無 | 無 | 新增 Tagged GTID（`UUID:TAG:NUMBER`） |
| Binlog 格式 | 可用 `MIXED`/`STATEMENT` | `binlog_format` 8.0.34 起棄用 | 仍可設，但官方方向只保留 ROW |

### 升級到 8.4 前要掃過的地方

8.4 移除舊語法後，以下東西都可能壞掉：

- 監控腳本中的 `SHOW SLAVE STATUS`、`SHOW MASTER STATUS`。
- 自動化切換工具（舊版 Orchestrator、MHA、自寫腳本）。
- 輸出欄位名稱也變了，例如 `Seconds_Behind_Master` → `Seconds_Behind_Source`、`Slave_IO_Running` → `Replica_IO_Running`。

8.0 可以先設定 `terminology_use_previous = BEFORE_8_0_26` 讓監控工具暫時看到舊名稱，但這只是過渡，升 8.4 前應該全部改成新語法。

## 小結

- 8.0 一律用 GTID + ROW + 新的 `REPLICA`/`SOURCE` 語法，為升級 8.4 鋪路。
- 半同步要監控是否退化；MGR 要注意主鍵與大交易限制。
- HA 方案再好，也要定期演練切換與還原。

下一篇：[監控與告警]({% post_url 2026-10-24-mysql-ops-04-monitoring %})。

### 參考資料

- [MySQL 8.4 Reference Manual：What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)
- [MySQL 8.0 Release Notes：Changes in MySQL 8.0.26](https://dev.mysql.com/doc/relnotes/mysql/8.0/en/news-8-0-26.html)
- [MySQL 8.4 Reference Manual：Installing Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync-installation.html)
