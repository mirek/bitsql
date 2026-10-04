// Sort-based grouping for GROUP BY, DISTINCT, UNION/EXCEPT/INTERSECT and
// DISTINCT aggregate inputs. Equality is `same_row`'s (collation-aware,
// NULLs equal to each other); `compare_rows` is the total order whose ties
// are exactly that equality, so equal rows sort into adjacent runs. Results
// keep the order of first appearance the linear-search versions produced.

///|
/// Order of rows under DISTINCT / GROUP BY equality: column by column, NULL
/// before any value, values by `@types.compare` under the column's
/// collation. `compare_rows(a, b, cs) == 0` exactly when `same_row(a, b, cs)`.
fn compare_rows(
  a : Row,
  b : Row,
  collations : Array[@types.Collation?],
  ansi? : Bool = false,
) -> Int raise @types.SqlError {
  for i in 0..<a.length() {
    let c = match (a[i], b[i]) {
      (Null, Null) => 0
      (Null, _) => -1
      (_, Null) => 1
      _ =>
        @types.compare(a[i], b[i], collation?=collations[i], ansi~).unwrap_or(0)
    }
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Positions 0..<n sorted by `compare_rows` on their rows, ties by position.
fn sorted_positions(
  keys : Array[Row],
  collations : Array[@types.Collation?],
  ansi? : Bool = false,
) -> Array[Int] raise @types.SqlError {
  let order = Array::makei(keys.length(), i => i)
  let mut failure : @types.SqlError? = None
  order.sort_by((x, y) => {
    let c = compare_rows(keys[x], keys[y], collations, ansi~) catch {
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
/// Group number of every key row: rows that are `same_row`-equal share a
/// group, and groups are numbered in order of first appearance (the first
/// row is in group 0, the next row not equal to it in group 1, ...).
/// Returns (group per row, number of groups). O(n log n) comparisons.
fn group_ids(
  keys : Array[Row],
  collations : Array[@types.Collation?],
  ansi? : Bool = false,
) -> (Array[Int], Int) raise @types.SqlError {
  let n = keys.length()
  let order = sorted_positions(keys, collations, ansi~)
  // each row's run leader: the first (smallest) position of its run
  let leader = Array::make(n, 0)
  let mut start = 0
  for k in 0..<n {
    if k > 0 &&
      compare_rows(keys[order[k - 1]], keys[order[k]], collations, ansi~) != 0 {
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
  sorted : Array[Row]
  collations : Array[@types.Collation?]
}

///|
fn RowSet::new(
  rows : Array[Row],
  collations : Array[@types.Collation?],
) -> RowSet raise @types.SqlError {
  let order = sorted_positions(rows, collations)
  { sorted: order.map(i => rows[i]), collations, }
}

///|
fn RowSet::contains(self : RowSet, row : Row) -> Bool raise @types.SqlError {
  let mut lo = 0
  let mut hi = self.sorted.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let c = compare_rows(self.sorted[mid], row, self.collations)
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
