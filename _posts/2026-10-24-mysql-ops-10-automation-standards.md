---
title: MySQL 運維 10：自動化與規範制定
date: 2026-10-24 09:39:00 +0800
categories: [MySQL, 自動化與規範]
tags: [mysql, mysql8, dba, automation, ansible, mysql-shell, sql-standards, naming-convention]
description: 以 MySQL 8.0 為主，整理腳本與 Ansible 自動化、MySQL Shell AdminAPI、DBaaS 平台思維、SQL 開發規範、命名規範與運維文件化，並比較 5.7 與 8.4 LTS 的差異。
---

當管理的實例從 3 台變成 300 台，靠人工登入一台一台處理就行不通了。本篇是系列最後一篇，以 MySQL 8.0 為主，整理如何把前九篇的工作自動化、標準化，最後比較 5.7 與 8.4 對自動化腳本的影響。

{% include mysql-ops-series.md %}

## 自動化的層次

```text
Level 0  人工登入執行
Level 1  Shell / Python 腳本
Level 2  設定管理（Ansible）＋ 版本控管
Level 3  工單 / 自助平台（DBaaS）＋ 審核流程
Level 4  自動修復（Auto-remediation）
```

不需要一步到位，從「最常做、最容易出錯」的工作開始自動化：建立實例、建立帳號、備份與還原驗證、從庫重建、Schema 變更。

## 腳本：安全的寫法

```bash
#!/usr/bin/env bash
set -euo pipefail

# 帳密不要寫在腳本裡，用 mysql_config_editor 產生加密的 ~/.mylogin.cnf
#   mysql_config_editor set --login-path=dba --host=127.0.0.1 --user=dba --password
MYSQL="mysql --login-path=dba -N -B"

check_replica() {
  local lag
  lag=$($MYSQL -e "SHOW REPLICA STATUS\G" | awk '/Seconds_Behind_Source/ {print $2}')
  if [[ "$lag" == "NULL" || "$lag" -gt 60 ]]; then
    echo "replica lag abnormal: $lag" >&2
    return 1
  fi
}

check_replica
```

原則：

- **冪等（idempotent）**：重複執行結果一樣，例如 `CREATE USER IF NOT EXISTS`。
- **先 dry-run**：危險操作預設只印出要執行的 SQL，加 `--execute` 才真的執行。
- **記錄**：誰、何時、在哪台、做了什麼，寫入集中 log。
- **用新語法**：`SHOW REPLICA STATUS`、`Seconds_Behind_Source`，才能同時在 8.0 與 8.4 運作。

## Ansible

使用 `community.mysql` collection：

{% raw %}
```yaml
# playbook: mysql_users.yml
- hosts: mysql_primary
  become: true
  vars_files:
    - vault/mysql_secrets.yml          # ansible-vault 加密
  tasks:
    - name: Create application database
      community.mysql.mysql_db:
        name: shop
        encoding: utf8mb4
        collation: utf8mb4_0900_ai_ci
        login_unix_socket: /var/run/mysqld/mysqld.sock

    - name: Create application user
      community.mysql.mysql_user:
        name: app_shop
        host: "10.0.1.%"
        password: "{{ app_shop_password }}"
        plugin: caching_sha2_password
        priv: "shop.*:SELECT,INSERT,UPDATE,DELETE"
        state: present
        login_unix_socket: /var/run/mysqld/mysqld.sock

    - name: Persist global variable
      community.mysql.mysql_variables:
        variable: max_connections
        value: 2000
        mode: persist                  # 對應 SET PERSIST（8.0+）
        login_unix_socket: /var/run/mysqld/mysqld.sock
```

my.cnf 用 Jinja2 template 管理，依主機規格自動計算 `innodb_buffer_pool_size`：

```jinja
innodb_buffer_pool_size = {{ (ansible_memtotal_mb * 0.7) | int }}M
server_id               = {{ ansible_default_ipv4.address.split('.')[-1] | int + 1000 }}
```
{% endraw %}

## MySQL Shell：官方自動化工具

