---
title: MySQL 運維 07：安全與權限管理
date: 2026-10-24 09:36:00 +0800
categories: [MySQL, 安全權限]
tags: [mysql, mysql8, dba, security, roles, caching-sha2-password, tls, encryption, audit]
description: 以 MySQL 8.0 為主，整理帳號與最小權限、角色、密碼策略、認證外掛、SSL/TLS、資料加密與審計，並比較 5.7 與 8.4 LTS 的差異。
---

資料庫是攻擊者最想拿到的東西。本篇以 MySQL 8.0 為主，從帳號權限、密碼、連線加密、資料加密到審計逐層整理，最後比較 5.7 與 8.4 的差異；其中 **8.4 預設停用 `mysql_native_password`** 是升級時最容易造成連線失敗的一項。

{% include mysql-ops-series.md %}

## 帳號與最小權限

### 帳號規劃

| 帳號類型 | 範例 | 權限 |
| :--- | :--- | :--- |
| 應用程式 | `app_shop@10.0.1.%` | 只給該 schema 的 DML |
| 唯讀報表 | `report@10.0.2.%` | 只給 `SELECT` |
| 遷移 / DDL | `migrator@10.0.3.10` | 該 schema 的 DDL，平時鎖定 |
| 備份 | `bkuser@localhost` | `BACKUP_ADMIN`、`RELOAD`… |
| 監控 | `exporter@localhost` | `PROCESS`、`REPLICATION CLIENT`、`SELECT` |
| 個人 DBA | `jimmy@10.0.9.%` | 透過角色授權，個人帳號可審計 |

原則：

- **一個用途一個帳號**，不要共用。
- **限制來源主機**，不要用 `'%'`。
- `root` 只允許 `localhost`，日常不使用。
- 定期清查：`SELECT user, host, account_locked, password_last_changed FROM mysql.user;`

### 8.0 的角色（Role）

```sql
CREATE ROLE 'r_app_rw', 'r_app_ro';
GRANT SELECT, INSERT, UPDATE, DELETE ON shop.* TO 'r_app_rw';
GRANT SELECT ON shop.* TO 'r_app_ro';

CREATE USER 'app_shop'@'10.0.1.%' IDENTIFIED BY '***';
GRANT 'r_app_rw' TO 'app_shop'@'10.0.1.%';
SET DEFAULT ROLE ALL TO 'app_shop'@'10.0.1.%';   -- 很重要，否則登入後角色未啟用

SHOW GRANTS FOR 'app_shop'@'10.0.1.%' USING 'r_app_rw';
```

> 角色授權後，若沒有 `SET DEFAULT ROLE`，使用者登入時角色預設不會啟用，會出現「明明有授權卻沒權限」的狀況。也可以設定 `activate_all_roles_on_login = ON`。
{: .prompt-warning }

### 動態權限：拆解 SUPER

8.0 把 `SUPER` 拆成細粒度的動態權限，`SUPER` 本身已棄用：

| 動態權限 | 用途 |
| :--- | :--- |
| `SYSTEM_VARIABLES_ADMIN` | 修改全域變數 |
| `REPLICATION_SLAVE_ADMIN` | 管理複製 |
| `BINLOG_ADMIN` | 管理 binlog |
| `CONNECTION_ADMIN` | 連線數滿時仍可登入、KILL 他人連線 |
| `BACKUP_ADMIN` | 執行 `LOCK INSTANCE FOR BACKUP` |
| `SYSTEM_USER` | 保護高權限帳號不被一般管理員修改或 KILL |

### Partial Revokes（8.0.16+）

```sql
SET PERSIST partial_revokes = ON;
GRANT SELECT ON *.* TO 'analyst'@'10.0.2.%';
REVOKE SELECT ON hr.* FROM 'analyst'@'10.0.2.%';   -- 除了 hr 以外都能讀
```

## 密碼策略

