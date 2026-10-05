///|
test "IntTable agrees with Map over inserts, overwrites and growth" {
  let t = IntTable::new(0)
  let m : Map[Int64, Int] = Map([])
  let mut x = 12345L
  for i in 0..<20000 {
    // LCG keys: repeats, negatives and extremes
    x = x * 6364136223846793005L + 1442695040888963407L
    let k = match i % 5 {
      0 => x
      1 => x % 100L
      2 => -9223372036854775808L
      3 => 9223372036854775807L
      _ => (i / 3).to_int64()
    }
    t.set(k, i)
    m[k] = i
  }
  for k, v in m {
    assert_eq(t.get(k), v)
  }
  assert_eq(t.size, m.length())
  assert_eq(t.get(424242424242L), -1)
}
