---
title: MySQL 高可用實作 04：Group Replication（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:13:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, group-replication, mgr, dba]
description: 不靠 MySQL Shell，手動以 Percona Server 8.0.46 建立三節點單主 Group Replication，實測主庫宕機自動選主、節點重新加入與手動切換主庫。
---

前面三篇的主從複製，主庫掛了要靠人或外部工具切換。**Group Replication（MGR）** 讓節點之間用 Paxos 協定達成共識，交易要多數節點同意才提交，主庫掛掉時群組會**自動選出新主庫**。

這篇刻意不用 MySQL Shell，全部用 SQL 手動建立，目的是看清楚 MGR 底下到底設定了什麼。實務上建議用下一篇的 [InnoDB Cluster]({% post_url 2026-10-24-mysql-ha-lab-05-innodb-cluster %}) 自動化管理。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構

| 主機 | IP | MySQL 埠 | GR 通訊埠 |
| :--- | :--- | :--- | :--- |
| `db1` | 192.168.56.11 | 3306 | 33061 |
| `db2` | 192.168.56.12 | 3306 | 33061 |
| `db3` | 192.168.56.13 | 3306 | 33061 |

單主模式（Single-Primary），三台可容忍一台故障。節點數建議用奇數，3 台或 5 台。

## 步驟 0：主機準備（三台都做）

```bash
cat >> /etc/hosts <<'EOF'
192.168.56.11 db1
192.168.56.12 db2
192.168.56.13 db3
EOF
```

防火牆與 SELinux（**未實測**，容器內沒有 firewalld 與 SELinux）：

```bash
sudo firewall-cmd --permanent --add-port=3306/tcp --add-port=33061/tcp
sudo firewall-cmd --reload

# SELinux Enforcing 時，讓 mysqld 可以使用 33061
sudo dnf install -y policycoreutils-python-utils
sudo semanage port -a -t mysqld_port_t -p tcp 33061
```

## 步驟 1：安裝 Percona Server（三台都做）

與 [GTID 篇的步驟 1]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 相同：

```bash
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release setup ps80
sudo dnf install -y percona-server-server
```

GR 外掛已經包含在 `percona-server-server` 裡，不需要另外安裝：`/usr/lib64/mysql/plugin/group_replication.so`。

## 步驟 2：設定檔（三台都放）

dnf 安裝的 `/etc/my.cnf` 沒有 `!includedir /etc/my.cnf.d`，**先補上**，否則下面的 `gr.cnf` 不會被讀到（原因與實測錯誤見 [GTID 篇步驟 2-1]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %})）：

```bash
grep -q '^!includedir /etc/my.cnf.d' /etc/my.cnf || echo '!includedir /etc/my.cnf.d' >> /etc/my.cnf
```

效能與運維的基礎設定（buffer pool、redo log、I/O、連線、慢查詢日誌等）請直接沿用 [GTID 篇步驟 2-2]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 的 `/etc/my.cnf.d/00-server.cnf`，三台都放同一份。實測套用這份設定後，叢集建立與資料同步都正常。下面的 `gr.cnf` 只放本篇需要的設定。

先產生一個 UUID 當群組名稱，三台要一樣：

```console
$ cat /proc/sys/kernel/random/uuid      # 或 uuidgen
8e72d555-fe66-40fb-ac72-9df87aad549b
```

```ini
# /etc/my.cnf.d/gr.cnf
[mysqld]
server_id                = 1            # db1=1、db2=2、db3=3
report_host              = db1          # 填自己的主機名
bind_address             = 0.0.0.0

# ---- GR 的前提：GTID + ROW + binlog ----
log_bin                  = mysql-bin
binlog_format            = ROW
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON
binlog_checksum          = CRC32        # 8.0.21+ 起 GR 支援 checksum，不用再設 NONE
disabled_storage_engines = "MyISAM,BLACKHOLE,FEDERATED,ARCHIVE,MEMORY"

# ---- Group Replication ----
plugin_load_add                          = group_replication.so
loose_group_replication_group_name       = "8e72d555-fe66-40fb-ac72-9df87aad549b"
loose_group_replication_start_on_boot    = OFF
loose_group_replication_local_address    = "db1:33061"     # 填自己的主機名
loose_group_replication_group_seeds      = "db1:33061,db2:33061,db3:33061"
loose_group_replication_bootstrap_group  = OFF
loose_group_replication_single_primary_mode = ON
loose_group_replication_recovery_get_public_key = ON
```

