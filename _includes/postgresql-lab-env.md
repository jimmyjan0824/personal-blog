> **關於版本與實測範圍**
>
> - 本系列以撰寫時（2026-10）17.x 的最新版 **PostgreSQL 17.11** 為準，比較對象是 **18.6**，兩者都從 PGDG 官方套件庫用 `dnf` 安裝在 Rocky Linux 9.8 上。
> - 文中的指令輸出都是實際執行的結果：MacBook Air M4 / Docker Desktop 上的 **Rocky Linux 9.8 容器 + systemd**（aarch64），每台「主機」是一個容器，有固定 IP 與主機名。建置檔與測試腳本放在 [GitHub](https://github.com/jimmyjan0824/personal-blog/tree/main/tools/postgresql-lab)。
> - 設定檔以「16 GB RAM、8 vCPU、SSD」的專用主機為基準；實測的 Docker VM 只有約 7.7 GB 記憶體，所以**沒有做記憶體壓力測試**，`pgbench` 的數字也只代表容器環境。
> - 輸出中 `[主機]#` 是以 root 執行的指令，`[主機]$` 是以 postgres 帳號執行，`[主機] 資料庫=#` 是 psql 裡的 SQL；PostgreSQL 日誌的時間是台北時間（`log_timezone = 'Asia/Taipei'`，顯示為 `CST`）。
> - **沒有實測的部分**：`firewalld`、SELinux、Huge Pages（容器內沒有或共用宿主核心），文中會標示「未實測」。
{: .prompt-warning }
