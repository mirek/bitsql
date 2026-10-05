// Sort-based grouping for GROUP BY, DISTINCT, UNION/EXCEPT/INTERSECT and
// DISTINCT aggregate inputs. Equality is `same_row`'s (collation-aware,
// NULLs equal to each other); `compare_key_rows` is the total order whose ties
// are exactly that equality, so equal rows sort into adjacent runs. Results
// keep the order of first appearance the linear-search versions produced.

///|
/// Sort keys of a row's values under its columns' collations, for the
/// order of rows under DISTINCT / GROUP BY equality (`compare_key_rows`).
fn key_row(
  row : Row,
  collations : Array[@types.Collation?],
  ansi : Bool,
) -> Array[@types.SortKey] {
  row.mapi((i, v) => @types.sort_key(v, collation?=collations[i], ansi~))
}

///|
/// Order of rows under DISTINCT / GROUP BY equality, on rows of `key_row`
/// keys made with the same arguments: column by column, NULL before any
/// value, values by `@types.compare` under the column's collation. 0
/// exactly when `same_row` holds for the rows.
fn compare_key_rows(
  a : Array[@types.SortKey],
  b : Array[@types.SortKey],
  collations : Array[@types.Collation?],
  ansi : Bool,
) -> Int raise @types.SqlError {
  for i in 0..<a.length() {
    let c = @types.compare_sort_keys(
      a[i],
      b[i],
      collation?=collations[i],
      ansi~,
    )
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Positions of key rows sorted by `compare_key_rows`, ties by position.
fn sort_key_rows(
  keys : Array[Array[@types.SortKey]],
  collations : Array[@types.Collation?],
  ansi : Bool,
) -> Array[Int] raise @types.SqlError {
  let order = Array::makei(keys.length(), i => i)
  let mut failure : @types.SqlError? = None
  stable_sort_by(order, (x, y) => {
    let c = compare_key_rows(keys[x], keys[y], collations, ansi) catch {
      e => {
        failure = Some(e)
        0
      }
    }
    if c != 0 {
      c
    } else {
      x.compare(y)
    }
  })
  if failure is Some(e) {
    raise e
  }
  order
}

///|
/// Whether every column of the key rows holds one exact key kind (NULLs
/// aside), so `Eq` / `Hash` on key rows is `compare_key_rows(..) == 0`
/// and no comparison could raise.
fn hashable_key_rows(keys : Array[Array[@types.SortKey]]) -> Bool {
  guard keys.length() > 0 else { return false }
  let width = keys[0].length()
  for c in 0..<width {
    let mut kind = 0
    for r in keys {
      let k = r[c].exact_kind()
      if k < 0 || (k > 0 && kind > 0 && k != kind) {
        return false
      }
      if k > 0 {
        kind = k
      }
    }
  }
  true
}

///|
/// `group_ids` of one-column key rows without a key array per row: integer
/// values hashed as Int64 (KeyInt equality), other exact sort keys hashed
/// directly; NULLs form one group. None when the column has inexact keys or
/// mixed key kinds (the caller's general path decides those).
fn single_column_ids(
  keys : Array[Row],
  collation : @types.Collation?,
  ansi : Bool,
) -> (Array[Int], Int)? {
  let n = keys.length()
  let ids = Array::make(n, 0)
  let mut count = 0
  let mut null_id = -1
  if keys
    .iter()
    .all(r => r[0] is (Null | TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_))) {
    let seen = IntTable::new(16)
    for i, r in keys {
      if r[0] is Null {
        if null_id < 0 {
          null_id = count
          count += 1
        }
        ids[i] = null_id
        continue
      }
      let k = r[0].int64_or(0L)
      let id = seen.get(k)
      if id >= 0 {
        ids[i] = id
      } else {
        ids[i] = count
        seen.set(k, count)
        count += 1
      }
    }
    return Some((ids, count))
  }
  let ks = keys.map(r => @types.sort_key(r[0], collation?, ansi~))
  let mut kind = 0
  for k in ks {
    let x = k.exact_kind()
    if x < 0 || (x > 0 && kind > 0 && x != kind) {
      return None
    }
    if x > 0 {
      kind = x
    }
  }
  // Store representative row positions in unboxed slots. Each incoming key
  // is hashed once, and a new group uses the same probe that found its empty
  // slot (no boxed Map entry or second lookup to insert it).
  let mut capacity = 16
  while capacity < n * 2 {
    capacity *= 2
  }
  let slots = FixedArray::make(capacity, -1)
  let mask = capacity - 1
  for i, k in ks {
    let mut slot = k.hash() & mask
    while slots[slot] >= 0 && ks[slots[slot]] != k {
      slot = (slot + 1) & mask
    }
    if slots[slot] >= 0 {
      ids[i] = ids[slots[slot]]
    } else {
      slots[slot] = i
      ids[i] = count
      count += 1
    }
  }
  Some((ids, count))
}

///|
/// Group number of every key row: rows that are `same_row`-equal share a
/// group, and groups are numbered in order of first appearance (the first
/// row is in group 0, the next row not equal to it in group 1, ...).
/// Returns (group per row, number of groups). Hashes exact sort keys when
/// every column has them, else O(n log n) comparisons.
fn group_ids(
  keys : Array[Row],
  collations : Array[@types.Collation?],
  ansi? : Bool = false,
) -> (Array[Int], Int) raise @types.SqlError {
  let n = keys.length()
  if n > 0 && keys[0].length() == 1 {
    match single_column_ids(keys, collations[0], ansi) {
      Some(r) => return r
      None => ()
    }
  }
  let ks = keys.map(r => key_row(r, collations, ansi))
  if hashable_key_rows(ks) {
    let seen : Map[Array[@types.SortKey], Int] = Map([])
    let ids = Array::make(n, 0)
    for i, k in ks {
      match seen.get(k) {
        Some(id) => ids[i] = id
        None => {
          ids[i] = seen.length()
          seen.set(k, ids[i])
        }
      }
    }
    return (ids, seen.length())
  }
  let order = sort_key_rows(ks, collations, ansi)
  // each row's run leader: the first (smallest) position of its run
  let leader = Array::make(n, 0)
  let mut start = 0
  for k in 0..<n {
    if k > 0 &&
      compare_key_rows(ks[order[k - 1]], ks[order[k]], collations, ansi) != 0 {
      start = k
    }
    leader[order[k]] = order[start]
  }
  let ids = Array::make(n, 0)
  let mut count = 0
  for i in 0..<n {
    // leader[i] <= i, so a leader is numbered before its followers
    if leader[i] == i {
      ids[i] = count
      count += 1
    } else {
      ids[i] = ids[leader[i]]
    }
  }
  (ids, count)
}

///|
/// DISTINCT over rows: the first row of each group, in order of first
/// appearance, with `prefer_representative` applied over the group's later
/// rows (copies; the input rows are not modified).
fn distinct_rows(
  rows : Array[Row],
  collations : Array[@types.Collation?],
) -> Array[Row] raise @types.SqlError {
  let (ids, _) = group_ids(rows, collations)
  let out : Array[Row] = []
  for i, row in rows {
    if ids[i] == out.length() {
      out.push(row.copy())
    } else {
      prefer_representative(out[ids[i]], row)
    }
  }
  out
}

///|
/// A set of rows for membership tests under `same_row` equality: hashed
/// exact keys when every column has them (a probe row with another key
/// kind is compared row by row), else binary search over sorted keys.
priv struct RowSet {
  sorted : Array[Array[@types.SortKey]]
  hashed : Set[Array[@types.SortKey]]?
  // exact key kind per column (0 when every key is NULL)
  kinds : Array[Int]
  collations : Array[@types.Collation?]
}

///|
fn RowSet::new(
  rows : Array[Row],
  collations : Array[@types.Collation?],
) -> RowSet raise @types.SqlError {
  let keys = rows.map(r => key_row(r, collations, false))
  let hashed = if hashable_key_rows(keys) {
    Some(Set::from_array(keys))
  } else {
    None
  }
  let kinds = Array::make(collations.length(), 0)
  if hashed is Some(_) {
    for r in keys {
      for c, k in r {
        if kinds[c] == 0 {
          kinds[c] = k.exact_kind()
        }
      }
    }
  }
  // hashed sets keep their rows unsorted (probes of another kind scan)
  let sorted = if hashed is Some(_) {
    keys
  } else {
    let order = sort_key_rows(keys, collations, false)
    order.map(i => keys[i])
  }
  { sorted, hashed, kinds, collations, }
}

///|
fn RowSet::contains(self : RowSet, row : Row) -> Bool raise @types.SqlError {
  let probe = key_row(row, self.collations, false)
  if self.hashed is Some(set) {
    if self.kinds_match(probe) {
      return set.contains(probe)
    }
    for k in self.sorted {
      if compare_key_rows(k, probe, self.collations, false) == 0 {
        return true
      }
    }
    return false
  }
  let mut lo = 0
  let mut hi = self.sorted.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = compare_key_rows(self.sorted[mid], probe, self.collations, false)
    if c == 0 {
      return true
    } else if c < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  false
}

///|
/// Whether hashing answers for `probe`: each column's key is NULL or of
/// the set's kind in that column.
fn RowSet::kinds_match(self : RowSet, probe : Array[@types.SortKey]) -> Bool {
  for c, k in probe {
    let kind = k.exact_kind()
    if kind < 0 || (kind > 0 && self.kinds[c] > 0 && self.kinds[c] != kind) {
      return false
    }
  }
  true
}
