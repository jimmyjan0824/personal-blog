# MySQL 高可用實作 Lab 07~12 實測環境（Rocky Linux 9 容器 + systemd + Percona）

部落格〈MySQL 高可用實作〉07~12 篇的驗證環境。每台「主機」都是 Rocky Linux 9 容器、systemd 當 PID 1，
Percona 套件在 build 映像或實驗過程中**真的從 repo.percona.com 用 dnf 安裝 / 升級**。

| 主機 | IP | 用途 |
| --- | --- | --- |
| db1~db6 | 192.168.58.11~16 | MySQL（各 lab 用到的節點數不同） |
| router | 192.168.58.20 | MySQL Router |
| app | 192.168.58.30 | 模擬應用程式，每 0.2 秒寫一筆（`conf/writer.sh`） |

```bash
./00-build.sh                     # 建置 mysqllab-ps80（8.0.46-37.1）與 mysqllab-ps84（8.4.11-12.1 + XtraBackup 8.4）

# Lab 07：8.0 → 8.4 LTS 滾動升級
./07-10-setup-80.sh && ./07-20-upgrade-replicas.sh && ./07-30-switchover.sh && ./07-40-upgrade-old-primary.sh
# Lab 08：8.4 → 9.7 LTS 滾動升級
./08-10-setup-84.sh && ./08-20-upgrade-97.sh
# Lab 09：InnoDB ReplicaSet
./09-replicaset.sh
# Lab 10：InnoDB ClusterSet（6 台 MySQL，建議 Docker 分配 8 GB 以上記憶體）
./10-clusterset.sh
# Lab 11：多來源 / 過濾 / 延遲複製
./11-multisource-delayed-filter.sh
# Lab 12：XtraBackup 全量 + 增量 + binlog PITR
./12-xtrabackup-pitr.sh

docker compose down -v            # 清除
```

- 每個腳本都會先 `docker compose down -v`，從全新的主機開始；輸出（指令 + 實際結果）記錄在 `results/`。
- `conf/` 掛載在容器內的 `/root/conf`。
- `shots/render.js` 把 `results/*.log` 的片段畫成終端機截圖，輸出到 `assets/img/posts/mysql-ha-lab-NN/`：
  `node shots/render.js shots/07.json`（需要 Node.js + Playwright）。輸出後可以用 Pillow 轉成 128 色調色盤 PNG，大小約剩 1/4：
  `python3 -c "import glob;from PIL import Image;[Image.open(f).convert('RGB').quantize(128,dither=0).save(f,optimize=True) for f in glob.glob('../../assets/img/posts/mysql-ha-lab-*/*.png')]"`
- Docker Hub 的 `rockylinux:9` 停在 9.3，要用 `rockylinux/rockylinux:9`。

## 只能透過 HTTPS 代理上網的環境

一般電腦不需要。若主機只能經由 HTTPS 代理（只支援 CONNECT）上網，例如雲端沙箱：

```bash
# 在主機上把代理轉到 docker bridge 可以連到的位址（例如 172.17.0.1:3128），再：
LAB_PROXY=http://172.17.0.1:3128 LAB_CA=/path/to/proxy-ca.crt ./00-build.sh
```

`lab-proxy-setup.sh` 會在映像裡設定 dnf 代理、信任代理的 CA，並把 Rocky / Percona 套件庫改成 https。
另外若 `docker exec` 的 umask 是 0000，`lib.sh` 已經強制 `umask 022`（否則 `/etc/my.cnf.d` 裡的檔案是 world-writable，mysqld 會忽略它們）。
