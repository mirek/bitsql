// Three-valued comparison of runtime values. The binder has already cast
// both operands to their common type (`common_type`); this function still
// accepts any mix of exact numerics, floats with numerics, and the temporal
// types without offsets, so evaluation does not depend on that cast being
// materialised for those families.

///|
/// Compare two values: Some(-1 | 0 | 1), or None (SQL "unknown") when
/// either side is NULL. Character values compare under `collation`
/// (default: the default collation); `ansi` marks char/varchar operands.
/// Raises EMU_INTERNAL for operands of incomparable families (a binder bug).
pub fn compare(
  a : Value,
  b : Value,
  collation? : Collation = default_collation,
  ansi? : Bool = false,
) -> Int? raise SqlError {
  if a is Null || b is Null {
    return None
  }
  let r = match (a, b) {
    // same-representation integers: no decimal conversion
    (Int(x), Int(y)) | (SmallInt(x), SmallInt(y)) | (TinyInt(x), TinyInt(y)) =>
      x.compare(y)
    (BigInt(x), BigInt(y)) => x.compare(y)
    // integers of different types: by value, exact in Int64 (the decimal
    // comparison below gives the same order)
    (
      TinyInt(_)
      | SmallInt(_)
      | Int(_)
      | BigInt(_),
      TinyInt(_)
      | SmallInt(_)
      | Int(_)
      | BigInt(_),
    ) => a.int64_or(0L).compare(b.int64_or(0L))
    (Variant(x, tx), Variant(y, ty)) => compare_variants(x, tx, y, ty)
    (Variant(_, _), _) | (_, Variant(_, _)) =>
      raise internal("sql_variant compared with a non-variant value")
    (String(x), String(y)) => compare_strings(x, y, collation, ansi~)
    (Guid(x), Guid(y)) => guid_compare(x, y)
    (Binary(x), Binary(y)) => compare_binary(x, y)
    (DateTimeOffset(x, _), DateTimeOffset(y, _)) => x.compare(y)
    (Time(x), Time(y)) => x.compare(y)
    (Float(x), _) | (_, Float(x)) => {
      let (p, q) = match (as_double(a), as_double(b)) {
        (Some(p), Some(q)) => (p, q)
        _ => raise internal("float compared with a non-numeric value")
      }
      ignore(x)
      p.compare(q)
    }
    _ =>
      match (a.as_decimal(), b.as_decimal()) {
        (Some(x), Some(y)) => x.compare(y)
        _ =>
          match (absolute_ticks(a), absolute_ticks(b)) {
            (Some(x), Some(y)) => x.compare(y)
            _ => raise internal("incomparable values")
          }
      }
  }
  Some(sign_of(r))
}

///|
/// Date/datetime values as 100 ns ticks since 0001-01-01 (legacy datetime
/// keeps its exact 1/300 s value: units * 100000 / 3 is not integral, so
/// the tick count is scaled by 3 everywhere to stay exact).
fn absolute_ticks(v : Value) -> @bigint.BigInt? {
  let three = @bigint.BigInt::from_int(3)
  match v {
    Date(d) =>
      Some(@bigint.BigInt::from_int64(d.to_int64() * TICKS_PER_DAY) * three)
    DateTime2(x) => Some(@bigint.BigInt::from_int64(x) * three)
    DateTime(d, u) =>
      Some(
        @bigint.BigInt::from_int64(
          (d + DAYS_TO_1900).to_int64() * TICKS_PER_DAY * 3L +
          u.to_int64() * 100_000L,
        ),
      )
    SmallDateTime(d, m) =>
      Some(
        @bigint.BigInt::from_int64(
          (d + DAYS_TO_1900).to_int64() * TICKS_PER_DAY +
          m.to_int64() * TICKS_PER_MINUTE,
        ) *
        three,
      )
    _ => None
  }
}

///|
/// Binary comparison: byte-wise, the shorter operand padded with 0x00
/// (unverified: mirrors the space padding of strings).
pub fn compare_binary(a : Bytes, b : Bytes) -> Int {
  let n = if a.length() > b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = if i < a.length() { a[i].to_int() } else { 0 }
    let y = if i < b.length() { b[i].to_int() } else { 0 }
    if x != y {
      return sign_of(x - y)
    }
  }
  0
}

///|
/// SQL `=`: Some(true/false) or None when unknown.
pub fn sql_equal(
  a : Value,
  b : Value,
  collation? : Collation = default_collation,
  ansi? : Bool = false,
) -> Bool? raise SqlError {
  match compare(a, b, collation~, ansi~) {
    Some(c) => Some(c == 0)
    None => None
  }
}
