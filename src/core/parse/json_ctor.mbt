///|
/// `JSON_OBJECT(k : v, ... [NULL|ABSENT ON NULL] [RETURNING json])` and
/// `JSON_ARRAY(v, ... [NULL|ABSENT ON NULL] [RETURNING json])` (SQL Server
/// 2022). Represented as a call whose name carries the clauses, like the
/// TRIM forms: `JSON_OBJECT`, `JSON_OBJECT ABSENT ON NULL`,
/// `JSON_ARRAY NULL ON NULL`, plus ` RETURNING JSON`. JSON_OBJECT's
/// arguments alternate key and value. The current token is the name.
fn Parser::json_ctor(
  self : Parser,
  object : Bool,
) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let name_tok = self.advance()
  self.expect_punct("(")
  let args = []
  let mut clause = ""
  if !self.is_punct(")") {
    while true {
      if (self.is_kw("NULL") && self.is_kw_at(1, "ON")) ||
        (self.is_kw("ABSENT") && self.is_kw_at(1, "ON")) {
        break
      }
      if object {
        let k = self.scalar()
        if !self.eat_punct(":") {
          // captured: JSON_OBJECT('a', 1) is 102 state 10 near the name
          raise @ast.SyntaxError(
            number=102,
            severity=15,
            state=10,
            message="Incorrect syntax near '\{name_tok.text}'.",
            span=name_tok.span,
          )
        }
        args.push(k)
      }
      args.push(self.scalar())
      if !self.eat_punct(",") {
        break
      }
    }
    if self.is_kw("NULL") || self.is_kw("ABSENT") {
      clause = if self.is_kw("NULL") {
        " NULL ON NULL"
      } else {
        " ABSENT ON NULL"
      }
      self.pos += 1
      self.expect_kw("ON")
      self.expect_kw("NULL")
    }
    if self.is_kw("RETURNING") {
      self.returning_json(object)
      clause = clause + " RETURNING JSON"
    }
  }
  self.expect_punct(")")
  let fname = (if object { "JSON_OBJECT" } else { "JSON_ARRAY" }) + clause
  let name : @ast.ObjectName = {
    parts: [{ name: fname, quoted: false, span: name_tok.span, }],
    span: name_tok.span,
  }
  mk(
    Call({
      name,
      args,
      distinct: false,
      star: false,
      niladic: false,
      within_group: [],
      over: None,
    }),
    self.span_from(start),
  )
}

