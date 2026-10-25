# Elasticsearch 9.5.5 實測環境（Rocky Linux 9 容器 + systemd）

部落格 Elasticsearch 安裝部署四篇（單節點 / 三節點 Cluster / 8.19 → 9.5 滾動升級 / Kibana）的驗證環境（9.5.5 為主，比較 8.19.23）。

```bash
./00-build.sh           # 建置 eslab-rocky9-base、eslab-rocky9-es9（9.5.5）、eslab-rocky9-es8（8.19.23）
./05-defaults.sh        # esd9 / esd8：RPM 原始設定啟動，匯出所有預設值與 8.19 vs 9.5 差異
./10-single-node.sh     # es1：單節點，現場照文章安裝；最後把同一份設定檔放到 8.19.23（esd8）比較
./20-cluster.sh         # esc1~esc3：三節點叢集，故障、失去過半數、滾動重啟、快照還原、加入 / 排空 esc4
./30-rolling-upgrade.sh # esu1~esu3：8.19.23 三節點滾動升級到 9.5.5（背景持續寫入），最後測試降版
./40-lag.sh             # 同步落後：叢集內副本追趕（seq_no / checkpoint）、CCR 跨叢集複製落後（esc1~esc3 → esd9，試用授權）
./50-kibana.sh          # kb1：Kibana 9.5.5 現場安裝，連 esc1~esc3（TLS、kibana_system、keystore），故障 / 拼錯參數 / 8.19.23 對照
docker compose down -v  # 清除（含快照 volume）
```

輸出記錄在 `results/`。`conf/` 是文章裡的設定檔，容器內掛載在 `/root/conf`；`bin/checkconf.py` 用來比對設定檔的「預設 / 建議」標記與 `05-defaults.sh` 匯出的預設值。

> Docker Hub 的 `rockylinux:9` 停在 9.3，要用 `rockylinux/rockylinux:9`。
> 映像裡的 RPM 在 `docker build` 時就跑了 security auto-config（憑證 SAN 是建置容器的名稱），叢集節點會換成自建 CA 的憑證；只有 auto-config 憑證的節點，`lib.sh` 以 `localhost` 驗證憑證、用 `--connect-to` 連到節點。
