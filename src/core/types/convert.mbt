// CAST / CONVERT / TRY_CAST / TRY_CONVERT between the v1 types.
//
// `cast(value, from, to, style?)`: `from` is the binder-computed source type,
// `to` the target; `style` is CONVERT's third argument (None for CAST, which
// for most types equals style 0 but not for datetime2-family → text).
//
// Error texts/states marked "captured" come from msduck reference/*.json
// (SQL Server 2025 RTM-CU7); the rest follow SQL Server's message catalog
// and are listed as unverified in .claude/skills/t-sql/SKILL.md findings.

///|
/// CAST / CONVERT. `dates` are the session's DATEFORMAT and LANGUAGE
/// (string ↔ date/time conversions).
pub fn cast(
  v : Value,
  from : SqlType,
  to : SqlType,
  style? : Int,
  dates? : DateSettings = default_date_settings,
) -> Value raise SqlError {
  if !can_convert_explicitly(from, to) {
    raise explicit_conversion_error(from, to)
  }
  if from is Variant || to is Variant {
    return cast_variant(v, from, to, style, dates)
  }
  if from is Xml || to is Xml {
    return cast_xml(v, from, to, style)
  }
  if from is Vector(_, _) || to is Vector(_, _) {
    return match (v, to) {
      (Null, _) => Null
      (String(s), Vector(n, base)) => Vector(vector_parse(s, n, base~))
      (Vector(data), Vector(n, base)) => {
        if data.base() != base {
          raise vector_base_conversion_error(data.base(), base)
        }
        if data.dimensions() != n {
          raise sql_error(
            42204,
            "The vector dimensions \{data.dimensions()} and \{n} do not match.",
            state=1,
          )
        }
        v
      }
      (Vector(data), _) => {
        let text = data.to_text()
        let length = match to {
          Char(n, _)
          | NChar(n, _)
          | VarChar(Some(n), _)
          | NVarChar(Some(n), _) => n
          _ => text.length()
        }
        if text.length() > length {
          raise sql_error(
            42211, "Truncation of vector is not allowed during the conversion. Ensure the vector size is appropriate before conversion.",
          )
        }
        cast(String(text), NVarChar(None, default_collation), to)
      }
      _ => raise internal("vector conversion")
    }
  }
  if from is Json || to is Json {
    return match (v, to) {
      (Null, _) => Null
      (String(s), Json) =>
        if from is Json {
          v
        } else {
          String(json_type_normalize(s))
        }
      (String(s), _) => String(json_type_to_text(s, to))
      _ => raise internal("json conversion of \{from.to_sql()}")
    }
  }
  if v is Null {
    return Null
  }
  // SQL Server reads binary as an internal date/time image whose layout
  // is not the storage bytes (0x5B950A AS date is 1900-01-01, captured)
  if from.family() is FBinary &&
    (
      to.family() is (FDate | FTime) ||
      (to.family() is FDateTime && !is_legacy_datetime(to))
    ) {
    raise not_supported("conversion of binary to \{to.clash_name()}")
  }
  match to.family() {
    FBit => to_bit(v, from)
    FInteger => to_integer(v, from, to)
    FDecimal => to_decimal(v, from, to)
    FMoney => to_money(v, from, to)
    FFloat => to_float(v, from, to)
    // captured: CONVERT(varchar, rowversion, 1) copies the raw bytes like
    // style 0 (msduck gaps-rowversion_identity #071)
    FString =>
      to_character(
        v,
        from,
        to,
        if from is RowVersion {
          None
        } else {
          style
        },
        dates,
      )
    FBinary => to_binary(v, from, to, style)
    FDate | FTime | FDateTime => to_temporal(v, from, to, style, dates)
    FGuid => to_guid(v, from)
    FVariant => raise internal("variant target")
    FXml => raise internal("xml target")
    FVector => raise internal("vector target")
    FJson => raise internal("json target")
  }
}

