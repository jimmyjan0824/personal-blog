---
title: MySQL 高可用實作 05：InnoDB Cluster（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:14:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, innodb-cluster, mysql-shell, mysql-router, group-replication, dba]
description: 用 Percona Server 8.0.46、Percona MySQL Shell 與 MySQL Router 建立三節點 InnoDB Cluster，實測 Clone 自動補資料、Router 讀寫分流、主庫宕機自動切換與全叢集停機後重啟。
---

上一篇手動建 [Group Replication]({% post_url 2026-10-24-mysql-ha-lab-04-group-replication %}) 要處理設定檔、復原帳號、GTID、bootstrap 等細節。**InnoDB Cluster** 把這些包起來：

- **MySQL Shell（AdminAPI）**：檢查、設定節點，建立與管理叢集。
- **Group Replication**：資料層，和上一篇一樣。
- **MySQL Router**：應用程式連 Router，Router 依叢集狀態把流量導到目前的 Primary。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構

| 主機 | IP | 安裝套件 | 角色 |
| :--- | :--- | :--- | :--- |
| `db1` | 192.168.56.11 | `percona-server-server`、`percona-mysql-shell` | 叢集成員 |
| `db2` | 192.168.56.12 | `percona-server-server`、`percona-mysql-shell` | 叢集成員 |
| `db3` | 192.168.56.13 | `percona-server-server`、`percona-mysql-shell` | 叢集成員 |
| `router` | 192.168.56.20 | `percona-mysql-router`、`percona-server-client` | 應用程式端的 Router |

Router 官方建議與應用程式裝在同一台，這裡為了示範獨立一台。

## 步驟 0：主機準備（四台都做）

```bash
cat >> /etc/hosts <<'EOF'
192.168.56.11 db1
192.168.56.12 db2
192.168.56.13 db3
192.168.56.20 router
EOF
```

防火牆（**未實測**，容器內沒有 firewalld）：

```bash
# db1~db3：8.0.27+ 的 InnoDB Cluster 預設 communicationStack 為 MYSQL，
# GR 成員間直接走 3306，不再需要 33061；33060 為 X Protocol
sudo firewall-cmd --permanent --add-port=3306/tcp --add-port=33060/tcp
# router：讀寫 6446、唯讀 6447（X Protocol 為 6448/6449）
sudo firewall-cmd --permanent --add-port=6446-6449/tcp
sudo firewall-cmd --reload
```

## 步驟 1：安裝套件

> 這一步**未實測**，測試環境連不到 `repo.percona.com`。`db1`~`db3` 使用 Percona 官方映像裡已安裝的同版本 RPM；`router` 則是把 Percona 官方 Router 映像中 `percona-mysql-router-8.0.46-37.1.el9` 套件的檔案放進節點，並建立該 RPM 會建立的 `mysqlrouter` 系統帳號，之後的 `systemctl` 操作都是真的執行。
{: .prompt-warning }

```bash
# db1~db3
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release setup ps80
sudo dnf install -y percona-server-server percona-mysql-shell

# router
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release setup ps80
sudo dnf install -y percona-mysql-router percona-server-client
```

確認版本（實測輸出）：

```console
db1# mysqlsh --version
mysqlsh   Ver 8.0.46 for Linux on x86_64 - for MySQL 8.0.46-37 (Source distribution)
router# mysqlrouter --version
MySQL Router  Ver 8.0.46-37 for Linux on x86_64 (Percona Server (GPL), Release 37, Revision 39e2b60e)
```

> MySQL Shell 與 Router 的版本要**大於等於** MySQL Server 的版本。
{: .prompt-info }

## 步驟 2：最小設定檔（db1~db3）

GTID、binlog 這些設定交給 `dba.configureInstance()` 處理，設定檔只放每台不同的東西：

```ini
# /etc/my.cnf.d/ic.cnf
[mysqld]
server_id     = 1        # db1=1、db2=2、db3=3
report_host   = db1      # 填自己的主機名
bind_address  = 0.0.0.0
disabled_storage_engines = "MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"
```

啟動並改 root 密碼（同 [GTID 篇步驟 3]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %})）：

```bash
sudo systemctl enable --now mysqld
TMP=$(sudo grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print $NF}')
mysql -uroot -p"$TMP" --connect-expired-password \
  -e "ALTER USER root@localhost IDENTIFIED BY 'Root#Pass2026';"
```

## 步驟 3：configureInstance（db1~db3 各自執行）

root 只能從 localhost 登入，直接檢查會被擋：