```sql
-- 密碼強度檢查（8.0 改為 component）
INSTALL COMPONENT 'file://component_validate_password';
SET PERSIST validate_password.policy = MEDIUM;
SET PERSIST validate_password.length = 14;

-- 帳號層級策略
CREATE USER 'jimmy'@'10.0.9.%' IDENTIFIED BY '***'
  PASSWORD EXPIRE INTERVAL 90 DAY
  PASSWORD HISTORY 5                 -- 不可重複使用最近 5 組
  PASSWORD REUSE INTERVAL 365 DAY
  PASSWORD REQUIRE CURRENT           -- 改密碼需輸入舊密碼（8.0.13+）
  FAILED_LOGIN_ATTEMPTS 5            -- 連續失敗 5 次（8.0.19+）
  PASSWORD_LOCK_TIME 1;              -- 鎖定 1 天

-- 雙密碼：輪換應用程式密碼不停機（8.0.14+）
ALTER USER 'app_shop'@'10.0.1.%' IDENTIFIED BY 'new***' RETAIN CURRENT PASSWORD;
-- 所有應用程式都換成新密碼後
ALTER USER 'app_shop'@'10.0.1.%' DISCARD OLD PASSWORD;
```

## 認證外掛

| 外掛 | 說明 |
| :--- | :--- |
| `mysql_native_password` | SHA1 雜湊，5.7 預設，已不安全 |
| `caching_sha2_password` | SHA-256 + 快取，**8.0 預設** |
| `auth_socket` | 依 Unix socket 的 OS 使用者認證，適合本機 root |
| `authentication_ldap_*`、Kerberos | Enterprise 版 |

`caching_sha2_password` 首次連線需要「安全通道」（TLS 或 RSA 金鑰交換），舊版驅動不支援時會出現：

```text
Authentication plugin 'caching_sha2_password' cannot be loaded
```

解法是**升級驅動**（如 MySQL Connector/J 8.0+、PHP 7.4+ mysqlnd），而不是把帳號改回 `mysql_native_password`。

```sql
-- 找出還在用舊外掛的帳號
SELECT user, host, plugin FROM mysql.user WHERE plugin = 'mysql_native_password';

-- 轉換
ALTER USER 'legacy_app'@'10.0.1.%' IDENTIFIED WITH caching_sha2_password BY '***';
```

## 連線加密：SSL/TLS

8.0 啟動時若找不到憑證，會自動產生自簽憑證，所以預設就支援 TLS，但**不強制**。

```ini
[mysqld]
require_secure_transport = ON
tls_version              = TLSv1.2,TLSv1.3
ssl_ca                   = /etc/mysql/ssl/ca.pem
ssl_cert                 = /etc/mysql/ssl/server-cert.pem
ssl_key                  = /etc/mysql/ssl/server-key.pem
```

```sql
-- 換憑證不用重啟（8.0.16+）
ALTER INSTANCE RELOAD TLS;

-- 針對帳號強制
ALTER USER 'app_shop'@'10.0.1.%' REQUIRE SSL;

-- 檢查目前連線是否加密
SELECT * FROM performance_schema.status_by_thread WHERE VARIABLE_NAME = 'Ssl_version';
```

## 資料加密（靜態加密）

InnoDB 支援表空間加密（TDE），需要先設定 keyring：

```sql
-- 8.0 建議使用 keyring component（8.0.24+），8.4 只能用 component
-- 透過 mysqld.my 與 component_keyring_file.cnf 設定後重啟

ALTER TABLE customers ENCRYPTION = 'Y';
SET PERSIST default_table_encryption = ON;   -- 8.0.16+ 新建 schema/表預設加密
SET PERSIST innodb_redo_log_encrypt = ON;    -- 8.0.16+ redo 加密
SET PERSIST innodb_undo_log_encrypt = ON;    -- 8.0.16+ undo 加密
SET PERSIST binlog_encryption = ON;          -- 8.0.14+ binlog 加密
```

> keyring 檔案就是解密金鑰，**不要跟資料目錄或備份放在一起**，並且要獨立備份。金鑰遺失 = 資料遺失。
{: .prompt-danger }

## 審計與弱點修補

- **審計日誌**：社群版沒有官方 Audit Plugin，可用 Percona Server 的 Audit Log Plugin，或 MariaDB Audit Plugin；Enterprise 版有 `audit_log`。
- **最少要記錄**：登入失敗、權限變更（`GRANT`/`REVOKE`/`CREATE USER`）、DDL、高權限帳號的所有操作。
- **弱點修補**：追蹤 Oracle 每季的 Critical Patch Update（CPU），8.0 EOL 後不再有修補，這也是應該升級 8.4 的主要原因。
- **資料遮罩**：非正式環境的資料要去識別化；Enterprise 版有 Data Masking，社群版可以在匯出時用 SQL 或工具處理。

