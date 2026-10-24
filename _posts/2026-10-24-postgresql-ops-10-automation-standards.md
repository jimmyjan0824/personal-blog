---
title: PostgreSQL 運維 10：自動化與規範制定
date: 2026-10-24 14:30:00 +0800
categories: [PostgreSQL, 自動化]
tags: [postgresql, postgresql17, postgresql18, dba, automation, ansible, patroni, standards, naming-convention, documentation]
description: 以 PostgreSQL 17 為主，整理日常維運腳本、Ansible 自動化部署、Patroni 與 Kubernetes Operator、SQL 開發規範、命名規範與運維文件化，並比較 18 的差異。
---

前面九篇整理了 PostgreSQL 運維的各個面向，最後一篇把它們串起來：**能自動化的就自動化，不能自動化的就寫成規範與文件**。本篇最後比較 18 對自動化與規範的影響。

{% include postgresql-ops-series.md %}

## 日常維運腳本

適合用排程（systemd timer 或 cron）自動跑的工作：

| 工作 | 頻率 | 做法 |
| :--- | :--- | :--- |
| 物理備份 | 每天 / 每週 | pgBackRest（見[備份篇]({% post_url 2026-10-24-postgresql-ops-02-backup-restore %})） |
| 還原演練 | 每月 | 自動還原到測試機 + `pg_amcheck` + 筆數比對 |
| 容量記錄 | 每天 | 寫入 `dba_capacity_log`（見[容量規劃篇]({% post_url 2026-10-24-postgresql-ops-06-capacity-scaling %})） |
| 分區維護 | 每天 | pg_partman 的 `run_maintenance_proc()` |
| `pg_stat_statements` 快照 | 每小時 | 存起來再 reset，供趨勢比較 |
| 未使用索引、膨脹報告 | 每週 | 產生報表給開發團隊 |
| 權限稽核 | 每月 | superuser 清單、`pg_hba.conf` 差異 |

以 systemd timer 跑每日備份為例：

```ini
# /etc/systemd/system/pgbackrest-incr.service
[Unit]
Description=pgBackRest incremental backup

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/bin/pgbackrest --stanza=main --type=incr backup
```

```ini
# /etc/systemd/system/pgbackrest-incr.timer
[Unit]
Description=Daily pgBackRest incremental backup

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

比 cron 好的地方：失敗會記錄在 journal、可以 `systemctl list-timers` 看下次執行時間，`Persistent=true` 讓主機關機錯過的排程在開機後補跑。

## Ansible 自動化部署

把 [Standalone 實作]({% post_url 2026-10-24-postgresql-lab-01-standalone %})的步驟寫成 Ansible role，每台新主機都一樣：

{% raw %}
```yaml
# roles/postgresql/tasks/main.yml（節錄）
- name: Install PGDG repo
  ansible.builtin.dnf:
    name: "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-{{ ansible_architecture }}/pgdg-redhat-repo-latest.noarch.rpm"

- name: Disable AppStream postgresql module
  ansible.builtin.command: dnf -qy module disable postgresql
  changed_when: false

- name: Install PostgreSQL
  ansible.builtin.dnf:
    name: ["postgresql{{ pg_major }}-server", "postgresql{{ pg_major }}-contrib"]

- name: initdb
  ansible.builtin.command: "/usr/pgsql-{{ pg_major }}/bin/postgresql-{{ pg_major }}-setup initdb"
  environment:
    PGSETUP_INITDB_OPTIONS: "--data-checksums --encoding=UTF8 --locale=C.UTF-8 --locale-provider=builtin --builtin-locale=C.UTF-8"
  args:
    creates: "/var/lib/pgsql/{{ pg_major }}/data/PG_VERSION"

- name: postgresql.conf
  ansible.builtin.template:
    src: postgresql.conf.j2
    dest: "/var/lib/pgsql/{{ pg_major }}/data/postgresql.conf"
    owner: postgres
    group: postgres
    mode: "0600"
  notify: reload postgresql