///|
/// TRY_CAST / TRY_CONVERT: value-dependent conversion failures give NULL;
/// disallowed conversions (529), source truncation (8152) and emulator
/// errors still raise.
pub fn try_cast(
  v : Value,
  from : SqlType,
  to : SqlType,
  style? : Int,
  dates? : DateSettings = default_date_settings,
) -> Value raise SqlError {
  cast(v, from, to, style?, dates~) catch {
    SqlError(_) as e if e.is_try_convertible() => Null
    e => raise e
  }
}

///|
fn internal(detail : String) -> SqlError {
  emulator_error(EMU_INTERNAL, detail)
}

///|
fn conversion_unsupported(from : SqlType, to : SqlType) -> SqlError {
  not_supported(
    "conversion from \{from.to_sql()} to \{to.to_sql()}",
    number=EMU_CONVERSION_NOT_SUPPORTED,
  )
}

///|
/// Inclusive range of an integer type.
pub fn int_range(t : SqlType) -> (Int64, Int64) {
  match t {
    TinyInt => (0L, 255L)
    SmallInt => (-32768L, 32767L)
    Int => (-2147483648L, 2147483647L)
    _ => (-9223372036854775808L, 9223372036854775807L)
  }
}

///|
/// Wrap an in-range integer as a value of integer type `t`.
pub fn int_value(t : SqlType, n : Int64) -> Value {
  match t {
    TinyInt => TinyInt(n.to_int())
    SmallInt => SmallInt(n.to_int())
    Int => Int(n.to_int())
    Bit => Bit(n != 0L)
    _ => BigInt(n)
  }
}

///|
/// Integer content of an integer-family or bit value.
pub fn Value::as_int64(self : Value) -> Int64? {
  match self {
    Bit(b) => Some(if b { 1L } else { 0L })
    TinyInt(n) | SmallInt(n) | Int(n) => Some(n.to_int64())
    BigInt(n) => Some(n)
    _ => None
  }
}

///|
/// `as_int64` for values known to be bit/integers, without the boxed
/// `Int64?` (an allocation per call on the native backend): `default` for
/// any other value.
pub fn Value::int64_or(self : Value, default : Int64) -> Int64 {
  match self {
    Bit(b) => if b { 1L } else { 0L }
    TinyInt(n) | SmallInt(n) | Int(n) => n.to_int64()
    BigInt(n) => n
    _ => default
  }
}

///|
/// Exact numeric content as a decimal (bit, integers, decimal, money).
pub fn Value::as_decimal(self : Value) -> Decimal? {
  match self {
    Decimal(d) => Some(d)
    Money(units) => Some(Decimal::new(@bigint.BigInt::from_int64(units), 4))
    _ =>
      match self.as_int64() {
        Some(n) => Some(Decimal::from_int64(n))
        None => None
      }
  }
}

///|
/// The decimal a float converts to: its exact binary value rounded to 17
/// significant digits, like SQL Server's float printing (see
/// float_text.mbt). Whether CAST(float AS decimal) uses 17 digits or the
/// exact binary value is unverified.
pub fn double_to_decimal17(d : Double) -> Decimal {
  if d == 0.0 {
    return Decimal::zero()
  }
  let (digits, e) = significant_digits(d, 17)
  let coef = @bigint.BigInt::from_string(digits)
  let signed = if d < 0.0 { -coef } else { coef }
  // value = digits * 10^(e - 16)
  if e - 16 >= 0 {
    Decimal::new(signed * pow10(e - 16), 0)
  } else {
    Decimal::new(signed, 16 - e)
  }
}

///|
/// Numeric value as a double (bit, integers, decimal, money, float).
fn as_double(v : Value) -> Double? {
  match v {
    Float(d) => Some(d)
    _ =>
      match v.as_decimal() {
        Some(d) => Some(d.to_double())
        None => None
      }
  }
}

///|
fn source_name(t : SqlType) -> String {
  t.message_name()
}

