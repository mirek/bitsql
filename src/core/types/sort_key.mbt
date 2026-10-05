// Precomputed sort keys: a value turned once into a form whose comparison
// is cheap and agrees exactly with `compare` (NULL first, as ORDER BY and
// DISTINCT / GROUP BY order them). Sorting n rows then derives n keys
// instead of re-deriving collation elements in each of the n log n
// comparisons.
//
// Only shapes with an exact cheap order get a key: integers, date /
// datetime2 ticks, and strings under linguistic collations (the
// collation-element levels laid out one after another). Everything else
// (and any pair of different key kinds) compares the original values with
// `compare`, so the order is `compare`'s by construction.
// `sort_key_wbtest.mbt` checks key order against `compare` pair by pair.

///|
/// A value prepared for repeated comparison under one collation.
pub enum SortKey {
  KeyNull
  /// tinyint / smallint / int / bigint
  KeyInt(Int64, Value)
  /// date / datetime2 as 100 ns ticks since 0001-01-01
  KeyTicks(Int64, Value)
  /// linguistic collation levels (see `text_key`)
  KeyText(FixedArray[Int], Value)
  KeyValue(Value)
}

///|
/// The sort key of `v` under `collation` (`ansi`: char/varchar operand).
pub fn sort_key(
  v : Value,
  collation? : Collation = default_collation,
  ansi? : Bool = false,
) -> SortKey {
  match v {
    Null => KeyNull
    TinyInt(x) | SmallInt(x) | Int(x) => KeyInt(x.to_int64(), v)
    BigInt(x) => KeyInt(x, v)
    Date(d) => KeyTicks(d.to_int64() * TICKS_PER_DAY, v)
    DateTime2(x) => KeyTicks(x, v)
    String(s) =>
      match text_key(s, collation, ansi) {
        Some(k) => KeyText(k, v)
        None => KeyValue(v)
      }
    _ => KeyValue(v)
  }
}

///|
fn SortKey::value(self : SortKey) -> Value {
  match self {
    KeyNull => Null
    KeyInt(_, v) | KeyTicks(_, v) | KeyText(_, v) | KeyValue(v) => v
  }
}

///|
/// Order of two keys made under the same `collation` and `ansi`: NULL
/// first, otherwise `compare`'s result.
pub fn compare_sort_keys(
  a : SortKey,
  b : SortKey,
  collation? : Collation = default_collation,
  ansi? : Bool = false,
) -> Int raise SqlError {
  match (a, b) {
    (KeyNull, KeyNull) => 0
    (KeyNull, _) => -1
    (_, KeyNull) => 1
    (KeyInt(x, _), KeyInt(y, _)) | (KeyTicks(x, _), KeyTicks(y, _)) =>
      x.compare(y)
    (KeyText(x, _), KeyText(y, _)) => compare_int_arrays(x, y)
    _ => compare(a.value(), b.value(), collation~, ansi~).unwrap_or(0)
  }
}

///|
fn compare_int_arrays(a : FixedArray[Int], b : FixedArray[Int]) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a[i]
    let y = b[i]
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  a.length().compare(b.length())
}

///|
/// Linguistic comparison as one integer sequence, compared
/// lexicographically (a proper prefix first). Each level `compare_linguistic`
/// consults, in its order, is written as weight + 1 per element it looks
/// at, then a 0 terminator, so an exhausted level sorts first exactly as
/// `compare_level` returns; the word-sort ignorables follow as (position
/// descending, unit) pairs. None where `compare_strings` takes another
/// route: binary collations (space padding is not a prefix order) and the
/// SQL sort order on varchar data (its NUL padding rule).
fn text_key(s : String, collation : Collation, ansi : Bool) -> FixedArray[Int]? {
  let ansi = ansi && !collation.utf8()
  if !(collation.kind is Linguistic) || (ansi && collation.sql_collation) {
    return None
  }
  let (es, ws) = collation_elements(s, collation, ansi)
  let out : Array[Int] = []
  let level = (key : (Element) -> Int, skip_zero_primary : Bool) => {
    for e in es {
      if !(skip_zero_primary && e.primary == 0) {
        out.push(key(e) + 1)
      }
    }
    out.push(0)
  }
  level(e => e.primary, true)
  if collation.accent_sensitive {
    level(e => e.secondary, false)
  }
  if collation.case_sensitive {
    level(e => e.tertiary, true)
  }
  if collation.kana_sensitive {
    level(e => e.kana, true)
  }
  if collation.width_sensitive {
    level(e => e.width, true)
  }
  // a later position sorts first (compare_linguistic: sign_of(wb - wa))
  for w in ws {
    out.push(0x3FFFFFFF - w.0)
    out.push(w.1 + 1)
  }
  Some(FixedArray::from_array(out))
}

///|
/// Kind of key for grouping: keys of one exact kind are equal under
/// `compare_sort_keys` exactly when they are equal under `Eq` (and then
/// hash alike), so rows can be grouped by hashing. 0 NULL, 1 integer,
/// 2 ticks, 3 text; -1 for keys that only `compare` can order.
pub fn SortKey::exact_kind(self : SortKey) -> Int {
  match self {
    KeyNull => 0
    KeyInt(_, _) => 1
    KeyTicks(_, _) => 2
    KeyText(_, _) => 3
    KeyValue(_) => -1
  }
}

///|
/// Payload equality of exact keys (`exact_kind` >= 0); keys that only
/// `compare` orders are never equal here.
pub impl Eq for SortKey with fn equal(a, b) {
  match (a, b) {
    (KeyNull, KeyNull) => true
    (KeyInt(x, _), KeyInt(y, _)) | (KeyTicks(x, _), KeyTicks(y, _)) => x == y
    (KeyText(x, _), KeyText(y, _)) => compare_int_arrays(x, y) == 0
    _ => false
  }
}

///|
pub impl Hash for SortKey with fn hash_combine(self, h) {
  match self {
    KeyNull => h.combine_int(0)
    KeyInt(x, _) => {
      h.combine_int(1)
      h.combine_int64(x)
    }
    KeyTicks(x, _) => {
      h.combine_int(2)
      h.combine_int64(x)
    }
    KeyText(x, _) => {
      h.combine_int(3)
      for w in x {
        h.combine_int(w)
      }
    }
    KeyValue(_) => h.combine_int(-1)
  }
}
