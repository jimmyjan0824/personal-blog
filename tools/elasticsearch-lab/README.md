# Elasticsearch 9.5.5 實測環境（Rocky Linux 9 容器 + systemd）

部落格 Elasticsearch 安裝部署文章的驗證環境（9.5.5 為主，比較 8.19.23）。

```bash
./00-build.sh        # 建置 eslab-rocky9-base、eslab-rocky9-es9（9.5.5）、eslab-rocky9-es8（8.19.23）
./05-defaults.sh     # esd9 / esd8：RPM 原始設定啟動，匯出所有預設值與 8.19 vs 9.5 差異
docker compose down -v  # 清除（含快照 volume）
```

輸出記錄在 `results/`。`conf/` 是文章裡的設定檔，容器內掛載在 `/root/conf`。

> Docker Hub 的 `rockylinux:9` 停在 9.3，要用 `rockylinux/rockylinux:9`。
