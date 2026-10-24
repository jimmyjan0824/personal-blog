> **關於版本與實測範圍**
>
> - 本系列以撰寫時（2026-10）最新的 **Elasticsearch 9.5.5**（Lucene 10.5.1、內附 OpenJDK 27）為準，比較對象是 8.x 的最後一個 minor **8.19.23**（Lucene 9.12.2），兩者都從 Elastic 官方 RPM 套件庫用 `dnf` 安裝在 Rocky Linux 9.8 上。
> - 文中的指令輸出都是實際執行的結果：MacBook Air M4 / Docker Desktop 上的 **Rocky Linux 9.8 容器 + systemd**（aarch64），每台「主機」是一個容器，有固定 IP 與主機名。驗證方法見文末「驗證方式與結果」。
> - 設定檔以「16 GB RAM、8 vCPU、本機 SSD」的專用主機為基準；實測的 Docker VM 只有約 7.7 GB 記憶體、好幾個節點共用，所以每個節點的 heap 固定為 1 GB（`lab-heap.options`），**寫入與查詢的數字只代表容器環境**，不能拿來估正式主機的效能。
> - 輸出中 `[主機]#` 是以 root 執行的指令，`[主機] GET /...` 是對該節點 `https://<主機>:9200` 送出的 REST 請求（以 `elastic` 帳號、驗證 CA 憑證）。Elasticsearch 日誌的時間是 UTC，腳本的時間戳記是台北時間。
> - **沒有實測的部分**：`firewalld`、SELinux、THP、關閉 swap（容器內沒有或共用宿主核心），文中會標示「未實測」。
{: .prompt-warning }
