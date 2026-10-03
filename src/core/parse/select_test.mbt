///|
test "select basics" {
  inspect(
    sx("SELECT 'foo' AS bar"),
    content=(
      #|(select (as 'foo' bar))
    ),
  )
  inspect(
    sx(
      (
        #|SELECT TOP 10 u.id, u.name AS n, COUNT(*)
        #|FROM dbo.users u WITH (NOLOCK)
        #|WHERE u.age >= 18 AND u.name LIKE N'a%'
        #|GROUP BY u.id, u.name
        #|HAVING COUNT(*) > 1
        #|ORDER BY u.name DESC
      ),
    ),
    content=(
      #|(query (select (top 10) u.id (as u.name n) (call COUNT *) (from (table dbo.users (as u) (with NOLOCK))) (where (and (>= u.age 18) (like u.name N'a%'))) (group-by u.id u.name) (having (> (call COUNT *) 1))) (order-by (desc u.name)))
    ),
  )
  inspect(
    sx("SELECT DISTINCT a, b c, d AS [e f], 'x' g, h 'i' FROM t"),
    content=(
      #|(select distinct a (as b c) (as d [e f]) (as 'x' g) (as h [i]) (from (table t)))
    ),
  )
  inspect(
    sx("SELECT n = 1, [m] = 2, 'o' = 3, @v = 4"),
    content=(
      #|(select (as 1 n) (as 2 [m]) (as 3 [o]) (= @v 4))
    ),
  )
  inspect(
    sx("SELECT *, t.*, s.t.* FROM t"),
    content=(
      #|(select * t.* s.t.* (from (table t)))
    ),
  )
  inspect(
    sx("SELECT @x = MAX(id), @y += 1 FROM t"),
    content=(
      #|(select (= @x (call MAX id)) (+= @y 1) (from (table t)))
    ),
  )
  inspect(
    sx("SELECT a INTO #tmp FROM t"),
    content=(
      #|(select a (into #tmp) (from (table t)))
    ),
  )
  inspect(
    sx("SELECT ALL a FROM t"),
    content=(
      #|(select a (from (table t)))
    ),
  )
}

///|
test "top forms" {
  inspect(
    sx("SELECT TOP 10 PERCENT * FROM t"),
    content=(
      #|(select (top 10 percent) * (from (table t)))
    ),
  )
  inspect(
    sx("SELECT TOP (10) PERCENT WITH TIES * FROM t ORDER BY x"),
    content=(
      #|(query (select (top 10 percent with-ties) * (from (table t))) (order-by x))
    ),
  )
  inspect(
    sx("SELECT TOP (@n) a FROM t"),
    content=(
      #|(select (top @n) a (from (table t)))
    ),
  )
  inspect(
    sx("SELECT TOP 10 * FROM t"),
    content=(
      #|(select (top 10) * (from (table t)))
    ),
  )
  inspect(
    sx("SELECT TOP @n a FROM t"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '@n'.
    ),
  )
}

