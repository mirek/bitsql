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
  if is_ascii_from(s, 0) {
    return Some(
      ascii_text_key(s, collation, !(ansi && collation.sql_collation)),
    )
  }
  let buffers = buffers_a
  let es = buffers.elems
  let ws = buffers.ws
  collation_elements_into(s, 0, collation, ansi, es, ws)
  // one exactly sized key: count base elements (accent-only ones only
  // appear at the accent level)
  let mut base = 0
  for e in es {
    if e >= 0 {
      base += 1
    }
  }
  let mut size = base + 1 + ws.length()
  if collation.accent_sensitive {
    size += es.length() + 1
  }
  if collation.case_sensitive {
    size += base + 1
  }
  if collation.kana_sensitive {
    size += base + 1
  }
  if collation.width_sensitive {
    size += base + 1
  }
  let out = FixedArray::make(size, 0)
  let mut at = 0
  // levels in `compare_linguistic` order, weight + 1 per element and a 0
  // terminator (already 0)
  for level in 0..<5 {
    let wanted = match level {
      0 => true
      1 => collation.accent_sensitive
      2 => collation.case_sensitive
      3 => collation.kana_sensitive
      _ => collation.width_sensitive
    }
    if wanted {
      for e in es {
        if level == 1 || e >= 0 {
          out[at] = element_weight(e, level) + 1
          at += 1
        }
      }
      at += 1
    }
  }
  // a later position sorts first (compare_linguistic: sign_of(wb - wa))
  let mut k = 0
  while k < ws.length() {
    out[at] = 0x3FFFFFFF - ws[k]
    out[at + 1] = ws[k + 1] + 1
    at += 2
    k += 2
  }
  buffers.release()
  Some(out)
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

///|
/// `text_key` of an all-ASCII string without building collation elements:
/// the same integers `collation_elements` gives such strings (no accents,
/// width or kana forms; only NUL can be ignorable, under word sort),
/// written into one array of the exact size.
fn ascii_text_key(
  s : String,
  collation : Collation,
  word_sort : Bool,
) -> FixedArray[Int] {
  let mut n = s.length()
  while n > 0 && (s[n - 1] == ' ' || (word_sort && s[n - 1].to_int() == 0)) {
    n -= 1
  }
  // elements (one per unit) and word-sort ignorables
  let mut elems = 0
  let mut marks = 0
  for i in 0..<n {
    let u = s[i].to_int()
    if word_sort && (u == '-' || u == '\'') {
      marks += 1
    } else if !(word_sort && u == 0) {
      elems += 1
    }
  }
  let plain_levels = (if collation.accent_sensitive { 1 } else { 0 }) +
    (if collation.kana_sensitive { 1 } else { 0 }) +
    (if collation.width_sensitive { 1 } else { 0 })
  let cased = collation.case_sensitive
  let levels = 1 + plain_levels + (if cased { 1 } else { 0 })
  let out = FixedArray::make(levels * (elems + 1) + 2 * marks, 0)
  // level offsets in `compare_linguistic` order: primary, accent, case,
  // kana, width (each elems weights + a 0 terminator)
  let stride = elems + 1
  let case_at = if cased {
    stride * (1 + (if collation.accent_sensitive { 1 } else { 0 }))
  } else {
    -1
  }
  let mut ws_at = levels * stride
  let mut e = 0
  for i in 0..<n {
    let u = s[i].to_int()
    if word_sort && (u == 0 || u == '-' || u == '\'') {
      if u != 0 {
        out[ws_at] = 0x3FFFFFFF - e
        out[ws_at + 1] = u + 1
        ws_at += 2
      }
      continue
    }
    out[e] = ascii_primary(u) + 1
    if case_at >= 0 {
      out[case_at + e] = if u >= 'A' && u <= 'Z' { 3 } else { 1 }
    }
    e += 1
  }
  // plain levels: weight 0 (+1) per element; terminators stay 0
  for l in 1..<levels {
    let base = l * stride
    if base != case_at {
      for k in 0..<elems {
        out[base + k] = 1
      }
    }
  }
  out
}