每台要改的只有 `server_id`、`report_host`、`group_replication_local_address` 三處：

```console
db3# grep -E "server_id|report_host|local_address" /etc/my.cnf.d/gr.cnf
server_id                = 3            # db1=1、db2=2、db3=3
report_host              = db3          # 填自己的主機名
loose_group_replication_local_address    = "db3:33061"     # 填自己的主機名
```

幾個重點：

- `start_on_boot = OFF`：群組建好之前先關閉，避免重啟時自己去找群組。建好後再打開。
- `disabled_storage_engines`：GR 只支援 InnoDB，直接禁止建立其他引擎的表。
- `recovery_get_public_key = ON`：新節點用 `caching_sha2_password` 帳號向其他節點同步資料時需要。

## 步驟 3：啟動、改 root 密碼（三台都做）

```bash
sudo systemctl enable --now mysqld
TMP=$(sudo grep 'temporary password' /var/log/mysqld.log | tail -1 | awk '{print $NF}')
mysql -uroot -p"$TMP" --connect-expired-password \
  -e "ALTER USER root@localhost IDENTIFIED BY 'Root#Pass2026';"
```

（`/root/.my.cnf` 的設定方式與注意事項見 GTID 篇。）

確認外掛已載入：

```console
db1# mysql -e "SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME='group_replication';"
+-------------------+---------------+
| PLUGIN_NAME       | PLUGIN_STATUS |
+-------------------+---------------+
| group_replication | ACTIVE        |
+-------------------+---------------+
```

## 步驟 4：清掉本機的 GTID（三台都做）

這一步官方文件不太強調，但**實測少做就會加入失敗**。

`ALTER USER` 改 root 密碼時會寫進 binlog，產生一筆只屬於這台的 GTID：

```console
db1# mysql -e "SELECT @@gtid_executed"
+----------------------------------------+
| @@gtid_executed                        |
+----------------------------------------+
| 89fb14f6-cf5b-11f1-9d6c-72d47a1ba679:1 |
+----------------------------------------+
```

第一台（bootstrap）沒關係，但後面加入的節點若帶著自己的 GTID，群組會拒絕它：

```console
db2# mysql -e "START GROUP_REPLICATION;"
ERROR 3092 (HY000) at line 1: The server is not configured properly to be an active member of the group. Please see more details on error log.

db2# grep ERROR /var/log/mysqld.log | tail -2
[ERROR] [MY-011526] [Repl] Plugin group_replication reported: 'This member has more executed transactions than those present in the group. Local transactions: 8d80b4ca-cf5b-11f1-9b1a-4e6a7008e790:1 > Group transactions: 89fb14f6-cf5b-11f1-9d6c-72d47a1ba679:1, 8e72d555-fe66-40fb-ac72-9df87aad549b:1'
[ERROR] [MY-011522] [Repl] Plugin group_replication reported: 'The member contains transactions not present in the group. The member will now exit the group.'
```

全新安裝、還沒有業務資料的節點，直接清掉即可：

```sql
RESET MASTER;
```

> `RESET MASTER` 會刪除所有 binlog。只能用在**全新、沒有資料**的節點上。
{: .prompt-danger }

## 步驟 5：建立分散式復原帳號（三台都做）

新節點加入時，會透過 `group_replication_recovery` 這個複製通道向現有成員拉資料。每台都要建立相同帳號，並用 `SQL_LOG_BIN=0` 避免產生 GTID：