// ---------------------------------------------------------------- bit

///|
fn to_bit(v : Value, from : SqlType) -> Value raise SqlError {
  match v {
    String(s) => {
      check_source_length(s, from)
      let t = trim_spaces(s).to_upper()
      if t == "TRUE" {
        return Bit(true)
      }
      if t == "FALSE" {
        return Bit(false)
      }
      match parse_int_text(s) {
        Some(n) => Bit(!n.is_zero())
        None => raise conversion_failed(from, s, Bit)
      }
    }
    Float(d) => Bit(d != 0.0)
    Binary(b) => Bit(b.iter().any(fn(x) { x != b'\x00' }))
    DateTime(_, _) | SmallDateTime(_, _) =>
      raise conversion_unsupported(from, Bit)
    _ =>
      match v.as_decimal() {
        Some(d) => Bit(!d.is_zero())
        None => raise internal("bad bit source \{from.to_sql()}")
      }
  }
}

// ------------------------------------------------------------- integers

///|
/// 245: Conversion failed when converting the varchar value '…' to data
/// type int. (captured; state 1)
fn conversion_failed(from : SqlType, text : String, to : SqlType) -> SqlError {
  sql_error(
    245,
    "Conversion failed when converting the \{source_name(from)} value '\{text}' to data type \{to.message_name()}.",
  )
}

///|
/// 8114: Error converting data type varchar to numeric. (captured; state 5)
fn error_converting(from : SqlType, to : SqlType, state? : Int = 5) -> SqlError {
  sql_error(
    8114,
    "Error converting data type \{source_name(from)} to \{to.message_name()}.",
    state~,
  )
}

///|
/// 8115 "Arithmetic overflow error converting expression to data type X."
/// (captured with state 2 for arithmetic and string → bigint).
pub fn overflow_expression(to : SqlType, state? : Int = 2) -> SqlError {
  sql_error(
    8115,
    "Arithmetic overflow error converting expression to data type \{to.message_name()}.",
    state~,
  )
}

///|
/// 8115 "Arithmetic overflow error converting <source> to data type X."
fn overflow_from(from : SqlType, to : SqlType, state? : Int = 1) -> SqlError {
  sql_error(
    8115,
    "Arithmetic overflow error converting \{source_name(from)} to data type \{to.message_name()}.",
    state~,
  )
}

///|
/// 8152 for character sources longer than SQL Server's conversion buffer
/// (captured: a 4001-unit nvarchar(max) → int fails with 8152 state 10,
/// even under TRY_CAST; 4000 units convert).
fn check_source_length(s : String, from : SqlType) -> Unit raise SqlError {
  let limit = if from.is_unicode() { 4000 } else { 8000 }
  if s.length() > limit {
    raise sql_error(8152, "String or binary data would be truncated.", state=10)
  }
}

///|
/// Integer text as SQL Server reads it: ASCII spaces trimmed; optional
/// sign, optionally followed by spaces; ASCII digits. Empty text and a
/// lone sign are 0. Tabs, NBSP, NUL, fractions, exponents and fullwidth
/// digits are invalid (captured: msduck reference/unicode-integer.json).
pub fn parse_int_text(text : String) -> @bigint.BigInt? {
  let s = trim_spaces(text)
  let n = s.length()
  let mut i = 0
  let mut negative = false
  if i < n && (s[i] == '+' || s[i] == '-') {
    negative = s[i] == '-'
    i += 1
    while i < n && s[i] == ' ' {
      i += 1
    }
  }
  let start = i
  while i < n && is_digit(s[i]) {
    i += 1
  }
  if i != n {
    return None
  }
  if start == n {
    return Some(@bigint.BigInt::from_int(0))
  }
  let v = @bigint.BigInt::from_string(s.unsafe_substring(start~, end=n))
  Some(if negative { -v } else { v })
}

