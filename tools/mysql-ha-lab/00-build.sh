#!/usr/bin/env bash
# 建置兩個映像：mysqllab-ps80（Lab 07 起點）與 mysqllab-ps84（Lab 08~12，含 XtraBackup 8.4）
source "$(dirname "$0")/lib.sh"
{
note "主機環境"
h "uname -srm; nproc; free -g | head -2; docker version --format '{{.Server.Version}} {{.Server.Arch}}'"
docker pull -q rockylinux/rockylinux:9
# 只能透過 HTTPS 代理上網的環境：LAB_PROXY=http://172.17.0.1:3128 LAB_CA=/path/ca.crt ./00-build.sh
EXTRA=(); [ -n "${LAB_PROXY:-}" ] && EXTRA=(--build-arg LAB_PROXY=$LAB_PROXY --secret id=labca,src=${LAB_CA})
note "docker build mysqllab-ps80（Percona Server 8.0.46-37.1）"
time docker build "${EXTRA[@]}" --progress=plain -t mysqllab-ps80 --build-arg PS_REPO=ps80 --build-arg PS_VER=-8.0.46-37.1.el9 . 2>&1 | tail -5
note "docker build mysqllab-ps84（Percona Server 8.4.11-12.1 + XtraBackup 8.4）"
time docker build "${EXTRA[@]}" --progress=plain -t mysqllab-ps84 --build-arg PS_REPO=ps-84-lts --build-arg PS_VER=-8.4.11-12.1.el9 --build-arg "PXB=pxb-84-lts percona-xtrabackup-84" . 2>&1 | tail -5
for i in mysqllab-ps80 mysqllab-ps84; do
  note "$i 內容"
  docker run --rm $i bash -c 'cat /etc/rocky-release; uname -m; rpm -qa | grep -iE "percona|qpress" | sort; mysqld --version; mysqlsh --version; mysqlrouter --version; xtrabackup --version 2>&1 | tail -1'
done
note "各套件庫可用的最新版本"
docker run --rm mysqllab-ps84 bash -c 'for r in ps80 ps-84-lts ps-97-lts; do percona-release setup -y $r >/dev/null 2>&1; echo "== $r"; dnf -q --showduplicates list percona-server-server percona-mysql-shell 2>/dev/null | tail -4; done; percona-release enable pxb-97-lts release >/dev/null 2>&1; echo "== pxb"; dnf -q --showduplicates list "percona-xtrabackup-8*" "percona-xtrabackup-9*" 2>/dev/null | tail -6'
} 2>&1 | tee results/00-build.log
