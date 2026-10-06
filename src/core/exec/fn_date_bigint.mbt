///|
fn date_big(n : Int64) -> @bigint.BigInt {
  @bigint.BigInt::from_int64(n)
}

///|
fn date_big_floor(n : @bigint.BigInt, d : Int64) -> @bigint.BigInt {
  let divisor = date_big(d)
  let q = n / divisor
  if n % divisor < date_big(0L) {
    q - date_big(1L)
  } else {
    q
  }
}

///|
fn date_big_round(n : @bigint.BigInt, d : Int64) -> @bigint.BigInt {
  let divisor = date_big(d)
  let half = date_big(d / 2L)
  if n < date_big(0L) {
    (n - half) / divisor
  } else {
    (n + half) / divisor
  }
}

///|
/// DATEADD amounts outside int need widened multiplication before checking the
/// temporal range. Captures: sql2025/dateadd-bigint{,-extremes}.sql.
fn dateadd_bigint(
  p : String,
  amount : @bigint.BigInt,
  x : @types.Value,
  t : @types.SqlType,
) -> @types.Value raise @types.SqlError {
  // Every calendar increment outside int exceeds the complete date range.
  if !is_time_part(p) {
    raise if t == SmallDateTime {
      @types.sql_error(
        517,
        "Adding a value to a 'smalldatetime' column caused an overflow.",
        state=1,
      )
    } else {
      add_overflow(t)
    }
  }
  let n = amount.to_int64()
  let ticks_delta = match p {
    "hour" => amount * date_big(36_000_000_000L)
    "minute" => amount * date_big(600_000_000L)
    "second" => amount * date_big(10_000_000L)
    "millisecond" => amount * date_big(10_000L)
    "microsecond" => amount * date_big(10L)
    "nanosecond" => date_big(round_half_away(n, 100L))
    _ => date_big(0L)
  }
  match x {
    Time(ticks) => {
      let scale = match t {
        Time(s) => s
        _ => 7
      }
      let day = date_big(@types.TICKS_PER_DAY)
      let total = date_big(ticks) + ticks_delta
      let r = (total - date_big_floor(total, @types.TICKS_PER_DAY) * day).to_int64()
      Time(floor_mod(@types.round_ticks(r, scale), @types.TICKS_PER_DAY))
    }
    DateTime2(ticks) => {
      // Captured SQL Server edge: signed-minimum nanoseconds is a no-op
      // for datetime2/datetimeoffset, unlike time.
      if p == "nanosecond" && n == -9223372036854775807L - 1L {
        return x
      }
      let scale = match t {
        DateTime2(s) => s
        _ => 7
      }
      DateTime2(dateadd_big_ticks(ticks, ticks_delta, scale, t))
    }
    DateTimeOffset(utc, off) => {
      if p == "nanosecond" && n == -9223372036854775807L - 1L {
        return x
      }
      let scale = match t {
        DateTimeOffset(s) => s
        _ => 7
      }
      let offset = off.to_int64() * @types.TICKS_PER_MINUTE
      let loc = dateadd_big_ticks(utc + offset, ticks_delta, scale, t)
      let result = loc - offset
      if result < 0L || result > MAX_TICKS {
        raise add_overflow(t)
      }
      DateTimeOffset(result, off)
    }
    DateTime(d, units) => {
      let delta = match p {
        "hour" => amount * date_big(1_080_000L)
        "minute" => amount * date_big(18_000L)
        "second" => amount * date_big(300L)
        "millisecond" => date_big_round(amount * date_big(3L), 10L)
        _ => date_big(0L)
      }
      let per_day = @types.DATETIME_UNITS_PER_DAY.to_int64()
      let total = date_big(
          (d + @types.DAYS_TO_1900).to_int64() * per_day + units.to_int64(),
        ) +
        delta
      let days = date_big_floor(total, per_day)
      if days < date_big(@types.DAYS_TO_1753.to_int64()) ||
        days > date_big(@types.MAX_DAYS.to_int64()) {
        raise add_overflow(t)
      }
      DateTime(
        days.to_int() - @types.DAYS_TO_1900,
        (total - days * date_big(per_day)).to_int(),
      )
    }
    SmallDateTime(d, minutes) => {
      let delta = match p {
        "hour" => amount * date_big(3_600_000L)
        "minute" => amount * date_big(60_000L)
        "second" => amount * date_big(1000L)
        "millisecond" => amount
        _ => date_big(0L)
      }
      let total_ms = date_big(
          (d + @types.DAYS_TO_1900).to_int64() * 86_400_000L +
          minutes.to_int64() * 60_000L,
        ) +
        delta
      // SQL first checks the intermediate datetime range, then the narrower
      // smalldatetime range (states 1 and 2 respectively).
      let days = date_big_floor(total_ms, 86_400_000L)
      if days < date_big(@types.DAYS_TO_1753.to_int64()) ||
        days > date_big(@types.MAX_DAYS.to_int64()) {
        raise @types.sql_error(
          517,
          "Adding a value to a 'smalldatetime' column caused an overflow.",
          state=1,
        )
      }
      let total_min = date_big_floor(total_ms + date_big(30_000L), 60_000L)
      let days = date_big_floor(total_min, 1440L)
      if days < date_big(@types.DAYS_TO_1900.to_int64()) ||
        days > date_big(@types.DAYS_TO_2079_06_06.to_int64()) {
        raise add_overflow(t)
      }
      SmallDateTime(
        days.to_int() - @types.DAYS_TO_1900,
        (total_min - days * date_big(1440L)).to_int(),
      )
    }
    _ => raise add_overflow(t)
  }
}

///|
fn dateadd_big_ticks(
  ticks : Int64,
  delta : @bigint.BigInt,
  scale : Int,
  t : @types.SqlType,
) -> Int64 raise @types.SqlError {
  let result = date_big(ticks) + delta
  if result < date_big(0L) || result > date_big(MAX_TICKS) {
    raise add_overflow(t)
  }
  let rounded = @types.round_ticks(result.to_int64(), scale)
  if rounded > MAX_TICKS {
    raise add_overflow(t)
  }
  rounded
}
