// Dumps SQL Server's AT TIME ZONE behaviour for every sys.time_zone_info name
// into scripts/timezones/sqlserver-timezones.json, the input of
// scripts/gen-timezones.py (which derives the compact rule tables embedded in
// src/core/types/timezone_data.mbt).
//
// Usage (in harness/): node src/dump-timezones.mjs ../scripts/timezones/sqlserver-timezones.json
// Use a private oracle when the shared one is busy:
//   BITSQL_ORACLE_NAME=bitsql-oracle-tz BITSQL_ORACLE_PORT=47345 node src/dump-timezones.mjs ...
//
// What is dumped (all values computed by SQL Server itself):
// - `zones`: sys.time_zone_info names in catalog order.
// - `catalog`: sys.time_zone_info rows at one SYSUTCDATETIME() instant.
// - `windows`: UTC scan windows. Each is scanned in 6-hour steps per zone,
//   plus every 30 minutes for 3 days around each new year (where Windows
//   year-rule switches cause short-lived offsets);
//   every change of DATEPART(TZOFFSET, utc AT TIME ZONE zone) is refined by
//   binary search to the exact 100 ns tick. Per zone and window: the offset at
//   the window start and the transitions [utc 'yyyy-mm-dd hh:mm:ss.fffffff',
//   offset before, offset after].
//   The main window covers 1899-12 .. 2102-01 (where Windows "dynamic DST"
//   rules vary per year); short windows at sample years far outside it prove
//   how SQL Server extrapolates the first / last yearly rule.
// - `probes`: local wall-clock (datetime2) inputs around every transition of
//   the main window between `probeFrom` and `probeTo`: for a transition at
//   local wall time L (in the offset before) with change d = after - before
//   minutes, the probes are L - 100ns, L, L + |d|/2, L + |d| - 100ns, L + |d|.
//   For each: [displayed offset, (local - utc) in minutes as a decimal string].
//   These pin down how SQL Server resolves skipped and repeated local times.
import { writeFileSync } from 'node:fs'
import { startOracle } from './oracle.mjs'
import { connect, close } from './client.mjs'
import { capture } from './capture-core.mjs'

const out = process.argv[2]
if (!out) throw new Error('usage: node src/dump-timezones.mjs <out.json>')

const { config, image } = await startOracle({ log: t => process.stderr.write(t) })
config.options.requestTimeout = 0
const c = await connect(config)

async function q(sql) {
  const r = await capture(c, { kind: 'batch', sql })
  if (r.errors.length) throw new Error(r.errors.map(e => `${e.number}: ${e.message}`).join('; ') + '\n' + sql)
  return r.sets
}
const lit = s => `N'${s.replace(/'/g, "''")}'`

const version = (await q(`SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))`))[0].rows[0][0]
const zones = (await q(`SELECT name FROM sys.time_zone_info`))[0].rows.map(r => r[0])
// the catalog at one instant: checks current_utc_offset / is_currently_dst
const catalogRows = (await q(`SELECT CONVERT(varchar(27), SYSUTCDATETIME(), 121), name, current_utc_offset, is_currently_dst FROM sys.time_zone_info`))[0].rows
const catalog = { at: catalogRows[0][0], rows: catalogRows.map(r => [r[1], r[2], r[3]]) }

// [start, number of 6-hour steps]
const MAIN = ['1899-12-01', 295000] // .. 2101-12-xx
const SAMPLE_YEARS = [1, 2, 3, 4, 5, 100, 400, 500, 1000, 1500, 1582, 1600, 1700, 1752, 1800,
  1850, 1896, 1897, 1898, 2102, 2103, 2104, 2200, 2300, 2400, 2500, 3000, 4000, 5000, 6000,
  7000, 8000, 9000, 9996, 9997, 9998, 9999]
const windows = [MAIN]
for (const y of SAMPLE_YEARS) {
  if (y === 1) windows.push(['0001-01-02', 4 * 364])
  else if (y === 9999) windows.push(['9998-12-31', 4 * 365])
  else windows.push([`${String(y - 1).padStart(4, '0')}-12-31`, 4 * 368])
}
const PROBE_FROM = '1970-01-01'
const PROBE_TO = '2060-01-01'

