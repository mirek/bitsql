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

///|
test "cascading referential actions fire child triggers, deepest first" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE lg (seq int IDENTITY, w varchar(20));\nCREATE TABLE p (id int PRIMARY KEY);\nCREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE);\nCREATE TABLE g (id int PRIMARY KEY, cid int REFERENCES c(id) ON DELETE SET NULL);\nINSERT p VALUES (1), (2);\nINSERT c VALUES (1, 1), (2, 1);\nINSERT g VALUES (1, 1), (2, 2), (3, NULL);",
      0,
    ),
  )
  for
    t in [
      "CREATE TRIGGER tp ON p AFTER DELETE AS INSERT lg SELECT CONCAT('p', @@ROWCOUNT)",
      "CREATE TRIGGER tc ON c AFTER DELETE AS INSERT lg SELECT CONCAT('c', @@ROWCOUNT, (SELECT COUNT(*) FROM deleted))",
      "CREATE TRIGGER tg ON g AFTER UPDATE AS INSERT lg SELECT CONCAT('g', @@ROWCOUNT, TRIGGER_NESTLEVEL(), IIF(UPDATE(cid), 'u', '-'))",
    ] {
    ignore(s.run_batch(t, 0))
  }
  ignore(s.run_batch("DELETE p WHERE id IN (1, 2)", 0))
  let after = s.run_batch(
    "SELECT w FROM lg ORDER BY seq; SELECT COUNT(*) FROM g WHERE cid IS NULL", 0,
  )
  assert_eq(row_values(after), [
    [Text("g21u")],
    [Text("c22")],
    [Text("p2")],
    [Int(3)],
  ])
}

///|
test "an error in a cascaded child trigger undoes the whole statement" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE p (id int PRIMARY KEY);\nCREATE TABLE c (id int PRIMARY KEY, pid int REFERENCES p(id) ON DELETE CASCADE);\nINSERT p VALUES (1);\nINSERT c VALUES (1, 1);",
      0,
    ),
  )
  ignore(
    s.run_batch(
      "CREATE TRIGGER tc ON c AFTER DELETE AS THROW 50001, 'no', 1", 0,
    ),
  )
  assert_eq(messages(s.run_batch("DELETE p", 0)), [50001])
  let after = s.run_batch(
    "SELECT COUNT(*) FROM p; SELECT COUNT(*) FROM c; SELECT @@TRANCOUNT", 0,
  )
  assert_eq(row_values(after), [[Int(1)], [Int(1)], [Int(0)]])
  // INSTEAD OF DELETE conflicts with ON DELETE CASCADE (2113)
  assert_eq(
    messages(
      s.run_batch("CREATE TRIGGER io ON c INSTEAD OF DELETE AS SELECT 1", 0),
    ),
    [2113],
  )
}
