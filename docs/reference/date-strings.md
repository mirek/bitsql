# Character strings → date/time

SQL Server 17.0.5005.3 under `SET LANGUAGE us_english` / `SET DATEFORMAT mdy`
(the defaults). Derived from captures: `harness/corpus/datestrings/*.cases.json`
(generator `harness/gen/datestrings.mjs`; every string × datetime,
smalldatetime, date, time, datetime2, datetimeoffset, plus ISDATE, implicit
conversions and CONVERT styles). Implementation:
`src/core/types/date_parse.mbt`, hooked in `convert_temporal.mbt`.

## Two parsers

| | legacy (datetime, smalldatetime) | new (date, time, datetime2, datetimeoffset) |
| --- | --- | --- |
| whitespace | U+0020 only (TAB, CR, LF, NBSP fail) | U+0020 and TAB (CR, LF, VT, FF fail) |
| syntax error | 241 state 1 (smalldatetime: 295 state 3 "Conversion failed when converting character string to smalldatetime data type.") | 241 state 1 |
| invalid field / duplicate part | 242 state 3 "The conversion of a varchar data type to a datetime data type resulted in an out-of-range value." (also for 13/1/2024, 2/30, 25:00) | 241 state 1 |
| range | datetime 1753-01-01..9999-12-31 23:59:59.997, smalldatetime 1900-01-01..2079-06-06 23:59:29.998, both 242 | datetimeoffset whose local or UTC instant leaves 0001..9999: 8114 state 31 |
| batch | 241 and 295 abort the batch; 242 ends only the statement | 241 aborts; 8114 aborts |

Empty or all-space strings are 1900-01-01 00:00:00 for every type (ISDATE
returns 0 for them). TRY_CAST/TRY_CONVERT turn 241, 242, 295, 8114 and 9807
into NULL. ISDATE(x) is 1 exactly when CAST(x AS datetime) succeeds.

Errors are raised at run time (after COLMETADATA), not while compiling a
literal. Completions (`implicit.cases.json`): a batch-ending 241/245/295 in
an assignment (`DECLARE @d datetime = 'x'`, `SET @d = …`, `SELECT @d = …`)
or an INSERT ends with DONE CurCmd 253 (a SELECT that already sent its
COLMETADATA keeps 193); a 242 in UPDATE is followed by INFO 3621 "The
statement has been terminated." with CurCmd 197.

## Shapes accepted by both

- Numeric dates `m/d/y` with `/`, `-` or `.`; spaces around the separators
  are fine (`1 / 2 / 2024`). A leading 4-digit part is the year
  (`2024/1/2`, `2024.1.2`).
- Two-digit years: 0–49 → 20xx, 50–99 → 19xx (two digit year cutoff 2049);
  one digit too (`1/2/0` is 2000-01-02).
- Unseparated `yyyy` (January 1), `yymmdd`, `yyyymmdd`; 5, 7, 9+ digits fail.
- Month names: the 12 full names and 3-letter abbreviations, any case
  (`Sept`, `Janu` fail). Components in any order: `Jan 2 2024`,
  `2 Jan 2024`, `2024 Jan 2`, `2 2024 Jan`, `2024 2 Jan`, `Jan 2024 2`. A
  4-digit number is the year; otherwise the first number is the day and the
  second the year (`24 Jan 2` = 2002-01-24, `Jan 2 3` = 2003-01-02). A lone
  4-digit number is the year with day 1 (`Jan 2024`); a lone short number
  fails (`Jan 2`, `Jan 24`). `n-Mon-n` with `-`, `/` or `.` works
  (`02-JAN-24`, `2024/Jan/02`); `Jan-2-2024` does not.
- Times `h:mi[:ss[.fff…]]`, `h:mi:ss:mmm` (colon milliseconds, 1–3 digits:
  `:5` = 5 ms), `h AM`, `hAM`, `h:mi PM` (case-insensitive). AM/PM: `12 AM`
  = 0, `13 PM` = 13, `0 PM` and `13 AM` fail. Hour > 23, minute or second >
  59 fail (`24:00` too).
- Time only: the date is 1900-01-01. Date only into `time`: 00:00:00.
- ISO `yyyy-mm-ddThh:mi:ss[.f…][Z]` (uppercase T and Z only).

## Legacy-only behaviour

- The time may stand anywhere: `10:11 1/2/2024`, `Jan 10:11 2 2024`,
  `1/2 10:11 /2024` all work.
- Mixed separators (`1/2-2024`), 3-digit month/day (`001/02/2024`), the
  4-digit year in the middle (`1/2024/2` = m/y/d).