function scanSql(zone, start, steps, probes) {
  return `SET NOCOUNT ON;
DECLARE @z nvarchar(256) = ${lit(zone)};
DECLARE @start datetime2(7) = '${start}';
CREATE TABLE #s (t datetime2(7) PRIMARY KEY, o int NULL);
WITH n AS (SELECT TOP (${steps + 1}) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS i
           FROM sys.all_columns a CROSS JOIN sys.all_columns b),
y AS (SELECT TOP (${Math.ceil(steps / 1400) + 2}) YEAR(@start) + ROW_NUMBER() OVER (ORDER BY (SELECT 1)) AS y FROM sys.all_columns),
k AS (SELECT TOP (145) ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS k FROM sys.all_columns)
INSERT #s (t)
SELECT DATEADD(minute, i * 360, @start) FROM n
UNION
SELECT DATEADD(minute, k.k * 30, DATEADD(hour, -36, DATETIME2FROMPARTS(y.y, 1, 1, 0, 0, 0, 0, 7)))
FROM y CROSS JOIN k
WHERE y.y BETWEEN 2 AND 9999
  AND DATEADD(minute, k.k * 30, DATEADD(hour, -36, DATETIME2FROMPARTS(y.y, 1, 1, 0, 0, 0, 0, 7))) BETWEEN @start AND DATEADD(minute, ${steps} * 360, @start);
UPDATE #s SET o = DATEPART(TZOFFSET, CAST(t AS datetimeoffset(7)) AT TIME ZONE @z);
CREATE TABLE #t (lo datetime2(7) NOT NULL, hi datetime2(7) NOT NULL, olo int NOT NULL, ohi int NOT NULL);
INSERT #t SELECT p, t, po, o
  FROM (SELECT t, o, LAG(o) OVER (ORDER BY t) AS po, LAG(t) OVER (ORDER BY t) AS p FROM #s) x WHERE o <> po;
WHILE 1 = 1
BEGIN
  UPDATE t SET lo = CASE WHEN m.o = t.olo THEN m.mid ELSE t.lo END,
               hi = CASE WHEN m.o = t.olo THEN t.hi ELSE m.mid END
  FROM #t t
  CROSS APPLY (SELECT DATEDIFF_BIG(nanosecond, t.lo, t.hi) / 200 * 100 AS h) d
  CROSS APPLY (SELECT DATEADD(nanosecond, CAST(d.h % 1000000000 AS int), DATEADD(second, CAST(d.h / 1000000000 AS int), t.lo)) AS mid) q
  CROSS APPLY (SELECT q.mid, DATEPART(TZOFFSET, CAST(q.mid AS datetimeoffset(7)) AT TIME ZONE @z) AS o) m
  WHERE DATEDIFF_BIG(nanosecond, t.lo, t.hi) > 100;
  IF @@ROWCOUNT = 0 BREAK;
END;
SELECT (SELECT o FROM #s WHERE t = @start) AS initial;
SELECT CONVERT(varchar(27), hi, 121) AS at, olo, ohi,
       DATEPART(TZOFFSET, CAST(hi AS datetimeoffset(7)) AT TIME ZONE @z) AS ohi_check,
       DATEPART(TZOFFSET, CAST(lo AS datetimeoffset(7)) AT TIME ZONE @z) AS olo_check
FROM #t ORDER BY hi;
${probes ? `SELECT CONVERT(varchar(27), t.hi, 121) AS at, k, DATEPART(TZOFFSET, r) AS shown,
       CAST(DATEDIFF_BIG(nanosecond, CAST(SWITCHOFFSET(r, 0) AS datetime2(7)), p) / 60000000000.0 AS varchar(40)) AS used
FROM #t t
CROSS APPLY (SELECT DATEADD(minute, t.olo, t.hi) AS l, ABS(t.ohi - t.olo) AS d) b
CROSS APPLY (VALUES (0, DATEADD(nanosecond, -100, b.l)), (1, b.l), (2, DATEADD(second, b.d * 30, b.l)),
                    (3, DATEADD(nanosecond, -100, DATEADD(minute, b.d, b.l))), (4, DATEADD(minute, b.d, b.l))) v(k, p)
CROSS APPLY (SELECT v.p AT TIME ZONE @z AS r) x
WHERE t.hi >= '${PROBE_FROM}' AND t.hi < '${PROBE_TO}'
ORDER BY t.hi, k;` : ''}
DROP TABLE #s; DROP TABLE #t;`
}

const result = {
  source: 'harness/src/dump-timezones.mjs',
  server: version,
  image,
  zones,
  windows: windows.map(([start, steps]) => ({ start, steps, stepMinutes: 360 })),
  probeFrom: PROBE_FROM,
  probeTo: PROBE_TO,
  denseYearEnds: 'every 30 minutes from Dec 30 12:00 to Jan 2 12:00 UTC around each new year in a window',
  catalog,
  scans: {},
  probes: {},
}
let n = 0
for (const zone of zones) {
  const perZone = []
  for (const [wi, [start, steps]] of windows.entries()) {
    const sets = await q(scanSql(zone, start, steps, wi === 0))
    const initial = sets[0].rows[0][0]
    const transitions = sets[1].rows.map(([at, olo, ohi, ohiCheck, oloCheck]) => {
      if (ohiCheck !== ohi || oloCheck !== olo) throw new Error(`${zone} ${at}: several changes within one step`)
      return [at, olo, ohi]
    })
    perZone.push({ initial, transitions })
    if (wi === 0) {
      const probes = {}
      for (const [at, k, shown, used] of sets[2].rows) {
        (probes[at] ??= [])[k] = [shown, Number(used).toString()]
      }
      result.probes[zone] = probes
    }
  }
  result.scans[zone] = perZone
  n += 1
  process.stderr.write(`\r${n}/${zones.length} ${zone}                    `)
}
process.stderr.write('\n')
await close(c)
writeFileSync(out, JSON.stringify(result) + '\n')
