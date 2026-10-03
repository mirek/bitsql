// Generates corpus/functions/*.cases.json: table-free SELECTs over scalar
// built-in functions (date/time, string, math, logic, hashing). One case per
// small group of expressions so the differential report stays granular.
// Expected output is captured from the oracle (npm run capture -- functions).
//
//   node gen/functions.mjs     (rewrites the .cases.json files; recapture
//                               changed cases with --force)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'functions')
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
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/functions.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

// ---------------------------------------------------------------- date/time
const D = "CAST('2024-01-31' AS date)"
const DT = "CAST('2024-01-31 13:45:30.997' AS datetime)"
const SDT = "CAST('2024-01-31 13:45:00' AS smalldatetime)"
const DT2 = "CAST('2024-01-31 13:45:30.1234567' AS datetime2)"
const DT23 = "CAST('2024-01-31 13:45:30.123' AS datetime2(3))"
const DTO = "CAST('2024-01-31 13:45:30.1234567 +05:30' AS datetimeoffset)"
const T = "CAST('13:45:30.1234567' AS time)"
const T0 = "CAST('13:45:30' AS time(0))"
const typed = { date: D, datetime: DT, smalldatetime: SDT, datetime2: DT2, datetime2_3: DT23, datetimeoffset: DTO, time: T }
const dto = e => [e, `CAST(${e} AS nvarchar(40))`]
const parts = ['year', 'quarter', 'month', 'dayofyear', 'day', 'week', 'weekday', 'hour', 'minute', 'second', 'millisecond', 'microsecond', 'nanosecond']
const abbrevs = ['yy', 'yyyy', 'qq', 'q', 'mm', 'm', 'dy', 'y', 'dd', 'd', 'wk', 'ww', 'dw', 'w', 'hh', 'mi', 'n', 'ss', 's', 'ms', 'mcs', 'ns']