```sql
SET SQL_LOG_BIN = 0;
CREATE USER 'rpl_user'@'%' IDENTIFIED BY 'Rpl#Pass2026';
GRANT REPLICATION SLAVE ON *.* TO 'rpl_user'@'%';
GRANT CONNECTION_ADMIN ON *.* TO 'rpl_user'@'%';
GRANT BACKUP_ADMIN ON *.* TO 'rpl_user'@'%';
GRANT GROUP_REPLICATION_STREAM ON *.* TO 'rpl_user'@'%';
SET SQL_LOG_BIN = 1;

CHANGE REPLICATION SOURCE TO
  SOURCE_USER = 'rpl_user',
  SOURCE_PASSWORD = 'Rpl#Pass2026'
  FOR CHANNEL 'group_replication_recovery';
```

## 步驟 6：在 db1 啟動群組（bootstrap）

只有**第一台、第一次**需要 bootstrap，完成後立刻關掉，否則下次重啟可能自己另開一個群組（腦裂）：

```sql
SET GLOBAL group_replication_bootstrap_group = ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group = OFF;

SELECT * FROM performance_schema.replication_group_members;
```

```console
+---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+
| CHANNEL_NAME              | MEMBER_ID                            | MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE | MEMBER_VERSION | MEMBER_COMMUNICATION_STACK |
+---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+
| group_replication_applier | 89fb14f6-cf5b-11f1-9d6c-72d47a1ba679 | db1         |        3306 | ONLINE       | PRIMARY     | 8.0.46         | XCom                       |
+---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+
```

## 步驟 7：db2、db3 加入群組

```sql
START GROUP_REPLICATION;
```

```console
db1# mysql -e "SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE, MEMBER_VERSION FROM performance_schema.replication_group_members;"
+-------------+-------------+--------------+-------------+----------------+
| MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE | MEMBER_VERSION |
+-------------+-------------+--------------+-------------+----------------+
| db1         |        3306 | ONLINE       | PRIMARY     | 8.0.46         |
| db2         |        3306 | ONLINE       | SECONDARY   | 8.0.46         |
| db3         |        3306 | ONLINE       | SECONDARY   | 8.0.46         |
+-------------+-------------+--------------+-------------+----------------+
```

三台都 `ONLINE`，群組建立完成。最後讓節點重啟後自動加回群組（三台都做）：

```sql
SET PERSIST group_replication_start_on_boot = ON;
```

## 步驟 8：驗證

在 Primary 寫入：

```sql
-- db1
CREATE DATABASE shop;
CREATE TABLE shop.orders (id INT AUTO_INCREMENT PRIMARY KEY, item VARCHAR(50), amount DECIMAL(10,2));
INSERT INTO shop.orders (item, amount) VALUES ('keyboard', 1290), ('mouse', 590);
```

Secondary 自動是唯讀，資料已同步：