MySQL Shell 支援 JavaScript、Python、SQL 三種模式，也能非互動執行，很適合寫自動化：

```bash
# 升級前檢查
mysqlsh root@db1 -- util check-for-server-upgrade --target-version=8.4.0 --output-format=JSON

# 平行匯出 / 匯入
mysqlsh root@db1 -- util dump-schemas shop --output-url=/backup/shop --threads=8

# InnoDB Cluster 狀態
mysqlsh root@db1 -- cluster status
```

```python
# mysqlsh --py 腳本：檢查所有沒有主鍵的表
result = session.run_sql("""
  SELECT t.table_schema, t.table_name
  FROM information_schema.tables t
  LEFT JOIN information_schema.table_constraints c
    ON c.table_schema = t.table_schema AND c.table_name = t.table_name
   AND c.constraint_type = 'PRIMARY KEY'
  WHERE t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL
    AND t.table_schema NOT IN ('mysql','sys','performance_schema','information_schema')
""")
for row in result.fetch_all():
    print(f"{row[0]}.{row[1]}")
```

## DBaaS 平台思維

當團隊規模變大，可以把常見需求做成自助服務：

| 功能 | 說明 |
| :--- | :--- |
| 實例申請 | 選規格與版本，自動部署、加入監控與備份 |
| 帳號申請 | 選權限範本，審核後自動建立，密碼送至密碼管理系統 |
| SQL 審核 | 自動 lint（如 Archery、Bytebase、goInception），通過後排程執行 |
| 資料查詢 | 唯讀查詢介面，自動遮罩敏感欄位、記錄審計 |
| 備份還原 | 一鍵還原到指定時間點的新實例 |

## SQL 開發規範

### 建表規範

