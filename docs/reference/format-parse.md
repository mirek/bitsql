# FORMAT, PARSE and .NET cultures

SQL Server runs FORMAT and PARSE/TRY_PARSE through .NET Framework culture
data. bitsql reproduces them with a generated culture table
(`src/core/exec/culture_data.mbt`, written by `harness/gen/cultures.mjs`
from the oracle's own FORMAT output; regenerate with
`node gen/cultures.mjs && moon fmt`). Rules below come from
`msduck-runs/format`, `msduck-runs/parse-try-parse`,
`functions2/format-*`, `functions2/parse-cultures` and probes on SQL
Server 17.0.5005 (Linux).

## Culture names

- Case-insensitive, `_` reads as `-` (`en_US`, `DE-de`). Any whitespace
  makes the name invalid (`'en-US '`): 9818 "The culture parameter 'x'
  provided in the function call is not supported." (NULL prints `'NULL'`).
- Well-formed tags are accepted even when unknown: a 2–3 letter language
  (`xx`, `xx-XX`, `ab-cd-ef`, `ab-123`), a one-letter prefix (`x-foo`,
  `i-klingon`, `a-b`), extensions (`en-US-x-foo`, `de-DE-u-nu-arab`).
  Rejected: `x`, `1`, `abcd`, `abcde`, `ab-c`, `ab-1`, `ab-12`, `ab-c1`,
  `ab-cdefghi`, `en--US`, `root`, language names (`German`, `Invariant`).
- An unknown language formats like the invariant culture (`iv`): 'xx-XX'
  gives `Tuesday, 05 March 2024` for `D` and `¤1.50` for `C`. A known
  language with an unknown region falls back to the language (`de-XX` is
  `de`); bitsql raises 50173/50171 for any real culture missing from its
  table instead (148 two-letter languages have data on the oracle).
- Without a culture argument the session language decides
  (`SET LANGUAGE Deutsch` formats like `de-DE`, British like `en-GB`,
  日本語 like `ja-JP`; the map follows `sys.syslanguages.lcid`).

## FORMAT numbers

- Standard formats: a letter plus at most two digits (`N99` is standard,
  `N100` custom: `N1` + `00` → `N11234`; `''` is `G`). Unknown letters
  (`B`, `Q`) and type mismatches (`D`/`X` on decimal or float, `R` on
  integers and decimals) are .NET FormatExceptions: FORMAT returns NULL.
- Digit buffers as in .NET Framework: integers and decimal/money exactly
  (money has scale 4: `G` of 2 money is `2.0000`), float to 15 significant
  digits (17 for `G16`+ and `E15`+), real to 7 (9). Rounding is half away
  from zero on the digit string and a result that rounds to zero loses its
  sign (`-0.001` with `N2` is `0.00`).
- `G` without precision: decimal prints every digit with its scale and no
  exponent (`42.50`, 38-digit decimals in full); float uses 15 digits and
  scientific notation when the exponent is ≥ 15 or < -4
  (`1.23456789012346E+20`, `1E-05`). `R` tries 15 digits and falls back to
  17 when that does not round-trip.
- Custom formats follow .NET's NumberToStringFormat: sections (`;`, an
  empty negative section reuses the first with a sign, a value rounding
  to zero switches to the zero section), `,` grouping and scaling,
  `%`/`‰`, `E+0`, quotes and `\`. Quirk: for decimal and money a format
  that starts with a quote prints its digit placeholders literally
  (`'a'0` → `a0`, `-a0` for -5) while int and float print `a5`.
- A NULL format string formats like `G` (`FORMAT(1234.5, CAST(NULL AS
  nvarchar(10)), 'de-DE')` is `1234,50`); a NULL literal is 8116 at bind.

## FORMAT dates and times

- date, datetime, datetime2, smalldatetime are DateTime (datetime arrives
  as SqlDateTime: whole milliseconds); datetimeoffset is DateTimeOffset.
- Standard formats come from the culture (`d D f F g G M Y t T`), plus
  culture-invariant `O` (with `zzz` for datetimeoffset), `R` and `u` (UTC
  for datetimeoffset), `s` (local clock). `U` is the long full pattern for
  DateTime and NULL for datetimeoffset. Any other single letter (`K`, `x`)
  is NULL; use `%K` for a single custom specifier.
- Custom: `y`..`yyyyy`, `M`..`MMMM` (genitive month names when the format
  also has `d`/`dd`: ru-RU `d MMMM` is `5 марта`), `d`..`dddd`, `h`/`H`
  (runs longer than two act as two), `m`, `s`, `f`..`fffffff` (eight is
  NULL), `F` trims zeros and drops a preceding `.` when nothing is left,
  `t`/`tt`, `z`..`zzz` (DateTime reads the server zone: `+00:00`), `K`,
  `g` (`A.D.`), `:` and `/` as the culture's separators.
- th-TH uses the Thai Buddhist year (+543). ar-SA uses Um Al-Qura (not
  emulated: 50173).
- time is a TimeSpan: `c`/`t`/`T` → `hh:mm:ss[.fffffff]`, `g` →
  `h:mm:ss[,FFFFFFF]` and `G` → `0:hh:mm:ss,fffffff` with the culture's
  decimal separator; custom formats take `d h m s f F` and quoted or
  escaped literals only (`hh:mm` is NULL, `hh\:mm` works); `D` is NULL.
- The result is nvarchar(4000); a format argument longer than 4000
  characters was already truncated by its type.

## PARSE / TRY_PARSE

- Numbers use the culture's NumberStyles symbols: decimal and group
  separators (a no-break space separator also matches a plain space, but
  not U+202F), signs, the currency symbol for money (currency separators
  first, the number ones before the symbol). Native digits are not digits
  (`١٢` fails).
- Dates take the culture's month and day names (full, abbreviated,
  genitive) and its short-date field order: `01/02/2010` is 1 February in
  en-GB, `02.01.2024` 2 January in de-DE, `23-11-2009` works in nl-NL,
  `2. Januar 2024` in de-DE, `23 de novembro de 2009` in pt-BR. Non-
  Gregorian cultures (ar-SA, th-TH) are emulator errors for dates.
- The 9819 message names the target type as SQL Server spells it
  (`numeric` for decimal) and the culture as written (`''` without USING).
- An ISO 8601 text whose fraction rounds past 9999-12-31 is a .NET
  ArgumentOutOfRangeException (6521 state 2, DateTime2 stack trace).
- A user alias type as target is 10761 state 2 naming it as written.
