// Generates corpus/functions2/*.cases.json: FORMAT/PARSE in many cultures
// (checks the generated culture table, src/core/exec/culture_data.mbt),
// .NET custom/standard format edge cases, ORDER BY key rules, GREATEST/
// LEAST and CONCAT typing, float literal range, SWITCHOFFSET numeric zones
// and LAG/LEAD/FIRST_VALUE/LAST_VALUE edge cases. One small batch per case.
// Expected output is captured from the oracle (npm run capture -- functions2).
//
//   node gen/functions2.mjs   (recapture changed files with --force)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'functions2')
mkdirSync(outDir, { recursive: true })
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60)

function family(file, groups) {
  const cases = []
  const seen = new Set()
  for (const g of groups) {
    const exprs = Array.isArray(g) ? g : [g]
    let name = `${String(cases.length).padStart(3, '0')}-${slug(exprs[0])}`
    while (seen.has(name)) name += 'x'
    seen.add(name)
    const sql = exprs[0].startsWith('!') ? exprs[0].slice(1) : `SELECT ${exprs.map((e, i) => `${e} AS c${i}`).join(', ')}`
    cases.push({ name, steps: [{ kind: 'batch', sql }] })
  }
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/functions2.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

// ------------------------------------------------------------ FORMAT cultures
const cultures = [
  'iv', 'en-US', 'en-GB', 'de-DE', 'fr-FR', 'ja-JP', 'zh-TW', 'zh-CN', 'ko-KR', 'th-TH', 'es-ES', 'it-IT', 'nl-NL',
  'nb-NO', 'nn-NO', 'pt-PT', 'pt-BR', 'fi-FI', 'sv-SE', 'da-DK', 'cs-CZ', 'hu-HU', 'pl-PL', 'ro-RO', 'hr-HR', 'sk-SK',
  'sl-SI', 'el-GR', 'bg-BG', 'ru-RU', 'tr-TR', 'et-EE', 'lv-LV', 'lt-LT', 'de-AT', 'de-CH', 'fr-CA', 'fr-CH', 'fr-BE',
  'en-CA', 'en-AU', 'en-IE', 'en-NZ', 'es-MX', 'nl-BE', 'uk-UA', 'he-IL', 'hi-IN', 'en', 'de', 'fr', 'ja', 'ar-SA',
]
const N = 'CAST(-1234567.891 AS decimal(12,3))'
const DTX = "CAST('2009-11-23 15:04:05.0123456' AS datetime2(7))"
const DT1 = "CAST('2024-01-02 03:04:05' AS datetime2(0))"
const fmtCult = []
for (const c of cultures) {
  const q = `'${c}'`
  fmtCult.push([`FORMAT(${N}, 'N', ${q})`, `FORMAT(${N}, 'C', ${q})`, `FORMAT(CAST(-0.1234 AS decimal(6,4)), 'P1', ${q})`, `FORMAT(${N}, 'F1', ${q})`, `FORMAT(${N}, '#,##0.0#', ${q})`, `FORMAT(CAST(1234.5 AS float), 'E2', ${q})`, `FORMAT(CAST(0.5 AS decimal(3,1)), '0.0%;-0.0%', ${q})`])
  if (c === 'ar-SA') continue
  fmtCult.push([`FORMAT(${DTX}, 'd', ${q})`, `FORMAT(${DTX}, 'D', ${q})`, `FORMAT(${DTX}, 'f', ${q})`, `FORMAT(${DTX}, 'G', ${q})`, `FORMAT(${DTX}, 'M', ${q})`, `FORMAT(${DTX}, 'Y', ${q})`, `FORMAT(${DTX}, 't', ${q})`])
  fmtCult.push([`FORMAT(${DT1}, 'dddd d MMMM yyyy', ${q})`, `FORMAT(${DT1}, 'MMMM', ${q})`, `FORMAT(${DT1}, 'ddd, d MMM', ${q})`, `FORMAT(${DT1}, 'hh:mm tt', ${q})`, `FORMAT(${DT1}, 'yyyy/MM/dd HH:mm', ${q})`])
}
fmtCult.push(
  [`FORMAT(1.5, 'N', 'xx-XX')`, `FORMAT(1.5, 'N', 'xx')`, `FORMAT(1.5, 'C', 'a-bc')`, `FORMAT(1.5, 'N', 'EN-gb')`, `FORMAT(1.5, 'N', 'de_DE')`],
  [`FORMAT(1.5, 'N', 'x')`], [`FORMAT(1.5, 'N', 'abcd')`], [`FORMAT(1.5, 'N', 'ab-12')`], [`FORMAT(1.5, 'N', NULL)`], [`FORMAT(1.5, 'N', '')`],
)
family('format-cultures', fmtCult)

// ------------------------------------------------------------ FORMAT numbers
const nums = {
  int: 'CAST(1234567 AS int)', neg_int: 'CAST(-42 AS int)', bigint: 'CAST(-9223372036854775807 AS bigint)', tinyint: 'CAST(200 AS tinyint)',
  dec: 'CAST(1234.5678 AS decimal(10,4))', small_dec: 'CAST(0.000123 AS decimal(10,6))', neg_dec: 'CAST(-0.005 AS decimal(5,3))',
  money: 'CAST(1234.5 AS money)', smallmoney: 'CAST(-12.3456 AS smallmoney)', float: 'CAST(1234.56789 AS float)', tiny_float: 'CAST(1.5e-10 AS float)',
  big_float: 'CAST(9.87654321e25 AS float)', real: 'CAST(3.14159 AS real)', zero: 'CAST(0 AS int)', zero_dec: 'CAST(0.00 AS decimal(5,2))',
}
const numFmt = []
for (const [k, v] of Object.entries(nums)) {
  numFmt.push(['C', 'C0', 'D', 'D8', 'E', 'e4', 'F', 'F0', 'G', 'G3', 'g10', 'N', 'N0', 'P', 'P0', 'R', 'X', 'x4'].map(f => `FORMAT(${v}, '${f}')`))
  numFmt.push(['0', '0.00', '#.##', '#,#', '#,##0.000', '00000', '0.0e+0', '0.##E-00', '0%', '0.0‰', '#,##0,', '0,,.00', '[#]0', '\\#0', '"x"0', "'a'0", '0;(0);zero', '0;;zero', '0.00;', ' '].map(f => `FORMAT(${v}, N'${f.replace(/'/g, "''")}')`))
}
numFmt.push(
  [`FORMAT(CAST(0.1 AS float) + CAST(0.2 AS float), 'R')`, `FORMAT(CAST(1 AS float) / 3, 'G17')`, `FORMAT(CAST(1e300 AS float), 'R')`, `FORMAT(CAST(0.0001 AS float), 'G')`, `FORMAT(CAST(0.00001 AS float), 'G')`],
  [`FORMAT(CAST(1 AS real) / 3, 'R')`, `FORMAT(CAST(16777217 AS real), 'G')`, `FORMAT(CAST(0.1 AS real), 'N10')`, `FORMAT(CAST(0.1 AS real), 'E8')`],
  [`FORMAT(12345, 'B')`, `FORMAT(12345, 'Q2')`, `FORMAT(12345, 'N100')`, `FORMAT(12345, 'N05')`, `FORMAT(12345, '')`],
  [`FORMAT(CAST(5 AS decimal(5,0)), N'''a''0')`, `FORMAT(CAST(5 AS money), N'"b"#')`, `FORMAT(CAST(5 AS float), N'''a''0')`, `FORMAT(CAST(5 AS int), N'''a''0')`],
  [`FORMAT(-0.001, 'N2')`, `FORMAT(-0.001, '0.00')`, `FORMAT(CAST(-0.001 AS float), '0.00')`, `FORMAT(-0.001, '0.00;(0.00);zero')`, `FORMAT(0.5, '#')`, `FORMAT(0, '#')`],
  [`FORMAT(1234567.891, '#,##0.00;(#,##0.00)', 'de-DE')`, `FORMAT(1234567.891, '#,0.0', 'fr-FR')`, `FORMAT(1234567.891, '0.0%', 'de-CH')`, `FORMAT(1234567.891, 'N', 'hi-IN')`, `FORMAT(-1234567.891, 'C', 'hi-IN')`],
  [`FORMAT(CAST(1234.5 AS decimal(6,1)), CAST(NULL AS nvarchar(10)))`, `FORMAT(CAST(1234.5 AS float), CAST(NULL AS nvarchar(10)), 'fr-FR')`],
)
family('format-numbers', numFmt)

// ------------------------------------------------------------ FORMAT dates
const dates = {
  datetime2: "CAST('2024-03-05 14:07:09.1200000' AS datetime2(7))", datetime: "CAST('2024-03-05 14:07:09.997' AS datetime)",
  smalldatetime: "CAST('2024-03-05 23:59:29' AS smalldatetime)", date: "CAST('0001-01-01' AS date)",
  dto: "CAST('2024-03-05 01:07:09.1234567 -05:30' AS datetimeoffset(7))",
}
const dateFmt = []
for (const [k, v] of Object.entries(dates)) {
  dateFmt.push(['d', 'D', 'f', 'F', 'g', 'G', 'm', 'o', 'r', 's', 't', 'T', 'u', 'U', 'y', 'K', 'x'].map(f => `FORMAT(${v}, '${f}')`))
  dateFmt.push(['%d', 'yyyyy y yy yyy', 'M MM MMM MMMM', 'h hh H HH hhh', 'm mm s ss', 'f ff fff ffff fffffff', 'F FF FFF FFFFFFF', 'ss.FFF', 'ss,FFF', 't tt', 'zzz z zz', '%K', "'quoted' \\\\x", 'dddd dd ddd', 'gg yyyy', '/ : -'].map(f => `FORMAT(${v}, N'${f.replace(/'/g, "''")}')`))
}
dateFmt.push(
  [`FORMAT(${dates.datetime2}, 'ffffffff')`],
  [`FORMAT(${dates.datetime2}, 'D', 'ru-RU')`, `FORMAT(${dates.datetime2}, 'd MMMM', 'ru-RU')`, `FORMAT(${dates.datetime2}, 'MMMM', 'ru-RU')`, `FORMAT(${dates.datetime2}, 'dd MMM', 'pl-PL')`, `FORMAT(${dates.datetime2}, 'MMM', 'pl-PL')`],
  [`FORMAT(${dates.datetime2}, 'D', 'th-TH')`, `FORMAT(${dates.datetime2}, 'yy yyyy', 'th-TH')`],
)
const times = ["CAST('14:07:09.1234567' AS time(7))", "CAST('00:00:00' AS time(0))", "CAST('09:05:03.5' AS time(1))"]
for (const t of times) {
  dateFmt.push(['c', 't', 'T', 'g', 'G', 'D', 'hh\\:mm', 'hh:mm', 'h\\.m\\.s', "hh'h'mm", 'ss\\.fff', 'ss\\.FFF', '%h', 'd\\.hh', 'HH\\:mm'].map(f => `FORMAT(${t}, N'${f.replace(/'/g, "''")}')`))
  dateFmt.push(['g', 'G'].map(f => `FORMAT(${t}, '${f}', 'de-DE')`))
}
family('format-dates', dateFmt)

// ------------------------------------------------------------ PARSE cultures
const parse = []
const p = (s, t, c) => `${c ? 'TRY_PARSE' : 'TRY_PARSE'}(N'${s.replace(/'/g, "''")}' AS ${t}${c ? ` USING '${c}'` : ''})`
for (const [c, num, money, date1, date2] of [
  ['de-DE', '-1.234,5', '1.234,50 €', '23.11.2009', '23. November 2009'],
  ['fr-FR', '1 234,5', '1 234,50 €', '23/11/2009', '23 novembre 2009'],
  ['en-GB', '1,234.5', '£1,234.50', '23/11/2009', '23 November 2009'],
  ['ja-JP', '1,234.5', '¥1,235', '2009/11/23', '2009/11/23 15:04'],
  ['es-ES', '1.234,5', '1.234,50 €', '23/11/2009', '23 noviembre 2009'],
  ['it-IT', '1.234,5', '€ 1.234,50', '23/11/2009', '23 novembre 2009'],
  ['nl-NL', '1.234,5', '€ 1.234,50', '23-11-2009', '23 november 2009'],
  ['pt-BR', '1.234,5', 'R$ 1.234,50', '23/11/2009', '23 de novembro de 2009'],
  ['ru-RU', '1 234,5', '1 234,50 ₽', '23.11.2009', '23 ноября 2009'],
  ['sv-SE', '1 234,5', '1 234,50 kr', '2009-11-23', '23 november 2009'],
  ['pl-PL', '1 234,5', '1 234,50 zł', '23.11.2009', '23 listopada 2009'],
  ['de-CH', "1'234.5", "CHF 1'234.50", '23.11.2009', '23. November 2009'],
  ['en-US', '(1,234.5)', '($1,234.50)', '11/23/2009', 'November 23, 2009'],
  ['iv', '1,234.5', '¤1,234.50', '11/23/2009', '23 November 2009'],
]) {
  parse.push([p(num, 'decimal(10,2)', c), p(num, 'float', c), p(num, 'int', c), p(money, 'money', c), p(date1, 'date', c), p(date2, 'date', c)])
}
parse.push(
  [p('1,5', 'decimal(5,2)', 'xx-XX'), p('1.5', 'decimal(5,2)', 'xx-XX'), p('1,5', 'decimal(5,2)', 'de'), p('1,5', 'decimal(5,2)', 'DE-de')],
  [`PARSE(N'1,5' AS decimal(5,2) USING 'Deutsch')`],
  [`PARSE(N'abc' AS int USING 'de-DE')`],
  [`PARSE(N'12/31/2009' AS date USING 'en-GB')`],
  [`PARSE(N'2009-11-23T15:04:05.99999999' AS datetime2(0))`],
)
family('parse-cultures', parse)

// ------------------------------------------------------------ ORDER BY keys, GREATEST/LEAST, CONCAT, literals
const T2 = "(VALUES (3, 1, N'c'), (1, 2, N'a'), (2, 1, NULL)) t(a, b, s)"
const misc = [
  `!SELECT a FROM ${T2} ORDER BY 'x'`,
  `!SELECT a FROM ${T2} ORDER BY a, NULL`,
  `!SELECT a FROM ${T2} ORDER BY CAST(1 AS int) + 2`,
  `!SELECT a FROM ${T2} ORDER BY -2`,
  `!SELECT a FROM ${T2} ORDER BY (SELECT 1), a`,
  `!SELECT 1 AS k, a FROM ${T2} ORDER BY k, a`,
  `!SELECT CAST(NULL AS int) AS k, a FROM ${T2} ORDER BY 1, 2 DESC`,
  `!SELECT a, a FROM ${T2} ORDER BY a`,
  `!SELECT a AS x, b AS x FROM ${T2} ORDER BY x`,
  `!SELECT *, a FROM ${T2} ORDER BY a`,
  `!SELECT a, a AS c FROM ${T2} ORDER BY t.a DESC`,
  `!SELECT t.*, b AS bb FROM ${T2} ORDER BY bb, a`,
  `!DECLARE @k int = 1; SELECT a FROM ${T2} ORDER BY a, @k`,
  `!DECLARE @k int = 1; SELECT a FROM ${T2} ORDER BY a + @k`,
  `!SELECT 1 AS k UNION ALL SELECT 2 ORDER BY 1 + 0`,
  `!SELECT a, ROW_NUMBER() OVER (ORDER BY a DESC) AS n FROM ${T2}`,
  `!SELECT a, SUM(a) OVER (PARTITION BY b) AS s FROM ${T2}`,
  `!SELECT 1e-308 AS a, -4e-320 AS b, 0e400 AS c`,
  `!SELECT 1 AS a; SELECT 2e308 AS b`,
  `!SELECT 1 AS a; IF 1 = 0 SELECT 1e-310 AS b`,
  `!SELECT CAST(CHAR(9) + '1.5' AS float) AS a, CAST(N' ' + N'2.5' AS float) AS b, CAST('3.5' + CHAR(0) + 'x' AS float) AS c`,
  `!SELECT CAST('1.5' + CHAR(9) AS float) AS a`,
  `!SELECT CAST('1e400' AS float) AS a`,
  ['GREATEST(1.5, 2.25, 3)', 'GREATEST(2.5, CAST(1 AS decimal(3,1)))', 'LEAST(CAST(1 AS numeric(4,1)), CAST(2 AS decimal(5,2)))', 'GREATEST(1e0, 2)', 'GREATEST(1e0, 2.5)'],
  ['GREATEST(CAST(N\'a\' AS nvarchar(max)), N\'b\')', 'LEAST(CAST(0x01 AS varbinary(max)), 0x02)', 'GREATEST(CAST(\'a\' AS varchar(max)))'],
  [`DATALENGTH(LEAST(REPLICATE(CAST('a' AS varchar(max)), 8001), 'b'))`],
  [`GREATEST(CAST('<a/>' AS xml), CAST('<b/>' AS xml))`],
  [`GREATEST('a' COLLATE Latin1_General_CS_AS, 'B' COLLATE Latin1_General_BIN)`],
  [`CONCAT(CAST(0x41 AS image), CAST('<a/>' AS xml))`], [`CONCAT('x', CAST('<a/>' AS xml), N'y')`], [`CONCAT_WS(N',', CAST(1 AS sql_variant), CAST('<a/>' AS xml))`],
  ['CONCAT(CAST(0x414243 AS varbinary(3)), N\'\')', 'CONCAT_WS(N\'-\', CAST(0x4100 AS binary(2)), 0x42)', 'CONCAT(0x41, \'\')', 'TRANSLATE(CAST(0x4142 AS binary(4)), N\'A\', N\'Z\')'],
  [`CONVERT(varchar(max), CAST(NULL AS image))`],
  ["SWITCHOFFSET(CAST('2024-01-01 10:00 +00:00' AS datetimeoffset), CAST(-90.9 AS decimal(5,1)))", "TODATETIMEOFFSET(CAST('2024-01-01 10:00' AS datetime2), CAST(59.5 AS money))", "SWITCHOFFSET(CAST('2024-01-01 10:00 +00:00' AS datetimeoffset), CAST(1e0 AS float))"],
  ["SWITCHOFFSET(CAST('2024-01-01 10:00 +00:00' AS datetimeoffset), ' +01:00')"], ["SWITCHOFFSET(CAST('2024-01-01 10:00 +00:00' AS datetimeoffset), 900)"],
  ["TODATETIMEOFFSET(CAST('9999-12-31 23:00' AS datetime2), '-01:30')"],
  ['COT(1)', 'COT(-2.5)', 'COT(0.001)', 'COT(10)'],
]
family('order-and-types', misc)

// ------------------------------------------------------------ offset window functions
const W = "(VALUES (1, NULL, 'a'), (2, 10, 'a'), (3, NULL, 'b'), (4, 20, 'b'), (5, NULL, 'b'), (6, 30, 'a')) v(id, x, g)"
const win = [
  `!SELECT id, LAG(x) IGNORE NULLS OVER (ORDER BY id) AS a, LEAD(x) IGNORE NULLS OVER (ORDER BY id) AS b FROM ${W} ORDER BY id`,
  `!SELECT id, FIRST_VALUE(x) IGNORE NULLS OVER (ORDER BY id) AS a, LAST_VALUE(x) IGNORE NULLS OVER (ORDER BY id) AS b FROM ${W} ORDER BY id`,
  `!SELECT id, FIRST_VALUE(x) IGNORE NULLS OVER (PARTITION BY g ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS a, LAST_VALUE(x) RESPECT NULLS OVER (PARTITION BY g ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS b FROM ${W} ORDER BY id`,
  `!SELECT id, LAG(x, 2, -1) IGNORE NULLS OVER (ORDER BY id) AS a, LEAD(x, 2, -1) IGNORE NULLS OVER (PARTITION BY g ORDER BY id) AS b FROM ${W} ORDER BY id`,
  `!SELECT id, LAG(x, 0) OVER (ORDER BY id) AS a, LEAD(x, 10, 99) OVER (ORDER BY id) AS b, LAG(x, NULL) OVER (ORDER BY id) AS c FROM ${W} ORDER BY id`,
  `!SELECT LAG(x, -1) OVER (ORDER BY id) FROM ${W}`,
  `!SELECT id, LAG(x, 1, 2.5) OVER (ORDER BY id) AS a, LAG(g, 1, 'zzz') OVER (ORDER BY id) AS b FROM ${W} ORDER BY id`,
  `!SELECT LAG(x, 1, 'a') OVER (ORDER BY id) FROM ${W}`,
  `!DECLARE @o int = 2; SELECT id, LAG(x, @o) OVER (ORDER BY id) AS a, LEAD(x, @o + 1, @o) OVER (ORDER BY id) AS b FROM ${W} ORDER BY id`,
  `!SELECT id, LAG(x, id % 3) OVER (ORDER BY id) AS a FROM ${W} ORDER BY id`,
  `!SELECT id, FIRST_VALUE(x) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) AS a, LAST_VALUE(x) OVER (ORDER BY id) AS b, LAST_VALUE(x) OVER (ORDER BY g) AS c FROM ${W} ORDER BY id`,
  `!SELECT id, FIRST_VALUE(id) OVER (PARTITION BY g ORDER BY x DESC) AS a, LAST_VALUE(id) OVER (PARTITION BY g ORDER BY x RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS b FROM ${W} ORDER BY id`,
  `!SELECT LAG(x) OVER () FROM ${W}`,
  `!SELECT FIRST_VALUE(x) OVER (PARTITION BY g) FROM ${W}`,
  `!SELECT LAG(x) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING) FROM ${W}`,
  `!SELECT id, x, g, LEAD(g) OVER (PARTITION BY g ORDER BY id) AS a FROM ${W}`,
]
family('offset-window', win)
