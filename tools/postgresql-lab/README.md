# PostgreSQL 17 實測環境（Rocky Linux 9.8 容器 + systemd）

部落格 PostgreSQL 安裝部署兩篇（Standalone / Streaming Replication）的驗證環境。

```bash
./00-build.sh        # 建置 pglab-rocky9-base、pglab-rocky9-pg17（PGDG 套件庫）
./10-standalone.sh   # pg1：Standalone，並在同一台裝 18 比較預設值
./20-streaming.sh    # pgs1~pgs3：1 主 2 從、quorum 同步、failover、pg_rewind
./30-extra.sh        # 補充驗證：運維文章中 17 vs 18 的差異（pg1 上 17 / 18 並存）
docker compose down  # 清除
```

輸出記錄在 `results/`。`conf/` 是文章裡的設定檔，容器內掛載在 `/root/conf`；`bin/checkconf.sh` 用來比對設定檔與 `pg_settings`。

> Docker Hub 的 `rockylinux:9` 停在 9.3，PGDG 套件庫已不支援（repomd.xml 404），要用 `rockylinux/rockylinux:9`。

實測環境：MacBook Air M4 / Docker Desktop 4.96.3，PostgreSQL 17.11 與 18.6（PGDG，aarch64）。`results/40-tcp-keepalives.log` 是另外以 TCP 連線確認 `tcp_keepalives_*` 的紀錄。
