# Percona Server 5.7 → 8.0 從庫先升級再切換 實測環境（Rocky Linux 9 容器 + systemd）

部落格〈MySQL 高可用實作 06：Percona Server 5.7 升級 8.0（先升從庫再切換）〉的驗證環境。
db1（主）、db2、db3（從）一開始都是 ps57 套件庫最新的 Percona Server 5.7，app 容器持續寫入。

```bash
./00-build.sh               # 建置 mysqlup-rocky9-ps57（linux/amd64，Percona 5.7 沒有 aarch64 套件）
./10-setup-57.sh            # 5.7 一主二從（GTID），灌測試資料，app 開始每 0.2 秒寫入 db1
./20-upgrade-replicas.sh    # db2、db3 依序就地升級到 ps80 最新版（升級檢查、validate-config、資料比對）
./30-switchover.sh          # db2 升為主庫、db3 改接 db2、量測寫入中斷；測試 5.7 的 db1 當 8.0 的從庫
./40-upgrade-old-primary.sh # db1 升級到 8.0 重新接上 db2，核對 app 每一筆成功寫入都在
docker compose down -v      # 清除
```

輸出記錄在 `results/`。`conf/` 掛載在容器內的 `/root/conf`。

- Apple Silicon 上整個環境以 amd64 模擬執行（Docker Desktop 的 Rosetta / QEMU），速度較慢但結果一致。
- Docker Hub 的 `rockylinux:9` 停在 9.3，要用 `rockylinux/rockylinux:9`。
