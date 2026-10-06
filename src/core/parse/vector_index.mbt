///|
/// The metric/type literals are part of the vector-index grammar, rather than
/// arbitrary expressions. Evidence: sql2025/vector-index-grammar.
fn Parser::vector_index_options(
  self : Parser,
) -> Array[@ast.OptionKV] raise @ast.SyntaxError {
  self.expect_kw("WITH")
  self.expect_punct("(")
  let out : Array[@ast.OptionKV] = []
  while true {
    let token = self.peek()
    let name = upper(token)
    if name is ("METRIC" | "TYPE") {
      self.pos += 1
      self.expect_punct("=")
      let value = self.peek()
      if !(value.kind is (Str | NStr)) {
        raise self.error()
      }
      let normalized = value.text.trim_end(chars=" ").to_owned().to_lower()
      let valid = if name == "METRIC" {
        normalized is ("cosine" | "euclidean" | "dot")
      } else {
        normalized == "diskann"
      }
      if !valid {
        raise self.error()
      }
      self.pos += 1
      out.push({ name, value: Some(value.text), })
    } else if name == "MAXDOP" {
      out.push(self.option_kv())
    } else if token.kind is Word {
      let known = name is ("ONLINE" | "DROP_EXISTING" | "FILLFACTOR")
      let display = if name == "FILLFACTOR" { "fillfactor" } else { token.text }
      raise @ast.SyntaxError(
        number=155,
        severity=15,
        message="'\{display}' is not a recognized CREATE VECTOR INDEX option.",
        span=token.span,
        state=if known { 6 } else { 1 },
      )
    } else {
      raise self.error()
    }
    if !self.eat_punct(",") {
      break
    }
  }
  self.expect_punct(")")
  out
}
