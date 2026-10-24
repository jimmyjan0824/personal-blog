---
title: Redis 運維 09：故障排查與事件處理
date: 2026-10-24 12:20:00 +0800
categories: [Redis, 故障排查]
tags: [redis, redis7, redis8, dba, troubleshooting, runbook, oom, latency, replication]
description: 以 Redis 7.4 為主，整理常見故障的現象、原因與處理步驟：記憶體滿與 OOM、延遲飆高、fork 失敗與 MISCONF、連線數爆滿、全量同步迴圈、Cluster 與 Sentinel 的錯誤、AOF 損毀，以及事後檢討，並比較 8.x 的改進。
---

Redis 出事通常很突然，而且影響範圍很大（所有依賴快取的服務一起變慢）。本篇以 Redis 7.4 為主，把常見的故障整理成 Runbook 格式：**現象 → 確認 → 處理 → 根治**，最後比較 8.x。

{% include redis-ops-series.md %}

## 第一步：快速判斷

```bash
redis-cli -h <主機> PING                                   # 活著嗎
redis-cli INFO server | grep -E "uptime_in_seconds|redis_version"
redis-cli INFO memory | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"
redis-cli INFO clients | grep -E "connected_clients|blocked_clients"
redis-cli INFO stats | grep -E "instantaneous_ops_per_sec|evicted_keys|rejected_connections"
redis-cli INFO persistence | grep -E "status|in_progress"
redis-cli INFO replication
redis-cli SLOWLOG GET 5
redis-cli LATENCY LATEST
tail -100 /var/log/redis/redis.log
```

## 記憶體滿

**現象**：寫入回 `OOM command not allowed when used memory > 'maxmemory'`（`noeviction`），或延遲上升、命中率下降（有淘汰策略）。

**確認**：`used_memory` 接近 `maxmemory`；`evicted_keys` 持續增加。

**處理**：

```bash
redis-cli --memkeys -i 0.01 | tail -20            # 找出佔用最多的 key
redis-cli INFO keyspace                           # keys 與 expires 的比例：大量 key 沒設 TTL？
redis-cli CONFIG SET maxmemory <更大的值>          # 主機還有餘裕時暫時放大
```

**根治**：所有快取 key 都要設 TTL；拆大 key；擴容（見[容量規劃]({% post_url 2026-10-24-redis-ops-06-capacity-scaling %})）。

## 被 OOM Killer 殺掉

**現象**：Redis 行程突然消失，`uptime_in_seconds` 歸零；`dmesg` 有 `Out of memory: Killed process ... (redis-server)`。

**原因**：沒設 `maxmemory`，或 `maxmemory` 設太大，加上 fork 的 copy-on-write、用戶端輸出緩衝把實體記憶體用光。

**根治**：`maxmemory` 抓實體記憶體的 60%～65%；設定 `client-output-buffer-limit` 防止單一用戶端吃光記憶體（例如 `MONITOR` 或訂閱者消化太慢）。

## 延遲飆高

| 可能原因 | 怎麼確認 | 處理 |
| :--- | :--- | :--- |
| 慢指令 / 大 key | `SLOWLOG GET`；`INFO commandstats` | 找出來源程式，改用 `SCAN`、拆 key、`UNLINK` |
| fork | `INFO stats` 的 `latest_fork_usec`；`LATENCY LATEST` 有 `fork` 事件 | 減少單一實例資料量；在從庫做 BGSAVE |
| AOF fsync 慢 | `LATENCY LATEST` 有 `aof-fsync-always` / `aof-write-pending-fsync`；磁碟 `iostat` 忙碌 | 換更快的磁碟；把其他高 IO 服務移開 |
| Swap | `mem_fragmentation_ratio < 1`；`cat /proc/$(pidof redis-server)/smaps \| grep Swap` | 加記憶體、降 `maxmemory`、`vm.swappiness = 1` |
| 過期 key 大量同時過期 | `LATENCY LATEST` 有 `expire-cycle` | TTL 加隨機值打散 |
| 主機被搶 CPU | `redis-cli --intrinsic-latency 30` 數值偏高 | 換專屬主機或調整 VM 配置 |
| 網路 | 用戶端慢但 slowlog 乾淨；`redis-cli --latency` 偏高 | 檢查網路、連線池大小、Pipeline |