- Year widths: 1–2 digits windowed, 3 digits windowed below 100 (`1/2/024` is
  2024, `1/2/123` is year 123 → 242), 4 literal (`0024` → 242), 5 → 241.
- At most 3 fraction digits (`.1234` → 241). `10:11.5` is 10:11:00.500.
  Hour/minute/second fields may have 3 digits (`010:10`).
- Commas between month-name components: `Jan, 2 2024`, `2,Jan,2024`; a comma
  after a 4-digit year, a doubled, leading or trailing comma → 242.
- `T` only in the strict form `yyyy-mm-ddThh:mi:ss[.fff]` (2-digit fields),
  optionally followed by `Z` and/or AM/PM (with or without a space);
  `T…10:11` without seconds, `20240102T…`, `1/2/2024T…` → 241; a leading `T`
  or `yyyyT` → 242. `Z` also after `yyyy-mm-dd` (`2024-01-02Z`, `… Z`), after
  a lone year (`2024Z`) and after a time-only string (`10:11Z`); elsewhere
  241. Offsets (`+05:30`) → 241.
- 241 vs 242 (value errors): an invalid month/day/hour, a second date or
  time, a date followed by extra numbers or separators (`1/2/2024/`,
  `1/2/2024 5`, `1//2/2024`), two month names, AM/PM without a time
  (`AM`, `PM 10:11`). Syntax errors (241): unknown words or characters,
  incomplete dates (`1/2`, `1/2/`, `Jan`), lone short numbers (`10`,
  `2024 10`), leading `/`/`-`/`.`, malformed times (`10:`, `10::11`,
  `10:11:12.`).

## New-parser-only behaviour

- Month/day 1–2 digits, years 1, 2 or 4 digits (`1/2/024` fails); no time
  before the date; a single separator kind.
- Up to 7 fraction digits; more are rounded half up at the 8th
  (`.12345678` → `.1234568`, `.000000000` fine).
- Offsets after a time (only): `Z`, `+hh:mi`, `-h:m`, with or without a space
  before (`10:11:12 +05:30`, `10:11Z`, `+ 01:00`), at most ±14:00, minutes ≤
  59; `+0530`, `+05`, `+001:00` fail. `yyyy-mm-ddZ` (no space) is the only
  date-only form with Z. datetime2/date/time drop the offset.
- In the `T` form the hour has two digits, seconds are required, no spaces
  and no AM/PM; offsets follow directly (`…12+05:30`, `…12Z`).
- Commas only directly before a trailing year: `January 2, 2024`,
  `2 Jan, 2024`; `Jan, 2 2024`, `Jan 2024, 2` fail.

## CONVERT styles (character → date/time)

bitsql implements 0, 1–5, 10, 11, 20, 21, 101–105, 110–112, 120, 121, 126,
127 (`styles.cases.json`); any other style raises Emulator 50105.

- Order: mdy (1, 10, 101, 110), dmy (3, 4, 5, 103, 104, 105), ymd (2, 11,
  102, 111, 20, 21, 120, 121, 126, 127). Styles below 100 need 2-digit years
  in separated numeric dates, the others 4 digits (violations → 241).
- Legacy parser: a 4-digit part is still the year wherever it stands, and the
  other two keep the style's month/day order (`2024-31-12` under 103 is
  2024-12-31; `2024/12/31` under 103 → 242). The `T` form is rejected (242
  for 4-digit numeric styles, 241 for the 2-digit ones and 112), `Z` → 241
  unless the style is 0 or 127. 112 rejects separated dates (241). 126 and
  127 accept separated dates only as strict `yyyy-mm-dd[Thh:mi:ss[.fff]]`;
  127 also rejects month names and 6/8-digit numbers.
- New parser: the year sits where the style puts it (`2024/12/31` under 101
  → 241). `T` forms, `yyyy-mm-ddZ`, month names, unseparated numbers and
  times are accepted under every style. 112 rejects separated dates with
  9807 state 0 "The input character string does not follow style 112,
  either change the input character string or use a different style." (also
  for `1/2/2024T10:11`).
- Seen but not implemented: 9807 for 12/100/106/107/113/114/… on the new
  parser, 9809 "The style N is not supported for conversions from varchar to
  date." for 15, 19, 26, 33, 128, 140, 141, -1; Hijri styles 130/131.

## Not modelled

- `SET DATEFORMAT` other than mdy and `SET LANGUAGE` other than us_english
  raise 50100: conversions in `src/core/types` have no session context.
