#!/usr/bin/env bash
# 建置兩個映像：pglab-rocky9-base（只有 systemd）與 pglab-rocky9-pg17（照步驟 1 用 PGDG 安裝 PostgreSQL 17，尚未 initdb）
source "$(dirname "$0")/lib.sh"
{
note "docker build pglab-rocky9-base"
docker pull -q rockylinux/rockylinux:9
docker build -t pglab-rocky9-base -f Dockerfile.base . 2>&1 | tail -5
docker run --rm pglab-rocky9-base cat /etc/rocky-release
note "docker build pglab-rocky9-pg17"
time docker build --progress=plain -t pglab-rocky9-pg17 . 2>&1 | tail -15
docker run --rm pglab-rocky9-pg17 bash -c 'rpm -q postgresql17-server postgresql17-contrib; /usr/pgsql-17/bin/postgres --version'
} 2>&1 | tee results/00-build.log
