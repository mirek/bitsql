///|
fn error_numbers(sql : String) -> String {
  @parse.batch_errors(sql).map(e => e.number().to_string()).join(" ")
}

///|
test "syntax error recovery (captured: tail5/b1-syntax-recovery)" {
  inspect(
    error_numbers("DECLARE @t TABLE(a int); UPDATE @t WITH (ROWLOCK) SET a = 1"),
    content="156 319",
  )
  inspect(
    error_numbers(
      "DECLARE @t TABLE(a int); MERGE @t WITH (HOLDLOCK) AS x USING (SELECT 1 AS a) s ON x.a = s.a WHEN NOT MATCHED THEN INSERT VALUES (s.a);",
    ),
    content="156 319 102",
  )
  inspect(error_numbers("SELECT 1 x y; SELECT 2 a b"), content="102 102")
  inspect(error_numbers("SELECT 1 x y; UPDATE"), content="102")
  inspect(error_numbers("SELECT 1"), content="")
}

///|
test "named windows resolve into OVER clauses" {
  let s = @parse.parse_statement(
    "SELECT SUM(n) OVER w2 FROM t WINDOW w1 AS (PARTITION BY g), w2 AS (w1 ORDER BY n)",
  )
  inspect(s.kind is Select(_), content="true")
  inspect(
    error_numbers("SELECT SUM(n) OVER x FROM t WINDOW w AS (ORDER BY n)"),
    content="5362",
  )
  inspect(
    error_numbers("SELECT SUM(n) OVER w FROM t WINDOW w AS (w1), w1 AS (w)"),
    content="5365",
  )
  inspect(
    error_numbers("SELECT LAG(n) OVER w FROM t WINDOW w AS (PARTITION BY g)"),
    content="5366",
  )
}
