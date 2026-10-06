///|
/// VECTOR_SEARCH accepts scalar tokens here, not arbitrary expressions or
/// parenthesized function calls. Type validation belongs to the binder.
fn Parser::vector_search_value(
  self : Parser,
) -> @ast.Expr raise @ast.SyntaxError {
  let t = self.peek()
  match t.kind {
    IntNum
    | DecimalNum
    | FloatNum
    | Money
    | Str
    | NStr
    | BinaryLit
    | Variable
    | GlobalVariable => self.primary_inner()
    Word if t.is_kw("NULL") => self.primary_inner()
    Word | QuotedIdent => {
      let name = self.object_name()
      mk(Column(name.parts), name.span)
    }
    _ => raise self.error()
  }
}

///|
fn Parser::vector_search_ref(
  self : Parser,
  start : @ast.Span,
) -> @ast.TableRef raise @ast.SyntaxError {
  self.expect_punct("(")
  if !self.is_kw("TABLE") && self.is_punct_at(1, "=") {
    // Named arguments are positional in this grammar; the oracle reports
    // the assignment token when the first argument is not TABLE.
    self.pos += 1
    raise self.error()
  }
  self.expect_kw("TABLE")
  self.expect_punct("=")
  let table = self.object_name()
  let source_alias = self.table_alias()
  self.expect_punct(",")
  self.expect_kw("COLUMN")
  self.expect_punct("=")
  let column = self.ident()
  self.expect_punct(",")
  self.expect_kw("SIMILAR_TO")
  self.expect_punct("=")
  let query = self.vector_search_value()
  self.expect_punct(",")
  self.expect_kw("METRIC")
  self.expect_punct("=")
  let metric = self.peek()
  if !(metric.kind is (Str | NStr)) ||
    !(metric.text.trim_end(chars=" ").to_owned().to_lower()
    is ("cosine" | "euclidean" | "dot")) {
    raise self.error()
  }
  self.pos += 1
  if self.is_punct(")") {
    raise syntax_error(102, "Incorrect syntax near 'TOP_N'.", self.peek().span)
  }
  self.expect_punct(",")
  self.expect_kw("TOP_N")
  self.expect_punct("=")
  let top = self.vector_search_value()
  if self.eat_punct(",") {
    raise self.error()
  }
  self.expect_punct(")")
  let alias_ = self.table_alias()
  {
    kind: VectorSearch({
      table,
      source_alias,
      column,
      query,
      metric: metric.text,
      top,
      alias_,
    }),
    span: self.span_from(start),
  }
}
