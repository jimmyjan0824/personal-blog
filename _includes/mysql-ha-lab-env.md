> **關於版本與實測範圍**
>
> - Percona 沒有 8.0.9 這個版本，8.0 系列的版號是 `8.0.4x-xx`。本系列以撰寫時（2026-10）8.0 最新的 **Percona Server for MySQL 8.0.46-37.1** 為準。
> - 文中所有指令輸出都是實際執行的結果。實測環境是在 Docker 裡起多個節點（`db1`~`db3`、`router`），每個節點以 **systemd 為 PID 1**，所以 `systemctl` 與 `mysqld_pre_systemd` 初始化流程都是真的跑過。
> - 節點映像是 Percona 官方的 `percona/percona-server:8.0.46-37.1`，底層是 RHEL 9 UBI，裝的是 `percona-server-server-8.0.46-37.1.el9.x86_64` 這批 **el9 RPM**，和 Rocky Linux 9 用 `dnf` 裝到的是同一份套件（Rocky 9 與 RHEL 9 二進位相容）。
> - **沒有實測的部分**：從 `repo.percona.com` 以 `dnf` 安裝（測試環境連不到 Percona 套件庫）、`firewalld` 與 SELinux 設定（容器內沒有）。這些步驟依官方文件撰寫，文中會標示「未實測」。
{: .prompt-warning }