const date = []
// DATEADD: every part on every type (errors are their own cases)
for (const [tn, v] of Object.entries(typed)) {
  for (const p of parts) {
    const e = `DATEADD(${p}, 1, ${v})`
    date.push(['datetimeoffset', 'datetime2', 'datetime2_3', 'time'].includes(tn) ? dto(e) : [e])
  }
}
for (const a of abbrevs) date.push([`DATEADD(${a}, 2, ${DT2})`])
date.push(
  [`DATEADD(month, 1, '2024-01-31')`, `DATEADD(day, 1, '2024-01-31')`, `DATEADD(day, 1, N'2024-01-31 10:00')`],
  [`DATEADD(month, 1, CAST('2023-01-31' AS date))`, `DATEADD(month, -1, CAST('2024-03-31' AS date))`, `DATEADD(year, 1, CAST('2024-02-29' AS date))`],
  [`DATEADD(day, 2.9, ${D})`, `DATEADD(day, -2.9, ${D})`, `DATEADD(day, CAST(3 AS bigint), ${D})`, `DATEADD(day, CAST(2 AS tinyint), ${D})`],
  [`DATEADD(day, NULL, ${D})`],
  [`DATEADD(day, 1, CAST(NULL AS date))`, `DATEADD(day, 1, NULL)`],
  [`DATEADD(day, '3', ${D})`],
  [`DATEADD(millisecond, 1, ${DT})`, `DATEADD(millisecond, 2, ${DT})`, `DATEADD(millisecond, 3, CAST('2024-01-01 00:00:00.000' AS datetime))`],
  [`DATEADD(second, 29, ${SDT})`, `DATEADD(second, 30, ${SDT})`, `DATEADD(minute, 1, ${SDT})`],
  ...[49, 50, 150, -150, 51, -49, -51].map(n => dto(`DATEADD(nanosecond, ${n}, ${DT2})`)),
  dto(`DATEADD(microsecond, 1, ${DT23})`), dto(`DATEADD(nanosecond, 100, CAST('2024-01-01' AS datetime2(0)))`), dto(`DATEADD(millisecond, 500, CAST('2024-01-01' AS datetime2(0)))`), dto(`DATEADD(millisecond, 499, CAST('2024-01-01' AS datetime2(0)))`),
  [`DATEADD(hour, 13, ${T})`, `DATEADD(minute, -900, ${T0})`, `DATEADD(second, 86400, ${T0})`],
  [`DATEADD(day, 1, CAST('9999-12-31' AS date))`],
  [`DATEADD(year, -1, CAST('0001-06-01' AS date))`],
  [`DATEADD(day, 1, CAST('9999-12-31 10:00' AS datetime2))`],
  [`DATEADD(year, 1, CAST('9999-01-01' AS datetime))`],
  [`DATEADD(day, 2147483647, ${D})`],
  [`DATEADD(day, 2147483648, ${D})`],
  [`DATEADD(hour, 1, ${D})`],
  [`DATEADD(minute, 1, ${D})`],
  [`DATEADD(day, 1, ${T})`],
  [`DATEADD(year, 1, ${T})`],
  [`DATEADD(microsecond, 1, ${DT})`],
  [`DATEADD(nanosecond, 1, ${SDT})`],
  [`DATEADD(fortnight, 1, ${D})`],
  [`DATEADD(day, 1, 5)`],
  [`DATEADD(day, 1, 'notadate')`],
  [`DATEADD(day, 1, 1.5)`],
  [`DATEADD(day, 1, CAST(1 AS float))`],
  [`DATEADD(day, 1, 0x00)`],
  [`DATEADD(tzoffset, 1, ${DTO})`],
  [`DATEADD(iso_week, 1, ${D})`],
  [`DATEADD(day, 1, ${DTO})`, `CAST(DATEADD(hour, -20, ${DTO}) AS nvarchar(40))`],
)
// DATEDIFF / DATEDIFF_BIG
const pairs = [
  ["'2023-12-31'", "'2024-01-01'"],
  ["'2024-01-01 23:59:59.997'", "'2024-01-02'"],
  [`CAST('2024-01-06' AS date)`, `CAST('2024-01-07' AS date)`],
  [`CAST('2024-01-07' AS date)`, `CAST('2024-01-13' AS date)`],
  [`CAST('2000-02-29 12:00' AS datetime2)`, `CAST('2024-02-28 11:00' AS datetime2)`],
  [`CAST('2024-01-01 00:00:00.0000001' AS datetime2)`, `CAST('2024-01-01 00:00:00.0000009' AS datetime2)`],
  [`${DTO}`, `CAST('2024-01-31 08:15:30.1234567 +00:00' AS datetimeoffset)`],
  [`CAST('2024-01-31 23:30 -02:00' AS datetimeoffset)`, `CAST('2024-02-01 00:30 +00:00' AS datetimeoffset)`],
  [`${T}`, `CAST('01:02:03' AS time)`],
  [`${D}`, `${DT}`],
  [`${D}`, `${DTO}`],
  [`${SDT}`, `${DT2}`],
]
for (const [a, b] of pairs) {
  for (const p of ['year', 'quarter', 'month', 'dayofyear', 'day', 'week', 'iso_week', 'hour', 'minute', 'second', 'millisecond', 'weekday']) {
    date.push([`DATEDIFF(${p}, ${a}, ${b})`])
  }
}
date.push(
  [`DATEDIFF(microsecond, ${DT2}, DATEADD(microsecond, 1234, ${DT2}))`, `DATEDIFF(nanosecond, ${DT2}, DATEADD(nanosecond, 1200, ${DT2}))`],
  [`DATEDIFF(second, '1900-01-01', '2024-01-01')`, `DATEDIFF(minute, '0001-01-01', '9999-12-31')`],
  [`DATEDIFF(millisecond, '1900-01-01', '2024-01-01')`],
  [`DATEDIFF(nanosecond, '2024-01-01', '2024-01-02')`],
  [`DATEDIFF_BIG(millisecond, '1900-01-01', '2024-01-01')`, `DATEDIFF_BIG(nanosecond, '2024-01-01', '2024-01-02')`, `DATEDIFF_BIG(day, '2024-01-01', '2024-01-02')`],
  [`DATEDIFF_BIG(nanosecond, CAST('0001-01-01' AS datetime2), CAST('9999-12-31' AS datetime2))`],
  [`DATEDIFF(day, NULL, '2024-01-01')`, `DATEDIFF(day, '2024-01-01', NULL)`, `DATEDIFF(day, CAST(NULL AS date), ${D})`],
  [`DATEDIFF(day, 0, '2024-01-01')`, `DATEDIFF(day, 1, 2)`, `DATEDIFF(hour, 0.5, 1)`],
  [`DATEDIFF(dd, '2024-01-01', '2024-03-01')`, `DATEDIFF(mm, '2024-01-31', '2024-02-01')`, `DATEDIFF(yy, '2024-12-31', '2025-01-01')`, `DATEDIFF(wk, '2024-01-06', '2024-01-07')`],
  [`DATEDIFF(tzoffset, ${DTO}, ${DTO})`],
  [`DATEDIFF(fortnight, '2024-01-01', '2024-01-02')`],
  [`DATEDIFF(day, 'x', '2024-01-01')`],
  [`DATEDIFF(hour, ${D}, ${T})`, `DATEDIFF(day, ${T}, ${D})`],
  [`DATEDIFF(day, '13:00', ${T})`],
)
// DATEPART / DATENAME / YEAR / MONTH / DAY
const partsAll = [...parts, 'iso_week', 'tzoffset']
for (const [tn, v] of Object.entries(typed)) {
  for (const p of partsAll) date.push([`DATEPART(${p}, ${v})`])
  for (const p of partsAll) date.push([`DATENAME(${p}, ${v})`])
}
for (const a of [...abbrevs, 'isowk', 'isoww', 'tz']) date.push([`DATEPART(${a}, ${DTO})`, `DATENAME(${a}, ${DTO})`])
date.push(
  [`DATEPART(year, '2024-07-04')`, `DATEPART(month, N'2024-07-04')`, `DATEPART(weekday, '2024-07-04')`, `DATENAME(weekday, '2024-07-04')`, `DATENAME(month, '2024-07-04')`],
  ...['2024-01-01', '2024-12-29', '2024-12-30', '2024-12-31', '2021-01-01', '2021-01-03', '2021-01-04', '2020-12-31', '2027-01-01', '2026-12-31'].map(d =>
    [`DATEPART(week, '${d}')`, `DATEPART(iso_week, '${d}')`, `DATEPART(weekday, '${d}')`, `DATEPART(dayofyear, '${d}')`, `DATENAME(weekday, '${d}')`]),
  ...['2024-01-01', '2024-02-01', '2024-03-01', '2024-04-01', '2024-05-01', '2024-06-01', '2024-07-01', '2024-08-01', '2024-09-01', '2024-10-01', '2024-11-01', '2024-12-01'].map(d =>
    [`DATENAME(month, '${d}')`, `DATENAME(weekday, '${d}')`, `DATENAME(quarter, '${d}')`]),
  [`DATEPART(day, NULL)`, `DATENAME(day, NULL)`, `DATEPART(year, CAST(NULL AS datetime2))`],
  [`DATEPART(year, 0)`, `DATEPART(day, 45000)`, `DATENAME(month, 1)`],
  [`DATEPART(hour, '2024-01-01T10:20:30')`, `DATEPART(minute, '10:20:30')`, `DATEPART(nanosecond, '10:20:30.1234567')`],
  [`DATEPART(year, ${T})`],
  [`DATEPART(hour, ${D})`],
  [`DATEPART(tzoffset, ${DT2})`],
  [`DATEPART(fortnight, ${D})`],
  [`DATEPART(day, 'garbage')`],
  [`DATENAME(year, ${T})`],
  [`YEAR(${D})`, `MONTH(${D})`, `DAY(${D})`],
  [`YEAR(${DTO})`, `MONTH(${DT})`, `DAY(${SDT})`, `YEAR(${DT2})`],
  [`YEAR('2024-05-06')`, `MONTH('2024-05-06')`, `DAY(N'2024-05-06')`],
  [`YEAR(NULL)`, `MONTH(CAST(NULL AS date))`, `DAY(NULL)`],
  [`YEAR(0)`, `MONTH(40)`, `DAY(45000)`],
  [`YEAR(${T})`, `MONTH(${T})`, `DAY(${T})`],
  [`YEAR('x')`],
  [`YEAR(1.5)`],
  [`EOMONTH(${D})`, `EOMONTH(${DT})`, `EOMONTH('2024-02-10')`],
  [`EOMONTH(${D}, 1)`, `EOMONTH(${D}, -1)`, `EOMONTH(${DT2}, 12)`, `EOMONTH(${DTO}, 0)`],
  [`EOMONTH(NULL)`, `EOMONTH(${D}, NULL)`],
  [`EOMONTH('2023-02-15')`, `EOMONTH('2000-02-15')`, `EOMONTH('1900-02-15')`, `EOMONTH('2024-12-31')`],
  [`EOMONTH(CAST('9999-12-01' AS date), 1)`],
  [`EOMONTH(${T})`],
  [`EOMONTH(${D}, 1.7)`],
  [`EOMONTH(${D}, '2')`],
  [`DATEFROMPARTS(2024, 2, 29)`, `DATEFROMPARTS(1, 1, 1)`, `DATEFROMPARTS(9999, 12, 31)`],
  [`DATEFROMPARTS(2024, NULL, 1)`, `DATEFROMPARTS(NULL, NULL, NULL)`],
  [`DATEFROMPARTS(2023, 2, 29)`],
  [`DATEFROMPARTS(2024, 13, 1)`],
  [`DATEFROMPARTS(0, 1, 1)`],
  [`DATEFROMPARTS(2024.9, '2', 3)`],
  [`DATEFROMPARTS(2024, 1)`],
  [`DATETIMEFROMPARTS(2024, 2, 29, 23, 59, 59, 997)`, `DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 0)`],
  [`DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 998)`],
  [`DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 999)`],
  [`DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 1)`, `DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 2)`, `DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, 5)`],
  [`DATETIMEFROMPARTS(1752, 12, 31, 0, 0, 0, 0)`],
  [`DATETIMEFROMPARTS(2024, 1, 1, 24, 0, 0, 0)`],
  [`DATETIMEFROMPARTS(2024, 1, 1, 0, 0, 0, NULL)`],
  [`DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 6, 7)`, `DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 6, 1)`, `DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 0, 0)`],
  [`DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 123, 3)`, `DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 1234567, 7)`],
  [`DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 10, 1)`],
  [`DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 6, 8)`],
  [`DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 6, NULL)`],
  [`!DECLARE @p int = 3; SELECT DATETIME2FROMPARTS(2024, 1, 2, 3, 4, 5, 6, @p) AS c0`],
  [`DATETIME2FROMPARTS(2024, 1, NULL, 3, 4, 5, 6, 2)`],
  [`SMALLDATETIMEFROMPARTS(2024, 1, 2, 3, 4)`, `SMALLDATETIMEFROMPARTS(2079, 6, 6, 23, 59)`],
  [`SMALLDATETIMEFROMPARTS(2079, 6, 7, 0, 0)`],
  [`TIMEFROMPARTS(23, 59, 59, 9999999, 7)`, `TIMEFROMPARTS(1, 2, 3, 4, 1)`, `TIMEFROMPARTS(1, 2, 3, 0, 0)`],
  [`TIMEFROMPARTS(1, 2, 3, 50, 2)`, `TIMEFROMPARTS(NULL, 2, 3, 0, 0)`],
  [`TIMEFROMPARTS(24, 0, 0, 0, 0)`],
  [`TIMEFROMPARTS(1, 2, 3, 10, 1)`],
  dto(`DATETIMEOFFSETFROMPARTS(2024, 1, 2, 3, 4, 5, 6, 7, 30, 1)`),
  dto(`DATETIMEOFFSETFROMPARTS(2024, 1, 2, 3, 4, 5, 6, -7, -30, 7)`),
  dto(`DATETIMEOFFSETFROMPARTS(2024, 1, 2, 3, 4, 5, 0, 14, 0, 0)`),
  [`DATETIMEOFFSETFROMPARTS(2024, 1, 2, 3, 4, 5, 0, 15, 0, 0)`],
  [`DATETIMEOFFSETFROMPARTS(2024, 1, 2, 3, 4, 5, 0, 1, -30, 0)`],
  dto(`TODATETIMEOFFSET(${DT2}, '+05:00')`),
  dto(`TODATETIMEOFFSET(${DT2}, -120)`),
  dto(`TODATETIMEOFFSET(${D}, '-08:00')`),
  dto(`TODATETIMEOFFSET(${DT}, 0)`),
  dto(`TODATETIMEOFFSET('2024-01-02 03:04:05', '+01:00')`),
  dto(`TODATETIMEOFFSET(${DTO}, '+01:00')`),
  dto(`TODATETIMEOFFSET(${DT23}, N'+14:00')`),
  [`TODATETIMEOFFSET(${DT2}, '+15:00')`],
  [`TODATETIMEOFFSET(${DT2}, 'x')`],
  [`TODATETIMEOFFSET(${DT2}, NULL)`, `TODATETIMEOFFSET(NULL, '+01:00')`],
  [`TODATETIMEOFFSET(${T}, 0)`],
  dto(`SWITCHOFFSET(${DTO}, '-05:00')`),
  dto(`SWITCHOFFSET(${DTO}, 60)`),
  dto(`SWITCHOFFSET(${DT2}, '+01:00')`),
  dto(`SWITCHOFFSET('2024-01-02 03:04:05 +02:00', '+00:00')`),
  dto(`SWITCHOFFSET(CAST('2024-01-02 03:04:05.12 +02:00' AS datetimeoffset(2)), '+00:00')`),
  [`SWITCHOFFSET(${DTO}, NULL)`, `SWITCHOFFSET(NULL, '+00:00')`],
  [`SWITCHOFFSET(${DTO}, '+14:01')`],
  [`SWITCHOFFSET(${D}, '+01:00')`],
  [`ISDATE('2024-01-31')`, `ISDATE('2024-02-30')`, `ISDATE('x')`, `ISDATE(NULL)`],
  [`ISDATE('2024-01-31 10:00:00.1234567')`, `ISDATE('2024-01-31 10:00:00.123')`, `ISDATE('1752-12-31')`, `ISDATE('17530101')`],
  [`ISDATE('10:00')`, `ISDATE('')`, `ISDATE('  2024-01-31  ')`, `ISDATE(N'Jan 5 2024')`],
  [`ISDATE(20240101)`],
  [`ISDATE(${D})`],
  [`ISDATE('2024-01-31 10:00 +01:00')`, `ISDATE('2024')`, `ISDATE('2024-13-01')`],
  ...['year', 'quarter', 'month', 'dayofyear', 'day', 'week', 'iso_week', 'hour', 'minute', 'second', 'millisecond', 'microsecond'].map(p =>
    [`DATETRUNC(${p}, ${DT2})`, `DATETRUNC(${p}, ${DT})`]),
  [`DATETRUNC(day, ${D})`, `DATETRUNC(month, '2024-05-17')`, `DATETRUNC(hour, ${T})`],
  [`DATETRUNC(weekday, ${D})`],
  [`DATETRUNC(hour, ${D})`],
  [`DATETRUNC(year, ${T})`],
  [`DATETRUNC(millisecond, ${SDT})`],
  [`DATETRUNC(day, NULL)`],
  dto(`DATETRUNC(day, ${DTO})`),
  [`DATETRUNC(microsecond, ${DT23})`],
  [`DATETRUNC(nanosecond, ${DT2})`],
  [`!SELECT @@DATEFIRST AS c0, DATEPART(weekday, '2024-01-07') AS c1`],
  [`!SET DATEFIRST 1; SELECT DATEPART(weekday, '2024-01-07') AS c0, DATEPART(week, '2024-01-07') AS c1, @@DATEFIRST AS c2`],
)
family('date', date)

