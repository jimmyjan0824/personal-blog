---
title: MySQL 高可用實作 10：InnoDB ClusterSet 跨機房 DR（Rocky Linux 9）
date: 2026-11-20 21:30:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql84, percona, rocky-linux, innodb-clusterset, innodb-cluster, group-replication, mysql-shell, mysql-router, disaster-recovery, failover, dba]
description: InnoDB ClusterSet 把兩個（以上）InnoDB Cluster 用非同步複製串起來，一個機房當主叢集、另一個當 DR。在 Percona Server 8.4.11 上用六台主機建立 clusterA / clusterB，實測計畫內切換機房（寫入停頓 3.5 秒）、主機房整個斷線後手動 forcePrimaryCluster（中斷 15.9 秒），以及斷線機房回來後 rebootClusterFromCompleteOutage 只恢復一台的陷阱。
media_subpath: /assets/img/posts/mysql-ha-lab-10
---

[Lab 05]({% post_url 2026-10-24-mysql-ha-lab-05-innodb-cluster %}) 的 InnoDB Cluster 可以撐過「一台機器掛掉」，但三台都在同一個機房；機房斷電、斷網，整個叢集一起消失。Group Replication 每筆交易都要多數派確認，也不適合把成員拆到延遲幾十毫秒的兩個機房。

