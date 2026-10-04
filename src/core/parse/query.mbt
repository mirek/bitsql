///|
/// `WITH name [(cols)] AS (query), ...`
fn Parser::ctes(self : Parser) -> Array[@ast.Cte] raise @ast.SyntaxError {
  self.expect_kw("WITH")
  let out : Array[@ast.Cte] = []
  while true {
    let start = self.start()
    let name = self.ident()
    let columns = if self.is_punct("(") { self.paren_idents() } else { [] }
    self.expect_kw("AS")
    self.expect_punct("(")
    let query = self.query()
    self.expect_punct(")")
    out.push({ name, columns, query, span: self.span_from(start), })
    if !self.eat_punct(",") {
      break
    }
  }
  out
}

///|
/// Full query expression with optional leading CTEs.
fn Parser::query(self : Parser) -> @ast.Query raise @ast.SyntaxError {
  let start = self.start()
  let ctes = if self.is_kw("WITH") { self.ctes() } else { [] }
  self.query_with(ctes, start)
}

///|
fn Parser::query_with(
  self : Parser,
  ctes : Array[@ast.Cte],
  start : @ast.Span,
) -> @ast.Query raise @ast.SyntaxError {
  self.enter()
  let body = self.query_body()
  let order_by = if self.is_kw("ORDER") {
    self.pos += 1
    self.expect_kw("BY")
    self.order_items()
  } else {
    []
  }
  let mut offset = None
  let mut fetch = None
  if self.is_kw("OFFSET") && order_by.length() > 0 {
    self.pos += 1
    offset = Some(self.scalar())
    if !self.eat_kw("ROWS") {
      self.expect_kw("ROW")
    }
    if self.eat_kw("FETCH") {
      if !self.eat_kw("NEXT") {
        self.expect_kw("FIRST")
      }
      fetch = Some(self.scalar())
      if !self.eat_kw("ROWS") {
        self.expect_kw("ROW")
      }
      self.expect_kw("ONLY")
    }
  }
  let for_clause = if self.is_kw("FOR") &&
    (
      self.is_kw_at(1, "JSON") ||
      self.is_kw_at(1, "XML") ||
      self.is_kw_at(1, "BROWSE")
    ) {
    Some(self.for_clause())
  } else {
    None
  }
  let options = self.query_hints()
  self.leave()
  {
    ctes,
    body,
    order_by,
    offset,
    fetch,
    for_clause,
    options,
    span: self.span_from(start),
  }
}

///|
/// `OPTION ( hint, ... )` as upper-cased token text per hint.
fn Parser::query_hints(
  self : Parser,
) -> Array[@ast.QueryHint] raise @ast.SyntaxError {
  let out = []
  if !self.eat_kw("OPTION") {
    return out
  }
  self.expect_punct("(")
  while true {
    let start = self.start()
    let text = self.balanced_text()
    if text == "" {
      raise self.error()
    }
    out.push({ text, span: self.span_from(start), })
    if !self.eat_punct(",") {
      break
    }
  }
  self.expect_punct(")")
  out
}

///|
/// Token text up to the next top-level `,` or `)`, words upper-cased and
/// joined by single spaces (strings re-quoted).
fn Parser::balanced_text(
  self : Parser,
  upper_words? : Bool = true,
) -> String raise @ast.SyntaxError {
  let sb = StringBuilder()
  let mut depth = 0
  let mut first = true
  while true {
    let t = self.peek()
    match t.kind {
      Eof => raise self.error()
      Punct if depth == 0 && (t.text == "," || t.text == ")") => break
      _ => ()
    }
    if t.is_punct("(") {
      depth += 1
    } else if t.is_punct(")") {
      depth -= 1
    }
    if !first {
      sb.write_char(' ')
    }
    first = false
    match t.kind {
      Word => sb.write_string(if upper_words { upper(t) } else { t.text })
      Str => sb.write_string("'\{t.text}'")
      NStr => sb.write_string("N'\{t.text}'")
      QuotedIdent => sb.write_string("[\{t.text}]")
      _ => sb.write_string(t.text)
    }
    self.pos += 1
  }
  sb.to_string()
}

