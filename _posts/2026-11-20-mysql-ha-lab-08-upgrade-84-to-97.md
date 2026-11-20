---
title: MySQL 高可用實作 08：8.4 LTS 升級 9.7 LTS，以及 26.7 開始的日曆版號（Rocky Linux 9）
date: 2026-11-20 20:30:00 +0800
categories: [MySQL, 高可用實作]
tags: [mysql, mysql84, mysql97, percona, rocky-linux, replication, upgrade, switchover, lts, versioning, dba]
description: 先整理 MySQL 的版本模型：LTS 8.0 → 8.4 → 9.7，9.7 之後改成 YY.M 日曆版號（26.7、26.10，下一個 LTS 預計 28.4）。接著在 Percona Server 8.4.11 一主二從上滾動升級到 9.7.2，實測 percona-release 不認得 ps-97-lts、Upgrade Checker 沒抓到 mysql_native_password 帳號、9.x 用戶端不處理 \G 等坑。寫入中斷 0.93 秒、無資料遺失。
media_subpath: /assets/img/posts/mysql-ha-lab-08
---

[上一篇]({% post_url 2026-11-20-mysql-ha-lab-07-upgrade-80-to-84 %})把 8.0 升到 8.4 LTS。這篇再往前一步升到 **9.7 LTS**，並先把 MySQL 這幾年改過兩次的版本模型講清楚，因為它決定了「下一次要升到哪一版、可以跳幾版」。

{% include mysql-ha-lab-series.md %}

> **關於版本與實測範圍**
>
> - 起點 **Percona Server 8.4.11-12.1**（`ps-84-lts`），目標 **9.7.2-3.1**（`ps-97-lts`），MySQL Shell **9.7.1**。
> - 指令輸出都是實際執行的結果：Rocky Linux 9.9 容器 + systemd、`dnf` 從 `repo.percona.com` 安裝與升級（x86_64，4 vCPU / 15 GB）。文中的圖是實測輸出的終端機截圖。
> - 驗證腳本與完整輸出：[`tools/mysql-ha-lab`](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/mysql-ha-lab) 的 `08-*.sh`、`results/08-*.log`。
> - 版本時程整理自 2026-11 時的 Oracle / Percona 公開資料，見文末參考資料；未來的版號（27.x、28.4）是官方的**預期**，不是承諾。
{: .prompt-warning }

## MySQL 的版本模型

### 三個時期

| 時期 | 版本 | 規則 |
| :--- | :--- | :--- |
| 8.0 時期（2018~2023） | 8.0.11 ~ 8.0.34 | 只有一條線，**小版本也會加新功能、改行為**，升級風險大 |
| LTS + Innovation（2023-07 起） | LTS：**8.4**、**9.7**<br>Innovation：8.1~8.3、9.0~9.6 | LTS 小版本只修 bug；Innovation 每季一版，只支援到下一版出來 |
| 日曆版號（2026-07 起） | Innovation：**26.7**、**26.10**、27.1…<br>下一個 LTS：**28.4**（預計 2028-04） | 版號改成 `YY.M.P`：年份後兩碼 + 發佈月份 + 修補版號 |

日曆版號的讀法：`26.7.0` = 2026 年 7 月發佈的 Innovation 版；LTS 會沿用它的 `YY.M` 前綴，例如 `28.4.0 → 28.4.1 → 28.4.2`。所以 **9.7 是最後一個用舊式版號的 LTS**，9.7 之後的下一版不是 9.8，而是 26.7。

### LTS 的支援時程

| LTS | GA | Premier Support | Extended Support |
| :--- | :--- | :--- | :--- |
| 8.0 | 2018-04 | 2025-04 已結束 | **2026-04 已結束** |
| 8.4 | 2024-04 | 2029-04 | 2032-04 |
| 9.7 | 2026-04-21 | 2031-04 | 2034-04 |
| 28.4（預計） | 2028-04 | — | — |

### 升級路徑

- **LTS → 下一個 LTS 可以直接就地升級**：8.0 → 8.4（Lab 07）、8.4 → 9.7（本篇）。
- **不能跳過 LTS**：8.0 不能直接到 9.7，要經過 8.4。
- **要進日曆版號的 Innovation 線（26.7、26.10…）只能從 9.7 升上去**，8.4 不行。
- 同一個 LTS 系列內（例如 9.7.1 ↔ 9.7.2）可以就地升級也可以就地降級；跨系列一律只能升、不能降，要退回就靠升級前的備份。
- 複製：舊版主庫 → 新版從庫可以（LTS → 下一個 LTS 也支援），反方向不支援。

