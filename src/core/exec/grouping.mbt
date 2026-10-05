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
/// Positions 0..<n sorted by `compare_key_rows` on their rows, ties by
/// position, with each row's sort keys (indexed by position).
fn sorted_key_positions(
  rows : Array[Row],
  collations : Array[@types.Collation?],
  ansi : Bool,
) -> (Array[Int], Array[Array[@types.SortKey]]) raise @types.SqlError {
  let keys = rows.map(r => key_row(r, collations, ansi))
  (sort_key_rows(keys, collations, ansi), keys)
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
/// A set of rows for membership tests under `same_row` equality.
priv struct RowSet {
  sorted : Array[Array[@types.SortKey]]
  collations : Array[@types.Collation?]
}

///|
fn RowSet::new(
  rows : Array[Row],
  collations : Array[@types.Collation?],
) -> RowSet raise @types.SqlError {
  let (order, keys) = sorted_key_positions(rows, collations, false)
  { sorted: order.map(i => keys[i]), collations, }
}

///|
fn RowSet::contains(self : RowSet, row : Row) -> Bool raise @types.SqlError {
  let probe = key_row(row, self.collations, false)
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
