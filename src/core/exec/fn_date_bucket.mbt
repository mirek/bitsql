// DATE_BUCKET (bound in bind/fn_date_bucket.mbt). Captures:
// harness/corpus/analytic/date-bucket*.sql.
//
// Values are mapped to a linear "domain": 100 ns ticks since 0001-01-01
// (datetimeoffset: UTC ticks; time: ticks since midnight), except datetime,
// whose 1/300 s units are exact in units of 1/3 tick counted from
// 1753-01-01 (keeps the range inside Int64).

///|
priv struct BucketDomain {
  /// domain units per 100 ns tick (3 for datetime, else 1)
  mult : Int64
  /// day number (since 0001-01-01) of domain value 0
  base_day : Int
}

///|
fn bucket_domain(t : @types.SqlType) -> BucketDomain {
  match t {
    DateTime => { mult: 3L, base_day: @types.DAYS_TO_1753, }
    _ => { mult: 1L, base_day: 0, }
  }
}

///|
fn BucketDomain::units_per_day(self : BucketDomain) -> Int64 {
  @types.TICKS_PER_DAY * self.mult
}

///|
fn bucket_value(dom : BucketDomain, v : @types.Value) -> Int64 {
  let upd = dom.units_per_day()
  match v {
    Date(d) => (d - dom.base_day).to_int64() * upd
    DateTime2(x) => x
    DateTimeOffset(utc, _) => utc
    Time(t) => t
    SmallDateTime(d, m) =>
      (d + @types.DAYS_TO_1900 - dom.base_day).to_int64() * upd +
      m.to_int64() * @types.TICKS_PER_MINUTE
    DateTime(d, u) =>
      (d + @types.DAYS_TO_1900 - dom.base_day).to_int64() * upd +
      u.to_int64() * 100_000L
    _ => 0L
  }
}

///|
fn bucket_overflow(t : @types.SqlType) -> @types.SqlError {
  @types.sql_error(
    9835,
    "Calculating date bucket for '\{t.base_name()}' column caused an overflow.",
  )
}

///|
/// Domain value back to a value of the result type `t`.
fn bucket_result(
  dom : BucketDomain,
  x : Int64,
  t : @types.SqlType,
  input : @types.Value,
) -> @types.Value raise @types.SqlError {
  let upd = dom.units_per_day()
  match t {
    Time(s) => {
      let r = floor_mod(x, @types.TICKS_PER_DAY)
      Time(floor_mod(@types.round_ticks(r, s), @types.TICKS_PER_DAY))
    }
    Date => {
      let d = floor_div(x, upd) + dom.base_day.to_int64()
      if d < 0L || d > @types.MAX_DAYS.to_int64() {
        raise bucket_overflow(t)
      }
      Date(d.to_int())
    }
    DateTime2(s) => {
      if x < 0L {
        raise bucket_overflow(t)
      }
      let r = @types.round_ticks(x, s)
      if r > MAX_TICKS {
        raise bucket_overflow(t)
      }
      DateTime2(r)
    }
    DateTimeOffset(s) => {
      let off = match input {
        DateTimeOffset(_, o) => o
        _ => 0
      }
      if x < 0L {
        raise bucket_overflow(t)
      }
      let r = @types.round_ticks(x, s)
      let loc = r + off.to_int64() * @types.TICKS_PER_MINUTE
      if r > MAX_TICKS || loc < 0L || loc > MAX_TICKS {
        raise bucket_overflow(t)
      }
      DateTimeOffset(r, off)
    }
    DateTime => {
      // 1/3-tick units to 1/300 s units
      let units = round_half_away(x, 100_000L)
      let per = @types.DATETIME_UNITS_PER_DAY.to_int64()
      let day = floor_div(units, per) + dom.base_day.to_int64()
      if day < @types.DAYS_TO_1753.to_int64() ||
        day > @types.MAX_DAYS.to_int64() {
        raise bucket_overflow(t)
      }
      DateTime(
        day.to_int() - @types.DAYS_TO_1900,
        floor_mod(units, per).to_int(),
      )
    }
    SmallDateTime => {
      let minutes = round_half_away(x, @types.TICKS_PER_MINUTE)
      let day = floor_div(minutes, 1440L)
      if day < @types.DAYS_TO_1900.to_int64() ||
        day > @types.DAYS_TO_2079_06_06.to_int64() {
        raise bucket_overflow(t)
      }
      SmallDateTime(
        day.to_int() - @types.DAYS_TO_1900,
        floor_mod(minutes, 1440L).to_int(),
      )
    }
    _ => raise @types.not_supported("DATE_BUCKET on \{t.to_sql()}")
  }
}