> **生產環境建議只跟 LTS**。Innovation 版只支援到下一個 Innovation 出來（約 3 個月），等於每季都要升級一次。Percona 也是這樣做的：`repo.percona.com` 上有 `ps-8x-innovation`（8.1~8.3），**但沒有 9.x Innovation 的套件庫**，8.4 之後直接提供 9.7 LTS。
{: .prompt-tip }

實際查 Percona 的三個套件庫：

![ps-84-lts 最新 8.4.11-12.1、ps-97-lts 最新 9.7.2-3.1、ps-8x-innovation 停在 8.3.0](01-repo-versions.png)

## 架構

和 Lab 07 相同：db1 主庫、db2 / db3 從庫（GTID + 半同步 + `replica_parallel_workers = 8`），app 每 0.2 秒寫一筆。起點是 **Lab 07 升級完成後的狀態**，只多了一個漏網之魚：一個報表系統用的舊帳號還是 `mysql_native_password`，所以 8.4 上還開著 `mysql_native_password = ON`。

```console
[db1] mysql> SELECT user, host, plugin FROM mysql.user WHERE user NOT LIKE 'mysql.%' ORDER BY user;
+-------------------+--------------+-----------------------+
| user              | host         | plugin                |
+-------------------+--------------+-----------------------+
| app               | 192.168.58.% | caching_sha2_password |
| legacy_report     | 192.168.58.% | mysql_native_password |
| percona.telemetry | localhost    | caching_sha2_password |
| repl              | 192.168.58.% | caching_sha2_password |
| root              | localhost    | caching_sha2_password |
+-------------------+--------------+-----------------------+
```

升級順序也和 Lab 07 相同：**db2 → db3 → 切換到 db2 → db1 升級後接回**。下面只寫和 8.0 → 8.4 不同的地方。

## 步驟 1：切換套件庫（坑：`percona-release setup` 不認得 ps-97-lts）

照 Lab 07 的習慣執行 `percona-release setup -y ps-97-lts`，看起來成功了，**實際上把所有 Percona 套件庫都停用、卻什麼都沒有啟用**：

![percona-release 1.0-34 setup ps-97-lts 後只剩 prel、telemetry，dnf 找不到 9.7](02-percona-release-trap.png)

這時接著 `dnf upgrade` 會顯示 `Complete!` 但什麼都沒升級（實測第一次就是這樣，啟動後還是 8.4.11）。`percona-release` 1.0-34 是目前最新版，`setup` 的捷徑名稱表裡有 `ps-84-lts` 但沒有 `ps-97-lts`。改用 `enable` 直接啟用套件庫：

```bash
sudo percona-release disable ps-84-lts release
sudo percona-release enable ps-97-lts release
```

![enable 之後出現 percona-ps-97-lts-release.repo，可以看到 9.7.1 ~ 9.7.2-3.1](03-percona-release-enable.png)

> 自動化腳本（Ansible 等）如果用 `percona-release setup` 切換版本，**一定要在後面檢查 `dnf list` 真的出現目標版本**，否則「升級完成」的訊息是假的。
{: .prompt-danger }

## 步驟 2：升級檢查（MySQL Shell 9.7.1）

先升級 MySQL Shell，再跑 Upgrade Checker（Shell 一定要比目標版本新或相同；拿 8.4.10 的 Shell 檢查 8.4.11 的伺服器會直接拒絕：`MySQL Shell cannot check MySQL server instances for upgrade if they are at a version the same as or higher than the MySQL Shell version`）：

```bash
sudo dnf upgrade -y percona-mysql-shell      # 9.7.1
mysqlsh --no-wizard -uroot -p --socket=/var/lib/mysql/mysql.sock \
  -- util check-for-server-upgrade --target-version=9.7 --config-path=/etc/my.cnf
```

結果 **Errors: 0、Warnings: 23**：

![Errors 0、Warnings 23；log_slave_updates 的建議寫成 consider using 'log_slave_updates'](04-checker-summary.png)

看起來可以放心升級，但這份報告有兩個問題：

