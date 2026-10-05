///|
/// Semantics of the O(n log n) execution paths (exec/grouping.mbt,
/// exec/memo.mbt, index seeks): the same rows, order, representatives,
/// NULL handling and warnings as the linear searches they replaced
/// (checked against the previous build and, except for the plan-dependent
/// GROUP BY / DISTINCT / UNION row order, against SQL Server 17.0.5005.3).
fn perf_session() -> @session.Session {
  let s = @session.Session::new(
    @session.Server::new(),
    spid=51,
    database="master",
    seed=1,
  )
  ignore(
    s.run_batch(
      (
        #|CREATE TABLE pc (id int PRIMARY KEY, v nvarchar(10) COLLATE Latin1_General_CI_AS NULL, n int NULL);
        #|INSERT pc VALUES (1, N'b', 1), (2, N'A', 2), (3, N'a ', NULL), (4, NULL, 3), (5, N'B', 1), (6, N'a', 2), (7, NULL, NULL);
        #|CREATE TABLE pd (id int PRIMARY KEY, w nvarchar(10) COLLATE Latin1_General_CI_AS NULL, k int NULL);
        #|INSERT pd VALUES (1, N'A', 2), (2, N'c', NULL), (3, N'a', 2), (4, N'B  ', 9)
      ),
      0,
    ),
  )
  s
}

///|
fn texts(items : Array[@reply.Item]) -> Array[Array[@tds.WireValue]] {
  row_values(items)
}

///|
test "GROUP BY: groups in order of first appearance, first spelling, NULLs together" {
  let s = perf_session()
  let r = s.run_batch("SELECT v, COUNT(*), SUM(n) FROM pc GROUP BY v", 0)
  assert_eq(texts(r), [
    [Text("b"), Int(2), Int(2)],
    [Text("A"), Int(3), Int(4)],
    [Null, Int(2), Int(3)],
  ])
  assert_eq(messages(r), [8153])
}

///|
test "DISTINCT sorted, UNION first appearance order, binary-smallest spelling" {
  let s = perf_session()
  // DISTINCT without ORDER BY comes out sorted (captured: corpus
  // orm/distinct-order)
  let r = s.run_batch("SELECT DISTINCT v FROM pc", 0)
  assert_eq(texts(r), [[Null], [Text("A")], [Text("B")]])
  let u = s.run_batch("SELECT w FROM pd UNION SELECT v FROM pc", 0)
  assert_eq(texts(u), [[Text("A")], [Text("c")], [Text("B")], [Null]])
}

///|
test "EXCEPT and INTERSECT under CI equality with NULLs" {
  let s = perf_session()
  let e = s.run_batch("SELECT v FROM pc EXCEPT SELECT w FROM pd", 0)
  assert_eq(texts(e), [[Null]])
  let i = s.run_batch("SELECT v FROM pc INTERSECT SELECT w FROM pd", 0)
  assert_eq(texts(i), [[Text("B")], [Text("A")]])
  let n = s.run_batch(
    "SELECT n FROM pc INTERSECT SELECT k FROM pd; SELECT n FROM pc EXCEPT SELECT k FROM pd",
    0,
  )
  assert_eq(texts(n), [[Int(2)], [Null], [Int(1)], [Int(3)]])
}

///|
test "COUNT(DISTINCT) and STRING_AGG keep the first value of each group" {
  let s = perf_session()
  let r = s.run_batch(
    "SELECT COUNT(DISTINCT v), COUNT(DISTINCT n), COUNT(v) FROM pc", 0,
  )
  assert_eq(texts(r), [[Int(2), Int(3), Int(5)]])
  assert_eq(messages(r), [8153])
  let g = s.run_batch(
    "SELECT n, COUNT(DISTINCT v) FROM pc GROUP BY n ORDER BY n", 0,
  )
  assert_eq(texts(g), [
    [Null, Int(1)],
    [Int(1), Int(1)],
    [Int(2), Int(1)],
    [Int(3), Int(0)],
  ])
}

