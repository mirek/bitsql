///|
/// sys.time_zone_info rows in SQL Server's catalog order. SQL Server reads
/// the server's local clock as a wall-clock time in every zone (captured:
/// at 2026-10-03 20:37 UTC on a UTC server, AUS Eastern Standard Time showed
/// +10:00 / not DST although AT TIME ZONE already gave +11:00, because its
/// DST began at 02:00 local on Oct 4). bitsql's server clock is UTC, so
/// `now` (the request's clock, UTC ticks) is that wall time.
fn time_zone_rows(now : Int64) -> Array[VRow] {
  let out : Array[VRow] = []
  for z in 0..<@types.tz_count() {
    let (utc, off) = @types.tz_local_to_utc(z, now)
    let (_, dst) = @types.tz_offset_info(z, utc)
    out.push(
      vrow([
        ("name", s(@types.tz_name(z))),
        ("current_utc_offset", s(@types.format_offset(off))),
        ("is_currently_dst", b(dst)),
      ]),
    )
  }
  out
}
