// STR and FORMAT. FORMAT runs .NET Framework formatting in SQL Server: the
// standard and custom numeric format strings over a digit buffer (ported
// from .NET's Number.Formatting: RoundNumber, FormatGeneral,
// NumberToStringFormat with the Framework's sign rules), DateTime /
// DateTimeOffset standard and custom formats, and TimeSpan formats for
// time. Culture data comes from culture_data.mbt. An invalid format string
// is a .NET FormatException, which FORMAT returns as NULL. Captures:
// msduck-runs/format, functions2/format-*.

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

// ------------------------------------------------------------ numbers

///|
/// .NET's NumberBuffer: significant digits (no leading zeros), the decimal
/// point position (`value = 0.d1d2… × 10^scale`) and the sign.
priv struct NumBuf {
  mut digits : Array[Char]
  mut scale : Int
  mut negative : Bool
  /// 0 integer, 1 decimal (SqlDecimal / SqlMoney), 2 double, 3 single
  kind : Int
}

///|
fn NumBuf::is_zero(self : NumBuf) -> Bool {
  self.digits.length() == 0
}

///|
fn NumBuf::digit(self : NumBuf, i : Int) -> Char {
  if i >= 0 && i < self.digits.length() {
    self.digits[i]
  } else {
    '\u{0}'
  }
}

///|
fn buf_of_text(
  text : String,
  point : Int,
  negative : Bool,
  kind : Int,
) -> NumBuf {
  // `text` = all digits of the coefficient, `point` = digits after the
  // decimal point
  let ds : Array[Char] = []
  let mut lead = true
  let mut skipped = 0
  for c in text {
    if lead && c == '0' {
      skipped += 1
      continue
    }
    lead = false
    ds.push(c)
  }
  {
    digits: ds,
    scale: text.length() - skipped - point,
    negative: negative && ds.length() > 0,
    kind,
  }
}

///|
/// The digit buffer .NET builds for a value: integers and decimals exactly
/// (decimal keeps trailing zeros: G prints them), doubles to 15 and singles
/// to 7 significant digits (.NET Framework DoubleToNumber precision).
fn num_buf(
  v : @types.Value,
  t : @types.SqlType,
  precision? : Int = 0,
) -> NumBuf? {
  match v {
    Float(d) => {
      let x = @types.Decimal::from_double_exact(d)
      let neg = x.sign() < 0
      let ax = if neg { x.neg() } else { x }
      let b = buf_of_text(
        ax.coef().to_string(),
        ax.scale(),
        neg,
        if t is Real {
          3
        } else {
          2
        },
      )
      let p = if precision > 0 { precision } else if t is Real { 7 } else { 15 }
      round_buf(b, p)
      Some(b)
    }
    Decimal(_) | Money(_) =>
      match v.as_decimal() {
        Some(x) => {
          let neg = x.sign() < 0
          let ax = if neg { x.neg() } else { x }
          let text = ax.coef().to_string()
          let b = buf_of_text(text, ax.scale(), neg, 1)
          if b.digits.length() == 0 {
            b.scale = -ax.scale()
          }
          Some(b)
        }
        None => None
      }
    _ =>
      match v.as_int64() {
        Some(n) => {
          let s = n.to_string()
          let neg = n < 0L
          let text = if neg {
            s.unsafe_substring(start=1, end=s.length())
          } else {
            s
          }
          Some(buf_of_text(text, 0, neg, 0))
        }
        None => None
      }
  }
}

///|
/// .NET RoundNumber (.NET Framework): keep `pos` digits, round half up,
/// drop trailing zeros; a zero result loses its sign.
fn round_buf(b : NumBuf, pos : Int) -> Unit {
  let n = b.digits.length()
  let mut i = 0
  while i < pos && i < n {
    i += 1
  }
  if i == pos && i < n && b.digits[i] >= '5' {
    while i > 0 && b.digits[i - 1] == '9' {
      i -= 1
    }
    if i > 0 {
      b.digits[i - 1] = (b.digits[i - 1].to_int() + 1).unsafe_to_char()
    } else {
      b.scale += 1
      b.digits = ['1']
      i = 1
    }
  } else {
    while i > 0 && b.digits[i - 1] == '0' {
      i -= 1
    }
  }
  if i == 0 {
    b.scale = 0
    b.negative = false
  }
  let keep : Array[Char] = []
  for k in 0..<@cmp.minimum(i, b.digits.length()) {
    keep.push(b.digits[k])
  }
  b.digits = keep
}

