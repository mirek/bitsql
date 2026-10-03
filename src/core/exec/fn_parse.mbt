// PARSE / TRY_PARSE (bound in bind/fn_parse.mbt). SQL Server runs these
// through .NET: numbers with NumberStyles.Number (integer and decimal
// targets), Float (float/real) or Currency (money/smallmoney), dates with
// DateTime.Parse. Numbers follow .NET's TryParseNumber state machine for
// the en-US and invariant cultures; dates accept a captured subset and raise
// an emulator error for any other shape. Captures:
// harness/corpus/analytic/parse-*.sql.

///|
priv enum ParseCulture {
  EnUs
  Invariant
}

///|
/// .NET number styles used by PARSE.
priv struct NumStyle {
  thousands : Bool
  trailing_sign : Bool
  exponent : Bool
  currency : Bool
}

///|
/// A parsed .NET number: sign, significant digits, decimal exponent
/// (value = digits * 10^exp).
priv struct NetNumber {
  negative : Bool
  digits : String
  exp : Int
}

///|
fn net_white(c : Int) -> Bool {
  c == 0x20 || (c >= 0x09 && c <= 0x0D)
}

///|
fn net_digit(c : Int) -> Bool {
  c >= 0x30 && c <= 0x39
}

///|
/// .NET Number.TryParseNumber for cultures whose signs are `+`/`-`,
/// decimal separator `.` and group separator `,`. Leading/trailing white
/// space and the decimal point are always allowed (all PARSE styles).
fn net_parse_number(s : String, st : NumStyle, sym : Int) -> NetNumber? {
  let n = s.length()
  let at = (i : Int) => if i < n { s.code_unit_at(i).to_int() } else { 0 }
  let mut i = 0
  let mut sign = false
  let mut parens = false
  let mut currency = false
  let mut negative = false
  // leading: white space (not after a sign unless a currency symbol was
  // seen), sign, '(' (currency style), currency symbol
  while i < n {
    let c = at(i)
    if net_white(c) && (!sign || currency) {
      i += 1
      continue
    }
    if !sign && (c == 0x2B || c == 0x2D) {
      sign = true
      negative = c == 0x2D
    } else if st.currency && !sign && c == 0x28 {
      sign = true
      parens = true
      negative = true
    } else if st.currency && !currency && c == sym {
      currency = true
    } else {
      break
    }
    i += 1
  }
  let digits = StringBuilder()
  let mut has_digits = false
  let mut nonzero = false
  let mut decimal = false
  let mut scale = 0 // digits before the point (after leading zeros)
  while i < n {
    let c = at(i)
    if net_digit(c) {
      has_digits = true
      if c != 0x30 || nonzero {
        nonzero = true
        digits.write_char(c.unsafe_to_char())
        if !decimal {
          scale += 1
        }
      } else if decimal {
        scale -= 1
      }
    } else if !decimal && c == 0x2E {
      decimal = true
    } else if st.thousands && has_digits && !decimal && c == 0x2C {
      ()
    } else {
      break
    }
    i += 1
  }
  if !has_digits {
    return None
  }
  let mut exp = 0
  if st.exponent && (at(i) == 0x65 || at(i) == 0x45) {
    let save = i
    i += 1
    let mut neg_exp = false
    if at(i) == 0x2B {
      i += 1
    } else if at(i) == 0x2D {
      i += 1
      neg_exp = true
    }
    if net_digit(at(i)) && i < n {
      let mut e = 0
      while i < n && net_digit(at(i)) {
        if e <= 1000 {
          e = e * 10 + (at(i) - 0x30)
        } else {
          e = 9999
        }
        i += 1
      }
      exp = if neg_exp { -e } else { e }
    } else {
      i = save
    }
  }
  // trailing: white space, sign, ')', currency symbol
  while i < n {
    let c = at(i)
    if net_white(c) {
      i += 1
      continue
    }
    if st.trailing_sign && !sign && (c == 0x2B || c == 0x2D) {
      sign = true
      negative = c == 0x2D
    } else if c == 0x29 && parens {
      parens = false
    } else if st.currency && !currency && c == sym {
      currency = true
    } else {
      break
    }
    i += 1
  }
  if i != n || parens {
    return None
  }
  let d = digits.to_string()
  // strip trailing zeros of the significant digits
  let mut end = d.length()
  while end > 0 && d.code_unit_at(end - 1) == '0' {
    end -= 1
  }
  let sig = d.unsafe_substring(start=0, end~)
  Some({
    negative: negative && sig.length() > 0,
    digits: sig,
    exp: scale + exp - sig.length(),
  })
}

