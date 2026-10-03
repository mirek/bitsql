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
