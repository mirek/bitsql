///|
/// Persistent (immutable) ordered map with an explicit comparator: the
/// storage primitive for tables and indexes. Every update returns a new map
/// sharing structure with the old one, so snapshots and rollback are pointer
/// swaps. AVL-balanced; O(log n) get/insert/remove.
///
/// The comparator is explicit (not a `Compare` impl) because index keys
/// compare under column collations: 'a' and 'A' are the same key under CI.
enum Node[K, V] {
  Leaf
  Node(Node[K, V], K, V, Node[K, V], Int, Int) // left, key, value, right, height, size
}

///|
pub struct PMap[K, V] {
  priv root : Node[K, V]
  priv cmp : (K, K) -> Int
}

///|
pub fn[K, V] PMap::empty(cmp : (K, K) -> Int) -> PMap[K, V] {
  { root: Leaf, cmp, }
}

///|
fn[K, V] height(n : Node[K, V]) -> Int {
  match n {
    Leaf => 0
    Node(_, _, _, _, h, _) => h
  }
}

///|
fn[K, V] size(n : Node[K, V]) -> Int {
  match n {
    Leaf => 0
    Node(_, _, _, _, _, s) => s
  }
}

///|
fn[K, V] mk(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  Node(
    l,
    k,
    v,
    r,
    1 + @cmp.maximum(height(l), height(r)),
    size(l) + size(r) + 1,
  )
}

///|
fn[K, V] balance(l : Node[K, V], k : K, v : V, r : Node[K, V]) -> Node[K, V] {
  let hl = height(l)
  let hr = height(r)
  if hl > hr + 1 {
    guard l is Node(ll, lk, lv, lr, _, _) else { mk(l, k, v, r) }
    if height(ll) >= height(lr) {
      mk(ll, lk, lv, mk(lr, k, v, r))
    } else {
      guard lr is Node(lrl, lrk, lrv, lrr, _, _) else { mk(l, k, v, r) }
      mk(mk(ll, lk, lv, lrl), lrk, lrv, mk(lrr, k, v, r))
    }
  } else if hr > hl + 1 {
    guard r is Node(rl, rk, rv, rr, _, _) else { mk(l, k, v, r) }
    if height(rr) >= height(rl) {
      mk(mk(l, k, v, rl), rk, rv, rr)
    } else {
      guard rl is Node(rll, rlk, rlv, rlr, _, _) else { mk(l, k, v, r) }
      mk(mk(l, k, v, rll), rlk, rlv, mk(rlr, rk, rv, rr))
    }
  } else {
    mk(l, k, v, r)
  }
}

///|
pub fn[K, V] PMap::size(self : PMap[K, V]) -> Int {
  size(self.root)
}

///|
pub fn[K, V] PMap::is_empty(self : PMap[K, V]) -> Bool {
  self.root is Leaf
}

///|
pub fn[K, V] PMap::get(self : PMap[K, V], key : K) -> V? {
  for n = self.root {
    match n {
      Leaf => break None
      Node(l, k, v, r, _, _) => {
        let c = (self.cmp)(key, k)
        if c == 0 {
          break Some(v)
        } else if c < 0 {
          continue l
        } else {
          continue r
        }
      }
    }
  }
}

///|
pub fn[K, V] PMap::contains(self : PMap[K, V], key : K) -> Bool {
  self.get(key) is Some(_)
}

///|
/// Inserts or replaces.
pub fn[K, V] PMap::add(self : PMap[K, V], key : K, value : V) -> PMap[K, V] {
  let cmp = self.cmp
  fn go(n : Node[K, V]) -> Node[K, V] {
    match n {
      Leaf => mk(Leaf, key, value, Leaf)
      Node(l, k, v, r, _, _) => {
        let c = cmp(key, k)
        if c == 0 {
          mk(l, key, value, r)
        } else if c < 0 {
          balance(go(l), k, v, r)
        } else {
          balance(l, k, v, go(r))
        }
      }
    }
  }

  { root: go(self.root), cmp, }
}

///|
fn[K, V] pop_min(n : Node[K, V]) -> (K, V, Node[K, V])? {
  match n {
    Leaf => None
    Node(Leaf, k, v, r, _, _) => Some((k, v, r))
    Node(l, k, v, r, _, _) =>
      match pop_min(l) {
        Some((mk_, mv, rest)) => Some((mk_, mv, balance(rest, k, v, r)))
        None => None
      }
  }
}

///|
pub fn[K, V] PMap::remove(self : PMap[K, V], key : K) -> PMap[K, V] {
  let cmp = self.cmp
  fn go(n : Node[K, V]) -> Node[K, V] {
    match n {
      Leaf => Leaf
      Node(l, k, v, r, _, _) => {
        let c = cmp(key, k)
        if c < 0 {
          balance(go(l), k, v, r)
        } else if c > 0 {
          balance(l, k, v, go(r))
        } else {
          match pop_min(r) {
            None => l
            Some((sk, sv, rest)) => balance(l, sk, sv, rest)
          }
        }
      }
    }
  }

  { root: go(self.root), cmp, }
}