///|
/// Exact decimal value of a parsed number, or None when its exponent is
/// absurd (more than 80 digits either way).
fn net_decimal(x : NetNumber) -> @types.Decimal? {
  if x.digits == "" {
    return Some(@types.Decimal::zero())
  }
  if x.exp > 80 || x.exp < -80 {
    return None
  }
  let coef = @bigint.BigInt::from_string(x.digits)
  let d = if x.exp >= 0 {
    @types.Decimal::new(coef, 0).rescale(x.exp).coef()
  } else {
    coef
  }
  let scale = if x.exp >= 0 { 0 } else { -x.exp }
  let v = @types.Decimal::new(d, scale)
  Some(if x.negative { v.neg() } else { v })
}

///|
fn parse_failed(
  try_ : Bool,
  text : String,
  type_name : String,
  culture : String,
) -> @types.Value raise @types.SqlError {
  if try_ {
    Null
  } else {
    raise @types.sql_error(
      9819,
      "Error converting string value '\{text}' into data type \{type_name} using culture '\{culture}'.",
    )
  }
}

///|
fn parse_culture(
  v : Array[@types.Value],
) -> (ParseCulture, String) raise @types.SqlError {
  if v.length() < 4 {
    return (EnUs, "")
  }
  let c = match v[3] {
    String(s) => s
    Null =>
      raise @types.sql_error(
        9818, "The culture parameter 'NULL' provided in the function call is not supported.",
      )
    _ => ""
  }
  match c.to_lower() {
    "en-us" | "en" | "en_us" => (EnUs, c)
    "iv" => (Invariant, c)
    "" | "invariant" =>
      raise @types.sql_error(
        9818,
        "The culture parameter '\{c}' provided in the function call is not supported.",
      )
    _ =>
      raise @types.not_supported(
        "PARSE culture '\{c}'",
        number=@types.EMU_PARSE_CULTURE,
      )
  }
}

