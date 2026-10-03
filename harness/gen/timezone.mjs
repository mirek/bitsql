// Generates corpus/timezone/at-time-zone.cases.json: AT TIME ZONE argument
// types, result metadata, name matching, range edges, DST gaps/overlaps in
// several hemispheres, and sys.time_zone_info. Expected output is captured
// from the oracle (npm run capture -- timezone).
//
//   node gen/timezone.mjs   (then recapture changed cases with --force)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'timezone')
mkdirSync(outDir, { recursive: true })
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60)

const cases = []
function add(label, sql) {
  cases.push({ name: `${String(cases.length).padStart(3, '0')}-${slug(label)}`, steps: [{ kind: 'batch', sql }] })
}
// value plus its text (tedious drops the offset and sub-ms digits)
const show = e => `SELECT ${e} AS v, CONVERT(nvarchar(40), ${e}) AS t`

// argument types and result metadata
for (const [label, e] of [
  ['datetime2(0)', "CAST('2024-07-01T12:34:56' AS datetime2(0))"],
  ['datetime2(3)', "CAST('2024-07-01T12:34:56.789' AS datetime2(3))"],
  ['datetime2(5)', "CAST('2024-07-01T12:34:56.78901' AS datetime2(5))"],
  ['datetime', "CAST('2024-07-01T12:34:56.997' AS datetime)"],
  ['smalldatetime', "CAST('2024-07-01T12:34:29' AS smalldatetime)"],
  ['datetimeoffset(0)', "CAST('2024-07-01T12:34:56+05:30' AS datetimeoffset(0))"],
  ['datetimeoffset(4)', "CAST('2024-07-01T12:34:56.1234-03:00' AS datetimeoffset(4))"],
]) add(`type ${label}`, show(`${e} AT TIME ZONE 'Central European Standard Time'`))
for (const t of ['date', 'time', 'varchar(30)', 'nvarchar(30)', 'sql_variant']) {
  add(`bad arg1 ${t}`, `SELECT CAST('2024-01-01' AS ${t}) AT TIME ZONE 'UTC' AS v`)
}
add('bad arg1 float', "SELECT CAST(1 AS float) AT TIME ZONE 'UTC' AS v")
add('bad arg1 bit', "SELECT CAST(1 AS bit) AT TIME ZONE 'UTC' AS v")
add('bad arg1 binary', "SELECT CAST(0x01 AS varbinary(8)) AT TIME ZONE 'UTC' AS v")
add('bad arg2 int', "SELECT CAST('2024-01-01' AS datetime2) AT TIME ZONE 5 AS v")
add('bad arg2 sql_variant', "SELECT CAST('2024-01-01' AS datetime2) AT TIME ZONE CAST(N'UTC' AS sql_variant) AS v")
add('bad arg2 datetime', "SELECT CAST('2024-01-01' AS datetime2) AT TIME ZONE GETDATE() AS v")
add('null input', "SELECT NULL AT TIME ZONE 'UTC' AS v")
add('null zone', "SELECT CAST('2024-01-01' AS datetime2(2)) AT TIME ZONE NULL AS v")
add('null both', "SELECT NULL AT TIME ZONE NULL AS v")

