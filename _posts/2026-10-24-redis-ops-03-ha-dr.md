---
title: Redis 運維 03：高可用與災難復原
date: 2026-10-24 11:20:00 +0800
categories: [Redis, 高可用]
tags: [redis, redis7, redis8, dba, replication, sentinel, cluster, ha, dr]
description: 以 Redis 7.4 為主，整理主從複製原理、Sentinel 與 Cluster 的故障切換機制、腦裂與資料遺失、WAIT / WAITAOF、跨機房與 RPO / RTO 規劃，並比較 8.x 的差異。
---

Redis 的高可用建立在**非同步複製**上，這代表任何切換都可能遺失少量資料。本篇先講清楚複製與切換的原理，再談怎麼把資料遺失與停機時間控制在可以接受的範圍。實際的部署與切換測試請看 [Sentinel 實作]({% post_url 2026-10-24-redis-lab-02-sentinel %})與 [Cluster 實作]({% post_url 2026-10-24-redis-lab-03-cluster %})。

{% include redis-ops-series.md %}

## 先定義 RPO 與 RTO

| 架構 | RPO（可能遺失的資料） | RTO（停機時間） |
| :--- | :--- | :--- |
| Standalone + RDB | 上次快照之後全部（最多約 1 小時） | 重啟 + 載入時間，主機壞了就要重建 |
| Standalone + AOF everysec | 約 1 秒 | 同上 |
| Sentinel（1 主 2 從） | 複製延遲內的寫入（通常 < 1 秒） | `down-after-milliseconds` + 選舉，約 5～15 秒 |
| Cluster（每主 1 從） | 同上 | `cluster-node-timeout` + 選舉，約 5～15 秒 |

## 主從複製原理

```text
從庫連上主庫 ── PSYNC <replid> <offset>
                    │
     ┌──────────────┴──────────────┐
     │ replid 相同且 offset 還在     │ 否則
     │ backlog 範圍內                │
     ▼                              ▼
  部分同步（+CONTINUE）           全量同步（+FULLRESYNC）
  只補傳缺少的指令                主庫 fork 產生 RDB 傳給從庫，從庫清空後載入
```

- **Replication ID + offset**：每個主庫有一組 replid，從庫記住自己同步到哪個 offset。切換後新主庫會保留舊的 replid 作為 `master_replid2`，所以其他從庫切換到新主庫時仍可以部分同步。
- **repl-backlog-size**：主庫保留最近寫入指令的環狀緩衝區。從庫斷線期間的寫入量超過它，就只能全量同步。預設 1 MB 太小，建議至少 256 MB。
- **全量同步很貴**：主庫要 fork，大資料集時 fork 本身就可能卡住數百毫秒；從庫載入期間無法服務。`repl-diskless-sync yes`（7.x 預設）讓 RDB 直接經網路傳送，不落主庫磁碟。
- **client-output-buffer-limit replica**：全量同步期間主庫的新寫入會暫存在這個緩衝區，超過上限連線就被切斷，從庫重新全量同步，形成無限迴圈。資料量大、寫入多時要調大。

## Sentinel

Sentinel 是獨立的行程，負責監控、通知與自動切換：

1. 每個 Sentinel 每秒 PING 主庫，超過 `down-after-milliseconds` 沒回應，判定**主觀下線（SDOWN）**。
2. 詢問其他 Sentinel，達到 `quorum` 個同意，判定**客觀下線（ODOWN）**。
3. Sentinel 之間用 Raft 類似的方式選出 leader，**需要過半數 Sentinel 同意**（3 台中的 2 台），所以 Sentinel 至少要 3 台、分散在不同主機。
4. Leader 依 `replica-priority`（越小越優先，0 不參選）→ 複製 offset（越新越優先）→ run ID 挑一台從庫升為主庫，並讓其他從庫改跟新主庫。
5. 舊主庫恢復後，Sentinel 會把它設成新主庫的從庫。

用戶端不能寫死主庫 IP，而是要問 Sentinel：`SENTINEL get-master-addr-by-name mymaster`。主流的用戶端函式庫（Jedis、Lettuce、redis-py、go-redis）都內建支援。

## Cluster

Cluster 不需要 Sentinel，節點之間透過 Cluster Bus（`port + 10000`）用 gossip 交換狀態：

1. 節點超過 `cluster-node-timeout` 沒回應，被標為 **PFAIL**。
2. 過半數主庫都認為它 PFAIL，升級為 **FAIL** 並廣播。
3. 該主庫的從庫發起選舉，取得過半數**主庫**的票就升為主庫，接手 slot。
4. 從庫和主庫斷線太久（超過 `cluster-node-timeout × cluster-replica-validity-factor`）就不參選，避免資料太舊的從庫被選上。