```console
db1# mysqlsh --js -uroot -p -S /var/lib/mysql/mysql.sock -e "dba.checkInstanceConfiguration()"
ERROR: New account(s) with proper source address specification to allow remote connection from all instances must be created to manage the cluster.
Dba.checkInstanceConfiguration: User 'root' can only connect from 'localhost'. (RuntimeError)
```

`configureInstance` 會順便建立可以遠端管理的叢集管理帳號，並修正所有不符合的設定，必要時自動重啟：

```bash
mysqlsh --js -uroot -p -S /var/lib/mysql/mysql.sock -e "
dba.configureInstance(null, {
  clusterAdmin: \"'clusteradmin'@'%'\",
  clusterAdminPassword: 'Clus#Pass2026',
  restart: true
})"
```

```console
Configuring local MySQL instance listening at port 3306 for use in an InnoDB cluster...

This instance reports its own address as db1:3306

applierWorkerThreads will be set to the default value of 4.

NOTE: Some configuration options need to be fixed:
+----------------------------------------+---------------+----------------+--------------------------------------------------+
| Variable                               | Current Value | Required Value | Note                                             |
+----------------------------------------+---------------+----------------+--------------------------------------------------+
| binlog_transaction_dependency_tracking | COMMIT_ORDER  | WRITESET       | Update the server variable                       |
| enforce_gtid_consistency               | OFF           | ON             | Update read-only variable and restart the server |
| gtid_mode                              | OFF           | ON             | Update read-only variable and restart the server |
+----------------------------------------+---------------+----------------+--------------------------------------------------+

Some variables need to be changed, but cannot be done dynamically on the server.

Creating user clusteradmin@%.
Account clusteradmin@% was successfully created.

Configuring instance...

WARNING: '@@binlog_transaction_dependency_tracking' is deprecated and will be removed in a future release. (Code 1287).
The instance 'db1:3306' was configured to be used in an InnoDB cluster.
Restarting MySQL...
NOTE: MySQL server at db1:3306 was restarted.
```

`configureInstance` 用 `SET PERSIST` 改設定，所以 `/etc/my.cnf.d/` 裡看不到，要看 `/var/lib/mysql/mysqld-auto.cnf`。它在 systemd 下可以直接用 `RESTART` 指令重啟，不用手動 `systemctl restart`。三台做完後：

```console
db1	ON	ON	1
db2	ON	ON	2
db3	ON	ON	3
```

（`SELECT @@hostname, @@gtid_mode, @@enforce_gtid_consistency, @@server_id`）

> 在腳本或 `-e` 裡執行 `mysqlsh` 時，請加 `--no-wizard`。實測沒加的時候，`configureInstance` 在沒有終端機的環境下會停在互動確認，CPU 吃滿且永遠不會結束。在終端機裡手動執行則會正常詢問。
{: .prompt-danger }

## 步驟 4：建立叢集（在 db1）

之後都用 `clusteradmin` 從任一台遠端操作：

```bash
mysqlsh --js clusteradmin@db1:3306
```

```javascript
var cluster = dba.createCluster('myCluster')
```

```console
A new InnoDB Cluster will be created on instance 'db1:3306'.

Validating instance configuration at db1:3306...

This instance reports its own address as db1:3306

Instance configuration is suitable.
NOTE: Group Replication will communicate with other members using 'db1:3306'. Use the localAddress option to override.

* Checking connectivity and SSL configuration...

Creating InnoDB Cluster 'myCluster' on 'db1:3306'...

Adding Seed Instance...
Cluster successfully created. Use Cluster.addInstance() to add MySQL instances.
At least 3 instances are needed for the cluster to be able to withstand up to
one server failure.
```

注意 `communicate with other members using 'db1:3306'`：成員之間走 3306，這是 8.0.27 起預設的 MySQL 通訊堆疊。

先寫一點資料，等一下看新節點會不會自動帶過去：

```sql
CREATE DATABASE shop;
CREATE TABLE shop.orders (id INT AUTO_INCREMENT PRIMARY KEY, item VARCHAR(50), amount DECIMAL(10,2));
INSERT INTO shop.orders (item, amount) VALUES ('keyboard', 1290), ('mouse', 590), ('monitor', 6990);
```

## 步驟 5：加入 db2、db3（Clone 自動補資料）

```javascript
cluster.addInstance('clusteradmin@db2:3306', {recoveryMethod: 'clone'})
cluster.addInstance('clusteradmin@db3:3306', {recoveryMethod: 'clone'})
```

`db2` 的實測輸出：

