///|
test "ROLLBACK in a trigger aborts the batch with 3609 and undoes the statement" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(s.run_batch("CREATE TABLE rb (id int PRIMARY KEY)", 0))
  ignore(
    s.run_batch(
      "CREATE TRIGGER trg_rb ON rb AFTER INSERT AS\nBEGIN\n  IF EXISTS (SELECT 1 FROM inserted WHERE id < 0)\n  BEGIN\n    RAISERROR('negative', 16, 1);\n    ROLLBACK TRANSACTION;\n  END\nEND",
      0,
    ),
  )
  let items = s.run_batch(
    "INSERT INTO rb VALUES (1);\nINSERT INTO rb VALUES (-1);\nSELECT 'not reached' AS r;",
    0,
  )
  assert_eq(messages(items), [50000, 3609])
  // the second INSERT was undone; the transaction is gone
  let after = s.run_batch("SELECT COUNT(*) FROM rb; SELECT @@TRANCOUNT", 0)
  assert_eq(row_values(after), [[Int(1)], [Int(0)]])
}
