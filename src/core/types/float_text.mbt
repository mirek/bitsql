// float/real ↔ text.
//
// CONVERT style 0 (also plain CAST) prints like C's `%.6g` on the *exact*
// binary value, rounding half away from zero, with an exponent of at least
// three digits: `1e+006`, `9.94922e-044`, `0.0001`, `123457` (for 123456.5).
// Verified against the 2,170-value grid in msduck
// reference/float-default-grid.json (a scaling-based formatter fails it).
// Styles 1 and 2 are `%.7e` / `%.15e` (8 and 16 significant digits) with the
// same exponent form; style 3 is not implemented.

///|
/// `p` significant digits of |d| (d finite, non-zero): digit string of
/// length `p` and the decimal exponent of its first digit. Like SQL Server,
/// the exact binary value is first rounded to 17 significant digits and that
/// is rounded (half away from zero) to `p`: the exact value
/// 1.2345749999999999779... prints as `1.23458` (grid row 3ff3c0d1b71758e2),
/// which neither exact rounding nor a 15/16-digit intermediate reproduces.
fn significant_digits(d : Double, p : Int) -> (String, Int) {
  let (d17, e17) = round_sig(
    Decimal::from_double_exact(if d < 0.0 { -d } else { d }),
    17,
  )
  if p >= 17 {
    return (d17, e17)
  }
  let (digits, e) = round_sig(
    Decimal::new(@bigint.BigInt::from_string(d17), 0),
    p,
  )
  (digits, e + e17 - 16)
}

///|
/// Round a positive decimal to `p` significant digits, half away from zero.
fn round_sig(exact : Decimal, p : Int) -> (String, Int) {
  let coef = exact.coef()
  let n = coef.to_string().length()
  let mut e = n - 1 - exact.scale()
  let q = if n > p {
    let div = pow10(n - p)
    let q0 = coef / div
    let r = coef - q0 * div
    let q1 = if (r + r).compare(div) >= 0 {
      q0 + @bigint.BigInt::from_int(1)
    } else {
      q0
    }
    if q1.to_string().length() > p {
      e += 1
      q1 / @bigint.BigInt::from_int(10)
    } else {
      q1
    }
  } else {
    coef * pow10(p - n)
  }
  (q.to_string(), e)
}

///|
fn exponent_text(e : Int) -> String {
  let sign = if e < 0 { "-" } else { "+" }
  let a = if e < 0 { -e } else { e }
  let s = a.to_string()
  sign +
  (if s.length() < 3 { String::make(3 - s.length(), '0') + s } else { s })
}

///|
fn strip_fraction_zeros(s : String) -> String {
  if !s.contains(".") {
    return s
  }
  let mut end = s.length()
  while end > 0 && s[end - 1] == '0' {
    end -= 1
  }
  if end > 0 && s[end - 1] == '.' {
    end -= 1
  }
  s.unsafe_substring(start=0, end~)
}

///|
fn is_negative(d : Double) -> Bool {
  d.reinterpret_as_uint64() >> 63 != 0
}

///|
/// `%.<p>g` with SQL Server's exponent form.
pub fn format_float_general(d : Double, p? : Int = 6) -> String {
  let sign = if is_negative(d) { "-" } else { "" }
  if d == 0.0 {
    return sign + "0"
  }
  let (digits, e) = significant_digits(d, p)
  if e < -4 || e >= p {
    let mant = strip_fraction_zeros(
      digits.unsafe_substring(start=0, end=1) +
      "." +
      digits.unsafe_substring(start=1, end=p),
    )
    sign + mant + "e" + exponent_text(e)
  } else if e >= 0 {
    sign +
    strip_fraction_zeros(
      digits.unsafe_substring(start=0, end=e + 1) +
      "." +
      digits.unsafe_substring(start=e + 1, end=p),
    )
  } else {
    sign + strip_fraction_zeros("0." + String::make(-e - 1, '0') + digits)
  }
}

///|
/// `%.<p-1>e` (p significant digits, trailing zeros kept).
pub fn format_float_scientific(d : Double, p : Int) -> String {
  let sign = if is_negative(d) { "-" } else { "" }
  let (digits, e) = if d == 0.0 {
    (String::make(p, '0'), 0)
  } else {
    significant_digits(d, p)
  }
  sign +
  digits.unsafe_substring(start=0, end=1) +
  "." +
  digits.unsafe_substring(start=1, end=p) +
  "e" +
  exponent_text(e)
}

///|
/// Parse text as SQL Server converts it to float: ASCII spaces trimmed,
/// `[+|-]digits[.digits][e[+|-]digits]` (either side of the point may be
/// empty, not both); empty text is 0. None if malformed. Infinite results
/// are returned as is (the caller reports overflow).
pub fn parse_float_text(text : String) -> Double? {
  let s = trim_spaces(text)
  let n = s.length()
  if n == 0 {
    return Some(0.0)
  }
  let mut i = 0
  let mut negative = false
  if s[0] == '+' || s[0] == '-' {
    negative = s[0] == '-'
    i = 1
  }
  let int_start = i
  while i < n && is_digit(s[i]) {
    i += 1
  }
  let int_part = s.unsafe_substring(start=int_start, end=i)
  let mut frac_part = ""
  if i < n && s[i] == '.' {
    i += 1
    let f = i
    while i < n && is_digit(s[i]) {
      i += 1
    }
    frac_part = s.unsafe_substring(start=f, end=i)
  }
  if int_part.length() + frac_part.length() == 0 {
    return None
  }
  let mut exp_part = ""
  if i < n && (s[i] == 'e' || s[i] == 'E') {
    i += 1
    let e = i
    if i < n && (s[i] == '+' || s[i] == '-') {
      i += 1
    }
    let digits_start = i
    while i < n && is_digit(s[i]) {
      i += 1
    }
    if i == digits_start {
      return None
    }
    exp_part = "e" + s.unsafe_substring(start=e, end=i)
  }
  if i != n {
    return None
  }
  let canonical = (if int_part == "" { "0" } else { int_part }) +
    "." +
    (if frac_part == "" { "0" } else { frac_part }) +
    exp_part
  let v = @string.parse_double(canonical) catch { _ => return None }
  Some(if negative { -v } else { v })
}
