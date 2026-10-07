///|
/// Captured SQL Server 2025 external-model grammar. Option contents are
/// validated at execution; malformed option syntax fails the whole batch.
fn Parser::external_model(
  self : Parser,
  mode : @ast.CreateMode,
) -> @ast.StmtKind raise @ast.SyntaxError {
  let name = self.ident()
  let owner = if mode is Create && self.eat_kw("AUTHORIZATION") {
    Some(self.ident())
  } else {
    None
  }
  self.expect_kw(if mode is Alter { "SET" } else { "WITH" })
  self.expect_punct("(")
  let options : Array[@ast.OptionKV] = []
  if !self.eat_punct(")") {
    while true {
      let key = self.peek()
      let k = upper(key)
      if ![
          "LOCATION", "API_FORMAT", "MODEL_TYPE", "MODEL", "CREDENTIAL", "PARAMETERS",
          "LOCAL_RUNTIME_PATH",
        ].contains(k) {
        raise near(key)
      }
      if options.any(o => o.name == k) {
        raise @ast.SyntaxError(
          number=102,
          severity=15,
          state=2,
          message="Incorrect syntax near '\{key.text}'.",
          span=key.span,
        )
      }
      self.pos += 1
      self.expect_punct("=")
      let value = if k == "MODEL_TYPE" {
        let t = self.peek()
        if !(t.kind is Word) || upper(t) != "EMBEDDINGS" {
          raise near(t)
        }
        self.pos += 1
        "EMBEDDINGS"
      } else if k == "CREDENTIAL" {
        self.ident().name
      } else {
        let t = self.peek()
        if !(t.kind is (Str | NStr)) {
          raise self.error()
        }
        if t.text.length() > 4000 {
          let prefix = t.text.unsafe_substring(
            start=0,
            end=if t.kind is NStr { 129 } else { 30 },
          )
          raise syntax_error(
            103,
            "The character string that starts with '\{prefix}' is too long. Maximum length is 4000.",
            t.span,
          )
        }
        self.pos += 1
        t.text
      }
      options.push({ name: k, value: Some(value), })
      if !self.eat_punct(",") {
        break
      }
    }
    self.expect_punct(")")
  }
  ExternalModel(mode, name, owner~, options~)
}

///|
/// The model identifier occupies the first internal call argument, followed
/// by source and optional PARAMETERS. It is a name, not a column reference.
/// Inference is still explicitly unsupported by the binder.
fn Parser::embedding_call(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let name_tok = self.advance()
  self.expect_punct("(")
  let source = self.scalar()
  self.expect_kw("USE")
  self.expect_kw("MODEL")
  let model = self.ident()
  let args = [mk(StrLit(model.name, national=true), model.span), source]
  if self.eat_kw("PARAMETERS") {
    args.push(self.scalar())
  }
  self.expect_punct(")")
  let name : @ast.ObjectName = {
    parts: [tok_ident(name_tok)],
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