```console
NOTE: The target instance 'db2:3306' has not been pre-provisioned (GTID set is empty). The Shell is unable to decide whether incremental state recovery can correctly provision it.

Clone based recovery selected through the recoveryMethod option

Validating instance configuration at db2:3306...
Instance configuration is suitable.
...
Adding instance to the cluster...

Monitoring recovery process of the new cluster member. Press ^C to stop monitoring and let it continue in background.
Clone based state recovery is now in progress.

NOTE: A server restart is expected to happen as part of the clone process. If the
server does not support the RESTART command or does not come back after a
while, you may need to manually start it back.

* Waiting for clone to finish...
NOTE: db2:3306 is being cloned from db1:3306
** Stage DROP DATA: Completed
** Stage FILE COPY: Completed
** Stage PAGE COPY: Completed
** Stage REDO COPY: Completed

NOTE: db2:3306 is shutting down...

* Waiting for server restart... ready
** Stage FILE SYNC: Completed
** Stage RESTART: Completed
* Clone process has finished: 74.82 MB transferred in about 1 second (~74.82 MB/s)

State recovery already finished for 'db2:3306'

The instance 'db2:3306' was successfully added to the cluster.
```

Clone 會把 `db1` 的資料整份複製過來（包含上一篇要手動處理的 GTID 狀態與使用者帳號），然後自動重啟 `db2`。不用 `mysqldump`，也不用 `RESET MASTER`。

## 步驟 6：查看叢集狀態

```javascript
cluster.status()
```

```json
{
    "clusterName": "myCluster",
    "defaultReplicaSet": {
        "name": "default",
        "primary": "db1:3306",
        "ssl": "REQUIRED",
        "status": "OK",
        "statusText": "Cluster is ONLINE and can tolerate up to ONE failure.",
        "topology": {
            "db1:3306": {
                "address": "db1:3306",
                "memberRole": "PRIMARY",
                "mode": "R/W",
                "readReplicas": {},
                "replicationLag": "applier_queue_applied",
                "role": "HA",
                "status": "ONLINE",
                "version": "8.0.46"
            },
            "db2:3306": {
                "address": "db2:3306",
                "memberRole": "SECONDARY",
                "mode": "R/O",
                "readReplicas": {},
                "replicationLag": "applier_queue_applied",
                "role": "HA",
                "status": "ONLINE",
                "version": "8.0.46"
            },
            "db3:3306": {
                "address": "db3:3306",
                "memberRole": "SECONDARY",
                "mode": "R/O",
                "readReplicas": {},
                "replicationLag": "applier_queue_applied",
                "role": "HA",
                "status": "ONLINE",
                "version": "8.0.46"
            }
        },
        "topologyMode": "Single-Primary"
    },
    "groupInformationSourceMember": "db1:3306"
}
```

`status` 為 `OK`、`can tolerate up to ONE failure`，三節點叢集建立完成。

## 步驟 7：設定 MySQL Router（在 router）

```bash
sudo mysqlrouter --bootstrap clusteradmin@db1:3306 --user=mysqlrouter
```

```console
Please enter MySQL password for clusteradmin:
# Bootstrapping system MySQL Router 8.0.46 (Percona Server (GPL), Release 37, Revision 39e2b60e) instance...

- Creating account(s) (only those that are needed, if any)
- Verifying account (using it to run SQL queries that would be run by Router)
- Storing account in keyring
- Adjusting permissions of generated files
- Creating configuration /etc/mysqlrouter/mysqlrouter.conf

Existing configuration backed up to '/etc/mysqlrouter/mysqlrouter.conf.bak'

# MySQL Router configured for the InnoDB Cluster 'myCluster'

After this MySQL Router has been started with the generated configuration

    $ /etc/init.d/mysqlrouter restart
or
    $ systemctl start mysqlrouter
or
    $ mysqlrouter -c /etc/mysqlrouter/mysqlrouter.conf

InnoDB Cluster 'myCluster' can be reached by connecting to:

## MySQL Classic protocol

- Read/Write Connections: localhost:6446
- Read/Only Connections:  localhost:6447

## MySQL X protocol

- Read/Write Connections: localhost:6448
- Read/Only Connections:  localhost:6449
```

bootstrap 會自動在叢集裡建立 Router 專用帳號，並產生設定檔。路由規則：

```console
router# grep -E '^\[routing|bind_port|destinations' /etc/mysqlrouter/mysqlrouter.conf
[routing:bootstrap_rw]
bind_port=6446
destinations=metadata-cache://myCluster/?role=PRIMARY
[routing:bootstrap_ro]
bind_port=6447
destinations=metadata-cache://myCluster/?role=SECONDARY
[routing:bootstrap_x_rw]
bind_port=6448
destinations=metadata-cache://myCluster/?role=PRIMARY
[routing:bootstrap_x_ro]
bind_port=6449
destinations=metadata-cache://myCluster/?role=SECONDARY
```

