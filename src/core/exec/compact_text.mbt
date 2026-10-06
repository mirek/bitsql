///|
/// Case-folded ASCII letters/digits, at most eight UTF-16 units, with SQL
/// trailing-space padding. Left-aligned nonzero bytes give prefix order.
/// This encoding is used only for the default English CI collation.
fn compact_word(s : String) -> Int64? {
  guard s.length() <= 8 else { return None }
  let mut n = s.length()
  while n > 0 && s.code_unit_at(n - 1) == 32 {
    n -= 1
  }
  let mut key = 0L
  for i in 0..<n {
    let c = s.code_unit_at(i)
    let folded = if c >= 65 && c <= 90 { c + 32 } else { c }
    guard (folded >= 97 && folded <= 122) || (folded >= 48 && folded <= 57) else {
      return None
    }
    key = (key << 8) | folded.to_int64()
  }
  Some(if n == 0 { 0L } else { key << ((8 - n) * 8) })
}

///|
fn compact_collation(collation : @types.Collation?, ansi : Bool) -> Bool {
  !ansi &&
  collation.unwrap_or(@types.default_collation) == @types.default_collation
}

///|
/// Validate the whole column before using the encoding. Any unsupported value
/// leaves the caller on its original comparison path; NULL has its own tag.
fn compact_words(
  values : Array[@types.Value],
  collation : @types.Collation?,
  ansi : Bool,
) -> Array[Int64]? {
  guard compact_collation(collation, ansi) else { return None }
  // Reject common boundary exceptions before allocating/scanning the column.
  // Every value is still checked below; these probes never authorize packing.
  if !values.is_empty() &&
    (
      compact_value(values[0]) is None ||
      compact_value(values[values.length() - 1]) is None
    ) {
    return None
  }
  let out : Array[Int64] = Array(capacity=values.length())
  for value in values {
    match value {
      Null => out.push(0L)
      String(s) =>
        match compact_word(s) {
          Some(key) => out.push(key)
          None => return None
        }
      _ => return None
    }
  }
  Some(out)
}

///|
fn compact_value(value : @types.Value) -> Int64? {
  match value {
    Null => Some(0L)
    String(s) => compact_word(s)
    _ => None
  }
}

///|
/// Sort directly from input rows, without copying a column just to reject it.
fn compact_row_words(values : Array[Row], column : Int) -> Array[Int64]? {
  if !values.is_empty() &&
    (
      compact_value(values[0][column]) is None ||
      compact_value(values[values.length() - 1][column]) is None
    ) {
    return None
  }
  let out : Array[Int64] = Array(capacity=values.length())
  for row in values {
    match compact_value(row[column]) {
      Some(key) => out.push(key)
      None => return None
    }
  }
  Some(out)
}