// ---------------------------------------------------------------- string
const str = []
str.push(
  [`STUFF('abcdef', 2, 3, 'XY')`, `STUFF(N'abcdef', 2, 3, 'XY')`, `STUFF('abcdef', 2, 3, N'XY')`],
  [`STUFF('abcdef', 0, 1, 'X')`, `STUFF('abcdef', 7, 1, 'X')`, `STUFF('abcdef', 6, 10, 'X')`, `STUFF('abcdef', 1, 0, 'X')`],
  [`STUFF('abcdef', 2, -1, 'X')`, `STUFF('abcdef', -1, 1, 'X')`, `STUFF('abcdef', 2, 1, NULL)`, `STUFF(NULL, 1, 1, 'x')`],
  [`STUFF('abcdef', 2, 2, '')`, `STUFF(CAST('abc' AS char(10)), 2, 1, 'Z')`, `STUFF(CAST('abc' AS varchar(max)), 2, 1, 'Z')`],
  [`STUFF(12345, 2, 1, 'x')`, `STUFF('abc', 1, 1, 9)`],
  [`STUFF('abc', '2', 1, 'x')`],
  [`STUFF('abc', 2.7, 1, 'x')`],
  [`STUFF('abc', 1, NULL, 'x')`],
  [`STUFF(0x010203, 2, 1, 0xFF)`],
  [`!DECLARE @s varchar(10) = 'hello'; SELECT STUFF(@s, 1, 1, 'J') AS c0, STUFF(@s, 1, 1, REPLICATE('x', 20)) AS c1`],
  [`PATINDEX('%b%', 'abc')`, `PATINDEX('b%', 'abc')`, `PATINDEX('%[0-9]%', 'ab12')`, `PATINDEX('%z%', 'abc')`],
  [`PATINDEX('%B%', 'abc')`, `PATINDEX(N'%c', N'abc')`, `PATINDEX('abc', 'abc')`, `PATINDEX('%', '')`],
  [`PATINDEX(NULL, 'abc')`],
  [`PATINDEX('%a%', NULL)`],
  [`PATINDEX('%a%', CAST('xa' AS varchar(max)))`, `PATINDEX('%a%', CAST(NULL AS varchar(10)))`],
  [`PATINDEX('%[^a-c]%', 'abcd')`, `PATINDEX('%_c%', 'abc')`, `PATINDEX('%a %', 'a ')`],
  [`PATINDEX('%2%', 123)`],
  [`CONCAT_WS(',', 'a', 'b', 'c')`, `CONCAT_WS(',', 'a', NULL, 'c')`, `CONCAT_WS(N'-', 'a', 1, 2.5)`],
  [`CONCAT_WS(NULL, 'a', 'b')`, `CONCAT_WS(',', NULL, NULL)`, `CONCAT_WS('', 'a', 'b')`],
  [`CONCAT_WS(',', CAST('a' AS varchar(10)), CAST('b' AS varchar(20)))`, `CONCAT_WS(', ', CAST('a' AS nvarchar(10)), 'b')`],
  [`CONCAT_WS(',', CAST('a' AS varchar(max)), 'b')`, `CONCAT_WS(',', CAST('2024-01-02' AS date), 5)`],
  [`CONCAT_WS(',', 'a')`],
  [`CONCAT_WS(',', CAST('a' AS char(3)), 'b')`, `CONCAT_WS(',', '', 'b', '')`],
  [`STR(123.456)`, `STR(123.456, 8, 2)`, `STR(-1.5, 5, 1)`, `STR(0.5)`],
  [`STR(123456789012)`, `STR(1234.5, 3)`, `STR(1.23456789, 20, 10)`, `STR(1.5, 10, 20)`],
  [`STR(NULL)`, `STR(1, NULL)`, `STR(2.5, 1)`, `STR(-2.5, 2)`],
  [`STR(1e30)`, `STR(1e30, 40)`, `STR(CAST(1 AS float)/3, 18, 16)`],
  [`STR('12.5', 6, 1)`],
  [`STR(12, 0)`],
  [`STR(12, 9000)`],
  [`STR(CAST(123.456 AS decimal(10,3)), 10, 2)`, `STR(CAST(5 AS money), 6, 2)`, `STR(5, 6, 2)`],
  [`QUOTENAME('abc')`, `QUOTENAME('a]b')`, `QUOTENAME('abc', '''')`, `QUOTENAME('abc', '"')`],
  [`QUOTENAME('abc', '(')`, `QUOTENAME('abc', ')')`, `QUOTENAME('abc', '<')`, `QUOTENAME('abc', '{')`, `QUOTENAME('abc', '>')`],
  ["QUOTENAME('abc', '`')", `QUOTENAME('abc', 'x')`, `QUOTENAME(NULL)`, `QUOTENAME('a', NULL)`],
  [`QUOTENAME(N'a''b', '''')`, `QUOTENAME(N'a"b', '"')`, `QUOTENAME('a)b', '(')`, `QUOTENAME('a}b', '{')`],
  [`QUOTENAME(REPLICATE('x', 128))`, `QUOTENAME(REPLICATE('x', 129))`],
  [`QUOTENAME(CAST('x' AS varchar(max)))`, `QUOTENAME('ab', '[]')`],
  [`QUOTENAME(123)`],
  [`STRING_ESCAPE('a"b\\c/d', 'json')`, `STRING_ESCAPE(N'tab' + CHAR(9) + 'nl' + CHAR(10), 'json')`, `STRING_ESCAPE(CHAR(1) + CHAR(31) + CHAR(127), 'json')`],
  [`STRING_ESCAPE(NULL, 'json')`, `STRING_ESCAPE(CAST('x' AS varchar(10)), 'json')`, `STRING_ESCAPE(CAST('x' AS varchar(max)), 'json')`],
  [`STRING_ESCAPE('x', 'html')`],
  [`STRING_ESCAPE(5, 'json')`],
  [`TRANSLATE('2*[3+4]/{7-2}', '[]{}', '()()')`, `TRANSLATE(N'abc', 'abc', 'xyz')`, `TRANSLATE('abcabc', 'ab', 'ba')`],
  [`TRANSLATE('abc', 'ab', 'x')`],
  [`TRANSLATE(NULL, 'a', 'b')`, `TRANSLATE('abc', NULL, 'b')`, `TRANSLATE('ABC', 'abc', 'xyz')`],
  [`TRANSLATE(CAST('abc' AS varchar(max)), 'a', 'z')`, `TRANSLATE(CAST('abc' AS char(5)), 'a', 'z')`],
  [`FORMAT(1234.5678, 'N2')`, `FORMAT(1234.5678, 'N')`, `FORMAT(1234, 'N0')`, `FORMAT(-1234.5, 'N1')`],
  [`FORMAT(0.1234, 'P')`, `FORMAT(0.1234, 'P1')`, `FORMAT(1234.5, 'C')`, `FORMAT(1234.5, 'F3')`],
  [`FORMAT(255, 'X')`, `FORMAT(255, 'x4')`, `FORMAT(42, 'D5')`, `FORMAT(-42, 'D')`],
  [`FORMAT(1234.5678, '#,##0.00')`, `FORMAT(5, '000')`, `FORMAT(1234.5, '0.##')`, `FORMAT(0.5, '#.#')`],
  [`FORMAT(1234.5678, 'E2')`, `FORMAT(1234.5678, 'G')`, `FORMAT(CAST(1234.5 AS decimal(10,2)), 'N2')`, `FORMAT(CAST(1234.5 AS money), 'C')`],
  [`FORMAT(CAST('2024-01-31 13:45:30.123' AS datetime2), 'yyyy-MM-dd')`, `FORMAT(CAST('2024-01-31 13:45:30.123' AS datetime2), 'dd/MM/yyyy HH:mm:ss')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime), 'yyyyMMdd')`],
  [`FORMAT(CAST('2024-01-31 13:45:30.123' AS datetime2), 'd')`, `FORMAT(CAST('2024-01-31 13:45:30.123' AS datetime2), 'D')`, `FORMAT(CAST('2024-01-31' AS date), 'MMMM dd, yyyy')`, `FORMAT(CAST('2024-01-31' AS date), 'ddd MMM')`],
  [`FORMAT(CAST('2024-01-31 13:45:30.123' AS datetime2), 'hh:mm tt')`, `FORMAT(CAST('2024-01-31 13:45:30.1234567' AS datetime2), 'HH:mm:ss.fff')`, `FORMAT(CAST('2024-01-31 03:05:09' AS datetime2), 'H:m:s')`],
  [`FORMAT(1234.5, 'N2', 'de-DE')`, `FORMAT(1234.5, 'N2', 'en-US')`, `FORMAT(CAST('2024-01-31' AS date), 'd', 'en-GB')`],
  [`FORMAT(NULL, 'N2')`],
  [`FORMAT(1, NULL)`],
  [`FORMAT(1, 'N2', 'xx-XX')`],
  [`FORMAT('abc', 'N2')`],
  [`FORMAT(5, 'Z')`],
  [`FORMAT(CAST('13:45:30' AS time), 'hh\\:mm')`],
  [`SOUNDEX('Robert')`, `SOUNDEX('Rupert')`, `SOUNDEX('Tymczak')`, `SOUNDEX('Pfister')`, `SOUNDEX('Ashcraft')`],
  [`SOUNDEX('')`, `SOUNDEX(NULL)`, `SOUNDEX('a')`, `SOUNDEX('123')`, `SOUNDEX(N'Lee')`],
  [`SOUNDEX('Honeyman')`, `SOUNDEX('Smith')`, `SOUNDEX('Smythe')`, `SOUNDEX(' abc')`, `SOUNDEX('Gutierrez')`],
  [`DIFFERENCE('Green', 'Greene')`, `DIFFERENCE('Robert', 'Rupert')`, `DIFFERENCE('abc', 'xyz')`, `DIFFERENCE(NULL, 'a')`],
  [`UNICODE(N'')`, `UNICODE(NULL)`, `UNICODE('A')`, `UNICODE(N'€')`, `UNICODE('€')`],
  [`NCHAR(0)`, `NCHAR(65535)`, `NCHAR(65536)`, `NCHAR(-1)`, `NCHAR(55357)`],
  [`NCHAR(128512)`],
  [`NCHAR('65')`, `NCHAR(65.9)`],
  [`CHAR(0)`, `CHAR(128)`, `CHAR(255)`, `CHAR(256)`, `CHAR(-1)`],
  [`ASCII('')`, `ASCII(NULL)`, `ASCII('€')`, `ASCII(N'€')`, `ASCII(N'雪')`, `ASCII(65)`],
  [`LEFT('abcdef', 3)`, `RIGHT(N'abcdef', 3)`, `LEFT(CAST('abc' AS varchar(max)), 2)`],
  [`SUBSTRING('abcdef', 2, 3)`, `SUBSTRING(N'abcdef', 2, 3)`, `SUBSTRING('abcdef', 0, 3)`, `SUBSTRING('abcdef', -5, 10)`],
  [`SUBSTRING('abcdef', 10, 3)`, `SUBSTRING(CAST('abc' AS char(10)), 2, 5)`, `SUBSTRING(CAST('abc' AS varchar(max)), 2, 1)`, `SUBSTRING(0x01020304, 2, 2)`],
  [`SUBSTRING('abcdef', 2, NULL)`],
  [`SUBSTRING(NULL, 1, 2)`],
  [`SUBSTRING('abc', 1, -1)`],
  [`SUBSTRING(123456, 2, 3)`],
  [`!DECLARE @s nvarchar(20) = N'abcdef', @i int = 2; SELECT SUBSTRING(@s, @i, 3) AS c0, SUBSTRING(@s, 2, @i) AS c1, LEFT(@s, @i) AS c2`],
  [`REPLACE('abcabc', 'b', 'XX')`, `REPLACE(N'abc', 'b', 'X')`, `REPLACE('abc', N'b', 'X')`, `REPLACE('abc', 'b', '')`],
  [`REPLACE('aBc', 'b', 'X')`, `REPLACE('abc' COLLATE Latin1_General_CS_AS, 'B', 'X')`, `REPLACE('abc', '', 'X')`, `REPLACE(NULL, 'a', 'b')`],
  [`REPLACE(CAST('abc' AS varchar(10)), 'b', 'XYZ')`, `REPLACE(CAST('abc' AS varchar(max)), 'b', 'X')`, `REPLACE(CAST('abc ' AS char(5)), ' ', '_')`],
  [`REPLACE(12345, 3, 'x')`],
  [`CHARINDEX('b', 'abc')`, `CHARINDEX('B', 'abc')`, `CHARINDEX('c', 'abcabc', 4)`, `CHARINDEX('c', 'abcabc', -5)`, `CHARINDEX('', 'abc')`],
  [`CHARINDEX('b', CAST('abc' AS varchar(max)))`, `CHARINDEX(NULL, 'abc')`, `CHARINDEX('a', 'abc', NULL)`, `CHARINDEX(N'b', 'abc')`],
  [`CHARINDEX('a', 'abc', 10)`, `CHARINDEX('b' COLLATE Latin1_General_CS_AS, 'aBc')`],
  [`LEN('abc  ')`, `LEN(N'  abc')`, `LEN('')`, `LEN(CAST('x' AS varchar(max)))`, `LEN(12.50)`],
  [`DATALENGTH('abc  ')`, `DATALENGTH(N'ab')`, `DATALENGTH(CAST(1 AS bigint))`, `DATALENGTH(CAST('x' AS nvarchar(max)))`, `DATALENGTH(NULL)`],
  [`DATALENGTH(CAST(1.5 AS decimal(5,1)))`, `DATALENGTH(CAST(1.5 AS decimal(20,1)))`, `DATALENGTH(CAST('2024-01-01' AS datetime2))`, `DATALENGTH(CAST('10:00' AS time(2)))`, `DATALENGTH(CAST(1 AS real))`],
  [`UPPER('abc')`, `LOWER(N'ÀBC')`, `UPPER(CAST('x' AS char(3)))`, `UPPER(12)`, `LOWER(NULL)`],
  [`REVERSE('abc')`, `REVERSE(N'a🦆b')`, `REVERSE(123)`, `REVERSE(CAST('ab' AS char(4)))`],
  [`LTRIM('  a  ')`, `RTRIM(N'  a  ')`, `TRIM('  a  ')`, `LTRIM(12)`, `TRIM(CAST(' a' AS char(4)))`],
  [`LTRIM('xxaxx', 'x')`, `RTRIM('xxaxx', 'x')`, `TRIM('x' FROM 'xxaxx')`, `TRIM(NULL)`],
  [`SPACE(5)`, `REPLICATE('ab', 2)`, `REPLICATE(N'ab', 2)`, `CONCAT('a', 1, NULL)`],
  [`CONCAT(CAST('a' AS varchar(10)), CAST('b' AS nvarchar(5)))`, `CONCAT('a', CAST(1 AS int), CAST(2 AS bigint))`, `CONCAT(1.5, CAST('2024-01-01' AS date))`],
  [`CONCAT(NULL, NULL)`, `CONCAT(CAST('a' AS varchar(max)), 'b')`, `CONCAT(0x41, 'b')`],
  [`STRING_AGG('a', ',')`],
)
family('string', str)

