// Calendar arithmetic, scale rounding and
// text formatting. All integer: days since 0001-01-01 and 100 ns ticks.

///|
pub const TICKS_PER_SECOND : Int64 = 10_000_000L

///|
pub const TICKS_PER_MINUTE : Int64 = 600_000_000L

///|
pub const TICKS_PER_DAY : Int64 = 864_000_000_000L

///|
/// 1/300 s units per day (legacy datetime).
pub const DATETIME_UNITS_PER_DAY : Int = 25_920_000

///|
/// Days from 0001-01-01 to 9999-12-31.
pub const MAX_DAYS : Int = 3_652_058

///|
/// Days from 0001-01-01 to 1900-01-01 (legacy datetime epoch).
pub const DAYS_TO_1900 : Int = 693_595

///|
/// Days from 0001-01-01 to 1753-01-01 (legacy datetime minimum).
pub const DAYS_TO_1753 : Int = 639_905

///|
/// Days from 0001-01-01 to 2079-06-06 (smalldatetime maximum).
pub const DAYS_TO_2079_06_06 : Int = 759_130

///|
/// Proleptic Gregorian date → days since 0001-01-01 (no validation).
pub fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = (month + 9) % 12
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468 + 719162
}

///|
/// Days since 0001-01-01 → (year, month, day).
pub fn civil_from_days(days : Int) -> (Int, Int, Int) {
  let z = days - 719162 + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let y = yoe + era * 400 + (if m <= 2 { 1 } else { 0 })
  (y, m, d)
}

///|
fn is_leap(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

///|
fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    _ => if is_leap(y) { 29 } else { 28 }
  }
}

///|
/// Is (y, m, d) a valid date in 0001-01-01 .. 9999-12-31?
pub fn is_valid_date(year : Int, month : Int, day : Int) -> Bool {
  year >= 1 &&
  year <= 9999 &&
  month >= 1 &&
  month <= 12 &&
  day >= 1 &&
  day <= days_in_month(year, month)
}

///|
/// 10^(7 - scale) ticks: the unit of a temporal scale.
pub fn scale_unit(scale : Int) -> Int64 {
  let mut u = 1L
  for _ in 0..<(7 - scale) {
    u = u * 10L
  }
  u
}

///|
/// Round non-negative ticks to a temporal scale, half up (SQL Server rounds
/// datetime2/time/datetimeoffset scale reductions: msduck
/// reference/temporal-guid-format.json, `2024-02-29T23:59:59.9999999` as
/// DATETIME2(0) is `2024-03-01 00:00:00`).
pub fn round_ticks(ticks : Int64, scale : Int) -> Int64 {
  let unit = scale_unit(scale)
  if unit == 1L {
    ticks
  } else {
    (ticks + unit / 2L) / unit * unit
  }
}

///|
/// Round time-of-day ticks to a scale without leaving the day: a value that
/// would round to 24:00:00 is clamped to the last representable unit
/// (captured: `23:59:59.9999999` as TIME(0) is `23:59:59`, as TIME(3)
/// `23:59:59.999`; msduck reference/temporal-guid-format.json). Whether
/// SQL Server rounds or truncates mid-day for TIME is unverified; bitsql
/// rounds, like datetime2.
pub fn round_time_ticks(ticks : Int64, scale : Int) -> Int64 {
  let r = round_ticks(ticks, scale)
  if r >= TICKS_PER_DAY {
    TICKS_PER_DAY - scale_unit(scale)
  } else {
    r
  }
}

///|
/// 100 ns ticks → legacy datetime 1/300 s units, half up (captured:
/// .001→.000, .002→.003, .005→.007, .998→.997, .999→next second).
pub fn ticks_to_datetime_units(ticks : Int64) -> Int64 {
  (ticks * 3L + 50_000L) / 100_000L
}

