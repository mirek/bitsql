///|
/// Per-request shortcuts (session/parse_cache.mbt, prebind.mbt reuse of
/// the first query's plan, dml_run.mbt WHERE seek) must not outlive the
/// state they were computed under.
fn cache_session() -> @session.Session {
  @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
}

///|
test "a repeated text binds against the current catalog" {
  let s = cache_session()
  ignore(s.run_batch("CREATE TABLE rc (c int); INSERT rc VALUES (1)", 0))
  let q = "SELECT c FROM rc"
  assert_eq(row_values(s.run_batch(q, 0)), [[Int(1)]])
  ignore(
    s.run_batch(
      "DROP TABLE rc; CREATE TABLE rc (c nvarchar(5)); INSERT rc VALUES (N'x')",
      0,
    ),
  )
  assert_eq(row_values(s.run_batch(q, 0)), [[Text("x")]])
  ignore(s.run_batch("DROP TABLE rc", 0))
  assert_eq(messages(s.run_batch(q, 0)), [208])
  // a compile-time type error of the first statement still ends the batch
  // before anything runs
  ignore(s.run_batch("CREATE TABLE rc (c int)", 0))
  let r = s.run_batch(
    "SELECT c FROM rc WHERE c + CAST('2020-01-01' AS date) = 1; PRINT 'x'", 0,
  )
  debug_inspect(
    messages(r),
    content=(
      #|[206]
    ),
  )
}

///|
test "first-query plan reuse inside a transaction" {
  let s = cache_session()
  ignore(s.run_batch("CREATE TABLE rt (id int PRIMARY KEY, v int)", 0))
  ignore(s.run_batch("BEGIN TRAN; INSERT rt VALUES (1, 10)", 0))
  assert_eq(row_values(s.run_batch("SELECT v FROM rt", 0)), [[Int(10)]])
  ignore(s.run_batch("ROLLBACK", 0))
  assert_eq(row_values(s.run_batch("SELECT v FROM rt", 0)), [])
}

///|
test "UPDATE/DELETE with a seekable WHERE match the scan" {
  let s = cache_session()
  ignore(
    s.run_batch(
      "CREATE TABLE ru (id int PRIMARY KEY, n int); INSERT ru VALUES (1, 1), (2, 2), (3, 3)",
      0,
    ),
  )
  ignore(
    s.run_batch(
      "DECLARE @i int = 2; UPDATE ru SET n = n + 10 WHERE id = @i; DELETE ru WHERE id = 3 AND n = 3",
      0,
    ),
  )
  assert_eq(row_values(s.run_batch("SELECT id, n FROM ru ORDER BY id", 0)), [
    [Int(1), Int(1)],
    [Int(2), Int(12)],
  ])
  // a WHERE that can fail keeps the row-by-row scan: id 1 divides by zero
  let r = s.run_batch(
    "UPDATE ru SET n = 0 WHERE 1 / (id - 1) = 1 AND id = 2", 0,
  )
  debug_inspect(
    messages(r),
    content=(
      #|[8134, 3621]
    ),
  )
  assert_eq(row_values(s.run_batch("SELECT n FROM ru WHERE id = 2", 0)), [
    [Int(12)],
  ])
}
