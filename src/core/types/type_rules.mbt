// Type rules the binder calls: data type precedence, implicit/explicit
// conversion legality, result types of arithmetic, and the common type of
// comparisons, UNION columns and CASE branches.
//
// Decimal result rules follow Microsoft's "Precision, scale, and length"
// page and are checked against captured metadata in msduck
// reference/decimal-division.json, numeric-arithmetic-context.json and
// numeric-literal-metadata.json.

///|
/// T-SQL data type precedence: higher wins (the lower-precedence operand is
/// converted). Order from `.claude/skills/t-sql/data-types.md` §1.
pub fn precedence(t : SqlType) -> Int {
  match t {
    // captured (json4): every other type converts to json in CASE /
    // COALESCE / UNION ALL (206 "int is incompatible with json", also for
    // sql_variant and xml)
    Json => 29
    Variant => 28
    Xml => 27
    DateTimeOffset(_) => 26
    DateTime2(_) => 25
    DateTime => 24
    SmallDateTime => 23
    Date => 22
    Time(_) => 21
    Float => 20
    Real => 19
    Decimal(_, _) | Numeric(_, _) => 18
    Money => 17
    SmallMoney => 16
    BigInt => 15
    Int => 14
    SmallInt => 13
    TinyInt => 12
    Bit => 11
    NText(_) => 10
    Text(_) => 9
    Image => 8
    RowVersion => 7
    UniqueIdentifier => 6
    NVarChar(_, _) => 5
    NChar(_, _) => 4
    VarChar(_, _) => 3
    Char(_, _) => 2
    VarBinary(_) => 1
    Binary(_) => 0
  }
}

///|
/// Arithmetic operators.
pub(all) enum ArithOp {
  Add
  Sub
  Mul
  Div
  Mod
} derive(Debug, Eq)

///|
/// Operator name as SQL Server prints it in 8117/402 messages.
pub fn ArithOp::name(self : ArithOp) -> String {
  match self {
    Add => "add"
    Sub => "subtract"
    Mul => "multiply"
    Div => "divide"
    Mod => "modulo"
  }
}

///|
fn is_numeric_family(f : TypeFamily) -> Bool {
  f is (FBit | FInteger | FDecimal | FMoney | FFloat)
}

///|
fn is_legacy_datetime(t : SqlType) -> Bool {
  t is (DateTime | SmallDateTime)
}

///|
/// May a value of type `from` be converted to `to` implicitly (operators,
/// assignment, comparison)? Follows SQL Server's conversion chart for the
/// v1 types.
pub fn can_convert_implicitly(from : SqlType, to : SqlType) -> Bool {
  if from.is_lob() || to.is_lob() {
    return lob_convertible(from, to)
  }
  let ff = from.family()
  let tf = to.family()
  if ff == tf {
    return true
  }
  match (ff, tf) {
    // json: only character types convert to it implicitly; it converts to
    // nothing implicitly (captured json4: 257 to strings, 206 otherwise)
    (FString, FJson) => true
    (FJson, _) | (_, FJson) => false
    // sql_variant: anything it can hold converts to it implicitly; it
    // converts to nothing else implicitly (captured 257)
    (_, FVariant) => variant_can_hold(from)
    (FVariant, _) => false
    // xml: strings and binary convert to it implicitly; it converts to
    // nothing implicitly (captured: xml/type 257/206)
    (FString | FBinary, FXml) => true
    (FXml, _) | (_, FXml) => false
    (FString, FBinary) => false
    (FString, _) => true
    (f, t) if is_numeric_family(f) && is_numeric_family(t) => true
    (f, FString) if is_numeric_family(f) => true
    (f, FBinary) if is_numeric_family(f) => true
    (f, FDateTime) if is_numeric_family(f) => is_legacy_datetime(to)
    (FDate, FDateTime) | (FTime, FDateTime) => true
    (FDate | FTime | FDateTime, FString) => true
    (FDateTime, FDate | FTime) => true
    (FGuid, FString | FBinary) => true
    (FBinary, FString | FGuid) => true
    // captured: CONVERT(float, 0x3FF8000000000000) is 529
    (FBinary, FFloat) => false
    (FBinary, t) if is_numeric_family(t) => true
    _ => false
  }
}