## 版本差異比較：5.7 vs 8.0 vs 8.4

| 項目 | 5.7 | 8.0 | 8.4 LTS |
| :--- | :--- | :--- | :--- |
| 預設認證外掛 | `mysql_native_password` | `caching_sha2_password` | `caching_sha2_password` |
| `mysql_native_password` | 預設 | 可用，8.0.34 起棄用 | **預設停用**，需 `--mysql-native-password=ON` 才能載入 |
| 設定預設外掛 | `default_authentication_plugin` | `default_authentication_plugin`（棄用）/ `authentication_policy`（8.0.27+） | `default_authentication_plugin` **移除** |
| 角色 | 無 | 有 | 有 |
| 動態權限 | 無，只有 `SUPER` | 有，`SUPER` 棄用 | 有，新增 `FLUSH_PRIVILEGES`、`OPTIMIZE_LOCAL_TABLE`、`TRANSACTION_GTID_TAG`、`SET_ANY_DEFINER`、`ALLOW_NONEXISTENT_DEFINER` |
| `SET_USER_ID` 權限 | — | 有 | **移除**，改用 `SET_ANY_DEFINER` / `ALLOW_NONEXISTENT_DEFINER` |
| `GRANT` 自動建帳號 | 棄用，預設 `NO_AUTO_CREATE_USER` 會阻擋未給密碼的情況 | **不行**，必須先 `CREATE USER` | 同 8.0 |
| 密碼歷史、登入失敗鎖定、雙密碼 | 無 | 有 | 有 |
| `validate_password` | Plugin | Component（Plugin 棄用） | Component |
| TLS 版本 | TLSv1、1.1、1.2（是否支援 1.3 視版本與 OpenSSL 而定） | 8.0.28 起移除 TLSv1/1.1，支援 TLSv1.3 | 只允許 TLSv1.2/1.3，並移除弱加密套件 |
| `--ssl` / `have_ssl` | 可用 | 8.0.26 起棄用 | **移除**，改用 `--tls-version` |
| `mysql_ssl_rsa_setup` | 需手動執行 | 伺服器自動產生，8.0.34 起棄用此工具 | **移除** |
| Keyring | `keyring_file` plugin | Plugin 與 Component（8.0.24+）並存 | `keyring_file`、`keyring_encrypted_file` plugin **移除**，只能用 component |
| Redo/Undo/Binlog 加密 | 無 | 有 | 有 |

### 升級到 8.4 的安全檢查清單

1. 查出所有 `plugin = 'mysql_native_password'` 的帳號，先在 8.0 轉成 `caching_sha2_password`，並確認所有驅動都支援。
2. my.cnf 中的 `default_authentication_plugin` 要移除或改成 `authentication_policy`，否則 8.4 會無法啟動。
3. 使用 keyring plugin 做 TDE 的實例，要先在 8.0 遷移到 keyring component。
4. 有使用 `SET_USER_ID` 權限的帳號、`--ssl` 參數都要調整。

## 小結

- 用角色 + 動態權限實踐最小權限，`root` 只留給本機緊急使用。
- 8.0 的密碼策略、雙密碼、`caching_sha2_password` 都應該啟用。
- 強制 TLS，敏感資料開啟 TDE，金鑰要分開保管。
- 8.0 已 EOL、不再有安全修補，規劃升級到 8.4 本身就是安全工作的一部分。

下一篇：[變更管理與發布]({% post_url 2026-10-24-mysql-ops-08-change-management %})。

### 參考資料

- [MySQL 8.0 Reference Manual：Security](https://dev.mysql.com/doc/refman/8.0/en/security.html)
- [MySQL 8.0 Reference Manual：Using Roles](https://dev.mysql.com/doc/refman/8.0/en/roles.html)
- [MySQL 8.4 Release Notes：Changes in MySQL 8.4.0](https://dev.mysql.com/doc/relnotes/mysql/8.4/en/news-8-4-0.html)
