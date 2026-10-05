///|
/// Lock modes bitsql models (design: storage-concurrency.md): S/U/X on keys
/// and tables, plus IS/IX for application locks (sp_getapplock
/// IntentShared/IntentExclusive). Pages, escalation and Range* modes are
/// deliberately absent.
pub(all) enum LockMode {
  IS
  IX
  S
  U
  X
} derive(Debug, Eq)

///|
/// SQL Server's compatibility matrix restricted to IS/IX/S/U/X.
pub fn compatible(a : LockMode, b : LockMode) -> Bool {
  match (a, b) {
    (X, _) | (_, X) => false
    (IS, _) | (_, IS) => true
    (IX, IX) => true
    (IX, _) | (_, IX) => false
    (S, S) | (S, U) | (U, S) => true
    _ => false
  }
}

///|
/// Stronger of two modes held by one session on one resource (S + IX would
/// be SIX; bitsql uses X).
pub fn LockMode::max(self : LockMode, other : LockMode) -> LockMode {
  match (self, other) {
    (X, _) | (_, X) => X
    (IX, S) | (S, IX) | (IX, U) | (U, IX) => X
    (U, _) | (_, U) => U
    (S, _) | (_, S) => S
    (IX, _) | (_, IX) => IX
    _ => IS
  }
}

///|
pub(all) enum Duration {
  Statement
  Transaction
  /// Held until released explicitly or the session ends (session-owned
  /// application locks).
  Session
} derive(Debug, Eq)

///|
pub(all) enum Bound[K] {
  Unbounded
  Inclusive(K)
  Exclusive(K)
} derive(Debug, Eq)

///|
/// Key interval on one index. A point key is `[k, k]`; a seek predicate
/// `k > 5` is `(5, +inf)`; `HOLDLOCK` on an absent key locks its point.
pub(all) struct Interval[K] {
  lo : Bound[K]
  hi : Bound[K]
} derive(Debug, Eq)

///|
pub fn[K] Interval::point(k : K) -> Interval[K] {
  { lo: Inclusive(k), hi: Inclusive(k), }
}

///|
pub fn[K] Interval::all() -> Interval[K] {
  { lo: Unbounded, hi: Unbounded, }
}

///|
/// True when the intervals share at least one key under `cmp`.
pub fn[K] Interval::overlaps(
  self : Interval[K],
  other : Interval[K],
  cmp : (K, K) -> Int,
) -> Bool {
  // self.lo <= other.hi && other.lo <= self.hi, respecting exclusivity
  lo_before_hi(self.lo, other.hi, cmp) && lo_before_hi(other.lo, self.hi, cmp)
}

///|
fn[K] lo_before_hi(lo : Bound[K], hi : Bound[K], cmp : (K, K) -> Int) -> Bool {
  match (lo, hi) {
    (Unbounded, _) | (_, Unbounded) => true
    (Inclusive(a), Inclusive(b)) => cmp(a, b) <= 0
    (Inclusive(a), Exclusive(b))
    | (Exclusive(a), Inclusive(b))
    | (Exclusive(a), Exclusive(b)) => cmp(a, b) < 0
  }
}

///|
pub(all) enum Resource[K] {
  /// One key of `index` on `table` (a row lock); same as a point
  /// `KeyRange` but a single allocation, since DML takes one per row.
  Key(table~ : Int, index~ : Int, K)
  /// Interval of keys of `index` on `table`.
  KeyRange(table~ : Int, index~ : Int, Interval[K])
  /// Whole table: the fallback when no index matches the predicate.
  WholeTable(Int)
} derive(Debug, Eq)

///|
pub fn[K] Resource::table(self : Resource[K]) -> Int {
  match self {
    Key(table~, _, ..) | KeyRange(table~, _, ..) => table
    WholeTable(t) => t
  }
}

///|
/// Whether two resources can contain a common row.
pub fn[K] Resource::overlaps(
  self : Resource[K],
  other : Resource[K],
  cmp : (K, K) -> Int,
) -> Bool {
  match (self, other) {
    (WholeTable(a), r) | (r, WholeTable(a)) => r.table() == a
    (KeyRange(table=t1, index=i1, a), KeyRange(table=t2, index=i2, b)) =>
      // Different indexes of one table may cover the same row; without row
      // identity we must assume they do (conservative: may over-block).
      t1 == t2 && (i1 != i2 || a.overlaps(b, cmp))
    (Key(table=t1, index=i1, a), Key(table=t2, index=i2, b)) =>
      t1 == t2 && (i1 != i2 || cmp(a, b) == 0)
    (Key(table=t1, index=i1, k), KeyRange(table=t2, index=i2, iv))
    | (KeyRange(table=t2, index=i2, iv), Key(table=t1, index=i1, k)) =>
      t1 == t2 && (i1 != i2 || iv.contains(k, cmp))
  }
}

///|
/// True when key `k` lies inside the interval under `cmp`.
fn[K] Interval::contains(
  self : Interval[K],
  k : K,
  cmp : (K, K) -> Int,
) -> Bool {
  let above_lo = match self.lo {
    Unbounded => true
    Inclusive(a) => cmp(a, k) <= 0
    Exclusive(a) => cmp(a, k) < 0
  }
  above_lo &&
  (match self.hi {
    Unbounded => true
    Inclusive(b) => cmp(k, b) <= 0
    Exclusive(b) => cmp(k, b) < 0
  })
}

///|
fn[K] bound_eq(a : Bound[K], b : Bound[K], cmp : (K, K) -> Int) -> Bool {
  match (a, b) {
    (Unbounded, Unbounded) => true
    (Inclusive(x), Inclusive(y)) | (Exclusive(x), Exclusive(y)) =>
      cmp(x, y) == 0
    _ => false
  }
}

///|
/// Structural equality of resources under `cmp`.
pub fn[K] Resource::same(
  self : Resource[K],
  other : Resource[K],
  cmp : (K, K) -> Int,
) -> Bool {
  match (self, other) {
    (WholeTable(a), WholeTable(b)) => a == b
    (KeyRange(table=t1, index=i1, a), KeyRange(table=t2, index=i2, b)) =>
      t1 == t2 &&
      i1 == i2 &&
      bound_eq(a.lo, b.lo, cmp) &&
      bound_eq(a.hi, b.hi, cmp)
    (Key(table=t1, index=i1, a), Key(table=t2, index=i2, b)) =>
      t1 == t2 && i1 == i2 && cmp(a, b) == 0
    // a point range and a key are the same resource (UPDLOCK on a key, then
    // X on the row it reads, is a conversion)
    (Key(table=t1, index=i1, k), KeyRange(table=t2, index=i2, iv))
    | (KeyRange(table=t2, index=i2, iv), Key(table=t1, index=i1, k)) =>
      t1 == t2 &&
      i1 == i2 &&
      (match (iv.lo, iv.hi) {
        (Inclusive(a), Inclusive(b)) => cmp(a, k) == 0 && cmp(b, k) == 0
        _ => false
      })
    _ => false
  }
}
