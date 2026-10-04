// Generates corpus/settings/*.cases.json: SET DATEFORMAT and SET LANGUAGE
// (string → date/time parsing per date order and language, month and day
// names, styles that print month names, @@DATEFIRST/@@LANGUAGE, INFO 5703
// texts). Expected output is captured from the oracle
// (npm run capture -- settings). Rules derived from the captures:
// docs/reference/date-strings.md ("DATEFORMAT and LANGUAGE").
//
//   node gen/settings.mjs   (rewrites the .cases.json files; case names are
//                            index-based, so recapture a changed file after
//                            deleting its expected.json)
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { formatJson } from '../src/json.mjs'

const outDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'corpus', 'settings')
mkdirSync(outDir, { recursive: true })

const slug = s => s.toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'x'
const lit = s => `N'${s.replace(/'/g, "''")}'`

function write(file, cases) {
  writeFileSync(join(outDir, `${file}.cases.json`), formatJson({ source: 'harness/gen/settings.mjs', cases }) + '\n')
  console.log(`${file}: ${cases.length} cases`)
}

// Every string under every type in one SELECT: TRY_CAST keeps one failing
// type from hiding the others (the error numbers are those of the default
// date order, docs/reference/date-strings.md).
const conversions = s => [
  `TRY_CAST(${lit(s)} AS date) AS d`,
  `TRY_CAST(${lit(s)} AS datetime) AS dt`,
  `TRY_CAST(${lit(s)} AS smalldatetime) AS sdt`,
  `CONVERT(nvarchar(40), TRY_CAST(${lit(s)} AS datetime2(7)), 121) AS dt2`,
  `CONVERT(nvarchar(40), TRY_CAST(${lit(s)} AS datetimeoffset(7)), 121) AS dto`,
  `ISDATE(${lit(s)}) AS isd`,
].join(', ')

// ------------------------------------------------------------ DATEFORMAT
const numeric = []
for (const sep of ['/', '-', '.']) {
  for (const [a, b, c] of [
    ['1', '2', '2024'], ['01', '02', '2024'], ['1', '2', '24'], ['2024', '1', '2'], ['1', '2024', '2'], ['24', '1', '2'],
    ['12', '31', '99'], ['31', '12', '99'], ['99', '12', '31'], ['2024', '31', '12'], ['31', '12', '2024'], ['12', '2024', '31'],
    ['31', '2024', '12'], ['13', '1', '24'], ['1', '13', '24'], ['1', '2', '3'],
  ]) numeric.push(`${a}${sep}${b}${sep}${c}`)
}
numeric.push(
  '1/2/024', '1/2/123', '001/02/2024', '1 / 2 / 2024', '1/2-2024', '1/2', '2024/01', '1/2/2024 10:11', '10:11 1/2/2024',
  '1/2/2024 10:11 PM', '2024-01-02', '2024-01-02T03:04:05', '2024-01-02 03:04:05.1234567 +02:00', '20240102', '240102',
  '2024-13-02', '2024-02-13', 'Jan 2 2024', '2 Jan 2024', '2024 Jan 2', '02-Jan-24', '2024/Jan/02', 'Jan 2024', '24 Jan 2',
)

