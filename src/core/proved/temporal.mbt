// Calendar and tick arithmetic behind every date/time type (specs in
// temporal.mbtp). Days count from 0001-01-01, ticks are 100 ns. The contracts
// cover the SQL Server range (0001-01-01 .. 9999-12-31) and prove that
// nothing in it overflows; `@types` re-exports these under the same names.

///|
/// Proleptic Gregorian date → days since 0001-01-01. Any day 1..31 is
/// accepted (no validation), and the result stays in the date range.
pub fn days_from_civil(
  year : Int,
  month : Int,
  day : Int,
) -> Int where {
  proof_require: 1 <= year && year <= 9999,
  proof_require: 1 <= month && month <= 12,
  proof_require: 1 <= day && day <= 31,
  proof_ensure: result => 0 <= result && result <= 3652058,
} {
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
pub fn civil_from_days(
  days : Int,
) -> (Int, Int, Int) where {
  proof_require: 0 <= days && days <= 3652058,
  proof_ensure: result => civil_shape(result),
} {
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
/// 10^(7 - scale) ticks: the unit of a temporal scale.
pub fn scale_unit(
  scale : Int,
) -> Int64 where {
  proof_require: 0 <= scale && scale <= 7,
  proof_ensure: result => result == pow10(7 - scale),
} {
  for i = 0, u = 1L; i < 7 - scale; {
    continue i + 1, u * 10L
  } nobreak {
    u
  } where {
    proof_invariant: 0 <= i && i <= 7 - scale,
    proof_invariant: u == pow10(i),
    proof_reasoning: "u = 10^i, and i stops at 7 - scale",
  }
}

///|
/// Round non-negative ticks (up to 9999-12-31 23:59:59.9999999) to a
/// temporal scale, half up (SQL Server rounds datetime2/time/datetimeoffset
/// scale reductions: captured-runs/temporal-guid-format,
/// `2024-02-29T23:59:59.9999999` as DATETIME2(0) is `2024-03-01 00:00:00`).
pub fn round_ticks(
  ticks : Int64,
  scale : Int,
) -> Int64 where {
  proof_require: 0L <= ticks && ticks <= 3155378975999999999L,
  proof_require: 0 <= scale && scale <= 7,
  proof_ensure: result => rounded_half_up(ticks, pow10(7 - scale), result),
} {
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
/// `23:59:59.999`; captured-runs/temporal-guid-format). Whether
/// SQL Server rounds or truncates mid-day for TIME is unverified; bitsql
/// rounds, like datetime2.
pub fn round_time_ticks(
  ticks : Int64,
  scale : Int,
) -> Int64 where {
  proof_require: 0L <= ticks && ticks < 864000000000L,
  proof_require: 0 <= scale && scale <= 7,
  proof_ensure: result => 0L <= result && result < 864000000000L,
  proof_ensure: result => result % pow10(7 - scale) == 0L,
} {
  proof_assert 1L <= pow10(7 - scale) && pow10(7 - scale) <= 10000000L
  proof_assert 864000000000L % pow10(7 - scale) == 0L
  let r = round_ticks(ticks, scale)
  if r >= 864_000_000_000L {
    864_000_000_000L - scale_unit(scale)
  } else {
    r
  }
}

///|
/// 100 ns ticks of a day → legacy datetime 1/300 s units, half up (captured:
/// .001→.000, .002→.003, .005→.007, .998→.997, .999→next second). The last
/// 1/600 s of a day rounds to a full day (25_920_000): use `datetime_parts`
/// to carry it.
pub fn ticks_to_datetime_units(
  ticks : Int64,
) -> Int64 where {
  proof_require: 0L <= ticks && ticks < 864000000000L,
  proof_ensure: result => 0L <= result && result <= 25920000L,
  proof_ensure: result => result == day_units(ticks),
} {
  (ticks * 3L + 50_000L) / 100_000L
}

///|
/// Legacy datetime 1/300 s units of a day → 100 ns ticks (rounded half up);
/// `ticks_to_datetime_units` maps the result back to `units`.
pub fn datetime_units_to_ticks(
  units : Int64,
) -> Int64 where {
  proof_require: 0L <= units && units < 25920000L,
  proof_ensure: result => 0L <= result && result < 864000000000L,
  proof_ensure: result => day_units(result) == units,
} {
  (units * 100_000L + 1L) / 3L
}

///|
/// Ticks since 0001-01-01 → legacy datetime (days since 0001-01-01, 1/300 s
/// units, both Int64), carrying a time that rounds up to midnight into the next day.
pub fn datetime_parts(
  ticks : Int64,
) -> (Int64, Int64) where {
  proof_require: 0L <= ticks && ticks <= 3155378975999999999L,
  proof_ensure: result => datetime_parts_ok(ticks, result),
} {
  let days = ticks / 864_000_000_000L
  let units = ticks_to_datetime_units(ticks % 864_000_000_000L)
  if units == 25_920_000L {
    (days + 1L, 0L)
  } else {
    (days, units)
  }
}
