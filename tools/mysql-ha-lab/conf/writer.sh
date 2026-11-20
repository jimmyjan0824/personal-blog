#!/bin/bash
# 模擬應用程式：每 0.2 秒寫一筆到 /tmp/target 指定的主機（可寫成 host:port，例如 router:6446），成功 / 失敗都記在 /tmp/writer.log
# 停止：touch /tmp/writer.stop；暫停（比對資料用）：touch /tmp/writer.pause
while [ ! -f /tmp/writer.stop ]; do
  if [ -f /tmp/writer.pause ]; then sleep 0.2; continue; fi
  T=$(cat /tmp/target); H=${T%%:*}; P=${T##*:}; [ "$P" = "$T" ] && P=3306
  OUT=$(mysql -h"$H" -P"$P" -uapp -pChangeMe_App_2026 --connect-timeout=2 -N \
        -e "INSERT INTO appdb.t_orders (note, src) VALUES (CONCAT('w-', NOW(6)), @@hostname); SELECT @@hostname" 2>&1 | grep -v 'Using a password')
  if echo "$OUT" | grep -q ERROR; then echo "$(date +%T.%3N) ERR $T $OUT"; else echo "$(date +%T.%3N) OK $T $OUT"; fi >> /tmp/writer.log
  sleep 0.2
done
