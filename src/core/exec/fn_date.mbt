// Date and time built-ins (bound in bind/fn_date.mbt). All arithmetic is on
// days since 0001-01-01 plus nanoseconds of the day, so legacy datetime's
// 1/300 s units keep their exact value (captured: DATEPART(nanosecond, a
// datetime ending .997) is 996666666).

///|
/// A loc civil moment.
priv struct Moment {
  days : Int
  ns : Int64 // nanoseconds since midnight
  offset : Int? // minutes, datetimeoffset only
}

///|
let ns_per_day : Int64 = 86_400_000_000_000L

///|
fn units_to_ns(units : Int) -> Int64 {
  units.to_int64() * 10_000_000L / 3L
}

///|
/// Moment of a temporal value (already of a temporal type).
fn moment(v : @types.Value) -> Moment? {
  match v {
    Date(d) => Some({ days: d, ns: 0L, offset: None, })
    Time(t) => Some({ days: @types.DAYS_TO_1900, ns: t * 100L, offset: None, })
    DateTime2(x) =>
      Some({
        days: (x / @types.TICKS_PER_DAY).to_int(),
        ns: x % @types.TICKS_PER_DAY * 100L,
        offset: None,
      })
    DateTimeOffset(utc, off) => {
      let loc = utc + off.to_int64() * @types.TICKS_PER_MINUTE
      Some({
        days: (loc / @types.TICKS_PER_DAY).to_int(),
        ns: loc % @types.TICKS_PER_DAY * 100L,
        offset: Some(off),
      })
    }
    DateTime(d, u) =>
      Some({ days: d + @types.DAYS_TO_1900, ns: units_to_ns(u), offset: None, })
    SmallDateTime(d, m) =>
      Some({
        days: d + @types.DAYS_TO_1900,
        ns: m.to_int64() * 60_000_000_000L,
        offset: None,
      })
    _ => None
  }
}

///|
/// The temporal type a DATEPART/DATEDIFF argument is read as: temporal
/// types as is, text as datetimeoffset(7) (captured: DATEPART(tzoffset,
/// '... +05:00') is 300, DATEDIFF on texts compares UTC instants), numbers
/// as datetime.
fn read_type(t : @types.SqlType) -> @types.SqlType {
  match t.family() {
    FDate | FTime | FDateTime => t
    FString => DateTimeOffset(7)
    _ => DateTime
  }
}

///|
fn to_read_type(
  v : @types.Value,
  t : @types.SqlType,
) -> (@types.Value, @types.SqlType) raise @types.SqlError {
  let rt = read_type(t)
  if rt == t {
    (v, t)
  } else {
    (@types.cast(v, t, rt), rt)
  }
}

///|
fn part_of(v : @types.Value) -> String {
  match v {
    String(s) => s
    _ => ""
  }
}

///|
fn is_time_part(p : String) -> Bool {
  p
  is ("hour"
  | "minute"
  | "second"
  | "millisecond"
  | "microsecond"
  | "nanosecond")
}

///|
fn unsupported_part(
  p : String,
  fname : String,
  t : @types.SqlType,
  state : Int,
) -> @types.SqlError {
  @types.sql_error(
    9810,
    "The datepart \{p} is not supported by date function \{fname} for data type \{t.base_name()}.",
    state~,
  )
}

///|
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
fn floor_mod(a : Int64, b : Int64) -> Int64 {
  a - floor_div(a, b) * b
}

///|
fn round_half_away(num : Int64, den : Int64) -> Int64 {
  let q = num / den
  let r = num % den
  if r.abs() * 2L >= den.abs() {
    if (num < 0L) != (den < 0L) {
      q - 1L
    } else {
      q + 1L
    }
  } else {
    q
  }
}

