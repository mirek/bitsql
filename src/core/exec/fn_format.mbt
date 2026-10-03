// STR and FORMAT. FORMAT follows .NET formatting for the en-US culture;
// only the common numeric and date/time format strings are implemented,
// anything else raises an emulator error rather than guessing.

///|
/// Digits of |d| rounded half away from zero to `dec` decimals, after
/// SQL Server's 17-significant-digit reading of the double.
fn round_digits(d : Double, dec : Int) -> (String, String) {
  let x = @types.double_to_decimal17(d.abs()).rescale(dec)
  let s = x.to_string()
  match s.find(".") {
    Some(i) =>
      (
        s.unsafe_substring(start=0, end=i),
        s.unsafe_substring(start=i + 1, end=s.length()),
      )
    None => (s, "")
  }
}

///|
/// STR(x, len, dec): right-justified, decimals reduced to fit, `*` when the
/// integer part does not fit (captured: STR(1.5, 10, 20) is '1.50000000',
/// STR(1234.5, 3) '***'); NULL for a length outside 1..8000.
fn str_format(x : Double, len : Int64, dec : Int64) -> String? {
  if len < 1L || len > 8000L || dec < 0L {
    return None
  }
  let len = len.to_int()
  // captured: the sign stays on values that round to zero (STR(-0.4) is
  // '-0'); decimals are fitted to the truncated integer part first, then
  // the rounded text must fit (STR(99.99, 4, 1) is '****', STR(9.96, 4, 1)
  // '10.0')
  let neg = x < 0.0
  let sign = if neg { 1 } else { 0 }
  let int_digits = @types.double_to_decimal17(x.abs())
    .trunc_to_bigint()
    .to_string()
    .length()
  if int_digits + sign > len {
    return Some("*".repeat(len))
  }
  let avail = len - int_digits - sign
  let d = if avail >= 2 {
    @cmp.minimum(@cmp.minimum(dec, 16L).to_int(), avail - 1)
  } else {
    0
  }
  let (ip, fp) = round_digits(x, d)
  let body = if d > 0 { ip + "." + fp } else { ip }
  let full = (if neg { "-" } else { "" }) + body
  if full.length() > len {
    return Some("*".repeat(len))
  }
  Some(" ".repeat(len - full.length()) + full)
}

