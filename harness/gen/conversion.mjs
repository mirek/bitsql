// Generates corpus/conversion/*.cases.json: the SQL Server behaviour behind
// bitsql's conversion and scalar-function work of 2026-10-04 (CONVERT date
// styles incl. Hijri, input styles, float/money styles and storage bytes,
// text/ntext/image, COMPRESS/DECOMPRESS, CHECKSUM, CURSOR_STATUS,
// COLUMNS_UPDATED). Expected output is captured from the oracle
// (npm run capture -- conversion).
//
//   node gen/conversion.mjs   (rewrites the .cases.json files; case names
//                              are index-based, so recapture a changed file
//                              after deleting its expected.json)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'conversion')
mkdirSync(outDir, { recursive: true })

const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 50) || 'x'
const lit = s => `'${s.replace(/'/g, "''")}'`

function write(file, cases) {
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/conversion.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

// one batch per case; `!`-prefixed entries are raw batches, others a SELECT
function simple(file, items) {
  const cases = items.map((x, i) => {
    // a select list ending in its own alias gets no `AS v`
    const sql = x.startsWith('!') ? x.slice(1) : /\bAS\s+[A-Za-z_]\w*\s*$/.test(x) ? `SELECT ${x}` : `SELECT ${x} AS v`
    return { name: `${String(i).padStart(3, '0')}-${slug(x.replace(/^!/, ''))}`, steps: [{ kind: 'batch', sql }] }
  })
  write(file, cases)
}

// multi-step cases: [name, [setup...], [batch...]]
function stepped(file, items) {
  const cases = items.map(([name, setup, batches], i) => ({
    name: `${String(i).padStart(3, '0')}-${name}`,
    steps: [...setup.map(sql => ({ kind: 'batch', sql, compare: false })), ...batches.map(sql => ({ kind: 'batch', sql }))],
  }))
  write(file, cases)
}

// ------------------------------------------------------------ Hijri (130/131)
{
  const dates = ['2024-01-02', '2024-02-01', '2024-03-01', '2024-04-01', '2024-05-01', '2024-06-01', '2024-07-01', '2024-08-01',
    '2024-09-01', '2024-10-01', '2024-11-01', '2024-12-01', '1753-01-01', '1900-01-01', '9999-12-31', '2000-02-29', '1990-07-15']
  const items = dates.map(d => `CONVERT(nvarchar(60), CAST('${d}' AS datetime), 130) AS h130, CONVERT(nvarchar(60), CAST('${d}' AS datetime), 131) AS h131, CONVERT(varchar(60), CAST('${d}' AS date), 130)`)
  items.push(
    "CONVERT(nvarchar(60), CAST('0622-07-18' AS date), 131)",
    "CONVERT(nvarchar(60), CAST('0622-07-17' AS date), 131)",
    "CONVERT(nvarchar(60), CAST('03:04:05' AS time(0)), 130)",
    "CONVERT(nvarchar(60), CAST('2024-01-02 03:04:05.1234567 +05:30' AS datetimeoffset(7)), 131)",
    "CONVERT(datetime, '21/06/1445  3:04:05:123AM', 131)",
    "CONVERT(nvarchar(40), CONVERT(datetime2, '21/06/1445', 131), 121)",
    "CONVERT(date, '29/02/1445', 131)",
    "CONVERT(datetime, '30/02/1445', 131)",
    "CONVERT(datetime2, '30/13/1445', 131)",
    "CONVERT(datetime2, '29/12/9666', 131)",
    "CONVERT(datetime, '31/12/2024', 130)",
    "CONVERT(nvarchar(40), CONVERT(datetime2, '10:11:12', 131), 121)",
    "CONVERT(datetime2, '21 Dec 1445', 131)",
    "CONVERT(datetime, '21/06/45', 131)",
    "CONVERT(nvarchar(40), CONVERT(datetimeoffset, '21/06/1445 10:11:12 +01:00', 131), 127)",
  )
  simple('hijri', items)
}

// ------------------------------------------------------- character input styles
{
  const styles = [0, 1, 3, 6, 7, 8, 9, 12, 13, 14, 22, 23, 24, 25, 100, 106, 107, 108, 109, 113, 114, 130, 131]
  const strs = ['12/31/2024', '31/12/2024', '12/31/24', '31/12/24', '2024/12/31', '2024-12-31', '20241231', '241231', '31 Dec 2024',
    'Dec 31 2024', 'Dec 31, 24', '31 Dec 24', '2024-12-31 10:11:12.123', '10:11:12', '10:11:12:123', '12/31/24 10:11:12 PM',
    '2024-12-31T10:11:12', 'garbage', 'Jan  2 2024  3:04:05:123AM', '02 Jan 2024 03:04:05:123', '21/06/1445', '21/06/1445  3:04:05:123AM']
  const items = []
  for (const t of ['datetime', 'datetime2', 'date']) {
    for (const s of strs) {
      items.push(`'${t}' AS t, ` + styles.map(st => `CONVERT(varchar(30), TRY_CONVERT(${t}, ${lit(s)}, ${st}), 121) AS s${st}`).join(', '))
    }
  }
  items.push(`st, TRY_CONVERT(datetime2, '20241231', st) AS a, TRY_CONVERT(datetime, '20241231', st) AS b, TRY_CONVERT(datetime, 'Dec 31 2024', st) AS c FROM (VALUES (15),(16),(19),(26),(27),(99),(115),(116),(122),(125),(129),(132),(200)) v(st) --`)
  for (const sql of [
    "CONVERT(datetime2, '12/31/2024', 6)", "CONVERT(datetime2, '12/31/2024', 22)", "CONVERT(date, '12/31/24', 100)",
    "CONVERT(datetime, '12/31/24', 22)", "CONVERT(datetime, '2024-12-31', 23)", "CONVERT(datetime2, '12/31/2024', 15)",
    "CONVERT(datetime, '12/31/2024', 15)", "CONVERT(time, '10:11:12', 99)", "CONVERT(datetime2, N'2024-12-31', 99)",
    "TRY_CONVERT(date, '2024-12-31', 128)", "CONVERT(datetime, '2024-12-31T10:11:12', 112)",
  ]) items.push(sql)
  simple('input-styles', items.map(x => x.endsWith('--') ? `!SELECT ${x.slice(0, -2)}` : x))
}

// ------------------------------------------------------- date/time output styles
{
  const items = []
  for (const st of [16, 17, 18, 19, 26, 98, 116, 119, 122, 129, 132, 140]) {
    items.push(`!SELECT CONVERT(varchar(60), CAST('2024-01-02 03:04:05' AS datetime2), ${st}) AS v`)
  }
  items.push(
    '!DECLARE @s int = NULL; SELECT CONVERT(varchar(30), CAST(\'2024-01-02\' AS datetime), @s) AS a',
    "!DECLARE @s varchar(5) = '112'; SELECT CONVERT(varchar(30), CAST('2024-01-02' AS datetime), @s) AS a",
    '!DECLARE @s bigint = 112; SELECT CONVERT(varchar(30), CAST(\'2024-01-02\' AS datetime), @s) AS a',
    '!DECLARE @s bit = 1; SELECT CONVERT(varchar(30), CAST(\'2024-01-02\' AS datetime), @s) AS a',
    '!DECLARE @s decimal(5,0) = 1; SELECT CONVERT(varchar(30), CAST(\'2024-01-02\' AS datetime), @s) AS a',
    "CONVERT(varchar(30), CAST('2024-01-02' AS datetime), 1+111)",
    "TRY_CONVERT(varchar(30), CAST('03:04:05' AS time), 1)",
  )
  simple('output-styles', items)
}

// ------------------------------------------------ float/money styles and bytes
{
  const items = [
    '!SELECT st, TRY_CONVERT(varchar(40), CAST(1.5 AS float), st) AS f, TRY_CONVERT(varchar(40), CAST(0.1 AS real), st) AS r, TRY_CONVERT(varchar(40), CAST(1.5 AS money), st) AS m FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(20),(21),(100),(101),(102),(103),(120),(121),(126),(127),(128),(129),(130),(200),(-1)) v(st)',
    "CONVERT(varchar(30), CAST(0.1 AS float), 3), CONVERT(varchar(30), CAST(-1e300 AS float), 3), CONVERT(varchar(30), CAST(0.1 AS real), 1), CONVERT(varchar(30), CAST(0.1 AS real), 2)",
    'CONVERT(varbinary(max), CAST(9 AS decimal(1,0))), CONVERT(varbinary(max), CAST(-9 AS decimal(1,0))), CONVERT(varbinary(max), CAST(0 AS decimal(5,2))), CONVERT(varbinary(max), CAST(-0.00 AS decimal(5,2))), CONVERT(varbinary(max), CAST(12.5 AS numeric(12,3)))',
    'CONVERT(varbinary(4), CAST(12.5 AS numeric(12,3))), CONVERT(binary(12), CAST(12.5 AS numeric(4,1))), CONVERT(varbinary(max), CAST(-0.99999999999999999999999999999999999999 AS decimal(38,38)))',
    'CONVERT(varbinary(max), CAST(-1.5 AS float)), CONVERT(varbinary(max), CAST(-1.5 AS real)), CONVERT(varbinary(3), CAST(1.5 AS float)), CONVERT(binary(10), CAST(1.5 AS float))',
    'CONVERT(varbinary(max), CAST(0.0051 AS money)), CONVERT(varbinary(max), CAST(-1 AS smallmoney)), CONVERT(varbinary(max), CAST(-922337203685477.5808 AS money))',
    'CONVERT(money, 0x0000000000000033), CONVERT(money, 0x33), CONVERT(money, 0x000000000000000033), CONVERT(smallmoney, 0xFFFFFFFF), CONVERT(smallmoney, 0x0000000100000000)',
    'CONVERT(decimal(5,2), 0x0100000009000000), CONVERT(decimal(10,2), 0x0502010039300000), CONVERT(decimal(3,0), 0x0502010039300000), CONVERT(decimal(5,2), 0x050201003930000000)',
    'CONVERT(decimal(5,2), 0x01)', 'CONVERT(decimal(5,2), 0x2702010039300000)', 'CONVERT(decimal(5,2), 0x0506010039300000)',
    'CONVERT(float, 0x3FF8000000000000)', 'CONVERT(real, 0x3FC00000)',
    "CONVERT(varchar(3), 0x0A0B, 1), CONVERT(varchar(3), 0x0A0B0C, 2), CONVERT(varchar(5), 0x0A0B0C, 1)",
    'CONVERT(varbinary(4), \'\', 1)', "CONVERT(varbinary(4), 'abc', 3)", 'CONVERT(varchar(20), 0x0A0B, 3)',
  ]
  simple('numeric-styles', items)
}

// ------------------------------------------------------------ text/ntext/image
{
  const types = {
    bit: 'CAST(1 AS bit)', int: '1', 'decimal(5,2)': 'CAST(1.5 AS decimal(5,2))', float: 'CAST(1 AS float)',
    'char(3)': "CAST('abc' AS char(3))", 'varchar(10)': "'abc'", 'varchar(max)': "CAST('abc' AS varchar(max))",
    'nchar(3)': "CAST(N'abc' AS nchar(3))", 'nvarchar(10)': "N'abc'", 'nvarchar(max)': "CAST(N'abc' AS nvarchar(max))",
    'binary(3)': 'CAST(0x616263 AS binary(3))', 'varbinary(10)': '0x616263', 'varbinary(max)': 'CAST(0x616263 AS varbinary(max))',
    datetime: "CAST('2024-01-02' AS datetime)", uniqueidentifier: "CAST('6F9619FF-8B86-D011-B42D-00C04FD430C8' AS uniqueidentifier)",
    sql_variant: 'CAST(1 AS sql_variant)', rowversion: 'CAST(0x0000000000000001 AS rowversion)',
  }
  const lobs = { text: "CAST('abc' AS text)", ntext: "CAST(N'abc' AS ntext)", image: 'CAST(0x616263 AS image)' }
  const items = []
  for (const [l, lv] of Object.entries(lobs)) {
    for (const [t, tv] of Object.entries(types)) {
      items.push(`CAST(${lv} AS ${t})`, `CAST(${tv} AS ${l})`)
    }
    for (const l2 of Object.keys(lobs)) items.push(`CAST(${lv} AS ${l2})`)
  }
  simple('lob-conversions', items)

  const exprs = [
    'LEN({x})', 'DATALENGTH({x})', 'LEFT({x},1)', 'SUBSTRING({x},2,1)', 'SUBSTRING({x},1,10) + SUBSTRING({x},1,10)', 'UPPER({x})', 'TRIM({x})',
    "REPLACE({x},'b','x')", "CHARINDEX('b',{x})", "PATINDEX('%b%',{x})", 'REVERSE({x})', "STUFF({x},1,1,'x')", 'REPLICATE({x},2)',
    "CONCAT({x},'x')", "CONCAT_WS(',',{x},'x')", "{x} + 'x'", "'x' + {x}", "ISNULL({x},'x')", "COALESCE({x},'x')", "NULLIF({x},'x')",
    "IIF(1=1,{x},'x')", "CASE WHEN 1=1 THEN {x} ELSE 'x' END", 'ASCII({x})', 'SOUNDEX({x})', 'QUOTENAME({x})', "STRING_ESCAPE({x},'json')",
    "FORMAT({x},'x')", "HASHBYTES('MD5',{x})", 'CHECKSUM({x})', 'BINARY_CHECKSUM({x})', "CASE WHEN {x} = 'abc' THEN 1 ELSE 0 END",
    "CASE WHEN {x} LIKE 'a%' THEN 1 ELSE 0 END", 'CASE WHEN {x} IS NULL THEN 1 ELSE 0 END', "CASE WHEN {x} IN ('abc') THEN 1 ELSE 0 END",
    "CASE WHEN {x} > 'a' THEN 1 ELSE 0 END", "SQL_VARIANT_PROPERTY({x},'BaseType')", "DIFFERENCE({x},'abc')", 'MAX({x})', 'COUNT({x})',
    'COUNT(DISTINCT {x})', '{x} COLLATE Latin1_General_BIN2', "TRANSLATE({x},'a','b')", 'ISJSON({x})', 'COMPRESS({x})',
    "CONVERT(varchar(10), {x}, 1)", "GREATEST({x},'a')", "JSON_VALUE({x},'$.a')",
  ]
  const fitems = []
  for (const [, lv] of Object.entries(lobs)) for (const e of exprs) fitems.push(e.replaceAll('{x}', lv))
  for (const [l, lv] of Object.entries(lobs)) {
    fitems.push(
      `!SELECT v FROM (SELECT ${lv} AS v) d ORDER BY v`, `!SELECT v FROM (SELECT ${lv} AS v) d GROUP BY v`,
      `!SELECT DISTINCT v FROM (SELECT ${lv} AS v) d`, `!SELECT ${lv} AS v UNION SELECT ${lv}`, `!SELECT ${lv} AS v UNION ALL SELECT ${lv}`,
      `!DECLARE @v ${l}`, `!SELECT ${lv} AS v INTO #t; SELECT * FROM #t`, `!SELECT v FROM (SELECT ${lv} AS v) d WHERE v LIKE '%b%'`,
      `!SELECT * FROM (SELECT ${lv} AS v) a JOIN (SELECT ${lv} AS v) b ON a.v = b.v`,
    )
  }
  simple('lob-functions', fitems)

  stepped('lob-table', [
    ['table', ['CREATE TABLE dbo.lt (id int NOT NULL PRIMARY KEY, t text NULL, n ntext NULL, i image NULL, tc text COLLATE Latin1_General_BIN2 NULL)',
      "INSERT dbo.lt VALUES (1, 'abc', N'äbc', 0x0102, 'x'), (2, NULL, NULL, NULL, NULL), (3, REPLICATE('z', 10), N'ż', 0x, '')"], [
      'SELECT id, t, n, i, tc, DATALENGTH(t) AS dt, DATALENGTH(n) AS dn, DATALENGTH(i) AS di FROM dbo.lt ORDER BY id',
      "SELECT id FROM dbo.lt WHERE t LIKE 'a%' OR n LIKE N'ż' ORDER BY id",
      "UPDATE dbo.lt SET t = 'new', n = N'nn', i = 0xFF WHERE id = 2; SELECT id, t, n, i FROM dbo.lt WHERE id = 2",
      "SELECT c.name, c.system_type_id, c.user_type_id, c.max_length, c.collation_name, c.is_nullable FROM sys.columns c WHERE c.object_id = OBJECT_ID('dbo.lt') ORDER BY c.column_id",
      "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, CHARACTER_OCTET_LENGTH, COLLATION_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'lt' ORDER BY ORDINAL_POSITION",
      'SELECT id FROM dbo.lt ORDER BY t',
      'SELECT SUBSTRING(t, 2, 2) AS a, SUBSTRING(n, 1, 1) AS b, SUBSTRING(i, 1, 1) AS c, CHARINDEX(\'b\', t) AS d, PATINDEX(\'%b%\', n) AS e FROM dbo.lt WHERE id = 1',
      'SELECT CAST(t AS varchar(2)) AS a, CAST(n AS nvarchar(max)) AS b, CAST(i AS varbinary(1)) AS c, CAST(t AS nvarchar(10)) AS d FROM dbo.lt WHERE id = 1',
      'INSERT dbo.lt (id, t) VALUES (4, 5)', "INSERT dbo.lt (id, i) VALUES (5, N'abc')",
      'INSERT dbo.lt (id, t) SELECT 6, n FROM dbo.lt WHERE id = 1; SELECT id, t FROM dbo.lt WHERE id = 6',
      'CREATE INDEX ix_t ON dbo.lt (t)', 'CREATE TABLE dbo.lt3 (t text PRIMARY KEY)',
      "SELECT CONCAT(t, n) AS a, CONCAT_WS('-', t, 'x') AS b FROM dbo.lt WHERE id = 1",
      "SELECT ISNULL(t, 'none') AS a, COALESCE(n, N'none') AS b FROM dbo.lt ORDER BY id",
    ]],
  ])
}

// ---------------------------------------------------------- COMPRESS/DECOMPRESS
{
  const loop = (n, m) => `!DECLARE @s varchar(max) = '', @i bigint = 1; WHILE @i <= ${n} BEGIN SET @s = @s + CHAR(97 + ((@i * 2654435761) % 4294967296) / 65536 % ${m}); SET @i = @i + 1 END; SELECT COMPRESS(@s) AS v`
  const items = [
    loop(3000, 3), loop(4000, 6),
    "COMPRESS(REPLICATE(CAST('The quick brown fox jumps over the lazy dog. ' AS varchar(max)), 2000))",
    "COMPRESS(N'abc'), COMPRESS(0x), COMPRESS(CAST('' AS varchar(10))), COMPRESS(CAST(NULL AS varchar(10)))",
    'COMPRESS(1)', 'DECOMPRESS(N\'abc\')', "DECOMPRESS(CAST(0x1f8b08000000000004004b4c4a0600c241243503000000 AS varchar(max)))",
  ]
  const hello = '1f8b0800000000000400cb48cdc9c9070086a6103605000000'
  for (const [name, hex] of [
    ['no-trailer', hello.slice(0, -16)], ['crc-2-bytes', hello.slice(0, -12)], ['isize-1-byte', hello.slice(0, -6)],
    ['truncated-deflate', hello.slice(0, -18)], ['bad-crc-short-trailer', hello.slice(0, -16) + '00000000'],
    ['fname', '1f8b080800000000000376616d6500' + hello.slice(20)], ['fextra', '1f8b0804000000000003020061 62'.replace(' ', '') + hello.slice(20)],
    ['reserved-flag', '1f8b0820000000000003' + hello.slice(20)], ['bad-magic', '1f8c' + hello.slice(4)],
    ['zlib-wrapper', '789ccb48cdc9c90700062c0215'], ['raw-deflate', hello.slice(20, -16)],
    ['stored-block', '1f8b08000000000000030105' + '00faff' + '68656c6c6f' + hello.slice(-16)],
    ['bad-block-type', '1f8b08000000000000030700' + hello.slice(-16)], ['empty-member', '1f8b0800000000000003030000000000000000'],
    ['second-member-bad', hello + '1f8b07'],
  ]) items.push(`DECOMPRESS(0x${hex}) /* ${name} */`)
  simple('compress', items)
}

// --------------------------------------------------------------- CHECKSUM
{
  const digits = '(VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15))'
  const items = [
    `!SELECT a.d * 16 + b.d AS n, CHECKSUM(CHAR(a.d * 16 + b.d)) AS ci, CHECKSUM(CHAR(a.d * 16 + b.d) COLLATE SQL_Latin1_General_CP1_CS_AS) AS cs, CHECKSUM(CHAR(a.d * 16 + b.d) COLLATE Latin1_General_BIN2) AS bin, BINARY_CHECKSUM(CHAR(a.d * 16 + b.d)) AS bc FROM ${digits} a(d) CROSS JOIN ${digits} b(d) WHERE a.d * 16 + b.d > 0 ORDER BY n`,
    "CHECKSUM('ab') AS a, CHECKSUM('ba') AS b, CHECKSUM('abcdefghij') AS c, CHECKSUM('a ') AS d, CHECKSUM(' abc') AS e, CHECKSUM('a' + CHAR(0)) AS f",
    "BINARY_CHECKSUM('abc ') AS a, BINARY_CHECKSUM(N'abc ') AS b, BINARY_CHECKSUM(N'é') AS c, BINARY_CHECKSUM(NCHAR(0x1234)) AS d, BINARY_CHECKSUM(REPLICATE('ab', 100)) AS e, BINARY_CHECKSUM(0x616200) AS f, BINARY_CHECKSUM(0xC8) AS g, BINARY_CHECKSUM(CHAR(200)) AS h",
    'CHECKSUM(CAST(1.5 AS float)) AS a, CHECKSUM(CAST(1.5 AS real)) AS b, CHECKSUM(CAST(-1.5 AS float)) AS c, CHECKSUM(CAST(-0.0 AS float)) AS d, CHECKSUM(CAST(-1.5 AS money)) AS e, CHECKSUM(CAST(-1.5 AS smallmoney)) AS f, CHECKSUM(CAST(-1 AS smallint)) AS g',
    "CHECKSUM(CAST('03:04:05.123' AS time(3))) AS a, CHECKSUM(CAST('2024-01-02 03:04:05' AS datetime2(0))) AS b, CHECKSUM(CAST('2024-01-02 03:04:05.5 +01:00' AS datetimeoffset(1))) AS c, CHECKSUM(CAST('0001-01-01' AS date)) AS d, CHECKSUM(CAST('2024-01-02T03:04:05' AS smalldatetime)) AS e",
    "CHECKSUM(CAST(NULL AS int)) AS a, CHECKSUM(CAST(NULL AS int), 1) AS b, BINARY_CHECKSUM(1, NULL) AS c, CHECKSUM(0x616200) AS d, CHECKSUM(CHAR(200) COLLATE Latin1_General_BIN) AS e, CHECKSUM(N'abc' COLLATE Latin1_General_100_BIN2) AS f",
    "CHECKSUM(CHAR(233) COLLATE SQL_Latin1_General_CP1_CI_AI) AS v", 'CHECKSUM(CAST(1 AS decimal(10,2))) AS v', "CHECKSUM(N'abc') AS v",
  ]
  simple('checksum', items)
}

// ---------------------------------------------------- CURSOR_STATUS, COLUMNS_UPDATED
stepped('cursor-status', [
  ['missing', [], ["SELECT CURSOR_STATUS('global','nope') AS g, CURSOR_STATUS('local','nope') AS l, CURSOR_STATUS('variable','@nope') AS v"]],
  ['lifecycle', [], [
    "DECLARE c CURSOR FOR SELECT 1 AS x WHERE 1=0; SELECT CURSOR_STATUS('global','c') AS declared; OPEN c; SELECT CURSOR_STATUS('global','c') AS opened_empty, CURSOR_STATUS('local','c') AS l; CLOSE c; SELECT CURSOR_STATUS('global','c') AS closed; DEALLOCATE c; SELECT CURSOR_STATUS('global','c') AS deallocated",
    "DECLARE c4 CURSOR FOR SELECT 1 AS x; OPEN c4; SELECT CURSOR_STATUS('global','c4') AS default_open; DEALLOCATE c4",
    "DECLARE c3 CURSOR LOCAL FOR SELECT 1 AS x; SELECT CURSOR_STATUS('local','c3') AS l, CURSOR_STATUS('global','c3') AS g; OPEN c3; SELECT CURSOR_STATUS('local','c3') AS l, CURSOR_STATUS('global','c3') AS g; DEALLOCATE c3",
  ]],
  ['errors', [], ["SELECT CURSOR_STATUS('bad','x') AS v", "SELECT CURSOR_STATUS('global', NULL) AS v", "SELECT CURSOR_STATUS('GLOBAL','x') AS a, CURSOR_STATUS(N'global',N'x') AS b"]],
])
stepped('columns-updated', [
  ['trigger', ['CREATE TABLE tcu (a int, b int, c int, d int, e int, f int, g int, h int, i int, j int)',
    'CREATE TABLE tcu_log (seq int IDENTITY, cu varbinary(10))',
    'CREATE TRIGGER tcu_t ON tcu AFTER INSERT, UPDATE, DELETE AS INSERT tcu_log (cu) SELECT COLUMNS_UPDATED()'], [
    'INSERT tcu (a) VALUES (1)', 'UPDATE tcu SET j = 2, a = 1', 'DELETE tcu', 'UPDATE tcu SET b = 1 WHERE 1 = 0',
    'SELECT seq, cu FROM tcu_log ORDER BY seq', 'SELECT COLUMNS_UPDATED() AS outside',
  ]],
])