///|
/// Integer digits with group separators (`sizes` from the right, the last
/// size repeating; 0 stops grouping).
fn group_digits(ip : String, sep : String, sizes : Array[Int]) -> String {
  if sep == "" || sizes.length() == 0 {
    return ip
  }
  let parts : Array[String] = []
  let mut end = ip.length()
  let mut k = 0
  while end > 0 {
    let size = sizes[@cmp.minimum(k, sizes.length() - 1)]
    if size <= 0 || end <= size {
      parts.push(ip.unsafe_substring(start=0, end~))
      end = 0
    } else {
      parts.push(ip.unsafe_substring(start=end - size, end~))
      end -= size
    }
    k += 1
  }
  parts.rev_in_place()
  parts.join(sep)
}

///|
/// FormatFixed: the integer digits (grouped when `sizes` is given) and
/// `dec` decimals of an already rounded buffer.
fn fixed_text(
  b : NumBuf,
  dec : Int,
  group : String,
  sizes : Array[Int],
  dec_sep : String,
) -> String {
  let ip = StringBuilder()
  if b.scale > 0 {
    for i in 0..<b.scale {
      ip.write_char(if i < b.digits.length() { b.digits[i] } else { '0' })
    }
  } else {
    ip.write_char('0')
  }
  let out = StringBuilder()
  out.write_string(group_digits(ip.to_string(), group, sizes))
  if dec > 0 {
    out.write_string(dec_sep)
    let mut k = b.scale
    for _ in 0..<dec {
      out.write_char(if k < 0 { '0' } else { b.digit(k) |> nz })
      k += 1
    }
  }
  out.to_string()
}

///|
fn nz(c : Char) -> Char {
  if c == '\u{0}' {
    '0'
  } else {
    c
  }
}

///|
fn exponent_text(
  value : Int,
  ch : Char,
  min_digits : Int,
  positive_sign : Bool,
  c : CultureData,
) -> String {
  let out = StringBuilder()
  out.write_char(ch)
  if value < 0 {
    out.write_string(c.neg_sign)
  } else if positive_sign {
    out.write_char('+')
  }
  let s = value.abs().to_string()
  if s.length() < min_digits {
    out.write_string("0".repeat(min_digits - s.length()))
  }
  out.write_string(s)
  out.to_string()
}

///|
/// .NET FormatGeneral.
fn general_text(
  b : NumBuf,
  max_digits : Int,
  exp_char : Char,
  suppress_scientific : Bool,
  c : CultureData,
) -> String {
  let out = StringBuilder()
  if b.negative {
    out.write_string(c.neg_sign)
  }
  let mut dig_pos = b.scale
  let mut scientific = false
  if !suppress_scientific && (dig_pos > max_digits || dig_pos < -3) {
    dig_pos = 1
    scientific = true
  }
  let mut k = 0
  if dig_pos > 0 {
    while dig_pos > 0 {
      out.write_char(nz(b.digit(k)))
      if k < b.digits.length() {
        k += 1
      }
      dig_pos -= 1
    }
  } else {
    out.write_char('0')
  }
  if k < b.digits.length() || dig_pos < 0 {
    out.write_string(c.n_dec)
    while dig_pos < 0 {
      out.write_char('0')
      dig_pos += 1
    }
    while k < b.digits.length() {
      out.write_char(b.digits[k])
      k += 1
    }
  }
  if scientific {
    out.write_string(exponent_text(b.scale - 1, exp_char, 2, true, c))
  }
  out.to_string()
}

///|
fn apply_pattern(pattern : String, number : String) -> String {
  pattern.replace(old="#", new=number)
}

///|
/// .NET ParseFormatSpecifier: a letter followed by up to two digits (a
/// third digit makes it custom) is a standard format.
fn standard_spec(f : String) -> (Char, Int)? {
  if f.length() == 0 {
    return Some(('G', -1))
  }
  let ch = f.code_unit_at(0).to_int().unsafe_to_char()
  if !ch.is_ascii_alphabetic() {
    return None
  }
  let mut i = 1
  let mut n = -1
  let len = f.length()
  let dig = (k : Int) => {
    let u = f.code_unit_at(k).to_int()
    if u >= 0x30 && u <= 0x39 {
      Some(u - 0x30)
    } else {
      None
    }
  }
  if i < len && dig(i) is Some(d) {
    n = d
    i += 1
    while i < len && dig(i) is Some(d2) {
      n = n * 10 + d2
      i += 1
      if n >= 10 {
        break
      }
    }
  }
  if i >= len {
    Some((ch, n))
  } else {
    None
  }
}

