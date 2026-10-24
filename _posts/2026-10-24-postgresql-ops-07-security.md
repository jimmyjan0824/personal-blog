---
title: PostgreSQL 運維 07：安全與權限管理
date: 2026-10-24 14:00:00 +0800
categories: [PostgreSQL, 安全]
tags: [postgresql, postgresql17, postgresql18, dba, security, roles, pg_hba, scram, tls, pgaudit, rls]
description: 以 PostgreSQL 17 為主，整理角色與最小權限、預設權限、pg_hba.conf 與 SCRAM 認證、SSL/TLS、資料列層級安全、稽核（pgaudit）、資料加密與遮罩，並比較 18 的差異。
---

PostgreSQL 的權限模型以**角色（role）**為核心：使用者和群組都是角色。本篇從帳號規劃、連線認證、加密到稽核依序整理，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 角色與最小權限

建議的角色結構：

| 角色 | 用途 | 權限 |
| :--- | :--- | :--- |
| `postgres` | 超級使用者 | 只在本機用 `peer` 登入，不給應用程式 |
| `dba_xxx` | 個人 DBA 帳號 | `CREATEDB`、`CREATEROLE`，必要時才切換成 superuser |
| `app_owner` | 擁有 schema 與資料表，只用來跑 migration | `NOLOGIN` 或只給 CI 用 |
| `app_rw` | 應用程式讀寫 | `SELECT/INSERT/UPDATE/DELETE` |
| `app_ro` | 報表、唯讀查詢 | `SELECT` |
| `monitor` | 監控 | `pg_monitor` |
| `replicator` | 複製 | `REPLICATION` |

```sql
-- 15 起 public schema 預設不能讓所有人建立物件；14 以前要自己 REVOKE
REVOKE ALL ON DATABASE appdb FROM PUBLIC;

CREATE ROLE app_owner NOLOGIN;
CREATE SCHEMA app AUTHORIZATION app_owner;

CREATE ROLE app_rw NOLOGIN;
CREATE ROLE app_ro NOLOGIN;
GRANT CONNECT ON DATABASE appdb TO app_rw, app_ro;
GRANT USAGE ON SCHEMA app TO app_rw, app_ro;

-- 既有的表
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_rw;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_ro;

-- 之後 app_owner 建立的表自動授權（最容易漏掉的一步）
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app GRANT USAGE ON SEQUENCES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA app GRANT SELECT ON TABLES TO app_ro;

-- 實際登入的帳號繼承群組角色
CREATE ROLE order_service LOGIN PASSWORD '...' IN ROLE app_rw;
ALTER ROLE order_service SET statement_timeout = '30s';
ALTER ROLE order_service CONNECTION LIMIT 100;
```

### 內建角色

| 角色 | 用途 |
| :--- | :--- |
| `pg_monitor` | 讀取所有監控檢視 |
| `pg_read_all_data` / `pg_write_all_data`（14+） | 所有表的讀 / 寫，適合備份、ETL 帳號 |
| `pg_signal_backend` | 取消或中止其他（非 superuser）連線 |
| `pg_maintain`（17+） | 對所有表執行 `VACUUM`、`ANALYZE`、`REINDEX`、`REFRESH MATERIALIZED VIEW`、`CLUSTER`、`LOCK`，不必是 owner |
| `pg_checkpoint`（15+） | 執行 `CHECKPOINT` |
| `pg_use_reserved_connections`（16+） | 使用 `reserved_connections` 保留的連線 |

17 新增的 `MAINTAIN` 權限可以單獨授權給某張表：`GRANT MAINTAIN ON app.orders TO dba_ops;`，維運帳號不再需要是 owner 或 superuser。

## 連線認證：pg_hba.conf

`pg_hba.conf` 由上往下比對，第一筆符合的規則生效：

```text
# TYPE  DATABASE     USER         ADDRESS            METHOD
local   all          postgres                        peer
host    replication  replicator   10.0.1.0/24        scram-sha-256
hostssl appdb        +app_rw      10.0.2.0/24        scram-sha-256
host    all          all          0.0.0.0/0          reject
```

- **一律用 `scram-sha-256`**，不要用 `md5`、更不要用 `trust`。
- `+app_rw` 表示「app_rw 角色的成員」，用群組管理比逐一列帳號好維護。
- `hostssl` 只接受 TLS 連線；`hostnossl` 可以用來明確拒絕未加密的連線。
- `replication` 是特殊關鍵字，`all` **不包含**複製連線。
- 改完 `SELECT pg_reload_conf();`，再用 `SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;` 檢查語法錯誤。

既有的 md5 密碼要遷移到 SCRAM：先確認 `password_encryption = scram-sha-256`（預設），再讓使用者重設一次密碼。

```sql
-- 還在用 md5 雜湊的帳號
SELECT rolname FROM pg_authid WHERE rolpassword LIKE 'md5%';
```

## 連線加密：SSL/TLS

```ini
# postgresql.conf
ssl = on
ssl_cert_file = '/etc/pki/postgresql/server.crt'
ssl_key_file = '/etc/pki/postgresql/server.key'   # 權限 600，擁有者 postgres
ssl_min_protocol_version = 'TLSv1.2'              # 預設就是 TLSv1.2
```

用戶端用 `sslmode=verify-full` 並指定 `sslrootcert`，才能防止中間人攻擊；`require` 只加密、不驗證主機。17 新增 `sslnegotiation=direct`，用戶端可以直接開始 TLS 握手，少一次往返。