**InnoDB ClusterSet** 的做法是：每個機房各自一個 InnoDB Cluster（機房內用 Group Replication 自動 failover），機房之間用一條**非同步複製通道**串起來。平常只有主叢集可以寫入，另一個叢集是隨時可以接手的 DR。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - Percona Server **8.4.11-12.1**、MySQL Shell **8.4.10**、MySQL Router **8.4.11**（都從 `ps-84-lts` 套件庫安裝）。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd（x86_64，4 vCPU / 15 GB）。六台 MySQL 同時跑，Docker 建議分配 8 GB 以上記憶體。文中的圖是實測輸出的終端機截圖。
> - 兩個「機房」在同一台主機的 Docker 網路上，沒有真實的跨機房延遲；這篇看的是操作流程和故障行為，不是跨機房效能。
> - 驗證腳本與完整輸出：[`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的 `10-clusterset.sh`、`results/10-clusterset.log`。
{: .prompt-warning }

## ClusterSet 是什麼

| | InnoDB Cluster（Lab 05） | **InnoDB ClusterSet** |
| :--- | :--- | :--- |
| 組成 | 一個 Group Replication 群組 | 一個主叢集 + 一或多個副本叢集，每個都是完整的 InnoDB Cluster |
| 機房內 failover | 自動 | 自動（各叢集自己的 GR） |
| 機房之間 | — | 非同步複製通道 `clusterset_replication` |
| 機房層級 failover | — | **手動**：`forcePrimaryCluster` |
| 計畫內切換機房 | — | 一行 `setPrimaryCluster` |
| 主機房故障可能遺失資料 | — | 是（跨機房是非同步） |
| Router | 找叢集的主節點 | 找「主叢集」的主節點，切換後自動跟上 |

ClusterSet 不會因為主叢集連不上就自動切換機房。這是刻意的設計：跨機房網路斷線時，Shell 沒辦法分辨「主機房真的掛了」還是「只是兩邊連不到」，自動切換很容易造成兩邊都在寫的 split-brain。

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1`~`db3` | 192.168.58.11~13 | site A：`clusterA`（一開始的主叢集） |
| `db4`~`db6` | 192.168.58.14~16 | site B：`clusterB`（副本叢集） |
| `router` | 192.168.58.20 | MySQL Router（6446 讀寫、6447 唯讀） |
| `app` | 192.168.58.30 | 每 0.2 秒透過 `router:6446` 寫一筆 |

每台的設定檔和 [Lab 09]({% post_url 2026-11-20-mysql-ha-lab-09-innodb-replicaset %}) 一樣：`00-server.cnf` + `replication.cnf`（GTID、binlog、`replica_preserve_commit_order`），`server_id`、`report_host` 每台不同。

## 步驟 1：六台 configureInstance

```bash
mysqlsh --js -e "dba.configureInstance(null, {clusterAdmin: \"'clusteradmin'@'192.168.58.%'\", clusterAdminPassword: '...', restart: false})"
```

六台都回 `The instance 'dbN:3306' is valid for InnoDB Cluster usage.`，並建立管理帳號 `clusteradmin`。後面的 AdminAPI 操作都用這個帳號連線。

## 步驟 2：site A 建立 clusterA

和 Lab 05 一樣，在 `db1` 建立叢集，再用 Clone 加入 `db2`、`db3`：

```js
var c = dba.createCluster('clusterA')
dba.getCluster().addInstance('db2:3306', {recoveryMethod: 'clone'})
dba.getCluster().addInstance('db3:3306', {recoveryMethod: 'clone'})
```

```text
* Clone process has finished: 78.15 MB transferred in about 1 second (~78.15 MB/s)
The instance 'db2:3306' was successfully added to the cluster.
* Clone process has finished: 77.31 MB transferred in about 1 second (~77.31 MB/s)
The instance 'db3:3306' was successfully added to the cluster.
```

## 步驟 3：建立 ClusterSet 與副本叢集

先把 `clusterA` 升級成 ClusterSet，再用 `createReplicaCluster` 在 site B 的 `db4` 建立 `clusterB`：

```js
dba.getCluster().createClusterSet('cs_lab')
var cs = dba.getClusterSet();
cs.createReplicaCluster('db4:3306', 'clusterB', {recoveryMethod: 'clone'})
```

![createReplicaCluster：errant GTID 被 Clone 蓋掉，建立跨叢集複製通道](01-replica-cluster.png)

幾個重點：

- `db4` 初始化時（設定 root 密碼等）留下一筆本機的 GTID，也就是 errant GTID。Shell 會警告「這台有不屬於 ClusterSet 的交易」；指定 `recoveryMethod: 'clone'` 時，Clone 會整個覆蓋資料目錄，這筆就消失了。
- 副本叢集先建立成只有一台的 InnoDB Cluster，再設定 **`clusterset_replication`** 通道：`Changing replication source of db4:3306 to db1:3306`。
- 接著用一般的 `addInstance` 把 `db5`、`db6` 加進 `clusterB`（在 `db4` 上執行）。

```js
// 在 db4
dba.getCluster().addInstance('db5:3306', {recoveryMethod: 'clone'})
dba.getCluster().addInstance('db6:3306', {recoveryMethod: 'clone'})
```

![cs.status()：clusterA 為 PRIMARY、clusterB 為 REPLICA](02-status.png)

`db4` 上可以看到跨叢集的複製通道，以及 `clusterB` 自己的 Group Replication 成員：

![db4 的 clusterset_replication 通道與 clusterB 成員](03-channel.png)

`SOURCE_CONNECTION_AUTO_FAILOVER = 1`：主叢集內部換主節點時，這條通道會自動改接新的主節點，不需要人處理。只有副本叢集的 PRIMARY（`db4`）在接收，`db5`、`db6` 再透過 `clusterB` 的 Group Replication 拿到資料。

## 步驟 4：Router bootstrap 到 ClusterSet

Router bootstrap 時連到 ClusterSet 的任何一台都可以，它會偵測到這是 ClusterSet：

```bash
mysqlrouter --bootstrap 'clusteradmin:...@db1:3306' --user=mysqlrouter
systemctl enable --now mysqlrouter
```

![Router bootstrap 到 ClusterSet，並在 listRouters() 看到它](04-router.png)

`targetCluster: null` 代表 Router 的預設行為是「跟著主叢集走」：6446 永遠連到主叢集的主節點。也可以用 `cs.setRoutingOption('router::system', 'target_cluster', 'clusterB')` 把某台 Router 固定在某個叢集，例如讓 site B 的報表程式只讀本地的副本叢集。8.4 的 Router 多了 6450 讀寫分離埠（`rwSplitPort`），這篇沒有用到。

接著 `app` 開始每 0.2 秒寫一筆到 `router:6446`，目前都寫到 `db1`。

## 步驟 5：計畫內切換機房

情境：site A 要停機維護，先把主叢集切到 site B：

```js
var cs = dba.getClusterSet(); cs.setPrimaryCluster('clusterB')
```

![setPrimaryCluster('clusterB')：主叢集換到 site B，寫入停頓 3.5 秒](05-switchover.png)

`setPrimaryCluster` 依序做這些事：

1. 確認兩個叢集都可用，等 `clusterB` 套用完已經收到的交易。
2. 把 `clusterA` 三台的複製來源改成 `db4`（`Changing replication source of db1:3306 to db4:3306`）。
3. 在所有成員取得**全域鎖**（`Acquiring global lock at PRIMARY / SECONDARIES`），補齊最後的交易。
4. 把 `clusterB` 升為 PRIMARY，`clusterA` 降為 REPLICA 並設成唯讀。

`app` 在這段期間收到 **14 筆 `ERROR 1290`**（`--read-only`）：`clusterA` 已經被設成唯讀，但 Router 還沒發現主叢集換了，連線還是送到 `db1`。從最後一筆寫進 `db1` 到第一筆寫進 `db4`，中間停了 **3.5 秒**。這比 Lab 09 ReplicaSet 的切換（0.25 秒）慢很多，因為兩個叢集的所有成員都要同步、上鎖，Router 也要從 metadata 發現新的主叢集。應用程式要能重試 `1290`。

切換完成後，`cs.status()` 的 `primaryCluster` 變成 `clusterB`、`globalPrimaryInstance` 是 `db4:3306`。

## 步驟 6：災難：主機房整個斷線

現在主叢集是 site B。模擬機房斷電：`db4`、`db5`、`db6` 一起 `kill -9`，然後停止服務。

```bash
# db4、db5、db6
systemctl kill -s KILL mysqld; systemctl stop mysqld
```

![site B 全部斷線：ClusterSet UNAVAILABLE，不會自動切換](06-site-down.png)

`cs.status()` 的 `status` 變成 **`UNAVAILABLE`**：`Primary Cluster is not reachable from the Shell, assuming it to be unavailable.` site A 的 `clusterA` 三台都還活著（`globalStatus: OK`），但它是副本叢集、唯讀，複製通道一直在 `CONNECTING`。**ClusterSet 不會自己把 clusterA 升上來**，Router 的 6446 也關了，`app` 收到 `ERROR 2003 Can't connect to MySQL server on 'router:6446'`。

## 步驟 7：在 site A 強制升為主叢集

確認 site B 真的掛了（不是只是網路斷了）之後，在 site A 執行：

```js
var cs = dba.getClusterSet(); cs.forcePrimaryCluster('clusterA')
```

![forcePrimaryCluster('clusterA')：舊主叢集被 INVALIDATED，Shell 提醒 split-brain](07-force-primary.png)

- `Checking whether target cluster has the most recent GTID set`：如果有多個副本叢集，Shell 會確認你選的這個資料最新。
- `Former PRIMARY cluster 'clusterB' was INVALIDATED, transactions that were not yet replicated may be lost.`：跨機房是非同步複製，site B 上還沒傳到 site A 的交易會遺失。這次實測 site B 斷線前寫進 `db4` 的 6 筆都已經複製過來（最後一節的核對），因為兩個「機房」之間幾乎沒有延遲；真實的跨機房環境不能保證。
- Shell 提醒：如果只是網路分區，舊的主叢集可能還活著，**兩邊都可以寫就是 split-brain**。要先用 `<Cluster>.fenceAllTraffic()` 或 `fenceWrites()` 把舊主叢集隔離。

`forcePrimaryCluster` 本身只花幾秒；從下指令到 Router 從 metadata 發現新的主叢集、重新打開 6446，大約 10 秒。從 site B 斷線到第一筆寫進 `db1`，`app` 中斷 **15.9 秒**、26 筆失敗，其中約 6 秒是腳本刻意等待、看 `cs.status()` 的「人工判斷」時間。實務上人工判斷要花的時間通常是分鐘等級，這才是 ClusterSet 機房 failover 的 RTO 主體。

## 步驟 8：斷線的機房回來之後

site B 修好，三台重新啟動。它們不會自己回到 ClusterSet：

```text
"clusterB": {
    "clusterErrors": [
        "ERROR: Cluster members are reachable but they're all OFFLINE.",
        "WARNING: Replication channel from the Primary Cluster is missing",
        "WARNING: Cluster was invalidated and must be either removed from the ClusterSet or rejoined"
    ],
    "globalStatus": "INVALIDATED",
    "status": "OFFLINE",
```

三台都停過，所以 `clusterB` 的 Group Replication 要先用 `rebootClusterFromCompleteOutage` 重新啟動：

```js
// 在 db4
dba.rebootClusterFromCompleteOutage('clusterB')
```

![rebootClusterFromCompleteOutage：叢集已被 INVALIDATED，只恢復 seed 一台](08-reboot.png)

**陷阱**：一般的 InnoDB Cluster 執行 `rebootClusterFromCompleteOutage` 會把所有成員都加回來，但這裡 `clusterB` 已經被 ClusterSet 標成 INVALIDATED，Shell 只恢復 seed（`db4`），其他兩台跳過：`Skipping rejoining remaining instances because the Cluster belongs to a ClusterSet and is INVALIDATED.` 所以接下來是兩段：

```js
// 在 db1（主叢集）：把 clusterB 加回 ClusterSet
var cs = dba.getClusterSet(); cs.rejoinCluster('clusterB')
// 在 db4：把 db5、db6 加回 clusterB
dba.getCluster().rejoinInstance('db5:3306')
dba.getCluster().rejoinInstance('db6:3306')
```

![rejoinCluster 之後，再逐台 rejoinInstance](09-rejoin.png)

`rejoinCluster` 把 `db4` 的複製來源改成新的主叢集 `db1`。`db5`、`db6` 的 GTID 和叢集一致，Shell 自動選擇增量復原（`Incremental state recovery was selected`），不需要 Clone。

如果 site B 斷線前有交易**沒有**複製到 site A，`rejoinCluster` 會發現 `clusterB` 有 errant GTID 而拒絕加入。這時只能把 `clusterB` 移除（`cs.removeCluster('clusterB', {force: true})`），清掉資料重新 `createReplicaCluster`；那些交易要另外從 binlog 撈出來人工判斷。

最後 `cs.status({extended: 1})` 回到 `HEALTHY`，`clusterB` 的 `transactionSetConsistencyStatus: OK`、`transactionSetErrantGtidSet` 為空，跨叢集複製走 TLS 1.3。

## 最終驗證

![最終驗證：app 成功的 401 筆全在，六台筆數與 CRC 相同](10-final.png)

`app` 共成功寫入 401 筆（395 筆寫到 `db1`、6 筆寫到 `db4`），全部都在；六台的筆數 5401（5000 筆初始資料 + 401）、CRC 完全相同。

## 實測遇到的坑

| 項目 | 現象 | 說明 / 解法 |
| :--- | :--- | :--- |
| 主機房故障 | `cs.status()` UNAVAILABLE、Router 關閉 6446 | ClusterSet 不會自動切換機房，要人判斷後 `forcePrimaryCluster` |
| 網路分區 | 舊主叢集可能還活著 | 先 `fenceAllTraffic()` / `fenceWrites()`，避免 split-brain |
| 計畫內切換 | 14 筆 `ERROR 1290`，停頓 3.5 秒 | 舊主叢集先被設成唯讀、Router 稍後才跟上；應用程式要重試 |
| 舊主叢集回來 | `rebootClusterFromCompleteOutage` 只恢復 seed | INVALIDATED 的叢集要 `rejoinCluster`，再逐台 `rejoinInstance` |
| errant GTID | `createReplicaCluster` 警告有不屬於 ClusterSet 的交易 | 用 Clone 覆蓋；若是舊主叢集上沒複製出去的交易，`rejoinCluster` 會拒絕 |
| 記憶體 | 六台 MySQL + Router 同時跑 | Docker 分配 8 GB 以上；實際環境每個機房至少三台 |

## 驗證方式與結果

```bash
./10-clusterset.sh   # 建立兩個叢集 + ClusterSet + Router、切換、整個機房斷線、forcePrimaryCluster、恢復、最終核對
```

| 步驟 | 怎麼驗證 | 結果 |
| :--- | :--- | :--- |
| 3 建立 | `cs.status()`、`clusterset_replication` 通道 | ✅ HEALTHY，`db4` 從 `db1` 複製 |
| 4 Router | `listRouters()`、app 紀錄 | ✅ 6446 → `db1` |
| 5 切換機房 | app 紀錄 | ✅ 主叢集換到 `clusterB`，14 筆失敗、停頓 3.5 秒 |
| 6 機房斷線 | `cs.status()` | ✅ UNAVAILABLE，不會自動切換（符合設計） |
| 7 強制切換 | app 紀錄、`cs.status()` | ✅ `clusterA` 接手，中斷 15.9 秒（含約 6 秒人工判斷） |
| 8 恢復 | `cs.status({extended: 1})` | ⚠️ reboot 只恢復 seed；`rejoinCluster` + `rejoinInstance` 後 HEALTHY |
| 最終 | app 成功筆數 vs 資料庫、六台 CRC | ✅ 401 筆全在、六台 CRC 相同 |

## 小結

- ClusterSet = **每個機房一個 InnoDB Cluster + 機房之間一條非同步複製通道 + Router 跟著主叢集走**。
- 機房內的故障由 Group Replication 自動處理；**機房層級的 failover 一定是手動的**，而且可能遺失還沒複製過去的交易。
- `setPrimaryCluster` 適合計畫內維護，寫入會停頓幾秒；`forcePrimaryCluster` 用在真正的災難，之後記得隔離舊主叢集。
- 舊主叢集回來後：`rebootClusterFromCompleteOutage`（只恢復一台）→ `rejoinCluster` → 逐台 `rejoinInstance`。

下一篇：[多來源、延遲與過濾複製]({% post_url 2026-11-20-mysql-ha-lab-11-multisource-delayed-filter %})。

### 參考資料

- [MySQL Shell 8.4：InnoDB ClusterSet](https://dev.mysql.com/doc/mysql-shell/8.4/en/innodb-clusterset.html)
- [MySQL Shell 8.4：Controlled Switchover for InnoDB ClusterSet](https://dev.mysql.com/doc/mysql-shell/8.4/en/innodb-clusterset-controlled-switchover.html)
- [MySQL Shell 8.4：Emergency Failover for InnoDB ClusterSet](https://dev.mysql.com/doc/mysql-shell/8.4/en/innodb-clusterset-emergency-failover.html)
