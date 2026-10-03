// AT TIME ZONE evaluation (bound in bind/fn_timezone.mbt). Zone rules:
// src/core/types/timezone.mbt. Captures: msduck at-time-zone*,
// harness/corpus/timezone/.

///|
/// 9820 for an unknown zone name. SQL Server shows U+0000 as '.' in the
/// message (captured: N'UTC' + NCHAR(0) + N'garbage' → 'UTC.garbage').
fn invalid_zone(name : String) -> @types.SqlError {
  @types.sql_error(
    9820,
    "The time zone parameter '\{name.replace_all(old="\u{0}", new=".")}' provided to AT TIME ZONE clause is invalid.",
  )
}

///|
fn tz_overflow() -> @types.SqlError {
  @types.sql_error(
    9813, "The timezone provided to builtin function AT TIME ZONE would cause the datetimeoffset to overflow the range of valid date range in either UTC or local time.",
  )
}

///|
/// `v[0] AT TIME ZONE v[1]`.
/// - datetimeoffset: the same instant shown in the zone's offset. A result
///   whose local time leaves 0001..9999 is clamped to the extreme UTC value
///   at +00:00 (captured, no error).
/// - datetime/smalldatetime/datetime2: a wall-clock time in the zone
///   (tz_local_to_utc); 9813 when the instant leaves the datetimeoffset range.
fn at_time_zone(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  if v[0] is Null || v[1] is Null {
    return Null
  }
  guard v[1] is String(name) else { return Null }
  guard @types.tz_lookup(name) is Some(zone) else { raise invalid_zone(name) }
  let scale = match e.ty {
    DateTimeOffset(s) => s
    _ => 7
  }
  match v[0] {
    DateTimeOffset(utc, _) => {
      let off = @types.tz_offset_at(zone, utc)
      let wall = utc + off.to_int64() * @types.TICKS_PER_MINUTE
      if wall < 0L {
        DateTimeOffset(0L, 0)
      } else if wall > MAX_TICKS {
        let unit = @types.scale_unit(scale)
        DateTimeOffset(MAX_TICKS + 1L - unit, 0)
      } else {
        DateTimeOffset(utc, off)
      }
    }
    x => {
      let wall = match x {
        DateTime2(t) => t
        _ =>
          match @types.cast(x, args[0].ty, DateTime2(scale)) {
            DateTime2(t) => t
            _ => return Null
          }
      }
      let (year, _, _) = @types.civil_from_days(
        (wall / @types.TICKS_PER_DAY).to_int(),
      )
      if @types.tz_local_unsupported(zone, year) {
        raise @types.not_supported(
          "AT TIME ZONE on \{year} local times in '\{@types.tz_name(zone)}' (irregular Windows rule year)",
        )
      }
      let (utc, off) = @types.tz_local_to_utc(zone, wall)
      let shown = utc + off.to_int64() * @types.TICKS_PER_MINUTE
      if utc < 0L || utc > MAX_TICKS || shown < 0L || shown > MAX_TICKS {
        raise tz_overflow()
      }
      DateTimeOffset(utc, off)
    }
  }
}
