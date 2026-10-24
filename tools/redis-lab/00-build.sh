#!/usr/bin/env bash
# 建置兩個映像：rocky9-base（只有 systemd）與 rocky9-redis74（照步驟 1 編譯安裝 Redis 7.4.11）
source "$(dirname "$0")/lib.sh"
{
note "docker build rocky9-base"
docker build -t rocky9-base -f Dockerfile.base . 2>&1 | tail -5
note "docker build rocky9-redis74"
time docker build --progress=plain -t rocky9-redis74 . 2>&1 | tail -40
docker run --rm rocky9-redis74 redis-server --version
} 2>&1 | tee results/00-build.log
