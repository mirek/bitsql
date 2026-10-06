///|
/// Only divert extended extraction calls; ordinary calls retain their existing
/// grammar and argument diagnostics.
fn Parser::json_extract_has_clause(self : Parser) -> Bool {
  let mut depth = 1
  let mut i = self.pos + 2
  while i < self.toks.length() && depth > 0 {
    let t = self.toks[i]
    if t.kind is Punct && t.text == "(" {
      depth += 1
    }
    if t.kind is Punct && t.text == ")" {
      depth -= 1
    }
    if depth == 1 && (t.is_kw("RETURNING") || t.is_kw("WITH")) {
      return true
    }
    i += 1
  }
  false
}

///|
/// The return type travels as an inert CAST(NULL AS type) argument. The binder
/// consumes its type; it is not an ordinary third JSON_VALUE argument.
fn Parser::json_extract(
  self : Parser,
  value : Bool,
) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let token = self.advance()
  self.expect_punct("(")
  let args = []
  if !self.is_punct(")") {
    args.push(self.scalar())
    while self.eat_punct(",") {
      args.push(self.scalar())
    }
  }
  let mut name = if value { "JSON_VALUE" } else { "JSON_QUERY" }
  if value && self.is_kw("RETURNING") {
    let returning = self.advance()
    if args.length() < 2 {
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=16,
        message="Incorrect syntax near 'RETURNING'.",
        span=returning.span,
      )
    }
    let ty = self.type_name()
    if ty.args.is_empty() &&
      ty.name.to_upper() is ("CHAR" | "VARCHAR" | "NCHAR" | "NVARCHAR") {
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=1,
        message="Incorrect syntax near 'RETURNING'.",
        span=returning.span,
      )
    }
    if !(ty.name.to_upper()
      is ("TINYINT"
      | "SMALLINT"
      | "INT"
      | "INTEGER"
      | "BIGINT"
      | "DECIMAL"
      | "NUMERIC"
      | "FLOAT"
      | "DOUBLE PRECISION"
      | "REAL"
      | "BIT"
      | "CHAR"
      | "VARCHAR"
      | "NCHAR"
      | "NVARCHAR"
      | "DATE"
      | "TIME"
      | "DATETIME2"
      | "DATETIMEOFFSET")) ||
      ty.schema is Some(_) {
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=29,
        message="Incorrect syntax near '\{ty.name}'.",
        span=ty.span,
      )
    }
    args.push(
      mk(Cast(mk(Null, returning.span), ty, try_=false), returning.span),
    )
    name = "JSON_VALUE RETURNING"
  } else if !value && self.eat_kw("WITH") {
    if self.eat_kw("WRAPPER") {
      raise self.error()
    }
    self.expect_kw("ARRAY")
    self.expect_kw("WRAPPER")
    name = "JSON_QUERY WITH ARRAY WRAPPER"
  }
  self.expect_punct(")")
  mk(
    Call({
      name: {
        parts: [{ name, quoted: false, span: token.span, }],
        span: token.span,
      },
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
