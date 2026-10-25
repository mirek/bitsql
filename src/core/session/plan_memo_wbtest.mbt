///|
fn memo_step(s : Session, sql : String) -> Unit raise {
  for item in s.run_batch(sql, 0) {
    if item is @reply.Message(m) && m.class >= 11 {
      fail("\{sql}: \{m.message}")
    }
  }
}

///|
fn memo_render(s : Session, sql : String) -> Bytes raise {
  @reply.render(Batch, s.run_batch(sql, 0), "bitsql")
}

///|
/// After every change, the first run (which may find an entry from before
/// the change), a memo hit and a bind without the memo answer alike.
fn memo_equivalent(
  s : Session,
  queries : Array[String],
  steps : Array[String],
) -> Unit raise {
  for step in steps {
    memo_step(s, step)
    for q in queries {
      let first = memo_render(s, q)
      let again = memo_render(s, q)
      s.plan_memo.clear()
      let fresh = memo_render(s, q)
      assert_eq(first, fresh, msg="\{q} after \{step}")
      assert_eq(again, fresh, msg="\{q} (memo) after \{step}")
    }
  }
}

///|
test "remembered plans follow catalog and session changes" {
  let server = Server::new()
  server.create_database("foo")
  server.create_database("bar")
  let s = Session::new(server, spid=51, database="foo", seed=1)
  memo_step(
    s, "USE bar; CREATE TABLE t(z varchar(9)); INSERT t VALUES('bar'); USE foo",
  )
  let queries = [
    "SELECT * FROM t", "SELECT a + 1 AS x, b FROM t WHERE a > 0 ORDER BY b", "SELECT COUNT(*), MAX(b) FROM t",
    "SELECT a FROM dbo.t WHERE a IN (SELECT a FROM t)",
  ]
  memo_equivalent(s, queries, [
    "CREATE TABLE t(a int IDENTITY PRIMARY KEY, b int); INSERT t(b) VALUES(1),(2)",
    "INSERT t(b) VALUES(3)", "ALTER TABLE t ADD c nvarchar(3)", "EXEC sp_rename 't.b', 'bb', 'COLUMN'; EXEC sp_rename 't.bb', 'b', 'COLUMN'",
    "SET IDENTITY_INSERT t ON", "SET IDENTITY_INSERT t OFF", "SET CONCAT_NULL_YIELDS_NULL OFF",
    "SET CONCAT_NULL_YIELDS_NULL ON", "SET ANSI_NULLS OFF", "SET ANSI_NULLS ON",
    "ALTER TABLE t ALTER COLUMN b bigint", "DROP TABLE t; CREATE TABLE t(a tinyint, b nvarchar(5)); INSERT t VALUES(1, N'x')",
  ])
  assert_true(!s.plan_memo.is_empty())
}

///|
test "remembered plans follow the database, synonyms and disabled indexes" {
  let server = Server::new()
  server.create_database("foo")
  server.create_database("bar")
  let s = Session::new(server, spid=51, database="foo", seed=1)
  memo_step(
    s, "CREATE TABLE t(a int PRIMARY KEY, b int); INSERT t VALUES(1, 1)",
  )
  memo_step(
    s, "USE bar; CREATE TABLE t(a nvarchar(4), b bit); INSERT t VALUES(N'b', 1); USE foo",
  )
  memo_equivalent(s, ["SELECT a, b FROM t"], [
    "USE bar", "USE foo", "ALTER DATABASE foo COLLATE Latin1_General_CS_AS", "CREATE TABLE u(a datetime2, b float); EXEC sp_rename 't', 'old'; CREATE SYNONYM t FOR u",
    "DROP SYNONYM t; EXEC sp_rename 'old', 't'",
  ])
  memo_step(s, "CREATE INDEX ix ON t(b)")
  memo_equivalent(
    s,
    [
      "SELECT a, b FROM t WHERE b = 1", "SELECT a FROM t WITH (INDEX(ix)) WHERE b = 1",
    ],
    [
      "ALTER INDEX ix ON t DISABLE", "ALTER INDEX ix ON t REBUILD", "DROP INDEX ix ON t",
      "CREATE INDEX ix ON t(b)", "ALTER INDEX ALL ON t DISABLE", "ALTER INDEX ALL ON t REBUILD",
    ],
  )
}