///|
fn leap(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

///|
fn month_days(y : Int, m : Int) -> Int {
  match m {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    _ => if leap(y) { 29 } else { 28 }
  }
}

///|
/// Adds months, clipping the day to the target month (Jan 31 + 1 month is
/// Feb 29 in 2024). None when the year leaves 1..9999.
fn add_months(days : Int, n : Int64) -> Int? {
  let (y, m, d) = @types.civil_from_days(days)
  let total = y.to_int64() * 12L + (m - 1).to_int64() + n
  let ny = floor_div(total, 12L)
  if ny < 1L || ny > 9999L {
    return None
  }
  let ny = ny.to_int()
  let nm = floor_mod(total, 12L).to_int() + 1
  Some(@types.days_from_civil(ny, nm, @cmp.minimum(d, month_days(ny, nm))))
}

///|
/// 0 = Sunday … 6 = Saturday (0001-01-01 was a Monday).
fn weekday_index(days : Int) -> Int {
  (days + 1) % 7
}

///|
fn day_of_year(days : Int) -> Int {
  let (y, _, _) = @types.civil_from_days(days)
  days - @types.days_from_civil(y, 1, 1) + 1
}

///|
/// Position of a day within its week (0-based) when weeks start on
/// @@DATEFIRST (1 = Monday … 7 = Sunday).
fn week_position(days : Int, datefirst : Int) -> Int {
  (weekday_index(days) - datefirst % 7 + 7) % 7
}

///|
/// DATEPART(week): week 1 contains January 1, weeks start on @@DATEFIRST.
fn week_of_year(days : Int, datefirst : Int) -> Int {
  let (y, _, _) = @types.civil_from_days(days)
  let jan1 = @types.days_from_civil(y, 1, 1)
  (days - jan1 + week_position(jan1, datefirst)) / 7 + 1
}

///|
/// ISO 8601 week number.
fn iso_week(days : Int) -> Int {
  let wd = days % 7 + 1 // Monday = 1
  let thursday = days - wd + 4
  let (y, _, _) = @types.civil_from_days(thursday)
  (thursday - @types.days_from_civil(y, 1, 1)) / 7 + 1
}

///|
let month_names : Array[String] = [
  "January", "February", "March", "April", "May", "June", "July", "August", "September",
  "October", "November", "December",
]

///|
let day_names : Array[String] = [
  "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
]

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    n.to_string()
  }
}

///|
fn offset_text(off : Int) -> String {
  let sign = if off < 0 { "-" } else { "+" }
  let a = off.abs()
  "\{sign}\{pad2(a / 60)}:\{pad2(a % 60)}"
}

///|
/// DATEPART / DATENAME / YEAR / MONTH / DAY.
fn date_part(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  datefirst : Int,
) -> @types.Value raise @types.SqlError {
  let p = part_of(v[0])
  if v[1] is Null {
    return Null
  }
  let (x, t) = to_read_type(v[1], args[1].ty)
  let datename = name == "DATENAME"
  let fname = if datename { "datename" } else { "datepart" }
  match t {
    Date if is_time_part(p) || p == "tzoffset" =>
      raise unsupported_part(p, fname, t, if datename { 4 } else { 2 })
    Time(_) if !is_time_part(p) =>
      raise unsupported_part(p, fname, t, if datename { 5 } else { 3 })
    DateTime | SmallDateTime if p == "tzoffset" =>
      raise unsupported_part(p, fname, DateTime, if datename { 7 } else { 6 })
    _ => ()
  }
  guard moment(x) is Some(m) else { return Null }
  let (y, mo, d) = @types.civil_from_days(m.days)
  // legacy datetime fractions come from the exact 1/300 s value
  let n : Int64 = match p {
    "year" => y.to_int64()
    "quarter" => ((mo - 1) / 3 + 1).to_int64()
    "month" => mo.to_int64()
    "dayofyear" => day_of_year(m.days).to_int64()
    "day" => d.to_int64()
    "week" => week_of_year(m.days, datefirst).to_int64()
    "weekday" => (week_position(m.days, datefirst) + 1).to_int64()
    "hour" => m.ns / 3_600_000_000_000L
    "minute" => m.ns / 60_000_000_000L % 60L
    "second" => m.ns / 1_000_000_000L % 60L
    "millisecond" => m.ns / 1_000_000L % 1000L
    "microsecond" => m.ns / 1000L % 1_000_000L
    "nanosecond" => m.ns % 1_000_000_000L
    "iso_week" => iso_week(m.days).to_int64()
    "tzoffset" => m.offset.unwrap_or(0).to_int64()
    _ => raise @types.not_supported("datepart \{p}")
  }
  if datename {
    String(
      match p {
        "month" => month_names[mo - 1]
        "weekday" => day_names[weekday_index(m.days)]
        "tzoffset" => offset_text(m.offset.unwrap_or(0))
        _ => n.to_string()
      },
    )
  } else {
    Int(n.to_int())
  }
}

