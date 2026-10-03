///|
fn cmp_int(a : Int, b : Int) -> Int {
  a.compare(b)
}

///|
fn key(k : Int) -> @sched.Resource[Int] {
  KeyRange(table=1, index=1, @sched.Interval::point(k))
}

///|
fn range(lo : Int, hi : Int) -> @sched.Resource[Int] {
  KeyRange(table=1, index=1, { lo: Inclusive(lo), hi: Inclusive(hi), })
}

///|
test "compatibility matrix" {
  let modes : Array[@sched.LockMode] = [S, U, X]
  let rows = modes.map(a => {
    modes.map(b => if @sched.compatible(a, b) { 1 } else { 0 })
  })
  assert_eq(rows, [[1, 1, 0], [1, 0, 0], [0, 0, 0]])
}

///|
test "interval overlap respects exclusive bounds" {
  let a : @sched.Interval[Int] = { lo: Inclusive(1), hi: Exclusive(5), }
  let b : @sched.Interval[Int] = { lo: Inclusive(5), hi: Unbounded, }
  let c : @sched.Interval[Int] = { lo: Exclusive(4), hi: Inclusive(5), }
  assert_false(a.overlaps(b, cmp_int))
  assert_true(b.overlaps(c, cmp_int))
  assert_true(a.overlaps(@sched.Interval::all(), cmp_int))
}

///|
test "S/U/X blocking and wake on release" {
  let m = @sched.LockManager::new(cmp_int)
  assert_eq(m.request(1, key(5), S, Transaction), Granted)
  assert_eq(m.request(2, key(5), U, Transaction), Granted) // S-U compatible
  assert_eq(m.request(3, key(5), U, Transaction), Waiting(request=1)) // U-U conflict
  assert_eq(m.request(4, key(6), X, Transaction), Granted) // other key
  assert_eq(m.release_all(1), [])
  assert_eq(m.release_all(2), [(3, 1)])
  assert_eq(m.held(3), 1)
}

///|
test "insert into a HOLDLOCK range waits (upsert pattern)" {
  let m = @sched.LockManager::new(cmp_int)
  // session 1: SELECT ... WITH (UPDLOCK, HOLDLOCK) WHERE k = 10 (absent key)
  assert_eq(m.request(1, key(10), U, Transaction), Granted)
  // session 2 runs the same check and must block, not both insert
  assert_eq(m.request(2, key(10), U, Transaction), Waiting(request=1))
  // session 1 inserts k=10 (U -> X upgrade on its own lock)
  assert_eq(m.request(1, key(10), X, Transaction), Granted)
  assert_eq(m.release_all(1), [(2, 1)])
  // a range scan lock blocks inserts anywhere inside it
  assert_eq(m.request(3, range(20, 30), S, Transaction), Granted)
  assert_eq(m.request(4, key(25), X, Transaction), Waiting(request=2))
  assert_eq(m.request(4, key(31), X, Transaction), Granted)
}

///|
test "whole-table lock conflicts with any key on the table" {
  let m = @sched.LockManager::new(cmp_int)
  assert_eq(m.request(1, WholeTable(1), S, Transaction), Granted)
  assert_eq(m.request(2, key(1), X, Transaction), Waiting(request=1))
  assert_eq(
    m.request(
      2,
      KeyRange(table=2, index=1, @sched.Interval::point(1)),
      X,
      Transaction,
    ),
    Granted,
  )
}

///|
test "FIFO: a reader queues behind a waiting writer" {
  let m = @sched.LockManager::new(cmp_int)
  assert_eq(m.request(1, key(1), S, Transaction), Granted)
  assert_eq(m.request(2, key(1), X, Transaction), Waiting(request=1))
  assert_eq(m.request(3, key(1), S, Transaction), Waiting(request=2))
  assert_eq(m.release_all(1), [(2, 1)])
  assert_eq(m.release_all(2), [(3, 2)])
}

///|
test "HOLDLOCK without UPDLOCK deadlocks; cheapest session is the victim" {
  let costs = Map::from_array([(1, 10L), (2, 5L)])
  let m = @sched.LockManager::new(cmp_int, cost=s => costs.get(s).unwrap_or(0L))
  // both read the key with HOLDLOCK (S), then both try to write it
  assert_eq(m.request(1, key(7), S, Transaction), Granted)
  assert_eq(m.request(2, key(7), S, Transaction), Granted)
  assert_eq(m.request(1, key(7), X, Transaction), Waiting(request=1))
  // session 2 closes the cycle; it is cheaper, so it is the victim
  assert_eq(
    m.request(2, key(7), X, Transaction),
    Deadlock(victim=2, request=None),
  )
  // engine rolls back the victim: session 1 proceeds
  assert_eq(m.release_all(2), [(1, 1)])
}

///|
test "deadlock victim may be the other session" {
  let costs = Map::from_array([(1, 1L), (2, 100L)])
  let m = @sched.LockManager::new(cmp_int, cost=s => costs.get(s).unwrap_or(0L))
  assert_eq(m.request(1, key(1), X, Transaction), Granted)
  assert_eq(m.request(2, key(2), X, Transaction), Granted)
  assert_eq(m.request(1, key(2), X, Transaction), Waiting(request=1))
  assert_eq(
    m.request(2, key(1), X, Transaction),
    Deadlock(victim=1, request=Some(2)),
  )
  assert_eq(m.release_all(1), [(2, 2)])
}

///|
test "statement-duration locks release at statement end" {
  let m = @sched.LockManager::new(cmp_int)
  assert_eq(m.request(1, key(1), S, Statement), Granted) // FK check
  assert_eq(m.request(1, key(2), X, Transaction), Granted)
  assert_eq(m.request(2, key(1), X, Transaction), Waiting(request=1))
  assert_eq(m.release_statement(1), [(2, 1)])
  assert_eq(m.held(1), 1)
  // cancel a pending request (lock timeout)
  assert_eq(m.request(3, key(2), S, Transaction), Waiting(request=2))
  assert_eq(m.cancel(2), [])
}