///|
fn to_integer(v : Value, from : SqlType, to : SqlType) -> Value raise SqlError {
  let (lo, hi) = int_range(to)
  match v {
    String(s) => {
      check_source_length(s, from)
      let parsed = match parse_int_text(s) {
        Some(n) => n
        None =>
          raise if to is BigInt {
            error_converting(from, to)
          } else {
            conversion_failed(from, s, to)
          }
      }
      if parsed.compare_int64(lo) < 0 || parsed.compare_int64(hi) > 0 {
        raise match to {
          TinyInt =>
            sql_error(
              244,
              "The conversion of the \{source_name(from)} value '\{s}' overflowed an INT1 column. Use a larger integer column.",
            )
          SmallInt =>
            sql_error(
              244,
              "The conversion of the \{source_name(from)} value '\{s}' overflowed an INT2 column. Use a larger integer column.",
              state=2,
            )
          Int =>
            sql_error(
              248,
              "The conversion of the \{source_name(from)} value '\{s}' overflowed an int column.",
            )
          _ => overflow_expression(to)
        }
      }
      int_value(to, parsed.to_int64())
    }
    Float(d) => {
      let t = d.trunc()
      if t < lo.to_double() || t > hi.to_double() || t.is_nan() {
        // captured: CAST(1e30 AS INT) → 232 state 3 "... value =
        // 1000000000000000000000000000000.000000." (17 significant digits)
        raise sql_error(
          232,
          "Arithmetic overflow error for type \{to.message_name()}, value = \{double_to_decimal17(d).rescale(6).to_string()}.",
          state=3,
        )
      }
      // exact: |t| < 2^63 here except at the very top, guarded above
      let n = Decimal::from_double_exact(t).trunc_to_bigint()
      if n.compare_int64(lo) < 0 || n.compare_int64(hi) > 0 {
        raise sql_error(
          232,
          "Arithmetic overflow error for type \{to.message_name()}, value = \{double_to_decimal17(d).rescale(6).to_string()}.",
          state=3,
        )
      }
      int_value(to, n.to_int64())
    }
    Decimal(d) => {
      let n = d.trunc_to_bigint()
      if n.compare_int64(lo) < 0 || n.compare_int64(hi) > 0 {
        // captured: 8115 state 2 "converting expression" for every integer
        // target (output/conversion-overflow)
        raise overflow_expression(to)
      }
      int_value(to, n.to_int64())
    }
    Money(_) => {
      // money → integer rounds (msduck docs/integer-conversion.md)
      let m = v.as_decimal().unwrap_or(Decimal::from_int64(0L))
      let n = m.rescale(0).coef()
      if n.compare_int64(lo) < 0 || n.compare_int64(hi) > 0 {
        // captured (output/conversion-overflow): int 237/1, smallint 237/2,
        // tinyint 232/11 with the value
        raise match to {
          TinyInt =>
            sql_error(
              232,
              "Arithmetic overflow error for type tinyint, value = \{m.rescale(6).to_string()}.",
              state=11,
            )
          _ =>
            sql_error(
              237,
              "There is insufficient result space to convert a money value to \{to.message_name()}.",
              state=if to is SmallInt { 2 } else { 1 },
            )
        }
      }
      int_value(to, n.to_int64())
    }
    DateTime(days, units) => {
      // rounds to the nearest day (noon rounds up); unverified
      let d = days + (if units >= DATETIME_UNITS_PER_DAY / 2 { 1 } else { 0 })
      let n = d.to_int64()
      if n < lo || n > hi {
        raise overflow_expression(to, state=1)
      }
      int_value(to, n)
    }
    SmallDateTime(days, minutes) => {
      let n = (days + (if minutes >= 720 { 1 } else { 0 })).to_int64()
      if n < lo || n > hi {
        raise overflow_expression(to, state=1)
      }
      int_value(to, n)
    }
    Binary(b) => {
      // rightmost bytes, big-endian, two's complement in the target width
      let width = match to {
        TinyInt => 1
        SmallInt => 2
        Int => 4
        _ => 8
      }
      let mut acc = 0UL
      let start = if b.length() > width { b.length() - width } else { 0 }
      for i in start..<b.length() {
        acc = (acc << 8) | b[i].to_uint64()
      }
      let n = match width {
        1 => acc.reinterpret_as_int64()
        2 =>
          acc.reinterpret_as_int64() -
          (if acc >= 0x8000UL { 0x10000L } else { 0L })
        4 =>
          acc.reinterpret_as_int64() -
          (if acc >= 0x80000000UL { 0x100000000L } else { 0L })
        _ => acc.reinterpret_as_int64()
      }
      int_value(to, n)
    }
    _ =>
      match v.as_int64() {
        Some(n) => {
          if n < lo || n > hi {
            // captured (output/conversion-overflow): bigint sources give
            // 8115/2; → smallint 220/1, → tinyint 220/2 from any integer
            // (also int: dml/compound-assignment, CAST(256 AS tinyint))
            raise match (from, to) {
              (BigInt, _) => overflow_expression(to)
              (_, TinyInt | SmallInt) =>
                sql_error(
                  220,
                  "Arithmetic overflow error for data type \{to.message_name()}, value = \{n}.",
                  state=if to is TinyInt { 2 } else { 1 },
                )
              _ => overflow_expression(to)
            }
          }
          int_value(to, n)
        }
        None => raise internal("bad integer source \{from.to_sql()}")
      }
  }
}