// ---------------------------------------------------------------- math
const math = []
const nums = { int: 'CAST(-7 AS int)', tinyint: 'CAST(7 AS tinyint)', smallint: 'CAST(-7 AS smallint)', bigint: 'CAST(-7 AS bigint)', bit: 'CAST(1 AS bit)', dec: 'CAST(-7.45 AS decimal(5,2))', num: 'CAST(-7.45 AS numeric(38,2))', money: 'CAST(-7.4567 AS money)', smallmoney: 'CAST(-7.4567 AS smallmoney)', float: 'CAST(-7.45 AS float)', real: 'CAST(-7.45 AS real)', str: "'-7.45'", lit: '-7.45' }
for (const [tn, v] of Object.entries(nums)) {
  math.push([`ABS(${v})`, `SIGN(${v})`, `CEILING(${v})`, `FLOOR(${v})`])
  math.push([`ROUND(${v}, 1)`, `ROUND(${v}, 0)`, `ROUND(${v}, -1)`, `ROUND(${v}, 1, 1)`])
  math.push([`POWER(${v}, 2)`, `SQUARE(${v})`, `DEGREES(${v})`, `RADIANS(${v})`])
}
math.push(
  [`ROUND(123.4545, 2)`, `ROUND(123.45, -2)`, `ROUND(150.75, 0)`, `ROUND(150.75, 0, 1)`, `ROUND(-150.75, 0, 1)`],
  [`ROUND(999.9, 0)`],
  [`ROUND(CAST(999.9 AS decimal(4,1)), 0)`],
  [`ROUND(CAST(9.5 AS decimal(2,1)), 0)`],
  [`ROUND(748.58, -3)`],
  [`ROUND(748.58, -4)`, `ROUND(748.58, -1)`, `ROUND(748.58, 5)`],
  [`ROUND(CAST(2147483647 AS int), -1)`],
  [`ROUND(CAST(1234 AS int), -2)`, `ROUND(CAST(1250 AS int), -2)`, `ROUND(CAST(-1250 AS int), -2)`, `ROUND(CAST(1299 AS int), -2, 1)`],
  [`ROUND(CAST(2.5 AS float), 0)`, `ROUND(CAST(-2.5 AS float), 0)`, `ROUND(CAST(1.005 AS float), 2)`, `ROUND(CAST(123.456 AS float), -1)`],
  [`ROUND(NULL, 1)`, `ROUND(1.5, NULL)`, `ROUND(1.55, 1, NULL)`, `ROUND(1.55, 1, 0)`, `ROUND(1.55, 1, 5)`],
  [`ROUND(1.5, 1.9)`],
  [`ROUND(1.55, '1')`],
  [`ROUND(CAST(12.345 AS decimal(38,3)), 2)`],
  [`ROUND(CAST(99999999999999999999999999999999999.999 AS decimal(38,3)), 2)`],
  [`ROUND(CAST(1 AS bit), 0)`],
  [`ROUND(1.5)`],
  [`CEILING(CAST(123.45 AS decimal(5,2)))`, `FLOOR(CAST(-123.45 AS decimal(5,2)))`, `CEILING(CAST(0.1 AS decimal(1,1)))`, `FLOOR(CAST(-0.1 AS decimal(1,1)))`],
  [`CEILING(CAST(99.5 AS decimal(3,1)))`],
  [`CEILING(CAST(1.2 AS money))`, `FLOOR(CAST(-1.2 AS smallmoney))`, `CEILING(1.2e0)`, `FLOOR(CAST(-1.5 AS real))`],
  [`ABS(CAST(-2147483648 AS int))`],
  [`ABS(CAST(-128 AS smallint))`, `ABS(CAST(-32768 AS smallint))`, `ABS(CAST(0 AS tinyint))`],
  [`ABS(CAST(-9223372036854775808 AS bigint))`],
  [`ABS(NULL)`, `SIGN(NULL)`, `CEILING(NULL)`, `FLOOR(NULL)`],
  [`ABS('abc')`],
  [`POWER(2, 10)`, `POWER(2, -1)`, `POWER(2.0, -1)`, `POWER(2.0, 0.5)`, `POWER(CAST(2 AS float), 0.5)`],
  [`POWER(10, 10)`],
  [`POWER(CAST(10 AS bigint), 18)`, `POWER(CAST(2 AS decimal(10,2)), 3)`, `POWER(CAST(2 AS decimal(38,0)), 100)`],
  [`POWER(-8, 1.0/3)`],
  [`POWER(0, -1)`],
  [`POWER(NULL, 2)`, `POWER(2, NULL)`, `POWER(2, CAST(3 AS bigint))`, `POWER('2', 3)`],
  [`POWER(1.1, 2)`, `POWER(1.10, 2)`, `POWER(CAST(1.1 AS numeric(10,5)), 3)`, `POWER(CAST(1.1 AS money), 2)`],
  [`SQRT(16)`, `SQRT(2)`, `SQRT(CAST(2 AS decimal(10,2)))`, `SQRT('9')`, `SQRT(NULL)`],
  [`SQRT(-1)`],
  [`SQUARE(3)`, `SQUARE(1.5)`, `SQUARE(NULL)`],
  [`SQUARE(1e200)`],
  [`EXP(1)`, `EXP(0)`, `EXP(-1.5)`, `EXP(NULL)`],
  [`EXP(1000)`],
  [`LOG(10)`, `LOG(EXP(2))`, `LOG(8, 2)`, `LOG(100, 10)`, `LOG(NULL)`],
  [`LOG(0)`],
  [`LOG(-1)`],
  [`LOG(8, 1)`],
  [`LOG(8, NULL)`, `LOG(8, 0.5)`],
  [`LOG10(1000)`, `LOG10(2)`, `LOG10(0.001)`, `LOG10(NULL)`],
  [`LOG10(0)`],
  [`PI()`, `PI() * 2`, `SIN(PI()/2)`, `COS(0)`, `TAN(PI()/4)`],
  [`SIN(1)`, `COS(1)`, `TAN(1)`, `COT(1)`, `ASIN(0.5)`, `ACOS(0.5)`, `ATAN(1)`, `ATN2(1, 1)`],
  [`ATN2(0, 0)`],
  [`ATN2(-1, -1)`, `ATN2(NULL, 1)`, `SIN(NULL)`],
  [`ASIN(2)`],
  [`ACOS(-1.5)`],
  [`COT(0)`],
  [`DEGREES(PI())`, `RADIANS(180)`, `RADIANS(180.0)`, `DEGREES(1)`, `RADIANS(CAST(180 AS float))`],
  [`DEGREES(CAST(1 AS decimal(5,2)))`, `RADIANS(CAST(1 AS decimal(5,2)))`, `RADIANS(1.0)`, `DEGREES(NULL)`],
  [`RAND(1)`, `RAND(0)`, `RAND(-1)`, `RAND(2147483647)`],
  [`RAND(42)`, `RAND(100)`, `RAND(12345)`, `RAND(NULL)`],
  [`!SELECT RAND(7) AS c0, RAND() AS c1, RAND() AS c2`],
  [`!SELECT RAND(7) AS c0; SELECT RAND() AS c0`],
  [`RAND(1.9)`, `RAND(CAST(5 AS bigint))`],
  [`!SELECT CASE WHEN RAND() >= 0 AND RAND() < 1 THEN 1 ELSE 0 END AS c0`],
  [`SIGN(CAST(0 AS float))`, `SIGN(CAST(-0.0 AS decimal(3,1)))`, `SIGN(CAST(5 AS money))`],
)
family('math', math)

