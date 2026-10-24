---
title: MySQL 高可用實作 01：GTID 主從複製（Percona Server 8.0 / Rocky Linux 9）
date: 2026-10-24 10:10:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql8, percona, rocky-linux, replication, gtid, dba]
description: 以 Percona Server for MySQL 8.0.46 在 Rocky Linux 9 上從安裝到驗證，一步步建立 GTID 主從複製，包含用 mysqldump 建立從庫、設定唯讀與計畫內切換，所有輸出皆為實測結果。
---

[高可用與災難復原]({% post_url 2026-10-24-mysql-ops-03-ha-dr %}) 一篇整理了各種 HA 架構的觀念，這個系列則是動手做：每一篇都從安裝開始，一路做到驗證成功。第一篇是所有架構的基礎，**GTID 主從複製**。

{% include mysql-ha-lab-series.md %}

{% include mysql-ha-lab-env.md %}

## 架構

| 主機 | IP | 角色 |
| :--- | :--- | :--- |
| `db1` | 192.168.56.11 | Source（主庫） |
| `db2` | 192.168.56.12 | Replica（從庫） |

兩台都是 Rocky Linux 9，安裝 Percona Server for MySQL 8.0.46-37.1。

## 步驟 0：主機準備（兩台都做）

讓每台主機都能用主機名互相解析。複製的設定與 `SHOW REPLICAS` 輸出都會用到主機名。

```bash
cat >> /etc/hosts <<'EOF'
192.168.56.11 db1
192.168.56.12 db2
EOF
```

開防火牆（**未實測**，容器內沒有 firewalld）：

```bash
sudo firewall-cmd --permanent --add-service=mysql     # 3306/tcp
sudo firewall-cmd --reload
```

SELinux 維持 `Enforcing` 即可，Percona 的 RPM 使用預設的 `/var/lib/mysql` 與 3306 埠，不需要額外設定。

## 步驟 1：安裝 Percona Server（兩台都做）

> 這一步**未實測**：測試環境連不到 `repo.percona.com`。指令依 Percona 官方文件撰寫，實測環境直接使用 Percona 官方映像裡已安裝好的同版本 el9 RPM。
{: .prompt-warning }

```bash
# 安裝 percona-release 工具並啟用 ps80 套件庫
sudo dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release setup ps80

# 安裝最新版，或指定版本
sudo dnf install -y percona-server-server
# sudo dnf install -y percona-server-server-8.0.46-37.1.el9
```

裝好後確認套件與版本（以下為實測輸出）：

```console
# rpm -qa | grep -E "^percona-server" | sort
percona-server-client-8.0.46-37.1.el9.x86_64
percona-server-devel-8.0.46-37.1.el9.x86_64
percona-server-rocksdb-8.0.46-37.1.el9.x86_64
percona-server-server-8.0.46-37.1.el9.x86_64
percona-server-shared-8.0.46-37.1.el9.x86_64

# mysqld --version
/usr/sbin/mysqld  Ver 8.0.46-37 for Linux on x86_64 (Percona Server (GPL), Release 37, Revision 39e2b60e)
```

> 用 `dnf` 安裝時只會帶入 `server`、`client`、`shared` 等相依套件；`devel`、`rocksdb` 是官方映像額外裝的，實際主機上沒有也沒關係。
{: .prompt-info }

## 步驟 2：設定檔（兩台都做）

Percona 的 `/etc/my.cnf` 最後一行是 `!includedir /etc/my.cnf.d`，所以把複製相關設定獨立放一個檔案，日後比較好維護：

```ini
# /etc/my.cnf.d/gtid.cnf
[mysqld]
server_id                = 1          # 每台不同：db1=1、db2=2
report_host              = db1        # 每台填自己的主機名
bind_address             = 0.0.0.0

# Binlog 與 GTID
log_bin                  = mysql-bin
binlog_format            = ROW
gtid_mode                = ON
enforce_gtid_consistency = ON
log_replica_updates      = ON
binlog_expire_logs_seconds = 604800   # 保留 7 天

# 複製安全性
relay_log                = relay-bin
relay_log_recovery       = ON
sync_binlog              = 1
innodb_flush_log_at_trx_commit = 1
```

`db2` 把 `server_id` 改成 `2`、`report_host` 改成 `db2`。

