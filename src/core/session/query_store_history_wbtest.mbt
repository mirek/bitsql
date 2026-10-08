///|
fn qs_run(s : Session, sql : String, now? : Int64 = 100L) -> Unit raise {
  for item in s.run_batch(sql, now) {
    if item is @reply.Message(m) && m.class >= 11 {
      fail(m.message)
    }
  }
}

///|
fn qs_session() -> Session raise {
  let server = Server::new()
  server.create_database("qs_test")
  let session = Session::new(server, spid=51, database="qs_test", seed=1)
  qs_run(
    session, "ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL); CREATE TABLE dbo.qs_workload(id int NOT NULL); INSERT dbo.qs_workload VALUES (1), (2), (3);",
  )
  session
}

///|
fn qs_selects(s : Session) -> Array[QueryStoreQuery] {
  s.server.query_history("qs_test").queries
  .values()
  .collect()
  .filter(q => q.text.contains("SELECT id"))
}

///|
test "Query Store captures actual successful executions and event timestamps" {
  let s = qs_session()
  qs_run(s, "SELECT id FROM dbo.qs_workload WHERE id > 1;", now=200L)
  qs_run(s, "SELECT id FROM dbo.qs_workload WHERE id > 1;", now=300L)
  let queries = qs_selects(s)
  assert_eq(queries.length(), 1)
  let q = queries[0]
  assert_eq(q.executions, 2L)
  assert_eq(q.total_rows, 4L)
  assert_eq((q.min_rows, q.max_rows, q.last_rows), (2L, 2L, 2L))
  assert_eq((q.first_time, q.last_time), (200L, 300L))
  assert_eq(q.object_id, 0)
  assert_eq(
    s.server.query_history("qs_test").texts.get(q.text),
    Some(q.text_id),
  )
  assert_eq(
    s.server.query_history("qs_test").keys.get((q.text, q.object_id, q.context)),
    Some(q.id),
  )
}

///|
test "Query Store procedure row counts agree with the oracle workload capture" {
  let s = qs_session()
  qs_run(
    s, "CREATE PROCEDURE dbo.qs_proc @min int AS SELECT id FROM dbo.qs_workload WHERE id > @min ORDER BY id;",
  )
  qs_run(s, "EXEC dbo.qs_proc @min = 1;")
  qs_run(s, "EXEC dbo.qs_proc @min = 2;")
  let queries = qs_selects(s)
  assert_eq(queries.length(), 1)
  let q = queries[0]
  assert_eq(q.object_id, s.db_of(0).lookup("dbo", "qs_proc").unwrap())
  assert_eq(q.executions, 2L)
  assert_eq(q.total_rows.to_double() / q.executions.to_double(), 1.5)
  assert_eq((q.min_rows, q.max_rows), (1L, 2L))
}

///|
test "Query Store READ_ONLY and OFF retain counts; CLEAR discards history" {
  let s = qs_session()
  qs_run(s, "SELECT id FROM dbo.qs_workload;")
  qs_run(
    s, "ALTER DATABASE CURRENT SET QUERY_STORE (OPERATION_MODE = READ_ONLY);",
  )
  qs_run(s, "SELECT id FROM dbo.qs_workload;")
  qs_run(s, "ALTER DATABASE CURRENT SET QUERY_STORE = OFF;")
  qs_run(s, "SELECT id FROM dbo.qs_workload;")
  assert_eq(qs_selects(s)[0].executions, 1L)
  qs_run(s, "ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;")
  assert_eq(qs_selects(s).length(), 0)
}

///|
test "Query Store history survives data rollback and is isolated by database" {
  let s = qs_session()
  qs_run(s, "BEGIN TRANSACTION; SELECT id FROM dbo.qs_workload; ROLLBACK;")
  assert_eq(qs_selects(s)[0].executions, 1L)
  s.server.create_database("other_qs")
  let other = Session::new(s.server, spid=52, database="other_qs", seed=1)
  qs_run(
    other, "ALTER DATABASE CURRENT SET QUERY_STORE = ON (QUERY_CAPTURE_MODE = ALL); SELECT 7 AS other_database;",
  )
  assert_eq(s.server.query_history("other_qs").queries.length(), 1)
  assert_eq(qs_selects(s).length(), 1)
}

///|
test "Query Store snapshot copies history rather than sharing mutable containers" {
  let s = qs_session()
  qs_run(s, "SELECT id FROM dbo.qs_workload;")
  let saved = s.server.query_history("qs_test").copy()
  qs_run(s, "SELECT id FROM dbo.qs_workload;")
  let q = qs_selects(s)[0]
  assert_eq(q.executions, 2L)
  assert_eq(saved.queries[q.id].executions, 1L)
}

///|
test "Query Store request replay counts each completed SELECT once" {
  let s = qs_session()
  let sql = "SELECT id FROM dbo.qs_workload; WAITFOR DELAY '00:00:01'; SELECT id FROM dbo.qs_workload;"
  ignore(s.run_batch(sql, 200L))
  assert_true(s.parked)
  assert_eq(qs_selects(s)[0].executions, 1L)
  s.time_out()
  qs_run(s, sql, now=10000200L)
  assert_true(!s.parked)
  assert_eq(qs_selects(s)[0].executions, 2L)
}

///|
test "Query Store CLEAR is not repeated when a later wait replays the batch" {
  let s = qs_session()
  let sql = "SELECT id FROM dbo.qs_workload; ALTER DATABASE CURRENT SET QUERY_STORE CLEAR; SELECT id FROM dbo.qs_workload; WAITFOR DELAY '00:00:01'; SELECT id FROM dbo.qs_workload;"
  ignore(s.run_batch(sql, 200L))
  assert_true(s.parked)
  assert_eq(qs_selects(s)[0].executions, 1L)
  s.time_out()
  qs_run(s, sql, now=10000200L)
  assert_eq(qs_selects(s)[0].executions, 2L)
}
