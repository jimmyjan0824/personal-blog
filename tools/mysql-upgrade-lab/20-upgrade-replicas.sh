#!/usr/bin/env bash
# 把從庫 db2、db3 依序就地升級（in-place）到 Percona Server 8.0：主庫 db1 維持 5.7，app 持續寫入 db1
source "$(dirname "$0")/lib.sh"
{
note "升級前"
m db1 "SELECT @@version;"
x app 'grep -c OK /tmp/writer.log; grep -c ERR /tmp/writer.log; tail -1 /tmp/writer.log'
SRC=db1 upgrade_node db2 yes
note "db2 升級完成，混合版本：db1 5.7 → db2 8.0、db3 5.7"
m db1 "SHOW SLAVE HOSTS;"
SRC=db1 upgrade_node db3 no
note "兩台從庫都是 8.0，主庫 db1 仍是 5.7"
sync_cmp db1 db2 db3
x app 'echo "OK=$(grep -c OK /tmp/writer.log) ERR=$(grep -c ERR /tmp/writer.log)"; grep ERR /tmp/writer.log | head -5'
} 2>&1 | tee results/20-upgrade-replicas.log
