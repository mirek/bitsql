# CONVERT styles and storage bytes

Rules derived from captures on SQL Server 2025 (17.0.5005.3), us_english.
Evidence: msduck `gaps-conversion` (format-*, parse-*, binary-*),
`concat-numeric-format`, and `harness/corpus/conversion/*`
(`hijri`, `input-styles`, `output-styles`, `numeric-styles`). Code:
`src/core/types/temporal_styles.mbt`, `hijri.mbt`, `date_parse.mbt`
(`date_style`), `float_bytes.mbt`, `convert_text.mbt`.

## Date/time → character

| Style | date | time | datetime / smalldatetime | datetime2 / datetimeoffset |
| --- | --- | --- | --- | --- |
| 0, 100 | `Jan  2 2024` | `3:04AM` (hour unpadded) | `Jan  2 2024  3:04AM` | same, dto adds ` +05:30` |
| 1-7, 10-12, 101-107, 110-112 | the date | 8114 | the date (no time) | the date (no offset) |
| 8, 24, 108 | 8114 | `03:04:05` | `03:04:05` | `03:04:05` (+ offset) |
| 9, 109 | `Jan  2 2024` | `3:04:05.1234567AM` | `Jan  2 2024  3:04:05:123AM` | `.fffffff` per scale (+ offset) |
| 13, 113 | `02 Jan 2024` | `03:04:05.1234567` | `02 Jan 2024 03:04:05:123` | `.fffffff` (+ offset) |
| 14, 114 | 281 | `03:04:05.1234567` | `03:04:05:123` | (+ offset) |
| 20, 120 | ISO date | `03:04:05` | `yyyy-mm-dd hh:mi:ss` | (+ offset) |
| 21, 25, 121 | ISO date | `.fffffff` | `.mmm` | `.fffffff` per scale (+ offset) |
| 22 | `01/02/24` | ` 3:04:05 AM` | `01/02/24  3:04:05 AM` | (+ offset) |
| 23 | ISO date | 8114 | ISO date | ISO date |
| 26-30 (undocumented) | yyyy-dd-mm, mm-dd-yyyy, mm-yyyy-dd, dd-mm-yyyy, dd-yyyy-mm | `03:04:05.fffffff` | that date + ` hh:mi:ss.mmm` | + `.fffffff` (+ offset) |
| 31-35 (undocumented) | the same dates alone | 8114 | the date | the date |
| 115 | `000000` | 8114 | `hhmmss` | `hhmmss` (no offset) |
| 126 | ISO date | fraction only if non-zero | `T`, fraction only if non-zero | `T`, dto `+05:30` |
| 127 | as 126 | as 126 | as 126 | dto in UTC with `Z` |
| 130, 131 | Hijri date | ` 3:04:05.1234567AM` | Hijri date + ` 3:04:05:123AM` | (+ offset) |
| anything else (15-19, 36-99, 116-119, 122-125, 128, 129, 132+) | 281 | 281 | 281 | 281 |

- datetime/smalldatetime write milliseconds with `:` in 9/13/14/109/113/114/
  130/131 and `.` in 21/25/121; scale-0 types write no fraction.
- AM/PM hours are space-padded to two characters except in styles 0/9/100/109
  of a time value alone.
- 8114 is "Error converting data type time to varchar." (state 5, target
  type named); 281 is "15 is not a valid style number when converting from
  datetime to a character string." (state 1). TRY_CONVERT turns both into
  NULL.
- Hijri (130/131) uses Microsoft's "Kuwaiti algorithm" (.NET HijriCalendar
  arithmetic, adjustment 0); dates before 622-07-18 are 9814 state 0. Style
  130 prints Arabic month names (`جمادى الثانية`), which become `?` in
  varchar; 131 prints `dd/mm/yyyy`; the day is space-padded.

## Character → date/time (CONVERT input styles)

- Text styles 6-9, 12-14, 24, 100, 106-109, 113, 114 accept no separated
  numeric date (like 112): the new parser raises 9807, the legacy one 241.
- 22 is mm/dd/yy and 23/25 yyyy-mm-dd for date/time2/datetimeoffset, but
  text-only for datetime/smalldatetime.
- 130/131 read `dd/mm/yyyy` (4-digit year) as a Hijri date; the legacy parser
  takes both, the new parser only 131. A time alone falls on Hijri 1900-01-01
  (= 2464-12-29). An invalid Hijri day is 242 (legacy) / 241 (new); beyond
  9999-12-31 is 242 state 3 for both. Style 130 with Arabic month names
  (legacy only) is an Emulator error in bitsql.
- Any other style number: 9809 state 1 "The style 99 is not supported for
  conversions from nvarchar to datetime2." for the new parser (TRY_CONVERT:
  NULL); the legacy parser treats it like 112.

## Run-time styles

`CONVERT(t, x, @s)` evaluates the style per row; a NULL style gives NULL;
non-integer style types (varchar, bit, decimal) are 8116 state 1 "Argument
data type varchar is invalid for argument 3 of convert function."; bigint is
accepted.

## Numbers → character

- float: 1 = 8 significant digits, 2 = 16, 3 = 17 (real too, of its double
  value), 126 = 16 for float / 8 for real, every other style number = style 0.
- money: 0 `1.50`, 1 with thousands separators, 2 and 126 four decimals,
  every other number = style 0.

## Storage bytes (CONVERT to binary/varbinary)

| Type | Bytes |
| --- | --- |
| float / real | IEEE binary64 / binary32, big-endian |
| money / smallmoney | 1/10000 units as big-endian int64 / int32 |
| decimal(p,s) | p, s, 0, sign (1 positive or zero, 0 negative), magnitude little-endian in the fewest whole 4-byte groups (12.5 as numeric(12,3): `0C030001D4300000`) |

Integers, float and money keep their low-order end when cut and are
zero-padded on the left into binary(n); decimal bytes keep their head when
cut but are padded on the left too. binary → float/real is 529. binary →
money takes the last 8 (4) bytes; binary → decimal reads the layout above
(shorter than 4 + storage: 8114 state 5; precision > 38: 8115 state 6;
scale > precision: 8114; every byte after the header is magnitude, so a
9-byte `0x050201003930000000` is -123.45).

## Binary ↔ character

Styles 1 (`0x…`) and 2 (hex) cut to whole bytes when the target is short
(`CONVERT(varchar(3), 0x0A0B, 1)` is `0x`); any style other than 0/1/2 is
9809 ("…from varbinary to varchar.").
