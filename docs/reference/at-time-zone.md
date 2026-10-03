# AT TIME ZONE and sys.time_zone_info

SQL Server 17.0.5005.3 behaviour, derived from captures: msduck
`at-time-zone*` cases (`harness/corpus/msduck/at-time-zone*.cases.json`),
`harness/corpus/timezone/at-time-zone.cases.json` (generator
`harness/gen/timezone.mjs`) and the rule dump
`scripts/timezones/sqlserver-timezones.json`. Implementation:
`src/core/types/timezone.mbt` (+ generated `timezone_data.mbt`),
`src/core/bind/fn_timezone.mbt`, `src/core/exec/fn_timezone.mbt`,
`src/core/session/sysviews_timezone.mbt`.

## Binding

- Argument 1: `datetime`, `smalldatetime`, `datetime2(n)`, `datetimeoffset(n)`
  or a bare NULL. Anything else (date, time, character strings, numbers,
  sql_variant, binary) is 8116 "Argument data type X is invalid for argument 1
  of AT TIME ZONE function." at compile time (no result set).
- Argument 2: any character type or a bare NULL; otherwise 8116 for argument 2.
- Result: `datetimeoffset(s)` with s = the input scale (datetime 3,
  smalldatetime 0, bare NULL 7), always nullable (flags 33 in a SELECT list).
- `x AT TIME ZONE N'a' + N'b'` is `(x AT TIME ZONE N'a') + N'b'` (402).

## Zone names

- The 141 names of `sys.time_zone_info` (Windows names; `UTC`, not `GMT` or
  `Etc/UTC`; no IANA names).
- ASCII case-insensitive. U+0000 is ignored anywhere (`N'UT' + NCHAR(0) + N'C'`
  works). U+212A KELVIN SIGN matches `k`; no other non-ASCII character folds
  (`ſ`, `ı`, `İ`, fullwidth letters, combining accents all fail).
- Spaces are significant: `N' UTC'`, `N'UTC '` and `CAST('UTC' AS char(10))`
  are invalid.
- Unknown name: 9820, state 1, severity 16, "The time zone parameter '<name>'
  provided to AT TIME ZONE clause is invalid.", raised at run time (the
  COLMETADATA has already been sent). U+0000 is shown as `.` in the message.
- NULL zone or NULL input: NULL.

## Semantics

- `datetimeoffset` input: the same instant shown with the zone's offset at
  that instant. If the shown local time leaves 0001-01-01..9999-12-31 the
  result is clamped, without error, to the minimum UTC value at `+00:00` or
  to the maximum at the result scale (`9999-12-31 23:59:59.9999999 +00:00`,
  `.999` for scale 3).
- `datetime`, `smalldatetime`, `datetime2` input: a wall-clock time in the
  zone. A UTC result outside the datetimeoffset range is 9813 "The timezone
  provided to builtin function AT TIME ZONE would cause the datetimeoffset to
  overflow the range of valid date range in either UTC or local time."
- Repeated wall times (clocks set back) and skipped ones (clocks set
  forward) are read in the offset *before* the change: DST end overlaps are
  daylight time (the earlier instant); DST start gaps are read in standard
  time and land after the change, showing the new offset (`2024-03-10 02:30`
  Pacific → `03:30 -07:00`). 48 changes (mostly one-off base offset changes,
  e.g. Turkey 2016-03-27, Venezuela 2016-05-01, and year-boundary rule
  switches such as Turks And Caicos 2018-01-01) are read in the offset after
  the change instead (`tz_after_picks`, fitted to probes; a range spanning a
  new year can differ on each side, Samoa 2011-12-31).

## The rule model

Windows time zones have yearly rules; SQL Server extrapolates the first
yearly rule back to year 1 and the last one forward to 9999. bitsql stores,
per zone, segments of the UTC timeline (fixed offset or annual rule, 644 in
total, 33 KB of source) plus the annual rules (`tz_rules`).

