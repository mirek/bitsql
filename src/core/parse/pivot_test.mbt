///|
test "pivot, unpivot and tablesample" {
  inspect(
    sx(
      "SELECT * FROM (SELECT a, b, c FROM t) s PIVOT (SUM(s.c) FOR b IN ([1], x)) AS p JOIN u ON 1 = 1",
    ),
    content=(
      #|(select * (from (join (pivot (derived (select a b c (from (table t))) (as s)) (SUM s.c) b (in [1] x) (as p)) (table u) (on (= 1 1)))))
    ),
  )
  inspect(
    sx(
      "SELECT * FROM t UNPIVOT (v FOR k IN (q1, [q 2])) u UNPIVOT (v2 FOR k2 IN (id)) u2",
    ),
    content=(
      #|(select * (from (unpivot (unpivot (table t) v k (in q1 [q 2]) (as u)) v2 k2 (in id) (as u2))))
    ),
  )
  inspect(
    sx(
      "SELECT * FROM t AS x TABLESAMPLE SYSTEM (10.5 PERCENT) REPEATABLE (3) WITH (NOLOCK)",
    ),
    content=(
      #|(select * (from (table t (as x) (with TABLESAMPLE(10.5,PERCENT,3) NOLOCK))))
    ),
  )
  inspect(
    sx("SELECT * FROM t PIVOT (SUM(a) FOR b IN ([1])) AS p (x, y)"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'x'.
    ),
  )
  inspect(
    sx("SELECT * FROM t TABLESAMPLE (@p PERCENT)"),
    content=(
      #|Msg 497, Level 15, State 1, Line 1: Variables are not allowed in the TABLESAMPLE or REPEATABLE clauses.
    ),
  )
  inspect(
    sx(
      "SELECT SUM(a) OVER (ORDER BY b ROWS BETWEEN @x PRECEDING AND CURRENT ROW) FROM t",
    ),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '@x'.
    ),
  )
  inspect(
    sx("SELECT SUM(a) OVER (ROWS UNBOUNDED PRECEDING) FROM t"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'ROWS'.
    ),
  )
  inspect(
    sx("SELECT STRING_AGG(DISTINCT a, ',') FROM t"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near ','.
    ),
  )
}
