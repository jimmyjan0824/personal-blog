# Rocky Linux 9 + systemd + Percona Server for MySQL 5.7（ps57 套件庫的最新版，build 時用 dnf 安裝，尚未初始化）
# Percona 5.7 只有 x86_64 套件，Apple Silicon 上用 linux/amd64 模擬執行（compose.yaml 已指定 platform）
# 注意：Docker Hub 的 rockylinux:9 停在 9.3，要用 rockylinux/rockylinux:9
FROM rockylinux/rockylinux:9
ARG PS57_VER=""
RUN dnf install -y systemd procps-ng iproute hostname which less vim-minimal tzdata diffutils \
 && dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm \
 && percona-release setup -y ps57 \
 && dnf install -y Percona-Server-server-57${PS57_VER} Percona-Server-client-57${PS57_VER} \
 && dnf clean all \
 && systemctl mask systemd-logind.service getty.target console-getty.service \
 && (systemctl disable mysqld 2>/dev/null; true)
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
