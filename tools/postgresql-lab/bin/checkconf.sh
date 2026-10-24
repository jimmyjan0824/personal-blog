#!/usr/bin/env bash
# 用法：checkconf.sh <設定檔> [port] [psql 路徑]
# 1. 列出 pg_file_settings 中沒有套用或有錯誤的設定
# 2. 依設定檔每個參數上一行註解的標記（建議 / 預設 / initdb），和 pg_settings 的實際值與 boot_val（編譯預設值）比對：
#    標「預設」但實際值 ≠ boot_val，或標「建議」但實際值 = boot_val，都印成 CHECK
f=$1; port=${2:-5432}; psql=${3:-/usr/pgsql-17/bin/psql}
vals=$(awk '
  /^#/ { if ($0 ~ /^# *建議/) tag="建議"; else if ($0 ~ /^# *預設/) tag="預設"; else if ($0 ~ /^# *initdb/) tag="initdb"; next }
  /^[a-z]/ { split($0, a, "="); gsub(/[ \t]/, "", a[1]); printf "%s(\x27%s\x27,\x27%s\x27,%d)", sep, (tag==""?"?":tag), a[1], NR; sep=","; tag="" }
' "$f")
runuser -u postgres -- "$psql" -X -p "$port" -d postgres -P pager=off <<SQL
\echo '--- pg_file_settings：沒有套用或有錯誤的設定（空的代表全部套用）'
SELECT sourceline, name, setting, applied, error FROM pg_file_settings WHERE error IS NOT NULL OR NOT applied ORDER BY sourceline;
\echo '--- 設定檔參數數量與標記'
WITH v(tag, name, line) AS (VALUES $vals)
SELECT tag, count(*) FROM v GROUP BY tag ORDER BY tag;
\echo '--- 需要確認的項目（CHECK）；UNKNOWN 代表這個版本沒有這個參數'
WITH v(tag, name, line) AS (VALUES $vals)
SELECT v.line, v.tag, v.name, s.setting, s.boot_val, s.unit, s.source,
       CASE WHEN s.name IS NULL THEN 'UNKNOWN'
            WHEN s.source <> 'configuration file' THEN 'CHECK(source)'
            WHEN v.tag = '預設' AND s.setting IS DISTINCT FROM s.boot_val THEN 'CHECK'
            WHEN v.tag = '建議' AND s.setting = s.boot_val THEN 'CHECK'
            ELSE 'ok' END AS result
FROM v LEFT JOIN pg_settings s ON lower(s.name) = v.name
WHERE s.name IS NULL OR s.source <> 'configuration file'
   OR (v.tag = '預設' AND s.setting IS DISTINCT FROM s.boot_val)
   OR (v.tag = '建議' AND s.setting = s.boot_val)
ORDER BY v.line;
\echo '--- 標「建議」的參數：實際值與預設值（boot_val，單位見 unit）'
WITH v(tag, name, line) AS (VALUES $vals)
SELECT v.name, s.setting, s.boot_val, s.unit FROM v JOIN pg_settings s ON lower(s.name) = v.name WHERE v.tag = '建議' ORDER BY v.line;
SQL
