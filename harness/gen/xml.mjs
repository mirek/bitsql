// Generates corpus/xml/*.cases.json: FOR XML (PATH/RAW/AUTO, subqueries),
// the xml data type (conversions, wire, operators) and its methods
// (value/query/exist/nodes). One case per batch so the differential report
// stays granular. Expected output is captured from the oracle
// (npm run capture -- xml).
//
//   node gen/xml.mjs     (rewrites the .cases.json files; recapture changed
//                         cases with --force, deleting the file's
//                         expected.json first when inserting cases mid-list)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'xml')
mkdirSync(outDir, { recursive: true })

const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60)

// Each entry: a SQL batch (string) or { name?, steps: [{kind, sql, params?}] }.
function family(file, entries) {
  const cases = []
  const seen = new Set()
  for (const e of entries) {
    const steps = typeof e === 'string' ? [{ kind: 'batch', sql: e }] : e.steps
    const first = steps.find(s => s.kind !== 'setup')?.sql ?? steps[0].sql
    let name = `${String(cases.length).padStart(3, '0')}-${slug(e.name ?? first)}`
    while (seen.has(name)) name += 'x'
    seen.add(name)
    cases.push({ name, steps: steps.map(s => s.kind === 'setup' ? { kind: 'batch', sql: s.sql, compare: false } : s) })
  }
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/xml.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

const V3 = "(VALUES (1, N'a&b'), (2, N'<c>'), (3, N'd')) v(id, name)"
const T = `DECLARE @t TABLE (id int, grp int, name nvarchar(10));
INSERT @t VALUES (1, 1, N'a'), (2, 1, N'b&'), (3, 2, N'c'), (4, 2, NULL);
`

// ------------------------------------------------ FOR XML in subqueries
family('subquery', [
  `SELECT STUFF((SELECT ',' + name FROM ${V3} FOR XML PATH('')), 1, 1, '') AS names`,
  `SELECT (SELECT ',' + name FROM ${V3} FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)') AS n`,
  `SELECT STUFF((SELECT ',' + name FROM ${V3} FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '') AS n`,
  `SELECT (SELECT name FROM ${V3} FOR XML PATH('')) AS x`,
  `SELECT (SELECT name FROM ${V3} FOR XML PATH(''), TYPE) AS x`,
  `SELECT (SELECT name AS [text()] FROM ${V3} FOR XML PATH('')) AS x`,
  `SELECT (SELECT id, name FROM ${V3} FOR XML PATH('row')) AS x`,
  `SELECT (SELECT id AS [@id], name FROM ${V3} FOR XML PATH('item'), ROOT('items'), TYPE) AS x`,
  `SELECT (SELECT id, name FROM ${V3} FOR XML RAW) AS a, (SELECT id, name FROM ${V3} FOR XML RAW, TYPE) AS b`,
  `SELECT (SELECT id, name FROM ${V3} FOR XML AUTO) AS a, (SELECT id, name FROM ${V3} FOR XML AUTO, ELEMENTS) AS b`,
  T + `SELECT grp, STUFF((SELECT N', ' + name FROM @t i WHERE i.grp = o.grp ORDER BY id DESC FOR XML PATH('')), 1, 2, N'') AS names FROM @t o GROUP BY grp ORDER BY grp`,
  T + `SELECT o.grp, (SELECT i.name AS [text()] FROM @t i WHERE i.grp = o.grp ORDER BY i.id FOR XML PATH('n'), TYPE) AS names FROM (SELECT DISTINCT grp FROM @t) o ORDER BY o.grp`,
  T + `SELECT (SELECT name + ',' FROM @t ORDER BY id FOR XML PATH('')) AS v1, (SELECT ISNULL(name, '?') + ',' FROM @t ORDER BY id FOR XML PATH('')) AS v2`,
  T + `DECLARE @s nvarchar(max) = (SELECT ',' + name FROM @t ORDER BY id FOR XML PATH('')); SELECT @s AS s, LEN(@s) AS n`,
  T + `DECLARE @s nvarchar(max); SET @s = STUFF((SELECT ';' + CAST(id AS varchar(5)) FROM @t ORDER BY id FOR XML PATH('')), 1, 1, ''); SELECT @s AS s`,
  T + `DECLARE @x xml = (SELECT id, name FROM @t ORDER BY id FOR XML RAW, TYPE); SELECT @x AS x`,
  T + `DECLARE @x xml = (SELECT id, name FROM @t ORDER BY id FOR XML RAW); SELECT @x AS x`,
  `SELECT (SELECT x FROM (VALUES (1)) v(x) WHERE 1 = 0 FOR XML PATH('row')) AS r, (SELECT x FROM (VALUES (1)) v(x) WHERE 1 = 0 FOR XML PATH('row'), TYPE) AS t`,
  `SELECT (SELECT NULL AS x FOR XML PATH('')) AS a, (SELECT NULL AS x FOR XML PATH(''), TYPE) AS b, (SELECT '' AS x FOR XML PATH('')) AS c`,
  `SELECT (SELECT CAST(NULL AS nvarchar(5)) FOR XML PATH('')) AS a, (SELECT N'' FOR XML PATH('')) AS b`,
  `SELECT CAST((SELECT 1 AS a FOR XML RAW) AS xml) AS c, CONCAT('<', (SELECT 1 AS a FOR XML RAW), '>') AS d`,
  `SELECT (SELECT 1 AS a FOR XML RAW) + N'z' AS e`,
  `SELECT LEN((SELECT 1 AS a FOR XML RAW, TYPE)) AS n`,
  `SELECT (SELECT 1 AS a FOR XML RAW, TYPE) + N'z' AS e`,
  `SELECT CAST((SELECT 1 AS a FOR XML RAW, TYPE) AS nvarchar(max)) + N'z' AS f`,
  `SELECT 1 AS one WHERE EXISTS (SELECT 1 AS a FOR XML PATH)`,
  `SELECT x.c.value('(/r/a)[1]', 'int') AS v FROM (SELECT (SELECT 5 AS a FOR XML PATH('r'), TYPE) AS c) x`,
  `SELECT c FROM (SELECT (SELECT 5 AS a FOR XML PATH('r')) AS c) x`,
  `WITH c AS (SELECT 1 AS a FOR XML PATH) SELECT * FROM c`,
  `SELECT * FROM (SELECT 1 AS a FOR XML PATH) d`,
  `SELECT * FROM (SELECT 1 AS a FOR XML PATH) d(x)`,
  `SELECT * FROM (SELECT 1 AS a FOR XML PATH, TYPE) d(x)`,
  `SELECT (SELECT TOP 2 v FROM (VALUES (3),(1),(2)) t(v) ORDER BY v FOR XML PATH('')) AS x`,
  `SELECT (SELECT v FROM (VALUES (3),(1),(2)) t(v) ORDER BY v DESC FOR XML PATH('')) AS x`,
  `SELECT o.n AS [@n], (SELECT i.v AS [text()] FROM (VALUES (1, N'a<'), (1, N'b'), (2, N'c')) i(k, v) WHERE i.k = o.n FOR XML PATH('v'), TYPE) FROM (VALUES (1), (2)) o(n) FOR XML PATH('o'), ROOT('all')`,
  `SELECT o.n AS [@n], (SELECT i.v FROM (VALUES (1, N'a<')) i(k, v) WHERE i.k = o.n FOR XML PATH('v')) AS sub FROM (VALUES (1)) o(n) FOR XML PATH('o')`,
  `SELECT o.n AS [@n], (SELECT i.v FROM (VALUES (1, N'a<')) i(k, v) WHERE i.k = o.n FOR XML PATH('v'), TYPE) AS sub FROM (VALUES (1)) o(n) FOR XML PATH('o')`,
  `SELECT (SELECT 1 AS a FOR JSON PATH) AS j, (SELECT 1 AS a FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS k`,
  `SELECT (SELECT 1 AS a WHERE 1 = 0 FOR JSON PATH) AS j`,
  `SELECT (SELECT id, name FROM ${V3} FOR JSON PATH, ROOT('r')) AS j`,
  `SELECT JSON_VALUE((SELECT 1 AS a FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), '$.a') AS v`,
  `SELECT * FROM (SELECT 1 AS a FOR JSON PATH) d(j)`,
  `SELECT 1 AS a, (SELECT 2 AS b FOR JSON PATH) AS c FOR JSON PATH`,
  `SELECT STUFF((SELECT ',' + CAST(n AS varchar(10)) FROM (VALUES (1),(2),(3)) v(n) ORDER BY n FOR XML PATH(''), TYPE).value('(./text())[1]', 'varchar(max)'), 1, 1, '') AS s`,
  `SELECT (SELECT N'x' + NCHAR(13) + NCHAR(10) + N'y' + NCHAR(9) + N'"' + N'''' AS [text()] FOR XML PATH('')) AS a, (SELECT N'x' + NCHAR(13) + N'y' FOR XML PATH(''), TYPE).value('.', 'nvarchar(10)') AS b`,
])

// ------------------------------------------------ top-level FOR XML PATH
family('path', [
  `SELECT 1 AS a, N'x<&>"''y' AS b FOR XML PATH`,
  `SELECT 1 AS a, 2 FOR XML PATH`,
  `SELECT 1, 2, 'x' FOR XML PATH('')`,
  `SELECT 1 + 1, N'a' + N'b', CAST(3 AS int) FOR XML PATH('r')`,
  `SELECT 1 AS [@id], N'v' AS [a/b], N't' AS [text()], N'd' AS [data()] FOR XML PATH('row'), ROOT('root')`,
  `SELECT 1 AS [@id], N'v' AS [a/b], 2 AS [a/@c] FOR XML PATH('row')`,
  `SELECT 1 AS [@id], NULL AS [x], N'y' AS [z] FOR XML PATH('row'), ELEMENTS XSINIL`,
  `SELECT 1 AS [@id], NULL AS [x], N'y' AS [z] FOR XML PATH('row'), ELEMENTS XSINIL, ROOT('r')`,
  `SELECT NULL AS [x] FOR XML PATH('row')`,
  `SELECT NULL AS [x] FOR XML PATH('')`,
  `SELECT x FROM (VALUES (1)) v(x) WHERE 1 = 0 FOR XML PATH('row')`,
  `SELECT x FROM (VALUES (1)) v(x) WHERE 1 = 0 FOR XML PATH('row'), ROOT('r')`,
  `SELECT x FROM (VALUES (1)) v(x) WHERE 1 = 0 FOR XML PATH('row'), TYPE`,
  `SELECT CAST(1.50 AS decimal(5,2)) AS d, CAST(2.5 AS float) AS f, CAST(1.5 AS real) AS r, CAST(3 AS money) AS m, CAST(1 AS bit) AS b FOR XML PATH('r')`,
  `SELECT CAST('2020-01-02T03:04:05.1234567' AS datetime2) AS dt2, CAST('2020-01-02T03:04:05.123' AS datetime) AS dt, CAST('2020-01-02' AS date) AS dd, CAST('03:04:05' AS time) AS tt, CAST('2020-01-02T03:04:05+02:00' AS datetimeoffset) AS dto, CAST('2020-01-02T03:04:00' AS smalldatetime) AS sdt FOR XML PATH('r')`,
  `SELECT CAST('2020-01-02T03:04:05' AS datetime2) AS a, CAST('2020-01-02T03:04:05.5' AS datetime2(3)) AS b, CAST('03:04:05.120' AS time(3)) AS c, CAST('2020-01-02T03:04:05' AS datetime) AS d, CAST('2020-01-02T03:04:05.1' AS datetimeoffset(2)) AS e, CAST('2020-01-02T00:00:00' AS datetime) AS f FOR XML PATH('r')`,
  `SELECT CAST('2020-01-02T03:04:05.120' AS datetime) AS a, CAST('2020-01-02T03:04:05.1' AS datetime2(7)) AS b, CAST('2020-01-02T03:04:05-07:30' AS datetimeoffset(0)) AS c, CAST('00:00:00' AS time(0)) AS d FOR XML PATH('r')`,
  `SELECT CAST('6F9619FF-8B86-D011-B42D-00C04FC964FF' AS uniqueidentifier) AS g, CAST(-0.5 AS decimal(3,2)) AS d, CAST(255 AS tinyint) AS t, CAST(-3 AS smallmoney) AS m, CAST(-1e300 AS float) AS f, CAST(0 AS float) AS z FOR XML PATH('r')`,
  `SELECT 0x0102FF AS b FOR XML PATH('r')`,
  `SELECT 0x0102FF AS b FOR XML PATH('r'), BINARY BASE64`,
  `SELECT N'a' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'b' + NCHAR(1) + N'"' + N'''' + N'>' AS t FOR XML PATH('')`,
  `SELECT CAST('x ' AS char(3)) AS h, CAST(N'é' AS nvarchar(5)) AS i, CAST(N'🦆' AS nvarchar(5)) AS j FOR XML PATH('r')`,
  `SELECT 1 AS [my col] FOR XML PATH`,
  `SELECT 1 AS [a//b] FOR XML PATH`,
  `SELECT 1 AS [@a/b] FOR XML PATH`,
  `SELECT 1 AS [a/] FOR XML PATH`,
  `SELECT N'v' AS [a/b], N'w' AS [a/c], N'x' AS [d], N'y' AS [a/e] FOR XML PATH('r')`,
  `SELECT N'v' AS [a/b/c], N'w' AS [a/b/d], N'x' AS [a/e] FOR XML PATH('r')`,
  `SELECT N'a' AS [x], N'b' AS [x] FOR XML PATH('r')`,
  `SELECT N'a' AS [text()], N'b' AS [text()] FOR XML PATH('r')`,
  `SELECT N'a' AS [data()], N'b' AS [data()], 3 AS [data()] FOR XML PATH('r')`,
  `SELECT N'a' AS [data()], N'b' AS [text()], N'c' AS [data()] FOR XML PATH('r')`,
  `SELECT N'a' AS [data()], N'b' AS [x], N'c' AS [data()] FOR XML PATH('r')`,
  `SELECT 1 AS [x], 2 AS [@y] FOR XML PATH('r')`,
  `SELECT CAST(N'<q>1</q>' AS xml) AS [x], CAST(N'<q>2</q>' AS xml) AS [*], CAST(N'<q>3</q>' AS xml) FOR XML PATH('r')`,
  `SELECT CAST(N'<q>1</q>' AS xml) AS [@x] FOR XML PATH('r')`,
  `SELECT N'<z/>' AS [*], N'<y/>' AS [node()] FOR XML PATH('r')`,
  `SELECT 'a' AS [node()], 'b' AS [comment()], 'c' AS [processing-instruction(pi)] FOR XML PATH('r')`,
  `SELECT N'' AS [x], N'' AS [text()] FOR XML PATH('r')`,
  `SELECT N'' AS [x] FOR XML PATH('r'), TYPE`,
  `SELECT N'' AS [@y] FOR XML PATH('r')`,
  `SELECT N' ' AS [x], N'  ' AS [y] FOR XML PATH('r')`,
  `SELECT N' ' AS [x], N'  ' AS [y] FOR XML PATH('r'), TYPE`,
  `SELECT N'a' AS [x/text()], N'b' AS [x/@y] FOR XML PATH('r')`,
  `SELECT N'b' AS [x/@y], N'a' AS [x/text()], N'c' AS [x/z] FOR XML PATH('r')`,
  `SELECT N'a' AS [x], NULL AS [x/y], N'b' AS [z] FOR XML PATH('r'), ELEMENTS XSINIL`,
  `SELECT N'a' AS [a/b], NULL AS [a/c], N'b' AS [a/d] FOR XML PATH('r')`,
  `SELECT 1 AS [@a], 2 AS [@b] FOR XML PATH('')`,
  `SELECT 1 AS a FOR XML PATH, ELEMENTS`,
  `SELECT 1 AS a FOR XML PATH(''), ROOT('r')`,
  `SELECT 1 AS a FOR XML PATH, ROOT`,
  `SELECT 1 AS a FOR XML PATH('a b')`,
  `SELECT 1 AS a FOR XML PATH('a/b')`,
  `SELECT 1 AS a FOR XML PATH('r'), ROOT('x y')`,
  `SELECT 1 AS [x] UNION ALL SELECT 2 FOR XML PATH('r')`,
  `SELECT v AS [@v], v * 10 AS [w] FROM (VALUES (3), (1), (2)) t(v) ORDER BY v FOR XML PATH('r'), ROOT('all')`,
  `SELECT TOP 1 1 AS x FOR XML PATH('r') ORDER BY 1`,
  `SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) AS a FOR XML PATH('r')`,
  `SELECT REPLICATE(CAST(N'&' AS nvarchar(max)), 1000) AS a FOR XML PATH('r'), TYPE`,
  `SELECT 1 AS a FOR XML PATH('r'), TYPE`,
  `SELECT 1 AS a, (SELECT 2 AS b FOR XML PATH('i'), TYPE) AS c FOR XML PATH('r')`,
  `SELECT 1 AS a FOR XML PATH('r'), BINARY BASE64, TYPE, ROOT('x')`,
  `SELECT 1 AS a FOR XML PATH('r'), TYPE, TYPE`,
  `SELECT 1 AS a FOR XML PATH('r'), XMLSCHEMA`,
  `SELECT 1 AS a FOR XML PATH('r'), ELEMENTS ABSENT`,
  `SELECT 1 AS [x:y] FOR XML PATH('r')`,
  `SELECT 1 AS [_x] , 2 AS [x.y], 3 AS [x-y] FOR XML PATH('r')`,
  `SELECT CAST(1 AS sql_variant) AS a, CAST(N'x' AS sql_variant) AS b FOR XML PATH('r')`,
  `SELECT 1 AS [@id] FOR XML PATH('r'), ELEMENTS XSINIL`,
])

// ------------------------------------------------ RAW and AUTO
const P = `CREATE TABLE p (pid int, name nvarchar(5)); CREATE TABLE c (cid int, pid int, v nvarchar(5));
INSERT p VALUES (1, N'a'), (2, N'b'), (3, NULL); INSERT c VALUES (10, 1, N'x'), (11, 1, N'y'), (12, 2, N'z');`
family('raw-auto', [
  `SELECT * FROM (VALUES (1, N'a'), (2, NULL)) v(id, n) FOR XML RAW`,
  `SELECT * FROM (VALUES (1, N'a'), (2, NULL)) v(id, n) FOR XML RAW, ELEMENTS XSINIL, ROOT('r'), TYPE`,
  `SELECT * FROM (VALUES (1, N'a'), (2, NULL)) v(id, n) FOR XML RAW, ELEMENTS`,
  `SELECT * FROM (VALUES (1, N'a'), (2, NULL)) v(id, n) FOR XML RAW('item'), ROOT('items')`,
  `SELECT 1 AS a FOR XML RAW('item'), ROOT`,
  `SELECT 1 AS a FOR XML RAW('item'), ELEMENTS`,
  `SELECT 1 AS a, NULL AS b FOR XML RAW('item'), ELEMENTS ABSENT`,
  `SELECT 1 AS a FOR XML RAW(''), ROOT('')`,
  `SELECT 1 AS a FOR XML RAW(''), ELEMENTS`,
  `SELECT 1 AS a FOR XML RAW, ROOT('x y')`,
  `SELECT 1 AS a FOR XML RAW('a b')`,
  `SELECT 1 AS a, 2 AS a FOR XML RAW`,
  `SELECT 1 AS a, 2 AS A FOR XML RAW`,
  `SELECT 1 AS a, 2 AS a FOR XML RAW, ELEMENTS`,
  `SELECT 1, 2 FOR XML RAW`,
  `SELECT 1, 2 FOR XML RAW, ELEMENTS`,
  `SELECT 0x0102FF AS b FOR XML RAW`,
  `SELECT 0x0102FF AS b FOR XML RAW, BINARY BASE64`,
  `SELECT N'a' + NCHAR(13) + NCHAR(10) + NCHAR(9) + N'b' + N'"' + N'''' + N'>' + N'<&' AS t FOR XML RAW`,
  `SELECT N'x' + NCHAR(1) AS t FOR XML RAW`,
  `SELECT 1 AS [my col], 2 AS [a$b], 3 AS [1x], 4 AS [x:y], 5 AS [é], 6 AS [@z] FOR XML RAW`,
  `SELECT 1 AS [my col] FOR XML RAW, ELEMENTS`,
  `SELECT N'' AS [x] FOR XML RAW`,
  `SELECT N'' AS [x] FOR XML RAW, ELEMENTS`,
  `SELECT N'' AS [x] FOR XML RAW, ELEMENTS, TYPE`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS i, @x AS [x], 2 AS j, @x AS [@y] FOR XML RAW`,
  `DECLARE @x xml = N'<a/>'; SELECT @x AS [x] FOR XML RAW, ELEMENTS`,
  `SELECT CAST(1.5 AS float) AS f, CAST('2020-01-02T03:04:05' AS datetime) AS d, CAST(1 AS bit) AS b, CAST(2.25 AS money) AS m FOR XML RAW`,
  `SELECT 1 AS id FOR XML RAW, ELEMENTS XSINIL, ROOT('r')`,
  `SELECT (SELECT 1 AS id FOR XML RAW, ELEMENTS XSINIL, TYPE) AS x`,
  `SELECT 1 AS id, NULL AS n FOR XML RAW, XSINIL`,
  `SELECT a FROM (VALUES (1), (2), (3)) v(a) ORDER BY a DESC FOR XML RAW`,
  `SELECT a FROM (VALUES (1), (2)) v(a) WHERE a > 5 FOR XML RAW`,
  `SELECT a FROM (VALUES (1), (2)) v(a) WHERE a > 5 FOR XML RAW, ROOT('r')`,
  `SELECT 1 AS a FOR XML RAW, XMLSCHEMA`,
  `SELECT 1 AS a FOR XML RAW, XMLDATA`,
  `SELECT 1 AS a FOR XML EXPLICIT`,
  `SELECT 1 AS Tag, NULL AS Parent, 2 AS [x!1!id] FOR XML EXPLICIT`,
  `SELECT 1 AS a FOR XML AUTO`,
  `SELECT * FROM (VALUES (1, 2)) v(a, b) FOR XML AUTO`,
  `SELECT * FROM (VALUES (1, 2)) v(a, b) FOR XML AUTO, ELEMENTS`,
  `SELECT 1 AS x INTO #xt; SELECT * FROM #xt FOR XML AUTO; SELECT x FROM #xt AS t FOR XML AUTO, ELEMENTS; SELECT x, x+1 AS y FROM #xt FOR XML AUTO, ROOT('r'), TYPE`,
  `DECLARE @t TABLE (id int, name varchar(10)); INSERT @t VALUES (1, 'a&'), (2, 'b'); SELECT * FROM @t FOR XML AUTO; SELECT id FROM @t AS q FOR XML AUTO('x')`,
  { steps: [{ kind: 'setup', sql: 'CREATE TABLE dbo.tt (id int, v nvarchar(5)); INSERT dbo.tt VALUES (1, N\'a\'), (2, NULL);' },
    { kind: 'batch', sql: 'SELECT * FROM dbo.tt FOR XML AUTO; SELECT * FROM dbo.tt x FOR XML AUTO; SELECT tt.id, tt.v FROM dbo.tt FOR XML AUTO, ELEMENTS; SELECT id + 1 AS n, id FROM dbo.tt FOR XML AUTO; SELECT * FROM tt FOR XML AUTO, ELEMENTS XSINIL; SELECT * FROM [tt] FOR XML AUTO' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT p.pid, p.name, c.cid, c.v FROM p JOIN c ON c.pid = p.pid ORDER BY p.pid, c.cid FOR XML AUTO' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT p.pid, c.cid FROM p LEFT JOIN c ON c.pid = p.pid ORDER BY p.pid, c.cid FOR XML AUTO, ELEMENTS' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT c.cid, p.pid FROM p JOIN c ON c.pid = p.pid ORDER BY c.cid FOR XML AUTO' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT p.pid, c.cid, p.name FROM p JOIN c ON c.pid = p.pid ORDER BY c.cid FOR XML AUTO, ROOT(\'r\')' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT name, (SELECT cid FROM c WHERE c.pid = p.pid FOR XML AUTO, TYPE) AS kids FROM p ORDER BY pid FOR XML AUTO' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT pid, COUNT(*) AS n FROM c GROUP BY pid ORDER BY pid FOR XML AUTO' }] },
  { steps: [{ kind: 'setup', sql: P }, { kind: 'batch', sql: 'SELECT * FROM p ORDER BY pid FOR XML RAW, ELEMENTS XSINIL' }] },
])

// ------------------------------------------------ the xml type
family('type', [
  `SELECT CAST(N'<a/>' AS xml) AS x, CAST(NULL AS xml) AS y`,
  `SELECT CAST(N'<?xml version="1.0"?><a><!-- c --><b x=''1'' y="2&quot;&apos;">t&lt;&gt;&amp;&#65;&#x42;</b><![CDATA[<cd>]]><?pi data?></a>' AS xml) AS x`,
  `SELECT CAST(N'  <a>  x  <b> </b>  </a>  ' AS xml) AS a, CONVERT(xml, N'<a>  x  <b> </b>  </a>', 1) AS b, CONVERT(xml, N'<a> <b/> </a>', 0) AS c`,
  `SELECT CAST(N'text only' AS xml) AS a, CAST(N'' AS xml) AS b, CAST(N'<a/><b/>text' AS xml) AS c`,
  `SELECT CAST(N'<a xmlns="urn:x" xmlns:p="urn:p"><p:b p:c="1"/></a>' AS xml) AS x`,
  `SELECT CAST(N'<a>&#x0D;&#13;' + NCHAR(13) + NCHAR(10) + N'</a>' AS xml) AS a, CAST(N'<a b="&#x0D;&#x09;x' + NCHAR(9) + N'y' + NCHAR(10) + N'"/>' AS xml) AS b`,
  `SELECT CAST(N'<a b="&lt;&gt;&amp;''"/>' AS xml) AS a, CAST(N'<a>"''</a>' AS xml) AS b, CAST(N'<a b=''"''/>' AS xml) AS c`,
  `SELECT CAST(N'<a>' AS xml) AS x`,
  `SELECT CAST(N'<a></b>' AS xml) AS x`,
  `SELECT CAST(N'<a b=1/>' AS xml) AS x`,
  `SELECT CAST(N'<a>&foo;</a>' AS xml) AS x`,
  `SELECT CAST(N'<a b="1" b="2"/>' AS xml) AS x`,
  `SELECT CAST(N'<a>' + NCHAR(10) + N'<b>' + NCHAR(10) + N'</a>' AS xml) AS x`,
  `SELECT CAST(N'<p:a/>' AS xml) AS x`,
  `SELECT CAST(N'<a/>junk<' AS xml) AS x`,
  `SELECT CAST(N'<a><!-- x -- y --></a>' AS xml) AS x`,
  `SELECT CAST('<a>é</a>' AS xml) AS a, CAST(0x3C613E783C2F613E AS xml) AS b, CAST(0xFFFE3C0061003E0078003C002F0061003E00 AS xml) AS c`,
  `SELECT CAST(CAST(N'<a>x</a>' AS xml) AS varbinary(max)) AS b`,
  `SELECT CAST(CAST(N'<a>x</a>' AS xml) AS varchar(20)) AS v, CONVERT(nvarchar(max), CAST(N'<a>x</a>' AS xml), 1) AS n, CAST(CAST(N'<a>é</a>' AS xml) AS varchar(max)) AS e`,
  `SELECT CAST(CAST(N'<a>x</a>' AS xml) AS nvarchar(5)) AS x`,
  `SELECT CAST(CAST(N'<a>x</a>' AS xml) AS nvarchar(8)) AS x, CAST(CAST(N'<a>x</a>' AS xml) AS char(10)) AS y`,
  `SELECT CAST(CAST(N'<a>1</a>' AS xml) AS int) AS x`,
  `SELECT CAST(1 AS xml) AS x`,
  `SELECT CAST(GETDATE() AS xml) AS x`,
  `SELECT TRY_CAST(N'<a>' AS xml) AS x`,
  `SELECT TRY_CONVERT(xml, N'<a/>') AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT CASE WHEN @x = @x THEN 1 END AS c`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x <> N'<a/>'`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x = N'<a/>'`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x > @x`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x LIKE N'<a/>'`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x IN (@x)`,
  `DECLARE @x xml = N'<a/>'; SELECT 1 AS one WHERE @x IS NOT NULL`,
  `DECLARE @x xml = N'<a/>'; DECLARE @s nvarchar(max) = @x; SELECT @s AS s`,
  `DECLARE @x xml = N'<a/>'; DECLARE @v varchar(10) = @x; SELECT @v AS v`,
  `DECLARE @x xml = N'<a/>'; DECLARE @i int = @x`,
  `DECLARE @x xml = 5`,
  `DECLARE @x xml = 0x3C612F3E; SELECT @x AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT @x + N'z' AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT @x + @x AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT CONCAT(@x, N'z') AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT LEN(@x) AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT UPPER(@x) AS x`,
  `DECLARE @x xml = N'<a/>'; SELECT ISNULL(@x, N'<z/>') AS a, COALESCE(@x, N'<y/>') AS b, CASE WHEN 1=1 THEN @x ELSE N'<q/>' END AS c, IIF(@x IS NULL, 1, 0) AS e`,
  `DECLARE @x xml; SELECT ISNULL(@x, N'<z/>') AS a, COALESCE(@x, N'<y/>') AS b, @x AS c`,
  `DECLARE @x xml = N'<a/>'; SELECT DATALENGTH(@x) AS d`,
  `DECLARE @x xml = N'<r/>'; SELECT @x AS x ORDER BY @x`,
  `DECLARE @t TABLE (d xml); SELECT d FROM @t ORDER BY d`,
  `DECLARE @t TABLE (d xml); SELECT DISTINCT d FROM @t`,
  `DECLARE @t TABLE (d xml); SELECT d FROM @t GROUP BY d`,
  `DECLARE @t TABLE (d xml); SELECT d FROM @t UNION SELECT d FROM @t`,
  `DECLARE @t TABLE (d xml); SELECT d FROM @t UNION ALL SELECT d FROM @t`,
  `DECLARE @t TABLE (d xml); SELECT MAX(d) AS m FROM @t`,
  `DECLARE @t TABLE (d xml); SELECT COUNT(d) AS n, COUNT(*) AS m FROM @t`,
  `DECLARE @x xml = N'<a/>'; SELECT CAST(@x AS sql_variant) AS v`,
  `SELECT CAST(N'<a>' + REPLICATE(N'x', 3000) + N'</a>' AS xml) AS big`,
  `SELECT CAST(REPLICATE(CAST(N'<a>xyz</a>' AS nvarchar(max)), 2000) AS xml) AS big`,
  { steps: [{ kind: 'batch', sql: `CREATE TABLE #t (id int, d xml NULL); INSERT #t VALUES (1, N'<a>1</a>'), (2, '<b/>'); INSERT #t SELECT 3, CAST(N'<c/>' AS xml); INSERT #t (id) VALUES (4); SELECT * FROM #t ORDER BY id; UPDATE #t SET d = N'<z/>' WHERE id = 2; SELECT d FROM #t WHERE d.exist('/z') = 1` }] },
  { steps: [{ kind: 'batch', sql: `CREATE TABLE dbo.xt (id int NOT NULL PRIMARY KEY, doc xml NOT NULL); INSERT dbo.xt VALUES (1, N'<r><i>1</i></r>'); SELECT id, doc FROM dbo.xt; SELECT name, system_type_id, user_type_id, max_length, precision, scale, collation_name, is_nullable FROM sys.columns WHERE object_id = OBJECT_ID('dbo.xt') ORDER BY column_id; SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, CHARACTER_OCTET_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'xt' AND COLUMN_NAME = 'doc'` }] },
  { steps: [{ kind: 'batch', sql: `CREATE TABLE dbo.xt2 (id int, doc xml); INSERT dbo.xt2 VALUES (1, N'<a>'); SELECT COUNT(*) AS n FROM dbo.xt2` }] },
  { steps: [{ kind: 'batch', sql: `CREATE TABLE dbo.xt3 (id int, doc xml DEFAULT N'<d/>'); INSERT dbo.xt3 (id) VALUES (1); SELECT id, doc FROM dbo.xt3; SELECT id, doc INTO #copy FROM dbo.xt3; SELECT doc FROM #copy` }] },
  `SELECT name, system_type_id, user_type_id, max_length, precision, scale, collation_name, is_nullable FROM sys.types WHERE name = 'xml'`,
  `DECLARE @x xml = N'<a/>'; SELECT SQL_VARIANT_PROPERTY(@x, 'BaseType') AS b`,
  `SELECT CAST(N'<a/>' AS xml(CONTENT)) AS x`,
  `DECLARE @x xml = N'<a/>'; PRINT CAST(@x AS nvarchar(max)); PRINT @x`,
  `SELECT CAST(N'<a>' + NCHAR(1) + N'</a>' AS xml) AS x`,
  `SELECT CAST(N'<a>&#1;</a>' AS xml) AS x`,
  `SELECT CAST(N'<!DOCTYPE a><a/>' AS xml) AS x`,
  `SELECT CAST(N'<?xml version="1.0" encoding="utf-8"?><a/>' AS xml) AS x`,
  `SELECT CAST(N'<a xml:space="preserve"> <b> </b> </a>' AS xml) AS x`,
  `SELECT CAST(N'<a>x</a>' AS xml).value('.', 'nvarchar(5)') AS v`,
])

// ------------------------------------------------ methods
const X = `DECLARE @x xml = N'<r><i n="1">a</i><i n="2">b</i><i n="3"><j>c</j></i></r>';
`
family('methods', [
  `DECLARE @x xml = N'<a b="1"><c>t1</c><c>t2</c></a>'; SELECT @x AS x, @x.value('(/a/c)[2]', 'nvarchar(10)') AS v, @x.value('(/a/@b)[1]', 'int') AS b, @x.exist('/a/c') AS e, @x.query('/a/c') AS q`,
  X + `SELECT @x.value('(/r/i)[1]', 'varchar(10)') AS v1, @x.value('(/r/i/@n)[3]', 'int') AS v2, @x.value('(/r/i[@n="2"])[1]', 'nvarchar(10)') AS v3, @x.value('(//j)[1]', 'nvarchar(10)') AS v4, @x.value('(/r/i[3]/j/text())[1]', 'nvarchar(10)') AS v5`,
  X + `SELECT @x.value('count(/r/i)', 'int') AS v6, @x.value('(/r/i)[9]', 'int') AS v7, @x.value('.', 'nvarchar(max)') AS v8, @x.value('(/r/i/@n)[1]', 'decimal(5,2)') AS v9`,
  X + `SELECT @x.value('(/r/i[@n=2])[1]', 'varchar(5)') AS a, @x.value('(/r/i[@n>1])[1]', 'varchar(5)') AS b, @x.value('(/r/i[last()])[1]', 'varchar(5)') AS c, @x.value('(/r/*)[2]', 'varchar(5)') AS d, @x.value('(/r/i/@*)[2]', 'varchar(5)') AS e`,
  X + `SELECT @x.value('local-name((/r/*)[1])', 'varchar(5)') AS f, @x.value('string((/r/i)[1])', 'varchar(5)') AS g, @x.value('(/r/i[. = "b"]/@n)[1]', 'int') AS h, @x.value('(r/i)[1]', 'varchar(5)') AS i, @x.value('(/r/i)[1]/@n', 'int') AS j`,
  X + `SELECT @x.value('/r[1]/i[1]/@n', 'int') AS a, @x.value('(/r/i[@n != "1"])[1]', 'varchar(5)') AS b, @x.value('(/r/i[@n >= 2 and @n < 3])[1]', 'varchar(5)') AS c, @x.value('(/r/i[@n = 1 or @n = 3])[2]', 'varchar(5)') AS d`,
  X + `SELECT @x.value('(/r/i[j])[1]/@n', 'int') AS a, @x.value('(/r/i[j = "c"])[1]/@n', 'int') AS b, @x.value('(/r/i[not(j)])[2]', 'varchar(5)') AS c, @x.value('(/r/i[position() = 2])[1]', 'varchar(5)') AS d`,
  X + `SELECT @x.value('(/r/i/j/..)[1]/@n', 'int') AS a, @x.value('(//i)[2]', 'varchar(5)') AS b, @x.value('(/r//text())[3]', 'varchar(5)') AS c, @x.value('(/*/*)[1]', 'varchar(5)') AS d, @x.value('name((/r/i)[1])', 'varchar(5)') AS e`,
  X + `SELECT @x.value('(/r/i)[1]', 'nvarchar(max)') AS a, @x.value('(/r/i)[1]', 'varchar(max)') AS b, @x.value('(/r/i/@n)[1]', 'bigint') AS c, @x.value('(/r/i/@n)[1]', 'float') AS d, @x.value('(/r/i/@n)[1]', 'bit') AS e`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('/r/i', 'varchar(5)') AS v`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT @x.value('/r/i/@n', 'int') AS v`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('/r/i[1]', 'varchar(5)') AS v`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('(/r/i)[1]', 'xml') AS v`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('(/r/i)[1]', 'sql_variant') AS v`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('(/r/i)[1]', 'text') AS v`,
  `DECLARE @x xml = N'<r><i>a</i><i>b</i></r>'; SELECT @x.value('(/r/i)[1]', 'nosuchtype') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; SELECT @x.value('(/r/i)[1]', 'int') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; SELECT @x.VALUE('(/r/i)[1]', 'int') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; SELECT @x.value('(/r/i[)[1]', 'int') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; DECLARE @p nvarchar(20) = N'(/r/i)[1]'; SELECT @x.value(@p, 'int') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; SELECT @x.value('(/r/i)[1]') AS v`,
  `DECLARE @x xml = N'<r><i>a</i></r>'; SELECT @x.nosuch('x') AS v`,
  `DECLARE @x xml; SELECT @x.value('(/r/i)[1]', 'int') AS v, @x.exist('/r') AS e, @x.query('/r') AS q`,
  `DECLARE @i int = 1; SELECT @i.value('.', 'int') AS v`,
  `DECLARE @s nvarchar(10) = N'<a/>'; SELECT @s.value('.', 'int') AS v`,
  `DECLARE @x xml = N'<r><i n="1">a</i><i n="2">b</i></r>'; SELECT @x.query('/r/i[@n="2"]') AS q1, @x.query('/r/i/text()') AS q2, @x.query('/r/x') AS q3, @x.query('.') AS q4, @x.exist('/r/i[@n="2"]') AS e1, @x.exist('/r/z') AS e2`,
  `DECLARE @x xml = N'<r><i n="1">a</i><i n="2">b</i></r>'; SELECT @x.query('data(/r/i/@n)') AS q5, @x.query('string(/r[1])') AS q6, @x.query('/r/i[1]/node()') AS q7`,
  `DECLARE @x xml = N'<a b="1">t</a>'; SELECT @x.query('/a/@b') AS q`,
  `DECLARE @x xml = N'<r><i n="1">a</i><i n="2">b</i></r>'; SELECT T.c.value('@n', 'int') AS n, T.c.value('.', 'nvarchar(10)') AS v, T.c.query('.') AS q FROM @x.nodes('/r/i') AS T(c)`,
  `DECLARE @x xml = N'<r><i n="1">a</i><i n="2">b</i></r>'; SELECT T.c.value('(../i)[1]', 'nvarchar(10)') AS first, T.c.value('local-name(.)', 'nvarchar(10)') AS name, T.c.exist('.[@n = 2]') AS two FROM @x.nodes('/r/i') AS T(c)`,
  `DECLARE @t TABLE (id int, doc xml); INSERT @t VALUES (1, N'<r><i>x</i><i>y</i></r>'), (2, N'<r/>'), (3, NULL);
SELECT t.id, n.c.value('.', 'varchar(5)') AS v FROM @t t CROSS APPLY t.doc.nodes('/r/i') n(c) ORDER BY t.id, v;
SELECT t.id, n.c.value('.', 'varchar(5)') AS v FROM @t t OUTER APPLY t.doc.nodes('/r/i') n(c) ORDER BY t.id, v;
SELECT id, doc.value('(/r/i)[1]', 'varchar(5)') AS a, doc.exist('/r/i') AS e, t.doc.query('/r/i[2]') AS q FROM @t t ORDER BY id`,
  `DECLARE @t TABLE (id int, doc xml); INSERT @t VALUES (1, N'<r><i>x</i></r>'), (2, N'<r/>'); SELECT id FROM @t WHERE doc.exist('/r/i') = 1; SELECT id FROM @t WHERE doc.value('(/r/i)[1]', 'varchar(5)') IS NULL`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT T.c FROM @x.nodes('/r/i') T(c)`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT 1 AS one FROM @x.nodes('/r/i') T(c) WHERE T.c IS NOT NULL`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT T.c.value('.', 'int') AS v FROM @x.nodes('/r/i') T`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT x.y.value('.', 'varchar(5)') AS v FROM @x.nodes('/r/i/@n') x(y)`,
  `DECLARE @x xml = N'<r><i n="1">a</i><i n="2"><j>b</j><j>c</j></i></r>'; SELECT i.c.value('@n', 'int') AS n, j.c.value('.', 'varchar(5)') AS v FROM @x.nodes('/r/i') i(c) CROSS APPLY i.c.nodes('j') j(c)`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT @x.exist('/r/i[@n="1"]') AS a, @x.exist('/r/i[@n="9"]') AS b, @x.exist('/r/i/@n') AS c, @x.exist('/r/i/@m') AS d`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT @x.value('sum(/r/i/@n)', 'int') AS v`,
  `DECLARE @x xml = N'<r><i n="1">a</i></r>'; DECLARE @v int = 1; SELECT @x.value('(/r/i[@n=sql:variable("@v")])[1]', 'varchar(5)') AS v`,
  `DECLARE @x xml = N'<a xmlns="urn:x"><b>1</b></a>'; SELECT @x.value('(/a/b)[1]', 'int') AS plain`,
  `DECLARE @x xml = N'<a xmlns="urn:x"><b>1</b></a>'; SELECT @x.value('declare default element namespace "urn:x"; (/a/b)[1]', 'int') AS ns`,
  `DECLARE @x xml = N'<a xmlns:p="urn:p"><p:b>1</p:b><b>2</b></a>'; SELECT @x.value('(/a/b)[1]', 'int') AS v, @x.value('(/a/*)[1]', 'int') AS w, @x.value('local-name((/a/*)[1])', 'varchar(5)') AS n`,
  `DECLARE @x xml = N'<a><b>1</b><b>2</b></a>'; SELECT @x.value('(/a/b)[1] + 1', 'int') AS v`,
  `DECLARE @x xml = N'<a><b> 1 </b></a>'; SELECT @x.value('(/a/b)[1]', 'int') AS i, @x.value('(/a/b)[1]', 'varchar(9)') AS v, @x.value('(/a/b)[1]', 'bit') AS bt`,
  `DECLARE @x xml = N'<a><b>true</b><d>1.5e0</d><e>12.50</e></a>'; SELECT @x.value('(/a/b)[1]', 'bit') AS b, @x.value('(/a/d)[1]', 'float') AS d, @x.value('(/a/e)[1]', 'decimal(5,1)') AS e, @x.value('(/a/e)[1]', 'money') AS m`,
  `DECLARE @x xml = N'<a><c>2020-01-02T03:04:05</c><d>2020-01-02</d></a>'; SELECT @x.value('(/a/c)[1]', 'datetime2') AS c, @x.value('(/a/d)[1]', 'date') AS d, @x.value('(/a/c)[1]', 'datetime') AS c3`,
  `DECLARE @x xml = N'<a>x&amp;y<b>&lt;z&gt;</b><!--c--><?p d?></a>'; SELECT @x.value('(/a)[1]', 'varchar(20)') AS a, @x.value('(/a/text())[1]', 'varchar(20)') AS b, @x.query('/a/b') AS c, @x.query('/a/comment()') AS d`,
  `DECLARE @x xml = N'<a><b>12345</b></a>'; SELECT @x.value('(/a/b)[1]', 'varchar(3)') AS v, @x.value('(/a/b)[1]', 'tinyint') AS t`,
  `DECLARE @x xml = N'<a><b>12345</b></a>'; SELECT @x.value('(/a/b)[1]', 'tinyint') AS t`,
  `SELECT CAST(N'<a><b>1</b></a>' AS xml).value('(/a/b)[1]', 'int') AS v, CAST(N'<a><b>1</b></a>' AS xml).exist('/a') AS e`,
  `SELECT (SELECT 1 AS b FOR XML PATH('a'), TYPE).value('(/a/b)[1]', 'int') AS v, (SELECT 1 AS b FOR XML PATH('a'), TYPE).query('/a/b') AS q`,
  `DECLARE @x xml = N'<r><i n="1"/><i n="2"/></r>'; SELECT SUM(T.c.value('@n', 'int')) AS s, COUNT(*) AS n FROM @x.nodes('/r/i') T(c)`,
  `DECLARE @x xml = N'<r><i n="1"/><i n="2"/></r>'; SELECT T.c.value('@n', 'int') AS n FROM @x.nodes('/r/i') T(c) ORDER BY T.c.value('@n', 'int') DESC`,
  `DECLARE @x xml = N'<r/>'; SELECT @x.value('(/r/@missing)[1]', 'int') AS a, @x.value('(/r/text())[1]', 'varchar(5)') AS b, @x.value('(/r)[1]', 'varchar(5)') AS c`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.value('(/r/i)[1]', 'nvarchar(5)') AS v FROM (VALUES (1), (2)) t(n)`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.value('(/r/i)[1]', 'int') + 1 AS v, UPPER(@x.value('local-name(/*[1])', 'varchar(5)')) AS n`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.exist('/r/i[. = 1]') AS a, @x.exist('/r/i[. = "1"]') AS b, @x.exist('/r/i[. > 0]') AS c`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.value('(/r/i)[1]', 'int') AS v WHERE @x.exist('/r') = 1`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.modify('delete /r/i')`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SET @x.modify('delete /r/i'); SELECT @x AS x`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.value('(/r/i)[1] cast as xs:int?', 'int') AS v`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.query('for $i in /r/i return $i') AS q`,
  `DECLARE @x xml = N'<r><i>1</i></r>'; SELECT @x.value('(/r/i)[1]', 'nvarchar(5)') AS v, @x.value('(/r/i)[1]', 'nchar(3)') AS w`,
])

// ------------------------------------------------ RPC and procedures
family('rpc', [
  { steps: [{ kind: 'rpc', sql: 'DECLARE @x xml = @p; SELECT @x AS x, @x.value(\'(/a/b)[1]\', \'int\') AS v', params: [{ name: '@p', type: 'nvarchar(max)', value: '<a><b>7</b></a>' }] }] },
  { steps: [{ kind: 'rpc', sql: 'SELECT CAST(@p AS xml) AS x', params: [{ name: '@p', type: 'nvarchar(50)', value: '<a>' }] }] },
  { steps: [{ kind: 'rpc', sql: 'SELECT (SELECT n FROM (VALUES (1), (2)) v(n) WHERE n >= @m FOR XML PATH(\'\')) AS s', params: [{ name: '@m', type: 'int', value: 1 }] }] },
  { steps: [{ kind: 'rpc', sql: 'SELECT n FROM (VALUES (1), (2)) v(n) WHERE n >= @m FOR XML RAW', params: [{ name: '@m', type: 'int', value: 1 }] }] },
  { steps: [{ kind: 'rpc', sql: 'SELECT n FROM (VALUES (1), (2)) v(n) WHERE n >= @m FOR XML RAW, TYPE', params: [{ name: '@m', type: 'int', value: 1 }] }] },
  { steps: [
    { kind: 'setup', sql: 'CREATE PROCEDURE dbo.px @d xml, @n int OUTPUT AS BEGIN SET @n = @d.value(\'count(/r/i)\', \'int\'); SELECT @d AS d; END' },
    { kind: 'proc', sql: 'dbo.px', params: [{ name: '@d', type: 'nvarchar(max)', value: '<r><i/><i/></r>' }, { name: '@n', type: 'int', output: true }] }] },
  { steps: [
    { kind: 'setup', sql: 'CREATE PROCEDURE dbo.py AS SELECT 1 AS a FOR XML PATH(\'r\')' },
    { kind: 'proc', sql: 'dbo.py' }] },
  { steps: [{ kind: 'batch', sql: 'EXEC sp_executesql N\'SELECT @x.value(\'\'(/a)[1]\'\', \'\'int\'\') AS v\', N\'@x xml\', @x = N\'<a>5</a>\'' }] },
])

// ------------------------------------------------ app-style mixes
const ORD = `CREATE TABLE dbo.cust (id int NOT NULL PRIMARY KEY, name nvarchar(20) NOT NULL);
CREATE TABLE dbo.ord (id int NOT NULL PRIMARY KEY, cust_id int NOT NULL, item nvarchar(20) NULL, qty int NOT NULL);
INSERT dbo.cust VALUES (1, N'Ann & Co'), (2, N'Bob'), (3, N'Cy');
INSERT dbo.ord VALUES (10, 1, N'pen', 2), (11, 1, N'ink <blue>', 1), (12, 2, NULL, 5), (13, 2, N'pad', 3);`
const app = sql => ({ steps: [{ kind: 'setup', sql: ORD }, { kind: 'batch', sql }] })
family('more', [
  app(`SELECT c.name, STUFF((SELECT ', ' + o.item FROM dbo.ord o WHERE o.cust_id = c.id ORDER BY o.id FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS items FROM dbo.cust c ORDER BY c.id`),
  app(`SELECT c.id AS [@id], c.name AS [name], (SELECT o.id AS [@id], o.item AS [item], o.qty AS [qty] FROM dbo.ord o WHERE o.cust_id = c.id ORDER BY o.id FOR XML PATH('order'), TYPE) AS [orders] FROM dbo.cust c ORDER BY c.id FOR XML PATH('customer'), ROOT('customers')`),
  app(`SELECT c.id, c.name, o.id, o.item FROM dbo.cust c LEFT JOIN dbo.ord o ON o.cust_id = c.id ORDER BY c.id, o.id FOR XML AUTO`),
  app(`SELECT cust.id, cust.name, ord.item, ord.qty FROM dbo.cust cust JOIN dbo.ord ord ON ord.cust_id = cust.id ORDER BY cust.id, ord.id FOR XML AUTO, ELEMENTS, ROOT('r')`),
  app(`SELECT * FROM dbo.ord ORDER BY id FOR XML RAW('o'), ELEMENTS XSINIL, ROOT('orders')`),
  app(`SELECT cust_id, COUNT(*) AS n, SUM(qty) AS total FROM dbo.ord GROUP BY cust_id ORDER BY cust_id FOR XML PATH('c')`),
  app(`DECLARE @doc xml = (SELECT id AS [@id], item FROM dbo.ord ORDER BY id FOR XML PATH('o'), ROOT('all'), TYPE);
SELECT x.o.value('@id', 'int') AS id, x.o.value('(item/text())[1]', 'nvarchar(20)') AS item, x.o.exist('item') AS has_item FROM @doc.nodes('/all/o') x(o) ORDER BY id`),
  app(`DECLARE @doc xml = N'<ids><id>11</id><id>13</id><id>99</id></ids>';
SELECT o.id, o.item FROM dbo.ord o JOIN @doc.nodes('/ids/id') t(n) ON o.id = t.n.value('.', 'int') ORDER BY o.id`),
  app(`DECLARE @doc xml = N'<ids><id>11</id><id>13</id></ids>';
SELECT id FROM dbo.ord WHERE id IN (SELECT t.n.value('.', 'int') FROM @doc.nodes('/ids/id') t(n)) ORDER BY id`),
  app(`CREATE TABLE dbo.docs (id int NOT NULL PRIMARY KEY, body xml NULL);
INSERT dbo.docs (id, body) SELECT c.id, (SELECT o.item AS [@item], o.qty AS [@qty] FROM dbo.ord o WHERE o.cust_id = c.id ORDER BY o.id FOR XML RAW('line'), ROOT('order'), TYPE) FROM dbo.cust c;
SELECT id, body, body.value('count(/order/line)', 'int') AS lines, body.value('sum(/order/line/@qty)', 'int') AS qty FROM dbo.docs ORDER BY id`),
  app(`CREATE TABLE dbo.docs2 (id int NOT NULL PRIMARY KEY, body xml NULL);
INSERT dbo.docs2 VALUES (1, N'<a><b>1</b></a>'), (2, NULL);
UPDATE dbo.docs2 SET body = (SELECT id AS [@id] FROM dbo.ord WHERE cust_id = 2 ORDER BY id FOR XML PATH('o'), TYPE) WHERE id = 2;
SELECT id, body FROM dbo.docs2 ORDER BY id;
SELECT d.id, n.x.value('@id', 'int') AS oid FROM dbo.docs2 d CROSS APPLY d.body.nodes('/o') n(x) ORDER BY d.id, oid`),
  app(`SELECT d.id FROM (VALUES (1, CAST(N'<a k="x"/>' AS xml)), (2, CAST(N'<a k="y"/>' AS xml))) d(id, doc) WHERE d.doc.exist('/a[@k="y"]') = 1`),
  app(`DECLARE @k nvarchar(5) = N'y'; SELECT d.id FROM (VALUES (1, CAST(N'<a k="x"/>' AS xml)), (2, CAST(N'<a k="y"/>' AS xml))) d(id, doc) WHERE d.doc.exist('/a[@k=sql:variable("@k")]') = 1`),
  app(`SELECT o.id, d.doc.value('(/a/@k)[1]', 'nvarchar(5)') AS k FROM dbo.ord o CROSS APPLY (SELECT CAST(N'<a k="' + CAST(o.qty AS nvarchar(5)) + N'"/>' AS xml) AS doc) d WHERE d.doc.value('(/a/@k)[1]', 'int') > 2 ORDER BY o.id`),
  app(`SELECT ' ' + item FROM dbo.ord WHERE item IS NOT NULL ORDER BY id FOR XML PATH('')`),
  app(`SELECT (SELECT ' ' FOR XML PATH('')) AS a, (SELECT ' ' AS [text()] FOR XML PATH('')) AS b, (SELECT N' x ' FOR XML PATH('')) AS c`),
  app(`SELECT 1 AS a, NULL AS b FOR XML PATH(''), ELEMENTS XSINIL`),
  app(`SELECT 1 AS a, NULL AS b FOR XML PATH(''), ELEMENTS XSINIL, ROOT('r')`),
  app(`SELECT id, (SELECT qty FROM dbo.ord i WHERE i.id = o.id FOR XML RAW, TYPE) AS x FROM dbo.ord o ORDER BY id FOR XML RAW, ELEMENTS`),
  { steps: [{ kind: 'setup', sql: ORD }, { kind: 'batch', sql: `CREATE VIEW dbo.v_items AS SELECT c.id, (SELECT o.item + ';' FROM dbo.ord o WHERE o.cust_id = c.id ORDER BY o.id FOR XML PATH('')) AS items FROM dbo.cust c` }, { kind: 'batch', sql: 'SELECT id, items FROM dbo.v_items ORDER BY id' }] },
  app(`WITH x AS (SELECT (SELECT id AS [@id] FROM dbo.ord ORDER BY id FOR XML PATH('o'), TYPE) AS doc) SELECT n.o.value('@id', 'int') AS id FROM x CROSS APPLY x.doc.nodes('/o') n(o) ORDER BY id`),
  app(`SELECT REPLICATE(CAST(N'ab' AS nvarchar(max)), 1100) + NCHAR(55357) + NCHAR(56838) AS a FOR XML PATH('')`),
  app(`DECLARE @x xml = N'<r><i n="1"/><i n="2"/><i n="3"/></r>'; SELECT n.i.value('@n', 'int') AS n, n.i.value('count(../i)', 'int') AS c, n.i.value('local-name(..)', 'varchar(5)') AS p FROM @x.nodes('/r/i') n(i)`),
  app(`DECLARE @x xml = N'<r><i n="1"/><i n="2"/><i n="3"/></r>'; SELECT n.i.value('@n', 'int') AS n FROM @x.nodes('/r/i[@n >= 2]') n(i) ORDER BY n DESC`),
  app(`DECLARE @x xml = N'<r><i n="1">a</i></r>'; SELECT @x.value('(/r/i/@n)[1]', 'nvarchar(10)') + @x.value('(/r/i)[1]', 'nvarchar(10)') AS v, LEN(@x.value('(/r/i)[1]', 'nvarchar(10)')) AS l, CAST(@x AS nvarchar(max)) AS t`),
  app(`DECLARE @x xml = N'<r/>'; SELECT @x.query('/r') AS a, @x.query('/r/*') AS b, @x.value('string(/r[1])', 'nvarchar(5)') AS c, @x.exist('/') AS d`),
  app(`DECLARE @x xml; SET @x = (SELECT TOP 2 id, item FROM dbo.ord ORDER BY id FOR XML RAW, TYPE); SELECT @x AS x; SET @x = NULL; SELECT @x AS y, CAST(@x AS nvarchar(10)) AS z`),
  app(`DECLARE @t TABLE (d xml); INSERT @t SELECT (SELECT id FROM dbo.ord ORDER BY id FOR XML PATH, TYPE); SELECT d FROM @t`),
  app(`SELECT CONVERT(nvarchar(max), (SELECT id, item FROM dbo.ord ORDER BY id FOR XML PATH('o'), TYPE)) AS t, CAST((SELECT item FROM dbo.ord ORDER BY id FOR XML PATH('')) AS xml) AS x`),
])
