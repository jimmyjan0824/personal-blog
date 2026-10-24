#!/usr/bin/env bash
# 共用函式：先印出要執行的指令再在容器內執行，輸出就是文章裡的實測輸出
#   x <節點> <shell 指令>          以 root 執行，印成「[節點]# 指令」
#   p <節點> <SQL> [資料庫] [port]  以 postgres 帳號用 psql 執行，印成「[節點] 資料庫=# SQL」
set -u
cd "$(dirname "$0")"
export PATH="$HOME/.docker/bin:$PATH"
mkdir -p results
PGBIN=${PGBIN:-/usr/pgsql-17/bin}
x() {
  local n=$1; shift
  echo "[$n]# $*"
  docker compose exec -T "$n" bash -c "export PATH=$PGBIN:\$PATH; $*" 2>&1
  echo
}
p() {
  local n=$1 sql=$2 db=${3:-postgres} port=${4:-5432}
  echo "[$n] $db=# $sql"
  docker compose exec -T -u postgres -w /var/lib/pgsql "$n" "$PGBIN/psql" -X -p "$port" -d "$db" -P pager=off -c "$sql" 2>&1
  echo
}
note() { echo; echo "======== $* ========  ($(date '+%F %T'))"; }
# 主機端指令：印成「# 主機端：指令」再執行
h() { echo "# 主機端：$*"; eval "$@" 2>&1; echo; }
