///|
fn icmp(a : Int, b : Int) -> Int {
  a.compare(b)
}

///|
test "add/get/remove keep order and invariants; old versions unchanged" {
  let mut m : @store.PMap[Int, String] = @store.PMap::empty(icmp)
  let versions = []
  // deterministic pseudo-random order
  let mut x = 7
  for _ in 0..<500 {
    x = (x * 1103515245 + 12345) & 0x7fffffff
    m = m.add(x % 1000, "v\{x % 1000}")
    versions.push(m)
  }
  assert_true(m.check_invariants())
  let keys = m.iter().map(kv => kv.0).collect()
  let sorted = keys.copy()
  sorted.sort()
  assert_eq(keys, sorted)
  let n = m.size()
  let first = versions[0]
  assert_eq(first.size(), 1)
  // remove every other key
  let mut r = m
  for i, k in keys {
    if i % 2 == 0 {
      r = r.remove(k)
    }
  }
  assert_true(r.check_invariants())
  assert_eq(r.size(), n / 2)
  assert_eq(m.size(), n) // persistent: original untouched
  assert_eq(r.get(keys[1]), Some("v\{keys[1]}"))
  assert_eq(r.get(keys[0]), None)
}

///|
test "range seeks with inclusive/exclusive bounds" {
  let mut m : @store.PMap[Int, Int] = @store.PMap::empty(icmp)
  for i in 0..<20 {
    m = m.add(i * 2, i)
  }
  let ks = (it : Iter[(Int, Int)]) => it.map(kv => kv.0).collect()
  assert_eq(ks(m.range(lo=4, hi=10)), [4, 6, 8, 10])
  assert_eq(ks(m.range(lo=4, hi=10, lo_incl=false, hi_incl=false)), [6, 8])
  assert_eq(ks(m.range(lo=35)), [36, 38])
  assert_eq(ks(m.range(hi=3)), [0, 2])
  assert_eq(ks(m.range(lo=5, hi=5)), [])
  assert_eq(m.min(), Some((0, 0)))
  assert_eq(m.max(), Some((38, 19)))
}

///|
test "custom comparator: case-insensitive keys collide" {
  let ci = (a : String, b : String) => a.to_lower().compare(b.to_lower())
  let m = @store.PMap::empty(ci).add("Alice", 1).add("ALICE", 2)
  assert_eq(m.size(), 1)
  assert_eq(m.get("alice"), Some(2))
}

///|
test "retain and from_sorted rebuild balanced maps" {
  for n in [0, 1, 2, 3, 7, 100, 1000] {
    let m = @store.PMap::from_sorted(Array::makei(n, i => (i, i * 2)), icmp)
    assert_true(m.check_invariants())
    assert_eq(m.size(), n)
    let odd = m.retain((k, _) => k % 3 != 0)
    assert_true(odd.check_invariants())
    assert_eq(
      odd.iter().collect(),
      m.iter().filter(kv => kv.0 % 3 != 0).collect(),
    )
    // still a working map: later adds and removes keep the invariants
    let more = odd.add(n + 5, 0).remove(1)
    assert_true(more.check_invariants())
    assert_eq(m.size(), n)
  }
}

///|
test "add_all equals repeated add" {
  let mut x = 11
  for size in [0, 10, 100, 1000] {
    let mut base : @store.PMap[Int, Int] = @store.PMap::empty(icmp)
    for i in 0..<size {
      base = base.add(i * 3, i)
    }
    for m in [5, 70, 300, 2000] {
      let entries = []
      for k in 0..<m {
        x = (x * 1103515245 + 12345) & 0x7fffffff
        entries.push((x % (4 * size + 50), k))
      }
      let mut expected = base
      for e in entries {
        expected = expected.add(e.0, e.1)
      }
      let got = base.add_all(entries)
      assert_true(got.check_invariants())
      assert_eq(got.iter().collect(), expected.iter().collect())
    }
  }
}
