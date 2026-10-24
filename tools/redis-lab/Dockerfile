# Rocky Linux 9 + systemd + 依「步驟 1」從原始碼編譯安裝 Redis（Sentinel / Cluster 節點用）
FROM rocky9-base
ARG REDIS_VER=7.4.11
RUN dnf install -y gcc make tar gzip systemd-devel \
 && cd /usr/local/src \
 && curl -fsSLO https://download.redis.io/releases/redis-${REDIS_VER}.tar.gz \
 && tar xzf redis-${REDIS_VER}.tar.gz \
 && cd redis-${REDIS_VER} \
 && make -j"$(nproc)" USE_SYSTEMD=yes \
 && make install \
 && dnf clean all