///|
/// In-order iteration over keys within the given bounds (None = unbounded).
/// `lo_incl` / `hi_incl` choose inclusive vs exclusive ends. This is the
/// index seek primitive.
pub fn[K, V] PMap::range(
  self : PMap[K, V],
  lo? : K,
  hi? : K,
  lo_incl? : Bool = true,
  hi_incl? : Bool = true,
) -> Iter[(K, V)] {
  let cmp = self.cmp
  fn above_lo(k : K) -> Bool {
    match lo {
      None => true
      Some(b) => {
        let c = cmp(k, b)
        c > 0 || (c == 0 && lo_incl)
      }
    }
  }

  fn below_hi(k : K) -> Bool {
    match hi {
      None => true
      Some(b) => {
        let c = cmp(k, b)
        c < 0 || (c == 0 && hi_incl)
      }
    }
  }

  // Explicit stack walk, pruning subtrees outside the bounds.
  let out = []
  fn walk(n : Node[K, V]) -> Unit {
    match n {
      Leaf => ()
      Node(l, k, v, r, _, _) => {
        let a = above_lo(k)
        let b = below_hi(k)
        if a {
          walk(l)
        }
        if a && b {
          out.push((k, v))
        }
        if b {
          walk(r)
        }
      }
    }
  }

  walk(self.root)
  out.iter()
}

///|
pub fn[K, V] PMap::iter(self : PMap[K, V]) -> Iter[(K, V)] {
  self.range()
}

///|
pub fn[K, V] PMap::min(self : PMap[K, V]) -> (K, V)? {
  for n = self.root {
    match n {
      Leaf => break None
      Node(Leaf, k, v, _, _, _) => break Some((k, v))
      Node(l, _, _, _, _, _) => continue l
    }
  }
}

///|
pub fn[K, V] PMap::max(self : PMap[K, V]) -> (K, V)? {
  for n = self.root {
    match n {
      Leaf => break None
      Node(_, k, v, Leaf, _, _) => break Some((k, v))
      Node(_, _, _, r, _, _) => continue r
    }
  }
}

///|
/// AVL invariant check (tests).
pub fn[K, V] PMap::check_invariants(self : PMap[K, V]) -> Bool {
  fn ok(n : Node[K, V]) -> Bool {
    match n {
      Leaf => true
      Node(l, _, _, r, h, s) =>
        ok(l) &&
        ok(r) &&
        (height(l) - height(r)).abs() <= 1 &&
        h == 1 + @cmp.maximum(height(l), height(r)) &&
        s == size(l) + size(r) + 1
    }
  }

  ok(self.root)
}

///|
/// A balanced map of entries already sorted by `cmp` with distinct keys,
/// built in O(n) (bulk rebuilds after large deletes).
pub fn[K, V] PMap::from_sorted(
  entries : Array[(K, V)],
  cmp : (K, K) -> Int,
) -> PMap[K, V] {
  fn build(lo : Int, hi : Int) -> Node[K, V] {
    if lo >= hi {
      return Leaf
    }
    let mid = lo + (hi - lo) / 2
    let (k, v) = entries[mid]
    mk(build(lo, mid), k, v, build(mid + 1, hi))
  }

  { root: build(0, entries.length()), cmp, }
}

///|
/// The entries for which `keep` holds, rebuilt in O(n).
pub fn[K, V] PMap::retain(
  self : PMap[K, V],
  keep : (K, V) -> Bool,
) -> PMap[K, V] {
  let out = []
  fn walk(n : Node[K, V]) -> Unit {
    match n {
      Leaf => ()
      Node(l, k, v, r, _, _) => {
        walk(l)
        if keep(k, v) {
          out.push((k, v))
        }
        walk(r)
      }
    }
  }

  walk(self.root)
  PMap::from_sorted(out, self.cmp)
}

///|
/// `add` of every entry in order (a later entry replaces an earlier one
/// with an equal key, as do entries replacing existing keys). Many entries
/// relative to the map are merged in one O(n + m log m) rebuild.
pub fn[K, V] PMap::add_all(
  self : PMap[K, V],
  entries : Array[(K, V)],
) -> PMap[K, V] {
  let m = entries.length()
  if m < 64 || m * 8 < self.size() {
    let mut out = self
    for e in entries {
      out = out.add(e.0, e.1)
    }
    return out
  }
  let cmp = self.cmp
  // sort positions by key, ties by position; keep the last of equal keys
  let order = Array::makei(m, i => i)
  order.sort_by((x, y) => {
    let c = cmp(entries[x].0, entries[y].0)
    if c != 0 {
      c
    } else {
      x.compare(y)
    }
  })
  let fresh = []
  for k, i in order {
    if k + 1 < m && cmp(entries[i].0, entries[order[k + 1]].0) == 0 {
      continue
    }
    fresh.push(entries[i])
  }
  let old = self.iter().collect()
  let merged = []
  let mut i = 0
  let mut j = 0
  while i < old.length() || j < fresh.length() {
    if j >= fresh.length() {
      merged.push(old[i])
      i += 1
    } else if i >= old.length() {
      merged.push(fresh[j])
      j += 1
    } else {
      let c = cmp(old[i].0, fresh[j].0)
      if c < 0 {
        merged.push(old[i])
        i += 1
      } else {
        // an equal key takes the new entry (as `add` replaces it)
        merged.push(fresh[j])
        j += 1
        if c == 0 {
          i += 1
        }
      }
    }
  }
  PMap::from_sorted(merged, cmp)
}