```console
db3# mysql -e "SELECT @@hostname, @@read_only, @@super_read_only; SELECT * FROM shop.orders;"
+------------+-------------+-------------------+
| @@hostname | @@read_only | @@super_read_only |
+------------+-------------+-------------------+
| db3        |           1 |                 1 |
+------------+-------------+-------------------+
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
+----+----------+---------+

db3# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('x', 1);"
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

沒有主鍵的表無法寫入：

```console
db1# mysql -e "CREATE TABLE shop.nopk (a INT, b INT); INSERT INTO shop.nopk VALUES (1,1);"
ERROR 3098 (HY000) at line 1: The table does not comply with the requirements by an external plugin.
```

`CREATE TABLE` 本身會成功，錯在 `INSERT`。這個錯誤訊息很不直覺，看到時第一個就要檢查主鍵。

8.0 的幾個預設值也確認一下（8.4 有改，見 [HA/DR 篇的版本比較]({% post_url 2026-10-24-mysql-ops-03-ha-dr %})）：

```console
db1# mysql -e "SELECT @@group_replication_consistency, @@group_replication_exit_state_action;"
+---------------------------------+---------------------------------------+
| @@group_replication_consistency | @@group_replication_exit_state_action |
+---------------------------------+---------------------------------------+
| EVENTUAL                        | READ_ONLY                             |
+---------------------------------+---------------------------------------+
```

## 步驟 9：故障演練：主庫宕機

直接停掉 Primary：

```bash
db1# systemctl stop mysqld
```

幾秒後在 `db2` 查詢，群組已自動選出新主庫：

```console
db2# mysql -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
+-------------+--------------+-------------+
| MEMBER_HOST | MEMBER_STATE | MEMBER_ROLE |
+-------------+--------------+-------------+
| db2         | ONLINE       | PRIMARY     |
| db3         | ONLINE       | SECONDARY   |
+-------------+--------------+-------------+
```

新主庫自動關閉唯讀，可以寫入：

```console
db2# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('monitor', 6990); SELECT @@hostname, @@super_read_only;"
+------------+-------------------+
| @@hostname | @@super_read_only |
+------------+-------------------+
| db2        |                 0 |
+------------+-------------------+
```

錯誤日誌可以看到選主過程：

```console
db2# grep -i primary /var/log/mysqld.log | tail -3
[System] [MY-013731] [Repl] Plugin group_replication reported: 'The member action "mysql_disable_super_read_only_if_primary" for event "AFTER_PRIMARY_ELECTION" with priority "1" will be run.'
[System] [MY-013731] [Repl] Plugin group_replication reported: 'The member action "mysql_start_failover_channels_if_primary" for event "AFTER_PRIMARY_ELECTION" with priority "10" will be run.'
[System] [MY-011510] [Repl] Plugin group_replication reported: 'This server is working as primary member.'
```

## 步驟 10：故障節點恢復

因為設了 `group_replication_start_on_boot = ON`，`db1` 啟動後會自動加回群組，並補齊離線期間的交易：

```console
db1# systemctl start mysqld
db1# mysql -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members; SELECT * FROM shop.orders;"
+-------------+--------------+-------------+
| MEMBER_HOST | MEMBER_STATE | MEMBER_ROLE |
+-------------+--------------+-------------+
| db1         | ONLINE       | SECONDARY   |
| db2         | ONLINE       | PRIMARY     |
| db3         | ONLINE       | SECONDARY   |
+-------------+--------------+-------------+
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
+----+----------+---------+
```

`db1` 回來後是 Secondary，不會搶回主庫。

## 步驟 11：手動切換主庫

想把主庫換回 `db1`，用 `group_replication_set_as_primary()` 指定成員 UUID：

```console
db2# mysql -e "SELECT group_replication_set_as_primary('89fb14f6-cf5b-11f1-9d6c-72d47a1ba679') AS result;"
+------------------------------------------------------------------+
| result                                                           |
+------------------------------------------------------------------+
| Primary server switched to: 89fb14f6-cf5b-11f1-9d6c-72d47a1ba679 |
+------------------------------------------------------------------+