```

`postgresql.conf.j2` 裡用主機記憶體計算參數：

```jinja
shared_buffers = {{ (ansible_memtotal_mb * 0.25) | int }}MB
effective_cache_size = {{ (ansible_memtotal_mb * 0.75) | int }}MB
max_parallel_workers = {{ ansible_processor_vcpus }}
```
{% endraw %}

注意 handler 的區別：大部分參數 `reload` 即可；`shared_buffers`、`max_connections` 等 `postmaster` 層級的參數要**重啟**，不要讓 Ansible 自動重啟正式環境的主庫，而是產生 `pending_restart` 報告，排維護時段處理。

## 高可用與平台化

| 層級 | 工具 |
| :--- | :--- |
| 自動故障切換 | **Patroni** + etcd：設定也由 Patroni 管理（`patronictl edit-config`），一處修改、所有節點同步 |
| 部署 Patroni 叢集 | [autobase](https://github.com/vitabaks/autobase)（原 postgresql_cluster）等 Ansible 專案 |
| Kubernetes | **CloudNativePG**、Zalando postgres-operator、Crunchy PGO：宣告式管理叢集、備份、切換 |
| DBaaS 平台 | 內部入口網站讓開發者申請資料庫，背後呼叫上述工具 |

在 Kubernetes 上跑 PostgreSQL 已經相當成熟，CloudNativePG 是 CNCF 專案，直接用 PostgreSQL 的串流複製，不依賴外部的 etcd。

## SQL 開發規範

給開發團隊的規範要短、可以檢查：

**設計**

- 每張表都要有主鍵，新表用 `bigint GENERATED ALWAYS AS IDENTITY`（或 UUID v7）。
- 時間欄位用 `timestamptz`，不要用 `timestamp`（沒有時區）。
- 金額用 `numeric`，不要用 `float` / `double precision`。
- 字串用 `text`（需要長度限制就加 `CHECK`），`varchar(n)` 和 `text` 效能相同。
- 外鍵欄位要建索引。
- JSON 用 `jsonb`，不要用 `json`；常查詢的欄位抽成一般欄位。

**查詢**

- 禁止 `SELECT *`（尤其有大欄位的表）。
- 禁止在 `WHERE` 對欄位套函式或轉型（除非有對應的運算式索引）。
- 分頁用 keyset，不用大 `OFFSET`。
- 批次寫入用多值 `INSERT` 或 `COPY`。
- 交易要短，不在交易中呼叫外部 API。

**上線**

- 所有 Schema 變更走 migration 工具，設定 `lock_timeout`（見[變更管理篇]({% post_url 2026-10-24-postgresql-ops-08-change-management %})）。
- 新查詢上線前附 `EXPLAIN` 結果。
- 應用程式要處理 `40001`（序列化失敗）與 `40P01`（死鎖）並重試。

## 命名規範

| 物件 | 規則 | 例子 |
| :--- | :--- | :--- |
| 資料表 | 小寫、底線、複數 | `orders`、`order_items` |
| 欄位 | 小寫、底線 | `created_at`、`customer_id` |
| 主鍵 | `<table>_pkey`（PostgreSQL 預設） | `orders_pkey` |
| 外鍵 | `fk_<table>_<ref>` | `fk_order_items_orders` |
| 索引 | `idx_<table>_<columns>` | `idx_orders_customer_id_created_at` |
| 唯一索引 | `uq_<table>_<columns>` | `uq_users_email` |
| CHECK 約束 | `ck_<table>_<rule>` | `ck_orders_amount_positive` |
| Schema | 依應用或領域 | `app`、`billing` |
| 角色 | `<app>_rw`、`<app>_ro`、個人帳號 `dba_<name>` | `order_rw` |

**全部小寫、不要用雙引號**。PostgreSQL 會把沒加引號的識別字轉成小寫，建立時用了 `"OrderItems"`，之後每次都得加引號才查得到。

## 運維文件化

| 文件 | 內容 |
| :--- | :--- |
| 架構圖 | 主機、IP、角色、複製拓樸、連線路徑（應用 → PgBouncer → HAProxy → PostgreSQL） |
| 設定基準 | 本系列實作篇的 `postgresql.conf`、`pg_hba.conf`，放在 Git |
| Runbook | 每個告警一份處理步驟（見[故障排查篇]({% post_url 2026-10-24-postgresql-ops-09-troubleshooting %})） |
| 操作手冊 | 切換、擴容、升級、還原的步驟與檢查清單 |
| 聯絡資訊 | 各資料庫的負責團隊、升級對象 |
| 變更紀錄 | 參數調整、版本升級的時間與原因 |

文件和設定都放在 Git，用 Pull Request 審核；這也是本系列實作篇把設定檔與測試腳本放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/postgresql-lab) 的原因。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| initdb | 要自己加 `--data-checksums` | 預設開，Ansible role 若要和 17 叢集一致（例如要 `pg_upgrade`）需加 `--no-data-checksums` |
| 參數範本 | `effective_io_concurrency` 等要自己調 | 新增 `io_method`、`io_workers`、`autovacuum_worker_slots`；I/O 相關預設值改變，範本要分版本 |
| `pg_upgrade` 自動化 | 升級後要排 `vacuumdb --analyze-in-stages` | 保留統計資訊；`--swap` 加快大型叢集；`--jobs` 也用在檢查階段 |
| UUID 主鍵 | `gen_random_uuid()` | 規範可改為 `uuidv7()` |
| Generated column | `STORED` | 預設 virtual，規範要明確寫出使用哪一種 |
| 認證 | SCRAM | md5 淘汰警告；可選 OAuth |

### 給自動化的升級建議

- Ansible role、Patroni 設定範本要以大版本為變數（`pg_major`），參數依版本分開維護。
- 升級流程寫成 playbook 並在測試環境演練，包含 `pg_upgrade --check`、extension 版本、checksums 是否一致。

## 小結

- 備份、還原演練、容量記錄、分區維護都排程自動化，用 systemd timer 比 cron 好管理。
- 部署用 Ansible role，HA 用 Patroni，Kubernetes 上用 CloudNativePG 等 Operator。
- 開發規範要短且可以檢查；命名全部小寫、不加引號。
- 設定、Runbook、文件都放在 Git。

這是 PostgreSQL 運維系列的最後一篇，回到 [第一篇]({% post_url 2026-10-24-postgresql-ops-01-installation-config %})。

### 參考資料

- [PostgreSQL 17 文件：Routine Database Maintenance Tasks](https://www.postgresql.org/docs/17/maintenance.html)
- [Ansible community.postgresql collection](https://docs.ansible.com/ansible/latest/collections/community/postgresql/)
- [Patroni documentation](https://patroni.readthedocs.io/)
- [CloudNativePG](https://cloudnative-pg.io/)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
