///|
/// Query-language behaviour end to end (expected values from the captures in
/// harness/corpus/query/*).
fn query_session() -> @session.Session {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE gb (id int NOT NULL, g int NULL, n int NULL); INSERT INTO gb VALUES (1, 1, 10), (2, 1, 20), (3, 2, NULL), (4, NULL, 5)",
      0,
    ),
  )
  s
}

///|
test "GROUP BY with HAVING, ORDER BY on an aggregate and warning 8153" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT g, COUNT(*) AS c, SUM(n) AS s FROM gb GROUP BY g HAVING COUNT(*) >= 1 ORDER BY SUM(n) DESC",
    0,
  )
  assert_eq(row_values(r), [
    [Int(1), Int(2), Int(30)],
    [Null, Int(1), Int(5)],
    [Int(2), Int(1), Null],
  ])
  assert_eq(messages(r), [8153])
  let bad = s.run_batch("SELECT g, n FROM gb GROUP BY g", 0)
  assert_eq(messages(bad), [8120])
}

///|
test "scalar aggregate over empty input returns one row, GROUP BY () none" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT COUNT(*) AS c, SUM(n) AS s FROM gb WHERE id > 100; SELECT COUNT(*) FROM gb WHERE id > 100 GROUP BY ()",
    0,
  )
  assert_eq(row_values(r), [[Int(0), Null]])
}

///|
test "correlated subqueries, NOT IN with NULL, ALL over empty" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT id, (SELECT COUNT(*) FROM gb i WHERE i.g = o.g) AS same_g FROM gb o ORDER BY id",
    0,
  )
  assert_eq(row_values(r), [
    [Int(1), Int(2)],
    [Int(2), Int(2)],
    [Int(3), Int(1)],
    [Int(4), Int(0)],
  ])
  let notin = s.run_batch(
    "SELECT id FROM gb WHERE id NOT IN (SELECT g FROM gb); SELECT id FROM gb WHERE id > ALL (SELECT id FROM gb WHERE id > 100) ORDER BY id",
    0,
  )
  assert_eq(row_values(notin), [[Int(1)], [Int(2)], [Int(3)], [Int(4)]])
  let many = s.run_batch("SELECT (SELECT id FROM gb) AS x", 0)
  assert_eq(messages(many), [512])
}

///|
test "recursive CTE streams rows before 530" {
  let s = query_session()
  let r = s.run_batch(
    "WITH r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 10) SELECT n FROM r OPTION (MAXRECURSION 3)",
    0,
  )
  assert_eq(row_values(r), [[Int(1)], [Int(2)], [Int(3)], [Int(4)]])
  assert_eq(messages(r), [530])
}

///|
test "window functions, set operations and TOP WITH TIES" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT id, ROW_NUMBER() OVER (PARTITION BY g ORDER BY id DESC) AS rn, SUM(n) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING) AS run FROM gb ORDER BY id",
    0,
  )
  assert_eq(row_values(r), [
    [Int(1), Int(2), Int(10)],
    [Int(2), Int(1), Int(30)],
    [Int(3), Int(1), Int(30)],
    [Int(4), Int(1), Int(35)],
  ])
  let u = s.run_batch(
    "SELECT g FROM gb UNION SELECT 3 EXCEPT SELECT 1 ORDER BY g; SELECT TOP 1 WITH TIES g FROM gb WHERE g IS NOT NULL ORDER BY g",
    0,
  )
  assert_eq(row_values(u), [[Null], [Int(2)], [Int(3)], [Int(1)], [Int(1)]])
}

///|
test "STRING_SPLIT with ordinal, OPENJSON over APPLY" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT value, ordinal FROM STRING_SPLIT('x;y', ';', 1); SELECT v.id, j.[value] FROM (VALUES (1, N'[1,2]')) v(id, doc) CROSS APPLY OPENJSON(v.doc) j",
    0,
  )
  assert_eq(row_values(r), [
    [Text("x"), Int(1)],
    [Text("y"), Int(2)],
    [Int(1), Text("1")],
    [Int(1), Text("2")],
  ])
}

///|
test "SELECT INTO and SELECT @v = ... FROM" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT id, n * 2 AS twice INTO copy FROM gb WHERE n IS NOT NULL; DECLARE @s int = 0; SELECT @s = @s + twice FROM copy; SELECT @s AS s",
    0,
  )
  assert_eq(row_values(r), [[Int(70)]])
}

///|
test "SELECT @v = ... FROM a CTE" {
  let s = query_session()
  let r = s.run_batch(
    "DECLARE @n int = 0, @last int; WITH a AS (SELECT n FROM gb WHERE n IS NOT NULL), b AS (SELECT n FROM a) SELECT @n = COUNT(*) FROM b; WITH c AS (SELECT n FROM gb WHERE n IS NOT NULL) SELECT @last = n FROM c ORDER BY n DESC; SELECT @n AS n, @last AS last",
    0,
  )
  assert_eq(row_values(r), [[Int(3), Int(5)]])
}