///|
fn Parser::for_clause(self : Parser) -> @ast.ForClause raise @ast.SyntaxError {
  self.expect_kw("FOR")
  if self.eat_kw("BROWSE") {
    return ForBrowse
  }
  if self.eat_kw("JSON") {
    let mode : @ast.JsonMode = if self.eat_kw("PATH") {
      JsonPath
    } else {
      self.expect_kw("AUTO")
      JsonAuto
    }
    let mut root = None
    let mut include_null_values = false
    let mut without_array_wrapper = false
    while self.eat_punct(",") {
      let t = self.peek()
      if t.is_kw("ROOT") && root is None {
        self.pos += 1
        if self.eat_punct("(") {
          let s = self.peek()
          if !(s.kind is Str || s.kind is NStr) {
            raise self.error()
          }
          self.pos += 1
          root = Some(s.text)
          self.expect_punct(")")
        } else {
          root = Some("root")
        }
      } else if t.is_kw("INCLUDE_NULL_VALUES") && !include_null_values {
        self.pos += 1
        include_null_values = true
      } else if t.is_kw("WITHOUT_ARRAY_WRAPPER") && !without_array_wrapper {
        self.pos += 1
        without_array_wrapper = true
      } else {
        raise self.error()
      }
    }
    return ForJson(mode~, root~, include_null_values~, without_array_wrapper~)
  }
  let xml = self.peek()
  self.expect_kw("XML")
  let m = self.peek()
  if !(m.is_kw("RAW") ||
    m.is_kw("AUTO") ||
    m.is_kw("PATH") ||
    m.is_kw("EXPLICIT")) {
    raise self.error()
  }
  self.pos += 1
  let mode = upper(m)
  let element = self.opt_paren_string()
  let options = []
  while self.eat_punct(",") {
    let t = self.peek()
    if !(t.kind is Word) ||
      !(upper(t)
      is ("TYPE" | "ROOT" | "ELEMENTS" | "BINARY" | "XMLSCHEMA" | "XMLDATA")) {
      raise self.error()
    }
    self.pos += 1
    let mut text = upper(t)
    if text == "ELEMENTS" && (self.is_kw("XSINIL") || self.is_kw("ABSENT")) {
      text = text + " " + upper(self.advance())
    } else if text == "BINARY" {
      self.expect_kw("BASE64")
      text = "BINARY BASE64"
    }
    match self.opt_paren_string() {
      Some(s) => text = text + "('" + s + "')"
      None => ()
    }
    if options.contains(text) {
      raise near(xml)
    }
    options.push(text)
  }
  ForXml(mode~, element~, options~)
}

///|
fn Parser::opt_paren_string(self : Parser) -> String? raise @ast.SyntaxError {
  if !self.is_punct("(") {
    return None
  }
  self.pos += 1
  let s = self.peek()
  if !(s.kind is Str || s.kind is NStr) {
    raise self.error()
  }
  self.pos += 1
  self.expect_punct(")")
  Some(s.text)
}

///|
/// UNION / EXCEPT over INTERSECT terms.
fn Parser::query_body(self : Parser) -> @ast.QueryBody raise @ast.SyntaxError {
  let mut left = self.intersect_term()
  while true {
    let op : @ast.SetOp = if self.is_kw("UNION") {
      self.pos += 1
      if self.eat_kw("ALL") {
        UnionAll
      } else {
        Union
      }
    } else if self.is_kw("EXCEPT") {
      self.pos += 1
      Except
    } else {
      break
    }
    let right = self.intersect_term()
    left = SetOperation(op, left, right)
  }
  left
}

///|
fn Parser::intersect_term(
  self : Parser,
) -> @ast.QueryBody raise @ast.SyntaxError {
  let mut left = self.query_primary()
  while self.eat_kw("INTERSECT") {
    let right = self.query_primary()
    left = SetOperation(Intersect, left, right)
  }
  left
}