///|
test "joins" {
  inspect(
    sx(
      "SELECT * FROM a JOIN b ON a.id = b.a_id LEFT OUTER JOIN c ON b.id = c.b_id",
    ),
    content=(
      #|(select * (from (left-join (join (table a) (table b) (on (= a.id b.a_id))) (table c) (on (= b.id c.b_id)))))
    ),
  )
  inspect(
    sx(
      "SELECT * FROM a RIGHT JOIN b ON 1 = 1 FULL OUTER JOIN c ON 1 = 1 CROSS JOIN d",
    ),
    content=(
      #|(select * (from (cross-join (full-join (right-join (table a) (table b) (on (= 1 1))) (table c) (on (= 1 1))) (table d))))
    ),
  )
  inspect(
    sx("SELECT * FROM a, b WHERE a.id = b.id"),
    content=(
      #|(select * (from (table a) (table b)) (where (= a.id b.id)))
    ),
  )
  inspect(
    sx("SELECT * FROM a LEFT JOIN b INNER JOIN c ON b.x = c.x ON a.y = b.y"),
    content=(
      #|(select * (from (left-join (table a) (join (table b) (table c) (on (= b.x c.x))) (on (= a.y b.y)))))
    ),
  )
  inspect(
    sx("SELECT * FROM (a JOIN b ON a.x = b.x) LEFT JOIN c ON c.y = a.y"),
    content=(
      #|(select * (from (left-join (join (table a) (table b) (on (= a.x b.x))) (table c) (on (= c.y a.y)))))
    ),
  )
  inspect(
    sx("SELECT * FROM a INNER HASH JOIN b ON a.x = b.x"),
    content=(
      #|(select * (from (join HASH (table a) (table b) (on (= a.x b.x)))))
    ),
  )
  inspect(
    sx(
      (
        #|SELECT t.id, s.value
        #|FROM tags t
        #|CROSS APPLY STRING_SPLIT(t.csv, ',', 1) s
        #|OUTER APPLY (
        #|  SELECT TOP (1) note FROM notes n
        #|  WHERE n.tag_id = t.id ORDER BY n.created_at DESC
        #|) latest
      ),
    ),
    content=(
      #|(select t.id s.value (from (outer-apply (cross-apply (table tags (as t)) (tvf STRING_SPLIT t.csv ',' 1 (as s))) (derived (query (select (top 1) note (from (table notes (as n))) (where (= n.tag_id t.id))) (order-by (desc n.created_at))) (as latest)))))
    ),
  )
  inspect(
    sx(
      (
        #|SELECT t.name, s.name AS schema_name, c.name AS column_name
        #|FROM sys.tables t
        #|JOIN sys.schemas s ON t.schema_id = s.schema_id
        #|JOIN sys.columns c ON c.object_id = t.object_id
        #|WHERE t.is_ms_shipped = 0
        #|ORDER BY t.name, c.column_id
      ),
    ),
    content=(
      #|(query (select t.name (as s.name schema_name) (as c.name column_name) (from (join (join (table sys.tables (as t)) (table sys.schemas (as s)) (on (= t.schema_id s.schema_id))) (table sys.columns (as c)) (on (= c.object_id t.object_id)))) (where (= t.is_ms_shipped 0))) (order-by t.name c.column_id))
    ),
  )
}

///|
test "table sources" {
  inspect(
    sx("SELECT x.n FROM (SELECT 1 AS n) x"),
    content=(
      #|(select x.n (from (derived (select (as 1 n)) (as x))))
    ),
  )
  inspect(
    sx("SELECT * FROM (SELECT 1 AS n) AS x (m)"),
    content=(
      #|(select * (from (derived (select (as 1 n)) (as x m))))
    ),
  )
  inspect(
    sx(
      "SELECT source.value FROM (VALUES (1, N'a'), (@value + 1, NULL)) AS source(value, label)",
    ),
    content=(
      #|(select source.value (from (values (1 N'a') ((+ @value 1) NULL) (as source value label))))
    ),
  )
  inspect(
    sx("SELECT * FROM (VALUES (1))"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ')'.
    ),
  )
  inspect(
    sx("SELECT * FROM @items AS i"),
    content=(
      #|(select * (from (table @items (as i))))
    ),
  )
  inspect(
    sx("SELECT * FROM t WITH (UPDLOCK, HOLDLOCK) WHERE id = 1"),
    content=(
      #|(select * (from (table t (with UPDLOCK HOLDLOCK))) (where (= id 1)))
    ),
  )
  inspect(
    sx(
      "SELECT * FROM t AS x WITH (ROWLOCK, READPAST, INDEX(ix_a, ix_b), INDEX = ix_c)",
    ),
    content=(
      #|(select * (from (table t (as x) (with ROWLOCK READPAST INDEX(ix_a,ix_b) INDEX(ix_c)))))
    ),
  )
  inspect(
    sx("SELECT * FROM t WITH (SERIALIZABLE) JOIN u WITH (NOLOCK) ON 1 = 1"),
    content=(
      #|(select * (from (join (table t (with SERIALIZABLE)) (table u (with NOLOCK)) (on (= 1 1)))))
    ),
  )
  inspect(
    sx("SELECT s.token FROM STRING_SPLIT('a,b', ',', 1) AS s (token, position)"),
    content=(
      #|(select s.token (from (tvf STRING_SPLIT 'a,b' ',' 1 (as s token position))))
    ),
  )
  inspect(
    sx(
      (
        #|SELECT j.id, j.details
        #|FROM OPENJSON(@json, '$.items') WITH (
        #|  id INT '$.itemId',
        #|  details NVARCHAR(MAX) '$.details' AS JSON,
        #|  name nvarchar(50)
        #|) j
      ),
    ),
    content=(
      #|(select j.id j.details (from (tvf OPENJSON @json '$.items' (with-schema (id INT '$.itemId') (details NVARCHAR(max) '$.details' as-json) (name nvarchar(50))) (as j))))
    ),
  )
  inspect(
    sx("SELECT * FROM OPENJSON(@j)"),
    content=(
      #|(select * (from (tvf OPENJSON @j)))
    ),
  )
  inspect(
    sx("SELECT value FROM GENERATE_SERIES(1, 5, 2)"),
    content=(
      #|(select value (from (tvf GENERATE_SERIES 1 5 2)))
    ),
  )
  inspect(
    sx("SELECT * FROM dbo.fn_items(@id, DEFAULT) f"),
    content=(
      #|(select * (from (tvf dbo.fn_items @id DEFAULT (as f))))
    ),
  )
}