啟動：

```console
router# systemctl enable --now mysqlrouter
Created symlink /etc/systemd/system/multi-user.target.wants/mysqlrouter.service → /usr/lib/systemd/system/mysqlrouter.service.
router# systemctl status mysqlrouter --no-pager
● mysqlrouter.service - Percona MySQL Router
     Loaded: loaded (/usr/lib/systemd/system/mysqlrouter.service; enabled; preset: enabled)
     Active: active (running) since Sat 2026-10-24 03:39:34 UTC; 2s ago
   Main PID: 80 (mysqlrouter)
     Status: "running"
```

> 不要加 `--conf-use-sockets`。Percona 的 `mysqlrouter.service` 設了 `PrivateTmp=true`，Router 建的 `/tmp/mysql.sock` 實際上落在 `/tmp/systemd-private-*-mysqlrouter.service-*/tmp/`，其他程式看不到。實測：
>
> `ERROR 2002 (HY000): Can't connect to local MySQL server through socket '/tmp/mysql.sock' (2)`
>
> 走 TCP 6446/6447 即可。
{: .prompt-tip }

## 步驟 8：透過 Router 驗證讀寫分流

在 Primary 建立應用程式帳號：

```sql
CREATE USER 'app'@'%' IDENTIFIED BY 'App#Pass2026';
GRANT SELECT, INSERT, UPDATE, DELETE ON shop.* TO 'app'@'%';
```

從 `router` 分別連 6446、6447：

```console
router# for p in 6446 6447 6447 6447; do mysql -h127.0.0.1 -P$p -uapp -p'App#Pass2026' -NBe "SELECT $p AS port, @@hostname, @@super_read_only"; done
6446	db1	0
6447	db2	1
6447	db3	1
6447	db2	1
```

- 6446 永遠到 Primary（`db1`），可寫入。
- 6447 在 Secondary 之間輪流分配，唯讀。

## 步驟 9：故障演練：Primary 宕機

停掉 `db1`，同時每秒透過 Router 的 6446 寫入一次：

```console
## stop db1 at 03:39:55
03:40:03 6446 -> db2
03:40:04 6446 -> db2
03:40:06 6446 -> db2
03:40:07 6446 -> db2
...
```

`systemctl stop mysqld` 本身花了幾秒做正常關機，關機完成後第一次寫入就已經被 Router 導到新的 Primary `db2`，**應用程式的連線設定完全不用改**。Router 日誌：

```console
router# grep metadata_cache /var/log/mysqlrouter/mysqlrouter.log | tail -6
2026-10-24 03:39:59 metadata_cache WARNING [7fdc9876f640] Member db1:3306 (e68a4e42-cf5b-11f1-b50c-563bd41dd4b4) defined in metadata not found in actual Group Replication
2026-10-24 03:39:59 metadata_cache INFO [7fdc9876f640] Potential changes detected in cluster after metadata refresh (view_id=0)
2026-10-24 03:39:59 metadata_cache INFO [7fdc9876f640] Metadata for cluster 'myCluster' has 3 member(s), single-primary:
2026-10-24 03:39:59 metadata_cache INFO [7fdc9876f640]     db1:3306 / 33060 - mode=n/a
2026-10-24 03:39:59 metadata_cache INFO [7fdc9876f640]     db2:3306 / 33060 - mode=RW
2026-10-24 03:39:59 metadata_cache INFO [7fdc9876f640]     db3:3306 / 33060 - mode=RO
```

此時叢集狀態：

```console
        "primary": "db2:3306",
        "status": "OK_NO_TOLERANCE_PARTIAL",
        "statusText": "Cluster is NOT tolerant to any failures. 1 member is not active.",
            "db1:3306": {
                "shellConnectError": "MySQL Error 2003: Could not open connection to 'db1:3306': Can't connect to MySQL server on 'db1:3306' (111)",
                "status": "(MISSING)"
```

## 步驟 10：節點恢復與切回主庫

AdminAPI 建立叢集時會把每個成員的 `group_replication_start_on_boot` 設為 `ON`（實測三台 `SELECT @@group_replication_start_on_boot` 都是 `1`），所以 `db1` 開機後會自動加回：

```console
db1# systemctl start mysqld
```

```console
db1:3306  SECONDARY  R/O  ONLINE
db2:3306  PRIMARY  R/W  ONLINE
db3:3306  SECONDARY  R/O  ONLINE
Cluster is ONLINE and can tolerate up to ONE failure.
```

