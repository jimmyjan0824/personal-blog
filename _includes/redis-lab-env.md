> **關於版本與實測範圍**
>
> - 本系列以撰寫時（2026-10）7.x 的最新版 **Redis 7.4.11** 為準，從 `download.redis.io` 下載原始碼，在 Rocky Linux 9 上用 `dnf` 安裝編譯工具後編譯安裝。
> - 文中的指令輸出都是實際執行的結果：MacBook Air M4 / Docker Desktop 上的 **Rocky Linux 9 容器 + systemd**（aarch64），每台「主機」是一個容器，有固定 IP 與主機名。驗證方法見文末「驗證方式與結果」。
> - 設定檔以「16 GB RAM、8 vCPU、SSD」的專用主機為基準；實測的 Docker VM 只有約 7.7 GB 記憶體，所以**沒有做記憶體壓力測試**，`redis-benchmark` 的數字也只代表容器環境。
> - 輸出中以 `#` 開頭、標「主機端」的是在 Mac 上執行的 `docker compose` 指令與時間（台北時間，UTC+8）；Redis 與 Sentinel 日誌的時間是 UTC。
> - **沒有實測的部分**：`firewalld` 與 SELinux（容器內沒有），文中會標示「未實測」。
{: .prompt-warning }
