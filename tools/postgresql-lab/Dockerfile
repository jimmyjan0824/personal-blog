# Rocky Linux 9.8 + systemd + 依「步驟 1」用 PGDG 套件庫安裝 PostgreSQL 17（Streaming Replication 節點用，尚未 initdb）
FROM pglab-rocky9-base
ARG PG_MAJOR=17
RUN dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm \
 && dnf -qy module disable postgresql \
 && dnf install -y postgresql${PG_MAJOR}-server postgresql${PG_MAJOR}-contrib \
 && dnf clean all