// zone expressions
add('varchar zone', show("CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE CAST('Tokyo Standard Time' AS varchar(40))"))
add('char zone padded', "SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE CAST('UTC' AS char(10)) AS v")
add('nchar zone exact', show("CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE CAST(N'UTC' AS nchar(3))"))
add('variable zone', `DECLARE @z nvarchar(max) = N'india standard time'; ${show("CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE @z")}`)
add('long invalid zone', `DECLARE @z nvarchar(max) = REPLICATE(N'x', 300); SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE @z AS v`)
add('kelvin sign', "SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE N'Kamchatka Standard Time' AS v")
add('dotless i', "SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE N'Pacıfic Standard Time' AS v")
add('multiple nuls', `SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE (N'Tokyo' + NCHAR(0) + NCHAR(0) + N' Standard Time' + NCHAR(0)) AS v`)
add('nul in invalid message', "SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE (NCHAR(0) + N'x' + NCHAR(0)) AS v")
add('binds tighter than plus', "SELECT CAST('2024-01-01' AS datetime2(0)) AT TIME ZONE N'U' + N'TC' AS v")
add('zone from column', `SELECT z, CONVERT(nvarchar(40), CAST('2024-01-15T12:00:00' AS datetime2(0)) AT TIME ZONE z) AS t FROM (VALUES (N'UTC'), (N'Nepal Standard Time'), (N'Chatham Islands Standard Time'), (N'Line Islands Standard Time'), (N'Dateline Standard Time')) v(z) ORDER BY z`)
add('invalid zone midway', `SELECT z, CONVERT(nvarchar(40), CAST('2024-01-15T12:00:00' AS datetime2(0)) AT TIME ZONE z) AS t FROM (VALUES (N'UTC'), (N'nope'), (N'Utc')) v(z) ORDER BY z`)
add('in where clause', "SELECT COUNT(*) AS n FROM (VALUES (1), (2)) v(k) WHERE CAST('2024-01-15' AS datetime2) AT TIME ZONE 'UTC' > '2024-01-01'")

// range edges
add('dto clamp max scale 7', show("CAST('9999-12-31T20:00:00+00:00' AS datetimeoffset(7)) AT TIME ZONE 'Tokyo Standard Time'"))
add('dto clamp max scale 3', show("CAST('9999-12-31T15:00:00+00:00' AS datetimeoffset(3)) AT TIME ZONE 'Tokyo Standard Time'"))
add('dto clamp max scale 0', show("CAST('9999-12-31T15:00:00+00:00' AS datetimeoffset(0)) AT TIME ZONE 'Tokyo Standard Time'"))
add('dto last local', show("CAST('9999-12-31T14:59:59.9999999+00:00' AS datetimeoffset(7)) AT TIME ZONE 'Tokyo Standard Time'"))
add('dto clamp min', show("CAST('0001-01-01T07:59:59+00:00' AS datetimeoffset(7)) AT TIME ZONE 'Pacific Standard Time'"))
add('dto first local', show("CAST('0001-01-01T08:00:00+00:00' AS datetimeoffset(7)) AT TIME ZONE 'Pacific Standard Time'"))
add('local overflow low', "SELECT CAST('0001-01-01T08:59:59' AS datetime2(0)) AT TIME ZONE 'Tokyo Standard Time' AS v")
add('local low ok', show("CAST('0001-01-01T09:00:00' AS datetime2(0)) AT TIME ZONE 'Tokyo Standard Time'"))
add('local overflow high', "SELECT CAST('9999-12-31T16:00:00' AS datetime2(0)) AT TIME ZONE 'Pacific Standard Time' AS v")
add('local high ok', show("CAST('9999-12-31T15:59:59' AS datetime2(0)) AT TIME ZONE 'Pacific Standard Time'"))
add('year 1 dst zone', show("CAST('0001-07-01T12:00:00' AS datetime2(0)) AT TIME ZONE 'Pacific Standard Time'"))
add('year 9999 dst zone', show("CAST('9999-07-01T12:00:00' AS datetime2(0)) AT TIME ZONE 'AUS Eastern Standard Time'"))