const dfCases = []
for (const f of ['mdy', 'dmy', 'ymd', 'ydm', 'myd', 'dym']) {
  for (const s of numeric) {
    dfCases.push({
      name: `${String(dfCases.length).padStart(4, '0')}-${f}-${slug(s)}`,
      steps: [{ kind: 'batch', sql: `SET DATEFORMAT ${f}; SELECT ${conversions(s)}` }],
    })
  }
}
// errors (not TRY_): the number and state under each order
for (const f of ['dmy', 'ydm', 'myd']) {
  for (const [t, s] of [['date', '13/13/2024'], ['datetime', '13/13/2024'], ['datetime', '2024/31/12'], ['date', '2024/31/12'], ['datetime2', '31/2024/12'], ['smalldatetime', '31/12/2024 25:00']]) {
    dfCases.push({
      name: `${String(dfCases.length).padStart(4, '0')}-${f}-error-${t}-${slug(s)}`,
      steps: [{ kind: 'batch', sql: `SET DATEFORMAT ${f}; SELECT CAST(${lit(s)} AS ${t}) AS v` }],
    })
  }
}
// SET DATEFORMAT forms: variables, quoted, invalid, @@OPTIONS-free reporting
for (const sql of [
  `SET DATEFORMAT 'dmy'; SELECT TRY_CAST(N'1/2/2024' AS date) AS v`,
  `SET DATEFORMAT N'ydm'; SELECT TRY_CAST(N'2024/1/2' AS date) AS d, TRY_CAST(N'2024/1/2' AS datetime) AS dt`,
  `DECLARE @f nvarchar(10) = N'DMY'; SET DATEFORMAT @f; SELECT TRY_CAST(N'1/2/2024' AS date) AS v`,
  `DECLARE @f varchar(10) = 'bad'; SET DATEFORMAT @f; SELECT 1 AS after_error`,
  `DECLARE @f varchar(10) = NULL; SET DATEFORMAT @f; SELECT 1 AS after_null`,
  `SET DATEFORMAT xyz; SELECT 1 AS after_error`,
  `SET DATEFORMAT dmy; SELECT ISDATE('13/1/2024') AS a, ISDATE('1/13/2024') AS b`,
  `SET DATEFORMAT dmy; DECLARE @d datetime = '13/01/2024'; SELECT @d AS v`,
  `SET DATEFORMAT dmy; CREATE TABLE t (d date); INSERT t VALUES ('13/01/2024'); SELECT d FROM t WHERE d = '13/1/2024'`,
  `SET DATEFORMAT dmy; SELECT DATEADD(day, 1, '13/01/2024') AS v, DATEDIFF(day, '01/02/2024', '01/03/2024') AS diff`,
  `SET DATEFORMAT dmy; SELECT CASE WHEN CAST('13/01/2024' AS datetime) > '12/01/2024' THEN 1 ELSE 0 END AS v`,
  `SET DATEFORMAT dmy; SELECT DATEADD(day, 1, CAST('13/01/2024' AS datetime)) AS v`,
  `SET DATEFORMAT dmy; SELECT CONVERT(datetime, '01/02/2024', 101) AS styled, CONVERT(datetime, '01/02/2024') AS unstyled`,
  `SET DATEFORMAT dmy; EXEC('SELECT TRY_CAST(N''1/2/2024'' AS date) AS inner_v'); SELECT TRY_CAST(N'1/2/2024' AS date) AS outer_v`,
  `EXEC('SET DATEFORMAT dmy'); SELECT TRY_CAST(N'1/2/2024' AS date) AS after_exec`,
  `SET DATEFORMAT dmy; SELECT CAST(CAST('2024-03-04' AS date) AS varchar(30)) AS d, CAST(CAST('2024-03-04' AS datetime) AS varchar(30)) AS dt`,
]) {
  dfCases.push({ name: `${String(dfCases.length).padStart(4, '0')}-form-${slug(sql.slice(0, 60))}`, steps: [{ kind: 'batch', sql }] })
}
write('dateformat', dfCases)