///|
fn Parser::query_primary(
  self : Parser,
) -> @ast.QueryBody raise @ast.SyntaxError {
  if self.is_punct("(") {
    self.pos += 1
    let q = self.query()
    self.expect_punct(")")
    Nested(q)
  } else if self.is_kw("SELECT") {
    Select(self.select_core())
  } else {
    raise self.error()
  }
}

///|
fn Parser::top(
  self : Parser,
  allow_bare : Bool,
) -> @ast.Top? raise @ast.SyntaxError {
  let start = self.start()
  if !self.eat_kw("TOP") {
    return None
  }
  let (count, parenthesized) = if self.eat_punct("(") {
    let e = self.scalar()
    self.expect_punct(")")
    (e, true)
  } else {
    let t = self.peek()
    if allow_bare &&
      (t.kind is IntNum || t.kind is DecimalNum || t.kind is FloatNum) {
      self.pos += 1
      let kind : @ast.ExprKind = match t.kind {
        IntNum => IntLit(t.text)
        DecimalNum => DecimalLit(t.text)
        _ => FloatLit(t.text)
      }
      ({ kind, span: t.span, }, false)
    } else {
      raise self.error()
    }
  }
  let percent = self.eat_kw("PERCENT")
  let with_ties = if self.is_kw("WITH") && self.is_kw_at(1, "TIES") {
    self.pos += 2
    true
  } else {
    false
  }
  Some({
    count,
    percent,
    with_ties,
    parenthesized,
    span: self.span_from(start),
  })
}

///|
fn Parser::select_core(self : Parser) -> @ast.Select raise @ast.SyntaxError {
  let start = self.start()
  self.expect_kw("SELECT")
  let distinct = if self.eat_kw("DISTINCT") {
    true
  } else {
    ignore(self.eat_kw("ALL"))
    false
  }
  let top = self.top(true)
  let items = self.select_items(true)
  let into = if self.eat_kw("INTO") { Some(self.object_name()) } else { None }
  let from = if self.eat_kw("FROM") { self.from_list() } else { [] }
  let where_ = if self.eat_kw("WHERE") { Some(self.cond()) } else { None }
  let group_by = if self.is_kw("GROUP") {
    self.pos += 1
    self.expect_kw("BY")
    self.group_items()
  } else {
    []
  }
  let having = if self.eat_kw("HAVING") { Some(self.cond()) } else { None }
  {
    distinct,
    top,
    items,
    into,
    from,
    where_,
    group_by,
    having,
    span: self.span_from(start),
  }
}

///|
fn Parser::from_list(
  self : Parser,
) -> Array[@ast.TableRef] raise @ast.SyntaxError {
  let out = [self.table_ref()]
  while self.eat_punct(",") {
    out.push(self.table_ref())
  }
  out
}

///|
fn assign_op(t : @lex.Token) -> @ast.AssignOp? {
  if !(t.kind is Punct) {
    return None
  }
  match t.text {
    "=" => Some(Assign)
    "+=" => Some(AddAssign)
    "-=" => Some(SubAssign)
    "*=" => Some(MulAssign)
    "/=" => Some(DivAssign)
    "%=" => Some(ModAssign)
    "&=" => Some(AndAssign)
    "|=" => Some(OrAssign)
    "^=" => Some(XorAssign)
    _ => None
  }
}

///|
fn Parser::select_items(
  self : Parser,
  allow_assign : Bool,
) -> Array[@ast.SelectItem] raise @ast.SyntaxError {
  let items = [self.select_item(allow_assign)]
  while self.eat_punct(",") {
    items.push(self.select_item(allow_assign))
  }
  items
}

///|
/// Length of `ident(.ident)*.*` at the cursor, or 0.
fn Parser::qualified_star_len(self : Parser) -> Int {
  let mut k = 0
  while true {
    let t = self.peek_at(k)
    if !(t.kind is Word || t.kind is QuotedIdent) ||
      !self.is_punct_at(k + 1, ".") {
      return 0
    }
    if self.is_punct_at(k + 2, "*") {
      return k + 3
    }
    k += 2
  }
  0
}