///|
fn group3(s : String) -> String {
  let out = StringBuilder()
  let n = s.length()
  for i in 0..<n {
    if i > 0 && (n - i) % 3 == 0 {
      out.write_char(',')
    }
    out.write_char(s.code_unit_at(i).to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn unsupported_format(f : String) -> @types.SqlError {
  @types.not_supported("FORMAT with format string '\{f}'")
}

///|
/// A number to format: exact decimal for exact types, 17-digit decimal of
/// the double for float/real.
fn format_number(
  v : @types.Value,
  t : @types.SqlType,
) -> (@types.Decimal, Bool)? {
  match v {
    Float(d) => {
      // .NET Framework formats a double from 15 significant digits, a
      // float32 from 7 (captured: FORMAT(CAST(0.1 AS float), 'N20') is
      // 0.10000000000000000000)
      let x = @types.Decimal::from_double_exact(d)
      let sig = if t is Real { 7 } else { 15 }
      let drop = x.digits() - sig
      let r = if drop > 0 {
        round_decimal(x, (x.scale() - drop).to_int64(), false)
      } else {
        x
      }
      Some((r.normalize(), t is Real))
    }
    _ =>
      match v.as_decimal() {
        Some(x) => Some((x, false))
        None => None
      }
  }
}

///|
fn dec_parts(x : @types.Decimal, places : Int) -> (Bool, String, String) {
  let r = x.rescale(places)
  let neg = r.sign() < 0
  let s = (if neg { r.neg() } else { r }).to_string()
  match s.find(".") {
    Some(i) =>
      (
        neg,
        s.unsafe_substring(start=0, end=i),
        s.unsafe_substring(start=i + 1, end=s.length()),
      )
    None => (neg, s, "")
  }
}

///|
fn standard_numeric(
  spec : Char,
  prec : Int?,
  x : @types.Decimal,
  v : @types.Value,
  t : @types.SqlType,
  f : String,
) -> String? raise @types.SqlError {
  let is_int = t.family() is (FInteger | FBit)
  match spec.to_ascii_uppercase() {
    'N' | 'F' => {
      let (neg, ip, fp) = dec_parts(x, prec.unwrap_or(2))
      let ip = if spec.to_ascii_uppercase() == 'N' { group3(ip) } else { ip }
      let body = if fp.length() > 0 { ip + "." + fp } else { ip }
      Some(if neg { "-" + body } else { body })
    }
    'P' => {
      let (neg, ip, fp) = dec_parts(
        x.mul(@types.Decimal::from_int64(100L)),
        prec.unwrap_or(2),
      )
      let body = group3(ip) + (if fp.length() > 0 { "." + fp } else { "" })
      Some((if neg { "-" } else { "" }) + body + "%")
    }
    'C' => {
      let (neg, ip, fp) = dec_parts(x, prec.unwrap_or(2))
      if neg {
        // .NET Framework en-US negative currency pattern is unverified
        raise unsupported_format(f)
      }
      Some("$" + group3(ip) + (if fp.length() > 0 { "." + fp } else { "" }))
    }
    'D' => {
      if !is_int {
        return None
      }
      let n = v.as_int64().unwrap_or(0L)
      let digits = n.abs().to_string()
      let p = prec.unwrap_or(0)
      let padded = if digits.length() < p {
        "0".repeat(p - digits.length()) + digits
      } else {
        digits
      }
      Some(if n < 0L { "-" + padded } else { padded })
    }
    'X' => {
      if !is_int {
        return None
      }
      let n = v.as_int64().unwrap_or(0L)
      let bits = match t {
        TinyInt => 8
        SmallInt => 16
        Int => 32
        _ => 64
      }
      let u = if bits == 64 {
        n.reinterpret_as_uint64()
      } else {
        (n & ((1L << bits) - 1L)).reinterpret_as_uint64()
      }
      let hex = if u == 0UL { "0" } else { u.to_string(radix=16) }
      let hex = if spec == 'X' { hex.to_upper() } else { hex }
      let p = prec.unwrap_or(0)
      Some(
        if hex.length() < p {
          "0".repeat(p - hex.length()) + hex
        } else {
          hex
        },
      )
    }
    'E' => {
      let p = prec.unwrap_or(6)
      if x.is_zero() {
        return Some(
          "0" +
          (if p > 0 { "." + "0".repeat(p) } else { "" }) +
          (if spec == 'E' { "E+000" } else { "e+000" }),
        )
      }
      let neg = x.sign() < 0
      let ax = if neg { x.neg() } else { x }
      let digits = ax.coef().to_string()
      let exp = digits.length() - 1 - ax.scale()
      // scale the coefficient to p+1 significant digits
      let shift = p + 1 - digits.length()
      let scaled = @types.Decimal::new(ax.coef(), ax.scale() + exp)
      let r = scaled.rescale(p)
      let (r, exp) = if r.coef().to_string().length() > p + 1 {
        (@types.Decimal::new(r.coef(), r.scale() + 1).rescale(p), exp + 1)
      } else {
        (r, exp)
      }
      ignore(shift)
      let es = exp.abs().to_string()
      let es = if es.length() < 3 {
        "0".repeat(3 - es.length()) + es
      } else {
        es
      }
      Some(
        (if neg { "-" } else { "" }) +
        r.to_string() +
        (if spec == 'E' { "E" } else { "e" }) +
        (if exp < 0 { "-" } else { "+" }) +
        es,
      )
    }
    'G' =>
      if prec is None && !(v is Float(_)) {
        Some(x.normalize().to_string())
      } else {
        raise unsupported_format(f)
      }
    _ => None
  }
}

///|
/// Custom numeric formats built from 0, #, '.', ',' and '%' (one section).
fn custom_numeric(
  x : @types.Decimal,
  f : String,
) -> String? raise @types.SqlError {
  for c in f {
    if !(c is ('0' | '#' | '.' | ',' | '%')) {
      raise unsupported_format(f)
    }
  }
  let percent = f.contains("%")
  let pat = f.replace_all(old="%", new="")
  let x = if percent { x.mul(@types.Decimal::from_int64(100L)) } else { x }
  let (ipat, fpat) = match pat.find(".") {
    Some(i) =>
      (
        pat.unsafe_substring(start=0, end=i),
        pat.unsafe_substring(start=i + 1, end=pat.length()),
      )
    None => (pat, "")
  }
  let grouping = ipat.contains(",")
  let ipat = ipat.replace_all(old=",", new="")
  let max_frac = fpat.length()
  let min_frac = {
    let mut n = 0
    for i in 0..<fpat.length() {
      if fpat.code_unit_at(i).to_int() == '0'.to_int() {
        n = i + 1
      }
    }
    n
  }
  let min_int = {
    let mut n = 0
    for i in 0..<ipat.length() {
      if ipat.code_unit_at(i).to_int() == '0'.to_int() {
        n = ipat.length() - i
        break
      }
    }
    n
  }
  let (neg, ip, fp) = dec_parts(x, max_frac)
  let mut fp = fp
  while fp.length() > min_frac && fp.has_suffix("0") {
    fp = fp.unsafe_substring(start=0, end=fp.length() - 1)
  }
  let mut ip = if ip == "0" { "" } else { ip }
  if ip.length() < min_int {
    ip = "0".repeat(min_int - ip.length()) + ip
  }
  if grouping {
    ip = group3(ip)
  }
  let body = ip + (if fp.length() > 0 { "." + fp } else { "" })
  let nonzero = body.iter().any(c => c >= '1' && c <= '9')
  Some(
    (if neg && nonzero { "-" } else { "" }) +
    body +
    (if percent { "%" } else { "" }),
  )
}

///|
let short_months : Array[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
fn pad_n(n : Int64, w : Int) -> String {
  let s = n.to_string()
  if s.length() < w {
    "0".repeat(w - s.length()) + s
  } else {
    s
  }
}

///|
/// Custom date/time format (en-US). Unsupported specifiers raise.
fn custom_date(
  m : Moment,
  f : String,
  time_only : Bool,
) -> String raise @types.SqlError {
  let (y, mo, d) = @types.civil_from_days(m.days)
  let h = (m.ns / 3_600_000_000_000L).to_int()
  let mi = (m.ns / 60_000_000_000L % 60L).to_int()
  let s = (m.ns / 1_000_000_000L % 60L).to_int()
  let frac = m.ns % 1_000_000_000L // nanoseconds
  let out = StringBuilder()
  let n = f.length()
  let mut i = 0
  while i < n {
    let c = f.code_unit_at(i).to_int().unsafe_to_char()
    let mut run = 1
    while i + run < n && f.code_unit_at(i + run).to_int().unsafe_to_char() == c {
      run += 1
    }
    let date_spec = c is ('y' | 'M' | 'd' | 't')
    if time_only && date_spec {
      raise unsupported_format(f)
    }
    match c {
      'y' =>
        out.write_string(
          match run {
            1 => (y % 100).to_string()
            2 => pad_n((y % 100).to_int64(), 2)
            _ => pad_n(y.to_int64(), run)
          },
        )
      'M' =>
        out.write_string(
          match run {
            1 => mo.to_string()
            2 => pad2(mo)
            3 => short_months[mo - 1]
            _ => month_names[mo - 1]
          },
        )
      'd' =>
        out.write_string(
          match run {
            1 => d.to_string()
            2 => pad2(d)
            3 =>
              day_names[weekday_index(m.days)].unsafe_substring(start=0, end=3)
            _ => day_names[weekday_index(m.days)]
          },
        )
      'H' => out.write_string(if run == 1 { h.to_string() } else { pad2(h) })
      'h' => {
        // TimeSpan (time) formats count hours, DateTime formats 12-hour
        let h12 = if time_only { h } else if h % 12 == 0 { 12 } else { h % 12 }
        out.write_string(if run == 1 { h12.to_string() } else { pad2(h12) })
      }
      'm' => out.write_string(if run == 1 { mi.to_string() } else { pad2(mi) })
      's' => out.write_string(if run == 1 { s.to_string() } else { pad2(s) })
      'f' | 'F' => {
        if run > 7 {
          raise unsupported_format(f)
        }
        let digits = pad_n(frac / pow10i(9 - run), run)
        if c == 'F' {
          let mut t = digits
          while t.length() > 0 && t.has_suffix("0") {
            t = t.unsafe_substring(start=0, end=t.length() - 1)
          }
          out.write_string(t)
        } else {
          out.write_string(digits)
        }
      }
      't' => {
        let ampm = if h < 12 { "AM" } else { "PM" }
        out.write_string(
          if run == 1 {
            ampm.unsafe_substring(start=0, end=1)
          } else {
            ampm
          },
        )
      }
      '\\' => {
        if i + 1 < n {
          out.write_char(f.code_unit_at(i + 1).to_int().unsafe_to_char())
          i += 2
          continue
        }
        raise unsupported_format(f)
      }
      '\'' | '"' => {
        let mut j = i + 1
        while j < n && f.code_unit_at(j).to_int().unsafe_to_char() != c {
          out.write_char(f.code_unit_at(j).to_int().unsafe_to_char())
          j += 1
        }
        i = j + 1
        continue
      }
      'z' => {
        guard m.offset is Some(off) && run <= 3 else {
          raise unsupported_format(f)
        }
        let sign = if off < 0 { "-" } else { "+" }
        let a = off.abs()
        out.write_string(
          match run {
            1 => sign + (a / 60).to_string()
            2 => sign + pad2(a / 60)
            _ => sign + pad2(a / 60) + ":" + pad2(a % 60)
          },
        )
      }
      ':' | '/' | '-' | ' ' | '.' | ',' | 'T' | '_' => {
        if time_only {
          raise unsupported_format(f)
        }
        out.write_string(c.to_string().repeat(run))
      }
      _ => raise unsupported_format(f)
    }
    i += run
  }
  out.to_string()
}

///|
/// TimeSpan custom formats only allow h, m, s, f, F, d; every literal must
/// be escaped with '\' or quoted.
fn timespan_literals_escaped(f : String) -> Bool {
  let n = f.length()
  let mut i = 0
  while i < n {
    let c = f.code_unit_at(i).to_int().unsafe_to_char()
    match c {
      '\\' => i += 2
      '\'' | '"' => {
        let mut j = i + 1
        while j < n && f.code_unit_at(j).to_int().unsafe_to_char() != c {
          j += 1
        }
        i = j + 1
      }
      'h' | 'm' | 's' | 'f' | 'F' | 'd' => i += 1
      _ => return false
    }
  }
  true
}

///|
fn format_value(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value raise @types.SqlError {
  if v.iter().any(x => x is Null) {
    return Null
  }
  let f = match v[1] {
    String(s) => s
    _ => return Null
  }
  if v.length() > 2 {
    match v[2] {
      String(c) if c.to_lower() == "en-us" => ()
      _ => raise @types.not_supported("FORMAT with a culture other than en-US")
    }
  }
  let t = args[0].ty
  let r = match t.family() {
    FDate | FDateTime | FTime => {
      guard moment(v[0]) is Some(m) else { return Null }
      let time_only = t is Time(_)
      if time_only {
        if f == "c" {
          // TimeSpan constant format: hh:mm:ss[.fffffff]
          let base = custom_date(m, "hh\\:mm\\:ss", true)
          let frac = m.ns % 1_000_000_000L / 100L
          return String(
            if frac == 0L {
              base
            } else {
              base + "." + pad_n(frac, 7)
            },
          )
        }
        if !timespan_literals_escaped(f) {
          // captured: FORMAT(time, 'hh:mm') is NULL (.NET FormatException)
          return Null
        }
      }
      if f.length() == 1 {
        if time_only {
          raise unsupported_format(f)
        }
        match f {
          "d" => Some(custom_date(m, "M/d/yyyy", false))
          "D" => Some(custom_date(m, "dddd, MMMM d, yyyy", false))
          "t" => Some(custom_date(m, "h:mm tt", false))
          "T" => Some(custom_date(m, "h:mm:ss tt", false))
          "g" => Some(custom_date(m, "M/d/yyyy h:mm tt", false))
          "G" => Some(custom_date(m, "M/d/yyyy h:mm:ss tt", false))
          "s" => Some(custom_date(m, "yyyy-MM-dd'T'HH:mm:ss", false))
          "M" | "m" => Some(custom_date(m, "MMMM d", false))
          "Y" | "y" => Some(custom_date(m, "MMMM yyyy", false))
          _ => raise unsupported_format(f)
        }
      } else {
        Some(custom_date(m, f, time_only))
      }
    }
    FInteger | FDecimal | FMoney | FFloat | FBit => {
      guard format_number(v[0], t) is Some((x, _)) else { return Null }
      let first = f.code_unit_at(0).to_int().unsafe_to_char()
      let rest = f.unsafe_substring(start=1, end=f.length())
      let is_digits = rest.iter().all(c => c >= '0' && c <= '9')
      if first.is_ascii_alphabetic() && is_digits && rest.length() <= 2 {
        let prec = if rest.length() == 0 {
          None
        } else {
          Some(digits_int(rest))
        }
        standard_numeric(first, prec, x, v[0], t, f)
      } else if first.is_ascii_alphabetic() {
        raise unsupported_format(f)
      } else {
        custom_numeric(x, f)
      }
    }
    _ => raise @types.not_supported("FORMAT of \{t.to_sql()}")
  }
  match r {
    Some(s) => String(s)
    None => Null
  }
}

///|
fn digits_int(s : String) -> Int {
  let mut n = 0
  for c in s {
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  n
}
