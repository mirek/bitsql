///|
test "errors carry SQL Server numbers and lines" {
  inspect(
    sx("SELECT 1\nSELECT * FROM\nWHERE x = 1"),
    content=(
      #|Msg 156, Level 15, State 1, Line 3: Incorrect syntax near the keyword 'WHERE'.
    ),
  )
  inspect(
    sx("SELECT 1\n\n  SELECT (1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 3: Incorrect syntax near '1'.
    ),
  )
  inspect(
    sx("SELECT 'abc"),
    content=(
      #|Msg 105, Level 15, State 1, Line 1: Unclosed quotation mark after the character string 'abc'.
    ),
  )
  inspect(
    sx("SELECT 1 /* never closed"),
    content=(
      #|Msg 113, Level 15, State 1, Line 1: Missing end comment mark '*/'.
    ),
  )
  inspect(
    sx("SELECT [abc"),
    content=(
      #|Msg 105, Level 15, State 1, Line 1: Unclosed quotation mark after the character string 'abc'.
    ),
  )
  inspect(
    sx("SELECT 1 ? 2"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '?'.
    ),
  )
  inspect(
    sx("%%%"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '%'.
    ),
  )
  inspect(
    sx("SELECT 1 !"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near '!'.
    ),
  )
  inspect(
    sx("[t]"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 't'.
    ),
  )
  inspect(
    sx("foo"),
    content=(
      #|Msg 102, Level 15, State 1, Line 1: Incorrect syntax near 'foo'.
    ),
  )
  inspect(
    sx("SELECT 'it''s' x\nFROM t\nWHERE y = 'a'\n  AND z = = 1"),
    content=(
      #|Msg 102, Level 15, State 1, Line 4: Incorrect syntax near '='.
    ),
  )
}

///|
test "error accessors" {
  let e = try @parse.parse_batch("SELECT 1\nSELECT FROM") catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  guard e is Some(e) else { fail("expected an error") }
  inspect(
    e.number(),
    content=(
      #|156
    ),
  )
  inspect(
    e.line(),
    content=(
      #|2
    ),
  )
  inspect(
    e.message(),
    content=(
      #|Incorrect syntax near the keyword 'FROM'.
    ),
  )
}

///|
test "nesting too deeply is an error, not a crash" {
  let deep = "(".repeat(5000) + "1" + ")".repeat(5000)
  inspect(
    ex(deep),
    content=(
      #|Msg 191, Level 15, State 1, Line 1: Some part of your SQL statement is nested too deeply. Rewrite the query or break it up into smaller queries.
    ),
  )
  let deep_if = "IF 1 = 1 ".repeat(3000) + "PRINT 1"
  inspect(
    sx(deep_if).length() > 0,
    content=(
      #|true
    ),
  )
}

///|
test "spans and definitions" {
  let src = "PRINT 1\n  CREATE PROC p AS\n  SELECT 1"
  let ss = @parse.parse_batch("CREATE PROC p AS\n  SELECT 1;\n  SELECT 2") catch {
    _ => []
  }
  inspect(
    ss.length(),
    content=(
      #|1
    ),
  )
  match ss[0].kind {
    CreateProcedure(p) => {
      inspect(
        p.definition,
        content=(
          #|CREATE PROC p AS
          #|  SELECT 1;
          #|  SELECT 2
        ),
      )
      inspect(
        p.body[1].span.line,
        content=(
          #|3
        ),
      )
      inspect(
        p.body[1].span.col,
        content=(
          #|3
        ),
      )
    }
    _ => fail("expected a procedure")
  }
  inspect(
    sx(src),
    content=(
      #|Msg 111, Level 15, State 1, Line 2: 'CREATE/ALTER PROCEDURE' must be the first statement in a query batch.
    ),
  )
  let s = @parse.parse_statement("SELECT a +\n   b FROM t") catch {
    _ => panic()
  }
  debug_inspect(
    s.span,
    content=(
      #|{ start: 0, end: 22, line: 1, col: 1 }
    ),
  )
  guard s.kind is Select({ body: Select(sel), .. }) else { fail("select") }
  guard sel.items[0].kind is ExprItem(e, ..) else { fail("item") }
  debug_inspect(
    e.span,
    content=(
      #|{ start: 7, end: 15, line: 1, col: 8 }
    ),
  )
  guard e.kind is Binary(_, _, b) else { fail("binary") }
  debug_inspect(
    b.span,
    content=(
      #|{ start: 14, end: 15, line: 2, col: 4 }
    ),
  )
}
