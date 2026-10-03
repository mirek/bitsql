///|
/// `WAITFOR DELAY 'hh:mm:ss[.mmm]'` / `WAITFOR TIME 'hh:mm[:ss[.mmm]]'`.
/// The request parks with a host timer (decisions.md: request restart); its
/// re-run passes the waits it already completed (`waits_done`), so the
/// statements before a wait run again from the restored request state and
/// produce the same output. Completes with CurCmd 243 (captured:
/// misc/waitfor).
fn Session::exec_waitfor(
  self : Session,
  kind : String,
  e : @ast.Expr,
) -> Unit raise {
  self.cur_cmd = 243
  let (v, ty) = self.eval(e)
  let text = match
    @types.cast(v, ty, VarChar(Some(30), @types.default_collation)) {
    String(s) => s
    _ => raise @types.not_supported("WAITFOR with a NULL time")
  }
  let ms = match parse_wait_time(text) {
    Some(t) => t
    None =>
      raise @types.sql_error(
        148,
        "Incorrect time syntax in time string '\{text}' used with WAITFOR.",
        severity=15,
      )
  }
  let delay = if kind == "TIME" {
    let day = 86400000L
    let now_ms = self.rt.now / 10000L % day
    let d = (ms.to_int64() - now_ms + day) % day
    d.to_int()
  } else {
    ms
  }
  self.waits_seen += 1
  if self.waits_seen > self.waits_done {
    if delay > 0 {
      self.wait_ms = Some(delay)
      self.in_waitfor = true
      raise Park
    }
    self.waits_done = self.waits_seen
  }
  self.done(243)
}

///|
/// Milliseconds of `hh:mm[:ss[.fff]]` (hours < 24).
fn parse_wait_time(s : String) -> Int? {
  let parts = s.trim(chars=" ").split(":").map(p => p.to_owned()).collect()
  if parts.length() < 2 || parts.length() > 3 {
    return None
  }
  let int = (p : String) => @string.parse_int(p) catch { _ => -1 }
  let h = int(parts[0])
  let m = int(parts[1])
  let mut sec = 0
  let mut frac = 0
  if parts.length() == 3 {
    let sp = parts[2].split(".").map(p => p.to_owned()).collect()
    sec = int(sp[0])
    if sp.length() == 2 {
      let f = sp[1]
      let digits = if f.length() > 3 {
        f.unsafe_substring(start=0, end=3)
      } else {
        f
      }
      frac = int(digits)
      for _ in digits.length()..<3 {
        frac = frac * 10
      }
    } else if sp.length() > 2 {
      return None
    }
  }
  if h < 0 || h > 23 || m < 0 || m > 59 || sec < 0 || sec > 59 || frac < 0 {
    return None
  }
  Some(((h * 60 + m) * 60 + sec) * 1000 + frac)
}
