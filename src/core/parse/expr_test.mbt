///|
test "operator precedence" {
  inspect(
    ex("1 + 2 * 3"),
    content=(
      #|(+ 1 (* 2 3))
    ),
  )
  inspect(
    ex("1 - 2 - 3"),
    content=(
      #|(- (- 1 2) 3)
    ),
  )
  inspect(
    ex("a & b | c ^ d + e"),
    content=(
      #|(+ (^ (| (& a b) c) d) e)
    ),
  )
  inspect(
    ex("-a * ~b"),
    content=(
      #|(* (- a) (~ b))
    ),
  )
  inspect(
    ex("NOT a = 1 AND b = 2 OR c = 3"),
    content=(
      #|(or (and (not (= a 1)) (= b 2)) (= c 3))
    ),
  )
  inspect(
    ex("a = 1 OR b = 2 AND c = 3"),
    content=(
      #|(or (= a 1) (and (= b 2) (= c 3)))
    ),
  )
  inspect(
    ex("NOT NOT a <> b"),
    content=(
      #|(not (not (<> a b)))
    ),
  )
  inspect(
    ex("a != b AND a !< b AND a !> b"),
    content=(
      #|(and (and (<> a b) (!< a b)) (!> a b))
    ),
  )
  inspect(
    ex("(a = 1 OR b = 2) AND c = 3"),
    content=(
      #|(and (paren (or (= a 1) (= b 2))) (= c 3))
    ),
  )
  inspect(
    ex("'a' + N'b' + 'it''s'"),
    content=(
      #|(+ (+ 'a' N'b') 'it''s')
    ),
  )
}

///|
test "predicates" {
  inspect(
    ex("x IS NOT NULL"),
    content=(
      #|(is-not-null x)
    ),
  )
  inspect(
    ex("x IS NULL AND y IS NOT NULL"),
    content=(
      #|(and (is-null x) (is-not-null y))
    ),
  )
  inspect(
    ex("name NOT LIKE 'a%' ESCAPE '\\'"),
    content=(
      #|(not-like name 'a%' (escape '\'))
    ),
  )
  inspect(
    ex("x IN (1, 2, 3)"),
    content=(
      #|(in x 1 2 3)
    ),
  )
  inspect(
    ex("x NOT IN (SELECT id FROM t)"),
    content=(
      #|(not-in x (select id (from (table t))))
    ),
  )
  inspect(
    ex("x BETWEEN 1 AND 10 AND y = 2"),
    content=(
      #|(and (between x 1 10) (= y 2))
    ),
  )
  inspect(
    ex("x NOT BETWEEN a + 1 AND b"),
    content=(
      #|(not-between x (+ a 1) b)
    ),
  )
  inspect(
    ex("EXISTS (SELECT 1 FROM t)"),
    content=(
      #|(exists (select 1 (from (table t))))
    ),
  )
  inspect(
    ex("NOT EXISTS (SELECT 1 FROM t WHERE t.a = o.a)"),
    content=(
      #|(not (exists (select 1 (from (table t)) (where (= t.a o.a)))))
    ),
  )
  inspect(
    ex("x > ALL (SELECT v FROM t)"),
    content=(
      #|(> all x (select v (from (table t))))
    ),
  )
  inspect(
    ex("x = ANY (SELECT v FROM t)"),
    content=(
      #|(= any x (select v (from (table t))))
    ),
  )
  inspect(
    ex("(SELECT COUNT(*) FROM t) > 0"),
    content=(
      #|(> (subquery (select (call COUNT *) (from (table t)))) 0)
    ),
  )
}

