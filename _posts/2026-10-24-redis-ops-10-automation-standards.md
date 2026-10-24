---
title: Redis 運維 10：自動化與規範制定
date: 2026-10-24 12:30:00 +0800
categories: [Redis, 自動化與規範]
tags: [redis, redis7, redis8, dba, automation, ansible, standards, naming]
description: 以 Redis 7.4 為主，整理用 Ansible 自動化安裝與設定、單機多實例的 systemd 範本、每日巡檢腳本、Key 命名與 TTL 規範、指令與用戶端使用規範，並比較 8.x 對自動化的影響與系列總結。
---

前九篇的內容如果都靠人手操作，遲早會出錯：某台忘了設 `vm.overcommit_memory`、某台的 `maxmemory` 和其他台不一樣、某個應用程式在線上跑 `KEYS *`。本篇以 Redis 7.4 為主，整理怎麼把運維工作自動化，並訂出開發與運維都要遵守的規範。

{% include redis-ops-series.md %}

## 用 Ansible 自動化安裝

把[實作文]({% post_url 2026-10-24-redis-lab-01-standalone %})的步驟寫成 role，每台主機的差異（IP、角色）放在 inventory：

```text
roles/redis/
├── defaults/main.yml        # redis_version: 7.4.11、redis_maxmemory: 10gb ...
├── tasks/main.yml
├── templates/redis.conf.j2
├── templates/sentinel.conf.j2
├── templates/redis.service.j2
└── handlers/main.yml        # 設定變更時的處理（見下方說明）
```

```yaml
# roles/redis/tasks/main.yml（節錄）
- name: sysctl
  ansible.posix.sysctl:
    name: "{{ item.k }}"
    value: "{{ item.v }}"
    sysctl_file: /etc/sysctl.d/99-redis.conf
  loop:
    - { k: vm.overcommit_memory, v: "1" }
    - { k: net.core.somaxconn, v: "1024" }
    - { k: vm.swappiness, v: "1" }

- name: build dependencies
  ansible.builtin.dnf:
    name: [gcc, make, tar, gzip, systemd-devel]

- name: download source
  ansible.builtin.get_url:
    url: "https://download.redis.io/releases/redis-{{ redis_version }}.tar.gz"
    dest: "/usr/local/src/redis-{{ redis_version }}.tar.gz"
    checksum: "sha256:{{ redis_sha256 }}"

- name: build and install
  ansible.builtin.shell: |
    tar xzf redis-{{ redis_version }}.tar.gz
    cd redis-{{ redis_version }} && make -j"$(nproc)" USE_SYSTEMD=yes && make install
  args:
    chdir: /usr/local/src
    creates: "/usr/local/src/redis-{{ redis_version }}/src/redis-server"

- name: redis.conf
  ansible.builtin.template:
    src: redis.conf.j2
    dest: /etc/redis/redis.conf
    owner: redis
    group: redis
    mode: "0640"
  notify: restart redis   # 只在初次部署用；已上線的實例改走滾動重啟流程
```

注意事項：