// ---------------------------------------------------------------- logic / misc
const logic = []
logic.push(
  [`CHOOSE(2, 'a', 'b', 'c')`, `CHOOSE(4, 'a', 'b', 'c')`, `CHOOSE(0, 'a', 'b')`, `CHOOSE(NULL, 'a', 'b')`],
  [`CHOOSE(1, 1, 2.5)`, `CHOOSE(2, 'a', N'bb')`, `CHOOSE(1, CAST('x' AS varchar(3)), CAST('yy' AS varchar(10)))`],
  [`CHOOSE(2.9, 'a', 'b', 'c')`, `CHOOSE('2', 'a', 'b')`, `CHOOSE(1, NULL, 'b')`],
  [`CHOOSE(1, 'a', 2)`],
  [`CHOOSE(1, 2, 'a')`],
  [`CHOOSE(1)`],
  [`CHOOSE(1, CAST('2024-01-01' AS date), '2024-02-02')`],
  [`GREATEST(1, 2, 3)`, `LEAST(1, 2, 3)`, `GREATEST(1, 2.5)`, `LEAST(CAST(1 AS bigint), 2)`],
  [`GREATEST('a', 'b', 'C')`, `LEAST(N'a', 'B')`, `GREATEST(CAST('a' AS varchar(3)), CAST('bb' AS varchar(10)))`],
  [`GREATEST(1, NULL, 3)`, `LEAST(NULL, NULL)`, `GREATEST(NULL)`, `LEAST(5)`],
  [`GREATEST(CAST('2024-01-01' AS date), '2024-05-05')`, `LEAST(1.5, CAST(2 AS float))`, `GREATEST(CAST(1 AS money), 2)`],
  [`GREATEST(1, 'a')`],
  [`GREATEST(1, '5')`, `LEAST('10', 9)`],
  [`GREATEST(CAST(1.25 AS decimal(5,2)), CAST(100.5 AS decimal(10,1)))`],
  [`GREATEST(0x01, 0x02)`],
  [`ISNUMERIC('123')`, `ISNUMERIC('12.5')`, `ISNUMERIC('abc')`, `ISNUMERIC(NULL)`, `ISNUMERIC('')`],
  [`ISNUMERIC('$12')`, `ISNUMERIC('1e5')`, `ISNUMERIC('-')`, `ISNUMERIC('+')`, `ISNUMERIC('.')`, `ISNUMERIC(',')`],
  [`ISNUMERIC('1,000')`, `ISNUMERIC(' 12 ')`, `ISNUMERIC('1d2')`, `ISNUMERIC('0x10')`, `ISNUMERIC('$')`, `ISNUMERIC('\\')`],
  [`ISNUMERIC(12)`, `ISNUMERIC(1.5)`, `ISNUMERIC(CAST(1 AS bit))`, `ISNUMERIC(CAST(1 AS money))`],
  [`ISNUMERIC(CAST('2024-01-01' AS date))`],
  [`ISNUMERIC('1e')`, `ISNUMERIC('e5')`, `ISNUMERIC('1.2.3')`, `ISNUMERIC(CHAR(9) + '1')`, `ISNUMERIC('£5')`, `ISNUMERIC('€5')`],
  [`ISNUMERIC('1E+308')`, `ISNUMERIC('1E+309')`, `ISNUMERIC('99999999999999999999999999999999999999999')`, `ISNUMERIC('-$5')`, `ISNUMERIC('$-5')`],
  [`IIF(1 = 1, 'a', 'b')`, `IIF(NULL = 1, 1, 2)`, `IIF(1 = 2, 1, 2.5)`],
  [`NULLIF(1, 1)`, `NULLIF('a', 'b')`, `NULLIF(1, 1.0)`, `ISNULL(NULL, 5)`, `COALESCE(NULL, 2, 3)`],
  [`NEWSEQUENTIALID()`],
  [`!SELECT CASE WHEN NEWID() IS NULL THEN 0 ELSE 1 END AS c0, DATALENGTH(NEWID()) AS c1`],
  [`!SELECT CASE WHEN GETDATE() IS NULL THEN 0 ELSE 1 END AS c0, CASE WHEN SYSDATETIME() IS NULL THEN 0 ELSE 1 END AS c1`],
  [`!SELECT TOP 0 GETDATE() AS a, GETUTCDATE() AS b, SYSDATETIME() AS c, SYSUTCDATETIME() AS d, SYSDATETIMEOFFSET() AS e, CURRENT_TIMESTAMP AS f, NEWID() AS g`],
  [`!SELECT TOP 0 RAND() AS a, @@DATEFIRST AS b, DB_NAME() AS c, HOST_NAME() AS d, SUSER_SNAME() AS e, USER_NAME() AS f`],
)
family('logic', logic)

