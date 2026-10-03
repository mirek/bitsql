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
    if self.eat_kw("RETURNING") {
      ignore(self.ident())
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