///|
/// A standard numeric format; None is a FormatException (NULL).
fn standard_number(
  spec : Char,
  prec : Int,
  v : @types.Value,
  t : @types.SqlType,
  c : CultureData,
) -> String? {
  let is_int = t.family() is FInteger
  let is_float = v is Float(_)
  match spec {
    'C' | 'c' => {
      guard num_buf(v, t) is Some(b) else { return None }
      let n = if prec < 0 { c.c_digits } else { prec }
      round_buf(b, b.scale + n)
      let body = fixed_text(b, n, c.c_group, c.c_sizes, c.c_dec)
      Some(apply_pattern(if b.negative { c.c_neg } else { c.c_pos }, body))
    }
    'F' | 'f' | 'N' | 'n' => {
      guard num_buf(v, t) is Some(b) else { return None }
      let n = if prec < 0 { c.n_digits } else { prec }
      round_buf(b, b.scale + n)
      if spec is ('F' | 'f') {
        let body = fixed_text(b, n, "", [], c.n_dec)
        Some(if b.negative { c.neg_sign + body } else { body })
      } else {
        let body = fixed_text(b, n, c.n_group, c.n_sizes, c.n_dec)
        Some(if b.negative { apply_pattern(c.n_neg, body) } else { body })
      }
    }
    'P' | 'p' => {
      guard num_buf(v, t) is Some(b) else { return None }
      let n = if prec < 0 { c.p_digits } else { prec }
      if !b.is_zero() {
        b.scale += 2
      }
      round_buf(b, b.scale + n)
      let body = fixed_text(b, n, c.p_group, c.p_sizes, c.p_dec)
      Some(apply_pattern(if b.negative { c.p_neg } else { c.p_pos }, body))
    }
    'E' | 'e' => {
      let n = if prec < 0 { 6 } else { prec }
      let precision = match t {
        Real if n > 6 => 9
        Float if n > 14 => 17
        _ => 0
      }
      guard num_buf(v, t, precision~) is Some(b) else { return None }
      round_buf(b, n + 1)
      let out = StringBuilder()
      if b.negative {
        out.write_string(c.neg_sign)
      }
      out.write_char(nz(b.digit(0)))
      if n > 0 {
        out.write_string(c.n_dec)
        for k in 1..<=n {
          out.write_char(nz(b.digit(k)))
        }
      }
      let e = if b.is_zero() { 0 } else { b.scale - 1 }
      out.write_string(exponent_text(e, spec, 3, true, c))
      Some(out.to_string())
    }
    'G' | 'g' => {
      let exp_char = if spec == 'G' { 'E' } else { 'e' }
      // .NET Framework: G16+ reads a double with 17 digits, a single
      // with 9 for G8+ (captured: G17 of 0.1+0.2 is 0.30000000000000004)
      let precision = match t {
        Real if prec > 7 => 9
        Float if prec > 15 => 17
        _ => 0
      }
      guard num_buf(v, t, precision~) is Some(b) else { return None }
      if prec < 1 {
        match b.kind {
          // decimal: every digit, never scientific (captured: 42.50 is
          // '42.50', decimal(38,38) prints all 38 digits)
          1 => Some(general_text(b, b.digits.length(), exp_char, true, c))
          0 => Some(general_text(b, 19, exp_char, false, c))
          2 => Some(general_text(b, 15, exp_char, false, c))
          _ => Some(general_text(b, 7, exp_char, false, c))
        }
      } else {
        round_buf(b, prec)
        Some(general_text(b, prec, exp_char, false, c))
      }
    }
    'R' | 'r' => {
      if !is_float {
        return None
      }
      guard v is Float(d) else { return None }
      let short = if t is Real { 7 } else { 15 }
      let long = if t is Real { 9 } else { 17 }
      guard num_buf(v, t, precision=short) is Some(b) else { return None }
      let text = general_text(b, short, 'E', false, c)
      // round trip: the short form must read back as the same value
      let back = buf_value(b)
      let same = if t is Real {
        Float::from_double(back).to_double() == d
      } else {
        back == d
      }
      if same {
        Some(text)
      } else {
        guard num_buf(v, t, precision=long) is Some(b2) else { return None }
        Some(general_text(b2, long, 'E', false, c))
      }
    }
    'D' | 'd' => {
      if !is_int {
        return None
      }
      let n = v.as_int64().unwrap_or(0L)
      let s = n.to_string()
      let digits = if n < 0L {
        s.unsafe_substring(start=1, end=s.length())
      } else {
        s
      }
      let padded = if digits.length() < prec {
        "0".repeat(prec - digits.length()) + digits
      } else {
        digits
      }
      Some(if n < 0L { c.neg_sign + padded } else { padded })
    }
    'X' | 'x' => {
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
      Some(
        if hex.length() < prec {
          "0".repeat(prec - hex.length()) + hex
        } else {
          hex
        },
      )
    }
    _ => None
  }
}