// -------------------------------------------------------------- decimal

///|
fn to_decimal(v : Value, from : SqlType, to : SqlType) -> Value raise SqlError {
  let (p, s) = to.precision_scale().unwrap()
  let d = match v {
    String(text) => {
      let t = trim_spaces(text)
      match Decimal::parse(t) {
        Some(d) => {
          let r = d.rescale(s)
          if r.digits() > p {
            // captured: 8115 state 8
            raise overflow_from(from, to, state=8)
          }
          return Decimal(r)
        }
        // captured: CAST('not-a-number' AS NUMERIC(10,0)) → 8114 state 5
        None => raise error_converting(from, to)
      }
    }
    Float(x) => double_to_decimal17(x)
    DateTime(_, _) | SmallDateTime(_, _) =>
      raise conversion_unsupported(from, to)
    Binary(b) => binary_to_decimal(b, from, to)
    _ =>
      match v.as_decimal() {
        Some(d) => d
        None => raise internal("bad decimal source \{from.to_sql()}")
      }
  }
  let r = d.rescale(s)
  if r.digits() > p {
    // captured: numeric → numeric is state 8 (traps/decimal-overflow)
    raise overflow_from(
      from,
      to,
      state=if from.family() == FDecimal { 8 } else { 1 },
    )
  }
  Decimal(r)
}

// ---------------------------------------------------------------- money

///|
fn money_limits(t : SqlType) -> (Int64, Int64) {
  if t is SmallMoney {
    (-2147483648L, 2147483647L)
  } else {
    (-9223372036854775808L, 9223372036854775807L)
  }
}

///|
/// Money text: ASCII spaces trimmed, optional sign, optional `$`, digits
/// with optional `,` group separators, optional fraction.
fn parse_money_text(text : String) -> Decimal? {
  let s = trim_spaces(text)
  let sb = StringBuilder()
  let mut i = 0
  let n = s.length()
  if i < n && (s[i] == '+' || s[i] == '-') {
    if s[i] == '-' {
      sb.write_char('-')
    }
    i += 1
  }
  if i < n && s[i] == '$' {
    i += 1
  }
  let mut seen_digit = false
  while i < n {
    let c = s[i]
    if is_digit(c) {
      sb.write_char(c.to_int().unsafe_to_char())
      seen_digit = true
    } else if c == '.' {
      sb.write_char('.')
    } else if c != ',' {
      return None
    }
    i += 1
  }
  if !seen_digit {
    return if n == 0 { Some(Decimal::zero()) } else { None }
  }
  Decimal::parse(sb.to_string())
}