///|
/// `JSON_ARRAYAGG(v [ORDER BY ...] [NULL|ABSENT ON NULL] [RETURNING json])`
/// and `JSON_OBJECTAGG(k : v [NULL|ABSENT ON NULL] [RETURNING json])` (SQL
/// Server 2025). The call keeps its plain name (so it is an aggregate);
/// the clauses travel in a trailing string literal `@ast.JSON_AGG_MARKER` +
/// `N`/`A` (+ `J` for RETURNING json), and an inner ORDER BY becomes the
/// call's WITHIN GROUP list (a real WITHIN GROUP clause is ignored). `JSON_OBJECTAGG(k, v)` parses as a plain call
/// (the binder reports 174). Syntax errors captured in msduck
/// json-aggregates (#009, #026, #028-#032, #056, #057, #061).
fn Parser::json_agg(
  self : Parser,
  object : Bool,
) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let name_tok = self.advance()
  let near_name = (state : Int) => {
    @ast.SyntaxError(
      number=102,
      severity=15,
      state~,
      message="Incorrect syntax near '\{name_tok.text}'.",
      span=name_tok.span,
    )
  }
  let name : @ast.ObjectName = {
    parts: [
      { name: name_tok.text.to_upper(), quoted: false, span: name_tok.span, },
    ],
    span: name_tok.span,
  }
  self.expect_punct("(")
  if self.eat_punct(")") {
    // captured: JSON_ARRAYAGG() is 174 (binder)
    return mk(
      Call({
        name,
        args: [],
        distinct: false,
        star: false,
        niladic: false,
        within_group: [],
        over: None,
      }),
      self.span_from(start),
    )
  }
  let mut distinct = false
  if self.is_kw("DISTINCT") {
    if object {
      // captured: "Incorrect syntax near 'k:'."
      self.pos += 1
      let t = self.peek()
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=1,
        message="Incorrect syntax near '\{t.text}:'.",
        span=t.span,
      )
    }
    self.pos += 1
    distinct = true
  }
  let args = []
  let first = self.scalar()
  args.push(first)
  if object && self.is_punct(",") {
    // JSON_OBJECTAGG(k, v): a plain call, 174 in the binder
    while self.eat_punct(",") {
      args.push(self.call_arg())
    }
    self.expect_punct(")")
    return mk(
      Call({
        name,
        args,
        distinct: false,
        star: false,
        niladic: false,
        within_group: [],
        over: None,
      }),
      self.span_from(start),
    )
  }
  if object {
    self.expect_punct(":")
    args.push(self.scalar())
    while self.eat_punct(",") {
      args.push(self.scalar())
      self.expect_punct(":")
      args.push(self.scalar())
    }
  } else if self.is_punct(":") {
    raise near_name(10)
  }
  let mut within_group = []
  if !object && self.is_kw("ORDER") && self.is_kw_at(1, "BY") {
    self.pos += 2
    within_group = self.order_items()
  }
  let mut clause = "N"
  let mut clauses = 0
  while (self.is_kw("NULL") || self.is_kw("ABSENT")) && self.is_kw_at(1, "ON") {
    if clauses > 0 {
      raise near_name(20)
    }
    clause = if self.is_kw("NULL") { "N" } else { "A" }
    clauses += 1
    self.pos += 2
    self.expect_kw("NULL")
  }
  if clauses == 0 && !object {
    // JSON_ARRAYAGG defaults to ABSENT ON NULL
    clause = "A"
  }
  if self.is_kw("RETURNING") {
    self.returning_json(object)
    clause = clause + "J"
  }
  self.expect_punct(")")
  args.push(
    mk(StrLit(@ast.JSON_AGG_MARKER + clause, national=false), name_tok.span),
  )
  if self.is_kw("WITHIN") && self.is_kw_at(1, "GROUP") {
    if object {
      // captured: 102 (not 156) near 'WITHIN'
      let t = self.peek()
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=1,
        message="Incorrect syntax near '\{t.text}'.",
        span=t.span,
      )
    }
    // captured: accepted but ignored (msduck json-aggregates#058/#059 list
    // the rows in scan order)
    self.pos += 2
    self.expect_punct("(")
    self.expect_kw("ORDER")
    self.expect_kw("BY")
    ignore(self.order_items())
    self.expect_punct(")")
  }
  let over = if self.is_kw("OVER") { Some(self.over()) } else { None }
  mk(
    Call({
      name,
      args,
      distinct,
      star: false,
      niladic: false,
      within_group,
      over,
    }),
    self.span_from(start),
  )
}

///|
/// `RETURNING JSON [(n | MAX)]` of the JSON constructors and aggregates
/// (captured json4/returning: the length is accepted and ignored; another
/// type is 102 state 19, JSON_OBJECT* with the "Supported Syntax" text).
fn Parser::returning_json(
  self : Parser,
  object : Bool,
) -> Unit raise @ast.SyntaxError {
  let r = self.advance()
  let t = self.peek()
  if !(t.kind is Word && t.text.to_upper() == "JSON") {
    raise @ast.SyntaxError(
      number=102,
      severity=15,
      state=19,
      message=if object {
        "Incorrect syntax near 'RETURNING. Supported Syntax is RETURNING JSON'."
      } else {
        "Incorrect syntax near 'RETURNING'."
      },
      span=r.span,
    )
  }
  self.pos += 1
  if self.eat_punct("(") {
    let n = self.peek()
    if n.kind is IntNum || n.is_kw("MAX") {
      self.pos += 1
    } else {
      raise self.error()
    }
    self.expect_punct(")")
  }
}

///|
/// ISJSON(x, word): an unknown bare word is SQL Server's parse error 155
/// (captured: json3/isjson-path-exists, `ISJSON(N'1', NUMBER)`); other
/// forms of the argument are the binder's 1023.
fn check_isjson_option(
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
) -> Unit raise @ast.SyntaxError {
  if name.parts.length() != 1 ||
    args.length() != 2 ||
    name.base().to_upper() != "ISJSON" {
    return
  }
  guard args[1].kind is Column([id]) else { return }
  if !(id.name.to_upper() is ("VALUE" | "ARRAY" | "OBJECT" | "SCALAR")) {
    raise syntax_error(
      155,
      "'\{id.name}' is not a recognized isjson option.",
      id.span,
    )
  }
}