///|
/// Legacy datetime 1/300 s units → 100 ns ticks (rounded half up).
pub fn datetime_units_to_ticks(units : Int) -> Int64 {
  (units.to_int64() * 100_000L + 1L) / 3L
}

///|
/// A parsed date/time literal before it is fitted to a target type.
pub(all) struct ParsedTemporal {
  /// (year, month, day) if a date was present
  date : (Int, Int, Int)?
  /// time of day in 100 ns ticks if a time was present
  time : Int64?
  /// number of fractional-second digits written
  fraction_digits : Int
  /// UTC offset in minutes if present (`Z` = 0)
  offset : Int?
} derive(Debug, Eq)

///|
/// Why a string did not parse as a date/time.
pub(all) suberror TemporalParseError {
  /// Not a valid date/time: SQL Server error 241.
  Invalid
} derive(Debug, Eq)

///|
fn is_digit(c : UInt16) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Trim leading and trailing U+0020 only (SQL Server conversions trim ASCII
/// spaces, not tabs or other whitespace: msduck reference/unicode-integer.json).
pub fn trim_spaces(s : String) -> String {
  let n = s.length()
  let mut a = 0
  while a < n && s[a] == ' ' {
    a += 1
  }
  let mut b = n
  while b > a && s[b - 1] == ' ' {
    b -= 1
  }
  if a == 0 && b == n {
    s
  } else {
    s.unsafe_substring(start=a, end=b)
  }
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn pad_n(n : Int64, width : Int) -> String {
  let s = n.to_string()
  if s.length() >= width {
    s
  } else {
    String::make(width - s.length(), '0') + s
  }
}

///|
/// `yyyy-mm-dd`
pub fn format_date_iso(days : Int) -> String {
  let (y, m, d) = civil_from_days(days)
  pad_n(y.to_int64(), 4) + "-" + pad2(m) + "-" + pad2(d)
}

///|
/// `hh:mi:ss` plus `.` and `digits` fraction digits (none when 0).
pub fn format_time_iso(ticks : Int64, digits : Int) -> String {
  let secs = ticks / TICKS_PER_SECOND
  let frac = ticks % TICKS_PER_SECOND
  let h = (secs / 3600L).to_int()
  let mi = (secs / 60L % 60L).to_int()
  let s = (secs % 60L).to_int()
  let base = pad2(h) + ":" + pad2(mi) + ":" + pad2(s)
  if digits <= 0 {
    base
  } else {
    base + "." + pad_n(frac, 7).unsafe_substring(start=0, end=digits)
  }
}

///|
let month_abbrev : Array[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
/// Style 0/100 date part: `Mon dd yyyy` with the day space-padded
/// (`Jan  2 2024`), us_english month names.
pub fn format_date_style0(days : Int) -> String {
  let (y, m, d) = civil_from_days(days)
  let dd = if d < 10 { " " + d.to_string() } else { d.to_string() }
  month_abbrev[m - 1] + " " + dd + " " + pad_n(y.to_int64(), 4)
}

///|
/// Style 0/100 time part: `hh:miAM` with a space-padded 12-hour clock
/// (` 2:00PM`, `12:04AM`).
pub fn format_time_style0(ticks : Int64) -> String {
  let mins = (ticks / TICKS_PER_MINUTE).to_int()
  let h24 = mins / 60
  let mi = mins % 60
  let h12 = if h24 % 12 == 0 { 12 } else { h24 % 12 }
  let hh = if h12 < 10 { " " + h12.to_string() } else { h12.to_string() }
  hh + ":" + pad2(mi) + (if h24 < 12 { "AM" } else { "PM" })
}

///|
/// ` +hh:mm` / ` -hh:mm` suffix (with the leading space) for an offset.
pub fn format_offset(minutes : Int) -> String {
  let sign = if minutes < 0 { "-" } else { "+" }
  let m = if minutes < 0 { -minutes } else { minutes }
  sign + pad2(m / 60) + ":" + pad2(m % 60)
}