1. **完全沒有檢查帳號的認證外掛**。8.4 的 Checker（Lab 07）有 `authMethodUsage`，會列出 `mysql_native_password` 帳號；9.7.1 對 8.4 → 9.7 只跑了 `sysVars` 和 `checkTableCommand` 兩項，`legacy_report` 沒有被列出來，設定檔裡的 `mysql_native_password = ON` 也沒有被當成錯誤。
2. 棄用變數的建議有誤：設定檔寫的是 `log_replica_updates`、`replica_parallel_workers`，Checker 卻說「正在使用 `log_slave_updates`」，還建議「改用 `log_slave_updates`」。這是 Checker 從別名讀到的值，可以忽略。

> 所以 9.7 升級前要**自己查**認證外掛：
>
> ```sql
> SELECT user, host, plugin FROM mysql.user WHERE plugin = 'mysql_native_password';
> ```
>
> 有任何一筆都要先在 8.4 上換成 `caching_sha2_password`。**MySQL 9.0 起 `mysql_native_password` 外掛整個移除**，沒有任何設定可以再打開。
{: .prompt-danger }

Checker 列出的新預設值，升級後實測對照見步驟 5。

## 步驟 3：停複製、備份、升級套件（db2）

和 Lab 07 相同。`innodb_fast_shutdown = 0` 關機、備份資料目錄後：

```console
[db2]# dnf upgrade -y 'percona-server-*' percona-mysql-router percona-icu-data-files percona-mysql-shell
...
[db2]# rpm -qa | grep -iE 'percona-(server|mysql|icu|xtrabackup)' | sort
percona-icu-data-files-9.7.2-3.1.el9.x86_64
percona-mysql-router-9.7.2-3.1.el9.x86_64
percona-mysql-shell-9.7.1-2.el9.x86_64
percona-server-client-9.7.2-3.1.el9.x86_64
percona-server-server-9.7.2-3.1.el9.x86_64
percona-server-shared-9.7.2-3.1.el9.x86_64
percona-xtrabackup-84-8.4.0-7.1.el9.x86_64
```

> 注意最後一行：**`percona-xtrabackup-84` 不會跟著升級**，它只支援 8.4。9.7 要另外裝 `pxb-97-lts` 套件庫的 `percona-xtrabackup-97`，否則升級後的第一次備份就會失敗。
{: .prompt-warning }

## 步驟 4：設定檔與啟動

8.4 的設定檔直接給 9.7，`mysql_native_password = ON` 變成不認得的參數：

![validate-config：unknown variable 'mysql_native_password=ON'](05-validate-native.png)

拿掉這一行（其餘設定不用改）後 `exit=0`，啟動：

![資料字典 80300 → 90200、Server upgrade from 80411 to 90702 completed](06-first-start.png)

半同步外掛照常載入，複製自動恢復：

```console
[db2] mysql> SELECT PLUGIN_NAME, PLUGIN_STATUS FROM information_schema.PLUGINS WHERE PLUGIN_NAME LIKE '%native%' OR PLUGIN_NAME LIKE 'rpl_semi%';
+-----------------------+---------------+
| PLUGIN_NAME           | PLUGIN_STATUS |
+-----------------------+---------------+
| rpl_semi_sync_source  | ACTIVE        |
| rpl_semi_sync_replica | ACTIVE        |
+-----------------------+---------------+
```

`mysql_native_password` 已經不在外掛清單裡了。`legacy_report` 連 9.7 的 db2 時：

![ERROR 1524；在 8.4 主庫 ALTER USER 換成 caching_sha2_password 後，9.7 從庫登入成功](07-legacy-login.png)

因為帳號資料會複製，**在還是 8.4 的主庫上 `ALTER USER`** 就能一次修好所有節點。這也說明了正確的順序：**升級前先換外掛**，不要等 9.7 上線後才發現。

### 坑：9.x 的 mysql 用戶端不處理 `\G`

升級完 db2 後，同一個腳本裡的 `mysql -e "SELECT ...\G"` 開始失敗：

![mysql 9.7.2：-e 與管線輸入的 \G 都報 Unknown command；加 --commands 或改用 --vertical 才正常](08-client-commands.png)

9.x 的 `mysql` 用戶端新增了 `--commands` 選項，**非互動模式（`-e`、管線、`< script.sql`）預設不處理 `\G`、`\c` 這類用戶端指令**。互動模式不受影響，所以手動操作時不會發現，**是排程腳本、監控腳本在升級後突然失敗**。解法：

- 要直式輸出改用 `mysql --vertical`（或 `-E`），不要在 SQL 結尾寫 `\G`。
- 一定要用用戶端指令的腳本加 `--commands`（8.4 用戶端不認得這個選項，混合版本期間要注意）。

