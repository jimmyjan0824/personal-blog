#!/usr/bin/env python3
# 從 writer.log 算寫入中斷：指定時間（到結束時間）之間，失敗筆數、相鄰兩筆成功寫入之間最長的空檔
import sys, collections
from datetime import datetime
since, log = sys.argv[1], sys.argv[2]
until = sys.argv[3] if len(sys.argv) > 3 else '99'
f = '%H:%M:%S.%f'
rows = [l.rstrip('\n').split(' ', 3) for l in open(log) if since <= l[:12] <= until]
err = [r for r in rows if r[1] == 'ERR']
oks = [r for r in rows if r[1] == 'OK']
print(f'ERR 筆數: {len(err)}')
for msg, c in collections.Counter(r[3] for r in err).most_common(3):
    print(f'  {c:3d} {msg}')
best = (0, None, None)
for a, b in zip(oks, oks[1:]):
    g = (datetime.strptime(b[0], f) - datetime.strptime(a[0], f)).total_seconds()
    if g > best[0]: best = (g, a, b)
g, a, b = best
if a:
    print(f'最後一筆成功（舊）: {a[0]} {a[3]}')
    print(f'第一筆成功（新）  : {b[0]} {b[3]}')
    print(f'寫入中斷秒數（兩筆成功寫入的最大間隔）: {g:.3f}')
