///|
/// DML target: `@t` or an object name, with optional `WITH (hints)`.
fn Parser::dml_target(self : Parser) -> @ast.TableRef raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  if t.kind is Variable {
    self.pos += 1
    let hints = self.table_hints()
    return {
      kind: TableVar(t.text, alias_=None, hints~),
      span: self.span_from(start),
    }
  }
  let name = self.object_name()
  let hints = self.table_hints()
  { kind: Table(name, alias_=None, hints~), span: self.span_from(start), }
}

///|
/// Zero or more `OUTPUT items [INTO target [(cols)]]` clauses.
fn Parser::output_clauses(
  self : Parser,
) -> Array[@ast.OutputClause] raise @ast.SyntaxError {
  let out : Array[@ast.OutputClause] = []
  while self.is_kw("OUTPUT") {
    let start = self.start()
    self.pos += 1
    // OUTPUT needs a qualified star (inserted.* / deleted.*); a bare `*` is
    // error 102 near '*' (msduck output-unqualified capture).
    let items = []
    while true {
      if self.is_punct("*") {
        raise self.error()
      }
      items.push(self.select_item(false))
      if !self.eat_punct(",") {
        break
      }
    }
    let into = if self.eat_kw("INTO") {
      let target = self.dml_target()
      let cols = if self.is_punct("(") && !self.at_query_start_at(1) {
        self.paren_idents()
      } else {
        []
      }
      Some((target, cols))
    } else {
      None
    }
    out.push({ items, into, span: self.span_from(start), })
  }
  out
}

///|
fn Parser::dml_top(self : Parser) -> @ast.Top? raise @ast.SyntaxError {
  self.top(false)
}

///|
fn Parser::insert_stmt(
  self : Parser,
  ctes : Array[@ast.Cte],
) -> @ast.Insert raise @ast.SyntaxError {
  self.expect_kw("INSERT")
  let top = self.dml_top()
  ignore(self.eat_kw("INTO"))
  let target = self.dml_target()
  let columns = if self.is_punct("(") && !self.at_query_start_at(1) {
    self.paren_idents()
  } else {
    []
  }
  let output = self.output_clauses()
  let source : @ast.InsertSource = if self.eat_kw("VALUES") {
    InsertValues(self.values_rows())
  } else if self.is_kw("DEFAULT") && self.is_kw_at(1, "VALUES") {
    self.pos += 2
    DefaultValues
  } else if self.is_kw("EXEC") || self.is_kw("EXECUTE") {
    self.pos += 1
    InsertExec(self.exec_body())
  } else if self.at_query_start() || self.is_punct("(") {
    InsertQuery(self.query())
  } else {
    raise self.error()
  }
  let options = match source {
    InsertValues(_) | DefaultValues => self.query_hints()
    _ => []
  }
  { ctes, top, target, columns, output, source, options, }
}

///|
/// `col`, `t.col`, `@v`, `@v = col` targets followed by an assignment.
fn Parser::set_clause(self : Parser) -> @ast.SetClause raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  let target : @ast.SetTarget = if t.kind is Variable {
    self.pos += 1
    // `@v = col = expr`
    if self.is_punct("=") && self.column_then_assign() {
      self.pos += 1
      let col = self.object_name()
      SetVarColumn(t.text, col.parts)
    } else {
      SetVariable(t.text)
    }
  } else {
    SetColumn(self.object_name().parts)
  }
  let op = match assign_op(self.peek()) {
    Some(op) => op
    None => raise self.error()
  }
  self.pos += 1
  let value = if self.is_kw("DEFAULT") {
    let d = self.advance()
    mk(Default, d.span)
  } else {
    self.scalar()
  }
  { target, op, value, span: self.span_from(start), }
}

///|
/// At `= name(.name)* =`?
fn Parser::column_then_assign(self : Parser) -> Bool {
  let mut k = 1
  while true {
    let t = self.peek_at(k)
    let ok = match t.kind {
      QuotedIdent => true
      Word => !is_reserved(t.text)
      _ => false
    }
    if !ok {
      return false
    }
    if self.is_punct_at(k + 1, ".") {
      k += 2
    } else {
      return assign_op(self.peek_at(k + 1)) is Some(_)
    }
  }
  false
}

///|
fn Parser::set_clauses(
  self : Parser,
) -> Array[@ast.SetClause] raise @ast.SyntaxError {
  let out = [self.set_clause()]
  while self.eat_punct(",") {
    out.push(self.set_clause())
  }
  out
}

