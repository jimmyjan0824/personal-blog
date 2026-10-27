---
title: PostgreSQL 運維 02：備份與還原
date: 2026-10-24 13:10:00 +0800
categories: [PostgreSQL, 備份還原]
tags: [postgresql, postgresql17, postgresql18, dba, backup, pg_dump, pg_basebackup, pitr, pgbackrest, wal]
description: 以 PostgreSQL 17 為主，整理 pg_dump 邏輯備份、pg_basebackup 物理備份、17 新增的增量備份、WAL 歸檔與 PITR、pgBackRest，以及還原演練，並比較 18 的差異。
---

備份是資料庫最後一道防線：高可用擋得住主機故障，擋不住 `DELETE` 少了 `WHERE`，因為誤刪會立刻複製到所有從庫。本篇以 PostgreSQL 17 為主，最後比較 18 的差異。

{% include postgresql-ops-series.md %}

## 備份的分類

| 類型 | 工具 | 優點 | 缺點 |
| :--- | :--- | :--- | :--- |
| 邏輯備份 | `pg_dump`、`pg_dumpall` | 可跨大版本、跨平台，可只還原單一資料表 | 大資料庫備份與還原都慢，只能還原到備份當下 |
| 物理備份 | `pg_basebackup`、pgBackRest、WAL-G、Barman | 快，可搭配 WAL 做 PITR | 只能還原整個叢集，必須同大版本、同架構 |
| 持續 WAL 歸檔 | `archive_command`、`pg_receivewal` | 搭配物理備份做時間點還原（PITR） | 要監控歸檔是否失敗 |

正式環境的標準組合是：**物理全量備份 + 持續 WAL 歸檔**，再加上定期的邏輯備份當作第二道保險。

## 邏輯備份：pg_dump

```bash
# custom 格式（-Fc）：壓縮、可用 pg_restore 挑選物件、可平行還原
pg_dump -h 127.0.0.1 -U postgres -Fc -Z zstd:3 -f appdb_$(date +%F).dump appdb

# directory 格式（-Fd）：可以平行備份（-j），大資料庫用這個
pg_dump -h 127.0.0.1 -U postgres -Fd -j 4 -f appdb_$(date +%F).dir appdb

# 叢集層級的物件（角色、tablespace）不在 pg_dump 裡，要另外用 pg_dumpall
pg_dumpall -h 127.0.0.1 -U postgres --globals-only > globals_$(date +%F).sql
```

還原：

```bash
createdb -O app appdb_restore
pg_restore -h 127.0.0.1 -U postgres -d appdb_restore -j 4 --no-owner appdb_2026-10-24.dump

# 只還原一張表
pg_restore -d appdb_restore -t orders appdb_2026-10-24.dump
```

- `pg_dump` 在一個 `REPEATABLE READ` 快照裡完成，**備份期間不鎖寫入**，但會持有長交易，讓 vacuum 無法清理備份開始後產生的死 tuple，大資料庫要排在離峰時段。
- `-Z zstd:3` 需要 16 以上的 `pg_dump`；舊版本用 `-Z 6`（gzip）。
- 跨大版本遷移時，**用新版本的 `pg_dump`** 去備份舊版本的資料庫。

## 物理備份：pg_basebackup

```bash
# 以 tar 格式備份整個叢集，WAL 一起串流進來（-X stream），備份本身就能還原
/usr/pgsql-17/bin/pg_basebackup -h 127.0.0.1 -U replicator -D /backup/base_$(date +%F) -Ft -z -X stream -c fast -P

# 驗證備份（13+，依 backup_manifest 檢查每個檔案的 checksum）
/usr/pgsql-17/bin/pg_verifybackup /backup/base_2026-10-24     # 17 只支援 plain 格式；tar 格式要先解開
```

- `-c fast`：立刻觸發 checkpoint，不用等下一次排程的 checkpoint。
- 用 replication 角色連線，`pg_hba.conf` 要允許 `replication` 資料庫，這和 [Streaming Replication]({% post_url 2026-10-24-postgresql-lab-02-streaming-replication %}) 建立從庫用的是同一套機制。