> 從庫的 `read_only` / `super_read_only` **先不要寫進設定檔**。第一次啟動時 root 密碼是過期的，必須先 `ALTER USER`，而 `super_read_only=ON` 會把這個動作擋掉：
>
> `ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement`
>
> 這是實測踩到的。唯讀在步驟 7 用 `SET PERSIST` 開啟即可。
{: .prompt-danger }

## 步驟 3：啟動並設定 root 密碼（兩台都做）

```bash
sudo systemctl enable --now mysqld
sudo grep 'temporary password' /var/log/mysqld.log
```

```console
Created symlink /etc/systemd/system/mysql.service → /usr/lib/systemd/system/mysqld.service.
Created symlink /etc/systemd/system/multi-user.target.wants/mysqld.service → /usr/lib/systemd/system/mysqld.service.
● mysqld.service - MySQL Server
     Loaded: loaded (/usr/lib/systemd/system/mysqld.service; enabled; preset: enabled)
     Active: active (running) since Sat 2026-10-24 03:43:21 UTC; 15ms ago
2026-10-24T03:43:18.343242Z 6 [Note] [MY-010454] [Server] A temporary password is generated for root@localhost: K6cruSwt(u5g
```

第一次啟動時，systemd 的 `ExecStartPre=/usr/bin/mysqld_pre_systemd` 會初始化資料目錄並產生臨時密碼。用臨時密碼登入後立刻改掉：

```bash
mysql -uroot -p --connect-expired-password \
  -e "ALTER USER root@localhost IDENTIFIED BY 'Root#Pass2026';"
```

為了後面操作方便，把密碼放進 `/root/.my.cnf`：

```bash
cat > /root/.my.cnf <<'EOF'
[client]
user=root
password="Root#Pass2026"
EOF
chmod 600 /root/.my.cnf
```

> 選項檔裡 `#` 是註解符號。密碼含 `#` 時**一定要加引號**，否則會被截成 `Root`，結果是 `ERROR 1045 (28000): Access denied`。這也是實測踩到的。
{: .prompt-warning }

確認設定生效：

```console
# mysql -e "select @@hostname,@@server_id,@@server_uuid,@@version,@@version_comment,@@gtid_mode,@@enforce_gtid_consistency,@@log_bin,@@binlog_format\G"
*************************** 1. row ***************************
                @@hostname: db1
               @@server_id: 1
             @@server_uuid: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e
                 @@version: 8.0.46-37
         @@version_comment: Percona Server (GPL), Release 37, Revision 39e2b60e
               @@gtid_mode: ON
@@enforce_gtid_consistency: ON
                 @@log_bin: 1
           @@binlog_format: ROW
```

## 步驟 4：主庫建立複製帳號（db1）

```sql
CREATE USER 'repl'@'192.168.56.%' IDENTIFIED BY 'Repl#Pass2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.56.%';

-- 示範用的業務資料
CREATE DATABASE shop;
CREATE TABLE shop.orders (
  id INT AUTO_INCREMENT PRIMARY KEY,
  item VARCHAR(50),
  amount DECIMAL(10,2),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO shop.orders (item, amount) VALUES ('keyboard', 1290), ('mouse', 590), ('monitor', 6990);

SHOW MASTER STATUS;
```

```console
+------------------+----------+--------------+------------------+------------------------------------------+
| File             | Position | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set                        |
+------------------+----------+--------------+------------------+------------------------------------------+
| mysql-bin.000002 |     1884 |              |                  | 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 |
+------------------+----------+--------------+------------------+------------------------------------------+
```

## 步驟 5：用 mysqldump 建立從庫資料

主庫上已經有資料時，要先把資料搬到從庫。資料量小用 `mysqldump`，大的建議用 XtraBackup（見 [備份與還原]({% post_url 2026-10-24-mysql-ops-02-backup-restore %})）。

在 `db1` 匯出：

```bash
mysqldump --all-databases --single-transaction --triggers --routines --events \
  --source-data=2 --set-gtid-purged=ON --flush-privileges > /root/full.sql
```

```console
# grep -n -E "^SET @@GLOBAL.GTID_PURGED|^-- CHANGE MASTER|FLUSH PRIV" /root/full.sql
36:SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6';
42:-- CHANGE MASTER TO MASTER_LOG_FILE='mysql-bin.000002', MASTER_LOG_POS=1884;
1098:/*! FLUSH PRIVILEGES */;
```