// ---------------------------------------------------------------- hashing
const hash = []
for (const alg of ['MD2', 'MD4', 'MD5', 'SHA', 'SHA1', 'SHA2_256', 'SHA2_512']) {
  hash.push([`HASHBYTES('${alg}', 'abc')`, `HASHBYTES('${alg}', N'abc')`, `HASHBYTES('${alg}', '')`])
}
hash.push(
  [`HASHBYTES('MD5', NULL)`],
  [`HASHBYTES(NULL, 'abc')`, `HASHBYTES('md5', 'abc')`, `HASHBYTES(N'Sha2_256', 0x616263)`, `HASHBYTES('MD5', CAST(NULL AS varchar(10)))`],
  [`HASHBYTES('SHA2_256', REPLICATE(CAST('a' AS varchar(max)), 10000))`, `HASHBYTES('SHA1', REPLICATE('abcdefgh', 100))`],
  [`HASHBYTES('SHA2_512', 'The quick brown fox jumps over the lazy dog')`, `HASHBYTES('MD5', 'The quick brown fox jumps over the lazy dog')`],
  [`HASHBYTES('SHA2_256', CAST(1 AS int))`],
  [`HASHBYTES('SHA2_256', CAST('abc' AS char(5)))`, `HASHBYTES('SHA1', N'🦆')`, `HASHBYTES('SHA1', CAST('é' AS varchar(5)))`],
  [`HASHBYTES('SHA3_256', 'abc')`],
  [`!SELECT CASE WHEN HASHBYTES('SHA2_256', 'abc') = HASHBYTES('SHA2_256', 'abc') THEN 1 ELSE 0 END AS c0`],
  [`CHECKSUM(1)`, `CHECKSUM(1, 2)`, `CHECKSUM('abc')`, `CHECKSUM(N'abc')`, `CHECKSUM('ABC')`],
  [`CHECKSUM(NULL)`],
  [`CHECKSUM(CAST(1 AS bigint))`, `CHECKSUM(1.5)`, `CHECKSUM(CAST('2024-01-01' AS date))`],
  [`BINARY_CHECKSUM(1)`, `BINARY_CHECKSUM('abc')`, `BINARY_CHECKSUM('ABC')`, `BINARY_CHECKSUM(N'abc')`, `BINARY_CHECKSUM(1, 'a')`],
  [`BINARY_CHECKSUM(NULL)`],
  [`BINARY_CHECKSUM('')`, `BINARY_CHECKSUM('abcdefghijklmnopqrstuvwxyz')`, `BINARY_CHECKSUM(0x0102)`],
  [`COMPRESS('abc')`],
)
family('hash', hash)