///|
fn Parser::select_item(
  self : Parser,
  allow_assign : Bool,
) -> @ast.SelectItem raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  if t.is_punct("*") {
    self.pos += 1
    return { kind: Star([]), span: t.span, }
  }
  if allow_assign &&
    t.kind is Variable &&
    assign_op(self.peek_at(1)) is Some(op) {
    self.pos += 2
    let e = self.scalar()
    return { kind: Assign(t.text, op, e), span: self.span_from(start), }
  }
  let n = self.qualified_star_len()
  if n > 0 {
    let quals = []
    for i = 0; i < n - 1; i = i + 2 {
      quals.push(tok_ident(self.peek_at(i)))
    }
    self.pos += n
    return { kind: Star(quals), span: self.span_from(start), }
  }
  // `alias = expr`
  if self.is_punct_at(1, "=") &&
    (
      t.kind is QuotedIdent ||
      t.kind is Str ||
      t.kind is NStr ||
      (t.kind is Word && !is_reserved(t.text))
    ) {
    self.pos += 2
    let e = self.scalar()
    let alias_ : @ast.Ident = {
      name: t.text,
      quoted: !(t.kind is Word),
      span: t.span,
    }
    return {
      kind: ExprItem(e, alias_=Some(alias_)),
      span: self.span_from(start),
    }
  }
  let e = self.scalar()
  let alias_ = self.column_alias()
  { kind: ExprItem(e, alias_~), span: self.span_from(start), }
}

///|
/// `[AS] alias` after a select-list expression (identifier or string).
fn Parser::column_alias(self : Parser) -> @ast.Ident? raise @ast.SyntaxError {
  let has_as = self.eat_kw("AS")
  let t = self.peek()
  if t.kind is Str || t.kind is NStr {
    self.pos += 1
    return Some({ name: t.text, quoted: true, span: t.span, })
  }
  if self.at_ident() {
    return Some(self.ident())
  }
  if has_as {
    raise self.error()
  }
  None
}

///|
/// `[AS] alias` after a table source. `USING` is a bare alias anywhere but
/// after a MERGE target (captured: msduck gaps-identifiers using-alias-bare,
/// `FROM using using`).
fn Parser::table_alias(
  self : Parser,
  merge_target? : Bool = false,
) -> @ast.Ident? raise @ast.SyntaxError {
  if self.eat_kw("AS") {
    return Some(self.ident())
  }
  if self.at_ident() && !(merge_target && self.is_kw("USING")) {
    Some(self.ident())
  } else {
    None
  }
}

///|
fn Parser::group_items(
  self : Parser,
) -> Array[@ast.GroupItem] raise @ast.SyntaxError {
  let out = [self.group_item(false)]
  while self.eat_punct(",") {
    out.push(self.group_item(false))
  }
  out
}

///|
fn Parser::group_item(
  self : Parser,
  in_sets : Bool,
) -> @ast.GroupItem raise @ast.SyntaxError {
  if self.is_punct("(") && self.is_punct_at(1, ")") {
    self.pos += 2
    return GroupEmpty
  }
  if (self.is_kw("ROLLUP") || self.is_kw("CUBE")) && self.is_punct_at(1, "(") {
    let is_rollup = self.is_kw("ROLLUP")
    self.pos += 2
    let units = [self.group_unit()]
    while self.eat_punct(",") {
      units.push(self.group_unit())
    }
    self.expect_punct(")")
    return if is_rollup { Rollup(units) } else { Cube(units) }
  }
  if !in_sets && self.is_kw("GROUPING") && self.is_kw_at(1, "SETS") {
    self.pos += 2
    self.expect_punct("(")
    let sets = [self.group_item(true)]
    while self.eat_punct(",") {
      sets.push(self.group_item(true))
    }
    self.expect_punct(")")
    return GroupingSets(sets)
  }
  if in_sets && self.is_punct("(") {
    self.pos += 1
    let es = [self.scalar()]
    while self.eat_punct(",") {
      es.push(self.scalar())
    }
    self.expect_punct(")")
    return GroupTuple(es)
  }
  GroupExpr(self.scalar())
}

