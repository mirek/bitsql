// Generates corpus/datestrings/*.cases.json: character strings converted to
// date/time types under the defaults (us_english, DATEFORMAT mdy), CONVERT
// styles, ISDATE and implicit conversions. Expected output is captured from
// the oracle (npm run capture -- datestrings). Rules derived from the
// captures: docs/reference/date-strings.md.
//
//   node gen/datestrings.mjs   (rewrites the .cases.json files; case names
//                               are index-based, so recapture a changed file
//                               after deleting its expected.json)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'datestrings')
mkdirSync(outDir, { recursive: true })

const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'x'
const lit = s => `'${s.replace(/'/g, "''")}'`

function write(file, cases) {
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/datestrings.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

// Every string × every target type, one SELECT per case (241 and 295 abort
// the batch). datetime/smalldatetime/date come back as values; the others
// as style-121 text so sub-millisecond digits and offsets are compared.
const types = ['datetime', 'smalldatetime', 'date', 'time', 'datetime2', 'datetimeoffset']
const expr = (t, s) => ['datetime', 'smalldatetime', 'date'].includes(t)
  ? `CAST(${s} AS ${t})`
  : `CONVERT(nvarchar(40), CAST(${s} AS ${t}), 121)`

function matrix(file, strings, { prefix = '' } = {}) {
  const cases = []
  for (const s of strings) {
    for (const t of types) {
      const name = `${String(cases.length).padStart(4, '0')}-${t}-${slug(s)}`
      cases.push({ name, steps: [{ kind: 'batch', sql: `SELECT ${expr(t, prefix + lit(s))} AS v` }] })
    }
  }
  write(file, cases)
}

// ------------------------------------------------------------ numeric dates
const numeric = []
for (const sep of ['/', '-', '.']) {
  for (const [a, b, c] of [
    ['1', '2', '2024'], ['01', '02', '2024'], ['1', '2', '24'], ['2024', '1', '2'], ['1', '2024', '2'], ['24', '1', '2'],
    ['1', '2', '024'], ['12', '31', '99'], ['2024', '31', '12'], ['0', '2', '2024'], ['1', '2', '0'], ['2023', '02', '29'],
    ['12', '31', '1752'], ['12', '31', '9999'], ['1', '1', '10000'],
  ]) numeric.push(`${a}${sep}${b}${sep}${c}`)
  numeric.push(`1${sep}2`, `1${sep}2${sep}`, `1${sep}2${sep}2024${sep}`, `${sep}1${sep}2${sep}2024`, `1${sep}${sep}2${sep}2024`)
}
numeric.push(
  '1/2/49', '1/2/50', '1/2/00', '1/2/1', '1/2/099', '1/2/100', '1/2/123', '1/2/0024', '1/2/0999', '1/2/1000', '1/2/00024',
  '001/02/2024', '1/002/2024', '099/1/2', '0001/02/03', '001/002/0024', '13/1/2024', '2/30/2024', '2/29/2024', '2/29/2023', '12/31/1899',
  '1/2-2024', '1-2/2024', '2024-1/2', '2024/01-02', '1 / 2 / 2024', '1/ 2/2024', '1/2 /2024', '1/2/2024/5', '1/2 2024', '1 2 2024',
  '2024-01', '2024/01', '2024-13-01', '2024-1-32', '0024-01-02', '1753-01-01', '1752-12-31', '0001-01-01', '9999-12-31', '1900-01-01', '2079-06-06', '2079-06-07',
)
const unseparated = [
  '2024', '1999', '0001', '9999', '0999', '1752', '1900', '2079', '2080', '24', '240', '24010', '240102', '240132', '241301', '491231', '500101', '991231', '000101',
  '20240102', '20241301', '20240230', '00010101', '17530101', '17521231', '2024010', '202401021', '2024010203',
  '20240102 10:11', '240102 10:11', '2024 10:11', '10:11 20240102', '20240102 10PM', '2024 10', '2024 2024',
]
// ------------------------------------------------------------ month names
const alpha = [
  'Jan 2 2024', 'January 2, 2024', 'January 2,2024', 'Jan 2 ,2024', 'January 2 , 2024', '2 Jan 2024', '2 Jan, 2024', '2024 Jan 2', 'Jan 2024', '2024 Jan',
  'Jan 2024 2', '2 2024 Jan', '2024 2 Jan', 'Jan 2 24', '2 Jan 24', '24 Jan 2', 'Jan 2 3', 'Jan 2 024', 'Jan 2 0024', 'Jan 2 00024', 'Jan 0024', 'Jan 024',
  'Jan 2', '2 January', 'Jan 24', 'Jan', 'Jan Feb 2024', 'Jan 2 2024 Feb', '2024 Jan 2 3', '1/2/2024 Jan', '1/2 Jan', 'Jan 1/2',
  'JAN 02 24', 'jan 2 2024', 'JANUARY 2 2024', 'sEpTeMbEr 30 2024', 'Sep 30, 2024', 'Sept 2 2024', 'Janu 2 2024', 'Febr 1 2024', 'Ja 1 2024',
  'Feb 29 2023', 'Feb 29 2024', 'Apr 31 2024', 'Mar 1 2024', 'April 1 2024', 'May 1 2024', 'June 1 2024', 'Jun 1 2024', 'July 4 2024', 'Jul 4 2024',
  'Aug 31 2024', 'August 1 2024', 'Oct 1 2024', 'October 1 2024', 'Nov 30 2024', 'November 1 2024', 'Dec 31 2024', 'December 31 2024', 'March 1 2024', 'February 1 2024',
  '2-Jan-2024', '02-JAN-24', '2024-Jan-02', '24-Jan-02', '02/Jan/2024', '2024/Jan/02', '2024.Jan.02', '02.Jan.2024', '2-Jan 2024', '2,Jan,2024',
  'Jan-2-2024', 'Jan/2/2024', 'Jan.2.2024', 'Jan-2024', '2024-Jan', 'Jan 2-2024', '2 Jan-2024',
  'Jan, 2 2024', 'Jan,2,2024', '2, Jan 2024', '2024, Jan 2', 'Jan 2024, 2', 'Jan 2,, 2024', ',Jan 2 2024', 'Jan 2 2024,',
  'Tuesday, January 2, 2024', 'Jan 2 1753', 'Dec 31 1752', 'Jun 6 2079', 'Jun 7 2079', 'Dec 31 9999',
]
// ------------------------------------------------------------ times
const times = [
  '10:11', '10:11:12', '10:11:12.1', '10:11:12.12', '10:11:12.123', '10:11:12.1234', '10:11:12.1234567', '10:11:12.12345678', '10:11:12.000000000',
  '10:11:12.5', '10:11:12.555', '10:11:12.999', '10:11:12.9999', '10:11:59.9999999', '23:59:59.997', '23:59:59.998', '23:59:59.999', '23:59:59.9999999', '23:59:59.99999999',
  '10:11:12:5', '10:11:12:12', '10:11:12:123', '10:11:12:999', '10:11:12:1234', '10:11:12:', '10:11:12.', '10:11:12,123', '10:11:12.1.2', '10::11', '10:', ':10', '10',
  '1:2', '1:2:3', '1:2:3.4', '000:10', '010:10', '10:010', '10:11:012', '10:11.5', '10:60', '10:11:60', '24:00', '24:00:00', '25:00', '23:59',
  '10:11 PM', '10:11:12 PM', '10:11:12.123 AM', '10:11:12.5 PM', '10:11PM', '10:11 pm', '10:11 Am', '10PM', '10 PM', '10am', '12 AM', '12 PM', '12:00 AM', '12:00 PM',
  '12:30 AM', '12:30 PM', '0 AM', '00 AM', '0 PM', '1 PM', '11 PM', '13 PM', '23 PM', '24 PM', '13 AM', '13:00 PM', '13:00 AM', '0:30 PM', '0:00 AM', '11:59:59.997 PM',
  '10 P', '10 A.M.', 'PM 10:11', 'AM', '10:11 AM PM', '10:11 A', '10:11 AMX',
]
// ------------------------------------------------------------ dates with times
const combos = [
  '1/2/2024 10:11', '1/2/2024 10:11 PM', '1/2/2024 10:11:12.123 PM', '1/2/2024 10 PM', '1/2/2024 10:11AM', '01/02/2024 10:11:12.123', '01-02-2024 10:11', '2024/01/02 10:11:12.123',
  '2024.01.02 10:11', '12.31.2024 23:59', '1-2-24 10:11 PM', '2024-01-02 10:11', '2024-01-02 10:11:12', '2024-01-02 10:11:12.5', '2024-01-02 10:11:12.555', '2024-01-02 10PM',
  '2024-01-02 10:11:12.1234567', '1/2/2024 10:11:12.1234567', '1/2/2024 10:11:12.9999999', '12/31/9999 23:59:59.997', '12/31/9999 23:59:59.998', '12/31/9999 23:59:59.9999999', '9999-12-31 23:59:59.999',
  'Jan 2 2024 10:11', 'Jan 2 2024 10:11:12.123 AM', 'Jan 2 2024 10 AM', 'Jan 2, 2024 10:11 PM', 'Jan 2,2024 10:11PM', 'Jan 2 2024 AM',
  '10:11 1/2/2024', '10 PM 1/2/2024', '10 AM 1/2/2024', '10:11 Jan 2 2024', 'Jan 2 10:11 2024', 'Jan 10:11 2 2024', '1/2 10:11 /2024',
  '1/2/2024 25:00', '1/2/2024 13 AM', '1/2/2024 AM 10:11', '1/2/2024 10:11:12 AM PM', '1/2/2024 1/2/2024', '1/2/2024 10:11 10:12', '1/2/2024 5', '1/2/2024 10', '1/2/2024 2024',
  '10:11 5', '5 10:11', '2024 5 10:11', '1/2/2024,', '1/2/2024, 10:11', '1/2/2024 ,10:11', '10:11, 1/2/2024', '2 Jan 2024, 10:11', 'Jan 2 2024 , 10:11', '2024-01-02 10:11 Jan',
  '1/2/2024T10:11', '1/2/2024x', '1/2/2024 x', 'x1/2/2024', 'garbage', '1/2/2024 10:11 A',
]
// ------------------------------------------------------------ ISO 8601 and offsets
const iso = [
  '2024-01-02T10:11:12', '2024-01-02T10:11:12.123', '2024-01-02T10:11:12.1234', '2024-01-02T10:11:12.1234567', '2024-01-02T10:11:12.12345678',
  '2024-01-02T10:11:12Z', '2024-01-02T10:11:12.123Z', '2024-01-02T10:11:12.123456Z', '2024-01-02T10:11:12 Z', '2024-01-02T10:11:12  Z', '2024-01-02T10:11:12Z ', '2024-01-02T10:11:12z', '2024-01-02t10:11:12',
  '2024-01-02T10:11:12PM', '2024-01-02T10:11:12 PM', '2024-01-02T10:11:12.123 PM', '2024-01-02T10:11 PM', '2024-01-02T10:11', '2024-01-02T10:11Z', '2024-01-02T10', '2024-01-02T', '2024-01-02 T10:11',
  '2024-01-02T1:11:12', '2024-01-02T10:1:12', '2024-1-02T10:11:12', '2024-01-2T10:11:12', '24-01-02T10:11:12', '20240102T10:11:12', '2024/01/02T10:11:12', '2024.01.02T10:11:12',
  '2024-01-02T10:11:12:123', '2024-01-02T10:11:12.', '2024-01-02TZ', '2024-01-02T24:00:00', '0001-01-01T00:00:00', '9999-12-31T23:59:59.997', '9999-12-31T23:59:59.9999999',
  'T10:11:12', 'T10:11', 'T', 'T 10:11', '2024T10:11:12',
  '2024-01-02T10:11:12+05:30', '2024-01-02T10:11:12-05:30', '2024-01-02T10:11:12.123+05:30', '2024-01-02T10:11:12+14:00', '2024-01-02T10:11:12-14:00', '2024-01-02T10:11:12+13:59',
  '2024-01-02T10:11:12+13:60', '2024-01-02T10:11:12+14:01', '2024-01-02T10:11:12 +05:30', '2024-01-02T10:11:12Z+05:00',
  '2024-01-02 10:11:12 +05:30', '2024-01-02 10:11:12+05:30', '2024-01-02 10:11:12 -14:00', '2024-01-02 10:11:12 +14:01', '2024-01-02 10:11:12+0530', '2024-01-02 10:11:12 +5:30',
  '2024-01-02 10:11:12 +05', '2024-01-02 10:11:12 +1:00', '2024-01-02 10:11:12 +01:0', '2024-01-02 10:11:12 +001:00', '2024-01-02 10:11:12 -00:00', '2024-01-02 10:11:12 + 01:00',
  '2024-01-02 10:11:12 +01:00 ', '2024-01-02 10:11:12 PM +01:00', '2024-01-02 10:11:12 +01:00 PM', '2024-01-02 10:11:12.1234567 +01:00', '2024-01-02 +05:00',
  '2024-01-02 10:11:12Z', '2024-01-02 10:11:12 Z', '2024-01-02 10:11 Z', '2024-01-02 10:11Z', '1/2/2024 10:11Z', '1/2/2024 10:11:12 +05:30', 'Jan 2 2024 10:11 +01:00',
  '10:11 +01:00', '10:11Z', '10:11:12.123Z', '2024-01-02Z', '2024-01-02 Z', '1/2/2024Z', '20240102Z', 'Jan 2 2024Z', 'Z', '2024Z',
  '0001-01-01 00:00 +01:00', '0001-01-01 00:00 -01:00', '9999-12-31 23:59 -01:00', '9999-12-31 23:59 +01:00',
]
// ------------------------------------------------------------ whitespace
const blanks = [
  '', ' ', '   ', '  1/2/2024  ', '\t1/2/2024', '1/2/2024\t', '1/2/2024\t10:11', '\t\t1/2/2024 \t ', '10:11\tPM', 'Jan\t2\t2024',
  '1/2/2024\n', '\n1/2/2024', '1/2/2024\r', '1/2/2024\r\n10:11', '1/2/2024\v', '1/2/2024\f', ' 1/2/2024', '1/2/2024  10:11', 'Jan  2  2024', '  10:11  ',
]

matrix('numeric', numeric)
matrix('unseparated', unseparated)
matrix('alpha', alpha)
matrix('times', times)
matrix('combos', combos)
matrix('iso', iso)
matrix('blanks', blanks)
// nvarchar sources follow the same rules (242's message names nvarchar)
matrix('nvarchar', ['1/2/2024', '13/1/2024', 'Jan 2 2024 10:11 PM', 'garbage', '2024-01-02T10:11:12.1234567+05:30', '1/2/2024\t10:11', '2/30/2024', '10:11:12.1234'], { prefix: 'N' })

// ------------------------------------------------------------ ISDATE
{
  const all = [...numeric, ...unseparated, ...alpha, ...times, ...combos, ...iso, ...blanks]
  const cases = []
  for (let i = 0; i < all.length; i += 10) {
    const chunk = all.slice(i, i + 10)
    cases.push({ name: `${String(cases.length).padStart(3, '0')}-${slug(chunk[0])}`, steps: [{ kind: 'batch', sql: `SELECT ${chunk.map((s, k) => `ISDATE(${lit(s)}) AS c${k}`).join(', ')}` }] })
  }
  cases.push({ name: `${String(cases.length).padStart(3, '0')}-other-sources`, steps: [{ kind: 'batch', sql: "SELECT ISDATE(N'1/2/2024') AS a, ISDATE(CAST('1/2/2024' AS char(20))) AS b, ISDATE(NULL) AS c, ISDATE(N'garbage') AS d, ISDATE(CAST(N'13/1/2024' AS nchar(12))) AS e" }] })
  write('isdate', cases)
}

// ------------------------------------------------------------ implicit conversions and statement behaviour
{
  const raw = [
    "SELECT 1 AS v WHERE CAST('2024-01-02' AS date) = '01/02/2024'",
    "SELECT 1 AS v WHERE CAST('2024-01-02' AS date) = '13/02/2024'",
    "DECLARE @d date = '2024-01-02'; SELECT CASE WHEN @d = '1/2/24' THEN 1 ELSE 0 END AS v",
    "DECLARE @d datetime = '2024-01-02'; SELECT CASE WHEN @d = 'Jan 2 2024' THEN 1 ELSE 0 END AS v",
    "DECLARE @d datetime2 = '2024-01-02 22:11'; SELECT CASE WHEN @d = '1/2/2024 10:11 PM' THEN 1 ELSE 0 END AS v",
    "DECLARE @d smalldatetime = 'Jan 2 2024 10:11PM'; SELECT @d AS v",
    "DECLARE @d datetimeoffset = 'January 2, 2024 10:11 PM +05:30'; SELECT CONVERT(nvarchar(40), @d, 121) AS v",
    "DECLARE @d time = '10:11 PM'; SELECT CONVERT(nvarchar(40), @d, 121) AS v",
    "DECLARE @d datetime = '13/1/2024'",
    "DECLARE @d datetime = 'garbage'; SELECT 1 AS after",
    "DECLARE @s varchar(20) = '13/1/2024'; DECLARE @d datetime = @s; SELECT 1 AS after",
    "DECLARE @s varchar(20) = '13/1/2024'; SELECT CAST(@s AS datetime) AS v",
    "DECLARE @s nvarchar(20) = N'13/1/2024'; SELECT CAST(@s AS smalldatetime) AS v",
    "DECLARE @s nvarchar(20) = N'x'; SELECT CAST(@s AS smalldatetime) AS v",
    "DECLARE @s varchar(40) = 'Jan 2 2024 10:11 PM'; SELECT CAST(@s AS datetime) AS a, CAST(@s AS date) AS b, CONVERT(nvarchar(40), CAST(@s AS datetime2(3)), 121) AS c",
    "SELECT CAST('x' AS datetime) AS v; SELECT 1 AS after",
    "SELECT CAST('13/1/2024' AS datetime) AS v; SELECT 2 AS after",
    "SELECT CAST('x' AS smalldatetime) AS v; SELECT 3 AS after",
    "SELECT CAST('13/1/2024' AS smalldatetime) AS v; SELECT 4 AS after",
    "SELECT CAST('x' AS date) AS v; SELECT 5 AS after",
    "SELECT CAST('2024-01-02 10:00 +15:00' AS datetimeoffset) AS v; SELECT 6 AS after",
    "SELECT CAST('1/2/123' AS date) AS v; SELECT 7 AS after",
    "SELECT CONVERT(date, '12/31/2024', 112) AS v; SELECT 8 AS after",
    "SELECT TRY_CAST('x' AS datetime) AS a, TRY_CAST('13/1/2024' AS datetime) AS b, TRY_CAST('x' AS smalldatetime) AS c, TRY_CAST('2079-06-07' AS smalldatetime) AS d, TRY_CAST('x' AS date) AS e",
    "SELECT TRY_CONVERT(date, '13/1/2024') AS a, TRY_CONVERT(date, '13/1/2024', 103) AS b, TRY_CONVERT(date, '12/31/2024', 112) AS c, TRY_CONVERT(datetime, '12/31/2024', 103) AS d",
    "SELECT TRY_CAST(N'Jan 2 2024' AS datetime) AS a, TRY_CAST('10:11 PM' AS time) AS b, TRY_CAST('2024-01-02T10:11:12+05:30' AS datetime) AS c",
    "SELECT DATEADD(day, 1, 'Jan 2 2024') AS a, DATEADD(day, 1, '1/2/2024 10:11 PM') AS b, DATEDIFF(day, '1/1/2024', 'Feb 1 2024') AS c",
    "SELECT DATEPART(month, '2 Mar 2024') AS a, DATENAME(month, '4/5/2024') AS b, YEAR('Jan 2 99') AS c, MONTH('12/1/2024') AS d, DAY('1.15.2024') AS e",
    "SELECT EOMONTH('2/1/2024') AS a, DATEFROMPARTS(2024, 1, 2) AS b",
  ]
  const cases = raw.map((sql, i) => ({ name: `${String(i).padStart(3, '0')}-${slug(sql)}`, steps: [{ kind: 'batch', sql }] }))
  cases.push({
    name: `${String(cases.length).padStart(3, '0')}-table-compare-and-insert`,
    steps: [
      { kind: 'batch', compare: false, sql: 'CREATE TABLE t (id int NOT NULL PRIMARY KEY, d date NULL, dt datetime NULL, sdt smalldatetime NULL, d2 datetime2(3) NULL, dto datetimeoffset(0) NULL)' },
      { kind: 'batch', sql: "INSERT INTO t VALUES (1, '01/02/2024', 'Jan 2 2024 10:11 PM', '1/2/2024 10:11:29', '2024-01-02T10:11:12.1235', 'Jan 2 2024 10:11 PM -05:00'), (2, 'Feb 3 2024', '2/3/24', '20240203', '3 Feb 2024', '2024-02-03Z')" },
      { kind: 'batch', sql: "SELECT id, d, dt, sdt, CONVERT(nvarchar(40), d2, 121) AS d2, CONVERT(nvarchar(40), dto, 121) AS dto FROM t ORDER BY id" },
      { kind: 'batch', sql: "SELECT id FROM t WHERE d = '01/02/2024' OR dt = 'February 3, 2024' ORDER BY id" },
      { kind: 'batch', sql: "SELECT id FROM t WHERE d BETWEEN 'Jan 1 2024' AND '1/31/2024' ORDER BY id" },
      { kind: 'batch', sql: "SELECT id FROM t WHERE dt > '13/1/2024'" },
      { kind: 'batch', sql: "SELECT id FROM t WHERE d > 'garbage'" },
      { kind: 'batch', sql: "UPDATE t SET dt = '12/31/1752' WHERE id = 1" },
      { kind: 'batch', sql: "INSERT INTO t (id, d) VALUES (3, '2/30/2024')" },
    ],
  })
  // completion of batch-aborting conversion errors in assignments
  for (const sql of [
    "DECLARE @i int = 'x'; SELECT 1 AS after",
    "DECLARE @s varchar(10) = 'garbage'; DECLARE @d datetime = @s; SELECT 1 AS after",
    "DECLARE @d datetime; SET @d = 'garbage'; SELECT 1 AS after",
    "DECLARE @d datetime; SELECT @d = 'garbage'; SELECT 1 AS after",
    "DECLARE @d date = 'garbage'; SELECT 1 AS after",
    "DECLARE @d smalldatetime = 'garbage'; SELECT 1 AS after",
    "DECLARE @d datetime; SET @d = '13/1/2024'; SELECT 1 AS after",
  ]) cases.push({ name: `${String(cases.length).padStart(3, '0')}-${slug(sql)}`, steps: [{ kind: 'batch', sql }] })
  write('implicit', cases)
}

// ------------------------------------------------------------ CONVERT styles
// Values and acceptance: TRY_CONVERT under every supported style as one row
// per (type, string). Error numbers: CONVERT per (type, string, style) for a
// subset.
{
  const styles = [0, 1, 2, 3, 4, 5, 10, 11, 20, 21, 101, 102, 103, 104, 105, 110, 111, 112, 120, 121, 126, 127]
  const strs = [
    '12/31/2024', '31/12/2024', '12/31/24', '31/12/24', '2024/12/31', '24/12/31', '12-31-2024', '31-12-2024', '31.12.2024', '24.12.31', '1/2/2024', '1/2/24',
    '20241231', '241231', '2024', '2024-12-31', '2024-1-2', '2024.12.31', '2024-12-31 10:11', '2024-12-31 10:11:12.123', '2024-12-31 10:11:12.1234567',
    '2024-12-31T10:11:12', '2024-12-31T10:11:12.123', '2024-12-31T10:11:12.123Z', '2024-12-31T10:11:12+01:00', '2024-12-31Z', '2024-12-31 10:11:12 +01:00',
    'Dec 31 2024', '31 Dec 2024', 'Dec 31 2024 10:11', '20241231 10:11', '10:11', '10:11:12.123', '12/31/2024 10:11 PM', '31/12/2024 22:11', '1/2/2024T10:11', 'garbage',
  ]
  const cases = []
  for (const t of ['datetime', 'smalldatetime', 'date', 'datetime2', 'datetimeoffset']) {
    for (const s of strs) {
      const cols = styles.map(st => t === 'datetime2' || t === 'datetimeoffset'
        ? `CONVERT(nvarchar(40), TRY_CONVERT(${t}, ${lit(s)}, ${st}), 121) AS s${st}`
        : `TRY_CONVERT(${t}, ${lit(s)}, ${st}) AS s${st}`)
      cases.push({ name: `${String(cases.length).padStart(4, '0')}-try-${t}-${slug(s)}`, steps: [{ kind: 'batch', sql: `SELECT ${cols.join(', ')}` }] })
    }
  }
  const errStrs = ['12/31/2024', '31/12/2024', '12/31/24', '2024/12/31', '2024-12-31T10:11:12', '2024-12-31T10:11:12Z', '2024-12-31 10:11', 'Dec 31 2024', '20241231', 'garbage']
  for (const t of ['datetime', 'smalldatetime', 'date', 'datetime2']) {
    for (const s of errStrs) {
      for (const st of [1, 3, 101, 103, 111, 112, 120, 126, 127]) {
        cases.push({ name: `${String(cases.length).padStart(4, '0')}-${t}-${st}-${slug(s)}`, steps: [{ kind: 'batch', sql: `SELECT CONVERT(nvarchar(40), CONVERT(${t}, ${lit(s)}, ${st}), 121) AS v` }] })
      }
    }
  }
  // nvarchar source and a style the emulator does not implement (stays an
  // explicit Emulator error)
  for (const sql of [
    "SELECT CONVERT(datetime, N'31/12/2024 10:11', 103) AS a, CONVERT(date, N'31.12.2024', 104) AS b",
    "SELECT CONVERT(datetime, '31 Dec 2024', 106) AS v",
    "SELECT CONVERT(date, '12/31/2024', 13) AS v",
  ]) cases.push({ name: `${String(cases.length).padStart(4, '0')}-${slug(sql)}`, steps: [{ kind: 'batch', sql }] })
  write('styles', cases)
}