**緊急處理**：找到正在執行的慢指令來源：`CLIENT LIST` 看 `cmd` 與 `age`，必要時 `CLIENT KILL ID <id>`。Lua 腳本卡住時，用 `SCRIPT KILL`（腳本還沒寫入資料時才有效），否則只能 `SHUTDOWN NOSAVE`。

## fork 失敗 / MISCONF

**現象**：寫入回 `MISCONF Redis is configured to save RDB snapshots, but it's currently unable to persist to disk`。

**確認**：

```bash
grep -E "Can't save in background|Background saving error|Failed opening" /var/log/redis/redis.log | tail
df -h /var/lib/redis
cat /proc/sys/vm/overcommit_memory
```

| 日誌 | 原因 | 處理 |
| :--- | :--- | :--- |
| `fork: Cannot allocate memory` | `vm.overcommit_memory = 0` | `sysctl -w vm.overcommit_memory=1` 並寫入 `/etc/sysctl.d/` |
| `No space left on device` | 磁碟滿 | 清理空間（舊的 RDB、AOF 備份、日誌） |
| `Permission denied` | `dir` 目錄權限錯誤 | `chown redis:redis` |

處理完後執行一次 `BGSAVE` 確認成功，寫入就會恢復。**不要用 `CONFIG SET stop-writes-on-bgsave-error no` 掩蓋問題**。

## 連線數爆滿

**現象**：新連線回 `ERR max number of clients reached`；`rejected_connections` 增加。

**處理**：

```bash
redis-cli CLIENT LIST | awk '{print $2}' | cut -d= -f2 | cut -d: -f1 | sort | uniq -c | sort -rn | head   # 依來源 IP 統計
redis-cli CLIENT LIST | grep -E "idle=[0-9]{4,}" | head                                              # 閒置很久的連線
redis-cli CONFIG SET timeout 300                                                                     # 暫時讓閒置連線被回收
```

**根治**：修正應用程式的連線洩漏、限制連線池大小；`maxclients` 不是越大越好。

## 全量同步迴圈

**現象**：從庫一直 `MASTER <-> REPLICA sync started`，主庫日誌出現 `scheduled to be closed ASAP for overcoming of output buffer limits`；網路與主庫 CPU 持續偏高。

**原因**：全量同步期間主庫的新寫入超過 `client-output-buffer-limit replica`，連線被切斷，重新全量同步，無限循環。

**處理**：

```bash
redis-cli CONFIG SET client-output-buffer-limit "replica 1gb 512mb 120"
redis-cli CONFIG SET repl-backlog-size 512mb
redis-cli CONFIG REWRITE
```

## AOF 損毀

**現象**：啟動失敗，日誌出現 `Bad file format reading the append only file` 或 `Unexpected end of file`。

**處理**：

```bash
cp -a /var/lib/redis/appendonlydir /root/aof-broken-$(date +%F)    # 先備份
redis-check-aof /var/lib/redis/appendonlydir/appendonly.aof.manifest
redis-check-aof --fix /var/lib/redis/appendonlydir/appendonly.aof.manifest   # 截掉損毀之後的內容
```

`aof-load-truncated yes`（預設）時，只有「尾端不完整」會自動處理；中間損毀一定要手動修。

## Cluster 常見錯誤

