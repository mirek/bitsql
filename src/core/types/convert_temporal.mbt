// Conversions into date, time, datetime2, datetimeoffset, datetime and
// smalldatetime.

///|
/// A temporal source reduced to local civil parts.
priv struct Instant {
  days : Int?
  time : Int64?
  offset : Int?
}

///|
/// 241 state 1 (captured): any failure of the date/time/datetime2/
/// datetimeoffset parser, and a syntax error of the datetime parser.
fn temporal_text_error() -> SqlError {
  sql_error(
    241, "Conversion failed when converting date and/or time from character string.",
  )
}

///|
/// A character string → local civil parts for a target type: datetime and
/// smalldatetime use SQL Server's legacy parser, the other types the new one
/// (date_parse.mbt).
fn parse_text(
  s : String,
  from : SqlType,
  to : SqlType,
  style : Int?,
) -> ParsedTemporal raise SqlError {
  let n = style.unwrap_or(0)
  let legacy = to is (DateTime | SmallDateTime)
  let st = match date_style(n, legacy) {
    Some(st) => st
    // captured: "The style 99 is not supported for conversions from
    // nvarchar to datetime2." (state 1; TRY_CONVERT gives NULL)
    None =>
      raise sql_error(
        9809,
        "The style \{n} is not supported for conversions from \{from.base_name()} to \{to.base_name()}.",
      )
  }
  if legacy &&
    n == 130 &&
    s.iter().any(c => c.to_int() >= 0x600 && c.to_int() <= 0x6FF) {
    raise not_supported(
      "CONVERT style 130 with Arabic month names",
      number=EMU_STYLE_NOT_SUPPORTED,
    )
  }
  let p = parse_text_style(s, from, to, st, n, legacy)
  if !st.hijri {
    return p
  }
  // Hijri styles: the parsed date is Hijri; a time alone is on Hijri
  // 1900-01-01 for the new parser (captured: 2464-12-29) and on Gregorian
  // 1900-01-01 for datetime/smalldatetime
  if p.date is None && legacy {
    return p
  }
  let (hy, hm, hd) = p.date.unwrap_or((1900, 1, 1))
  let days = days_from_hijri(hy, hm, hd)
  if days > MAX_DAYS {
    // captured: 242 state 3 also for datetime2 ('29/12/9666', 131)
    raise legacy_out_of_range(from, to)
  }
  { ..p, date: Some(civil_from_days(days)), }
}

///|
fn parse_text_style(
  s : String,
  from : SqlType,
  to : SqlType,
  st : DateStyle,
  n : Int,
  legacy : Bool,
) -> ParsedTemporal raise SqlError {
  parse_date_string(s, if legacy { Legacy } else { Modern }, st) catch {
    Syntax if to is SmallDateTime =>
      // captured: 295 state 3
      raise sql_error(
        295,
        "Conversion failed when converting character string to smalldatetime data type.",
        state=3,
      )
    Value if legacy => raise legacy_out_of_range(from, to)
    Syntax | Value => raise temporal_text_error()
    StyleMismatch =>
      // captured: 9807 state 0 for date/datetime2 under style 112
      raise sql_error(
        9807,
        "The input character string does not follow style \{n}, either change the input character string or use a different style.",
        state=0,
      )
  }
}

///|
/// A non-character temporal value as local civil parts.
fn instant_of(v : Value, from : SqlType) -> Instant raise SqlError {
  match v {
    Date(d) => { days: Some(d), time: None, offset: None, }
    Time(t) => { days: None, time: Some(t), offset: None, }
    DateTime2(x) =>
      {
        days: Some((x / TICKS_PER_DAY).to_int()),
        time: Some(x % TICKS_PER_DAY),
        offset: None,
      }
    DateTimeOffset(utc, off) => {
      let local_ticks = utc + off.to_int64() * TICKS_PER_MINUTE
      {
        days: Some((local_ticks / TICKS_PER_DAY).to_int()),
        time: Some(local_ticks % TICKS_PER_DAY),
        offset: Some(off),
      }
    }
    DateTime(d, u) =>
      {
        days: Some(d + DAYS_TO_1900),
        time: Some(datetime_units_to_ticks(u)),
        offset: None,
      }
    SmallDateTime(d, m) =>
      {
        days: Some(d + DAYS_TO_1900),
        time: Some(m.to_int64() * TICKS_PER_MINUTE),
        offset: None,
      }
    _ => raise internal("bad temporal source \{from.to_sql()}")
  }
}

///|
/// 242: out-of-range legacy datetime (captured for varchar → smalldatetime,
/// state 3).
fn legacy_out_of_range(from : SqlType, to : SqlType) -> SqlError {
  sql_error(
    242,
    "The conversion of a \{source_name(from)} data type to a \{to.message_name()} data type resulted in an out-of-range value.",
    state=3,
  )
}

