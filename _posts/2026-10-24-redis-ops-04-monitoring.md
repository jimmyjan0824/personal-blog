---
title: Redis 運維 04：監控與告警
date: 2026-10-24 11:30:00 +0800
categories: [Redis, 監控告警]
tags: [redis, redis7, redis8, dba, monitoring, prometheus, grafana, slowlog, latency]
description: 以 Redis 7.4 為主，整理 INFO 的核心指標、告警閾值、Prometheus + redis_exporter + Grafana、慢查詢與延遲監控、大 key 與熱 key 分析，並比較 8.x 新增的監控能力。
---

Redis 的問題通常來得很快：記憶體滿了開始淘汰或拒絕寫入、一個大 key 讓延遲飆高、全量同步迴圈把網路塞爆。監控的目標是在使用者感受到之前就發現。本篇以 Redis 7.4 為主，最後比較 8.x。

{% include redis-ops-series.md %}

## 指標從哪裡來

| 來源 | 內容 |
| :--- | :--- |
| `INFO [section]` | 幾乎所有指標：`server`、`clients`、`memory`、`persistence`、`stats`、`replication`、`cpu`、`latencystats`、`keyspace` |
| `SLOWLOG GET` | 執行時間超過 `slowlog-log-slower-than` 的指令 |
| `LATENCY LATEST` / `LATENCY DOCTOR` | 超過 `latency-monitor-threshold` 的延遲事件（fork、AOF fsync、過期清理等） |
| `CLIENT LIST` | 每條連線的來源、閒置時間、輸出緩衝 |
| `MEMORY STATS` / `MEMORY DOCTOR` | 記憶體分布與診斷建議 |
| `redis-cli --bigkeys` / `--memkeys` / `--hotkeys` | 掃描大 key 與熱 key |
| Sentinel：`SENTINEL MASTER` / `INFO sentinel` | 主庫狀態、從庫數、Sentinel 數 |
| Cluster：`CLUSTER INFO` | `cluster_state`、`cluster_slots_fail` |

## 核心指標

| 類別 | 指標（INFO 欄位） | 看什麼 |
| :--- | :--- | :--- |
| 可用性 | `uptime_in_seconds` | 突然歸零代表重啟過 |
| 記憶體 | `used_memory`、`maxmemory` | 使用率；快到上限就會開始淘汰或拒絕寫入 |
| | `mem_fragmentation_ratio` | `used_memory_rss / used_memory`。> 1.5 碎片多；< 1 代表被 swap 了，非常危險 |
| | `evicted_keys` | 持續增加代表記憶體不夠，快取命中率會下降 |
| 吞吐 | `instantaneous_ops_per_sec` | 每秒指令數 |
| | `keyspace_hits`、`keyspace_misses` | 命中率 = hits / (hits + misses)，快取用途通常要 > 90% |
| 連線 | `connected_clients`、`maxclients` | 接近上限時新連線會被拒絕 |
| | `rejected_connections` | 不為 0 代表已經有連線被拒絕 |
| | `blocked_clients` | 等待 `BLPOP` 等阻塞指令的連線 |
| 延遲 | `latencystats`（7.0+） | 每個指令的 p50 / p99 / p99.9 延遲 |
| | `latest_fork_usec` | 上次 fork 花的時間，大資料集可能超過 100 ms |
| 持久化 | `rdb_last_bgsave_status`、`aof_last_write_status` | 不是 `ok` 就要立刻處理（通常是磁碟滿或權限） |
| | `aof_rewrite_in_progress`、`rdb_bgsave_in_progress` | 同時發生時 IO 會很重 |
| 複製 | `master_link_status` | 從庫上看，`down` 代表和主庫斷線 |
| | `master_repl_offset` 差值 | 主庫 offset - 從庫 offset = 複製延遲（bytes） |
| | `sync_full`、`sync_partial_err` | 全量同步次數，持續增加代表 backlog 太小或緩衝被切斷 |

## 告警閾值建議

| 告警 | 條件 | 等級 |
| :--- | :--- | :--- |
| Redis 掛掉 | 連不上 / `redis_up == 0` 持續 1 分鐘 | Critical |
| 記憶體使用率 | `used_memory / maxmemory > 90%` 持續 5 分鐘 | Warning（快取）/ Critical（noeviction） |
| 淘汰 | `rate(evicted_keys) > 0` 持續 10 分鐘（`noeviction` 的實例則看寫入錯誤） | Warning |
| 碎片 | `mem_fragmentation_ratio > 1.5` 且 `used_memory_rss > 1GB` | Warning |
| 連線數 | `connected_clients / maxclients > 80%` | Warning |
| 拒絕連線 | `rate(rejected_connections) > 0` | Critical |
| 持久化失敗 | `rdb_last_bgsave_status != ok` 或 `aof_last_write_status != ok` | Critical |
| 從庫斷線 | `master_link_status == down` 持續 1 分鐘 | Critical |
| 從庫數 | 主庫的 `connected_slaves` 少於預期 | Warning |
| 全量同步 | `rate(sync_full) > 0`（非計畫內） | Warning |
| 命中率 | 快取命中率 < 80% 持續 30 分鐘 | Warning |
| Cluster | `cluster_state != ok` | Critical |
| Sentinel | `+switch-master` 事件（發生過切換） | Info，事後檢查原因 |

## Prometheus + redis_exporter + Grafana

最常見的組合是 [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter)：