- `--set-gtid-purged=ON`：檔案裡會寫入 `GTID_PURGED`，從庫匯入後就知道「這些交易已經有了」，接上複製時只會拉後面的交易。
- `--flush-privileges`：**一定要加**。`--all-databases` 會把 `mysql.user` 一起匯入，但匯入的是資料表內容，記憶體裡的權限不會更新。實測沒加這個參數時，從庫上的 `repl` 帳號看得到但不能登入，等到做切換時才會出錯：`Host 'db1' is not allowed to connect to this MySQL server`。
- 8.0.46 的 `mysqldump` 註解裡仍是舊語法 `CHANGE MASTER TO`，用 GTID 自動定位時用不到這行，看看就好。

把檔案複製到 `db2`，**先 `RESET MASTER` 再匯入**：

```console
# mysql -e "SELECT @@gtid_executed"
+----------------------------------------+
| @@gtid_executed                        |
+----------------------------------------+
| 0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589:1 |
+----------------------------------------+

# mysql -e "RESET MASTER"
# mysql < /root/full.sql
# mysql -e "SELECT @@gtid_executed, @@gtid_purged"
+------------------------------------------+------------------------------------------+
| @@gtid_executed                          | @@gtid_purged                            |
+------------------------------------------+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 | 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6 |
+------------------------------------------+------------------------------------------+
```

注意 `db2` 匯入前已經有一筆自己的 GTID（`0f1ea8d1...:1`），那是步驟 3 的 `ALTER USER` 產生的。8.0 的 dump 檔用 `'+'` 語法附加 `GTID_PURGED`，**不清掉也不會報錯**，但這筆只存在從庫的交易會變成 errant transaction，日後切換主庫時可能出問題。所以匯入前一律 `RESET MASTER`。

> 匯入 `mysql` 系統庫後，`db2` 的 root 密碼會變成和 `db1` 一樣。
{: .prompt-info }

## 步驟 6：設定複製（db2）

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'db1',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = 'Repl#Pass2026',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_SSL = 1;

START REPLICA;
```

> 少了 `SOURCE_SSL = 1` 會連不上。8.0 預設認證外掛是 `caching_sha2_password`，實測錯誤如下：
>
> `Last_IO_Error: Error connecting to source 'repl@db1:3306'. ... Message: Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.`
>
> 8.0 安裝時會自動產生自簽憑證，所以直接開 `SOURCE_SSL = 1` 就能用。若不想走 SSL，改用 `GET_SOURCE_PUBLIC_KEY = 1`。
{: .prompt-danger }

```console
# mysql -e "SHOW REPLICA STATUS\G"
                  Source_Host: db1
                  Source_User: repl
                  Source_Port: 3306
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
           Source_SSL_Allowed: Yes
        Seconds_Behind_Source: 0
                Last_IO_Error:
               Last_SQL_Error:
    Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
           Retrieved_Gtid_Set:
            Executed_Gtid_Set: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-6
                Auto_Position: 1
```

`Replica_IO_Running` 與 `Replica_SQL_Running` 都是 `Yes`，複製就建立好了。

## 步驟 7：從庫設為唯讀（db2）

```sql
SET PERSIST read_only = ON;
SET PERSIST super_read_only = ON;
```

`SET PERSIST` 會寫進 `/var/lib/mysql/mysqld-auto.cnf`，重啟後依然有效。

## 步驟 8：驗證

在 `db1` 寫入一筆：

```console
# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('headset', 2490); SELECT @@gtid_executed; SHOW REPLICAS;"
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         2 | db2  | 3306 |         1 | 0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589 |
+-----------+------+------+-----------+--------------------------------------+
```

在 `db2` 查詢，資料與 GTID 集合都一致：

```console
# mysql -e "SELECT id,item,amount FROM shop.orders; SELECT @@gtid_executed;"
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
|  4 | headset  | 2490.00 |
+----+----------+---------+
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
```

從庫寫入會被擋下：

```console
# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('should-fail', 1);"
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only option so it cannot execute this statement
```

## 步驟 9：計畫內切換（Switchover）

GTID 最大的好處是切換時不用找 binlog 檔名與位置。以下把主庫從 `db1` 換到 `db2`。

**1. 舊主庫停止寫入（db1）**

```console
# mysql -e "SET PERSIST read_only=ON; SET PERSIST super_read_only=ON; SELECT @@gtid_executed;"
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7 |
+------------------------------------------+
```

**2. 等新主庫追上（db2）**：回傳 `0` 代表在逾時（10 秒）內已套用完上面的 GTID 集合。

```console
# mysql -e "SELECT WAIT_FOR_EXECUTED_GTID_SET('0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7', 10) AS caught_up;"
+-----------+
| caught_up |
+-----------+
|         0 |
+-----------+
```

**3. 提升新主庫（db2）**

```console
# mysql -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SELECT @@read_only, @@super_read_only;"
+-------------+-------------------+
| @@read_only | @@super_read_only |
+-------------+-------------------+
|           0 |                 0 |
+-------------+-------------------+
```

**4. 舊主庫改成從庫（db1）**

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'db2', SOURCE_PORT = 3306,
  SOURCE_USER = 'repl', SOURCE_PASSWORD = 'Repl#Pass2026',
  SOURCE_AUTO_POSITION = 1, SOURCE_SSL = 1;
START REPLICA;
```