///|
/// May `CAST`/`CONVERT` convert `from` to `to` (otherwise error 529)?
pub fn can_convert_explicitly(from : SqlType, to : SqlType) -> Bool {
  if from.is_lob() || to.is_lob() {
    return lob_convertible(from, to)
  }
  if can_convert_implicitly(from, to) {
    return true
  }
  match (from.family(), to.family()) {
    // out of a variant: checked against the base type at run time
    (FVariant, _) => true
    (FXml, FString | FBinary) => true
    // captured json4: json converts explicitly to character types only
    (FJson, FString) => true
    (FString, FBinary) => true
    (FDateTime, t) if is_numeric_family(t) => is_legacy_datetime(from)
    (FBinary, FDateTime) => is_legacy_datetime(to)
    // date, time, datetime2 and datetimeoffset convert to their storage
    // bytes (captured: msduck temporal-guid-format, tail/functions-binary)
    (FDateTime, FBinary) => true
    (FDate | FTime, FBinary) => true
    _ => false
  }
}

///|
/// Error 529: explicit conversion not allowed.
pub fn explicit_conversion_error(from : SqlType, to : SqlType) -> SqlError {
  sql_error(
    529,
    "Explicit conversion from data type \{from.clash_name()} to \{to.clash_name()} is not allowed.",
  )
}

///|
/// Error 257: implicit conversion not allowed (assignment contexts).
pub fn implicit_conversion_error(from : SqlType, to : SqlType) -> SqlError {
  // captured: a max type or timestamp assigned to sql_variant is 206
  if to is Variant && !(from is Variant) {
    return type_clash_error(from, to)
  }
  // captured (json4): json to/from a non-character type is 206
  if (to is Json && from.family() != FString) ||
    (from is Json && to.family() != FString) {
    return type_clash_error(from, to)
  }
  // captured (xml/type): xml to/from a non-character type is 206
  if (to is Xml && !(from.family() is (FString | FBinary))) ||
    (from is Xml && !(to.family() is (FString | FBinary))) {
    return type_clash_error(from, to)
  }
  sql_error(
    257,
    "Implicit conversion from data type \{from.clash_name()} to \{to.clash_name()} is not allowed. Use the CONVERT function to run this query.",
    state=3,
  )
}

///|
/// Error 206: operand type clash (state 2, no trailing period: captured).
pub fn type_clash_error(from : SqlType, to : SqlType) -> SqlError {
  sql_error(
    206,
    "Operand type clash: \{from.clash_name()} is incompatible with \{to.clash_name()}",
    state=2,
  )
}

///|
/// Error 8117: operand type invalid for an operator.
pub fn invalid_operand_error(t : SqlType, op : ArithOp) -> SqlError {
  sql_error(
    8117,
    "Operand data type \{t.clash_name()} is invalid for \{op.name()} operator.",
  )
}

