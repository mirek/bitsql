// sql_variant: conversion, comparison and SQL_VARIANT_PROPERTY.
//
// A non-NULL sql_variant value is `Value::Variant(base value, base type)`;
// the base type keeps its declared parameters (varchar(3) for 'abc',
// nchar(10), decimal(10,2), datetime2(4)). Rules below come from captures
// in harness/corpus/variant/ (see docs/reference/sql-variant.md).

///|
/// May a value of type `t` be stored in a sql_variant? Max types and
/// timestamp may not (captured: CAST → 529, assignment → 206). A variant
/// "holds" another variant by copying it.
pub fn variant_can_hold(t : SqlType) -> Bool {
  !(t
  is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None) | RowVersion | Xml))
}

///|
/// CAST/CONVERT with sql_variant on either side (called by `cast`).
/// Into a variant the value keeps its type as the base type; out of a
/// variant the base value converts as if it had its base type, and a
/// conversion its base type does not allow fails at run time with 529
/// state 3 (captured: CAST(CAST(1 AS sql_variant) AS date)).
fn cast_variant(
  v : Value,
  from : SqlType,
  to : SqlType,
  style : Int?,
) -> Value raise SqlError {
  match (v, to) {
    (Null, _) => Null
    (Variant(_, _), Variant) => v
    (_, Variant) => Variant(v, from)
    (Variant(inner, base), _) => {
      if !can_convert_explicitly(base, to) {
        raise sql_error(
          529,
          "Explicit conversion from data type \{base.clash_name()} to \{to.clash_name()} is not allowed.",
          state=3,
        )
      }
      cast(inner, base, to, style?)
    }
    _ => raise internal("sql_variant cast of a non-variant value")
  }
}

///|
/// Assignment (INSERT/UPDATE column, SET/SELECT variable, parameter)
/// conversion: like `cast`, but a sql_variant source only converts to a
/// sql_variant target (257) and a target sql_variant rejects max types and
/// timestamp (206). Checked before the value, so a NULL fails too.
pub fn assign(v : Value, from : SqlType, to : SqlType) -> Value raise SqlError {
  // an untyped NULL (typed int by the binder) may be assigned to xml; the
  // type rule for other sources is checked at compile time (precheck_xml)
  if v is Null && (from is Xml || to is Xml) {
    return Null
  }
  check_assign(from, to)
  cast(v, from, to)
}

///|
/// Type check of an assignment `to ← from` (see `assign`).
pub fn check_assign(from : SqlType, to : SqlType) -> Unit raise SqlError {
  // xml never converts implicitly to another type, and only strings and
  // binary convert to it (captured: xml/type 257/206)
  if (from is Xml || to is Xml) && !can_convert_implicitly(from, to) {
    raise implicit_conversion_error(from, to)
  }
  // captured: INSERT of an int into text is 206 "Operand type clash: int
  // is incompatible with text" (nvarchar into image too)
  if (from.is_lob() || to.is_lob()) && !lob_convertible(from, to) {
    raise type_clash_error(from, to)
  }
  match (from, to) {
    (Variant, Variant) => ()
    (Variant, _) => raise implicit_conversion_error(from, to)
    (_, Variant) =>
      if !variant_can_hold(from) {
        raise type_clash_error(from, to)
      }
    _ => ()
  }
}

///|
/// Comparison family rank of a variant's base type: values of different
/// families order by rank (date/time > approximate > exact numeric >
/// character > binary > uniqueidentifier). Captured ORDER BY over mixed
/// variants (variant/compare-order.sql) and SQL Server's documented
/// sql_variant comparison table.
fn variant_rank(t : SqlType) -> Int {
  match t.family() {
    FDate | FTime | FDateTime => 6
    FFloat => 5
    FBit | FInteger | FDecimal | FMoney => 4
    FString => 3
    FBinary => 2
    FGuid => 1
    FVariant | FXml => 0
  }
}

///|
/// The collation fields sql_variant comparison orders by before comparing
/// strings: LCID, collation version, comparison flags, sort id (each as an
/// integer, in that order). Mirrors the TDS collation bytes
/// (session/wire.mbt `collation_bytes`).
fn collation_key(c : Collation) -> (Int, Int, Int, Int) {
  let flags = match c.kind {
    Bin => 16
    Bin2 => 32
    Linguistic =>
      (if c.case_sensitive { 0 } else { 1 }) |
      (if c.accent_sensitive { 0 } else { 2 }) |
      (if c.kana_sensitive { 0 } else { 4 }) |
      (if c.width_sensitive { 0 } else { 8 })
  }
  let sort_id = if c.sql_collation {
    match (c.case_sensitive, c.accent_sensitive, c.kind) {
      (_, _, Bin | Bin2) => 40
      (false, true, _) => 52
      (true, true, _) => 51
      (false, false, _) => 54
      _ => 52
    }
  } else {
    0
  }
  let version = if c.version >= 100 {
    2
  } else if c.version >= 90 {
    1
  } else {
    0
  }
  (1033, version, flags, sort_id)
}