///|
fn parse_call(
  v : Array[@types.Value],
  _args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  let try_ = v[1] is Int(1)
  let type_name = match v[2] {
    String(s) => s
    _ => ""
  }
  let (culture, culture_text) = parse_culture(v)
  let text = match v[0] {
    Null => return Null
    String(s) => s
    _ => ""
  }
  let fail = () => parse_failed(try_, text, type_name, culture_text)
  let t = e.ty
  let sym = match culture {
    EnUs => 0x24 // $
    Invariant => 0xA4 // ¤
  }
  match t {
    TinyInt | SmallInt | Int | BigInt => {
      let style = {
        thousands: true,
        trailing_sign: true,
        exponent: false,
        currency: false,
      }
      guard net_parse_number(text, style, sym) is Some(x) else { return fail() }
      // a fraction must be all zeros (they were stripped)
      if x.exp < 0 || x.digits.length() + x.exp > 19 {
        return fail()
      }
      guard net_decimal(x) is Some(d) else { return fail() }
      let (lo, hi) = @types.int_range(t)
      let big = d.trunc_to_bigint()
      if big < @bigint.BigInt::from_int64(lo) ||
        big > @bigint.BigInt::from_int64(hi) {
        return fail()
      }
      @types.int_value(t, big.to_int64())
    }
    Numeric(p, s) => {
      let style = {
        thousands: true,
        trailing_sign: true,
        exponent: false,
        currency: false,
      }
      guard net_parse_number(text, style, sym) is Some(x) else { return fail() }
      guard net_decimal(x) is Some(d) else { return fail() }
      let r = d.rescale(s)
      if r.digits() > p {
        return fail()
      }
      Decimal(r)
    }
    Money | SmallMoney => {
      let style = {
        thousands: true,
        trailing_sign: true,
        exponent: false,
        currency: true,
      }
      guard net_parse_number(text, style, sym) is Some(x) else { return fail() }
      guard net_decimal(x) is Some(d) else { return fail() }
      let r = d.rescale(4)
      let limit = if t is Money {
        @bigint.BigInt::from_string("9223372036854775807")
      } else {
        @bigint.BigInt::from_int(2147483647)
      }
      let c = r.coef()
      if c > limit || c < -limit - @bigint.BigInt::from_int(1) {
        return fail()
      }
      Money(c.to_int64())
    }
    Float | Real => {
      let style = {
        thousands: false,
        trailing_sign: false,
        exponent: true,
        currency: false,
      }
      guard net_parse_number(text, style, sym) is Some(x) else { return fail() }
      let canonical = (if x.negative { "-" } else { "" }) +
        (if x.digits == "" { "0" } else { x.digits }) +
        "e" +
        x.exp.to_string()
      guard @types.parse_float_text(canonical) is Some(f) else { return fail() }
      if t is Real {
        let r = Float::from_double(f).to_double()
        if r.is_inf() || r.is_nan() {
          return fail()
        }
        Float(r)
      } else {
        if f.is_inf() || f.is_nan() {
          return fail()
        }
        Float(f)
      }
    }
    _ =>
      match parse_net_datetime(text, t) {
        ParsedOk(ticks, offset) =>
          match parse_temporal_result(ticks, offset, t) {
            Some(r) => r
            // captured: a smalldatetime out of range is a CLR cast
            // exception, also under TRY_PARSE
            None if t is SmallDateTime => raise smalldate_cast_error()
            None => fail()
          }
        ParsedInvalid => fail()
        ParsedUnsupported(why) =>
          raise @types.not_supported(
            "PARSE of '\{text}' as \{t.to_sql()} (\{why})",
            number=@types.EMU_PARSE_FORMAT,
          )
      }
  }
}

///|
/// The parsed local date/time (100 ns ticks since 0001-01-01, rounded to 7
/// digits) to the target type. None when out of the type's range.
fn parse_temporal_result(
  ticks : Int64,
  offset : Int?,
  t : @types.SqlType,
) -> @types.Value? {
  match t {
    DateTimeOffset(_) => {
      let off = offset.unwrap_or(0)
      let utc = ticks - off.to_int64() * @types.TICKS_PER_MINUTE
      if utc < 0L || utc > MAX_TICKS {
        return None
      }
      let v : @types.Value = DateTimeOffset(utc, off)
      try @types.cast(v, DateTimeOffset(7), t) catch {
        _ => None
      } noraise {
        r => Some(r)
      }
    }
    _ =>
      try @types.cast(DateTime2(ticks), DateTime2(7), t) catch {
        _ => None
      } noraise {
        r => Some(r)
      }
  }
}

///|
fn smalldate_cast_error() -> @types.SqlError {
  @types.sql_error(
    6521,
    "A .NET Framework error occurred during statement execution: \r\nSystem.InvalidCastException: Specified cast is not valid.\r\nSystem.InvalidCastException: \r\n   at System.Data.SqlServer.Internal.CXVariantBase.SqlDateTimeToSmallDate(SqlDateTime sdt)\r\n   at System.Data.SqlServer.Internal.SqlParseIntrinsicImpl.<>c.<ParseSmalldate>b__10_0(CXVariantBase* pxvar, String strParse, CultureInfo ci)\r\n.",
    state=2,
  )
}