### 17 新增：增量備份

17 之前，`pg_basebackup` 每次都是全量。17 加上了**原生增量備份**：

```ini
# postgresql.conf：讓 walsummarizer 行程記錄每段 WAL 改了哪些區塊
summarize_wal = on
```

```bash
# 週日全量
/usr/pgsql-17/bin/pg_basebackup -D /backup/full -c fast
# 週一起增量：指定上一份備份的 backup_manifest
/usr/pgsql-17/bin/pg_basebackup -D /backup/incr1 --incremental=/backup/full/backup_manifest -c fast
/usr/pgsql-17/bin/pg_basebackup -D /backup/incr2 --incremental=/backup/incr1/backup_manifest -c fast

# 還原前用 pg_combinebackup 把全量 + 增量合成一份完整的備份
/usr/pgsql-17/bin/pg_combinebackup /backup/full /backup/incr1 /backup/incr2 -o /restore/data
```

適合「資料量大、每天只改一小部分」的資料庫。不過 `pg_combinebackup` 只能處理 plain 格式的備份，也沒有內建的保留與排程管理，**大型正式環境多半還是用 pgBackRest**。

## WAL 歸檔與 PITR

PITR（Point-In-Time Recovery）＝全量物理備份 + 之後所有的 WAL，可以還原到任意時間點（例如誤刪前一秒）。

```ini
# postgresql.conf（改 archive_mode 要重啟）
archive_mode = on
archive_command = 'test ! -f /pgarchive/%f && cp %p /pgarchive/%f'
# 寫入很少時，最多 5 分鐘強制切換一次 WAL 檔，限制 RPO
archive_timeout = 5min
```

- `archive_command` **必須在檔案已存在時回傳非 0**（上面的 `test ! -f`），否則可能覆蓋掉好的歸檔。
- 指令失敗時 PostgreSQL 會一直重試，WAL 留在 `pg_wal` 不會刪除，**歸檔壞掉最後會塞滿磁碟**，一定要監控 `pg_stat_archiver.failed_count`。
- 實際環境不要只 `cp` 到本機，要送到另一台主機或物件儲存（S3、GCS），這正是 pgBackRest、WAL-G 做的事。

### 還原到指定時間點

```bash
# 1. 停止服務，把壞掉的資料目錄移走
sudo systemctl stop postgresql-17
sudo mv /var/lib/pgsql/17/data /var/lib/pgsql/17/data.broken

# 2. 放回全量備份
sudo -u postgres mkdir -m 700 /var/lib/pgsql/17/data
sudo -u postgres tar xzf /backup/base_2026-10-24/base.tar.gz -C /var/lib/pgsql/17/data

# 3. 設定還原目標（寫在 postgresql.conf 或 postgresql.auto.conf）
cat <<'CONF' | sudo -u postgres tee -a /var/lib/pgsql/17/data/postgresql.auto.conf
restore_command = 'cp /pgarchive/%f %p'
recovery_target_time = '2026-10-24 14:29:59+08'
recovery_target_action = 'pause'
CONF

# 4. 建立 recovery.signal 後啟動
sudo -u postgres touch /var/lib/pgsql/17/data/recovery.signal
sudo systemctl start postgresql-17
```

`recovery_target_action = 'pause'` 會停在目標時間點讓你檢查資料，確認無誤後執行 `SELECT pg_wal_replay_resume();` 結束還原、開始接受寫入；不對的話可以改目標時間重來。

> 12 起已經沒有 `recovery.conf`，改用 `recovery.signal`（PITR）或 `standby.signal`（從庫）加上 `postgresql.conf` 裡的參數。網路上很多舊教學還是 `recovery.conf`，在 17 上照做會啟動失敗。
{: .prompt-warning }

## pgBackRest：正式環境的首選