///|
fn compare_tuple(a : (Int, Int, Int, Int), b : (Int, Int, Int, Int)) -> Int {
  if a.0 != b.0 {
    return sign_of(a.0 - b.0)
  }
  if a.1 != b.1 {
    return sign_of(a.1 - b.1)
  }
  if a.2 != b.2 {
    return sign_of(a.2 - b.2)
  }
  sign_of(a.3 - b.3)
}

///|
/// Three-way comparison of two non-NULL variants (-1, 0, 1).
fn compare_variants(
  x : Value,
  tx : SqlType,
  y : Value,
  ty : SqlType,
) -> Int raise SqlError {
  let rx = variant_rank(tx)
  let ry = variant_rank(ty)
  if rx != ry {
    return sign_of(rx - ry)
  }
  match (x, y) {
    (String(a), String(b)) => {
      let ca = tx.collation().unwrap_or(default_collation)
      let cb = ty.collation().unwrap_or(default_collation)
      let k = compare_tuple(collation_key(ca), collation_key(cb))
      if k != 0 {
        return k
      }
      compare_strings(a, b, ca, ansi=!tx.is_unicode() && !ty.is_unicode())
    }
    (Binary(a), Binary(b)) => compare_binary(a, b)
    (Guid(a), Guid(b)) => guid_compare(a, b)
    _ =>
      if rx == 6 {
        compare_temporal_variants(x, tx, y, ty)
      } else {
        compare(x, y).unwrap_or(0)
      }
  }
}

///|
/// Date/time variants of different types: a time is compared as a
/// datetime2 on 1900-01-01 (captured: time sorts before any later date);
/// with a datetimeoffset on either side both compare as UTC instants.
fn compare_temporal_variants(
  x : Value,
  tx : SqlType,
  y : Value,
  ty : SqlType,
) -> Int raise SqlError {
  if tx is DateTimeOffset(_) || ty is DateTimeOffset(_) {
    let a = cast(x, tx, DateTimeOffset(7))
    let b = cast(y, ty, DateTimeOffset(7))
    return compare(a, b).unwrap_or(0)
  }
  let a = if tx is Time(_) { cast(x, tx, DateTime2(7)) } else { x }
  let b = if ty is Time(_) { cast(y, ty, DateTime2(7)) } else { y }
  compare(a, b).unwrap_or(0)
}

///|
/// Arithmetic with a sql_variant operand (captured, variant/operators.sql):
/// against an integer, decimal, money or float operand it is 257 (no
/// implicit conversion from sql_variant to that type), otherwise and for
/// modulo 402 naming both operand types. The binder passes "NULL" for an
/// untyped NULL literal operand.
pub fn variant_arith_error(
  op : ArithOp,
  a : SqlType,
  b : SqlType,
  a_name? : String,
  b_name? : String,
) -> SqlError {
  let other = if a is Variant { b } else { a }
  let other_null = if a is Variant {
    b_name is Some("NULL")
  } else {
    a_name is Some("NULL")
  }
  if op != Mod &&
    !(other is Variant) &&
    !other_null &&
    other.family() is (FInteger | FDecimal | FMoney | FFloat) {
    return implicit_conversion_error(Variant, other)
  }
  let an = a_name.unwrap_or(a.clash_name())
  let bn = b_name.unwrap_or(b.clash_name())
  sql_error(
    402,
    "The data types \{an} and \{bn} are incompatible in the \{op.name()} operator.",
  )
}

// ------------------------------------------------- SQL_VARIANT_PROPERTY

///|
/// Storage bytes of a decimal value: sign byte plus the smallest whole
/// number of 32-bit groups holding the coefficient (captured:
/// DATALENGTH(CAST(12345678901234567890 AS decimal(38,0))) is 9).
pub fn decimal_storage_bytes(d : Decimal) -> Int {
  let c = d.coef()
  let mag = if c.compare_int(0) < 0 { c.neg() } else { c }
  let bytes = if mag.is_zero() { 1 } else { mag.to_octets().length() }
  1 + 4 * ((bytes + 3) / 4)
}

///|
fn temporal_storage(scale : Int, base : Int) -> Int {
  base + (if scale <= 2 { 0 } else if scale <= 4 { 1 } else { 2 })
}