///|
test "case cast convert" {
  inspect(
    ex("CASE WHEN x = 1 THEN 'one' ELSE 'many' END"),
    content=(
      #|(case (when (= x 1) 'one') (else 'many'))
    ),
  )
  inspect(
    ex("CASE x WHEN 1 THEN 'one' WHEN 2 THEN 'two' END"),
    content=(
      #|(case x (when 1 'one') (when 2 'two'))
    ),
  )
  inspect(
    ex("CAST(x AS nvarchar(50))"),
    content=(
      #|(cast x nvarchar(50))
    ),
  )
  inspect(
    ex("TRY_CAST(x AS int)"),
    content=(
      #|(try-cast x int)
    ),
  )
  inspect(
    ex("CAST(x AS varchar(max))"),
    content=(
      #|(cast x varchar(max))
    ),
  )
  inspect(
    ex("CAST(x AS decimal(18, 4))"),
    content=(
      #|(cast x decimal(18,4))
    ),
  )
  inspect(
    ex("CONVERT(varchar(10), GETDATE(), 120)"),
    content=(
      #|(convert varchar(10) (call GETDATE) 120)
    ),
  )
  inspect(
    ex("TRY_CONVERT(datetime2, @s)"),
    content=(
      #|(try-convert datetime2 @s)
    ),
  )
  inspect(
    ex("x COLLATE Latin1_General_100_CI_AI = N'cafe'"),
    content=(
      #|(= (collate x Latin1_General_100_CI_AI) N'cafe')
    ),
  )
  inspect(
    ex("a + b COLLATE Latin1_General_BIN2"),
    content=(
      #|(+ a (collate b Latin1_General_BIN2))
    ),
  )
  inspect(
    ex("d AT TIME ZONE 'UTC' AT TIME ZONE 'Central European Standard Time'"),
    content=(
      #|(at-time-zone (at-time-zone d 'UTC') 'Central European Standard Time')
    ),
  )
  inspect(
    ex("PARSE('1' AS int USING 'en-US')"),
    content=(
      #|(parse '1' int 'en-US')
    ),
  )
  inspect(
    ex("CAST(1 AS DOUBLE PRECISION)"),
    content=(
      #|(cast 1 double precision)
    ),
  )
}

///|
test "functions" {
  inspect(
    ex("COUNT(DISTINCT name)"),
    content=(
      #|(call COUNT distinct name)
    ),
  )
  inspect(
    ex("COUNT(*)"),
    content=(
      #|(call COUNT *)
    ),
  )
  inspect(
    ex("GETDATE()"),
    content=(
      #|(call GETDATE)
    ),
  )
  inspect(
    ex("CURRENT_TIMESTAMP"),
    content=(
      #|(call CURRENT_TIMESTAMP)
    ),
  )
  inspect(
    ex("SYSTEM_USER + SESSION_USER + USER"),
    content=(
      #|(+ (+ (call SYSTEM_USER) (call SESSION_USER)) (call USER))
    ),
  )
  inspect(
    ex("LEFT(x, 1) + RIGHT(x, 2)"),
    content=(
      #|(+ (call LEFT x 1) (call RIGHT x 2))
    ),
  )
  inspect(
    ex("COALESCE(a, b, 0) + NULLIF(a, 0) + ISNULL(a, 1)"),
    content=(
      #|(+ (+ (call COALESCE a b 0) (call NULLIF a 0)) (call ISNULL a 1))
    ),
  )
  inspect(
    ex("IIF(a > 1, 'x', 'y')"),
    content=(
      #|(call IIF (> a 1) 'x' 'y')
    ),
  )
  inspect(
    ex("dbo.fn(1, DEFAULT)"),
    content=(
      #|(call dbo.fn 1 DEFAULT)
    ),
  )
  inspect(
    ex("ROW_NUMBER() OVER (PARTITION BY a ORDER BY b DESC)"),
    content=(
      #|(call ROW_NUMBER (over (partition-by a) (order-by (desc b))))
    ),
  )
  inspect(
    ex(
      "SUM(x) OVER (ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
    ),
    content=(
      #|(call SUM x (over (order-by d) (rows unbounded-preceding current-row)))
    ),
  )
  inspect(
    ex(
      "AVG(x) OVER (PARTITION BY g ORDER BY d ROWS BETWEEN 2 PRECEDING AND 1 FOLLOWING)",
    ),
    content=(
      #|(call AVG x (over (partition-by g) (order-by d) (rows (preceding 2) (following 1))))
    ),
  )
  inspect(
    ex("SUM(x) OVER (ORDER BY d RANGE UNBOUNDED PRECEDING)"),
    content=(
      #|(call SUM x (over (order-by d) (range unbounded-preceding)))
    ),
  )
  inspect(
    ex("STRING_AGG(name, ',') WITHIN GROUP (ORDER BY name)"),
    content=(
      #|(call STRING_AGG name ',' (within-group name))
    ),
  )
  inspect(
    ex("NEXT VALUE FOR dbo.order_ids"),
    content=(
      #|(next-value-for dbo.order_ids)
    ),
  )
  inspect(
    ex("JSON_VALUE(@j, '$.a') + JSON_QUERY(@j, '$.b')"),
    content=(
      #|(+ (call JSON_VALUE @j '$.a') (call JSON_QUERY @j '$.b'))
    ),
  )
  inspect(
    ex("DATEADD(day, -1, SYSUTCDATETIME())"),
    content=(
      #|(call DATEADD day (- 1) (call SYSUTCDATETIME))
    ),
  )
  inspect(
    ex("UPDATE(col)"),
    content=(
      #|(call UPDATE col)
    ),
  )
}

