#!/usr/bin/env bash
# 建置 mysqlup-rocky9-ps57：Rocky 9 + systemd + Percona Server 5.7（linux/amd64）
source "$(dirname "$0")/lib.sh"
{
note "主機環境"
h "sw_vers 2>/dev/null; uname -m; docker version --format '{{.Server.Version}} {{.Server.Arch}}'"
note "docker build mysqlup-rocky9-ps57 (linux/amd64)"
docker pull -q --platform linux/amd64 rockylinux/rockylinux:9
time docker build --platform linux/amd64 --progress=plain -t mysqlup-rocky9-ps57 . 2>&1 | tail -25
docker run --rm --platform linux/amd64 mysqlup-rocky9-ps57 bash -c 'cat /etc/rocky-release; uname -m; rpm -qa | grep -i percona | sort; mysqld --version'
note "ps57 套件庫可用的版本（最後 5 版）"
docker run --rm --platform linux/amd64 mysqlup-rocky9-ps57 bash -c 'dnf -q --showduplicates list Percona-Server-server-57 2>/dev/null | tail -5'
note "ps80 套件庫可用的版本（最後 5 版）"
docker run --rm --platform linux/amd64 mysqlup-rocky9-ps57 bash -c 'percona-release setup -y ps80 >/dev/null 2>&1; dnf -q --showduplicates list percona-server-server 2>/dev/null | tail -5'
} 2>&1 | tee results/00-build.log