///|
test "FOR JSON splits text into 2033-character rows" {
  let s = query_session()
  let r = s.run_batch(
    "SELECT REPLICATE(CAST(N'x' AS nvarchar(max)), 5000) AS big FOR JSON PATH", 0,
  )
  let lens = row_values(r).map(row => {
    match row[0] {
      Text(t) => t.length()
      _ => -1
    }
  })
  assert_eq(lens, [2033, 2033, 946])
}

///|
test "long literals are (n)varchar(max) and survive VALUES/UNION unification" {
  // captured: harness/corpus/compat/long-literal-unify (the 0.1.3 compat
  // report stored 4000 of 4060 characters)
  let s = query_session()
  let long = String::make(4060, 'x')
  let r = s.run_batch(
    "SELECT CAST(LEN(v) AS int) FROM (VALUES (N'foo'), (N'\{long}')) s(v) ORDER BY 1; SELECT CAST(LEN(v) AS int) FROM (SELECT N'a' AS v UNION ALL SELECT N'\{long}') u ORDER BY 1",
    0,
  )
  assert_eq(row_values(r), [[Int(3)], [Int(4060)], [Int(1)], [Int(4060)]])
  let ascii = String::make(8001, 'y')
  let r = s.run_batch(
    "SELECT CAST(LEN(v) AS int) FROM (VALUES ('foo'), ('\{ascii}')) s(v) ORDER BY 1",
    0,
  )
  assert_eq(row_values(r), [[Int(3)], [Int(8001)]])
}

///|
test "unique-index seeks return exactly the rows a scan would" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE k (a int NOT NULL, b nvarchar(10) NOT NULL, v int, CONSTRAINT pk_k PRIMARY KEY (a, b), CONSTRAINT uq_v UNIQUE (v)); INSERT k VALUES (1, N'x', 10), (1, N'Y', 20), (2, N'x', NULL)",
      0,
    ),
  )
  let rows = (sql : String) => row_values(s.run_batch(sql, 0))
  // case-insensitive collation and trailing spaces, as `=` compares
  assert_eq(
    rows(
      "DECLARE @b nvarchar(10) = N'y  '; SELECT v FROM k WHERE a = 1 AND b = @b",
    ),
    [[Int(20L)]],
  )
  // NULL key value: no row
  assert_eq(rows("DECLARE @v int; SELECT a FROM k WHERE v = @v"), [])
  // partial composite key: scan
  assert_eq(rows("SELECT COUNT(*) FROM k WHERE a = 1").length(), 1)
  // extra predicate is still applied
  assert_eq(rows("SELECT a FROM k WHERE v = 10 AND a = 2"), [])
  // correlated (outer column) key
  assert_eq(
    rows(
      "SELECT (SELECT k2.b FROM k k2 WHERE k2.v = k1.v) AS b FROM k k1 WHERE k1.a = 1 AND k1.b = N'x'",
    ),
    [[Text("x")]],
  )
}

///|
test "equi-join index gives the nested-loop result and order" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      "CREATE TABLE l (k nvarchar(5), n int); CREATE TABLE r (k nvarchar(5), m int); INSERT l VALUES (N'a', 1), (N'B', 2), (NULL, 3), (N'c', 4); INSERT r VALUES (N'b', 10), (N'A', 20), (N'a', 30), (NULL, 40), (N'b ', 50)",
      0,
    ),
  )
  let rows = (sql : String) => row_values(s.run_batch(sql, 0))
  // CI collation, trailing spaces, duplicates in input order, NULL never matches
  assert_eq(rows("SELECT l.n, r.m FROM l JOIN r ON l.k = r.k"), [
    [Int(1L), Int(20L)],
    [Int(1L), Int(30L)],
    [Int(2L), Int(10L)],
    [Int(2L), Int(50L)],
  ])
  assert_eq(
    rows("SELECT l.n, r.m FROM l LEFT JOIN r ON l.k = r.k AND r.m > 25"),
    [[Int(1L), Int(30L)], [Int(2L), Int(50L)], [Int(3L), Null], [Int(4L), Null]],
  )
  assert_eq(rows("SELECT COUNT(*) FROM l FULL JOIN r ON r.k = l.k"), [[Int(7L)]])
}

///|
test "NEXT VALUE FOR: one value per row, new values per row and statement" {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(s.run_batch("CREATE SEQUENCE dbo.q AS int START WITH 1", 0))
  let rows = (sql : String) => row_values(s.run_batch(sql, 0))
  assert_eq(
    rows(
      "SELECT NEXT VALUE FOR dbo.q, NEXT VALUE FOR dbo.q FROM (VALUES (1), (2)) v(x)",
    ),
    [[Int(1L), Int(1L)], [Int(2L), Int(2L)]],
  )
  assert_eq(
    rows(
      "DECLARE @a int, @b int; SET @a = NEXT VALUE FOR dbo.q; SET @b = NEXT VALUE FOR dbo.q; SELECT @a, @b",
    ),
    [[Int(3L), Int(4L)]],
  )
  assert_eq(
    rows(
      "CREATE TABLE sq (a int, b int); INSERT sq VALUES (NEXT VALUE FOR dbo.q, NEXT VALUE FOR dbo.q), (NEXT VALUE FOR dbo.q, 0); SELECT a, b FROM sq",
    ),
    [[Int(5L), Int(5L)], [Int(6L), Int(0L)]],
  )
}
