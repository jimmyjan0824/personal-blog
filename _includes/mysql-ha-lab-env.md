> **關於版本與實測範圍**
>
> - Percona 沒有 8.0.9 這個版本，8.0 系列的版號是 `8.0.4x-xx`。本系列以撰寫時（2026-10）8.0 最新的 **Percona Server for MySQL 8.0.46-37.1** 為準。
> - 文中的指令輸出都是實際執行的結果，在兩個環境各完整跑過一次（驗證方法見文末「驗證方式與結果」）：
>   1. **Rocky Linux 9 容器 + systemd，用 `dnf` 從 `repo.percona.com` 實際安裝**（MacBook Air M4 / Docker Desktop，aarch64）。這是和真實 Rocky 9 主機最接近的驗證。
>   2. Percona 官方映像 `percona/percona-server:8.0.46-37.1`（RHEL 9 UBI，同版本 el9 RPM）+ systemd（Linux / x86_64）。
> - **沒有實測的部分**：`firewalld` 與 SELinux 設定（容器內沒有），文中會標示「未實測」。
{: .prompt-warning }
