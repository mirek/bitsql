///|
/// PIVOT / UNPIVOT operators after a table source (also after a join tree:
/// `a JOIN b ON .. PIVOT (..) p` pivots the join) and the TABLESAMPLE clause
/// of a table (captured: harness/corpus/analytic/pivot*.sql, tablesample.sql).

///|
fn Parser::pivot_tail(
  self : Parser,
  src : @ast.TableRef,
) -> @ast.TableRef raise @ast.SyntaxError {
  let mut src = src
  while self.is_kw("PIVOT") || self.is_kw("UNPIVOT") {
    let unpivot = self.is_kw("UNPIVOT")
    self.pos += 1
    self.expect_punct("(")
    let clause : @ast.PivotClause = if unpivot {
      let value = self.ident()
      self.expect_kw("FOR")
      let name = self.ident()
      self.expect_kw("IN")
      self.expect_punct("(")
      let columns = [self.object_name().parts]
      while self.eat_punct(",") {
        columns.push(self.object_name().parts)
      }
      self.expect_punct(")")
      Unpivot(value~, name~, columns~)
    } else {
      // the aggregate takes exactly one column name: `COUNT(*)`,
      // `SUM(a + 1)`, `SUM(DISTINCT a)`, `SUM(a), SUM(b)` are syntax errors
      // at the offending token
      let agg = self.object_name()
      self.expect_punct("(")
      let value = self.object_name().parts
      self.expect_punct(")")
      self.expect_kw("FOR")
      let column = self.object_name().parts
      self.expect_kw("IN")
      self.expect_punct("(")
      let values = [self.ident()]
      while self.eat_punct(",") {
        values.push(self.ident())
      }
      self.expect_punct(")")
      Pivot(agg~, value~, column~, values~)
    }
    self.expect_punct(")")
    ignore(self.eat_kw("AS"))
    let alias_ = self.ident()
    // captured: `PIVOT (..) AS p (a, b)` is 102 near 'a', not near '('
    if self.is_punct("(") {
      self.pos += 1
      raise self.error()
    }
    src = { kind: Pivot(src, clause, alias_~), span: src.span.to(self.prev()), }
  }
  src
}

///|
/// `TABLESAMPLE [SYSTEM] (n [PERCENT | ROWS]) [REPEATABLE (seed)]` after a
/// table name and alias, kept as a table hint named TABLESAMPLE whose args
/// are the size text, the unit and optionally the seed text. Sizes and
/// seeds are number literals (optionally negative), NULL or a variable;
/// the binder reports 476/479/482/497 for them.
fn Parser::tablesample(
  self : Parser,
) -> Array[@ast.TableHint] raise @ast.SyntaxError {
  if !self.is_kw("TABLESAMPLE") {
    return []
  }
  let start = self.start()
  self.pos += 1
  ignore(self.eat_kw("SYSTEM"))
  self.expect_punct("(")
  let size = self.sample_number()
  let unit = if self.eat_kw("PERCENT") {
    "PERCENT"
  } else if self.eat_kw("ROWS") {
    "ROWS"
  } else {
    "PERCENT"
  }
  self.expect_punct(")")
  let args = [size, unit]
  if self.eat_kw("REPEATABLE") {
    self.expect_punct("(")
    args.push(self.sample_number())
    self.expect_punct(")")
  }
  [{ name: "TABLESAMPLE", args, span: self.span_from(start), }]
}

///|
fn Parser::sample_number(self : Parser) -> String raise @ast.SyntaxError {
  let neg = self.eat_punct("-")
  let t = self.peek()
  match t.kind {
    IntNum | DecimalNum | FloatNum => {
      self.pos += 1
      if neg {
        "-" + t.text
      } else {
        t.text
      }
    }
    // captured: 497 is a compile error of the whole batch
    Variable if !neg =>
      raise syntax_error(
        497,
        "Variables are not allowed in the TABLESAMPLE or REPEATABLE clauses.",
        t.span,
      )
    Word if !neg && upper(t) == "NULL" => {
      self.pos += 1
      "NULL"
    }
    _ => raise self.error()
  }
}
