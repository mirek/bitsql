///|
/// Optimal string alignment distance, using three rows for adjacent swaps.
fn fuzzy_edit(a : Array[Array[Int]], b : Array[Array[Int]]) -> Int {
  let n = b.length()
  let mut previous = Array::makei(n + 1, i => i)
  let mut older = Array::make(n + 1, 0)
  let mut current = Array::make(n + 1, 0)
  for i in 1..<(a.length() + 1) {
    current[0] = i
    for j in 1..<(n + 1) {
      let substitution = previous[j - 1] +
        (if a[i - 1] == b[j - 1] { 0 } else { 1 })
      let mut distance = @cmp.minimum(
        substitution,
        @cmp.minimum(previous[j] + 1, current[j - 1] + 1),
      )
      if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
        distance = @cmp.minimum(distance, older[j - 2] + 1)
      }
      current[j] = distance
    }
    let scratch = older
    older = previous
    previous = current
    current = scratch
  }
  previous[n]
}

///|
fn fuzzy_jaro(a : Array[Array[Int]], b : Array[Array[Int]]) -> Double {
  if a == b {
    return 1.0
  }
  let na = a.length()
  let nb = b.length()
  if na == 0 || nb == 0 {
    return 0.0
  }
  let window = @cmp.maximum(0, @cmp.maximum(na, nb) / 2 - 1)
  let ma = Array::make(na, -1)
  let mb = Array::make(nb, false)
  let mut matches = 0
  for i in 0..<na {
    for j in @cmp.maximum(0, i - window)..<@cmp.minimum(nb, i + window + 1) {
      if !mb[j] && a[i] == b[j] {
        ma[i] = j
        mb[j] = true
        matches += 1
        break
      }
    }
  }
  if matches == 0 {
    return 0.0
  }
  let mut j = 0
  let mut transpositions = 0
  for i in 0..<na {
    if ma[i] >= 0 {
      while !mb[j] {
        j += 1
      }
      // Count displaced matched positions, including equal repeated letters.
      // Captured by sql2025/fuzzy-algorithms, unlike textbook character comparisons.
      if ma[i] != j {
        transpositions += 1
      }
      j += 1
    }
  }
  let m = matches.to_double()
  let base = (
      m / na.to_double() +
      m / nb.to_double() +
      (m - transpositions.to_double() / 2.0) / m
    ) /
    3.0
  let mut prefix = 0
  while prefix < @cmp.minimum(4, @cmp.minimum(na, nb)) && a[prefix] == b[prefix] {
    prefix += 1
  }
  base + prefix.to_double() * 0.1 * (1.0 - base)
}

///|
fn call_fuzzy(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value? raise @types.SqlError {
  if !(name
    is ("EDIT_DISTANCE"
    | "EDIT_DISTANCE_SIMILARITY"
    | "JARO_WINKLER_DISTANCE"
    | "JARO_WINKLER_SIMILARITY")) {
    return None
  }
  if v.iter().any(x => x is Null) {
    return Some(Null)
  }
  let coll = pair_collation(args[0].ty, args[1].ty)
  if coll.sql_collation {
    raise @types.sql_error(
      9847, "The fuzzy string matching function does not support SQL_* collations. Use a Windows collation instead.",
    )
  }
  guard v[0] is String(sa) && v[1] is String(sb) else { return Some(Null) }
  let a = @types.fuzzy_elements(sa, coll)
  let b = @types.fuzzy_elements(sb, coll)
  ctx.rt.charge(a.length().to_int64() * b.length().to_int64() + 1L)
  if name.has_prefix("JARO") {
    let empty_a = sa.trim_end(chars=" ").is_empty()
    let empty_b = sb.trim_end(chars=" ").is_empty()
    let similarity = if empty_a != empty_b { 0.0 } else { fuzzy_jaro(a, b) }
    return Some(
      if name == "JARO_WINKLER_DISTANCE" {
        Float(1.0 - similarity)
      } else {
        Int((similarity * 100.0 + 0.5).to_int())
      },
    )
  }
  let distance = fuzzy_edit(a, b)
  if name == "EDIT_DISTANCE_SIMILARITY" {
    let n = @cmp.maximum(a.length(), b.length())
    return Some(
      Int(
        if n == 0 {
          100
        } else {
          ((1.0 - distance.to_double() / n.to_double()) * 100.0 + 0.5).to_int()
        },
      ),
    )
  }
  let limit = if v.length() == 3 { v[2].as_int64().unwrap_or(-1L) } else { -1L }
  Some(
    Int(
      if limit >= 0L && limit < distance.to_int64() {
        limit.to_int() + 1
      } else {
        distance
      },
    ),
  )
}
