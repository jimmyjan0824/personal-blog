// 把 results/*.log 裡的一段實測輸出畫成終端機截圖（PNG），放到 assets/img/posts/<lab>/
// 用法：node shots/render.js shots/07.json
//   spec: { "out": "mysql-ha-lab-07", "shots": [ { "name": "01-checker", "title": "db2 — 升級檢查",
//            "log": "07-20-upgrade-replicas.log", "from": "開頭字串", "to": "結尾字串(含)" 或 "lines": 30,
//            "skip": ["要略過的行包含的字串"], "hl": ["要標黃的字串"] } ] }
const fs = require('fs'), path = require('path');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
const spec = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const outDir = path.resolve(root, '../../assets/img/posts', spec.out);
fs.mkdirSync(outDir, { recursive: true });
const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
function cut(s) {
  const lines = fs.readFileSync(path.join(root, 'results', s.log), 'utf8').replace(/\x1b\[[0-9;]*m/g, '').split('\n');
  let i = lines.findIndex((l, k) => k >= (s.after ? lines.findIndex(x => x.includes(s.after)) : 0) && l.includes(s.from));
  if (i < 0) throw new Error(`${s.name}: from not found: ${s.from}`);
  let j;
  if (s.to) { j = lines.findIndex((l, k) => k > i && l.includes(s.to)); if (j < 0) throw new Error(`${s.name}: to not found: ${s.to}`); }
  else j = i + (s.lines || 30) - 1;
  let out = lines.slice(i, j + 1).filter(l => !(s.skip || []).some(k => l.includes(k)))
    .filter(l => s.border || !/^\+[-+]+\+$/.test(l))
    .filter((l, k, a) => !(l.trim() === '' && k > 0 && a[k - 1].trim() === ''));
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  return out;
}
function color(l, hl) {
  let h = esc(l);
  const p = h.match(/^(\[[a-z0-9]+\](?:#| mysql&gt;| mysqlsh&gt;))(.*)$/);
  if (p) return `<span class="pr">${p[1]}</span><span class="cmd">${p[2]}</span>`;
  if (/ERROR|Error:|\[ERROR\]|Authentication requires|is not loaded|Connecting|exit=1/.test(l)) h = `<span class="err">${h}</span>`;
  else if (/Warning|WARNING/.test(l)) h = `<span class="warn">${h}</span>`;
  for (const k of hl || []) h = h.split(esc(k)).join(`<span class="hl">${esc(k)}</span>`);
  return h;
}
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 980, height: 400 }, deviceScaleFactor: 2 });
  for (const s of spec.shots) {
    const body = cut(s).map(l => color(l, s.hl)).join('\n');
    await page.setContent(`<!doctype html><meta charset="utf-8"><style>
      body{margin:0;background:#e9edf2;padding:18px;display:inline-block}
      .win{background:#1e2329;border-radius:9px;box-shadow:0 6px 22px rgba(0,0,0,.28);overflow:hidden;width:940px}
      .bar{background:#2d333b;height:32px;display:flex;align-items:center;padding:0 12px;gap:7px}
      .dot{width:12px;height:12px;border-radius:50%}
      .t{color:#adbac7;font:13px "DejaVu Sans","WenQuanYi Zen Hei",sans-serif;margin-left:10px}
      pre{margin:0;padding:14px 16px 16px;color:#d1d7e0;font:12.5px/1.45 "DejaVu Sans Mono","WenQuanYi Zen Hei Mono","WenQuanYi Zen Hei",monospace;white-space:pre-wrap;word-break:break-all}
      .pr{color:#7ee787}.cmd{color:#ffffff;font-weight:bold}.err{color:#ff7b72}.warn{color:#e3b341}.hl{background:#5a4a00;color:#ffe58a}
    </style><div class="win"><div class="bar"><span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span><span class="t">${esc(s.title)}</span></div><pre>${body}</pre></div>`);
    const el = await page.$('body');
    const f = path.join(outDir, s.name + '.png');
    await el.screenshot({ path: f });
    console.log(f);
  }
  await browser.close();
})();