```bash
# 每台 Redis 主機上跑一個 exporter（也可以一個 exporter 抓多台）
redis_exporter \
  --redis.addr=redis://127.0.0.1:6379 \
  --redis.password-file=/etc/redis_exporter/pwd.json \
  --web.listen-address=:9121
```

監控帳號用 ACL 建立最小權限的使用者（見[安全篇]({% post_url 2026-10-24-redis-ops-07-security %})），不要用 `default` 帳號。

幾條 Prometheus 告警規則：

```yaml
groups:
- name: redis
  rules:
  - alert: RedisDown
    expr: redis_up == 0
    for: 1m
    labels: { severity: critical }
  - alert: RedisMemoryHigh
    expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9 and redis_memory_max_bytes > 0
    for: 5m
    labels: { severity: warning }
  - alert: RedisRejectedConnections
    expr: increase(redis_rejected_connections_total[5m]) > 0
    labels: { severity: critical }
  - alert: RedisReplicaLinkDown
    expr: redis_master_link_up == 0
    for: 1m
    labels: { severity: critical }
  - alert: RedisRdbSaveFailed
    expr: redis_rdb_last_bgsave_status == 0
    labels: { severity: critical }
```

Grafana 可以直接匯入社群的 Redis Dashboard（ID 763 或 11835），再依自己的告警項目調整。

## 慢查詢與延遲監控

```bash
redis-cli CONFIG SET slowlog-log-slower-than 10000   # 10 ms（微秒）
redis-cli SLOWLOG GET 10                             # 最近 10 筆
redis-cli SLOWLOG RESET

redis-cli CONFIG SET latency-monitor-threshold 100   # 100 ms
redis-cli LATENCY LATEST                             # 各事件最近一次與最大延遲
redis-cli LATENCY DOCTOR                             # 文字版診斷
```

- Slowlog 只計算**指令執行時間**，不含網路與排隊。用戶端看到慢但 slowlog 是空的，通常是網路、連線池或 Redis 主執行緒被其他指令卡住。
- `redis-cli --latency -h <主機>` 可以從用戶端角度量測往返延遲；`--latency-history` 每 15 秒輸出一次。
- `redis-cli --intrinsic-latency 30`（在 Redis 主機上執行）量測主機本身的延遲，虛擬機或容器被 CPU 搶占時很明顯。

## 大 key 與熱 key

```bash
redis-cli --bigkeys -i 0.01      # 每 100 個 SCAN 休息 10 ms，避免影響線上
redis-cli --memkeys -i 0.01      # 依實際記憶體用量排序
redis-cli --hotkeys              # 需要 maxmemory-policy 是 LFU（allkeys-lfu / volatile-lfu）
redis-cli MEMORY USAGE user:1001 SAMPLES 0
```

大 key 的判斷標準（團隊可自訂）：String > 1 MB、集合類元素 > 5,000 或總大小 > 10 MB。處理方式見[效能調校]({% post_url 2026-10-24-redis-ops-05-performance-tuning %})。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| key 大小分布 | 要用 `--bigkeys` 掃描 | 8.0 新增 `INFO keysizes`，直接看各型別 key 大小的分布（不用掃描） |
| I/O 執行緒 | 無對應區段 | 8.0 新增 `INFO threads`，看每個 I/O 執行緒的負載 |
| 每個 slot 的用量 | 無 | 8.2～8.4 加入 `CLUSTER SLOT-STATS`（key 數、CPU 時間、網路 I/O），8.6 起由 `cluster-slot-stats-enabled` 控制要收集哪些 |
| 熱 key | `--hotkeys`（要 LFU 策略） | 8.6 新增 `HOTKEYS` 指令偵測與回報熱 key |
| 記憶體分布 | `MEMORY STATS` | 8.6 新增 `key-memory-histograms`，按資料型別收集記憶體分布直方圖 |
| Slowlog | 每筆最多記 32 個參數、每個參數最多 128 字元（寫死） | 8.8 起可用 `slowlog-entry-max-argc`、`slowlog-entry-max-string-len` 調整；8.10 回傳原始參數總數 |
| redis-cli | `--latency` 只有平均值 | 8.10 新增 `--latency-percentiles`，可指定 p50 / p99 等 |

### 給監控系統的升級建議

- 升級後 redis_exporter 要一起升級，才能收集 8.x 新增的 `keysizes`、`threads` 指標。
- 8.x 的 `INFO keysizes` 可以取代定期跑 `--bigkeys` 的排程，減少對線上的掃描壓力。
- Cluster 升到 8.4 以上後，可用 `CLUSTER SLOT-STATS` 找出熱點 slot，作為重新分配 slot 的依據。

## 小結

- 最重要的告警：Redis 掛掉、記憶體使用率、持久化失敗、從庫斷線、拒絕連線。
- `mem_fragmentation_ratio < 1` 代表被 swap，比碎片高更危險。
- 開啟 `latency-monitor-threshold`，`LATENCY DOCTOR` 才有資料。
- 大 key 用 `--bigkeys` / `--memkeys` 定期掃描，8.x 可改看 `INFO keysizes`。

下一篇：[效能調校]({% post_url 2026-10-24-redis-ops-05-performance-tuning %})。

### 參考資料

- [Redis INFO command](https://redis.io/docs/latest/commands/info/)
- [Diagnosing latency issues](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/)
- [Redis latency monitoring](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency-monitor/)
- [oliver006/redis_exporter](https://github.com/oliver006/redis_exporter)
