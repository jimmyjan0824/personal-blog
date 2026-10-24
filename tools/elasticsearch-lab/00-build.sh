#!/usr/bin/env bash
# 建置三個映像：eslab-rocky9-base（只有 systemd）、eslab-rocky9-es9（9.5.5）、eslab-rocky9-es8（8.19.23），RPM 已安裝、尚未啟動
source "$(dirname "$0")/lib.sh"
{
note "docker build eslab-rocky9-base"
docker pull -q rockylinux/rockylinux:9
docker build -t eslab-rocky9-base -f Dockerfile.base . 2>&1 | tail -5
docker run --rm eslab-rocky9-base cat /etc/rocky-release
note "docker build eslab-rocky9-es9（Elasticsearch 9.5.5）"
time docker build --progress=plain --build-arg ES_MAJOR=9 --build-arg ES_VERSION=9.5.5 -t eslab-rocky9-es9 . 2>&1 | tail -40
note "docker build eslab-rocky9-es8（Elasticsearch 8.19.23）"
time docker build --progress=plain --build-arg ES_MAJOR=8 --build-arg ES_VERSION=8.19.23 -t eslab-rocky9-es8 . 2>&1 | tail -40
for i in es9 es8; do docker run --rm eslab-rocky9-$i bash -c 'rpm -q elasticsearch; /usr/share/elasticsearch/bin/elasticsearch --version 2>/dev/null; /usr/share/elasticsearch/jdk/bin/java -version 2>&1 | head -1'; done
} 2>&1 | tee results/00-build.log