// gaps and overlaps: [zone, local times]
const wall = [
  ['AUS Eastern Standard Time', ['2024-04-07T01:59:59', '2024-04-07T02:00:00', '2024-04-07T02:30:00', '2024-04-07T03:00:00', '2024-10-06T01:59:59', '2024-10-06T02:00:00', '2024-10-06T02:30:00', '2024-10-06T03:00:00']],
  ['Lord Howe Standard Time', ['2024-04-07T01:30:00', '2024-04-07T01:45:00', '2024-04-07T02:00:00', '2024-10-06T02:00:00', '2024-10-06T02:15:00', '2024-10-06T02:30:00']],
  ['Chatham Islands Standard Time', ['2024-04-07T02:45:00', '2024-04-07T03:15:00', '2024-09-29T02:45:00', '2024-09-29T03:15:00', '2024-09-29T03:45:00']],
  ['Morocco Standard Time', ['2024-03-10T02:30:00', '2024-03-10T03:30:00', '2024-04-14T01:30:00', '2024-04-14T02:30:00', '2030-01-01T00:00:00', '2050-06-01T00:00:00']],
  ['Iran Standard Time', ['2000-03-21T00:30:00', '2000-09-21T23:30:00', '2024-03-21T00:30:00']],
  ['Samoa Standard Time', ['2011-12-29T12:00:00', '2011-12-30T12:00:00', '2011-12-31T12:00:00']],
  ['Russian Standard Time', ['2011-03-27T02:30:00', '2014-10-26T01:30:00', '2010-10-31T02:30:00']],
  ['Pacific Standard Time', ['1970-04-26T02:30:00', '1990-04-01T02:30:00', '2006-10-29T01:30:00', '2007-03-11T02:30:00', '2007-11-04T01:30:00']],
  ['Paraguay Standard Time', ['2024-03-23T23:30:00', '2024-03-24T00:00:00', '2024-10-06T00:30:00']],
  ['Cuba Standard Time', ['2024-03-10T00:30:00', '2024-11-03T00:30:00']],
  ['Greenland Standard Time', ['2023-03-25T21:30:00', '2023-10-28T21:30:00', '2024-03-30T21:30:00']],
  ['Egypt Standard Time', ['2023-04-28T00:30:00', '2023-10-26T23:30:00', '2014-07-01T00:00:00']],
]
for (const [zone, locals] of wall) {
  add(`wall ${zone}`, `SELECT l, CONVERT(nvarchar(40), CAST(l AS datetime2(7)) AT TIME ZONE '${zone}') AS t, ` +
    `CONVERT(nvarchar(40), SWITCHOFFSET(CAST(l AS datetime2(7)) AT TIME ZONE '${zone}', 0)) AS u ` +
    `FROM (VALUES ${locals.map(l => `('${l}')`).join(', ')}) v(l) ORDER BY l`)
}
// instants around transitions (datetimeoffset input)
add('instants pacific 2024', `SELECT u, CONVERT(nvarchar(40), CAST(u AS datetimeoffset(7)) AT TIME ZONE 'Pacific Standard Time') AS t FROM (VALUES ` +
  "('2024-03-10T09:59:59.9999999+00:00'), ('2024-03-10T10:00:00+00:00'), ('2024-11-03T08:59:59.9999999+00:00'), ('2024-11-03T09:00:00+00:00')) v(u) ORDER BY u")
add('chained zones', show("CAST('2024-03-31T02:30:00' AS datetime2(0)) AT TIME ZONE 'GMT Standard Time' AT TIME ZONE 'Tokyo Standard Time'"))
add('datepart tzoffset', "SELECT DATEPART(TZOFFSET, CAST('2024-07-01' AS datetime2) AT TIME ZONE 'Newfoundland Standard Time') AS o, DATEPART(TZOFFSET, CAST('2024-01-01' AS datetime2) AT TIME ZONE 'Newfoundland Standard Time') AS w")

// sys.time_zone_info (values depend on the clock: compare only stable facts)
add('catalog names', 'SELECT name FROM sys.time_zone_info')
add('catalog metadata', 'SELECT TOP (0) * FROM sys.time_zone_info')
// the server clock (UTC here) is read as a wall-clock time in each zone
add('catalog consistent with at time zone', "SELECT COUNT(*) AS n, SUM(CASE WHEN current_utc_offset = RIGHT(CONVERT(nvarchar(40), SYSDATETIME() AT TIME ZONE name), 6) THEN 1 ELSE 0 END) AS same FROM sys.time_zone_info")
add('catalog dst bit of zones without dst', "SELECT COUNT(*) AS n FROM sys.time_zone_info WHERE is_currently_dst = 1 AND name IN (N'UTC', N'Tokyo Standard Time', N'India Standard Time', N'China Standard Time', N'Arabian Standard Time')")
add('catalog lookup by name', "SELECT name, LEN(current_utc_offset) AS l FROM sys.time_zone_info WHERE name = N'utc'")

writeFileSync(join(outDir, 'at-time-zone.cases.json'), formatJson({ source: 'harness/gen/timezone.mjs', cases }) + '\n')
console.log(`at-time-zone: ${cases.length} cases`)
