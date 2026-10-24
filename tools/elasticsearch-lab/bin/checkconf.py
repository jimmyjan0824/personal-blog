#!/usr/bin/env python3
# 用法：checkconf.py <設定檔> <預設值檔> [實際值 JSON]
#   設定檔：elasticsearch.yml 或索引範本 YAML，參數一律寫成「扁平」的 key: value，
#           上一行註解以「# 建議」「# 預設」「# 必要」開頭標記（「必要」= 路徑、名稱、憑證等沒有好壞之分的值）
#   預設值檔：05-defaults.sh 匯出的 key|value（全新安裝的節點 / 索引的 include_defaults）
#   實際值 JSON：_nodes/_local/settings?flat_settings 或 <index>/_settings?flat_settings&include_defaults 的結果（可省略）
# 標「預設」但值 ≠ 預設值、標「建議」但值 = 預設值、預設值檔裡沒有這個參數（UNKNOWN）、實際值與設定檔不同，都印成 CHECK
import json, re, sys

UNITS = {'nanos': 1e-6, 'micros': 1e-3, 'ms': 1, 's': 1000, 'm': 60000, 'h': 3600000, 'd': 86400000,
         'b': 1, 'kb': 1024, 'mb': 1024**2, 'gb': 1024**3, 'tb': 1024**4, 'pb': 1024**5}

def norm(v):
    v = str(v).strip().strip('"').strip("'")
    if v.startswith('['):
        v = ','.join(x.strip().strip('"').strip("'") for x in v.strip('[]').split(',') if x.strip())
    v = v.lower()
    # 時間與大小換算成同一單位再比（1s = 1000ms、10gb = 10240mb、-1b = -1）
    m = re.fullmatch(r'(-?\d+(?:\.\d+)?)(nanos|micros|ms|s|m|h|d|b|kb|mb|gb|tb|pb)', v)
    if m:
        x = float(m.group(1)) * UNITS[m.group(2)] if float(m.group(1)) >= 0 else float(m.group(1))
        unit = 't' if m.group(2) in ('nanos', 'micros', 'ms', 's', 'm', 'h', 'd') else 'b'
        return f'{x:g}{unit}' if x >= 0 else '-1'
    m = re.fullmatch(r'-?\d+\.0', v)
    return v[:-2] if m else v

conf, deffile = sys.argv[1], sys.argv[2]
defaults = {}
for line in open(deffile, encoding='utf-8'):
    k, _, v = line.rstrip('\n').partition('|')
    defaults[k] = v
actual = {}
if len(sys.argv) > 3:
    j = json.load(open(sys.argv[3], encoding='utf-8'))
    def holders(d):
        if isinstance(d, dict):
            if isinstance(d.get('settings'), dict):
                yield d
            else:
                for v in d.values():
                    yield from holders(v)
    for h in holders(j):
        for part in ('defaults', 'settings'):
            for k, v in (h.get(part) or {}).items():
                actual[k] = v if not isinstance(v, list) else '[' + ','.join(map(str, v)) + ']'

tag, rows, counts = None, [], {}
for no, line in enumerate(open(conf, encoding='utf-8'), 1):
    s = line.strip()
    if s.startswith('#'):
        m = re.match(r'#\s*(建議|預設|必要)', s)
        if m:
            tag = m.group(1)
        continue
    m = re.match(r'^\s*([a-z][\w.\-]*):\s*(\S.*?)\s*$', line)
    if not m or m.group(2) in ('', '|', '>'):
        continue
    key, val = m.group(1), re.sub(r'\s+#.*$', '', m.group(2))
    if key in ('template', 'settings', 'index_patterns', 'priority', 'version', 'composed_of', '_meta'):
        continue
    if key.startswith('template.'):
        key = key[len('template.'):]
    if key.startswith('settings.'):
        key = key[len('settings.'):]
    if not key.startswith(('index.', 'cluster.', 'node.', 'path.', 'network.', 'http.', 'transport.', 'discovery.', 'bootstrap.',
                           'indices.', 'thread_pool.', 'xpack.', 'action.', 'search.', 'ingest.', 'gateway.', 'script.', 'logger.', 'snapshot.', 'repositories.', 'monitor.', 'readiness.')):
        continue
    t = tag or '?'
    tag = None
    counts[t] = counts.get(t, 0) + 1
    d = defaults.get(key)
    if t == '必要':
        result = 'ok'
    elif d is None:
        result = 'UNKNOWN'
    elif t == '預設' and norm(val) != norm(d):
        result = 'CHECK'
    elif t == '建議' and norm(val) == norm(d):
        result = 'CHECK'
    else:
        result = 'ok'
    a = actual.get(key)
    if a is not None and norm(a) != norm(val):
        result = 'CHECK(actual)' if result == 'ok' else result + ',CHECK(actual)'
    rows.append((no, t, key, val, d, a, result))

print('--- 設定檔參數數量與標記')
for k in sorted(counts):
    print(f'{k}\t{counts[k]}')
print('--- 需要確認的項目（CHECK / UNKNOWN；UNKNOWN 代表預設值清單裡沒有這個參數，例如沒有預設值的路徑、清單型設定）')
print('line\ttag\tsetting\tfile\tdefault\tactual\tresult')
for r in rows:
    if r[6] != 'ok':
        print('\t'.join('' if x is None else str(x) for x in r))
print('--- 標「建議」的參數：設定值與預設值')
for r in rows:
    if r[1] == '建議':
        print(f'{r[2]}\t{r[3]}\t(預設 {r[4]})')
print(f'--- 共 {len(rows)} 個參數，ok {sum(1 for r in rows if r[6] == "ok")} 個')