///|
fn max_int(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn min_int(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Result (precision, scale) of `decimal(p1,s1) op decimal(p2,s2)`.
///
/// - `+ -`: p = max(s1,s2) + max(p1-s1, p2-s2) + 1, s = max(s1,s2); over 38
///   the scale shrinks to 38 - max(p1-s1, p2-s2) (Microsoft's documented
///   rule for addition/subtraction).
/// - `*`: p = p1+p2+1, s = s1+s2; `/`: p = p1-s1+s2+max(6, s1+p2+1),
///   s = max(6, s1+p2+1); over 38 (both): integral = p-s; integral < 32 →
///   s = min(s, 38-integral); otherwise s = min(s, 6). p = 38.
/// - `%`: p = min(p1-s1, p2-s2) + max(s1,s2), s = max(s1,s2) (never > 38).
pub fn decimal_result(
  op : ArithOp,
  p1 : Int,
  s1 : Int,
  p2 : Int,
  s2 : Int,
) -> (Int, Int) {
  fn reduce(p : Int, s : Int) -> (Int, Int) {
    if p <= 38 {
      return (p, s)
    }
    let integral = p - s
    if integral < 32 {
      (38, min_int(s, 38 - integral))
    } else {
      (38, min_int(s, 6))
    }
  }

  match op {
    Add | Sub => {
      let integral = max_int(p1 - s1, p2 - s2)
      let s = max_int(s1, s2)
      let p = s + integral + 1
      if p <= 38 {
        (p, s)
      } else {
        (38, max_int(0, min_int(s, 38 - integral)))
      }
    }
    Mul => reduce(p1 + p2 + 1, s1 + s2)
    Div => {
      let s = max_int(6, s1 + p2 + 1)
      reduce(p1 - s1 + s2 + s, s)
    }
    Mod => (min_int(p1 - s1, p2 - s2) + max_int(s1, s2), max_int(s1, s2))
  }
}

///|
/// (precision, scale) common to two decimals in UNION / CASE / comparison:
/// p = max(s1,s2) + max(p1-s1, p2-s2), s = max(s1,s2), capped at 38 by
/// shrinking the scale (integral digits are kept).
pub fn decimal_union(p1 : Int, s1 : Int, p2 : Int, s2 : Int) -> (Int, Int) {
  let integral = max_int(p1 - s1, p2 - s2)
  let s = max_int(s1, s2)
  if s + integral <= 38 {
    (s + integral, s)
  } else {
    (38, max_int(0, 38 - integral))
  }
}

///|
/// Decimal or Numeric: Numeric only when no operand is a Decimal and one is
/// a Numeric (captured: NUMERIC(10,0)/INT → numeric, DECIMAL(10,0)/2 →
/// decimal). Mixed DECIMAL/NUMERIC is unverified; bitsql picks decimal.
fn decimal_kind(a : SqlType, b : SqlType, p : Int, s : Int) -> SqlType {
  if a is Decimal(_, _) || b is Decimal(_, _) {
    Decimal(p, s)
  } else if a is Numeric(_, _) || b is Numeric(_, _) {
    Numeric(p, s)
  } else {
    Decimal(p, s)
  }
}

///|
fn higher(a : SqlType, b : SqlType) -> SqlType {
  if precedence(a) >= precedence(b) {
    a
  } else {
    b
  }
}

///|
fn string_len_units(t : SqlType) -> Int? {
  match t {
    Char(n, _) | NChar(n, _) => Some(n)
    VarChar(n, _) | NVarChar(n, _) => n
    _ => Some(0)
  }
}

///|
/// Result type of `a + b` on two character operands (concatenation): Unicode
/// if either side is; lengths add up, capped at 8000 bytes (4000 Unicode
/// characters; the value is then silently truncated); max if either side is
/// max. Collation is taken from `a` (collation precedence is the binder's
/// job).
pub fn concat_result_type(a : SqlType, b : SqlType) -> SqlType {
  let coll = a.collation().unwrap_or(default_collation)
  let unicode = a.is_unicode() || b.is_unicode()
  // captured (msduck character-concat-declarations, probes): two fixed
  // operands give a fixed result (char+char char, char+nchar nchar, capped
  // at char(8000) / nchar(4000)); any varying operand gives varying
  let fixed = a is (Char(_, _) | NChar(_, _)) && b is (Char(_, _) | NChar(_, _))
  match (string_len_units(a), string_len_units(b)) {
    (Some(x), Some(y)) => {
      let cap = if unicode { 4000 } else { 8000 }
      let n = min_int(x + y, cap)
      match (unicode, fixed) {
        (true, true) => NChar(n, coll)
        (true, false) => NVarChar(Some(n), coll)
        (false, true) => Char(n, coll)
        (false, false) => VarChar(Some(n), coll)
      }
    }
    _ => if unicode { NVarChar(None, coll) } else { VarChar(None, coll) }
  }
}

///|
/// The type an arithmetic expression `a op b` has (both operands non-NULL
/// typed; the binder types a bare NULL literal as int first). Raises the
/// SQL Server errors for invalid operand types (8117, 206, 402) and
/// EMU_OPERATOR_NOT_SUPPORTED for legacy datetime arithmetic.
pub fn arith_result_type(
  op : ArithOp,
  a : SqlType,
  b : SqlType,
) -> SqlType raise SqlError {
  if a is Variant || b is Variant {
    raise variant_arith_error(op, a, b)
  }
  // captured (xml/type, json4): xml + xml is 8117, xml + nvarchar 402
  if a is (Xml | Json) || b is (Xml | Json) {
    if a == b {
      raise invalid_operand_error(a, op)
    }
    raise sql_error(
      402,
      "The data types \{a.clash_name()} and \{b.clash_name()} are incompatible in the \{op.name()} operator.",
    )
  }
  let fa = a.family()
  let fb = b.family()
  // String + string is concatenation; other operators on two strings are
  // invalid. A string meeting a number converts to the number type.
  if fa == FString && fb == FString {
    if op == Add {
      return concat_result_type(a, b)
    }
    raise invalid_operand_error(a, op)
  }
  if fa == FBinary && fb == FBinary && op == Add {
    return match (a, b) {
      (VarBinary(None), _) | (_, VarBinary(None)) => VarBinary(None)
      _ =>
        VarBinary(
          Some(min_int(string_len_units_bin(a) + string_len_units_bin(b), 8000)),
        )
    }
  }
  // a string with date/time/datetime2/datetimeoffset: 402 (captured:
  // timezone/at-time-zone#030); legacy datetime converts the string
  if (fa == FString) != (fb == FString) {
    let other = if fa == FString { b } else { a }
    if other.family() is (FDate | FTime | FDateTime) &&
      !is_legacy_datetime(other) {
      raise sql_error(
        402,
        "The data types \{a.clash_name()} and \{b.clash_name()} are incompatible in the \{op.name()} operator.",
      )
    }
  }
  let a1 = if fa == FString { b } else { a }
  let b1 = if fb == FString { a } else { b }
  let fa1 = a1.family()
  let fb1 = b1.family()
  // temporal operands
  if fa1 is (FDate | FTime | FDateTime) || fb1 is (FDate | FTime | FDateTime) {
    if is_legacy_datetime(a1) || is_legacy_datetime(b1) {
      raise not_supported(
        "arithmetic on \{a.base_name()} and \{b.base_name()}",
        number=EMU_OPERATOR_NOT_SUPPORTED,
      )
    }
    if fa1 is (FDate | FTime | FDateTime) && fb1 is (FDate | FTime | FDateTime) {
      raise invalid_operand_error(a1, op)
    }
    raise type_clash_error(
      if fa1 is (FDate | FTime | FDateTime) {
        b1
      } else {
        a1
      },
      if fa1 is (FDate | FTime | FDateTime) {
        a1
      } else {
        b1
      },
    )
  }
  if fa1 == FGuid || fb1 == FGuid {
    if fa1 == FGuid && fb1 == FGuid {
      raise invalid_operand_error(a1, op)
    }
    raise type_clash_error(
      if fa1 == FGuid {
        a1
      } else {
        b1
      },
      if fa1 == FGuid {
        b1
      } else {
        a1
      },
    )
  }
  if fa1 == FBinary || fb1 == FBinary {
    raise not_supported(
      "arithmetic on \{a.base_name()} and \{b.base_name()}",
      number=EMU_OPERATOR_NOT_SUPPORTED,
    )
  }
  // numeric operands
  if fa1 == FBit && fb1 == FBit {
    raise invalid_operand_error(a1, op)
  }
  if fa1 == FFloat || fb1 == FFloat {
    if op == Mod {
      raise sql_error(
        402,
        "The data types \{a1.clash_name()} and \{b1.clash_name()} are incompatible in the modulo operator.",
      )
    }
    return if a1 is Float || b1 is Float { Float } else { Real }
  }
  if fa1 == FDecimal || fb1 == FDecimal {
    let (p1, s1) = a1.precision_scale().unwrap()
    let (p2, s2) = b1.precision_scale().unwrap()
    let (p, s) = decimal_result(op, p1, s1, p2, s2)
    return decimal_kind(a1, b1, p, s)
  }
  if fa1 == FMoney || fb1 == FMoney {
    return if a1 is Money || b1 is Money { Money } else { SmallMoney }
  }
  // integers (bit promotes)
  higher(a1, b1)
}

///|
fn string_len_units_bin(t : SqlType) -> Int {
  match t {
    Binary(n) | VarBinary(Some(n)) => n
    RowVersion => 8
    _ => 0
  }
}

///|
/// The common type of two operands of a comparison, or two UNION / CASE
/// branches: same-family types merge their parameters (string lengths,
/// decimal precision, temporal scale); otherwise the higher-precedence type
/// wins if the other converts to it implicitly, else error 206. For strings
/// the collation of `a` is kept (collation precedence and 468 conflicts are
/// the binder's job).
pub fn common_type(a : SqlType, b : SqlType) -> SqlType raise SqlError {
  // a LOB wins by precedence (captured: CASE .. text .. ELSE 'x' is text)
  if a.is_lob() || b.is_lob() {
    let hi = higher(a, b)
    let lo = if hi == a { b } else { a }
    if !can_convert_implicitly(lo, hi) {
      raise type_clash_error(lo, hi)
    }
    return hi
  }
  match (a, b) {
    (Decimal(p1, s1) | Numeric(p1, s1), Decimal(p2, s2) | Numeric(p2, s2)) => {
      let (p, s) = decimal_union(p1, s1, p2, s2)
      return decimal_kind(a, b, p, s)
    }
    (Time(x), Time(y)) => return Time(max_int(x, y))
    (DateTime2(x), DateTime2(y)) => return DateTime2(max_int(x, y))
    (DateTimeOffset(x), DateTimeOffset(y)) =>
      return DateTimeOffset(max_int(x, y))
    _ => ()
  }
  let fa = a.family()
  let fb = b.family()
  if fa == FString && fb == FString {
    let coll = a.collation().unwrap_or(default_collation)
    let unicode = a.is_unicode() || b.is_unicode()
    let fixed = a is (Char(_, _) | NChar(_, _)) &&
      b is (Char(_, _) | NChar(_, _))
    return match (string_len_units(a), string_len_units(b)) {
      (Some(x), Some(y)) => {
        // a long varchar meeting nvarchar caps at nvarchar(4000) (captured:
        // msduck conditional-literal-folding #012, varchar(5000) vs N'x')
        let n = if unicode {
          min_int(max_int(x, y), 4000)
        } else {
          max_int(x, y)
        }
        match (unicode, fixed) {
          (true, true) => NChar(n, coll)
          (true, false) => NVarChar(Some(n), coll)
          (false, true) => Char(n, coll)
          (false, false) => VarChar(Some(n), coll)
        }
      }
      _ => if unicode { NVarChar(None, coll) } else { VarChar(None, coll) }
    }
  }
  if fa == FBinary && fb == FBinary {
    return match (a, b) {
      (VarBinary(None), _) | (_, VarBinary(None)) => VarBinary(None)
      (Binary(x), Binary(y)) => Binary(max_int(x, y))
      _ =>
        VarBinary(
          Some(max_int(string_len_units_bin(a), string_len_units_bin(b))),
        )
    }
  }
  let hi = higher(a, b)
  let lo = if hi == a { b } else { a }
  // integer/money/float/decimal mixes: decimal against an integer or money
  // keeps enough digits for both.
  if hi.family() == FDecimal && lo.precision_scale() is Some((p2, s2)) {
    let (p1, s1) = hi.precision_scale().unwrap()
    let (p, s) = decimal_union(p1, s1, p2, s2)
    return decimal_kind(hi, lo, p, s)
  }
  if !can_convert_implicitly(lo, hi) {
    raise type_clash_error(lo, hi)
  }
  hi
}
