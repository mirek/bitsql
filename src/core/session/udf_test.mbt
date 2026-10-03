///|
/// User-defined functions end to end (expected values from the captures in
/// harness/corpus/udf/*).
fn udf_session() -> @session.Session {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  for
    b in [
      "CREATE TABLE t (id int NOT NULL PRIMARY KEY, a int NULL); INSERT INTO t VALUES (1, 10), (2, NULL), (3, 30)",
      "CREATE FUNCTION dbo.fact (@n int) RETURNS bigint AS BEGIN IF @n <= 1 RETURN 1; RETURN @n * dbo.fact(@n - 1); END",
      "CREATE FUNCTION dbo.big (@min int) RETURNS TABLE AS RETURN SELECT id, a FROM dbo.t WHERE id >= @min",
      "CREATE FUNCTION dbo.ms (@n int) RETURNS @r TABLE (k int NOT NULL PRIMARY KEY) AS BEGIN DECLARE @i int = 1; WHILE @i <= @n BEGIN INSERT INTO @r VALUES (@i); SET @i += 1; END RETURN END",
    ] {
    ignore(s.run_batch(b, 0))
  }
  s
}

///|
test "scalar, inline and multi-statement functions" {
  let s = udf_session()
  let r = s.run_batch(
    "SELECT dbo.fact(5) AS f, (SELECT COUNT(*) FROM dbo.big(2)) AS b, (SELECT SUM(k) FROM dbo.ms(4)) AS m",
    0,
  )
  assert_eq(row_values(r), [[Int(120L), Int(2L), Int(10L)]])
  let applied = s.run_batch(
    "SELECT t.id, m.k FROM t CROSS APPLY dbo.ms(t.id) AS m ORDER BY t.id, m.k", 0,
  )
  assert_eq(row_values(applied).length(), 6)
}

///|
test "nesting limit 217 and CREATE FUNCTION side effects 443" {
  let s = udf_session()
  assert_eq(messages(s.run_batch("SELECT dbo.fact(33)", 0)), [217])
  let bad = s.run_batch(
    "CREATE FUNCTION dbo.p () RETURNS int AS BEGIN PRINT 1; RETURN 1 END", 0,
  )
  assert_eq(messages(bad), [443])
}
