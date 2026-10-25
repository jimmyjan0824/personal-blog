// 用法（kb1 上，以 Kibana 內附的 node 執行）：node kibana-defaults.js /usr/share/kibana > defaults.txt
// Kibana 沒有像 Elasticsearch include_defaults 的 API，所以直接載入安裝目錄裡的設定 schema（@kbn/config-schema 物件），
// 對空物件 validate({}) 取得預設值。輸出：設定路徑|值|來源檔案
//   有 path 的 descriptor（核心服務、多數外掛的 config）→ 印成完整的設定名稱，例如 elasticsearch.requestTimeout
//   沒有 path 的 schema（外掛 config.js 裡匯出的 configSchema）→ 設定路徑前面是「?」，要對照外掛的 configPath
// 有必填欄位、validate({}) 失敗的 schema 會被略過
const fs = require('fs'), path = require('path');
const root = process.argv[2] || '/usr/share/kibana';
const ctx = { dev: false, prod: true, dist: true, serverless: false, version: '9.5.5', branch: '', buildNum: 0, buildSha: '' };
const isSchema = (v) => v && typeof v === 'object' && typeof v.validate === 'function' && typeof v.getSchema === 'function';
const seen = new Set();
function flat(prefix, v, out) {
  if (v && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Date) && Object.keys(v).length && !v.asMilliseconds && !v.getValueInBytes) {
    for (const [k, x] of Object.entries(v)) flat(prefix ? `${prefix}.${k}` : k, x, out);
  } else {
    let s;
    if (v && v.asMilliseconds) s = `${v.asMilliseconds()}ms`;
    else if (v && v.getValueInBytes) s = `${v.getValueInBytes()}b`;
    else s = JSON.stringify(v);
    out.push([prefix, s]);
  }
}
function tryValidate(p, schema, file) {
  if (seen.has(schema)) return; seen.add(schema);
  let v; try { v = schema.validate({}, ctx); } catch (e) { return; }
  const out = []; flat(p, v, out);
  for (const [k, s] of out) console.log(`${k}|${s}|${path.relative(root, file)}`);
}
function walk(dir) {
  let ents; try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const f = path.join(dir, e.name);
    if (e.isDirectory()) { if (!/^(test|tests|__fixtures__|__mocks__|public|target|\..*)$/.test(e.name)) walk(f); continue; }
    if (!/config[^/]*\.js$/.test(e.name) || !/server|core|config/.test(f)) continue;
    let m; try { m = require(f); } catch { continue; }
    for (const [name, x] of Object.entries(m || {})) {
      try {
        if (x && x.path && isSchema(x.schema)) tryValidate(Array.isArray(x.path) ? x.path[0] : x.path, x.schema, f);
        else if (x && isSchema(x.schema)) tryValidate(`?${name}`, x.schema, f);
        else if (isSchema(x)) tryValidate(`?${name}`, x, f);
      } catch { /* 忽略 */ }
    }
  }
}
for (const d of ['node_modules/@kbn', 'src', 'x-pack']) walk(path.join(root, d));