///|
test "uncorrelated IN / NOT IN: CI equality, trailing spaces, NULL in the set" {
  let s = perf_session()
  let r = s.run_batch(
    "SELECT id FROM pc WHERE v IN (SELECT w FROM pd) ORDER BY id", 0,
  )
  assert_eq(texts(r), [[Int(1)], [Int(2)], [Int(3)], [Int(5)], [Int(6)]])
  // pd.k holds a NULL: NOT IN is never true
  let n = s.run_batch("SELECT id FROM pc WHERE n NOT IN (SELECT k FROM pd)", 0)
  assert_eq(texts(n), [])
  let n2 = s.run_batch(
    "SELECT id FROM pc WHERE n NOT IN (SELECT k FROM pd WHERE k IS NOT NULL) ORDER BY id",
    0,
  )
  assert_eq(texts(n2), [[Int(1)], [Int(4)], [Int(5)]])
  // a NULL probe: unknown, also under NOT
  let p = s.run_batch(
    "SELECT id FROM pc WHERE NOT (n IN (SELECT k FROM pd WHERE k = 2)) ORDER BY id",
    0,
  )
  assert_eq(texts(p), [[Int(1)], [Int(4)], [Int(5)]])
}

///|
test "memoized subqueries see variable changes and writes of the statement" {
  let s = perf_session()
  // the subquery reads @lim, which the loop changes between statements
  let r = s.run_batch(
    (
      #|DECLARE @lim int = -1;
      #|WHILE @lim <= 1 BEGIN
      #|  SELECT COUNT(*) FROM pc WHERE n IN (SELECT k - @lim FROM pd);
      #|  SET @lim += 1;
      #|END
    ),
    0,
  )
  assert_eq(texts(r), [[Int(1)], [Int(2)], [Int(2)]])
  // SQL Server reads the pre-update state for every row
  let u = s.run_batch(
    "UPDATE pd SET k = (SELECT MAX(k) FROM pd) + id; SELECT id, k FROM pd ORDER BY id",
    0,
  )
  assert_eq(texts(u), [
    [Int(1), Int(10)],
    [Int(2), Int(11)],
    [Int(3), Int(12)],
    [Int(4), Int(13)],
  ])
}

///|
test "correlated lookups on an unindexed column: duplicates in scan order" {
  let s = perf_session()
  let r = s.run_batch(
    (
      #|SELECT id, (SELECT TOP 1 d.id FROM pd d WHERE d.w = c.v),
      #|  (SELECT COUNT(*) FROM pd d WHERE d.w = c.v),
      #|  CASE WHEN EXISTS (SELECT 1 FROM pd d WHERE d.k = c.n) THEN 1 ELSE 0 END
      #|FROM pc c ORDER BY id
    ),
    0,
  )
  assert_eq(texts(r), [
    [Int(1), Int(4), Int(1), Int(0)],
    [Int(2), Int(1), Int(2), Int(1)],
    [Int(3), Int(1), Int(2), Int(0)],
    [Int(4), Null, Int(0), Int(0)],
    [Int(5), Int(4), Int(1), Int(0)],
    [Int(6), Int(1), Int(2), Int(1)],
    [Int(7), Null, Int(0), Int(0)],
  ])
}

///|
test "correlated lookups through a non-unique index" {
  let s = perf_session()
  ignore(
    s.run_batch("CREATE INDEX pd_k ON pd (k); CREATE INDEX pd_w ON pd (w)", 0),
  )
  let r = s.run_batch(
    (
      #|SELECT id, (SELECT TOP 1 d.id FROM pd d WHERE d.k = c.n ORDER BY d.id DESC),
      #|  (SELECT COUNT(*) FROM pd d WHERE d.k = c.n),
      #|  (SELECT STRING_AGG(CAST(d.id AS nvarchar(5)), N',') FROM pd d WHERE d.w = c.v)
      #|FROM pc c ORDER BY id
    ),
    0,
  )
  assert_eq(texts(r), [
    [Int(1), Null, Int(0), Text("4")],
    [Int(2), Int(3), Int(2), Text("1,3")],
    [Int(3), Null, Int(0), Text("1,3")],
    [Int(4), Null, Int(0), Null],
    [Int(5), Null, Int(0), Text("4")],
    [Int(6), Int(3), Int(2), Text("1,3")],
    [Int(7), Null, Int(0), Null],
  ])
}