///|
test "set operations and tails" {
  inspect(
    sx("SELECT 1 AS n UNION ALL SELECT 2 ORDER BY n"),
    content=(
      #|(query (union-all (select (as 1 n)) (select 2)) (order-by n))
    ),
  )
  inspect(
    sx("SELECT 1 UNION SELECT 2 INTERSECT SELECT 3 EXCEPT SELECT 4"),
    content=(
      #|(except (union (select 1) (intersect (select 2) (select 3))) (select 4))
    ),
  )
  inspect(
    sx("(SELECT 1) UNION (SELECT 2 ORDER BY 1 OFFSET 0 ROWS)"),
    content=(
      #|(union (nested (select 1)) (nested (query (select 2) (order-by 1) (offset 0))))
    ),
  )
  inspect(
    sx("SELECT * FROM t ORDER BY id OFFSET 10 ROWS FETCH NEXT 5 ROWS ONLY"),
    content=(
      #|(query (select * (from (table t))) (order-by id) (offset 10) (fetch 5))
    ),
  )
  inspect(
    sx("SELECT * FROM t ORDER BY id OFFSET @o ROW FETCH FIRST @n ROW ONLY"),
    content=(
      #|(query (select * (from (table t))) (order-by id) (offset @o) (fetch @n))
    ),
  )
  inspect(
    sx("SELECT * FROM t OPTION (RECOMPILE, MAXRECURSION 0)"),
    content=(
      #|(query (select * (from (table t))) (option 'RECOMPILE' 'MAXRECURSION 0'))
    ),
  )
  inspect(
    sx("SELECT * FROM t OPTION (OPTIMIZE FOR (@p = 1))"),
    content=(
      #|(query (select * (from (table t))) (option 'OPTIMIZE FOR ( @p = 1 )'))
    ),
  )
}

///|
test "ctes" {
  inspect(
    sx("WITH a AS (SELECT 1 AS x), b (y) AS (SELECT 2) SELECT * FROM a, b"),
    content=(
      #|(query (with (a (select (as 1 x))) (b (y) (select 2))) (select * (from (table a) (table b))))
    ),
  )
  inspect(
    sx(
      (
        #|WITH r (n) AS (
        #|  SELECT 1
        #|  UNION ALL
        #|  SELECT n + 1 FROM r WHERE n < 10
        #|)
        #|SELECT n FROM r OPTION (MAXRECURSION 100)
      ),
    ),
    content=(
      #|(query (with (r (n) (union-all (select 1) (select (+ n 1) (from (table r)) (where (< n 10)))))) (select n (from (table r))) (option 'MAXRECURSION 100'))
    ),
  )
  inspect(
    sx("WITH c AS (SELECT 1 AS x) INSERT INTO t SELECT x FROM c"),
    content=(
      #|(insert (with (c (select (as 1 x)))) (table t) (select x (from (table c))))
    ),
  )
  inspect(
    sx("WITH c AS (SELECT * FROM t) DELETE FROM c WHERE x = 1"),
    content=(
      #|(delete (with (c (select * (from (table t))))) (table c) (where (= x 1)))
    ),
  )
  inspect(
    sx("WITH c AS (SELECT * FROM t) UPDATE c SET x = 1"),
    content=(
      #|(update (with (c (select * (from (table t))))) (table c) (set (= x 1)))
    ),
  )
}