// ------------------------------------------------------------ LANGUAGE
// Languages of the captured corpora first, then a sample of the others.
const languages = ['us_english', 'British', 'German', 'French', 'Japanese', 'Spanish', 'Italian', 'Dutch', 'Swedish', 'Russian', 'Polish', 'Portuguese', 'Brazilian', 'Danish', 'Czech', 'Arabic', 'Simplified Chinese']
const lgCases = []
const add = (name, sql) => lgCases.push({ name: `${String(lgCases.length).padStart(4, '0')}-${name}`, steps: [{ kind: 'batch', sql }] })
// INFO 5703 and the reported settings for all 34 languages
add('all-languages-5703', `DECLARE @n sysname, @i int = 0;
WHILE @i < 34
BEGIN
  SELECT @n = name FROM sys.syslanguages WHERE langid = @i;
  SET LANGUAGE @n;
  SELECT @@LANGUAGE AS lang, @@LANGID AS langid, @@DATEFIRST AS datefirst, DATENAME(month, '20240315') AS m, DATENAME(weekday, '20240315') AS wd;
  SET @i += 1;
END`)
add('syslanguages', `SELECT langid, dateformat, datefirst, upgrade, name, alias, months, shortmonths, days, lcid, msglangid FROM sys.syslanguages ORDER BY langid`)
for (const l of languages) {
  const s = slug(l)
  add(`${s}-settings`, `SET LANGUAGE ${l === 'Simplified Chinese' ? "N'Simplified Chinese'" : l}; SELECT @@LANGUAGE AS lang, @@LANGID AS langid, @@DATEFIRST AS datefirst, DATEPART(weekday, '20240315') AS dw, TRY_CAST(N'03/04/2024' AS date) AS d, TRY_CAST(N'03/04/2024' AS datetime) AS dt, TRY_CAST(N'2024/03/04' AS datetime) AS ymd`)
  const months = Array.from({ length: 12 }, (_, i) => `DATENAME(month, '2024${String(i + 1).padStart(2, '0')}15') AS m${i + 1}`).join(', ')
  add(`${s}-month-names`, `SET LANGUAGE ${l === 'Simplified Chinese' ? "N'Simplified Chinese'" : l}; SELECT ${months}`)
  const days = Array.from({ length: 7 }, (_, i) => `DATENAME(weekday, '202403${String(11 + i)}') AS w${i + 1}`).join(', ')
  add(`${s}-day-names`, `SET LANGUAGE ${l === 'Simplified Chinese' ? "N'Simplified Chinese'" : l}; SELECT ${days}, DATENAME(dw, CAST('2024-03-11' AS date)) AS dw_date`)
  const styles = [0, 100, 106, 107, 109, 113, 130].map(st => `CONVERT(nvarchar(40), CAST('2024-03-04T05:06:07.123' AS datetime), ${st}) AS s${st}`).join(', ')
  add(`${s}-styles`, `SET LANGUAGE ${l === 'Simplified Chinese' ? "N'Simplified Chinese'" : l}; SELECT ${styles}, CAST(CAST('2024-12-04T05:06:07' AS datetime) AS nvarchar(40)) AS cast_dt, CAST(CAST('2024-12-04T05:06:07' AS smalldatetime) AS nvarchar(40)) AS cast_sdt, CONVERT(nvarchar(40), CAST('2024-12-04' AS date), 106) AS date106, CONVERT(nvarchar(40), CAST('2024-12-04T05:06:07' AS datetime2(3)), 109) AS dt2_109`)
}
// month names in strings: the language's full and short names, English
// names under other languages, and mixed case
const parse = {
  British: ['4 March 2024', 'Mar 4 2024', '04/03/2024'],
  German: ['4 März 2024', '4 Mär 2024', '4 März 2024 10:11', 'März 4 2024', '4 Mai 2024', '4 Dezember 2024', '4 Dez 2024', '4 March 2024', '4 Mar 2024', '4 MÄRZ 2024', '4 maerz 2024', '04.03.2024'],
  French: ['4 mars 2024', '4 janvier 2024', '4 janv 2024', '4 févr 2024', '4 février 2024', '4 FÉVRIER 2024', '4 août 2024', '4 aout 2024', '4 décembre 2024', '4 déc 2024', '4 March 2024', '04/03/2024'],
  Japanese: ['2024/03/04', '03/04/2024', '4 Mar 2024', '2024 03 04'],
  Spanish: ['4 Marzo 2024', '4 Mar 2024', '4 Ene 2024', '4 Enero 2024', '4 January 2024'],
  Italian: ['4 marzo 2024', '4 gen 2024', '4 gennaio 2024', '4 January 2024'],
  Dutch: ['4 maart 2024', '4 mrt 2024', '4 mei 2024', '4 March 2024'],
  Russian: ['4 Март 2024', '4 мар 2024', '4 March 2024'],
  Czech: ['4 březen 2024', '4 III 2024', '4 XII 2024', '4 March 2024'],
  us_english: ['4 March 2024', '4 März 2024', '4 mars 2024'],
}
for (const [l, strings] of Object.entries(parse)) {
  for (const str of strings) add(`${slug(l)}-parse-${slug(str)}`, `SET LANGUAGE ${l}; SELECT ${conversions(str)}`)
}
// SET LANGUAGE forms and errors
for (const sql of [
  `SET LANGUAGE 'Deutsch'; SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE N'British English'; SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE [Français]; SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE english; SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE ENGLISH; SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE nonsense; SELECT @@LANGUAGE AS after_error`,
  `DECLARE @l sysname = N'German'; SET LANGUAGE @l; SELECT @@LANGUAGE AS lang`,
  `DECLARE @l sysname = NULL; SET LANGUAGE @l; SELECT @@LANGUAGE AS lang`,
  `DECLARE @l sysname = N'bad'; SET LANGUAGE @l; SELECT @@LANGUAGE AS after_error`,
  `SET LANGUAGE German; SET DATEFORMAT mdy; SELECT TRY_CAST(N'03/04/2024' AS date) AS d, @@DATEFIRST AS df`,
  `SET DATEFORMAT ymd; SET LANGUAGE French; SELECT TRY_CAST(N'03/04/2024' AS date) AS d`,
  `SET DATEFIRST 3; SET LANGUAGE German; SELECT @@DATEFIRST AS df`,
  `SET LANGUAGE German; SET DATEFIRST 7; SELECT @@DATEFIRST AS df, DATEPART(weekday, '20240315') AS dw`,
  `SET LANGUAGE German; SELECT CAST('x' AS int) AS v`,
  `SET LANGUAGE German; SELECT 1/0 AS v`,
  `SET LANGUAGE French; RAISERROR('custom %d', 16, 1, 5)`,
  `SET LANGUAGE German; EXEC('SET LANGUAGE French'); SELECT @@LANGUAGE AS lang`,
  `SET LANGUAGE German; SELECT DATENAME(month, CAST('2024-03-04' AS date)) AS d, DATENAME(month, CAST('2024-03-04' AS datetimeoffset)) AS dto, FORMAT(CAST('2024-03-04' AS date), 'MMMM') AS fmt`,
  `SET LANGUAGE German; SELECT CONVERT(datetime, '4 März 2024', 106) AS v`,
  `SET LANGUAGE German; SELECT CONVERT(datetime, '4 Mar 2024', 106) AS v`,
  `SET LANGUAGE German; SELECT ISDATE('4 März 2024') AS a, ISDATE('4 March 2024') AS b`,
  `SET LANGUAGE German; SELECT * FROM (SELECT TOP 1 1 AS x FROM sys.objects) t; DBCC USEROPTIONS WITH NO_INFOMSGS`,
]) add(`form-${slug(sql.slice(0, 60))}`, sql)
write('language', lgCases)