///|
/// The double a rounded buffer denotes (for the 'R' round-trip check).
fn buf_value(b : NumBuf) -> Double {
  if b.is_zero() {
    return 0.0
  }
  let ds = String::from_array(b.digits)
  let text = (if b.negative { "-" } else { "" }) +
    "0." +
    ds +
    "e" +
    b.scale.to_string()
  @types.parse_float_text(text).unwrap_or(@double.not_a_number)
}

///|
/// .NET FindSection: the start of section `n` (0 positive, 1 negative,
/// 2 zero) of a custom format, 0 when it is missing or empty.
fn find_section(f : Array[Char], n : Int) -> Int {
  if n == 0 {
    return 0
  }
  let len = f.length()
  let mut section = n
  let mut src = 0
  while src < len {
    let ch = f[src]
    src += 1
    match ch {
      '\'' | '"' => {
        while src < len && f[src] != ch {
          src += 1
        }
        if src < len {
          src += 1
        }
      }
      '\\' => if src < len { src += 1 }
      ';' => {
        section -= 1
        if section == 0 {
          if src < len && f[src] != ';' {
            return src
          }
          return 0
        }
      }
      _ => ()
    }
  }
  0
}

///|
/// .NET NumberToStringFormat (custom numeric format strings).
fn custom_number(
  b : NumBuf,
  format : String,
  c : CultureData,
  literal? : Bool = false,
) -> String {
  let f = format.to_array()
  let len = f.length()
  let mut section = find_section(
    f,
    if b.is_zero() {
      2
    } else if b.negative {
      1
    } else {
      0
    },
  )
  let mut digit_count = 0
  let mut decimal_pos = -1
  let mut first_digit = 0x7FFFFFFF
  let mut last_digit = 0
  let mut scientific = false
  let mut thousand_pos = -1
  let mut thousand_count = 0
  let mut thousand_seps = false
  let mut scale_adjust = 0
  while true {
    digit_count = 0
    decimal_pos = -1
    first_digit = 0x7FFFFFFF
    last_digit = 0
    scientific = false
    thousand_pos = -1
    thousand_seps = false
    scale_adjust = 0
    let mut src = section
    while src < len && f[src] != ';' {
      let ch = f[src]
      src += 1
      match ch {
        '#' => digit_count += 1
        '0' => {
          if first_digit == 0x7FFFFFFF {
            first_digit = digit_count
          }
          digit_count += 1
          last_digit = digit_count
        }
        '.' => if decimal_pos < 0 { decimal_pos = digit_count }
        ',' =>
          if digit_count > 0 && decimal_pos < 0 {
            if thousand_pos >= 0 {
              if thousand_pos == digit_count {
                thousand_count += 1
                continue
              }
              thousand_seps = true
            }
            thousand_pos = digit_count
            thousand_count = 1
          }
        '%' => scale_adjust += 2
        '\u{2030}' => scale_adjust += 3
        '\'' | '"' => {
          while src < len && f[src] != ch {
            src += 1
          }
          if src < len {
            src += 1
          }
        }
        '\\' => if src < len { src += 1 }
        'E' | 'e' =>
          if (src < len && f[src] == '0') ||
            (
              src + 1 < len &&
              (f[src] == '+' || f[src] == '-') &&
              f[src + 1] == '0'
            ) {
            src += 1
            while src < len && f[src] == '0' {
              src += 1
            }
            scientific = true
          }
        _ => ()
      }
    }
    if decimal_pos < 0 {
      decimal_pos = digit_count
    }
    if thousand_pos >= 0 {
      if thousand_pos == decimal_pos {
        scale_adjust -= thousand_count * 3
      } else {
        thousand_seps = true
      }
    }
    if !b.is_zero() {
      b.scale += scale_adjust
      let pos = if scientific {
        digit_count
      } else {
        b.scale + digit_count - decimal_pos
      }
      round_buf(b, pos)
      if b.is_zero() {
        let s2 = find_section(f, 2)
        if s2 != section {
          section = s2
          continue
        }
      }
    } else {
      b.scale = 0
    }
    break
  }
  let first_digit = if first_digit < decimal_pos {
    decimal_pos - first_digit
  } else {
    0
  }
  let last_digit = if last_digit > decimal_pos {
    decimal_pos - last_digit
  } else {
    0
  }
  let mut dig_pos = 0
  let mut adjust = 0
  if scientific {
    dig_pos = decimal_pos
    adjust = 0
  } else {
    dig_pos = if b.scale > decimal_pos { b.scale } else { decimal_pos }
    adjust = b.scale - decimal_pos
  }
  // group separator positions (counted from the decimal point)
  let sep_pos : Array[Int] = []
  if thousand_seps && c.n_group != "" {
    let sizes = c.n_sizes
    let mut idx = 0
    let mut total = sizes[0]
    let mut size = total
    let total_digits = dig_pos + (if adjust < 0 { adjust } else { 0 })
    let num_digits = if first_digit > total_digits {
      first_digit
    } else {
      total_digits
    }
    while num_digits > total {
      if size == 0 {
        break
      }
      sep_pos.push(total)
      if idx < sizes.length() - 1 {
        idx += 1
        size = sizes[idx]
      }
      total += size
    }
  }
  let mut sep_ctr = sep_pos.length() - 1
  let out = StringBuilder()
  if b.negative && section == 0 {
    out.write_string(c.neg_sign)
  }
  let mut decimal_written = false
  let mut cur = 0
  let mut src = section
  let emit_sep = () => {
    if thousand_seps && dig_pos > 1 && sep_ctr >= 0 {
      if dig_pos == sep_pos[sep_ctr] + 1 {
        out.write_string(c.n_group)
        sep_ctr -= 1
      }
    }
  }
  while src < len && f[src] != ';' {
    let ch = f[src]
    src += 1
    // decimal/money quirk: placeholders print as written (see format_value)
    if literal && ch is ('#' | '0' | '.' | ',') {
      out.write_char(ch)
      continue
    }
    if adjust > 0 && ch is ('#' | '0' | '.') {
      while adjust > 0 {
        out.write_char(
          if cur < b.digits.length() {
            cur += 1
            b.digits[cur - 1]
          } else {
            '0'
          },
        )
        emit_sep()
        dig_pos -= 1
        adjust -= 1
      }
    }
    match ch {
      '#' | '0' => {
        let d = if adjust < 0 {
          adjust += 1
          if dig_pos <= first_digit {
            '0'
          } else {
            '\u{0}'
          }
        } else if cur < b.digits.length() {
          cur += 1
          b.digits[cur - 1]
        } else if dig_pos > last_digit {
          '0'
        } else {
          '\u{0}'
        }
        if d != '\u{0}' {
          out.write_char(d)
          emit_sep()
        }
        dig_pos -= 1
      }
      '.' =>
        if dig_pos == 0 && !decimal_written {
          if last_digit < 0 ||
            (decimal_pos < digit_count && cur < b.digits.length()) {
            out.write_string(c.n_dec)
            decimal_written = true
          }
        }
      '\u{2030}' => out.write_string(c.permille)
      '%' => out.write_string(c.percent)
      ',' => ()
      '\'' | '"' => {
        while src < len && f[src] != ch {
          out.write_char(f[src])
          src += 1
        }
        if src < len {
          src += 1
        }
      }
      '\\' =>
        if src < len {
          out.write_char(f[src])
          src += 1
        }
      'E' | 'e' => {
        let mut positive_sign = false
        let mut i = 0
        let mut handled = true
        if scientific {
          if src < len && f[src] == '0' {
            i += 1
          } else if src + 1 < len && f[src] == '+' && f[src + 1] == '0' {
            positive_sign = true
          } else if src + 1 < len && f[src] == '-' && f[src + 1] == '0' {
            ()
          } else {
            out.write_char(ch)
            handled = false
          }
          if handled {
            src += 1
            while src < len && f[src] == '0' {
              src += 1
              i += 1
            }
            if i > 10 {
              i = 10
            }
            let e = if b.is_zero() { 0 } else { b.scale - decimal_pos }
            out.write_string(exponent_text(e, ch, i, positive_sign, c))
            scientific = false
          }
        } else {
          out.write_char(ch)
          if src < len {
            if f[src] == '+' || f[src] == '-' {
              out.write_char(f[src])
              src += 1
            }
            while src < len && f[src] == '0' {
              out.write_char(f[src])
              src += 1
            }
          }
        }
      }
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

// ------------------------------------------------------------ dates

///|
/// A date/time value as .NET sees it: DateTime (datetime, datetime2,
/// smalldatetime, date) or DateTimeOffset (offset Some).
priv struct NetDate {
  year : Int
  month : Int
  day : Int
  weekday : Int // 0 = Sunday
  hour : Int
  minute : Int
  second : Int
  ticks : Int64 // 100 ns within the second
  offset : Int?
}

///|
fn net_date(m : Moment) -> NetDate {
  let (y, mo, d) = @types.civil_from_days(m.days)
  let ns = m.ns
  {
    year: y,
    month: mo,
    day: d,
    weekday: weekday_index(m.days),
    hour: (ns / 3_600_000_000_000L).to_int(),
    minute: (ns / 60_000_000_000L % 60L).to_int(),
    second: (ns / 1_000_000_000L % 60L).to_int(),
    ticks: ns % 1_000_000_000L / 100L,
    offset: m.offset,
  }
}

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
fn unsupported_format(f : String) -> @types.SqlError {
  @types.not_supported("FORMAT with format string '\{f}'")
}

///|
/// .NET uses genitive month names when the format also has a day number
/// ('d' or 'dd' outside quotes).
fn has_day_number(f : Array[Char]) -> Bool {
  let n = f.length()
  let mut i = 0
  while i < n {
    let ch = f[i]
    match ch {
      '\'' | '"' => {
        i += 1
        while i < n && f[i] != ch {
          i += 1
        }
        i += 1
      }
      '\\' => i += 2
      'd' => {
        let mut run = 0
        while i < n && f[i] == 'd' {
          run += 1
          i += 1
        }
        if run <= 2 {
          return true
        }
      }
      _ => i += 1
    }
  }
  false
}

///|
/// .NET DateTimeFormat.FormatCustomized. None is a FormatException.
fn custom_date(
  dt : NetDate,
  format : String,
  c : CultureData,
) -> String? raise @types.SqlError {
  let f = format.to_array()
  let n = f.length()
  let genitive = has_day_number(f)
  let year = if c.calendar == 1 { dt.year + 543 } else { dt.year }
  let out = StringBuilder()
  let mut i = 0
  while i < n {
    let ch = f[i]
    let mut run = 1
    while i + run < n && f[i + run] == ch {
      run += 1
    }
    match ch {
      'y' =>
        out.write_string(
          match run {
            1 => (year % 100).to_string()
            2 => pad_n((year % 100).to_int64(), 2)
            _ => pad_n(year.to_int64(), run)
          },
        )
      'M' =>
        out.write_string(
          match run {
            1 => dt.month.to_string()
            2 => pad2(dt.month)
            3 =>
              (if genitive { c.months_abbr_gen } else { c.months_abbr })[dt.month -
              1]
            _ => (if genitive { c.months_gen } else { c.months })[dt.month - 1]
          },
        )
      'd' =>
        out.write_string(
          match run {
            1 => dt.day.to_string()
            2 => pad2(dt.day)
            3 => c.days_abbr[dt.weekday]
            _ => c.days[dt.weekday]
          },
        )
      'H' => {
        let h = dt.hour
        out.write_string(if run == 1 { h.to_string() } else { pad2(h) })
      }
      'h' => {
        let h = if dt.hour % 12 == 0 { 12 } else { dt.hour % 12 }
        out.write_string(if run == 1 { h.to_string() } else { pad2(h) })
      }
      'm' =>
        out.write_string(
          if run == 1 {
            dt.minute.to_string()
          } else {
            pad2(dt.minute)
          },
        )
      's' =>
        out.write_string(
          if run == 1 {
            dt.second.to_string()
          } else {
            pad2(dt.second)
          },
        )
      'f' | 'F' => {
        if run > 7 {
          return None
        }
        let digits = pad_n(dt.ticks / pow10i(7 - run), run)
        if ch == 'F' {
          let mut t = digits
          while t.length() > 0 && t.has_suffix("0") {
            t = t.unsafe_substring(start=0, end=t.length() - 1)
          }
          if t == "" {
            // captured: 'ss.FFF' of a whole second is '09' (the '.' goes)
            let s = out.to_string()
            if s.has_suffix(".") {
              out.reset()
              out.write_string(s.unsafe_substring(start=0, end=s.length() - 1))
            }
          }
          out.write_string(t)
        } else {
          out.write_string(digits)
        }
      }
      't' => {
        let d = if dt.hour < 12 { c.am } else { c.pm }
        out.write_string(
          if run == 1 {
            if d.length() > 0 {
              d.unsafe_substring(start=0, end=1)
            } else {
              ""
            }
          } else {
            d
          },
        )
      }
      'z' => {
        // a DateTime reads the server's zone: UTC on the oracle (captured
        // 'zzz' of datetime2 is '+00:00')
        let off = dt.offset.unwrap_or(0)
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
      'K' => {
        match dt.offset {
          Some(off) => out.write_string(offset_text(off))
          None => ()
        }
        i += 1
        continue
      }
      'g' =>
        if c.calendar == 0 && (c.name == "iv" || c.name.has_prefix("en")) {
          out.write_string("A.D.")
        } else {
          raise unsupported_format(format)
        }
      ':' => {
        out.write_string(c.time_sep)
        i += 1
        continue
      }
      '/' => {
        out.write_string(c.date_sep)
        i += 1
        continue
      }
      '\'' | '"' => {
        let mut j = i + 1
        while j < n && f[j] != ch {
          if f[j] == '\\' && j + 1 < n {
            j += 1
          }
          out.write_char(f[j])
          j += 1
        }
        i = j + 1
        continue
      }
      '%' => {
        // '%x': a single custom specifier
        if i + 1 < n && f[i + 1] != '%' {
          match custom_date(dt, f[i + 1].to_string(), c) {
            Some(s) => out.write_string(s)
            None => return None
          }
          i += 2
          continue
        }
        return None
      }
      '\\' => {
        if i + 1 < n {
          out.write_char(f[i + 1])
          i += 2
          continue
        }
        return None
      }
      _ => {
        out.write_char(ch)
        i += 1
        continue
      }
    }
    i += run
  }
  Some(out.to_string())
}

///|
/// Standard and custom DateTime / DateTimeOffset formats.
fn format_date(
  dt : NetDate,
  utc : NetDate,
  f : String,
  c : CultureData,
) -> String? raise @types.SqlError {
  let dto = dt.offset is Some(_)
  if f.length() != 1 {
    if c.calendar == 2 {
      raise @types.not_supported(
        "FORMAT of dates in culture \{c.name} (Hijri calendar)",
      )
    }
    return custom_date(dt, f, c)
  }
  let inv = invariant_culture()
  let greg = (p : String) => {
    if c.calendar == 2 {
      raise @types.not_supported(
        "FORMAT of dates in culture \{c.name} (Hijri calendar)",
      )
    }
    custom_date(dt, p, c)
  }
  match f.code_unit_at(0).to_int().unsafe_to_char() {
    'd' => greg(c.pat_d)
    'D' => greg(c.pat_long_d)
    'f' => greg(c.pat_f)
    'F' => greg(c.pat_long_f)
    'g' => greg(c.pat_g)
    'G' => greg(c.pat_long_g)
    'm' | 'M' => greg(c.pat_m)
    't' => greg(c.pat_t)
    'T' => greg(c.pat_long_t)
    'y' | 'Y' => greg(c.pat_y)
    'o' | 'O' =>
      custom_date(
        dt,
        if dto {
          "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffffzzz"
        } else {
          "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffff"
        },
        inv,
      )
    'r' | 'R' => custom_date(utc, "ddd, dd MMM yyyy HH':'mm':'ss 'GMT'", inv)
    's' => custom_date(dt, "yyyy'-'MM'-'dd'T'HH':'mm':'ss", inv)
    'u' => custom_date(utc, "yyyy'-'MM'-'dd HH':'mm':'ss'Z'", inv)
    // captured: 'U' of a datetimeoffset is NULL (FormatException); a
    // DateTime is converted from the server zone (UTC) to UTC
    'U' => if dto { None } else { greg(c.pat_long_f) }
    _ => None
  }
}

///|
/// TimeSpan formats (time values). None is a FormatException.
fn format_timespan(ns : Int64, f : String, c : CultureData) -> String? {
  let h = (ns / 3_600_000_000_000L).to_int()
  let mi = (ns / 60_000_000_000L % 60L).to_int()
  let s = (ns / 1_000_000_000L % 60L).to_int()
  let ticks = ns % 1_000_000_000L / 100L
  if f.length() == 1 {
    let base = pad2(h) + ":" + pad2(mi) + ":" + pad2(s)
    return match f {
      "c" | "t" | "T" =>
        Some(if ticks == 0L { base } else { base + "." + pad_n(ticks, 7) })
      "g" => {
        let frac = pad_n(ticks, 7)
        let mut t = frac
        while t.length() > 0 && t.has_suffix("0") {
          t = t.unsafe_substring(start=0, end=t.length() - 1)
        }
        let b = h.to_string() + ":" + pad2(mi) + ":" + pad2(s)
        Some(if t == "" { b } else { b + c.n_dec + t })
      }
      "G" => Some("0:" + base + c.n_dec + pad_n(ticks, 7))
      _ => None
    }
  }
  let chars = f.to_array()
  let n = chars.length()
  let out = StringBuilder()
  let mut i = 0
  while i < n {
    let ch = chars[i]
    let mut run = 1
    while i + run < n && chars[i + run] == ch {
      run += 1
    }
    match ch {
      'd' => {
        if run > 8 {
          return None
        }
        out.write_string(pad_n(0L, run))
      }
      'h' => {
        if run > 2 {
          return None
        }
        out.write_string(if run == 1 { h.to_string() } else { pad2(h) })
      }
      'm' => {
        if run > 2 {
          return None
        }
        out.write_string(if run == 1 { mi.to_string() } else { pad2(mi) })
      }
      's' => {
        if run > 2 {
          return None
        }
        out.write_string(if run == 1 { s.to_string() } else { pad2(s) })
      }
      'f' | 'F' => {
        if run > 7 {
          return None
        }
        let digits = pad_n(ticks / pow10i(7 - run), run)
        if ch == 'F' {
          let mut t = digits
          while t.length() > 0 && t.has_suffix("0") {
            t = t.unsafe_substring(start=0, end=t.length() - 1)
          }
          out.write_string(t)
        } else {
          out.write_string(digits)
        }
      }
      '\'' | '"' => {
        let mut j = i + 1
        while j < n && chars[j] != ch {
          out.write_char(chars[j])
          j += 1
        }
        if j >= n {
          return None
        }
        i = j + 1
        continue
      }
      '\\' => {
        if i + 1 >= n {
          return None
        }
        out.write_char(chars[i + 1])
        i += 2
        continue
      }
      '%' => {
        i += 1
        continue
      }
      // captured: FORMAT(time, 'hh:mm') is NULL: every literal must be
      // quoted or escaped
      _ => return None
    }
    i += run
  }
  Some(out.to_string())
}

// ------------------------------------------------------------ FORMAT

///|
fn format_value(
  ctx : Ctx,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value raise @types.SqlError {
  let c = if v.length() > 2 {
    match v[2] {
      String(name) =>
        resolve_culture(name, "FORMAT", number=@types.EMU_FORMAT_CULTURE)
      Null => raise culture_not_supported("NULL")
      _ => raise culture_not_supported("")
    }
  } else {
    session_culture(ctx, "FORMAT", number=@types.EMU_FORMAT_CULTURE)
  }
  if v[0] is Null {
    return Null
  }
  // captured: a NULL format formats like 'G' (FORMAT(1234.5, CAST(NULL AS
  // nvarchar(10)), 'de-DE') is '1234,50')
  let f = match v[1] {
    String(s) => s
    _ => ""
  }
  let t = args[0].ty
  let r = match t.family() {
    FDate | FDateTime => {
      guard moment(v[0]) is Some(m) else { return Null }
      // datetime reaches .NET as SqlDateTime: whole milliseconds
      let m = match v[0] {
        DateTime(_, u) => {
          let ms = (u.to_int64() * 20L + 3L) / 6L
          { ..m, ns: ms * 1_000_000L, }
        }
        _ => m
      }
      let dt = net_date(m)
      let utc = match m.offset {
        Some(off) => {
          let shifted = m.ns - off.to_int64() * 60_000_000_000L
          let carry = if shifted < 0L {
            -1
          } else if shifted >= ns_per_day {
            1
          } else {
            0
          }
          let um : Moment = {
            days: m.days + carry,
            ns: shifted - carry.to_int64() * ns_per_day,
            offset: None,
          }
          net_date(um)
        }
        None => dt
      }
      format_date(dt, utc, f, c)
    }
    FTime => {
      guard moment(v[0]) is Some(m) else { return Null }
      format_timespan(m.ns, f, c)
    }
    FInteger | FDecimal | FMoney | FFloat =>
      match standard_spec(f) {
        Some((spec, prec)) => standard_number(spec, prec, v[0], t, c)
        None =>
          match num_buf(v[0], t) {
            // captured probes: for decimal and money a custom format that
            // starts with a quote prints its digit placeholders as written
            // ('a'0 is 'a0', '#'0'!' is '#0!'; int and float print 'a5'),
            // while sections and the sign still apply ('a'0 of -5 is
            // '-a0', "a"0;"b"0 of -5 'b0')
            Some(b) if b.kind == 1 && (f.has_prefix("'") || f.has_prefix("\"")) =>
              Some(custom_number(b, f, c, literal=true))
            Some(b) => Some(custom_number(b, f, c))
            None => None
          }
      }
    _ => raise @types.not_supported("FORMAT of \{t.to_sql()}")
  }
  match r {
    // captured: FORMAT is nvarchar(4000)
    Some(s) =>
      String(
        if s.length() > 4000 {
          s.unsafe_substring(start=0, end=4000)
        } else {
          s
        },
      )
    None => Null
  }
}