```sql
CREATE TABLE `order_item` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主鍵',
  `order_id`    BIGINT UNSIGNED NOT NULL COMMENT '訂單 ID',
  `product_id`  BIGINT UNSIGNED NOT NULL COMMENT '商品 ID',
  `quantity`    INT UNSIGNED    NOT NULL DEFAULT 1 COMMENT '數量',
  `unit_price`  DECIMAL(12,2)   NOT NULL COMMENT '單價',
  `created_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '建立時間',
  `updated_at`  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) COMMENT '更新時間',
  PRIMARY KEY (`id`),
  KEY `idx_order_id` (`order_id`),
  KEY `idx_product_id_created_at` (`product_id`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='訂單明細';
```

- 每張表**必須有主鍵**，建議用 `BIGINT UNSIGNED AUTO_INCREMENT` 或有序的 ID（避免隨機 UUID 造成頁分裂）。
- 一律 InnoDB、`utf8mb4`。
- 金額用 `DECIMAL`，不要用 `FLOAT`/`DOUBLE`。
- 欄位盡量 `NOT NULL` 並給預設值。
- 每張表、每個欄位都要有 `COMMENT`。
- 必備 `created_at`、`updated_at`。
- 單表索引數量建議不超過 5~6 個。

### 查詢規範

- 禁止 `SELECT *`，只取需要的欄位。
- `UPDATE`/`DELETE` 必須有 `WHERE` 並走索引；大量更新要分批。
- 禁止在 WHERE 條件的欄位上套函數或做隱式型別轉換。
- 避免大交易，單一交易修改列數建議 < 1 萬。
- 深分頁改用 Keyset Pagination。
- 不在資料庫中做重運算（大量 JSON 處理、複雜字串操作），交給應用程式。

### 命名規範

| 物件 | 規則 | 範例 |
| :--- | :--- | :--- |
| 資料庫 | 小寫、底線分隔、業務名稱 | `shop`、`user_center` |
| 表 | 小寫單數、底線分隔 | `order_item` |
| 欄位 | 小寫、底線分隔，布林用 `is_` 開頭 | `is_deleted` |
| 主鍵 | `id` | `id` |
| 普通索引 | `idx_欄位1_欄位2` | `idx_user_id_created_at` |
| 唯一索引 | `uk_欄位` | `uk_email` |
| 外鍵欄位 | `被參照表_id` | `user_id` |

**避免使用保留字**作為表名或欄位名。8.0 新增了不少保留字（如 `RANK`、`GROUPS`、`WINDOW`、`ROW_NUMBER`、`LATERAL`），5.7 時代合法的欄位名升級後可能變成語法錯誤。

## 運維文件化

每個資料庫叢集都應該有一份文件（放在 Git 或 Wiki），包含：

- **架構圖**：主從拓樸、Proxy、應用程式連線方式。
- **基本資料**：版本、規格、參數差異、負責人、業務重要性。
- **備份**：方式、頻率、保存位置、上次還原演練日期與耗時。
- **Runbook**：常見告警的處理步驟（見上一篇）。
- **變更紀錄**：重大變更、升級、事故的連結。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 參數持久化 | 只能改 my.cnf | `SET PERSIST`，Ansible 可用 `mode: persist` | 同 8.0 |
| MySQL Shell AdminAPI | 可管理 5.7 InnoDB Cluster（功能較少） | 完整支援 Cluster、ReplicaSet、ClusterSet | 同 8.0，新版 Shell 對齊 8.4 |
| 升級檢查 | — | `util.checkForServerUpgrade` | 同上，目標版本設 8.4 |
| 複製相關腳本 | `SLAVE`/`MASTER` 語法 | 新舊語法並存 | **只能用新語法** |
| 建帳號 | `GRANT ... IDENTIFIED BY` 可建帳號 | 必須 `CREATE USER` 再 `GRANT` | 同 8.0 |
| 預設認證 | `mysql_native_password` | `caching_sha2_password` | `mysql_native_password` 預設停用 |
| 保留字 | — | 新增大量保留字（`RANK`、`GROUPS` 等） | 同 8.0 |
| 預設字元集 / 排序 | `latin1` / `latin1_swedish_ci` | `utf8mb4` / `utf8mb4_0900_ai_ci` | 同 8.0 |
| `mysql_upgrade`、`mysqlpump`、`mysql_ssl_rsa_setup` | 存在 | 棄用 | **移除** |
| `mysql` client 新選項 | — | — | 新增 `--system-command`、`--commands`（可關閉 `system` 指令） |

### 給自動化腳本的升級建議

1. 在 8.0 就把所有腳本改成新語法（`SHOW REPLICA STATUS`、`CHANGE REPLICATION SOURCE TO`、`SHOW BINARY LOG STATUS` 需 8.2+，8.0 仍用 `SHOW MASTER STATUS`，可依版本判斷）。
2. 移除對 `mysqlpump`、`mysql_upgrade`、`mysql_ssl_rsa_setup` 的呼叫。
3. Ansible 的 `community.mysql` 升到新版，以支援新語法與 8.4。
4. 在 CI 中用 8.4 容器跑一次所有腳本與 migration，提早抓出不相容的地方。

## 系列總結

這十篇從安裝、備份、高可用、監控、效能、容量、安全、變更、排障到自動化，整理了 MySQL 8.0 運維的主要面向。幾個貫穿全系列的重點：

- **8.0 已在 2026-04-30 EOL**，現在就該規劃升級到 8.4 LTS。
- 升級最大的坑：**舊複製語法移除**、**`mysql_native_password` 預設停用**、**InnoDB 預設值改變**、**已移除的工具與參數**。
- 所有運維工作的最終形態，都是「有文件、可重複、自動化、可審計」。

感謝閱讀，有任何問題歡迎到 [GitHub](https://github.com/jimmyjan0824) 與我交流。

### 參考資料

- [MySQL Shell 8.4 Manual](https://dev.mysql.com/doc/mysql-shell/8.4/en/)
- [Ansible community.mysql collection](https://docs.ansible.com/ansible/latest/collections/community/mysql/index.html)
- [MySQL 8.0 Reference Manual：Keywords and Reserved Words](https://dev.mysql.com/doc/refman/8.0/en/keywords.html)
- [MySQL 8.4 Release Notes：Changes in MySQL 8.4.0](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)
