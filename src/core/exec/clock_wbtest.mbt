///|
test "request replay reuses evaluated clocks and advances only at new evaluations" {
  let rt = Runtime::new(database="master", spid=51, now=10, seed=42)
  rt.begin_attempt(false)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.clock_reads.length(), 1)
  rt.now = 20
  rt.begin_attempt(true)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.read_clock(), 20)
  rt.now = 30
  rt.begin_attempt(true)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.read_clock(), 10)
  assert_eq(rt.read_clock(), 20)
  assert_eq(rt.read_clock(), 30)
  rt.finish_attempt()
  rt.now = 40
  assert_eq(rt.read_clock(), 40)
  rt.begin_attempt(false)
  assert_eq(rt.read_clock(), 40)
}