> 本系列的驗證腳本也中了這個坑：`SHOW REPLICA STATUS\G` 在 9.7 節點上什麼都沒印出來。之後的腳本都改成 `mysql --vertical`。
{: .prompt-info }

## 步驟 5：9.7 改了哪些預設值

同一台 db2 升級前後的變數比對（排除版本號、路徑、SSL 等不相關的項目）：

![back_log、binlog_transaction_dependency_history_size、caching_sha2_password_digest_rounds、explain_format、innodb_change_buffering 等](09-new-defaults.png)

| 變數 | 8.4.11 | 9.7.2 | 影響 |
| :--- | :--- | :--- | :--- |
| `explain_format` | TRADITIONAL | **TREE** | `EXPLAIN` 的輸出格式變了，解析 `EXPLAIN` 表格的工具要改，或在 session 設回 `TRADITIONAL` |
| `explain_json_format_version` | 1 | 2 | `EXPLAIN FORMAT=JSON` 的結構改版 |
| `innodb_change_buffering` | none | **all** | 8.4 把它關掉，9.7 又打開了 |
| `innodb_change_buffer_max_size` | 25 | 5 | change buffer 最多佔 buffer pool 的 5% |
| `caching_sha2_password_digest_rounds` | 5000 | 10000 | 只影響新設定的密碼雜湊，認證時 CPU 稍高 |
| `back_log` | 500 | 10000 | 連線佇列變長 |
| `binlog_transaction_dependency_history_size` | 25000 | 10000000 | WRITESET 記住更多資料列 hash，平行複製的判斷範圍更大 |
| `innodb_log_writer_threads` | ON | OFF | 依 vCPU 數決定，這台 4 vCPU |

> Checker 還列了 `group_replication_ssl_mode` → `REQUIRED`、`group_replication_recovery_use_ssl` → `ON`、thread pool 相關參數等，這台沒有載入 Group Replication 與 thread pool 外掛所以比對不到。**用 InnoDB Cluster 的環境要特別注意 Group Replication 預設要求 SSL**。
{: .prompt-warning }

## 步驟 6：升級 db3、切換、升級舊主庫

db3 照步驟 3~4 升級，此時 **8.4 主庫 → 兩台 9.7 從庫**，app 0 失敗（OK=410）。切換流程與 Lab 07 相同，db3 改接 db2 只需要改 `SOURCE_HOST`（其他連線參數會保留）：

```sql
-- db3
STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2'; START REPLICA;
```

切換的寫入中斷 **0.93 秒、失敗 4 筆**（`super_read_only` 擋下）。db1 先在設定檔加 `super_read_only = ON`，升級到 9.7（完整關機 11.5 秒、啟動約 5 秒）後接回 db2。db1 原本是主庫、沒有複製設定，所以要寫完整的連線參數，`repl` 已經是 `caching_sha2_password`，記得 `GET_SOURCE_PUBLIC_KEY = 1`：

```sql
-- db1
CHANGE REPLICATION SOURCE TO SOURCE_HOST='db2', SOURCE_USER='repl', SOURCE_PASSWORD='...',
  SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
```

```console
[db2] mysql> SHOW REPLICAS;
+-----------+------+------+-----------+--------------------------------------+
| Server_Id | Host | Port | Source_Id | Replica_UUID                         |
+-----------+------+------+-----------+--------------------------------------+
|         1 | db1  | 3306 |         2 | 0654f967-e4eb-11f1-bcc4-969437c2ccce |
|         3 | db3  | 3306 |         2 | 0d5b3430-e4eb-11f1-a735-fecf52fd4ac0 |
+-----------+------+------+-----------+--------------------------------------+
| Rpl_semi_sync_source_clients | 2     |
```

## 步驟 7：最終驗證

![OK=658 = 410 + 248；三台 9.7.2-3、5658 筆、CRC 相同](10-final.png)

三台都是 9.7.2-3，app 回報成功的 658 筆全部在資料庫裡，三台筆數與 CRC 相同。

## 實測踩到的坑