| 功能 | pg_basebackup | pgBackRest |
| :--- | :--- | :--- |
| 全量 / 差異 / 增量 | 全量；17+ 有增量 | 全部支援，區塊層級增量 |
| 平行備份與還原 | 無 | 有 |
| 壓縮、加密 | 壓縮 | 壓縮 + 加密 |
| 送到 S3 / GCS / Azure | 無 | 內建 |
| 保留策略 | 自己寫 | `repo1-retention-full=2` |
| WAL 歸檔 | 要另外設 | `archive_command = 'pgbackrest --stanza=main archive-push %p'`，非同步、平行 |
| 從從庫備份 | 可以 | 可以（`backup-standby=y`），減輕主庫負擔 |

```bash
pgbackrest --stanza=main --type=full backup
pgbackrest --stanza=main --type=incr backup
pgbackrest --stanza=main info
pgbackrest --stanza=main --type=time "--target=2026-10-24 14:29:59+08" restore
```

其他選擇：**WAL-G**（輕量、雲端物件儲存為主）、**Barman**（集中式備份伺服器，管理多個叢集）。

## 備份策略與還原演練

| 項目 | 建議 |
| :--- | :--- |
| 全量 | 每週 1 次 |
| 增量 / 差異 | 每天 1 次 |
| WAL 歸檔 | 持續，`archive_timeout` 5 分鐘 |
| 邏輯備份 | 每天或每週，重要資料表另外保留 |
| 保留 | 至少 2 份全量 + 期間所有 WAL；法規要求另計 |
| 異地 | 至少一份在另一個機房或雲端（3-2-1 原則） |
| 還原演練 | **每月**還原到測試機，量測實際還原時間（RTO） |

沒有演練過的備份不算備份。演練要驗證：

1. 還原流程文件化，照著做能完成。
2. 還原後 `amcheck`（`pg_amcheck -d appdb`）檢查索引與資料表沒有損毀。
3. 應用程式的關鍵查詢可以執行，資料筆數和預期相符。
4. 實際花了多久，是否符合 RTO。

## 版本差異比較：17 vs 18

| 項目 | 17 | 18 |
| :--- | :--- | :--- |
| 增量備份 | 新增 `pg_basebackup --incremental`、`pg_combinebackup`、`summarize_wal` | 沿用；`pg_combinebackup` 新增 `--link`（用 hard link 加快合併） |
| `pg_verifybackup` | 只能驗 plain 格式 | 可以直接驗 tar 格式 |
| `pg_dump` / `pg_upgrade` 與統計資訊 | 不包含統計資訊，還原或升級後要 `ANALYZE` | 可以匯出 / 保留最佳化器統計資訊，還原後查詢計畫更快恢復正常 |
| data checksums | 預設不開 | 預設開，物理備份與 `pg_amcheck` 更容易發現損毀 |
| 還原相容性 | 物理備份只能還原到 17 | 物理備份只能還原到 18（跨大版本一律用邏輯備份或 `pg_upgrade`） |

### 給備份策略的升級建議

- 升級到 18 前後各做一次全量備份，舊版本的物理備份**無法**還原到新版本。
- 若已經用 17 的增量備份，升級後要重新做一份 18 的全量，增量鏈不能跨版本。
- pgBackRest 等工具要先確認支援 18 的版本。

## 小結

- 物理備份 + WAL 歸檔才能做 PITR，邏輯備份是第二道保險。
- 17 有原生增量備份，正式環境仍建議 pgBackRest。
- 監控歸檔失敗，否則 `pg_wal` 會塞滿磁碟。
- 每月還原演練，驗證 RTO。

下一篇：[高可用與災難復原]({% post_url 2026-10-24-postgresql-ops-03-ha-dr %})。

### 參考資料

- [PostgreSQL 17 文件：Backup and Restore](https://www.postgresql.org/docs/17/backup.html)
- [PostgreSQL 17 文件：pg_basebackup](https://www.postgresql.org/docs/17/app-pgbasebackup.html)
- [PostgreSQL 17 文件：pg_combinebackup](https://www.postgresql.org/docs/17/app-pgcombinebackup.html)
- [pgBackRest User Guide](https://pgbackrest.org/user-guide-rhel.html)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)