```console
                  Source_Host: db2
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
                Last_IO_Error:
            Executed_Gtid_Set: 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7
                Auto_Position: 1
```

**5. 驗證**：在新主庫 `db2` 寫入，`db1` 收得到，GTID 集合多了 `db2` 的 UUID。

```console
db2# mysql -e "INSERT INTO shop.orders (item, amount) VALUES ('webcam', 1890);"
db1# mysql -e "SELECT id,item,amount FROM shop.orders; SELECT @@gtid_executed;"
+----+----------+---------+
| id | item     | amount  |
+----+----------+---------+
|  1 | keyboard | 1290.00 |
|  2 | mouse    |  590.00 |
|  3 | monitor  | 6990.00 |
|  4 | headset  | 2490.00 |
|  5 | webcam   | 1890.00 |
+----+----------+---------+
+------------------------------------------+
| @@gtid_executed                          |
+------------------------------------------+
| 0c51f2a4-cf5d-11f1-8d86-66fd07bf7c7e:1-7,
0f1ea8d1-cf5d-11f1-b64c-da5b19eaf589:1 |
+------------------------------------------+
```

切換完成後，記得把應用程式的連線（DNS、VIP 或 ProxySQL）指向新主庫。

## 實測踩到的坑

| 現象 | 原因 | 解法 |
| :--- | :--- | :--- |
| 改 root 密碼出現 `ERROR 1290 ... --super-read-only` | 設定檔先開了 `super_read_only` | 唯讀等密碼改完再用 `SET PERSIST` 開 |
| `.my.cnf` 設好密碼仍 `Access denied` | 密碼含 `#` 被當成註解 | `password="..."` 加引號 |
| `Authentication requires secure connection` | `caching_sha2_password` 需要 SSL 或公鑰 | `SOURCE_SSL = 1` 或 `GET_SOURCE_PUBLIC_KEY = 1` |
| 切換時 `Host 'db1' is not allowed to connect` | 匯入 `mysql.user` 後沒有 flush | `mysqldump` 加 `--flush-privileges` |
| 從庫多一筆自己的 GTID | 初始化時 `ALTER USER` 寫了 binlog | 匯入前 `RESET MASTER` |

## 小結

- 8.0 建複製一律用 GTID + `SOURCE_AUTO_POSITION = 1`，切換只要比對 GTID 集合。
- 建從庫前先 `RESET MASTER`，dump 時加 `--set-gtid-purged=ON --flush-privileges`。
- 從庫用 `SET PERSIST super_read_only = ON` 防止誤寫。

下一篇：[半同步複製]({% post_url 2026-10-24-mysql-ha-lab-02-semi-sync %})，在這個 GTID 架構上把 RPO 降到接近 0。

### 參考資料

- [Percona Server for MySQL 8.0：Install from Percona Software repository (YUM)](https://docs.percona.com/percona-server/8.0/yum-repo.html)
- [MySQL 8.0 Reference Manual：Setting Up Replication Using GTIDs](https://dev.mysql.com/doc/refman/8.0/en/replication-gtids-howto.html)
- [MySQL 8.0 Reference Manual：CHANGE REPLICATION SOURCE TO Statement](https://dev.mysql.com/doc/refman/8.0/en/change-replication-source-to.html)