///|
fn date_bucket(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
  dates : @types.DateSettings,
) -> @types.Value raise @types.SqlError {
  let p = part_of(v[0])
  let t = e.ty
  if p
    is ("microsecond"
    | "nanosecond"
    | "dayofyear"
    | "weekday"
    | "iso_week"
    | "tzoffset") {
    raise unsupported_part(p, "Date_Bucket", t, 1)
  }
  if v[1] is Null || v[2] is Null {
    return Null
  }
  let width = match @types.cast(v[1], args[1].ty, BigInt) {
    BigInt(w) => w
    _ => 0L
  }
  if width <= 0L {
    raise @types.sql_error(
      9834, "Invalid bucket width value passed to date_bucket function. Only positive values are allowed.",
    )
  }
  if width > 2147483647L {
    raise @types.not_supported(
      "DATE_BUCKET width above 2147483647",
      number=@types.EMU_DATE_BUCKET_WIDTH,
    )
  }
  // the date and origin in the result type (same base type, maybe a
  // different precision)
  let x_val = if args[2].ty == t {
    v[2]
  } else {
    @types.cast(v[2], args[2].ty, t, dates~)
  }
  let o_val : @types.Value = if v.length() > 3 && !(v[3] is Null) {
    if args[3].ty == t {
      v[3]
    } else {
      @types.cast(v[3], args[3].ty, t, dates~)
    }
  } else {
    match t {
      Time(_) => Time(0L)
      DateTimeOffset(_) =>
        DateTimeOffset(@types.DAYS_TO_1900.to_int64() * @types.TICKS_PER_DAY, 0)
      _ => DateTime2(@types.DAYS_TO_1900.to_int64() * @types.TICKS_PER_DAY)
    }
  }
  let dom = bucket_domain(t)
  let x = bucket_value(dom, x_val)
  // the default origin is given as datetime2 1900-01-01: map it directly
  let o = match (t, o_val) {
    (DateTime2(_), _) | (DateTimeOffset(_), _) | (Time(_), _) =>
      bucket_value(dom, o_val)
    (_, DateTime2(ticks)) =>
      (ticks / @types.TICKS_PER_DAY - dom.base_day.to_int64()) *
      dom.units_per_day()
    _ => bucket_value(dom, o_val)
  }
  let months : Int64? = match p {
    "year" => Some(12L)
    "quarter" => Some(3L)
    "month" => Some(1L)
    _ => None
  }
  match months {
    Some(per) => {
      let w = width * per
      let upd = dom.units_per_day()
      let xd = floor_div(x, upd).to_int() + dom.base_day
      let od = floor_div(o, upd).to_int() + dom.base_day
      let otod = floor_mod(o, upd)
      let (xy, xm, _) = @types.civil_from_days(xd)
      let (oy, om, _) = @types.civil_from_days(od)
      let diff = (xy * 12 + xm - (oy * 12 + om)).to_int64()
      // SQL Server counts months in 32 bits: with a wider bucket a date
      // after the origin lands in the origin's bucket (captured), one
      // before it gives a wrapped result (captured: 1800-01-01 with year
      // 2147483647 is 1901-01-01), not modelled
      if w > 2147483647L && diff < 0L {
        raise @types.not_supported(
          "DATE_BUCKET \{p} width above \{2147483647L / per} before the origin",
          number=@types.EMU_DATE_BUCKET_WIDTH,
        )
      }
      let mut k = floor_div(diff, w) * w
      let candidate = (k : Int64) => {
        match add_months(od, k) {
          Some(d) => Some((d - dom.base_day).to_int64() * upd + otod)
          None => None
        }
      }
      let mut c = candidate(k)
      if c is Some(cv) && cv > x {
        k = k - w
        c = candidate(k)
      }
      match c {
        Some(cv) => bucket_result(dom, cv, t, x_val)
        None => raise bucket_overflow(t)
      }
    }
    None => {
      let unit_len : Int64 = match p {
        "week" => 7L * @types.TICKS_PER_DAY
        "day" => @types.TICKS_PER_DAY
        "hour" => 36_000_000_000L
        "minute" => @types.TICKS_PER_MINUTE
        "second" => @types.TICKS_PER_SECOND
        _ => 10_000L // millisecond
      }
      let len = unit_len * dom.mult
      let diff = x - o
      let max_w = 4_000_000_000_000_000_000L / len
      let start = if width > max_w {
        // one bucket covers every representable value
        if diff >= 0L {
          o
        } else {
          raise bucket_overflow(t)
        }
      } else {
        let w = width * len
        o + floor_div(diff, w) * w
      }
      bucket_result(dom, start, t, x_val)
    }
  }
}