db2# mysql -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
+-------------+--------------+-------------+
| MEMBER_HOST | MEMBER_STATE | MEMBER_ROLE |
+-------------+--------------+-------------+
| db1         | ONLINE       | PRIMARY     |
| db2         | ONLINE       | SECONDARY   |
| db3         | ONLINE       | SECONDARY   |
+-------------+--------------+-------------+
```

## 全部節點都停機時

`start_on_boot = ON` 只能讓節點「加入現有群組」。三台都停機後重新開機，沒有任何節點有群組可加，要手動找出 GTID 最完整的那台重新 bootstrap，其餘再 `START GROUP_REPLICATION`。這一段用 InnoDB Cluster 的 `dba.rebootClusterFromCompleteOutage()` 會簡單很多，下一篇有實測。

## 應用程式要怎麼連

MGR 本身**不提供**連線導向，主庫換了之後應用程式不會知道。常見做法：

- **MySQL Router**：搭配 InnoDB Cluster，下一篇介紹。
- **ProxySQL**：設定 `mysql_group_replication_hostgroups`，依成員狀態自動調整讀寫群組。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| `gr.cnf` 的設定沒生效、`gtid_mode=OFF` | dnf 版 `/etc/my.cnf` 沒有 `!includedir` | 第一次啟動前補上 |
| `This member has more executed transactions than those present in the group` | 改 root 密碼產生了本機 GTID | 全新節點加入前 `RESET MASTER` |
| `ERROR 3098 ... does not comply with the requirements by an external plugin` | 表沒有主鍵 | 每張表都要有主鍵 |

## 驗證方式與結果

驗證環境與 [GTID 篇的「驗證方式與結果」]({% post_url 2026-10-24-mysql-ha-lab-01-gtid-replication %}) 相同（環境 A：Rocky 9 容器 + dnf 安裝，Mac M4；環境 B：Percona 官方映像，Linux x86_64），每次從全新的三台主機開始。

| 步驟 | 怎麼驗證 | 判定通過的條件 | 環境 A | 環境 B |
| :--- | :--- | :--- | :--- | :--- |
| 3 | `information_schema.PLUGINS` | `group_replication` 為 `ACTIVE` | ✅ | ✅ |
| 4 | `SELECT @@gtid_executed` | `RESET MASTER` 前各有一筆本機 GTID，之後清空 | ✅ | ✅ |
| 6~7 | `performance_schema.replication_group_members` | 三台 `ONLINE`，一台 `PRIMARY` | ✅ | ✅ |
| 8 | Secondary 查資料、寫入；建立無主鍵表後寫入 | 資料一致；寫入回 `ERROR 1290`；無主鍵寫入回 `ERROR 3098` | ✅ | ✅ |
| 9 | `systemctl stop mysqld` 停掉 Primary，查成員表與錯誤日誌 | 剩下兩台自動選出新 Primary 且可寫入 | ✅ 停機 6.6 秒後 db2 成為 Primary | ✅ db2 成為 Primary |
| 10 | `systemctl start mysqld` | 舊 Primary 以 `SECONDARY` 自動加回，資料齊全 | ✅ | ✅ |
| 11 | `group_replication_set_as_primary()` | 指定節點成為 `PRIMARY` | ✅ | ✅ |

**錯誤處理紀錄**：

- 缺 `!includedir`：環境 A 遇到，補上後通過（環境 B 的官方映像已有這行）。
- 少做 `RESET MASTER` 造成 `ERROR 3092`：環境 B 遇到，錯誤日誌原文見步驟 4，清掉後重新 `START GROUP_REPLICATION` 即可加入。
- 無主鍵表的 `ERROR 3098`：兩個環境都重現。
- `firewalld`、SELinux（`semanage port`）在容器內無法測試，未驗證。

## 小結

- MGR 的設定核心是：GTID + 相同 `group_name` + 各自的 `local_address` + 共同的 `group_seeds`。
- bootstrap 只做一次，做完立刻關掉。
- 實測主庫 `systemctl stop` 後幾秒內自動選出新主庫，舊主庫回來會以 Secondary 身分自動加入。
- 手動維護 MGR 的步驟不少，正式環境建議用 InnoDB Cluster 管理。

下一篇：[InnoDB Cluster]({% post_url 2026-10-24-mysql-ha-lab-05-innodb-cluster %})，用 MySQL Shell 與 MySQL Router 把這些步驟自動化。

### 參考資料

- [MySQL 8.0 Reference Manual：Deploying Group Replication in Single-Primary Mode](https://dev.mysql.com/doc/refman/8.0/en/group-replication-deploying-in-single-primary-mode.html)
- [MySQL 8.0 Reference Manual：Group Replication Requirements](https://dev.mysql.com/doc/refman/8.0/en/group-replication-requirements.html)
- [Percona Server for MySQL 8.0：Group Replication](https://docs.percona.com/percona-server/8.0/group-replication.html)