///|
const MAX_TICKS : Int64 = 3_155_378_975_999_999_999L

///|
fn to_temporal(
  v : Value,
  from : SqlType,
  to : SqlType,
  style : Int?,
) -> Value raise SqlError {
  let ff = from.family()
  if ff is (FBit | FInteger | FDecimal | FMoney | FFloat) {
    return numeric_to_legacy(v, from, to)
  }
  if ff == FBinary {
    raise conversion_unsupported(from, to)
  }
  let inst = match v {
    String(text) => {
      let p = parse_text(text, from, to, style)
      let days = match p.date {
        Some((y, m, d)) => Some(days_from_civil(y, m, d))
        None => None
      }
      { days, time: p.time, offset: p.offset, }
    }
    _ => instant_of(v, from)
  }
  let from_text = ff == FString
  let days = inst.days.unwrap_or(DAYS_TO_1900)
  let time = inst.time.unwrap_or(0L)
  match to {
    Date => Date(days)
    Time(s) => Time(round_time_ticks(time, s))
    DateTime2(s) => {
      let x = round_ticks(days.to_int64() * TICKS_PER_DAY + time, s)
      if x > MAX_TICKS {
        raise if from_text {
          temporal_text_error()
        } else {
          overflow_expression(to, state=1)
        }
      }
      DateTime2(x)
    }
    DateTimeOffset(s) => {
      let off = inst.offset.unwrap_or(0)
      let local_ticks = round_ticks(days.to_int64() * TICKS_PER_DAY + time, s)
      let utc = local_ticks - off.to_int64() * TICKS_PER_MINUTE
      if local_ticks > MAX_TICKS || utc < 0L || utc > MAX_TICKS {
        // captured: '0001-01-01T00:00:00+14:00' → 8114 state 31
        raise if from_text {
          error_converting(from, to, state=31)
        } else {
          overflow_expression(to, state=1)
        }
      }
      DateTimeOffset(utc, off)
    }
    DateTime | SmallDateTime => {
      let mut d = days
      let mut units = ticks_to_datetime_units(time).to_int()
      if units >= DATETIME_UNITS_PER_DAY {
        d += 1
        units -= DATETIME_UNITS_PER_DAY
      }
      if to is DateTime {
        if d < DAYS_TO_1753 || d > MAX_DAYS {
          raise legacy_out_of_range(from, to)
        }
        DateTime(d - DAYS_TO_1900, units)
      } else {
        // round to the minute at 30 s, after 1/300 s rounding (captured:
        // 23:59:29.998 rounds down, 23:59:29.999 up)
        let mut minutes = (units + 9000) / 18000
        if minutes >= 1440 {
          d += 1
          minutes -= 1440
        }
        if d < DAYS_TO_1900 || d > DAYS_TO_2079_06_06 {
          raise legacy_out_of_range(from, to)
        }
        SmallDateTime(d - DAYS_TO_1900, minutes)
      }
    }
    _ => raise internal("bad temporal target \{to.to_sql()}")
  }
}

///|
/// int/decimal/money/float → datetime/smalldatetime: days since 1900-01-01
/// plus a fraction of a day.
fn numeric_to_legacy(
  v : Value,
  from : SqlType,
  to : SqlType,
) -> Value raise SqlError {
  let x = match v {
    Float(d) => double_to_decimal17(d)
    _ =>
      match v.as_decimal() {
        Some(d) => d
        None => raise internal("bad numeric source \{from.to_sql()}")
      }
  }
  let t = x.trunc_to_bigint()
  let floor = if x.sign() < 0 && Decimal::new(t, 0).compare(x) != 0 {
    t - @bigint.BigInt::from_int(1)
  } else {
    t
  }
  let overflow = sql_error(
    8115,
    "Arithmetic overflow error converting expression to data type \{to.message_name()}.",
    state=2,
  )
  if floor.compare_int(-1_000_000) < 0 || floor.compare_int(10_000_000) > 0 {
    raise overflow
  }
  let mut days = floor.to_int()
  let frac = x.sub(Decimal::new(floor, 0))
  let mut units = frac
    .mul(Decimal::from_int64(DATETIME_UNITS_PER_DAY.to_int64()))
    .rescale(0)
    .coef()
    .to_int()
  if units >= DATETIME_UNITS_PER_DAY {
    days += 1
    units -= DATETIME_UNITS_PER_DAY
  }
  let abs_days = days + DAYS_TO_1900
  if to is DateTime {
    if abs_days < DAYS_TO_1753 || abs_days > MAX_DAYS {
      raise overflow
    }
    DateTime(days, units)
  } else {
    let mut minutes = (units + 9000) / 18000
    if minutes >= 1440 {
      days += 1
      minutes -= 1440
    }
    if days < 0 || days + DAYS_TO_1900 > DAYS_TO_2079_06_06 {
      raise overflow
    }
    SmallDateTime(days, minutes)
  }
}