///|
test "group by forms" {
  inspect(
    sx(
      "SELECT a, b, SUM(v) FROM t GROUP BY a, ROLLUP((b, c), d), GROUPING SETS ((e, f), CUBE(g, h), ())",
    ),
    content=(
      #|(select a b (call SUM v) (from (table t)) (group-by a (rollup (b c) (d)) (grouping-sets (e f) (cube (g) (h)) ())))
    ),
  )
  inspect(
    sx("SELECT COUNT(*) FROM t GROUP BY ()"),
    content=(
      #|(select (call COUNT *) (from (table t)) (group-by ()))
    ),
  )
}

///|
test "for json and xml" {
  inspect(
    sx(
      (
        #|SELECT id, name AS [info.name] FROM users ORDER BY id
        #|FOR JSON PATH, ROOT('users'), INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER
      ),
    ),
    content=(
      #|(query (select id (as name [info.name]) (from (table users))) (order-by id) (for-json path (root 'users') include-null-values without-array-wrapper))
    ),
  )
  inspect(
    sx("SELECT t.id FROM t FOR JSON AUTO"),
    content=(
      #|(query (select t.id (from (table t))) (for-json auto))
    ),
  )
  inspect(
    sx("SELECT 1 FOR JSON PATH, ROOT"),
    content=(
      #|(query (select 1) (for-json path (root 'root')))
    ),
  )
  inspect(
    sx("SELECT 1 FOR JSON XML"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'XML'.
    ),
  )
  inspect(
    sx("SELECT 1 FOR JSON PATH, ROOT(1)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '1'.
    ),
  )
  inspect(
    sx("SELECT 1 FOR JSON PATH, INCLUDE_NULL_VALUES, INCLUDE_NULL_VALUES"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'INCLUDE_NULL_VALUES'.
    ),
  )
  inspect(
    sx(
      "SELECT STUFF((SELECT ',' + name FROM t FOR XML PATH('')), 1, 1, '') AS names",
    ),
    content=(
      #|(select (as (call STUFF (subquery (query (select (+ ',' name) (from (table t))) (for-xml PATH ''))) 1 1 '') names))
    ),
  )
  inspect(
    sx(
      "SELECT 1 AS [value] FOR XML PATH('row'), ROOT('a'), ELEMENTS XSINIL, BINARY BASE64, TYPE",
    ),
    content=(
      #|(query (select (as 1 [value])) (for-xml PATH 'row' ROOT('a') ELEMENTS XSINIL BINARY BASE64 TYPE))
    ),
  )
  inspect(
    sx("SELECT 1 AS [value] FOR XML PATH('row'), TYPE, TYPE"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'XML'.
    ),
  )
}

///|
test "select errors" {
  inspect(
    sx("SELECT FROM"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'FROM'.
    ),
  )
  inspect(
    sx("SELECT * FROM"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'FROM'.
    ),
  )
  inspect(
    sx("SELECT * FROM t CROSS APPLY"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'APPLY'.
    ),
  )
  inspect(
    sx("SELECT * FROM t OUTER APPLY f(1) ON 1 = 1"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'ON'.
    ),
  )
  inspect(
    sx("SELECT * FROM t PIVOT (SUM(v) FOR k IN (a)) p"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'PIVOT'.
    ),
  )
  inspect(
    sx("SELECT * FROM (VALUES) AS s(v)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ')'.
    ),
  )
  inspect(
    sx("SELECT a b c FROM t"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'c'.
    ),
  )
  inspect(
    sx("SELECT 1 = 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '='.
    ),
  )
  inspect(
    sx("SELECT * FROM t WHERE"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'WHERE'.
    ),
  )
  inspect(
    sx("SELECT key FROM t"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'key'.
    ),
  )
}