// ---------------------------------------------------------------- follow-ups
// Second round: rules the first captures left open.
const more = []
more.push(
  [`BINARY_CHECKSUM(256)`, `BINARY_CHECKSUM(-1)`, `BINARY_CHECKSUM(CAST(256 AS bigint))`, `BINARY_CHECKSUM(CAST(256 AS smallint))`, `BINARY_CHECKSUM(CAST(2 AS tinyint))`],
  [`BINARY_CHECKSUM(N'é')`, `BINARY_CHECKSUM(N'雪')`, `BINARY_CHECKSUM('é')`, `BINARY_CHECKSUM(CAST('ab' AS char(4)))`, `BINARY_CHECKSUM(N'a', N'b')`],
  [`CHECKSUM(256)`, `CHECKSUM(-1)`, `CHECKSUM(CAST(256 AS bigint))`, `CHECKSUM(CAST(-1 AS bigint))`, `CHECKSUM(CAST(4294967296 AS bigint))`],
  [`CHECKSUM(1, NULL)`, `CHECKSUM(CAST(NULL AS int))`, `CHECKSUM(CAST(1 AS tinyint), CAST(2 AS smallint))`],
  [`DATALENGTH(CAST(12345678901 AS decimal(20,0)))`, `DATALENGTH(CAST(1 AS decimal(38,0)))`, `DATALENGTH(CAST(1 AS numeric(10,0)))`, `DATALENGTH(CAST(12345678901234567890123 AS decimal(30,0)))`],
  [`DATALENGTH(CAST('10:00' AS time(0)))`, `DATALENGTH(CAST('10:00' AS time(4)))`, `DATALENGTH(CAST('2024-01-01' AS datetimeoffset(0)))`, `DATALENGTH(CAST('2024-01-01' AS smalldatetime))`, `DATALENGTH(CAST(1 AS smallmoney))`],
  [`SOUNDEX('a1b')`, `SOUNDEX('ab-c')`, `SOUNDEX('Ab cd')`, `SOUNDEX('ébc')`, `SOUNDEX('O''Brien')`],
  [`SOUNDEX('Lloyd')`, `SOUNDEX('Jackson')`, `SOUNDEX('Washington')`, `SOUNDEX('Lee')`, `SOUNDEX('Bbbb')`],
  ...[['Smith', 'Smyth'], ['Smith', 'Jones'], ['Robert', 'Rob'], ['abc', 'abd'], ['Lee', 'Leigh'], ['Washington', 'Washer'], ['Jackson', 'Jaxen'], ['a', 'b'], ['Tymczak', 'Tinsdale'], ['Ashcraft', 'Ashcroft'], ['Pfister', 'Fister'], ['Honeyman', 'Moneyman']].map(([a, b]) =>
    [`SOUNDEX('${a}')`, `SOUNDEX('${b}')`, `DIFFERENCE('${a}', '${b}')`, `DIFFERENCE('${b}', '${a}')`]),
  [`FORMAT(-1234.5, 'C')`, `FORMAT(-5, 'C0')`],
  [`FORMAT(1234.5678, 'F')`, `FORMAT(-0.5, 'N0')`, `FORMAT(0.125, 'N2')`, `FORMAT(2.5, 'N0')`, `FORMAT(CAST(2.5 AS float), 'N0')`],
  [`FORMAT(CAST(0.1 AS float), 'N20')`, `FORMAT(1e20, 'N0')`, `FORMAT(CAST(1.5 AS real), 'N2')`, `FORMAT(-0.001, 'P1')`],
  [`FORMAT(CAST(-1 AS int), 'X')`, `FORMAT(CAST(-1 AS smallint), 'X')`, `FORMAT(CAST(-1 AS bigint), 'x')`, `FORMAT(1.5, 'X')`, `FORMAT(1.5, 'D')`],
  [`FORMAT(1234567.891, '#,0.0')`, `FORMAT(0, '#')`, `FORMAT(0, '0.00')`, `FORMAT(-0.004, '0.00')`, `FORMAT(42, '00000')`],
  [`FORMAT(CAST('2024-01-31 13:45:30.1234567' AS datetime2), 'yyyy-MM-ddTHH:mm:ss.fffffff')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'MMM d yyyy h:mm tt')`, `FORMAT(CAST('2024-03-05' AS date), 'M/d/yy')`],
  [`FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'G')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'g')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 't')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'T')`],
  [`FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 's')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'M')`, `FORMAT(CAST('2024-01-31 13:45:30' AS datetime2), 'Y')`, `FORMAT(CAST('2024-01-31 13:45:30 +05:30' AS datetimeoffset), 'yyyy-MM-dd HH:mm zzz')`],
  [`FORMAT(CAST('13:45:30.123' AS time), 'hh\\:mm\\:ss\\.fff')`, `FORMAT(CAST('13:45:30' AS time), 'hh:mm')`, `FORMAT(CAST('13:45:30' AS time), 'c')`],
  [`ISNUMERIC('1,000.5e3')`, `ISNUMERIC('- 5')`, `ISNUMERIC('5-')`, `ISNUMERIC('$1,2,3')`, `ISNUMERIC('1e+')`, `ISNUMERIC('.e1')`],
  [`ISNUMERIC('¥5')`, `ISNUMERIC('5$')`, `ISNUMERIC('$$5')`, `ISNUMERIC('+-5')`, `ISNUMERIC('1.')`, `ISNUMERIC('1 2')`],
  [`DATEADD(day, 1, CAST('2079-06-06 10:00' AS smalldatetime))`],
  [`DATEADD(minute, -1, CAST('1900-01-01 00:00' AS smalldatetime))`],
  [`DATEADD(day, 1, CAST('9999-12-31 10:00 +00:00' AS datetimeoffset))`],
  [`DATEADD(hour, 10, CAST('9999-12-31 20:00 -05:00' AS datetimeoffset))`],
  [`DATEADD(year, -1, CAST('0001-06-01 10:00' AS datetime2))`],
  [`DATEADD(day, -1, CAST('1753-01-01' AS datetime))`],
  [`DATEADD(millisecond, 5, CAST('2024-01-01 00:00:00.000' AS datetime))`, `DATEADD(millisecond, -1, CAST('2024-01-01 00:00:00.000' AS datetime))`, `DATEADD(millisecond, -2, CAST('2024-01-01 00:00:00.000' AS datetime))`, `DATEADD(second, -1, CAST('2024-01-01 00:00:10' AS smalldatetime))`],
  [`DATETRUNC(second, CAST('2024-01-31 13:45:00' AS smalldatetime))`, `DATETRUNC(minute, CAST('2024-01-31 13:45:00' AS smalldatetime))`],
  [`DATETRUNC(millisecond, CAST('2024-01-31 13:45:30.12' AS datetime2(2)))`],
  [`DATETRUNC(weekday, CAST('2024-01-31' AS datetime))`],
  [`DATETRUNC(day, '2024-01-31 13:45:30 +05:00')`, `DATETRUNC(day, 45000)`],
  [`!DECLARE @n int = -1; SELECT LEFT('abc', @n) AS c0`],
  [`!DECLARE @n int = -1; SELECT SUBSTRING('abc', 1, @n) AS c0`],
  [`!DECLARE @n int = -1; SELECT RIGHT(N'abc', @n) AS c0`],
  [`!DECLARE @s varchar(10) = 'abcdef', @i int = 2, @j int = 3; SELECT STUFF(@s, @i, @j, 'XY') AS c0, STUFF(@s, 2, @j, 'XY') AS c1`],
  [`!DECLARE @s nvarchar(10) = N'abcdef'; SELECT REPLICATE(@s, 1000) AS c0, SPACE(LEN(@s)) AS c1, LEFT(@s, LEN(@s) - 1) AS c2`],
  [`!DECLARE @d datetime2(3) = '2024-01-31 10:00:00.123'; SELECT DATEADD(day, 1, @d) AS c0, DATEPART(ms, @d) AS c1, EOMONTH(@d) AS c2, DATETRUNC(hour, @d) AS c3`],
  [`!DECLARE @x decimal(10,4) = 123.4567; SELECT ROUND(@x, 2) AS c0, ROUND(@x, -1, 1) AS c1, CEILING(@x) AS c2, FLOOR(-@x) AS c3, ABS(-@x) AS c4, SIGN(@x) AS c5`],
  [`!DECLARE @f float = 2.5; SELECT ROUND(@f, 0) AS c0, POWER(@f, 2) AS c1, SQRT(@f) AS c2, LOG(@f) AS c3, EXP(@f) AS c4`],
  [`TRANSLATE(N'abc', 'ab', N'xy')`, `TRANSLATE('abc', N'ab', 'xy')`, `TRANSLATE(N'🦆a', N'🦆', N'xy')`],
  [`QUOTENAME(N'a]b', ']')`, `QUOTENAME('', '[')`, `QUOTENAME('a', '''''')`, `QUOTENAME('a', '"')`],
  [`STR(-0.4)`, `STR(0.4)`, `STR(99.99, 4, 1)`, `STR(9.96, 4, 1)`, `STR(-9.96, 4, 1)`, `STR(123.45, 6, -1)`],
  [`STR(1e16, 20)`, `STR(123456789.123456789, 30, 15)`, `STR(0.000001, 10, 8)`, `STR(5, 10, 5)`],
  [`CHARINDEX('a', 'abc', 0)`, `CHARINDEX('bc', 'abcbc', 3)`, `CHARINDEX(N'é', N'cafe' + NCHAR(769))`, `CHARINDEX('ss', 'straße')`],
  [`REPLACE(N'straße', 'ss', 'X')`, `REPLACE('aAa', 'a', 'b')`, `REPLACE('abc' COLLATE Latin1_General_BIN2, 'B', 'x')`],
  [`PATINDEX('%[b]%', 'ABC')`, `PATINDEX('%b%' COLLATE Latin1_General_CS_AS, 'ABC')`, `PATINDEX('a%', 'abc  ')`, `PATINDEX('%c', 'abc  ')`],
  [`GREATEST(N'a', 'b' COLLATE Latin1_General_CS_AS)`, `LEAST('A', 'a')`, `GREATEST('a ', 'a')`],
  [`GREATEST(CAST(1 AS tinyint), CAST(2 AS int))`, `LEAST(CAST(1 AS bigint), CAST(2 AS int))`, `GREATEST(1.5, 2)`, `GREATEST(CAST(1 AS float), 2)`],
  [`CHOOSE(3, 'a', 'b', 'c')`, `CHOOSE(-1, 'a')`, `CHOOSE(1, N'x', 'y')`, `CHOOSE(2, 1, 2.5)`],
  [`!SELECT RAND(3) AS c0; SELECT RAND() AS c0; SELECT RAND(3) AS c0, RAND() AS c1`],
  [`RAND(-2147483648)`],
  [`RAND(2147483562)`, `RAND(2147483563)`, `RAND(2147483564)`, `RAND(1073741824)`],
  [`COS(0.5)`, `SIN(0.5)`, `TAN(0.5)`, `ATAN(0.5)`, `EXP(0.5)`, `LOG(0.5)`, `LOG10(0.5)`, `SQRT(0.5)`],
  [`COS(2)`, `SIN(2)`, `TAN(2)`, `ACOS(0.1)`, `ASIN(0.1)`, `EXP(2)`, `LOG(2)`, `POWER(2.0e0, 0.1)`],
)
family('more', more)