///|
test "literals and variables" {
  inspect(
    ex("@x + @@ROWCOUNT"),
    content=(
      #|(+ @x @@ROWCOUNT)
    ),
  )
  inspect(
    ex("1.5 + .5 + 1. + 1e3 + 2.5E-2 + 0xDEADbeef + 0x + $12.50"),
    content=(
      #|(+ (+ (+ (+ (+ (+ (+ 1.5 .5) 1.) 1e3) 2.5E-2) 0xDEADbeef) 0x) $12.50)
    ),
  )
  inspect(
    ex("-2147483648"),
    content=(
      #|(- 2147483648)
    ),
  )
  inspect(
    ex("$action"),
    content=(
      #|$action
    ),
  )
  inspect(
    ex("[my col].[x]]y] + \"q\""),
    content=(
      #|(+ [my col].[x]y] [q])
    ),
  )
  inspect(
    ex("#tmp.a + ##g.b"),
    content=(
      #|(+ #tmp.a ##g.b)
    ),
  )
  inspect(
    ex("db..t.c"),
    content=(
      #|db..t.c
    ),
  )
  inspect(
    ex("(SELECT MAX(id) FROM t)"),
    content=(
      #|(subquery (select (call MAX id) (from (table t))))
    ),
  )
  inspect(
    ex("((SELECT 1) + 1)"),
    content=(
      #|(paren (+ (subquery (select 1)) 1))
    ),
  )
  inspect(
    ex("((SELECT 1) UNION (SELECT 2))"),
    content=(
      #|(subquery (union (nested (select 1)) (nested (select 2))))
    ),
  )
}

///|
test "expression errors" {
  inspect(
    ex("1 +"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '+'.
    ),
  )
  inspect(
    ex("a = = b"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '='.
    ),
  )
  inspect(
    ex("CASE END"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'END'.
    ),
  )
  inspect(
    ex("SELECT"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'SELECT'.
    ),
  )
  inspect(
    ex("ERROR_PROCEDURE(*)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '*'.
    ),
  )
  inspect(
    ex("FROM(1)"),
    content=(
      #|Msg 156, Level 15, State 1, Line 1: Incorrect syntax near the keyword 'FROM'.
    ),
  )
}

///|
test "JSON_OBJECT and JSON_ARRAY constructors" {
  inspect(
    ex("JSON_OBJECT('a':1, @k:x ABSENT ON NULL)"),
    content=(
      #|(call JSON_OBJECT ABSENT ON NULL 'a' 1 @k x)
    ),
  )
  inspect(
    ex("JSON_ARRAY(1, NULL NULL ON NULL RETURNING json)"),
    content=(
      #|(call JSON_ARRAY NULL ON NULL RETURNING JSON 1 NULL)
    ),
  )
  inspect(
    ex("JSON_OBJECT()"),
    content=(
      #|(call JSON_OBJECT)
    ),
  )
  inspect(
    ex("JSON_OBJECT('a', 1)"),
    content=(
      #|Msg 102, Level 15, State 10, Line 1: Incorrect syntax near 'JSON_OBJECT'.
    ),
  )
  inspect(
    ex("JSON_ARRAY(1 ABSENT ON NULL, 2)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ','.
    ),
  )
}