| 坑 | 現象 | 解法 |
| :--- | :--- | :--- |
| `percona-release setup -y ps-97-lts` | 停用全部 Percona 套件庫、沒有啟用 9.7；`dnf upgrade` 顯示 Complete 但沒升級 | `percona-release enable ps-97-lts release`，並確認 `dnf list` 有 9.7 |
| Upgrade Checker 9.7.1 | 0 錯誤，**沒有檢查認證外掛**，沒抓到 `mysql_native_password` 帳號 | 升級前自己查 `mysql.user` 的 `plugin` 欄位 |
| `mysql_native_password = ON` | 9.7 起不來：`unknown variable` | 先把帳號換成 `caching_sha2_password`，再拿掉這行 |
| 漏換的 `mysql_native_password` 帳號 | `ERROR 1524 Plugin 'mysql_native_password' is not loaded`，無法再打開 | 在 8.4 主庫 `ALTER USER ... IDENTIFIED WITH caching_sha2_password` |
| 9.x 用戶端 `--commands` | `mysql -e "...\G"` → `Unknown command '\G'` | 改用 `--vertical`，或加 `--commands` |
| `explain_format` 預設 TREE | 解析 `EXPLAIN` 表格輸出的工具壞掉 | 工具改用 `FORMAT=JSON`，或 session 設 `explain_format = TRADITIONAL` |
| XtraBackup 不會跟著升級 | `percona-xtrabackup-84` 還在 | 另裝 `percona-xtrabackup-97` |
| 舊 Shell 檢查新伺服器 | `cannot check MySQL server instances ... same as or higher than the MySQL Shell version` | 先升級 MySQL Shell |

## 驗證方式與結果

```bash
./08-10-setup-84.sh     # 8.4.11 一主二從（Lab 07 的最終設定 + 一個 mysql_native_password 帳號），app 寫入 db1
./08-20-upgrade-97.sh   # 套件庫切換、升級檢查、db2 / db3 升級、切換、db1 升級後接回、最終核對
```

| 步驟 | 怎麼驗證 | 結果 |
| :--- | :--- | :--- |
| 1 套件庫 | `ls /etc/yum.repos.d`、`dnf list` | ✅ 重現 `setup` 的坑；`enable` 後出現 9.7.2-3.1 |
| 2 升級檢查 | `util check-for-server-upgrade --config-path` | ⚠️ 0 錯誤、23 警告，但漏掉認證外掛 |
| 4 啟動 9.7 | 錯誤日誌、`SHOW REPLICA STATUS` | ✅ `80411 → 90702 completed`，IO / SQL `Yes`，啟動 4.5~5.3 秒 |
| 4 舊帳號 | `legacy_report` 登入 9.7 | ✅ 重現 `ERROR 1524`；換外掛後成功 |
| 6 混合版本 | 8.4 主庫寫入，比對筆數與 CRC | ✅ 一致，app OK=410、ERR=0 |
| 6 切換 | app 紀錄 | ✅ 中斷 0.93 秒、4 筆失敗 |
| 7 最終 | app 成功筆數 vs 資料庫、三台 CRC | ✅ 658 = 410 + 248，CRC 相同 |

## 小結

- MySQL 的 LTS 是 **8.0 → 8.4 → 9.7 → 28.4（預計）**，LTS 之間可以直接升級但不能跳過；9.7 之後改用 `YY.M` 日曆版號，要進 26.x Innovation 線只能從 9.7 升。
- 8.4 → 9.7 的升級流程和 8.0 → 8.4 相同，但 **`mysql_native_password` 在 9.x 完全移除**，而 9.7.1 的 Upgrade Checker 不會提醒你，升級前要自己查帳號。
- 升級時別相信「Complete!」：`percona-release setup` 可能什麼都沒啟用，`dnf list` 確認目標版本。
- 9.x 用戶端的 `--commands` 會讓腳本裡的 `\G` 失敗，`explain_format` 改成 TREE 會影響解析 `EXPLAIN` 的工具。

### 參考資料

- [MySQL 9.7 Reference Manual：Upgrading MySQL](https://dev.mysql.com/doc/refman/9.7/en/upgrading.html)
- [MySQL Releases: Innovation and LTS](https://dev.mysql.com/doc/refman/9.7/en/mysql-releases.html)
- [Percona Blog：Meet MySQL 26.7: A New Versioning Era Begins](https://www.percona.com/blog/meet-mysql-26-7-a-new-versioning-era-begins/)
- [endoflife.date：MySQL](https://endoflife.date/mysql)
- [MySQL 9.7 Reference Manual：mysql Client Options（--commands）](https://dev.mysql.com/doc/refman/9.7/en/mysql-command-options.html)
- [Percona Server for MySQL 9.7 文件](https://docs.percona.com/percona-server/9.7/)
