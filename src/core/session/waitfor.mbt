///|
/// `WAITFOR DELAY|TIME '<time>' | @var`. The request parks with a host
/// timer (decisions.md: request restart); its re-run passes the waits it
/// already completed (`waits_done`), so the statements before a wait run
/// again from the restored request state and produce the same output.
/// Completes with CurCmd 243 (captured: misc/waitfor).
///
/// Argument rules (captured: msduck gaps-transactions #057–#122, corpus
/// stmts/tx-waitfor-*):
/// - a string literal must match the WAITFOR time grammar
///   (`parse_wait_time`), else compile error 148 for the whole batch
///   (precheck);
/// - a NULL variable of any type completes at once;
/// - char/varchar/nchar/nvarchar variables follow the same grammar, but a
///   mismatch is 241 (and varchar(max)/nvarchar(max) are always 241);
/// - datetime uses its time of day; int/smallint count seconds;
/// - any other type is 9815 state 0 ("cannot be of type bit").
fn Session::exec_waitfor(
  self : Session,
  kind : String,
  e : @ast.Expr,
) -> Unit raise {
  self.cur_cmd = 243
  let (v, ty) = self.eval(e)
  let ms : Int64? = match v {
    Null => None
    _ =>
      match ty {
        Char(_, _) | VarChar(Some(_), _) | NChar(_, _) | NVarChar(Some(_), _) => {
          let text = match v {
            String(s) => s
            _ => ""
          }
          match parse_wait_time(text) {
            Some(t) => Some(t.to_int64())
            None if e.kind is StrLit(_, ..) =>
              raise @types.sql_error(
                148,
                "Incorrect time syntax in time string '\{text}' used with WAITFOR.",
                severity=15,
              )
            None => raise wait_conversion_error()
          }
        }
        VarChar(None, _) | NVarChar(None, _) => raise wait_conversion_error()
        DateTime =>
          match v {
            DateTime(_, ticks) => Some(ticks.to_int64() * 10L / 3L)
            _ => None
          }
        Int | SmallInt => {
          let n = v.as_int64().unwrap_or(0L)
          if n < 0L {
            // captured: SQL Server waits (far) longer than a request
            // timeout for a negative count; not emulated
            raise @types.not_supported(
              "WAITFOR with a negative number of seconds",
            )
          }
          Some(n * 1000L)
        }
        t =>
          raise @types.sql_error(
            9815,
            "Waitfor delay and waitfor time cannot be of type \{t.base_name()}.",
            state=0,
          )
      }
  }
  let delay = match ms {
    None => 0L
    Some(ms) =>
      if kind == "TIME" {
        let day = 86400000L
        let now_ms = self.rt.now / 10000L % day
        (ms % day - now_ms + day) % day
      } else {
        ms
      }
  }
  self.waits_seen += 1
  if self.waits_seen > self.waits_done {
    if delay > 0L {
      if self.attn.cancelling {
        self.cur_cmd = 243
        self.cancel_at_wait(None)
      }
      // a delay longer than a day would outlive any client timeout
      self.wait_ms = Some(
        if delay > 86400000L {
          86400000
        } else {
          delay.to_int()
        },
      )
      self.in_waitfor = true
      raise Park
    }
    self.waits_done = self.waits_seen
  }
  self.rt.rowcount = 0L
  self.done(243)
}

///|
fn wait_conversion_error() -> @types.SqlError {
  @types.sql_error(
    241, "Conversion failed when converting date and/or time from character string.",
  )
}

///|
/// Milliseconds of a WAITFOR time string (captured, see `exec_waitfor`):
/// blanks around and between the parts are ignored; empty is 0;
/// `h:m[:s[.f|:f]]` with h 0–23, m and s 0–59, 1–3 fraction digits (`.5` is
/// 500 ms, `:5` is 5 ms); an optional upper-case ` AM`/` PM` after a blank
/// (12 AM is hour 0, 0 PM is invalid, 13 PM stays 13).
fn parse_wait_time(s : String) -> Int? {
  // tokens: (kind, text, preceded by a blank); kind 'n' number, 'w' word,
  // or the punctuation character itself
  let toks : Array[(Char, String, Bool)] = []
  let chars = s.to_array()
  let mut i = 0
  let mut blank = false
  while i < chars.length() {
    let c = chars[i]
    if c == ' ' {
      blank = true
      i += 1
    } else if c >= '0' && c <= '9' {
      let start = i
      while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
        i += 1
      }
      toks.push(('n', String::from_array(chars[start:i]), blank))
      blank = false
    } else if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
      let start = i
      while i < chars.length() &&
            (
              (chars[i] >= 'A' && chars[i] <= 'Z') ||
              (chars[i] >= 'a' && chars[i] <= 'z')
            ) {
        i += 1
      }
      toks.push(('w', String::from_array(chars[start:i]), blank))
      blank = false
    } else if c == ':' || c == '.' {
      toks.push((c, "", blank))
      blank = false
      i += 1
    } else {
      return None
    }
  }
  if toks.is_empty() {
    return Some(0)
  }
  let mut p = 0
  let num = () => {
    match toks.get(p) {
      Some(('n', t, _)) if t.length() <= 9 => {
        p += 1
        @string.parse_int(t) catch {
          _ => -1
        }
      }
      _ => -1
    }
  }
  let punct = (c : Char) => {
    match toks.get(p) {
      Some((k, _, _)) if k == c => {
        p += 1
        true
      }
      _ => false
    }
  }
  let mut h = num()
  if h < 0 || !punct(':') {
    return None
  }
  let m = num()
  if m < 0 {
    return None
  }
  let mut sec = 0
  let mut frac = 0
  if punct(':') {
    sec = num()
    if sec < 0 {
      return None
    }
    let dot = punct('.')
    if dot || punct(':') {
      let digits = match toks.get(p) {
        Some(('n', t, _)) if t.length() >= 1 && t.length() <= 3 => t
        _ => return None
      }
      p += 1
      frac = @string.parse_int(digits) catch { _ => return None }
      if dot {
        for _ in digits.length()..<3 {
          frac = frac * 10
        }
      }
    }
  }
  match toks.get(p) {
    None => ()
    Some(('w', w, true)) if (w == "AM" || w == "PM") && p == toks.length() - 1 => {
      // captured: hour 0 is valid with AM but not with PM
      if h == 0 && w == "PM" {
        return None
      }
      if w == "AM" && h == 12 {
        h = 0
      } else if w == "PM" && h < 12 {
        h += 12
      }
    }
    _ => return None
  }
  if h > 23 || m > 59 || sec > 59 {
    return None
  }
  Some(((h * 60 + m) * 60 + sec) * 1000 + frac)
}
