///|
fn messages(items : Array[@reply.Item]) -> Array[Int] {
  let out = []
  for it in items {
    if it is Message(m) {
      out.push(m.number)
    }
  }
  out
}

///|
test "doomed transaction is rolled back with 3998 at batch end" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(s.run_batch("CREATE TABLE t (id int PRIMARY KEY)", 0))
  let items = s.run_batch(
    "SET XACT_ABORT ON; BEGIN TRAN; INSERT t VALUES (1); BEGIN TRY INSERT t VALUES (1) END TRY BEGIN CATCH SELECT XACT_STATE() AS st, ERROR_NUMBER() AS n END CATCH; SELECT @@TRANCOUNT AS tc",
    0,
  )
  assert_eq(messages(items), [3998])
  let after = s.run_batch("INSERT t VALUES (5); SELECT @@TRANCOUNT", 0)
  assert_eq(messages(after), [])
}

///|
fn row_values(items : Array[@reply.Item]) -> Array[Array[@tds.WireValue]] {
  let out = []
  for it in items {
    if it is Row(v) {
      out.push(v)
    }
  }
  out
}

///|
test "emulator.snapshot / emulator.restore isolate tests" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE seed (id int IDENTITY PRIMARY KEY, v int); INSERT seed (v) VALUES (1)",
      0,
    ),
  )
  ignore(s.run_batch("EXEC emulator.snapshot 'seeded'", 0))
  ignore(
    s.run_batch("INSERT seed (v) VALUES (2); CREATE TABLE extra (x int)", 0),
  )
  ignore(s.run_batch("EXEC emulator.restore 'seeded'", 0))
  let r = s.run_batch(
    "INSERT seed (v) VALUES (3); SELECT id, v FROM seed ORDER BY id", 0,
  )
  // identity counter restored too: the new row gets id 2 again
  assert_eq(row_values(r), [[Int(1), Int(1)], [Int(2), Int(3)]])
  let missing = s.run_batch("SELECT * FROM extra", 0)
  assert_eq(messages(missing), [208])
}
