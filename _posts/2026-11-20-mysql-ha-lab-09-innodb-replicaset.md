---
title: MySQL 高可用實作 09：InnoDB ReplicaSet，用 MySQL Shell 管理非同步主從（Rocky Linux 9）
date: 2026-11-20 21:00:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql84, percona, rocky-linux, innodb-replicaset, mysql-shell, mysql-router, replication, failover, dba]
description: InnoDB ReplicaSet 是「用 AdminAPI 管理的 GTID 非同步主從」。在 Percona Server 8.4.11 上用 MySQL Shell 建立一主二從、Clone 自動補資料、MySQL Router 自動找主庫，實測計畫內切換（寫入停頓 0.25 秒）、主庫 kill -9 後手動 failover，以及舊主庫重新加入時的 super_read_only 陷阱。
media_subpath: /assets/img/posts/mysql-ha-lab-09
---

[Lab 01]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 用手動指令建了 GTID 主從，切換要自己下 `STOP REPLICA`、`CHANGE REPLICATION SOURCE`、改 `read_only`；[Lab 05]({% post_url 2026-10-24-mysql-ha-lab-05-innodb-cluster %}) 的 InnoDB Cluster 全自動，但底層是 Group Replication，對網路延遲和寫入衝突比較敏感。

**InnoDB ReplicaSet** 介於兩者之間：底層就是 Lab 01 的 GTID 非同步複製，但建立、加節點、切換、failover 都交給 MySQL Shell 的 AdminAPI，再配上 MySQL Router 自動找主庫。適合「想要簡單好管理、可以接受手動 failover」的環境。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - Percona Server **8.4.11-12.1**、MySQL Shell **8.4.10**、MySQL Router **8.4.11**（都從 `ps-84-lts` 套件庫安裝）。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd（x86_64，4 vCPU / 15 GB）。文中的圖是實測輸出的終端機截圖。
> - 驗證腳本與完整輸出：[`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的 `09-replicaset.sh`、`results/09-replicaset.log`。
{: .prompt-warning }

## ReplicaSet、Cluster、手動主從怎麼選

| | 手動 GTID 主從（Lab 01） | **InnoDB ReplicaSet** | InnoDB Cluster（Lab 05） |
| :--- | :--- | :--- | :--- |
| 底層 | 非同步複製 | 非同步複製 | Group Replication |
| 節點數 | 不限 | 1 主 + 任意從庫 | 3~9 台 |
| 自動 failover | ✗ | **✗（手動 `forcePrimaryInstance`）** | ✓ |
| 計畫內切換 | 手動多個步驟 | 一行 `setPrimaryInstance` | 一行 `setPrimaryInstance` |
| 主庫故障可能遺失資料 | 是（非同步） | **是（非同步）** | 否（多數派確認） |
| Router 自動找主庫 | ✗ | ✓ | ✓ |
| 新節點補資料 | 手動 dump / XtraBackup | Clone 自動 | Clone 自動 |
| 跨機房、高延遲網路 | 適合 | 適合 | 不適合（每筆交易要多數派確認） |
| 寫入衝突、大交易限制 | 無 | 無 | 有（GR 的限制） |

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.58.11 | 主庫（PRIMARY） |
| `db2` | 192.168.58.12 | 從庫（SECONDARY） |
| `db3` | 192.168.58.13 | 從庫（SECONDARY） |
| `router` | 192.168.58.20 | MySQL Router（6446 讀寫、6447 唯讀） |
| `app` | 192.168.58.30 | 每 0.2 秒透過 `router:6446` 寫一筆 |

## 步驟 1：設定檔

三台都放 [Lab 01]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的 `00-server.cnf`，加上 AdminAPI 需要的複製設定（`server_id`、`report_host` 每台不同，放在 `server-id.cnf`）：

```ini
# /etc/my.cnf.d/replication.cnf
[mysqld]
bind_address             = 0.0.0.0
log_bin                  = mysql-bin
gtid_mode                = ON
enforce_gtid_consistency = ON
binlog_expire_logs_seconds = 604800
sync_binlog              = 1
relay_log                = relay-bin
relay_log_recovery       = ON
replica_parallel_workers = 8
replica_preserve_commit_order = ON
```

> `report_host` 一定要設成其他節點連得到的主機名。AdminAPI 和 Router 都用它記錄節點位址，沒設的話會用 `@@hostname`，在容器或主機名不可解析的環境會連不上。
{: .prompt-warning }

## 步驟 2：dba.configureReplicaSetInstance()

每台用 root 透過本機 socket 進 MySQL Shell，檢查設定並建立叢集管理帳號（三台都要建，因為此時還沒有複製）：

```bash
mysqlsh --uri root@localhost --socket=/var/lib/mysql/mysql.sock
```

```js
dba.configureReplicaSetInstance(null, {
  clusterAdmin: "'clusteradmin'@'192.168.58.%'",
  clusterAdminPassword: '...'
})
```

![configureReplicaSetInstance：applierWorkerThreads will be set to the default value of 4](01-configure.png)

注意第三行：**AdminAPI 把 `replica_parallel_workers` 改成 4**，而且是用 `SET PERSIST` 寫進 `mysqld-auto.cnf`，優先順序比設定檔高：

```console
[db1] mysql> SELECT @@replica_parallel_workers;   -- 設定檔寫 8
+----------------------------+
| @@replica_parallel_workers |
+----------------------------+
|                          4 |
+----------------------------+

[db1]# python3 -m json.tool /var/lib/mysql/mysqld-auto.cnf | grep -A1 replica_parallel_workers
        "replica_parallel_workers": {
            "Value": "4",
```

要維持 8 個 worker，在這一步就指定 `dba.configureReplicaSetInstance(null, {applierWorkerThreads: 8, ...})`；事後才改的話用 `SET PERSIST replica_parallel_workers = 8`。直接改設定檔是沒用的。

## 步驟 3：建立 ReplicaSet、Clone 加入從庫

以 `clusteradmin` 連到 db1：

```js
// mysqlsh clusteradmin@db1:3306
var rs = dba.createReplicaSet('rs_lab')
rs.addInstance('db2:3306', {recoveryMethod: 'clone'})
rs.addInstance('db3:3306', {recoveryMethod: 'clone'})
```

![addInstance：偵測到 errant GTID，用 Clone 覆蓋整台資料，約 78 MB 1 秒](02-add-clone.png)

兩個重點：

- **errant GTID**：db2 初始化後改 root 密碼那一筆交易在 db2 自己的 GTID 下，不屬於 ReplicaSet。AdminAPI 會偵測出來並拒絕用增量複製加入（手動主從不會擋，日後切換時才爆，見 [Lab 07]({% post_url 2026-11-20-mysql-ha-lab-07-upgrade-80-to-84 %})）。
- **Clone** 直接把 db1 的資料檔複製過去並自動重啟 db2，不用自己 dump。db3 則是從 db2 clone（AdminAPI 會挑一台從庫當 donor，減少主庫負擔）。

完成後的狀態：

![rs.status()：PRIMARY db1 R/W、db2 / db3 R/O ONLINE，replicationSslMode REQUIRED](03-status.png)

AdminAPI 建的複製通道預設就是 **TLS（`replicationSslMode: REQUIRED`）**，從庫也自動設了 `super_read_only = ON`。

## 步驟 4：MySQL Router

```bash
sudo mysqlrouter --bootstrap clusteradmin@db1:3306 --user=mysqlrouter
sudo systemctl enable --now mysqlrouter
```

![Router 8.4.11 bootstrap：6446 讀寫、6447 唯讀、6450 讀寫分離；6446 → db1、6447 輪流 db2 / db3](04-router.png)

Bootstrap 會在 ReplicaSet 裡建立 Router 專用帳號、把設定寫到 `/etc/mysqlrouter/mysqlrouter.conf`。8.4 的 Router 多了 **6450 讀寫分離埠**（同一條連線，讀交易送從庫、寫交易送主庫）。

## 步驟 5：計畫內切換

app 透過 `router:6446` 持續寫入，然後一行指令把 db2 升為主庫：

```js
rs.setPrimaryInstance('db2:3306')
```

![setPrimaryInstance：同步交易、取得全域鎖、改複製來源；app 0 筆失敗、最大間隔 0.253 秒](05-switchover.png)

AdminAPI 做的事和 Lab 01 手動切換一樣（同步交易 → 舊主庫唯讀 → 新主庫可寫 → 其他從庫改接），差別是它先在所有節點取得**全域鎖**，切換期間的寫入是**被擋住等待**而不是失敗。這次 **0 筆失敗、兩筆成功寫入間最長隔 0.25 秒**；另一次完整重跑是 3 筆 `ERROR 1290 (read-only)`、0.92 秒（寫入剛好在鎖釋放前打到舊主庫）。

Router 透過 metadata 的變化自動把 6446 指向 db2，應用程式不用改任何設定。

## 步驟 6：主庫故障，ReplicaSet 不會自動 failover

模擬主庫 db2 當機：

```bash
systemctl kill -s KILL mysqld; systemctl stop mysqld
```

![app：Can't connect to router:6446；rs.status() 提示 repair it or perform a failover](06-primary-down.png)

- Router 找不到主庫時**直接關閉 6446 的監聽**，應用程式拿到的是 `ERROR 2003 Can't connect ... (111)`（連線被拒），而不是連線卡住。
- ReplicaSet **不會自己選新主庫**，要人來決定。這是刻意的設計：非同步複製下，自動 failover 可能把落後的從庫升成主庫、造成資料遺失，所以交給人判斷。

## 步驟 7：手動 failover

確認 db2 短時間內修不好，把 db1 強制升為主庫：

```js
rs.forcePrimaryInstance('db1:3306')
```

![forcePrimaryInstance：等從庫套用完收到的交易、升級 db1、db3 改接 db1；舊主庫 db2 被標記為 invalidated](07-force-primary.png)

`forcePrimaryInstance` 會先等候選人**套用完已經收到的 relay log**，再檢查其他從庫的 GTID，挑選資料最新的一台（指定的 db1 不是最新時會拒絕）。寫入中斷 **6.7 秒**，但這幾乎全是「人發現問題、下指令」的時間（腳本在主庫掛掉後等了 5 秒才下指令）；`forcePrimaryInstance` 本身約 1 秒。實務上這段時間取決於監控告警和值班反應，可能是好幾分鐘。

> **非同步複製的 failover 可能遺失資料**：主庫在交易 commit 後、binlog 還沒送到任何從庫前就當機，這些交易就不見了。本例最後核對時 67 筆成功寫入全部都在（寫入量低、從庫幾乎即時），但這不是保證。不能接受任何遺失的話，要搭配 [半同步]({% post_url 2026-10-24-mysql-ha-lab-02-semi-sync %})（ReplicaSet 不直接管理，要自己設定），或改用 InnoDB Cluster。
{: .prompt-danger }

## 步驟 8：舊主庫回來後的陷阱

db2 修好重新啟動：

![db2 重啟後 read_only = 0、super_read_only = 0；status 顯示 INVALIDATED 並警告 Accidental updates](08-invalidated.png)

**被 kill 的舊主庫重啟後是可寫的**（它最後的角色是主庫，設定檔裡沒有 `super_read_only`）。Router 不會把流量送給 INVALIDATED 的節點，但**直連 db2 的程式、排程、DBA 手動操作都能寫進去**，產生 ReplicaSet 裡沒有的交易（errant GTID），之後就不能用增量方式加回來，只能 Clone 覆蓋。

> 舊主庫修好後，**先確認它不會在你不知情時接受寫入**：
>
> - 修復期間 `systemctl disable mysqld`，避免主機重開機時自動啟動。
> - 啟動後第一件事 `SET GLOBAL super_read_only = ON`，再用 `rs.rejoinInstance()` 加回去（AdminAPI 加回時會自己設好唯讀）。
> - 讓應用程式只透過 Router 連線，不要寫死個別節點的位址。
{: .prompt-danger }

## 步驟 9：重新加入

```js
rs.rejoinInstance('db2:3306')
```

![rejoinInstance：GTID 是子集合，選擇 Incremental state recovery](09-rejoin.png)

db2 的 GTID 集合是 ReplicaSet 的子集合（被 kill 前的交易都已經送到從庫），AdminAPI 自動選擇**增量復原**，改接 db1 後追上。如果 db2 有 errant 交易，要改用 `{recoveryMethod: 'clone'}` 覆蓋。

## 步驟 10：最終驗證

![OK=67（db1 49 筆 + db2 18 筆）；三台 5067 筆、CRC 相同](10-final.png)

app 回報成功的 67 筆（寫到 db1 的 49 筆 + 寫到 db2 的 18 筆）全部在資料庫裡，三台筆數與 CRC 相同；失敗的 30 筆都是 failover 期間連不上 Router（沒有寫入成功）的請求。

## 實測重點與坑

| 項目 | 現象 | 說明 / 解法 |
| :--- | :--- | :--- |
| `configureReplicaSetInstance` | `replica_parallel_workers` 被 `SET PERSIST` 成 4 | 設定檔的值無效；用 `applierWorkerThreads` 選項指定，或 `SET PERSIST` |
| errant GTID | `addInstance` 拒絕增量加入 | 用 Clone；手動建從庫時先 `RESET BINARY LOGS AND GTIDS` |
| 主庫故障 | Router 關閉 6446，應用程式 `ERROR 2003` | ReplicaSet 不會自動 failover，要 `forcePrimaryInstance` |
| 舊主庫重啟 | `super_read_only = OFF`，可以被直接寫入 | 修好後先不要啟動服務，或以唯讀啟動再 `rejoinInstance` |
| 非同步 | failover 可能遺失已 commit 的交易 | 需要零遺失就用半同步或 InnoDB Cluster |
| 切換期間的寫入 | 全域鎖期間被擋住等待；偶爾打到舊主庫收到 `ERROR 1290` | 應用程式要有重試 |

## 驗證方式與結果

```bash
./09-replicaset.sh   # 建立 ReplicaSet + Router、切換、kill 主庫、手動 failover、rejoin、最終核對
```

| 步驟 | 怎麼驗證 | 結果 |
| :--- | :--- | :--- |
| 3 建立 | `rs.status()` | ✅ 一主二從 ONLINE，複製走 TLS |
| 4 Router | 6446 / 6447 實際連到哪台 | ✅ 6446 → db1、6447 → db2 / db3 |
| 5 切換 | app 紀錄 | ✅ 0 失敗、最大停頓 0.25 秒（另一次 3 筆失敗、0.92 秒） |
| 6~7 failover | app 紀錄、`rs.status()` | ✅ 手動 failover 後恢復，中斷 6.7 秒（含 5 秒人為等待） |
| 8 舊主庫 | `@@super_read_only` | ⚠️ 重啟後為 0（可寫），已重現 |
| 9 rejoin | `rs.status()` | ✅ 增量復原、三台 ONLINE |
| 10 最終 | app 成功筆數 vs 資料庫、三台 CRC | ✅ 67 筆全在、CRC 相同 |

## 小結

- ReplicaSet = **GTID 非同步複製 + AdminAPI + Router**，管理起來和 InnoDB Cluster 一樣方便，但沒有 Group Replication 的限制。
- **沒有自動 failover**，主庫掛掉要人下 `forcePrimaryInstance`；非同步複製下 failover 可能遺失資料。
- Clone 讓加節點變得很簡單，也會順便擋掉 errant GTID。
- 舊主庫修好後**不要直接啟動**，它是可寫的。

下一篇：[InnoDB ClusterSet 跨機房 DR]({% post_url 2026-11-20-mysql-ha-lab-10-innodb-clusterset %})。

### 參考資料

- [MySQL Shell 8.4：InnoDB ReplicaSet](https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-innodb-replicaset.html)
- [MySQL Shell 8.4：Planned Changes of the Primary / Forcing the Primary Instance](https://dev.mysql.com/doc/mysql-shell/8.4/en/replicaset-adopting.html)
- [MySQL Router 8.4：Bootstrapping MySQL Router](https://dev.mysql.com/doc/mysql-router/8.4/en/mysql-router-deploying-bootstrapping.html)
- [MySQL 8.4 Reference Manual：The Clone Plugin](https://dev.mysql.com/doc/refman/8.4/en/clone-plugin.html)