///|
fn Parser::group_unit(self : Parser) -> Array[@ast.Expr] raise @ast.SyntaxError {
  if self.is_punct("(") {
    self.pos += 1
    let es = [self.scalar()]
    while self.eat_punct(",") {
      es.push(self.scalar())
    }
    self.expect_punct(")")
    es
  } else {
    [self.scalar()]
  }
}

///|
fn Parser::join_kind(
  self : Parser,
) -> (@ast.JoinKind, String?)? raise @ast.SyntaxError {
  let t = self.peek()
  if !(t.kind is Word) {
    return None
  }
  let u = upper(t)
  match u {
    "JOIN" => {
      self.pos += 1
      Some((Inner, None))
    }
    "INNER" | "LEFT" | "RIGHT" | "FULL" => {
      // LEFT( / RIGHT( would be a function, not a join.
      if self.is_punct_at(1, "(") {
        return None
      }
      self.pos += 1
      if u != "INNER" {
        ignore(self.eat_kw("OUTER"))
      }
      let hint = self.join_hint()
      self.expect_kw("JOIN")
      let kind : @ast.JoinKind = match u {
        "INNER" => Inner
        "LEFT" => Left
        "RIGHT" => Right
        _ => Full
      }
      Some((kind, hint))
    }
    "CROSS" =>
      if self.is_kw_at(1, "JOIN") {
        self.pos += 2
        Some((Cross, None))
      } else if self.is_kw_at(1, "APPLY") {
        self.pos += 2
        Some((CrossApply, None))
      } else {
        raise near(self.peek_at(1))
      }
    "OUTER" =>
      if self.is_kw_at(1, "APPLY") {
        self.pos += 2
        Some((OuterApply, None))
      } else {
        raise near(self.peek_at(1))
      }
    "LOOP" | "HASH" | "MERGE" | "REMOTE" if self.is_kw_at(1, "JOIN") => {
      self.pos += 2
      Some((Inner, Some(u)))
    }
    _ => None
  }
}

///|
fn Parser::join_hint(self : Parser) -> String? {
  let t = self.peek()
  if (
      t.is_kw("LOOP") ||
      t.is_kw("HASH") ||
      t.is_kw("MERGE") ||
      t.is_kw("REMOTE")
    ) &&
    self.is_kw_at(1, "JOIN") {
    self.pos += 1
    Some(upper(t))
  } else {
    None
  }
}

///|
fn Parser::table_ref(self : Parser) -> @ast.TableRef raise @ast.SyntaxError {
  self.enter()
  let left = self.table_primary()
  let r = self.join_tail(left)
  self.leave()
  r
}

///|
fn Parser::join_tail(
  self : Parser,
  left : @ast.TableRef,
) -> @ast.TableRef raise @ast.SyntaxError {
  let mut left = self.pivot_tail(left)
  while self.join_kind() is Some((kind, hint)) {
    let right = self.table_primary()
    match kind {
      Cross | CrossApply | OuterApply =>
        left = {
          kind: Join(kind, left, right, on=None, hint~),
          span: left.span.to(self.prev()),
        }
      _ => {
        // Nested form: `a JOIN b JOIN c ON .. ON ..`.
        let right = if self.is_kw("ON") {
          right
        } else {
          self.enter()
          let r = self.join_tail(right)
          self.leave()
          r
        }
        self.expect_kw("ON")
        let on = self.cond()
        left = {
          kind: Join(kind, left, right, on=Some(on), hint~),
          span: left.span.to(self.prev()),
        }
      }
    }
    left = self.pivot_tail(left)
  }
  left
}