想把 Primary 換回 `db1`：

```javascript
cluster.setPrimaryInstance('db1:3306')
```

```console
Setting instance 'db1:3306' as the primary instance of cluster 'myCluster'...

Instance 'db3:3306' remains SECONDARY.
Instance 'db1:3306' was switched from SECONDARY to PRIMARY.
Instance 'db2:3306' was switched from PRIMARY to SECONDARY.

The instance 'db1:3306' was successfully elected as primary.
```

Router 自動跟上，6446 又回到 `db1`。

## 步驟 11：全叢集停機後重啟

機房斷電這類情況，三台全部停機後再開機，節點會停在 `OFFLINE`，因為沒有群組可以加入：

```console
db1# mysql -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
+-------------+--------------+-------------+
| MEMBER_HOST | MEMBER_STATE | MEMBER_ROLE |
+-------------+--------------+-------------+
| db1         | OFFLINE      |             |
+-------------+--------------+-------------+
```

用 `rebootClusterFromCompleteOutage()`，它會比對各節點的 GTID，選出資料最完整的節點重新 bootstrap，再把其他節點加回來：

```javascript
var cluster = dba.rebootClusterFromCompleteOutage('myCluster')
```

```console
Restoring the Cluster 'myCluster' from complete outage...

Cluster instances: 'db1:3306' (OFFLINE), 'db2:3306' (OFFLINE), 'db3:3306' (OFFLINE)
Waiting for instances to apply pending received transactions...
...
* Waiting for seed instance to become ONLINE...
db1:3306 was restored.
...
The instance 'db2:3306' was successfully rejoined to the cluster.
...
The instance 'db3:3306' was successfully rejoined to the cluster.

The Cluster was successfully rebooted.

Cluster is ONLINE and can tolerate up to ONE failure.
```

```console
+-------------+--------------+-------------+
| MEMBER_HOST | MEMBER_STATE | MEMBER_ROLE |
+-------------+--------------+-------------+
| db1         | ONLINE       | PRIMARY     |
| db2         | ONLINE       | SECONDARY   |
| db3         | ONLINE       | SECONDARY   |
+-------------+--------------+-------------+
```

## 常用 AdminAPI 指令

| 指令 | 用途 |
| :--- | :--- |
| `dba.getCluster()` | 取得叢集物件 |
| `cluster.status()` / `cluster.status({extended: 1})` | 叢集狀態 |
| `cluster.describe()` | 叢集拓樸 |
| `cluster.addInstance()` / `cluster.removeInstance()` | 加入 / 移除節點 |
| `cluster.rejoinInstance()` | 讓脫離的節點重新加入 |
| `cluster.setPrimaryInstance()` | 切換 Primary |
| `cluster.listRouters()` | 列出已註冊的 Router |
| `dba.rebootClusterFromCompleteOutage()` | 全叢集停機後重啟 |

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `User 'root' can only connect from 'localhost'` | 叢集管理需要可遠端登入的帳號 | `configureInstance` 時用 `clusterAdmin` 建立 |
| `mysqlsh -e` 卡住不結束、CPU 100% | 非終端機環境下停在互動確認 | 加 `--no-wizard` |
| Router 的 `/tmp/mysql.sock` 連不到 | systemd 的 `PrivateTmp=true` | 不用 `--conf-use-sockets`，走 TCP |

## 小結

- InnoDB Cluster = Group Replication + MySQL Shell + MySQL Router，上一篇手動處理的 GTID、復原帳號、bootstrap 都由 AdminAPI 代勞。
- 新節點用 Clone 補資料，不需要 `mysqldump`。
- 實測 Primary 停機後，Router 自動把 6446 導到新 Primary；舊 Primary 回來自動以 Secondary 加入。
- 全叢集停機用 `rebootClusterFromCompleteOutage()` 恢復。

這個系列到這裡告一段落。回到 [高可用與災難復原]({% post_url 2026-10-24-mysql-ops-03-ha-dr %}) 可以看各種方案的 RPO / RTO 比較。

### 參考資料

- [MySQL Shell 8.0：MySQL InnoDB Cluster](https://dev.mysql.com/doc/mysql-shell/8.0/en/mysql-innodb-cluster.html)
- [MySQL Router 8.0：Bootstrapping MySQL Router](https://dev.mysql.com/doc/mysql-router/8.0/en/mysql-router-deploying-bootstrapping.html)
- [Percona Server for MySQL 8.0：Install Percona MySQL Shell / Router](https://docs.percona.com/percona-server/8.0/yum-repo.html)