///|
/// UTC (days, ns) of a DATEDIFF operand: non-offset types count as UTC.
fn utc_moment(m : Moment) -> (Int, Int64) {
  match m.offset {
    None | Some(0) => (m.days, m.ns)
    Some(off) => {
      let total = m.ns - off.to_int64() * 60_000_000_000L
      let dd = floor_div(total, ns_per_day)
      (m.days + dd.to_int(), floor_mod(total, ns_per_day))
    }
  }
}

///|
fn datediff(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value raise @types.SqlError {
  let p = part_of(v[0])
  if v[1] is Null || v[2] is Null {
    return Null
  }
  let fname = name.to_lower()
  if p == "iso_week" || p == "tzoffset" {
    raise @types.sql_error(
      9806,
      "The datepart \{p} is not supported by date function \{fname}.",
      state=0,
    )
  }
  let (a, _) = to_read_type(v[1], args[1].ty)
  let (b, _) = to_read_type(v[2], args[2].ty)
  guard moment(a) is Some(ma) && moment(b) is Some(mb) else { return Null }
  let (d1, n1) = utc_moment(ma)
  let (d2, n2) = utc_moment(mb)
  let big = (x : Int64) => @bigint.BigInt::from_int64(x)
  let calendar = (f : (Int) -> Int64) => big(f(d2) - f(d1))
  let clock = (unit : Int64) => {
    let per_day = ns_per_day / unit
    big((d2 - d1).to_int64()) * big(per_day) + big(n2 / unit - n1 / unit)
  }
  let diff = match p {
    "year" =>
      calendar(d => {
        let (y, _, _) = @types.civil_from_days(d)
        y.to_int64()
      })
    "quarter" =>
      calendar(d => {
        let (y, m, _) = @types.civil_from_days(d)
        y.to_int64() * 4L + ((m - 1) / 3).to_int64()
      })
    "month" =>
      calendar(d => {
        let (y, m, _) = @types.civil_from_days(d)
        y.to_int64() * 12L + m.to_int64()
      })
    "dayofyear" | "day" | "weekday" => big((d2 - d1).to_int64())
    "week" => calendar(d => ((d + 1) / 7).to_int64())
    "hour" => clock(3_600_000_000_000L)
    "minute" => clock(60_000_000_000L)
    "second" => clock(1_000_000_000L)
    "millisecond" => clock(1_000_000L)
    "microsecond" => clock(1000L)
    "nanosecond" => clock(1L)
    _ => raise @types.not_supported("datepart \{p}")
  }
  let (lo, hi) = if name == "DATEDIFF" {
    (-2147483648L, 2147483647L)
  } else {
    (-9223372036854775807L - 1L, 9223372036854775807L)
  }
  if diff < big(lo) || diff > big(hi) {
    raise @types.sql_error(
      535,
      "The \{fname} function resulted in an overflow. The number of dateparts separating two date/time instances is too large. Try to use \{fname} with a less precise datepart.",
      state=0,
    )
  }
  let n = diff.to_int64()
  if name == "DATEDIFF" {
    Int(n.to_int())
  } else {
    BigInt(n)
  }
}

///|
/// The DATEADD increment: integers as is, decimals and floats truncated.
fn add_amount(v : @types.Value) -> @bigint.BigInt raise @types.SqlError {
  match v {
    Float(d) => @types.Decimal::from_double_exact(d).trunc_to_bigint()
    _ =>
      match v.as_decimal() {
        Some(x) => x.trunc_to_bigint()
        None => raise @types.not_supported("DATEADD increment of this type")
      }
  }
}

///|
fn add_overflow(t : @types.SqlType) -> @types.SqlError {
  // captured: date, datetime2, datetimeoffset state 3, datetime 1,
  // smalldatetime 2
  let state = match t {
    DateTime => 1
    SmallDateTime => 2
    _ => 3
  }
  @types.sql_error(
    517,
    "Adding a value to a '\{t.base_name()}' column caused an overflow.",
    state~,
  )
}

///|
const MAX_TICKS : Int64 = 3_155_378_975_999_999_999L

///|
fn dateadd(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  let p = part_of(v[0])
  let t = e.ty
  if v[1] is Null || v[2] is Null {
    return Null
  }
  match t {
    _ if p == "iso_week" || p == "tzoffset" =>
      raise unsupported_part(p, "dateadd", t, 2)
    Date if is_time_part(p) => raise unsupported_part(p, "dateadd", t, 1)
    Time(_) if !is_time_part(p) => raise unsupported_part(p, "dateadd", t, 1)
    DateTime if p == "microsecond" || p == "nanosecond" =>
      raise unsupported_part(p, "dateadd", t, 0)
    SmallDateTime if p == "microsecond" || p == "nanosecond" =>
      raise unsupported_part(p, "dateadd", t, 3)
    _ => ()
  }
  let x = if args[2].ty == t { v[2] } else { @types.cast(v[2], args[2].ty, t) }
  let amount = add_amount(v[1])
  if amount < @bigint.BigInt::from_int(-2147483648) ||
    amount > @bigint.BigInt::from_int(2147483647) {
    raise add_overflow(t)
  }
  let n = amount.to_int64()
  let months : Int64? = match p {
    "year" => Some(n * 12L)
    "quarter" => Some(n * 3L)
    "month" => Some(n)
    _ => None
  }
  let days_delta : Int64? = match p {
    "dayofyear" | "day" | "weekday" => Some(n)
    "week" => Some(n * 7L)
    _ => None
  }
  // shifts a day number by the calendar part, or None on overflow
  let shift_days = (d : Int) => {
    match (months, days_delta) {
      (Some(mm), _) => add_months(d, mm)
      (_, Some(dd)) => {
        let r = d.to_int64() + dd
        if r < 0L || r > @types.MAX_DAYS.to_int64() {
          None
        } else {
          Some(r.to_int())
        }
      }
      _ => Some(d)
    }
  }
  // clock increment in 100 ns ticks
  let ticks_delta = () => {
    match p {
      "hour" => n * 36_000_000_000L
      "minute" => n * 600_000_000L
      "second" => n * 10_000_000L
      "millisecond" => n * 10_000L
      "microsecond" => n * 10L
      "nanosecond" => round_half_away(n, 100L)
      _ => 0L
    }
  }
  match x {
    Date(d) =>
      match shift_days(d) {
        Some(r) => Date(r)
        None => raise add_overflow(t)
      }
    Time(ticks) => {
      let s = match t {
        Time(s) => s
        _ => 7
      }
      let r = floor_mod(ticks + ticks_delta(), @types.TICKS_PER_DAY)
      Time(floor_mod(@types.round_ticks(r, s), @types.TICKS_PER_DAY))
    }
    DateTime2(ticks) => {
      let s = match t {
        DateTime2(s) => s
        _ => 7
      }
      DateTime2(add_ticks(ticks, shift_days, ticks_delta(), s, t))
    }
    DateTimeOffset(utc, off) => {
      let s = match t {
        DateTimeOffset(s) => s
        _ => 7
      }
      let loc = utc + off.to_int64() * @types.TICKS_PER_MINUTE
      let r = add_ticks(loc, shift_days, ticks_delta(), s, t)
      let u = r - off.to_int64() * @types.TICKS_PER_MINUTE
      if u < 0L || u > MAX_TICKS {
        raise add_overflow(t)
      }
      DateTimeOffset(u, off)
    }
    DateTime(d, units) => {
      guard shift_days(d + @types.DAYS_TO_1900) is Some(nd) else {
        raise add_overflow(t)
      }
      let delta = match p {
        "hour" => n * 1_080_000L
        "minute" => n * 18_000L
        "second" => n * 300L
        "millisecond" => round_half_away(n * 3L, 10L)
        _ => 0L
      }
      let total = nd.to_int64() * @types.DATETIME_UNITS_PER_DAY.to_int64() +
        units.to_int64() +
        delta
      let days = floor_div(total, @types.DATETIME_UNITS_PER_DAY.to_int64())
      if days < @types.DAYS_TO_1753.to_int64() ||
        days > @types.MAX_DAYS.to_int64() {
        raise add_overflow(t)
      }
      DateTime(
        days.to_int() - @types.DAYS_TO_1900,
        floor_mod(total, @types.DATETIME_UNITS_PER_DAY.to_int64()).to_int(),
      )
    }
    SmallDateTime(d, minutes) => {
      guard shift_days(d + @types.DAYS_TO_1900) is Some(nd) else {
        raise add_overflow(t)
      }
      // seconds and milliseconds round to the minute (captured: +29 s
      // keeps the minute, +30 s moves to the next)
      let ms = nd.to_int64() * 86_400_000L +
        minutes.to_int64() * 60_000L +
        (match p {
          "hour" => n * 3_600_000L
          "minute" => n * 60_000L
          "second" => n * 1000L
          "millisecond" => n
          _ => 0L
        })
      let total_min = floor_div(ms + 30_000L, 60_000L)
      let days = floor_div(total_min, 1440L)
      if days < @types.DAYS_TO_1900.to_int64() ||
        days > @types.DAYS_TO_2079_06_06.to_int64() {
        raise add_overflow(t)
      }
      SmallDateTime(
        days.to_int() - @types.DAYS_TO_1900,
        floor_mod(total_min, 1440L).to_int(),
      )
    }
    _ => raise @types.not_supported("DATEADD on \{t.to_sql()}")
  }
}

///|
fn add_ticks(
  ticks : Int64,
  shift_days : (Int) -> Int?,
  delta : Int64,
  scale : Int,
  t : @types.SqlType,
) -> Int64 raise @types.SqlError {
  let d = (ticks / @types.TICKS_PER_DAY).to_int()
  let tod = ticks % @types.TICKS_PER_DAY
  guard shift_days(d) is Some(nd) else { raise add_overflow(t) }
  let r = nd.to_int64() * @types.TICKS_PER_DAY + tod + delta
  if r < 0L {
    raise add_overflow(t)
  }
  let r = @types.round_ticks(r, scale)
  if r > MAX_TICKS {
    raise add_overflow(t)
  }
  r
}

///|
fn eomonth(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value raise @types.SqlError {
  if v[0] is Null {
    return Null
  }
  let d = match @types.cast(v[0], args[0].ty, Date) {
    Date(d) => d
    _ => return Null
  }
  let n = if v.length() > 1 && !(v[1] is Null) {
    match @types.cast(v[1], args[1].ty, Int) {
      Int(k) => k.to_int64()
      _ => 0L
    }
  } else {
    0L
  }
  let (y, m, _) = @types.civil_from_days(d)
  let overflow = @types.sql_error(
    517, "Adding a value to a 'date' column caused an overflow.",
  )
  guard add_months(@types.days_from_civil(y, m, 1), n) is Some(first) else {
    raise overflow
  }
  let (ny, nm, _) = @types.civil_from_days(first)
  Date(first + month_days(ny, nm) - 1)
}

///|
fn int_args(v : Array[@types.Value]) -> Array[Int]? raise @types.SqlError {
  let out = []
  for x in v {
    match int_of(x) {
      Some(n) => out.push(n.to_int())
      None => return None
    }
  }
  Some(out)
}

///|
fn cannot_construct(t : String, state : Int) -> @types.SqlError {
  @types.sql_error(
    289,
    "Cannot construct data type \{t}, some of the arguments have values which are not valid.",
    state~,
  )
}

///|
fn pow10i(n : Int) -> Int64 {
  let mut r = 1L
  for _ in 0..<n {
    r = r * 10L
  }
  r
}

///|
/// Ticks of a time of day from parts (None when out of range).
fn tod_ticks(h : Int, mi : Int, s : Int) -> Int64? {
  if h < 0 || h > 23 || mi < 0 || mi > 59 || s < 0 || s > 59 {
    None
  } else {
    Some(((h * 60 + mi) * 60 + s).to_int64() * @types.TICKS_PER_SECOND)
  }
}

///|
/// Fraction ticks of `frac` at precision `p` (frac must be < 10^p).
fn frac_ticks(frac : Int, p : Int) -> Int64? {
  if frac < 0 || frac.to_int64() >= pow10i(p) {
    None
  } else {
    Some(frac.to_int64() * pow10i(7 - p))
  }
}

///|
fn from_parts(
  name : String,
  v : Array[@types.Value],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  guard int_args(v) is Some(a) else { return Null }
  let valid_date = (st : Int, tname : String) => {
    if @types.is_valid_date(a[0], a[1], a[2]) {
      @types.days_from_civil(a[0], a[1], a[2])
    } else {
      raise cannot_construct(tname, st)
    }
  }
  match name {
    "DATEFROMPARTS" => Date(valid_date(1, "date"))
    "DATETIMEFROMPARTS" => {
      let d = valid_date(3, "datetime")
      guard tod_ticks(a[3], a[4], a[5]) is Some(tt) &&
        a[6] >= 0 &&
        a[6] <= 999 &&
        d >= @types.DAYS_TO_1753 else {
        raise cannot_construct("datetime", 3)
      }
      // milliseconds round to 1/300 s, half up (captured: 998 → .997,
      // 999 → next second, 5 → .007)
      let units = tt / @types.TICKS_PER_SECOND * 300L +
        (a[6] * 3 + 5).to_int64() / 10L
      let mut days = d
      let mut u = units
      if u >= @types.DATETIME_UNITS_PER_DAY.to_int64() {
        days += 1
        u -= @types.DATETIME_UNITS_PER_DAY.to_int64()
      }
      if days > @types.MAX_DAYS {
        raise cannot_construct("datetime", 3)
      }
      DateTime(days - @types.DAYS_TO_1900, u.to_int())
    }
    "SMALLDATETIMEFROMPARTS" => {
      let d = valid_date(4, "smalldatetime")
      guard tod_ticks(a[3], a[4], 0) is Some(_) &&
        d >= @types.DAYS_TO_1900 &&
        d <= @types.DAYS_TO_2079_06_06 else {
        raise cannot_construct("smalldatetime", 4)
      }
      SmallDateTime(d - @types.DAYS_TO_1900, a[3] * 60 + a[4])
    }
    "DATETIME2FROMPARTS" => {
      let d = valid_date(5, "datetime2")
      guard tod_ticks(a[3], a[4], a[5]) is Some(tt) &&
        frac_ticks(a[6], a[7]) is Some(ft) else {
        raise cannot_construct("datetime2", 5)
      }
      DateTime2(d.to_int64() * @types.TICKS_PER_DAY + tt + ft)
    }
    "TIMEFROMPARTS" => {
      guard tod_ticks(a[0], a[1], a[2]) is Some(tt) &&
        frac_ticks(a[3], a[4]) is Some(ft) else {
        raise cannot_construct("time", 2)
      }
      Time(tt + ft)
    }
    "DATETIMEOFFSETFROMPARTS" => {
      let d = valid_date(6, "datetimeoffset")
      let (ho, mo) = (a[7], a[8])
      let off = ho * 60 + mo
      guard tod_ticks(a[3], a[4], a[5]) is Some(tt) &&
        frac_ticks(a[6], a[9]) is Some(ft) &&
        ho >= -14 &&
        ho <= 14 &&
        mo >= -59 &&
        mo <= 59 &&
        !(ho > 0 && mo < 0) &&
        !(ho < 0 && mo > 0) &&
        off.abs() <= 840 else {
        raise cannot_construct("datetimeoffset", 6)
      }
      let loc = d.to_int64() * @types.TICKS_PER_DAY + tt + ft
      let utc = loc - off.to_int64() * @types.TICKS_PER_MINUTE
      if utc < 0L || utc > MAX_TICKS {
        raise cannot_construct("datetimeoffset", 6)
      }
      DateTimeOffset(utc, off)
    }
    _ => raise @types.not_supported(name + " in " + e.ty.to_sql())
  }
}

///|
/// Parses a time zone argument: '+hh:mm' / '-hh:mm' text or minutes.
fn tz_minutes(v : @types.Value) -> Int? {
  match v {
    String(s) => {
      let s = s.trim().to_owned()
      if s.length() != 6 {
        return None
      }
      let sign = s.code_unit_at(0).to_int()
      let digit = (i : Int) => {
        let c = s.code_unit_at(i).to_int()
        if c >= '0'.to_int() && c <= '9'.to_int() {
          Some(c - '0'.to_int())
        } else {
          None
        }
      }
      guard (sign == '+'.to_int() || sign == '-'.to_int()) &&
        s.code_unit_at(3).to_int() == ':'.to_int() &&
        digit(1) is Some(h1) &&
        digit(2) is Some(h2) &&
        digit(4) is Some(m1) &&
        digit(5) is Some(m2) else {
        return None
      }
      let h = h1 * 10 + h2
      let m = m1 * 10 + m2
      if m > 59 {
        return None
      }
      let total = h * 60 + m
      if total > 840 {
        None
      } else if sign == '-'.to_int() {
        Some(-total)
      } else {
        Some(total)
      }
    }
    _ =>
      match v.as_int64() {
        Some(n) => if n < -840L || n > 840L { None } else { Some(n.to_int()) }
        None => None
      }
  }
}

///|
fn to_offset(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  if v[0] is Null || v[1] is Null {
    return Null
  }
  let scale = match e.ty {
    DateTimeOffset(s) => s
    _ => 7
  }
  let fname = name.to_lower()
  guard tz_minutes(v[1]) is Some(off) else {
    raise @types.sql_error(
      9812,
      "The timezone provided to builtin function \{fname} is invalid.",
      state=if name == "SWITCHOFFSET" { 0 } else { 2 },
    )
  }
  let x = match args[0].ty.family() {
    FDate | FTime | FDateTime => v[0]
    _ =>
      @types.cast(
        v[0],
        args[0].ty,
        if name == "SWITCHOFFSET" {
          DateTimeOffset(7)
        } else {
          DateTime2(7)
        },
      )
  }
  guard moment(x) is Some(m) else { return Null }
  let loc = m.days.to_int64() * @types.TICKS_PER_DAY + m.ns / 100L
  let utc = if name == "SWITCHOFFSET" {
    loc - m.offset.unwrap_or(0).to_int64() * @types.TICKS_PER_MINUTE
  } else {
    loc - off.to_int64() * @types.TICKS_PER_MINUTE
  }
  let utc = @types.round_ticks(utc, scale)
  let new_local = utc + off.to_int64() * @types.TICKS_PER_MINUTE
  if utc < 0L || utc > MAX_TICKS || new_local < 0L || new_local > MAX_TICKS {
    raise @types.overflow_expression(e.ty, state=1)
  }
  DateTimeOffset(utc, off)
}

///|
fn isdate(
  v : @types.Value,
  t : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  match v {
    Null => Int(0)
    String(s) =>
      if s.trim().length() == 0 {
        Int(0)
      } else {
        Int(if @types.try_cast(v, t, DateTime) is Null { 0 } else { 1 })
      }
    _ => Int(0)
  }
}

///|
fn datetrunc(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
  datefirst : Int,
) -> @types.Value raise @types.SqlError {
  let p = part_of(v[0])
  if v[1] is Null {
    return Null
  }
  let t = e.ty
  let bad = (st : Int) => unsupported_part(p, "datetrunc", t, st)
  let scale = match t {
    DateTime2(s) | DateTimeOffset(s) | Time(s) => s
    _ => 7
  }
  // states are per type (captured): datetime 9, smalldatetime 8, date and
  // time 10 for the other half's parts, otherwise 11
  let never = p is ("weekday" | "tzoffset" | "nanosecond")
  match t {
    DateTime if never || p == "microsecond" => raise bad(9)
    SmallDateTime if never || p == "millisecond" || p == "microsecond" =>
      raise bad(8)
    _ if never => raise bad(11)
    Date if is_time_part(p) => raise bad(10)
    Time(_) if !is_time_part(p) => raise bad(10)
    DateTime2(_) | DateTimeOffset(_) | Time(_) if (
        p == "millisecond" && scale < 3
      ) ||
      (p == "microsecond" && scale < 6) => raise bad(11)
    _ => ()
  }
  let x = if args[1].ty == t { v[1] } else { @types.cast(v[1], args[1].ty, t) }
  guard moment(x) is Some(m) else { return Null }
  let (y, mo, _) = @types.civil_from_days(m.days)
  let days = match p {
    "year" => @types.days_from_civil(y, 1, 1)
    "quarter" => @types.days_from_civil(y, (mo - 1) / 3 * 3 + 1, 1)
    "month" => @types.days_from_civil(y, mo, 1)
    "week" => m.days - week_position(m.days, datefirst)
    "iso_week" => m.days - m.days % 7
    _ => m.days
  }
  let unit : Int64 = match p {
    "hour" => 3_600_000_000_000L
    "minute" => 60_000_000_000L
    "second" => 1_000_000_000L
    "millisecond" => 1_000_000L
    "microsecond" => 1000L
    _ => ns_per_day
  }
  let ns = if unit == ns_per_day { 0L } else { m.ns / unit * unit }
  match x {
    Date(_) => Date(days)
    Time(_) => Time(ns / 100L)
    DateTime2(_) =>
      DateTime2(days.to_int64() * @types.TICKS_PER_DAY + ns / 100L)
    DateTimeOffset(_, off) => {
      let loc = days.to_int64() * @types.TICKS_PER_DAY + ns / 100L
      DateTimeOffset(loc - off.to_int64() * @types.TICKS_PER_MINUTE, off)
    }
    DateTime(_, _) => {
      // back to 1/300 s units, rounding to the nearest unit
      let units = (ns * 3L + 5_000_000L) / 10_000_000L
      DateTime(days - @types.DAYS_TO_1900, units.to_int())
    }
    SmallDateTime(_, _) =>
      SmallDateTime(days - @types.DAYS_TO_1900, (ns / 60_000_000_000L).to_int())
    _ => raise @types.not_supported("DATETRUNC on \{t.to_sql()}")
  }
}

///|
fn call_date(
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
  datefirst~ : Int,
) -> @types.Value? raise @types.SqlError {
  let r = match name {
    "DATEADD" => dateadd(v, args, e)
    "DATEDIFF" | "DATEDIFF_BIG" => datediff(name, v, args)
    "DATEPART" | "DATENAME" => date_part(name, v, args, datefirst)
    "EOMONTH" => eomonth(v, args)
    "DATEFROMPARTS"
    | "DATETIMEFROMPARTS"
    | "SMALLDATETIMEFROMPARTS"
    | "DATETIME2FROMPARTS"
    | "TIMEFROMPARTS"
    | "DATETIMEOFFSETFROMPARTS" => from_parts(name, v, e)
    "TODATETIMEOFFSET" | "SWITCHOFFSET" => to_offset(name, v, args, e)
    "ISDATE" => isdate(v[0], args[0].ty)
    "DATETRUNC" => datetrunc(v, args, e, datefirst)
    _ => return None
  }
  Some(r)
}
