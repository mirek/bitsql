///|
/// Integer literal: int when it fits, otherwise numeric(digits, 0)
/// (captured: 2147483648 is numeric(10,0)).
fn int_literal(text : String) -> @ir.Expr raise @types.SqlError {
  let digits = text.length()
  if digits <= 10 {
    let mut v = 0L
    for c in text {
      v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    if v <= 2147483647L {
      return @ir.Expr::lit(Int(v.to_int()), Int)
    }
  }
  decimal_literal(text)
}

///|
/// Decimal literal: numeric(p, s) with s = fraction digits and p = integral
/// digits (without leading zeros) + s, at least 1 (captured: 1.50 is
/// numeric(3,2)).
fn decimal_literal(text : String) -> @ir.Expr raise @types.SqlError {
  let d = match @types.Decimal::parse(text) {
    Some(d) => d
    None => raise err(102, "Incorrect syntax near '\{text}'.", severity=15)
  }
  let (int_part, frac_part) = match text.find(".") {
    Some(i) =>
      (
        text.unsafe_substring(start=0, end=i),
        text.unsafe_substring(start=i + 1, end=text.length()),
      )
    None => (text, "")
  }
  let mut int_digits = 0
  let mut leading = true
  for c in int_part {
    if leading && c == '0' {
      continue
    }
    leading = false
    int_digits += 1
  }
  let s = frac_part.length()
  let p = @cmp.maximum(1, int_digits + s)
  // captured: a literal with a decimal point and more than 38 digits is
  // 1007 (msduck percentile-numeric-rounding-v2 #016, #042-#044:
  // 1.00000000000000011102230246251565404236 fails, 38 digits pass)
  if p > 38 && text.contains(".") {
    raise err(
      1007,
      "The number '\{text}' is out of the range for numeric representation (maximum precision 38).",
      severity=15,
    )
  }
  if p > 38 {
    // SQL Server reads such literals as float
    match @types.parse_float_text(text) {
      Some(f) => return @ir.Expr::lit(Float(f), Float)
      None =>
        raise err(
          1007,
          "The number '\{text}' is out of the range for numeric representation (maximum precision 38).",
          severity=15,
        )
    }
  }
  @ir.Expr::lit(Decimal(d), Numeric(p, s))
}

///|
/// A float literal's value and range class: 0 in range, 1 too small (a
/// nonzero literal below the smallest normal double reads as 0, with
/// warning 337 at parse time), 2 too large (error 168). Captured: msduck
/// percentile-numeric-rounding-v2 (1e-308 and 5e-324 are 0 with 337,
/// 0e309 is 0, 1e309 is 168). None when the text is not a float literal.
pub fn float_literal_class(text : String) -> (Double, Int)? {
  let mut mantissa_zero = true
  let mut exp_negative = false
  let mut in_exp = false
  for c in text {
    match c {
      'e' | 'E' => in_exp = true
      '-' => if in_exp { exp_negative = true }
      '1'..='9' => if !in_exp { mantissa_zero = false }
      _ => ()
    }
  }
  if mantissa_zero {
    return Some((0.0, 0))
  }
  match @types.parse_float_text(text) {
    Some(f) if f.is_inf() => Some((0.0, 2))
    Some(f) if f.abs() < 2.2250738585072014e-308 => Some((0.0, 1))
    Some(f) => Some((f, 0))
    None =>
      if !in_exp {
        None
      } else if exp_negative {
        Some((0.0, 1))
      } else {
        Some((0.0, 2))
      }
  }
}

///|
fn float_literal(text : String) -> @ir.Expr raise @types.SqlError {
  match float_literal_class(text) {
    Some((_, 2)) => raise float_range_error(text)
    Some((f, _)) => @ir.Expr::lit(Float(f), Float)
    None => raise err(102, "Incorrect syntax near '\{text}'.", severity=15)
  }
}

///|
/// 168: a float literal beyond the double range.
pub fn float_range_error(text : String) -> @types.SqlError {
  err(
    168,
    "The floating point value '\{text}' is out of the range of computer representation (8 bytes).",
    severity=15,
  )
}

///|
fn money_literal(text : String) -> @ir.Expr raise @types.SqlError {
  let body = text.unsafe_substring(start=1, end=text.length())
  match @types.Decimal::parse(body) {
    Some(d) => {
      let scaled = d.rescale(4)
      let v = scaled.coef().to_int64()
      @ir.Expr::lit(Money(v), Money)
    }
    None => raise err(102, "Incorrect syntax near '\{text}'.", severity=15)
  }
}

///|
fn hex_value(c : Char) -> Int {
  match c {
    '0'..='9' => c.to_int() - '0'.to_int()
    'a'..='f' => c.to_int() - 'a'.to_int() + 10
    'A'..='F' => c.to_int() - 'A'.to_int() + 10
    _ => 0
  }
}

///|
fn binary_literal(text : String, params? : Bool = false) -> @ir.Expr {
  let hex = text.unsafe_substring(start=2, end=text.length())
  let odd = hex.length() % 2
  let n = (hex.length() + odd) / 2
  let digits = hex.to_array()
  let bytes = Bytes::makei(n, i => {
    let hi_idx = i * 2 - odd
    let hi = if hi_idx < 0 { 0 } else { hex_value(digits[hi_idx]) }
    let lo = hex_value(digits[hi_idx + 1])
    ((hi << 4) | lo).to_byte()
  })
  let n = if params && n <= 8000 { 8000 } else { n }
  // longer than 8000 bytes is varbinary(max) (captured: compat/long-literal-unify)
  let len = if n > 8000 { None } else { Some(@cmp.maximum(1, n)) }
  @ir.Expr::lit(Binary(bytes), VarBinary(len))
}

///|
fn string_literal(env : Env, s : String, national : Bool) -> @ir.Expr {
  // An empty literal still has length 1 in metadata (varchar(1)); a varchar
  // literal under a UTF-8 database collation counts UTF-8 bytes.
  let n = @cmp.maximum(
    1,
    if !national && env.collation.utf8() {
      @types.utf8_length(s)
    } else {
      s.length()
    },
  )
  let n = match (env.literal_params, national) {
    (true, true) if n <= 4000 => 4000
    (true, false) if n <= 8000 => 8000
    _ => n
  }
  // A literal longer than 4000 Unicode / 8000 byte characters is (n)varchar(max)
  // (captured: compat/long-literal-unify); a sized type would cap it to 4000
  // when VALUES / UNION / CASE unify it with a short literal.
  let len = if n > (if national { 4000 } else { 8000 }) {
    None
  } else {
    Some(n)
  }
  if national {
    @ir.Expr::lit(String(s), NVarChar(len, env.collation))
  } else {
    // Characters outside code page 1252 take SQL Server's best fit or '?'
    // (captured: 'Āłx🦆' is 0x416C783F3F).
    let v = @types.to_code_page(s, env.collation)
    @ir.Expr::lit(String(v), VarChar(len, env.collation))
  }
}