```sql
-- 哪些連線沒有加密
SELECT a.usename, a.client_addr, s.ssl, s.version
FROM pg_stat_activity a JOIN pg_stat_ssl s USING (pid)
WHERE a.backend_type = 'client backend';
```

## 資料列層級安全（RLS）

多租戶系統可以讓資料庫強制「只能看到自己租戶的資料」：

```sql
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON app.orders
  USING (tenant_id = current_setting('app.tenant_id')::bigint);
-- 應用程式每個交易開頭：SET LOCAL app.tenant_id = '42';
```

表的 owner 與 superuser 預設不受 RLS 限制；要連 owner 也受限，加 `ALTER TABLE ... FORCE ROW LEVEL SECURITY`。

## 稽核：pgaudit

內建的 `log_statement = 'ddl'` 可以記錄所有 DDL，但沒辦法依物件或角色篩選。正式的稽核需求用 **pgaudit**（PGDG 有 `pgaudit_17` 套件）：

```ini
shared_preload_libraries = 'pg_stat_statements,pgaudit'
pgaudit.log = 'ddl, role'          # 記錄 DDL 與權限變更
pgaudit.log_relation = on
```

需要記錄特定表的讀寫時，用 object audit：建立一個稽核角色，對它授權要追蹤的表，`pgaudit.role` 指向它。稽核日誌量可能很大，要送到集中式日誌系統（例如 ELK、Loki）並設定保留期限。

## 資料加密與遮罩

| 需求 | 做法 |
| :--- | :--- |
| 靜態加密（磁碟） | 社群版**沒有 TDE**。用檔案系統或磁碟層加密（LUKS、雲端磁碟加密）；商業版本（EDB）或 Percona 的 `pg_tde` 擴充套件提供 TDE |
| 欄位加密 | `pgcrypto` 的 `pgp_sym_encrypt()`，或在應用程式端加密（金鑰不進資料庫，更安全） |
| 資料遮罩 | `postgresql_anonymizer` 擴充套件：動態遮罩、產生去識別化的測試資料 |
| 備份加密 | pgBackRest 的 `repo1-cipher-type=aes-256-cbc` |

## 弱點修補

- Minor 版本每季更新，安全修補都在裡面，**一定要跟**。
- 訂閱 [PostgreSQL Security](https://www.postgresql.org/support/security/) 公告。
- 擴充套件（PostGIS、pgaudit 等）也要一起更新。
- 定期檢查：誰是 superuser、哪些帳號沒設密碼期限、`pg_hba.conf` 有沒有 `trust`。

```sql
SELECT rolname, rolsuper, rolcreaterole, rolcanlogin, rolvaliduntil
FROM pg_roles WHERE rolsuper OR rolcreaterole ORDER BY 1;
```

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| 維護權限 | 新增 `MAINTAIN` 權限與 `pg_maintain` 角色 | 沿用 |
| md5 密碼 | 可用 | **標為淘汰**：設定 md5 密碼時發出警告（`md5_password_warnings`），未來版本會移除 |
| OAuth | 無 | 新增 `oauth` 認證方法（需另外提供 validator 模組） |
| TLS | 新增 `sslnegotiation=direct` | 新增 `ssl_tls13_ciphers`；`ssl_ecdh_curve` 移除，改為 `ssl_groups`（可設多個，預設 `X25519:prime256v1`），設定檔裡有 `ssl_ecdh_curve` 的要改名 |
| `postgres_fdw` / `dblink` | 要在 user mapping 裡存密碼 | 可以把用戶端的 SCRAM 驗證資訊傳遞到遠端，不必存明文密碼 |
| 終止 autovacuum | 要 superuser | 新增 `pg_signal_autovacuum_worker` 角色 |

18.6 上設定 md5 密碼的實際警告：

```text
postgres=# SET password_encryption = 'md5'; CREATE ROLE md5_test LOGIN PASSWORD 'x';
WARNING:  setting an MD5-encrypted password
DETAIL:  MD5 password support is deprecated and will be removed in a future release of PostgreSQL.
HINT:  Refer to the PostgreSQL documentation for details about migrating to another password type.
```

17.11 執行同樣的指令沒有任何警告。

### 給安全的升級建議

- 升到 18 前先把所有 md5 密碼換成 SCRAM，否則會收到大量警告，且未來的版本不能再用。
- 18 的 OAuth 適合已有 SSO 的組織，但需要另外部署 validator，評估後再導入。

## 小結

- 角色分層：owner、讀寫、唯讀、監控、複製；用 `ALTER DEFAULT PRIVILEGES` 讓新表自動授權。
- `pg_hba.conf` 只用 `scram-sha-256`，最後一行 `reject`。
- 跨網路連線用 TLS + `verify-full`。
- 社群版沒有 TDE，靜態加密靠磁碟層。

下一篇：[變更管理與發布]({% post_url 2026-10-24-postgresql-ops-08-change-management %})。

### 參考資料

- [PostgreSQL 17 文件：Database Roles](https://www.postgresql.org/docs/17/user-manag.html)
- [PostgreSQL 17 文件：Predefined Roles](https://www.postgresql.org/docs/17/predefined-roles.html)
- [PostgreSQL 17 文件：The pg_hba.conf File](https://www.postgresql.org/docs/17/auth-pg-hba-conf.html)
- [PostgreSQL 17 文件：Row Security Policies](https://www.postgresql.org/docs/17/ddl-rowsecurity.html)
- [pgaudit](https://github.com/pgaudit/pgaudit)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