| 錯誤 | 原因 | 處理 |
| :--- | :--- | :--- |
| `CLUSTERDOWN The cluster is down` | 有 slot 沒有可用的節點（主從都掛） | 恢復節點；或暫時 `cluster-require-full-coverage no` 讓其他 slot 服務 |
| `CROSSSLOT Keys in request don't hash to the same slot` | 多 key 指令的 key 在不同 slot | 用 hash tag |
| `MOVED` / `ASK` | 用戶端沒開 Cluster 模式 | `redis-cli -c`；應用程式用 Cluster 用戶端 |
| `--cluster check` 顯示 slot open | reshard 中斷 | `redis-cli --cluster fix` |
| 從庫一直不升級 | 從庫資料太舊（超過 validity factor）或 `cluster-replica-no-failover yes` | 檢查日誌的 `Currently unable to failover` 原因；必要時 `CLUSTER FAILOVER FORCE` / `TAKEOVER` |

## Sentinel 常見問題

| 現象 | 原因 | 處理 |
| :--- | :--- | :--- |
| 主庫掛了但沒有切換 | 可用的 Sentinel 不到 quorum 或過半數 | 確認 3 台 Sentinel 都活著；`SENTINEL CKQUORUM mymaster` |
| `-failover-abort-no-good-slave` | 沒有合適的從庫（全部斷線或 priority 0） | 檢查從庫狀態與 `replica-priority` |
| 切換後舊主庫一直起不來當從庫 | 沒設 `masterauth` | 所有節點都要設 `masterauth` |
| 切換後設定又被改回 | 設定檔不可寫、`CONFIG REWRITE` 失敗 | 讓 redis 使用者對設定檔與目錄有寫入權限 |
| Sentinel 看到的從庫越來越多 | 從庫 IP 變動（容器、DHCP） | `SENTINEL RESET mymaster` |

## 事後檢討（Post-mortem）

每次事件結束後都要寫，重點不是追究責任，而是避免再發生：

```text
1. 摘要：發生什麼事、影響範圍、持續時間
2. 時間軸：第一個告警、確認、處理、恢復的時間點
3. 根本原因：用「5 個為什麼」追到流程或設計層面
4. 做得好的與做得不好的：告警是否及時？Runbook 是否有用？
5. 改進項目：每項都有負責人與期限
```

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| 全量同步迴圈 | 主庫緩衝切斷連線是最常見原因 | 8.0 新複製機制把增量暫存移到從庫端（`replica-full-sync-buffer-limit`），大幅降低主庫緩衝被撐爆的機率 |
| AOF 尾端損毀 | 只處理「不完整」的尾端 | 8.4 新增 `aof-load-corrupt-tail-max-size`，可自動修復尾端一定大小內的損毀 |
| 熱 key 排查 | `--hotkeys` 需要 LFU 策略 | 8.6 新增 `HOTKEYS` 指令 |
| 大 key 排查 | `--bigkeys` 掃描 | 8.0 `INFO keysizes` 直接看分布 |
| 搬遷卡住 | reshard 中斷要 `--cluster fix` | 8.4 原子 slot 搬遷，中斷的處理方式不同 |
| 已知問題 | — | 8.x 各版的 release notes 有「Known bugs and limitations」，升級前要先看（例如 8.6.0 的 `XADD IDMP` 與 `aof-use-rdb-preamble no` 的限制） |

### 給事件處理的升級建議

- 8.x 新增的觀測工具（`INFO keysizes`、`HOTKEYS`、`CLUSTER SLOT-STATS`）要更新到 Runbook 裡。
- 升級後的第一週提高告警敏感度，特別是延遲與記憶體，及早發現新版本的行為差異。

## 小結

- 先用一組固定的 `INFO` 指令快速判斷是記憶體、延遲、連線、持久化還是複製問題。
- `MISCONF` 最常見的原因是 `vm.overcommit_memory` 與磁碟滿，不要關掉 `stop-writes-on-bgsave-error` 了事。
- 全量同步迴圈調大 `client-output-buffer-limit replica` 與 `repl-backlog-size`。
- 每次事件都寫 Post-mortem，並更新 Runbook。

下一篇：[自動化與規範制定]({% post_url 2026-10-24-redis-ops-10-automation-standards %})。

### 參考資料

- [Diagnosing latency issues](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/)
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)
- [Redis cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/)
- [Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