///|
test "foreign key checks and cascades through key indexes (CI keys)" {
  let s = perf_session()
  let r = s.run_batch(
    (
      #|CREATE TABLE fp (k nvarchar(5) COLLATE Latin1_General_CI_AS NOT NULL, x int NOT NULL, CONSTRAINT fp_pk PRIMARY KEY (k, x));
      #|INSERT fp VALUES (N'a', 1), (N'b', 1), (N'c', 2);
      #|CREATE TABLE fc (id int PRIMARY KEY, x int NULL, k nvarchar(5) COLLATE Latin1_General_CI_AS NULL,
      #|  CONSTRAINT fc_fk FOREIGN KEY (k, x) REFERENCES fp (k, x) ON DELETE CASCADE);
      #|CREATE TABLE fn (id int PRIMARY KEY, x int NULL, k nvarchar(5) COLLATE Latin1_General_CI_AS NULL,
      #|  CONSTRAINT fn_fk FOREIGN KEY (k, x) REFERENCES fp (k, x));
      #|INSERT fc VALUES (1, 1, N'A '), (2, 1, N'B'), (3, NULL, N'z'), (4, 2, N'C'), (5, 1, N'a');
      #|INSERT fn VALUES (1, 2, N'C ');
      #|INSERT fn VALUES (2, 1, N'zz');
    ),
    0,
  )
  // the last INSERT names a missing key
  assert_eq(messages(r), [547, 3621])
  let d = s.run_batch(
    "DELETE fp WHERE x = 1; SELECT id FROM fc ORDER BY id; DELETE fp WHERE x = 2; SELECT COUNT(*) FROM fp",
    0,
  )
  assert_eq(texts(d), [[Int(3)], [Int(4)], [Int(1)]])
  assert_eq(messages(d), [547, 3621])
}

///|
/// Unnested correlated subqueries (exec/decorrelate.mbt) against the
/// per-row path: `pid + 0 = outer` is not a plain column key, so the same
/// query with it runs the subquery per outer row.
test "unnested correlated subqueries equal the per-row evaluation" {
  let s = perf_session()
  ignore(
    s.run_batch(
      (
        #|CREATE TABLE dp (id int PRIMARY KEY, g smallint NULL, lim int NULL);
        #|INSERT dp SELECT value, CASE WHEN value % 7 = 0 THEN NULL ELSE value % 5 END, value % 4 FROM GENERATE_SERIES(1, 60);
        #|CREATE TABLE dc (id int PRIMARY KEY, pid int NULL, v int NULL);
        #|INSERT dc SELECT value, CASE WHEN value % 11 = 0 THEN NULL ELSE value % 23 END, CASE WHEN value % 6 = 0 THEN NULL ELSE value % 9 END FROM GENERATE_SERIES(1, 90);
      ),
      0,
    ),
  )
  let shapes = [
    "SELECT id FROM dp WHERE EXISTS (SELECT 1 FROM dc WHERE dc.pid {k} dp.id) ORDER BY id",
    "SELECT id FROM dp WHERE NOT EXISTS (SELECT 1 FROM dc WHERE dc.pid {k} dp.g AND dc.v > 2) ORDER BY id",
    "SELECT id, (SELECT COUNT(*) FROM dc WHERE dc.pid {k} dp.g) FROM dp ORDER BY id",
    "SELECT id, (SELECT SUM(v) FROM dc WHERE dc.pid {k} dp.g AND dc.v >= dp.lim) FROM dp ORDER BY id",
    "SELECT id, (SELECT TOP 1 id FROM dc WHERE dc.pid {k} dp.id ORDER BY v DESC, id) FROM dp ORDER BY id",
    "SELECT id FROM dp WHERE lim IN (SELECT v FROM dc WHERE dc.pid {k} dp.g) ORDER BY id",
    "SELECT id FROM dp WHERE lim NOT IN (SELECT v FROM dc WHERE dc.pid {k} dp.g) ORDER BY id",
    "SELECT id, (SELECT COUNT(DISTINCT v) FROM dc WHERE dc.pid {k} dp.g) FROM dp ORDER BY id",
    "SELECT id, (SELECT v FROM dc WHERE dc.pid {k} dp.id) FROM dp ORDER BY id",
  ]
  for shape in shapes {
    let unnested = s.run_batch(shape.replace_all(old="{k}", new="="), 0)
    let per_row = s.run_batch(shape.replace_all(old="{k}", new="+ 0 ="), 0)
    assert_eq(texts(unnested), texts(per_row))
    assert_eq(messages(unnested), messages(per_row))
  }
}
