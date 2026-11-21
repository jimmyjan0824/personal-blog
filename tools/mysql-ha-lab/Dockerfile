# syntax=docker/dockerfile:1
# Rocky Linux 9 + systemd + Percona Server for MySQL（build 時用 dnf 從 repo.percona.com 安裝，尚未初始化）
#   PS_REPO：ps80 / ps-84-lts / ps-97-lts（percona-release 的套件庫名稱）
#   PS_VER ：固定版本，例如 -8.4.11-12.1.el9；留空就是該套件庫的最新版
#   PXB    ：要一起裝的 XtraBackup 套件庫與套件，例如 "pxb-84-lts percona-xtrabackup-84"；留空不裝
#   LAB_PROXY：只有在「只能透過 HTTPS 代理上網」的環境才需要（例如雲端沙箱），一般電腦留空
# 注意：Docker Hub 的 rockylinux:9 停在 9.3，要用 rockylinux/rockylinux:9
FROM rockylinux/rockylinux:9
ARG PS_REPO=ps-84-lts
ARG PS_VER=""
ARG SHELL_VER=""
ARG PXB=""
ARG LAB_PROXY=""
COPY lab-proxy-setup.sh /usr/local/sbin/
RUN --mount=type=secret,id=labca,required=false /usr/local/sbin/lab-proxy-setup.sh "${LAB_PROXY}"
RUN dnf install -y systemd procps-ng iproute hostname which less vim-minimal tzdata diffutils python3 glibc-langpack-en lsof \
 && dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm \
 && percona-release setup -y ${PS_REPO} \
 && dnf install -y percona-server-server${PS_VER} percona-server-client${PS_VER} \
                   percona-mysql-shell${SHELL_VER} percona-mysql-router${PS_VER} \
 && if [ -n "${PXB}" ]; then set -- ${PXB}; percona-release enable $1 release && dnf install -y $2 zstd lz4; fi \
 && dnf clean all \
 && systemctl mask systemd-logind.service getty.target console-getty.service \
 && (systemctl disable mysqld mysqlrouter 2>/dev/null; true)
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