///|
/// `WITH ( hint [, hint] )` table hints.
fn Parser::table_hints(
  self : Parser,
) -> Array[@ast.TableHint] raise @ast.SyntaxError {
  let out = []
  if !(self.is_kw("WITH") && self.is_punct_at(1, "(")) {
    return out
  }
  self.pos += 2
  while true {
    let start = self.start()
    let t = self.peek()
    if !(t.kind is Word) {
      raise self.error()
    }
    self.pos += 1
    let args = []
    if self.eat_punct("(") {
      while true {
        args.push(self.balanced_text(upper_words=false))
        if !self.eat_punct(",") {
          break
        }
      }
      self.expect_punct(")")
    } else if self.eat_punct("=") {
      args.push(self.balanced_text_until_hint_end())
    }
    out.push({ name: upper(t), args, span: self.span_from(start), })
    if self.eat_punct(")") {
      break
    }
    ignore(self.eat_punct(","))
  }
  out
}

///|
fn Parser::balanced_text_until_hint_end(
  self : Parser,
) -> String raise @ast.SyntaxError {
  let t = self.peek()
  match t.kind {
    Word | QuotedIdent | IntNum => {
      self.pos += 1
      t.text
    }
    _ => raise self.error()
  }
}

///|
fn Parser::table_primary(self : Parser) -> @ast.TableRef raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  if t.is_punct("(") {
    if self.is_kw_at(1, "VALUES") {
      self.pos += 2
      let rows = self.values_rows()
      self.expect_punct(")")
      ignore(self.eat_kw("AS"))
      let alias_ = self.ident()
      let columns = if self.is_punct("(") { self.paren_idents() } else { [] }
      return {
        kind: Values(rows, alias_~, columns~),
        span: self.span_from(start),
      }
    }
    if self.at_query_start_at(1) {
      let nested = self.is_punct_at(1, "(")
      let saved = self.pos
      let depth = self.depth
      let q : @ast.Query? = try {
        self.pos += 1
        let q = self.query()
        self.expect_punct(")")
        Some(q)
      } catch {
        e => if nested { None } else { raise e }
      }
      match q {
        Some(q) => {
          let alias_ = self.table_alias()
          let columns = if alias_ is Some(_) && self.is_punct("(") {
            self.paren_idents()
          } else {
            []
          }
          return {
            kind: Derived(q, alias_~, columns~),
            span: self.span_from(start),
          }
        }
        None => {
          self.pos = saved
          self.depth = depth
        }
      }
    }
    // Parenthesised join.
    self.pos += 1
    let r = self.table_ref()
    self.expect_punct(")")
    return r
  }
  if t.kind is Variable &&
    self.is_punct_at(1, ".") &&
    self.peek_at(2).kind is Word &&
    self.is_punct_at(3, "(") {
    // `@x.nodes('/a/b') AS T(c)`
    self.pos += 2
    let m = self.advance()
    if m.text != "nodes" {
      raise near(m)
    }
    let args = self.method_args()
    return self.nodes_ref(start, mk(Var(t.text), t.span), args)
  }
  if t.kind is Variable {
    self.pos += 1
    let alias_ = self.table_alias()
    // no hints on table variables: a following WITH starts a new statement
    // (319 when the previous one is unterminated; captured:
    // tail/table-hints-gaps)
    return {
      kind: TableVar(t.text, alias_~, hints=[]),
      span: self.span_from(start),
    }
  }
  let name = self.object_name()
  let np = name.parts.length()
  if self.is_punct("(") &&
    np >= 2 &&
    !name.parts[np - 1].quoted &&
    name.parts[np - 1].name == "nodes" {
    // `t.col.nodes('/a/b') AS T(c)`
    let target = name.parts[0:np - 1].to_owned()
    let args = self.method_args()
    return self.nodes_ref(start, mk(Column(target), name.span), args)
  }
  if self.is_punct("(") {
    self.pos += 1
    // `t (INDEX(0))`: an index hint needs WITH (captured: 1018,
    // tail/table-hints-gaps)
    if self.is_kw("INDEX") {
      let x = self.peek()
      raise syntax_error(
        1018,
        "Incorrect syntax near '\{x.text}'. If this is intended as a part of a table hint, A WITH keyword and parenthesis are now required. See SQL Server Books Online for proper syntax.",
        x.span,
      )
    }
    let args = []
    if !self.is_punct(")") {
      args.push(self.call_arg())
      while self.eat_punct(",") {
        args.push(self.call_arg())
      }
    }
    self.expect_punct(")")
    let openjson_with = if eq_upper_name(name, "OPENJSON") &&
      self.is_kw("WITH") &&
      self.is_punct_at(1, "(") {
      self.pos += 2
      let cols = [self.openjson_column()]
      while self.eat_punct(",") {
        cols.push(self.openjson_column())
      }
      self.expect_punct(")")
      Some(cols)
    } else {
      None
    }
    let alias_ = self.table_alias()
    let columns = if alias_ is Some(_) && self.is_punct("(") {
      self.paren_idents()
    } else {
      []
    }
    return {
      kind: TableFunc(name, args, openjson_with~, alias_~, columns~),
      span: self.span_from(start),
    }
  }
  let alias_ = self.table_alias()
  // `t alias (NOLOCK)`: one hint without WITH (captured: tail/table-hints)
  if alias_ is Some(_) &&
    self.is_punct("(") &&
    self.peek_at(1).kind is Word &&
    self.is_punct_at(2, ")") &&
    legacy_hint_words.contains(upper(self.peek_at(1))) {
    let h = self.peek_at(1)
    self.pos += 3
    return {
      kind: Table(name, alias_~, hints=[
        { name: upper(h), args: [], span: h.span, },
      ]),
      span: self.span_from(start),
    }
  }
  let hints = self.tablesample() + self.table_hints()
  { kind: Table(name, alias_~, hints~), span: self.span_from(start), }
}