- **設定檔範本與 `CONFIG REWRITE` 的衝突**：Sentinel 架構中 Redis 會自己改寫 `replicaof`，Ansible 再推一次範本就會把它蓋掉。做法是範本不含 `replicaof`，改用 `include` 拆檔，或 playbook 只在初次部署時推設定檔。
- **不要讓 handler 直接重啟正式環境的主庫**，重啟應該走[滾動重啟]({% post_url 2026-10-24-redis-ops-08-change-management %})流程（從庫 → 切換 → 舊主庫）。
- `redis_sha256` 要寫進 defaults，下載的原始碼先比對雜湊值，官方的雜湊值公布在 [redis-hashes](https://github.com/redis/redis-hashes)。

## 單機多實例：systemd 範本

一台主機跑多個 Redis（例如 Cluster 測試環境或多個小型快取）時，用 systemd 的範本 unit：

```ini
# /etc/systemd/system/redis@.service
[Unit]
Description=Redis 7.4 (port %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/redis-server /etc/redis/%i.conf
User=redis
Group=redis
RuntimeDirectory=redis-%i
LimitNOFILE=65535
TimeoutStartSec=infinity
TimeoutStopSec=infinity
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
# /etc/redis/6380.conf、/etc/redis/6381.conf 各自設定 port、dir、pidfile、logfile
sudo systemctl enable --now redis@6380 redis@6381
```

每個實例的 `dir`、`pidfile`、`logfile`、`cluster-config-file` 都要不同，`maxmemory` 加總不能超過主機的規劃。

## 每日巡檢腳本

```bash
#!/usr/bin/env bash
# redis-check.sh：每天跑一次，結果寄到群組或寫入監控系統
export REDISCLI_AUTH="$(cat /etc/redis/.monitor_pass)"
for h in 192.168.58.21 192.168.58.22 192.168.58.23; do
  echo "== $h"
  redis-cli -h "$h" --user monitor INFO server      | grep -E "redis_version|uptime_in_days"
  redis-cli -h "$h" --user monitor INFO memory      | grep -E "used_memory_human|maxmemory_human|mem_fragmentation_ratio"
  redis-cli -h "$h" --user monitor INFO persistence | grep -E "rdb_last_bgsave_status|aof_last_write_status"
  redis-cli -h "$h" --user monitor INFO replication | grep -E "role|connected_slaves|master_link_status"
  redis-cli -h "$h" --user monitor INFO keyspace
  redis-cli -h "$h" --user monitor SLOWLOG LEN
done
```

搭配[監控]({% post_url 2026-10-24-redis-ops-04-monitoring %})的告警，巡檢補足的是「沒到告警門檻但正在變差」的趨勢：碎片率、key 數成長、沒有 TTL 的 key 比例、版本是否落後。

## Key 命名規範

| 規則 | 範例 |
| :--- | :--- |
| 用冒號分層：`業務:物件:ID[:欄位]` | `order:detail:1001`、`user:session:abc123` |
| 全部小寫，單字之間用底線 | `user:login_fail:1001` |
| 長度盡量短，但要看得懂 | `u:1001` 太短；`user_profile_information:1001` 太長 |
| 需要時加版本號 | `user:v2:1001` |
| Cluster 多 key 操作用 hash tag | `{order:1001}:items`、`{order:1001}:total` |
| 不同應用不要共用前綴 | 用 ACL 的 `~order:*` 限制 |

## TTL 與資料大小規範

- **快取資料一定要設 TTL**，`INFO keyspace` 的 `expires` 應該接近 `keys`。
- TTL 加上隨機值（例如 `3600 + random(0, 300)`），避免大量 key 同時過期造成延遲與快取雪崩。
- 單一 String value 不超過 **10 KB**（建議值），超過要評估壓縮或拆分。
- 集合類型（Hash、List、Set、ZSet）元素數不超過 **5,000**，超過要分桶。
- 不要把 Redis 當作唯一的資料來源，除非有完整的持久化與備份設計。

## 指令使用規範

| 禁止 | 改用 |
| :--- | :--- |
| `KEYS` | `SCAN` |
| `HGETALL` / `SMEMBERS` / `LRANGE 0 -1`（大集合） | `HSCAN` / `SSCAN` / 分頁 |
| `DEL` 大 key | `UNLINK` |
| `FLUSHALL` / `FLUSHDB` | 用 ACL 禁止，只有 DBA 帳號可用 |
| 迴圈逐筆 `GET` / `SET` | Pipeline、`MGET` / `MSET` |
| 長時間的 Lua 腳本 | 拆小，或在應用程式端處理 |
| `MONITOR`（正式環境長時間開啟） | 排查時短暫使用 |
| `SELECT` 多個 db 區隔業務 | 用不同實例；Cluster 只支援 db 0 |

## 用戶端使用規範

- 使用連線池，設定**連線逾時**（1～2 秒）與**指令逾時**（依業務，通常 < 1 秒）。
- Sentinel 架構透過 Sentinel 取得主庫位址，不要寫死 IP；Cluster 架構使用支援 Cluster 的用戶端。
- 處理 Redis 不可用的情況：快取讀取失敗要能降級到資料庫，並加上熔斷，避免把資料庫打垮。
- 快取更新用「先更新資料庫，再刪除快取」（Cache-Aside），並處理刪除失敗的重試。

## 版本差異比較：7.4 vs 8.x

| 項目 | 7.4.11 | 8.x（8.10.2） |
| :--- | :--- | :--- |
| 安裝來源 | 原始碼編譯（官方 RPM 不提供 7.4） | 官方 RPM / APT 套件庫可直接 `dnf install`，含 systemd unit 與 SELinux 政策 |
| 備份自動化 | 腳本要自己關 rewrite、複製 AOF | 8.10 `BACKUP` 指令，腳本流程更單純 |
| 監控帳號權限 | 只需傳統指令 | 新增的 `INFO` 區段與指令（`HOTKEYS`、`CLUSTER SLOT-STATS`）要記得授權給監控帳號 |
| 原子指令 | 計數器限流、比較後寫入要用 Lua | 8.4 `SET` 比較後寫入、`MSETEX`；8.8 `INCREX` 可取代常見的限流 Lua 腳本 |
| 編譯參數 | `USE_SYSTEMD`、`BUILD_TLS` | 多了 `BUILD_WITH_MODULES`（內建模組）、`BUILD_COMPRESSION`（複製壓縮） |

### 給自動化的升級建議

- 8.x 可以改用官方 RPM 套件庫安裝，Ansible role 變得更簡單，也能直接用 `dnf update` 追 patch。
- 規範中的「禁止長時間 Lua」，在 8.x 可以多一條：能用原生原子指令（`HSETEX`、`MSETEX`、`INCREX`）就不要寫 Lua。

## 系列總結

這十篇加上三篇實作，從安裝、備份、高可用、監控、效能、容量、安全、變更、排障到自動化，整理了 Redis 7.4 運維的主要面向。幾個貫穿全系列的重點：

- **版本與授權**：7.4 是 RSALv2 / SSPL，要 OSI 授權選 7.2 或 8.x 的 AGPLv3；跑 7.4 一定要追到最新 patch（撰寫時為 7.4.11）。
- **設定**：`maxmemory` 一定要設、Lazy Free 全開、`vm.overcommit_memory = 1`，而且 redis.conf **不支援行尾註解**。
- **高可用**：一台放得下用 Sentinel，放不下才用 Cluster；非同步複製一定有遺失資料的可能。
- **效能**：單執行緒模型下，大 key 與 O(N) 指令是最大的敵人。
- **8.x 的升級重點**：新的 I/O 多執行緒與複製機制、原子 slot 搬遷、`BACKUP` 指令、內建模組；但 **8.6 以上的 RDB 無法回退到 7.4**，升級前務必保留備份與舊版從庫。

感謝閱讀，有任何問題歡迎到 [GitHub](https://github.com/jimmyjan0824) 與我交流。

### 參考資料

- [Redis administration](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/)
- [redis-hashes：官方原始碼雜湊值](https://github.com/redis/redis-hashes)
- [ansible.posix.sysctl](https://docs.ansible.com/ansible/latest/collections/ansible/posix/sysctl_module.html)
- [redis/redis-rpm](https://github.com/redis/redis-rpm)