///|
/// Bytes a base value occupies (DATALENGTH of the variant).
pub fn variant_data_length(v : Value, t : SqlType) -> Int {
  match v {
    String(s) => if t.is_unicode() { s.length() * 2 } else { s.length() }
    Binary(b) => b.length()
    Decimal(d) => decimal_storage_bytes(d)
    _ => fixed_storage(t)
  }
}

///|
/// Storage size of fixed-length base types.
fn fixed_storage(t : SqlType) -> Int {
  match t {
    Bit | TinyInt => 1
    SmallInt => 2
    Int | Real | SmallMoney | SmallDateTime => 4
    BigInt | Float | Money | DateTime => 8
    Date => 3
    Time(s) => temporal_storage(s, 3)
    DateTime2(s) => temporal_storage(s, 6)
    DateTimeOffset(s) => temporal_storage(s, 8)
    UniqueIdentifier => 16
    Decimal(p, _) | Numeric(p, _) =>
      if p <= 9 {
        5
      } else if p <= 19 {
        9
      } else if p <= 28 {
        13
      } else {
        17
      }
    Char(n, _) | Binary(n) => n
    NChar(n, _) => n * 2
    VarChar(n, _) | VarBinary(n) => n.unwrap_or(0)
    NVarChar(n, _) => n.unwrap_or(0) * 2
    RowVersion => 8
    Variant | Xml | Text(_) | NText(_) | Image => 0
  }
}

///|
/// Property bytes counted by TotalBytes: decimal precision and scale (2),
/// time-family scale (1), binary max length (2), character collation and
/// max length (6, although the TDS encoding carries 7). TotalBytes = 2 +
/// property bytes + data bytes (captured: int 6, decimal(10,2) 9,
/// varchar(3) 'abc' 11, nchar(10) 28, binary(5) 9, time(3) 7).
fn variant_property_bytes(t : SqlType) -> Int {
  match t {
    Decimal(_, _) | Numeric(_, _) => 2
    Time(_) | DateTime2(_) | DateTimeOffset(_) => 1
    Binary(_) | VarBinary(_) => 2
    Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _) => 6
    _ => 0
  }
}

///|
/// Precision SQL_VARIANT_PROPERTY reports (captured per base type: float
/// 53, real 24, date 10, time(s) 9+s (s>0), datetime2(s) 20+s, datetimeoffset(s)
/// 27+s, datetime 23, smalldatetime 16, character/binary/guid 0).
fn variant_precision(t : SqlType) -> Int {
  let frac = (s : Int) => if s > 0 { s + 1 } else { 0 }
  match t {
    Float => 53
    Real => 24
    Date => 10
    Time(s) => 8 + frac(s)
    DateTime2(s) => 19 + frac(s)
    DateTimeOffset(s) => 26 + frac(s)
    DateTime => 23
    SmallDateTime => 16
    _ =>
      match t.precision_scale() {
        Some((p, _)) => p
        None => 0
      }
  }
}

///|
/// Scale SQL_VARIANT_PROPERTY reports (datetime 3, temporal scales,
/// decimal/money scale, else 0).
fn variant_scale(t : SqlType) -> Int {
  match t {
    Time(s) | DateTime2(s) | DateTimeOffset(s) => s
    DateTime => 3
    _ =>
      match t.precision_scale() {
        Some((_, s)) => s
        None => 0
      }
  }
}

///|
/// MaxLength SQL_VARIANT_PROPERTY reports: the declared maximum in bytes
/// for character/binary base types (nvarchar(4000) 8000, nchar(10) 20),
/// the value's storage size for decimals, the fixed size otherwise.
fn variant_max_length(v : Value, t : SqlType) -> Int {
  match (v, t) {
    (Decimal(d), _) => decimal_storage_bytes(d)
    _ => fixed_storage(t)
  }
}

///|
/// SQL_VARIANT_PROPERTY(v, property): the result is itself a sql_variant
/// (sysname for BaseType/Collation, int otherwise); NULL for a NULL value
/// or an unknown property name (case-insensitive, no trimming).
pub fn sql_variant_property(v : Value, property : String) -> Value {
  guard v is Variant(inner, t) else { return Null }
  let sysname : SqlType = NVarChar(Some(128), default_collation)
  let int_ = (n : Int) => Value::Variant(Value::Int(n), SqlType::Int)
  match property.to_lower() {
    "basetype" => Variant(String(t.base_name()), sysname)
    "precision" => int_(variant_precision(t))
    "scale" => int_(variant_scale(t))
    "totalbytes" =>
      int_(2 + variant_property_bytes(t) + variant_data_length(inner, t))
    "collation" =>
      match t.collation() {
        Some(c) => Variant(String(c.name), sysname)
        None => Null
      }
    "maxlength" => int_(variant_max_length(inner, t))
    _ => Null
  }
}
