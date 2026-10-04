// PARSE / TRY_PARSE (bound in bind/fn_parse.mbt). SQL Server runs these
// through .NET: numbers with NumberStyles.Number (integer and decimal
// targets), Float (float/real) or Currency (money/smallmoney), dates with
// DateTime.Parse, in the culture of the USING argument or of the session
// language (culture.mbt). Numbers follow .NET's ParseNumber state machine
// with the culture's signs, separators and currency symbol; dates accept a
// captured subset and raise an emulator error for any other shape.
// Captures: harness/corpus/analytic/parse-*.sql, msduck-runs/parse-try-parse.

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
/// .NET MatchChars: `pat` at position `i` of `s` (a no-break space in the
/// pattern also matches a plain space, captured: '1 234,5' parses in
/// fr-FR, U+202F does not); the position after it, or None.
fn match_chars(s : String, i : Int, pat : String) -> Int? {
  if pat.length() == 0 || i + pat.length() > s.length() {
    return None
  }
  for k in 0..<pat.length() {
    let a = s.code_unit_at(i + k).to_int()
    let p = pat.code_unit_at(k).to_int()
    if a != p && !(p == 0xA0 && a == 0x20) {
      return None
    }
  }
  Some(i + pat.length())
}

///|
/// .NET Number.ParseNumber over culture `c` (signs, separators, currency
/// symbol; the currency style also accepts the number separators before
/// the symbol). Leading/trailing white space and the decimal point are
/// always allowed (all PARSE styles).
fn net_parse_number(s : String, st : NumStyle, c : CultureData) -> NetNumber? {
  let n = s.length()
  let at = (i : Int) => if i < n { s.code_unit_at(i).to_int() } else { 0 }
  let (dec_sep, group_sep) = if st.currency {
    (c.c_dec, c.c_group)
  } else {
    (c.n_dec, c.n_group)
  }
  let mut currency_sym : String? = if st.currency {
    Some(c.c_symbol)
  } else {
    None
  }
  let white_after_sign = c.n_neg == "- #"
  let mut i = 0
  let mut sign = false
  let mut parens = false
  let mut currency = false
  let mut negative = false
  // leading: white space (not after a sign unless a currency symbol was
  // seen), sign, '(' (currency style), currency symbol
  while i < n {
    let ch = at(i)
    if net_white(ch) && (!sign || currency || white_after_sign) {
      i += 1
      continue
    }
    if !sign && match_chars(s, i, "+") is Some(j) {
      sign = true
      i = j
      continue
    }
    if !sign && match_chars(s, i, c.neg_sign) is Some(j) {
      sign = true
      negative = true
      i = j
      continue
    }
    if st.currency && !sign && ch == 0x28 {
      sign = true
      parens = true
      negative = true
      i += 1
      continue
    }
    match currency_sym {
      Some(sym) =>
        match match_chars(s, i, sym) {
          Some(j) => {
            currency = true
            currency_sym = None
            i = j
            continue
          }
          None => ()
        }
      None => ()
    }
    break
  }
  let digits = StringBuilder()
  let mut has_digits = false
  let mut nonzero = false
  let mut decimal = false
  let mut scale = 0 // digits before the point (after leading zeros)
  while i < n {
    let ch = at(i)
    if net_digit(ch) {
      has_digits = true
      if ch != 0x30 || nonzero {
        nonzero = true
        digits.write_char(ch.unsafe_to_char())
        if !decimal {
          scale += 1
        }
      } else if decimal {
        scale -= 1
      }
      i += 1
      continue
    }
    if !decimal {
      let m = match match_chars(s, i, dec_sep) {
        Some(j) => Some(j)
        None =>
          if st.currency && !currency {
            match_chars(s, i, c.n_dec)
          } else {
            None
          }
      }
      if m is Some(j) {
        decimal = true
        i = j
        continue
      }
    }
    if st.thousands && has_digits && !decimal {
      let m = match match_chars(s, i, group_sep) {
        Some(j) => Some(j)
        None =>
          if st.currency && !currency {
            match_chars(s, i, c.n_group)
          } else {
            None
          }
      }
      if m is Some(j) {
        i = j
        continue
      }
    }
    break
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
    } else if match_chars(s, i, c.neg_sign) is Some(j) {
      i = j
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
    let ch = at(i)
    if net_white(ch) {
      i += 1
      continue
    }
    if st.trailing_sign && !sign {
      if match_chars(s, i, "+") is Some(j) {
        sign = true
        i = j
        continue
      }
      if match_chars(s, i, c.neg_sign) is Some(j) {
        sign = true
        negative = true
        i = j
        continue
      }
    }
    if ch == 0x29 && parens {
      parens = false
      i += 1
      continue
    }
    match currency_sym {
      Some(sym) =>
        match match_chars(s, i, sym) {
          Some(j) => {
            currency = true
            currency_sym = None
            i = j
            continue
          }
          None => ()
        }
      None => ()
    }
    break
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
/// The culture of the USING argument (9818 for a malformed name or NULL),
/// or the session language's culture; and the name as 9819 prints it
/// ('' without USING).
fn parse_culture(
  ctx : Ctx,
  v : Array[@types.Value],
) -> (CultureData, String) raise @types.SqlError {
  if v.length() < 4 {
    return (session_culture(ctx, "PARSE", number=@types.EMU_PARSE_CULTURE), "")
  }
  let c = match v[3] {
    String(s) => s
    Null => raise culture_not_supported("NULL")
    _ => ""
  }
  (resolve_culture(c, "PARSE", number=@types.EMU_PARSE_CULTURE), c)
}

///|
fn parse_call(
  ctx : Ctx,
  v : Array[@types.Value],
  _args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  let try_ = v[1] is Int(1)
  let type_name = match v[2] {
    String(s) => s
    _ => ""
  }
  let (culture, culture_text) = parse_culture(ctx, v)
  let text = match v[0] {
    Null => return Null
    String(s) => s
    _ => ""
  }
  let fail = () => parse_failed(try_, text, type_name, culture_text)
  let t = e.ty
  match t {
    TinyInt | SmallInt | Int | BigInt => {
      let style = {
        thousands: true,
        trailing_sign: true,
        exponent: false,
        currency: false,
      }
      guard net_parse_number(text, style, culture) is Some(x) else {
        return fail()
      }
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
      guard net_parse_number(text, style, culture) is Some(x) else {
        return fail()
      }
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
      guard net_parse_number(text, style, culture) is Some(x) else {
        return fail()
      }
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
      guard net_parse_number(text, style, culture) is Some(x) else {
        return fail()
      }
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
      match parse_net_datetime(text, t, culture) {
        ParsedOk(ticks, offset) =>
          match parse_temporal_result(ticks, offset, t) {
            Some(r) => r
            // captured: a smalldatetime out of range is a CLR cast
            // exception, also under TRY_PARSE
            None if t is SmallDateTime => raise smalldate_cast_error()
            None => fail()
          }
        ParsedInvalid => fail()
        // captured: msduck parse-try-parse#063 (ISO 8601 text, datetime2)
        ParsedOverflow if t is DateTime2(_) && text.contains("T") =>
          raise @types.sql_error(
            6521,
            "A .NET Framework error occurred during statement execution: \r\nSystem.ArgumentOutOfRangeException: The added or subtracted value results in an un-representable DateTime.\r\nParameter name: value\r\nSystem.ArgumentOutOfRangeException: \r\n   at System.DateTime.AddTicks(Int64 value)\r\n   at System.DateTimeParse.ParseISO8601(DateTimeRawInfo& raw, __DTString& str, DateTimeStyles styles, DateTimeResult& result)\r\n   at System.DateTimeParse.TryParse(String s, DateTimeFormatInfo dtfi, DateTimeStyles styles, DateTimeResult& result)\r\n   at System.DateTimeParse.Parse(String s, DateTimeFormatInfo dtfi, DateTimeStyles styles)\r\n   at System.Data.SqlServer.Internal.SqlParseIntrinsicImpl.<>c__DisplayClass14_0.<ParseDateTime2>b__0(CXVariantBase* pxvar, String strParse, CultureInfo ci)\r\n.",
            state=2,
          )
        ParsedOverflow =>
          raise @types.not_supported(
            "PARSE of '\{text}' as \{t.to_sql()} (fraction rounding past the maximum date)",
            number=@types.EMU_PARSE_FORMAT,
          )
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