///|
/// Hints allowed without WITH when they are the only one (documented).
let legacy_hint_words : Array[String] = [
  "NOLOCK", "READUNCOMMITTED", "UPDLOCK", "REPEATABLEREAD", "SERIALIZABLE", "READCOMMITTED",
  "TABLOCK", "TABLOCKX", "PAGLOCK", "ROWLOCK", "NOWAIT", "READPAST", "XLOCK", "HOLDLOCK",
]

///|
/// The alias and column list after `x.nodes(...)`.
fn Parser::nodes_ref(
  self : Parser,
  start : @ast.Span,
  target : @ast.Expr,
  args : Array[@ast.Expr],
) -> @ast.TableRef raise @ast.SyntaxError {
  let alias_ = self.table_alias()
  let columns = if alias_ is Some(_) && self.is_punct("(") {
    self.paren_idents()
  } else {
    []
  }
  { kind: Nodes(target, args, alias_~, columns~), span: self.span_from(start), }
}

///|
fn eq_upper_name(name : @ast.ObjectName, upper : String) -> Bool {
  name.parts.length() == 1 && @lex.eq_upper(name.parts[0].name, upper)
}

///|
fn Parser::openjson_column(
  self : Parser,
) -> @ast.OpenJsonColumn raise @ast.SyntaxError {
  let start = self.start()
  let name = self.ident()
  let type_ = self.type_name()
  let t = self.peek()
  let path = if t.kind is Str || t.kind is NStr {
    self.pos += 1
    Some(t.text)
  } else {
    None
  }
  let as_json = if self.is_kw("AS") && self.is_kw_at(1, "JSON") {
    self.pos += 2
    true
  } else {
    false
  }
  { name, type_, path, as_json, span: self.span_from(start), }
}

///|
/// `(a, b), (c, d)` rows after VALUES; items may be DEFAULT.
fn Parser::values_rows(
  self : Parser,
) -> Array[Array[@ast.Expr]] raise @ast.SyntaxError {
  let rows = [self.values_row()]
  while self.eat_punct(",") {
    rows.push(self.values_row())
  }
  rows
}

///|
fn Parser::values_row(self : Parser) -> Array[@ast.Expr] raise @ast.SyntaxError {
  self.expect_punct("(")
  let row = [self.call_arg()]
  while self.eat_punct(",") {
    row.push(self.call_arg())
  }
  self.expect_punct(")")
  row
}