///|
fn to_money(v : Value, from : SqlType, to : SqlType) -> Value raise SqlError {
  let d = match v {
    String(text) =>
      match parse_money_text(text) {
        Some(d) => d
        None =>
          raise sql_error(
            235, "Cannot convert a char value to money. The char value has incorrect syntax.",
          )
      }
    Float(x) => double_to_decimal17(x)
    Binary(b) => return binary_to_money(b, to)
    DateTime(_, _) | SmallDateTime(_, _) =>
      raise conversion_unsupported(from, to)
    _ =>
      match v.as_decimal() {
        Some(d) => d
        None => raise internal("bad money source \{from.to_sql()}")
      }
  }
  let units = d.rescale(4).coef()
  let (lo, hi) = money_limits(to)
  if units.compare_int64(lo) < 0 || units.compare_int64(hi) > 0 {
    if from.family() == FString && to is SmallMoney {
      // captured: 294 state 0
      raise sql_error(
        294,
        "The conversion from char data type to smallmoney data type resulted in a smallmoney overflow error.",
        state=0,
      )
    }
    raise overflow_expression(to)
  }
  Money(units.to_int64())
}

// ---------------------------------------------------------------- float

///|
/// Text a string → float conversion reads (captured probes): it ends at
/// the first NUL ('0.5'+CHAR(0) is 0.5, CHAR(0)+'0.5' is 0) and skips
/// leading TAB/LF/VT/FF/CR and no-break spaces, while only spaces may
/// trail ('0.5'+CHAR(9) is 8114). Integers and decimals take only spaces.
fn float_source_text(text : String) -> String {
  let n = text.length()
  let mut end = n
  for i in 0..<n {
    if text.code_unit_at(i) == '\u{0}' {
      end = i
      break
    }
  }
  let mut start = 0
  while start < end {
    let c = text.code_unit_at(start).to_int()
    // Unicode space separators: captured U+202F (others unverified)
    if c == 0x20 ||
      (c >= 0x09 && c <= 0x0D) ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 {
      start += 1
    } else {
      break
    }
  }
  if start == 0 && end == n {
    text
  } else {
    text.unsafe_substring(start~, end~)
  }
}

///|
fn to_float(v : Value, from : SqlType, to : SqlType) -> Value raise SqlError {
  let d = match v {
    String(text) =>
      match parse_float_text(float_source_text(text)) {
        Some(d) => d
        // captured: 8114 state 5 "Error converting data type varchar to float."
        None => raise error_converting(from, to)
      }
    DateTime(days, units) =>
      days.to_double() + units.to_double() / DATETIME_UNITS_PER_DAY.to_double()
    SmallDateTime(days, minutes) =>
      days.to_double() + minutes.to_double() / 1440.0
    Binary(_) => raise conversion_unsupported(from, to)
    _ =>
      match as_double(v) {
        Some(d) => d
        None => raise internal("bad float source \{from.to_sql()}")
      }
  }
  let r = if to is Real { Float::from_double(d).to_double() } else { d }
  if r.is_inf() || r.is_nan() {
    raise overflow_expression(to)
  }
  Float(r)
}

// ----------------------------------------------------------------- guid

///|
fn to_guid(v : Value, from : SqlType) -> Value raise SqlError {
  match v {
    Guid(_) => v
    String(s) =>
      match parse_guid(s) {
        Some(b) => Guid(b)
        // captured: 8169 state 2
        None =>
          raise sql_error(
            8169,
            "Conversion failed when converting from a character string to uniqueidentifier.",
            state=2,
          )
      }
    Binary(b) =>
      // first 16 bytes; shorter input is zero-padded (unverified)
      Guid(
        Bytes::makei(16, fn(i) { if i < b.length() { b[i] } else { b'\x00' } }),
      )
    _ => raise conversion_unsupported(from, UniqueIdentifier)
  }
}
