# Redis 7.4.11 實測環境（Rocky Linux 9 容器 + systemd）

部落格 Redis 安裝部署三篇（Standalone / Sentinel / Cluster）的驗證環境。

```bash
./00-build.sh        # 建置 rocky9-base、rocky9-redis74（dnf + 原始碼編譯）
./10-standalone.sh   # redis1
./20-sentinel.sh     # rs1~rs3
./30-cluster.sh      # rc1~rc6
docker compose down  # 清除
```

輸出記錄在 `results/`。`conf/` 是文章裡的設定檔，容器內掛載在 `/root/conf`。
