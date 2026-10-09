///|
/// Drive the pure measurement handshake with deterministic host samples.
fn monitored_run(
  s : Session,
  sql : String,
  now : Int64,
) -> Array[@reply.Item] raise {
  let mut out = s.run_batch(sql, now)
  let mut tick = now
  let mut turns = 0
  while s.is_parked() {
    assert_true(s.needs_sample())
    turns += 1
    assert_true(turns < 128)
    tick += 100000L
    s.sample(tick, 0L)
    out = s.run_batch(sql, tick)
    s.charge_cpu(100L)
  }
  for item in out {
    if item is @reply.Message(m) && m.class >= 11 {
      fail(m.message)
    }
  }
  out
}

///|
test "monitoring samples preserve results and split runtime intervals" {
  let server = Server::new()
  server.create_database("foo")
  let s = Session::new(server, spid=51, database="foo", seed=1)
  let now = 638000000000000000L
  server.enable_monitoring(now, 2, 1024L)
  ignore(
    monitored_run(
      s, "ALTER DATABASE CURRENT SET QUERY_STORE=ON (QUERY_CAPTURE_MODE=ALL,INTERVAL_LENGTH_MINUTES=1); CREATE TABLE t(id int); INSERT t VALUES(1),(2);",
      now,
    ),
  )
  let sql = "SELECT id FROM t"
  let first = monitored_run(s, sql, now)
  let second = monitored_run(s, sql, now + 1200000000L)
  assert_eq(
    @reply.render(Batch, first, "bitsql"),
    @reply.render(Batch, second, "bitsql"),
  )
  let q = server.query_history.values().to_array().filter(q => q.text == sql)[0]
  assert_eq(q.count, 2L)
  assert_eq(q.rows, 4L)
  assert_true(q.duration > 0L)
  assert_eq(q.cpu, 200L)
  let runtime = server.query_runtime
    .values()
    .to_array()
    .filter(r => r.text == sql)
  assert_eq(runtime.length(), 2)
  assert_true(runtime.all(r => r.count == 1L && r.rows == 2L))
  ignore(
    monitored_run(
      s, "ALTER DATABASE CURRENT SET QUERY_STORE=OFF; ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;",
      now,
    ),
  )
  assert_true(server.query_history.is_empty())
  assert_true(server.query_runtime.is_empty())
  assert_true(!server.query_statistics.is_empty())
}

///|
test "index usage survives rollback and missing index advice follows schema" {
  let server = Server::new()
  let s = Session::new(server, spid=51, database="master", seed=1)
  json_index_run(
    s, "CREATE TABLE t(id int PRIMARY KEY,n int); INSERT t VALUES(1,1),(2,2),(3,1); BEGIN TRAN; UPDATE t SET n=3 WHERE id=1; ROLLBACK;",
  )
  let rows : Array[VRow] = []
  server.index_usage_rows(rows)
  assert_eq(rows.length(), 1)
  assert_eq(rows[0]["user_updates"], BigInt(2L))
  json_index_run(s, "SELECT id FROM t WHERE n=1")
  let advice : Array[VRow] = []
  server.missing_index_rows(advice)
  assert_eq(advice.length(), 1)
  json_index_run(s, "ALTER TABLE t DROP COLUMN n")
  let after : Array[VRow] = []
  server.missing_index_rows(after)
  assert_true(after.is_empty())
}

///|
test "logical read observations aggregate cache hits and zero-read statements" {
  let server = Server::new()
  server.create_database("foo")
  let s = Session::new(server, spid=51, database="foo", seed=1)
  let now = 638000000000000000L
  server.enable_monitoring(now, 2, 1024L)
  ignore(
    monitored_run(
      s, "ALTER DATABASE CURRENT SET QUERY_STORE=ON (QUERY_CAPTURE_MODE=ALL,INTERVAL_LENGTH_MINUTES=60); CREATE TABLE t(id int); INSERT t VALUES(1),(2);",
      now,
    ),
  )
  let sql = "SELECT id FROM t"
  ignore(monitored_run(s, sql, now))
  ignore(monitored_run(s, sql, now))
  ignore(monitored_run(s, "SELECT 1 AS no_reads", now))
  let q = server.query_history.values().to_array().filter(q => q.text == sql)[0]
  assert_eq(q.count, 2L)
  assert_eq(q.logical_reads, 2L)
  assert_eq(q.last_logical_reads, 1L)
  assert_eq(q.logical_m2, 0.0)
  let zero = server.query_history
    .values()
    .to_array()
    .filter(q => q.text == "SELECT 1 AS no_reads")[0]
  assert_eq(zero.logical_reads, 0L)
  // Grow past a modeled page and run the same identity, invalidating the
  // materialized source cache without resetting runtime aggregation.
  ignore(
    monitored_run(s, "INSERT t SELECT TOP(2000) 1 FROM sys.all_objects", now),
  )
  ignore(monitored_run(s, sql, now))
  assert_true(q.last_logical_reads > 1L)
  assert_eq(q.min_logical_reads, 1L)
  assert_eq(q.max_logical_reads, q.last_logical_reads)
  assert_eq(q.logical_reads, 2L + q.last_logical_reads)
  assert_true(q.logical_m2 > 0.0)
  let runtime = server.query_runtime
    .values()
    .to_array()
    .filter(q => q.text == sql)[0]
  assert_eq(runtime.logical_reads, q.logical_reads)
  assert_eq(runtime.logical_m2, q.logical_m2)
}

///|
test "plan dbid attributes retain the originating database" {
  let server = Server::new()
  server.create_database("foo")
  server.create_database("bar")
  let now = 638000000000000000L
  server.enable_monitoring(now, 2, 1024L)
  let a = Session::new(server, spid=51, database="foo", seed=1)
  let b = Session::new(server, spid=52, database="bar", seed=1)
  ignore(monitored_run(a, "SELECT 1 AS origin_foo", now))
  ignore(monitored_run(b, "SELECT 2 AS origin_bar", now))
  guard a.system_tvf("dm_exec_plan_attributes", []) is Some((cols, rows)) else {
    fail("TVF")
  }
  assert_eq(cols.length(), 3)
  assert_eq(rows.length(), 2)
  for _, q in server.query_statistics {
    let row = rows.filter(r => r[3] == observation_handle(q.id, 64))[0]
    assert_eq(row[0], String("dbid"))
    assert_eq(
      row[1],
      Variant(Int(server.database_id(q.database).unwrap()), Int),
    )
    assert_eq(row[2], Bit(true))
  }
}