因為投票的是主庫，**Cluster 至少要 3 個主庫**；而且同一組主從不能放在同一台實體機上，否則一台機器壞掉就會遺失整段 slot。

## 腦裂與資料遺失

非同步複製加上自動切換，會出現這種情境：

```text
主庫 A 和其他節點網路斷開，但用戶端仍然連得到 A
 → Sentinel 把從庫 B 升為新主庫
 → 用戶端在這段時間繼續寫入 A
 → 網路恢復，A 被降為 B 的從庫，A 上的寫入全部被覆蓋
```

緩解方式：

```ini
# 主庫至少要有 1 台從庫，且延遲 ≤ 10 秒，才接受寫入
min-replicas-to-write 1
min-replicas-max-lag 10
```

A 和所有從庫斷開超過 10 秒就會拒絕寫入（`NOREPLICAS`），把遺失的時間窗口限制在 10 秒內。代價是從庫全部掛掉時，主庫也不能寫。Cluster 則是透過 `cluster-node-timeout`：被隔離的主庫超過 timeout 就自己停止接受寫入。

## WAIT 與 WAITAOF

對特別重要的寫入，可以在應用程式裡等待複製確認：

```text
SET order:1001 paid
WAIT 1 100        # 等至少 1 台從庫收到，最多 100 ms，回傳實際確認的從庫數
WAITAOF 1 1 100   # 7.2 新增：等本機與至少 1 台從庫都把寫入 fsync 到 AOF
```

`WAIT` 不會讓 Redis 變成強一致（切換時仍可能挑到沒收到的從庫），但能大幅降低遺失的機率。

## 跨機房與災難復原

- **同城雙機房**：Sentinel 放 3 個機房（或 2 + 1 仲裁點），避免一個機房斷線就無法達到過半數。
- **異地備援**：在 DR 機房放一台 `replica-priority 0` 的從庫，平時不會被選為主庫，災難時手動 `REPLICAOF NO ONE` 提升。
- **Cluster 跨機房**：主從分散在不同機房，但 Cluster Bus 對延遲很敏感，跨城市（RTT > 10 ms）不建議組同一個叢集。
- **備份是最後一道防線**：誤刪（`FLUSHALL`、錯誤的批次刪除）會立刻複製到所有從庫，HA 救不了，只能靠[備份]({% post_url 2026-10-24-redis-ops-02-backup-restore %})。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| 全量同步機制 | 主庫在 fork 期間把增量寫入暫存在 `client-output-buffer-limit replica` | 8.0 改用新的複製機制：全量同步時 RDB 與增量串流平行傳送，增量資料改由從庫端暫存，主庫的緩衝壓力變小；新增 `replica-full-sync-buffer-limit`（從庫端暫存上限，`0` 表示跟隨 replica 緩衝設定） |
| 複製串流壓縮 | 無 | 8.10 新增 `repl-compression`（zstd，等級 0～22），要用 `BUILD_COMPRESSION=yes` 編譯且 `io-threads > 1` 才有效，適合跨機房省頻寬 |
| Cluster slot 搬遷 | `MIGRATE` 逐 key 搬，搬大 key 會阻塞 | 8.4 新增 `CLUSTER MIGRATION` 原子 slot 搬遷，`redis-cli --cluster reshard / rebalance` 在 8.10 起也改用它 |
| Cluster 安全 | Cluster Bus 沒有驗證 | 8.10.2 起，未開 `tls-cluster` 時節點啟動會警告；`cluster-bus-port-protected-mode yes` 可強制要求 TLS |
| 切換後的相容性 | — | 主從要同版本。混用時**只能舊版當主、新版當從**（新版的 RDB 舊版讀不了） |

### 給 HA 架構的升級建議

- 升級順序：先升從庫 → 計畫內切換（`SENTINEL FAILOVER` 或 `CLUSTER FAILOVER`）→ 再升舊主庫。
- 8.0 新的複製機制在大資料集、高寫入量時改善最明顯，常因全量同步迴圈頭痛的環境值得優先升級。
- 8.4 的原子 slot 搬遷讓 Cluster 擴縮容不再需要逐 key 搬遷，大 key 多的叢集升級收益很大。

## 小結

- Redis 複製是非同步的，切換一定有遺失資料的可能，用 `min-replicas-to-write` 和 `WAIT` 縮小窗口。
- `repl-backlog-size` 與 `client-output-buffer-limit replica` 決定了會不會陷入全量同步迴圈。
- Sentinel 至少 3 台；Cluster 至少 3 主，主從不能在同一台機器。
- HA 救不了誤刪，備份還是必要。

下一篇：[監控與告警]({% post_url 2026-10-24-redis-ops-04-monitoring %})。

### 參考資料

- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [High availability with Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Redis cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/)
- [Redis 8.0 release notes](https://github.com/redis/redis/blob/8.0/00-RELEASENOTES)