An annual rule's offset at UTC instant u is decided like this (the only
formulation found that reproduces every scanned transition, including the
oddities at year ends):

- rule year Y = year of the standard-time wall clock (u + standard offset);
- D = the daylight-time wall clock (u + daylight offset) with its year
  replaced by Y;
- DST start = Y's start date + time (a standard wall time) shifted by the
  daylight delta; DST end = Y's end date + time (a daylight wall time);
- northern rule (start month < end month): DST iff start <= D < end;
  otherwise DST iff D < end or D >= start.

Consequence (captured): Central Brazilian Standard Time's extrapolated rule
ends DST on the first Thursday of January at 00:00; in 1903 (Jan 1 is that
Thursday) the change happens at 04:00 UTC instead of 03:00, and on
1904-01-01 03:00–04:00 UTC the zone shows standard time for one hour.

## sys.time_zone_info

- Columns: `name nvarchar(128)`, `current_utc_offset nvarchar(6)`,
  `is_currently_dst bit`, all NOT NULL; the database default collation.
- Row order without ORDER BY: catalog order (Dateline, UTC-11, Aleutian,
  Hawaiian, …), kept in `tz_names`.
- "Current" means: the server's *local* clock read as a wall-clock time in
  each zone, not the UTC instant. Captured at 2026-10-03 20:37 UTC on a UTC
  server: AUS Eastern Standard Time showed `+10:00` / not DST, while
  `SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE name` already gave
  `+11:00` (DST began at 02:00 local on Oct 4). bitsql's server clock is UTC,
  so it resolves the request clock (`Runtime.now`) as local time per zone.
- `is_currently_dst`: inside an annual rule, the daylight offset; for fixed
  segments, an increase reversed by the next change within a year (Morocco,
  West Bank 2026: true; Syria, Magallanes permanent shifts: false).

## Data source and regeneration

Everything is SQL Server's own answer; no IANA or registry data is used.

1. `harness/src/dump-timezones.mjs` (run against the oracle image; a private
   `bitsql-oracle-tz` container on 47345 avoids the shared one) scans every
   zone in 6-hour steps from 1899-12 to 2101-12 plus 37 sample years from 1 to
   9999 (every 30 minutes around each new year, where year-rule switches
   cause short blips), refines every change to the exact 100 ns tick, probes
   local times around every 1970–2060 change, and snapshots
   `sys.time_zone_info`. About 13 minutes; 2.4 MB JSON.
2. `python3 scripts/gen-timezones.py` fits the segments and rules, checks them
   against every scanned window, probe and the catalog snapshot (failing
   loudly), writes `timezone_data.mbt` and the test table
   `timezone_data_test.mbt` (6145 changes and 4718 local probes from the
   dump, checked against the MoonBit port).
3. `moon fmt && moon test -p mirek/bitsql/core/types`.

Cross-check (2026-10-03, `scripts/timezones/xcheck-msduck.py`): msduck's independent history captures
(`reference/at-time-zone-history-*.json`, SQL Server 17.0.4065.4, daily
offsets 0001–2500) agree on all 345,109 daily changes except 47 artifacts of
the year-1 clamp described above.

## Coverage limits

- Local (datetime/datetime2) input in two zone-years is not reproduced and
  raises `Emulator: AT TIME ZONE on <year> local times in '<zone>' …`:
  Volgograd Standard Time 2020 (SQL Server reads Jan 1 00:00–01:00 local as
  +05:00) and Samoa Standard Time 2009.
- Local-time resolution is probed only around changes between 1970 and 2060;
  elsewhere only regular annual-rule changes occur (the generator marks any
  other change outside that range unsupported).
- Changes that cancel within 6 hours (or within 30 minutes near a new year)
  could be missed by the scan.
- The rules are those of the captured image; a SQL Server update with new
  Windows time zone data needs a fresh dump.