///|
/// `WHERE cond` or `WHERE CURRENT OF cursor`.
fn Parser::dml_where(
  self : Parser,
) -> (@ast.Expr?, @ast.Ident?, Bool) raise @ast.SyntaxError {
  if !self.eat_kw("WHERE") {
    return (None, None, false)
  }
  if self.is_kw("CURRENT") && self.is_kw_at(1, "OF") {
    self.pos += 2
    let global = self.eat_kw("GLOBAL")
    (None, Some(self.cursor_name()), global)
  } else {
    (Some(self.cond()), None, false)
  }
}

///|
fn Parser::update_stmt(
  self : Parser,
  ctes : Array[@ast.Cte],
) -> @ast.Update raise @ast.SyntaxError {
  self.expect_kw("UPDATE")
  let top = self.dml_top()
  let target = self.dml_target()
  self.expect_kw("SET")
  let sets = self.set_clauses()
  let output = self.output_clauses()
  let from = if self.eat_kw("FROM") { self.from_list() } else { [] }
  let (where_, current_of, current_of_global) = self.dml_where()
  let options = self.query_hints()
  {
    ctes,
    top,
    target,
    sets,
    output,
    from,
    where_,
    current_of,
    current_of_global,
    options,
  }
}

///|
fn Parser::delete_stmt(
  self : Parser,
  ctes : Array[@ast.Cte],
) -> @ast.Delete raise @ast.SyntaxError {
  self.expect_kw("DELETE")
  let top = self.dml_top()
  ignore(self.eat_kw("FROM"))
  let target = self.dml_target()
  let output = self.output_clauses()
  let from = if self.eat_kw("FROM") { self.from_list() } else { [] }
  let (where_, current_of, current_of_global) = self.dml_where()
  let options = self.query_hints()
  {
    ctes,
    top,
    target,
    output,
    from,
    where_,
    current_of,
    current_of_global,
    options,
  }
}

///|
fn Parser::merge_stmt(
  self : Parser,
  ctes : Array[@ast.Cte],
) -> @ast.Merge raise @ast.SyntaxError {
  self.expect_kw("MERGE")
  let top = self.dml_top()
  ignore(self.eat_kw("INTO"))
  let start = self.start()
  let name = self.object_name()
  let hints = self.table_hints()
  let alias_ = self.table_alias(merge_target=true)
  let target : @ast.TableRef = {
    kind: Table(name, alias_~, hints~),
    span: self.span_from(start),
  }
  self.expect_kw("USING")
  let source = self.table_ref()
  self.expect_kw("ON")
  let on = self.cond()
  let whens : Array[@ast.MergeWhen] = []
  while self.is_kw("WHEN") {
    let wstart = self.start()
    self.pos += 1
    let match_ : @ast.MergeMatch = if self.eat_kw("MATCHED") {
      Matched
    } else {
      self.expect_kw("NOT")
      self.expect_kw("MATCHED")
      if self.eat_kw("BY") {
        if self.eat_kw("SOURCE") {
          NotMatchedBySource
        } else {
          self.expect_kw("TARGET")
          NotMatchedByTarget
        }
      } else {
        NotMatchedByTarget
      }
    }
    let condition = if self.eat_kw("AND") { Some(self.cond()) } else { None }
    self.expect_kw("THEN")
    let action : @ast.MergeAction = if self.eat_kw("UPDATE") {
      if match_ is NotMatchedByTarget {
        raise near(self.toks[self.pos - 1])
      }
      self.expect_kw("SET")
      MergeUpdate(self.set_clauses())
    } else if self.eat_kw("DELETE") {
      if match_ is NotMatchedByTarget {
        raise near(self.toks[self.pos - 1])
      }
      MergeDelete
    } else if self.eat_kw("INSERT") {
      if !(match_ is NotMatchedByTarget) {
        raise near(self.toks[self.pos - 1])
      }
      if self.is_kw("DEFAULT") && self.is_kw_at(1, "VALUES") {
        self.pos += 2
        MergeInsert(columns=[], values=[], default_values=true)
      } else {
        let columns = if self.is_punct("(") { self.paren_idents() } else { [] }
        self.expect_kw("VALUES")
        let values = self.values_row()
        MergeInsert(columns~, values~, default_values=false)
      }
    } else {
      raise self.error()
    }
    whens.push({ match_, condition, action, span: self.span_from(wstart), })
  }
  if whens.length() == 0 {
    raise self.error()
  }
  let output = self.output_clauses()
  let options = self.query_hints()
  if !self.is_punct(";") {
    raise syntax_error(
      10713,
      "A MERGE statement must be terminated by a semi-colon (;).",
      self.prev(),
    )
  }
  { ctes, top, target, source, on, whens, output, options, }
}
