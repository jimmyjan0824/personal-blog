#!/usr/bin/env bash
# 共用函式：x <節點> <指令>，先印出「[節點]# 指令」再在容器內執行，輸出就是文章裡的實測輸出
set -u
cd "$(dirname "$0")"
mkdir -p results
x() {
  local n=$1; shift
  echo "[$n]# $*"
  docker compose exec -T "$n" bash -c "export REDISCLI_AUTH=ChangeMe_Redis_2026; $*" 2>&1
  echo
}
note() { echo; echo "======== $* ========  ($(date '+%F %T'))"; }
# 比對設定檔與 CONFIG GET 實際值（記憶體單位換成 bytes 再比）
cmpconf() {
  local n=$1 f=$2 port=${3:-6379}
  docker compose exec -T "$n" bash -c "export REDISCLI_AUTH=ChangeMe_Redis_2026
    tobytes(){ v=\$1; case \$v in *gb) echo \$(( \${v%gb}*1024*1024*1024 ));; *mb) echo \$(( \${v%mb}*1024*1024 ));; *kb) echo \$(( \${v%kb}*1024 ));; *) echo \$v;; esac; }
    ok=0; bad=0
    grep -Ev '^\s*(#|$)' $f | grep -Ev '^(client-output-buffer-limit|save|bind|requirepass|masterauth|include|sentinel|replicaof|rename-command)' | while read -r k v; do
      v=\${v//\\\"/}; want=\$(tobytes \"\$v\"); got=\$(redis-cli -p $port --no-raw config get \$k | sed -n 2p | tr -d '\"')
      if [ \"\$want\" != \"\$got\" ]; then echo \"DIFF \$k file=\$v actual=\$got\"; fi
    done
    echo 'save:' \$(redis-cli -p $port config get save | sed -n 2p)
    echo 'client-output-buffer-limit:' \$(redis-cli -p $port config get client-output-buffer-limit | sed -n 2p)
    echo 'bind:' \$(redis-cli -p $port config get bind | sed -n 2p)
    echo 'compare done'" 2>&1
}
