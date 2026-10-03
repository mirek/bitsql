///|
fn stmt(kind : @ast.StmtKind, span : @ast.Span) -> @ast.Stmt {
  { kind, span, }
}

///|
/// Statements until `stop` holds or end of input. Semicolons separate
/// optionally; a CTE (`WITH`) or `THROW` after an unterminated statement is
/// an error as on SQL Server (319 / 102).
fn Parser::stmt_list(
  self : Parser,
  stop : (Parser) -> Bool,
  top? : Bool = false,
) -> Array[@ast.Stmt] raise @ast.SyntaxError {
  let out = []
  let mut terminated = true
  while true {
    while self.eat_punct(";") {
      terminated = true
    }
    if self.peek().kind is Eof || stop(self) {
      break
    }
    let t = self.peek()
    if !terminated && out.length() > 0 {
      if t.is_kw("WITH") {
        raise syntax_error(
          319,
          "Incorrect syntax near the keyword '\{t.text}'. If this statement is a common table expression, an xmlnamespaces clause or a change tracking context clause, the previous statement must be terminated with a semicolon.",
          t.span,
        )
      }
      if t.is_kw("THROW") {
        raise near(t)
      }
    }
    out.push(self.statement(top && out.length() == 0))
    terminated = false
  }
  out
}

///|
fn never(_p : Parser) -> Bool {
  false
}

///|
fn at_end(p : Parser) -> Bool {
  p.is_kw("END")
}

///|
/// A single statement (bodies of IF / WHILE / ELSE).
fn Parser::single(self : Parser) -> @ast.Stmt raise @ast.SyntaxError {
  while self.eat_punct(";") {

  }
  if self.peek().kind is Eof {
    raise self.error()
  }
  self.statement(false)
}

///|
fn Parser::statement(
  self : Parser,
  first : Bool,
) -> @ast.Stmt raise @ast.SyntaxError {
  self.enter()
  let start = self.start()
  let kind = self.statement_kind(first)
  self.leave()
  stmt(kind, self.span_from(start))
}

///|
fn Parser::statement_kind(
  self : Parser,
  first : Bool,
) -> @ast.StmtKind raise @ast.SyntaxError {
  let t = self.peek()
  if t.is_punct("(") {
    return Select(self.query())
  }
  if t.kind is QuotedIdent {
    raise near(t)
  }
  if !(t.kind is Word) {
    raise self.error()
  }
  // label:
  if self.is_punct_at(1, ":") && !is_reserved(t.text) {
    self.pos += 2
    return Label(tok_ident(t))
  }
  match upper(t) {
    "SELECT" => Select(self.query())
    "WITH" => {
      let start = self.start()
      let ctes = self.ctes()
      if self.is_kw("SELECT") || self.is_punct("(") {
        Select(self.query_with(ctes, start))
      } else if self.is_kw("INSERT") {
        Insert(self.insert_stmt(ctes))
      } else if self.is_kw("UPDATE") {
        Update(self.update_stmt(ctes))
      } else if self.is_kw("DELETE") {
        Delete(self.delete_stmt(ctes))
      } else if self.is_kw("MERGE") {
        Merge(self.merge_stmt(ctes))
      } else {
        raise self.error()
      }
    }
    "INSERT" => Insert(self.insert_stmt([]))
    "UPDATE" => Update(self.update_stmt([]))
    "DELETE" => Delete(self.delete_stmt([]))
    "MERGE" => Merge(self.merge_stmt([]))
    "TRUNCATE" => {
      self.pos += 1
      self.expect_kw("TABLE")
      Truncate(self.object_name())
    }
    "CREATE" | "ALTER" => self.create_or_alter(first)
    "DROP" => self.drop_stmt()
    "GRANT" | "DENY" | "REVOKE" => Permission(self.permission())
    "DECLARE" => self.declare_stmt()
    "SET" => self.set_stmt()
    "IF" => {
      self.pos += 1
      let c = self.cond()
      let then_ = self.single()
      if self.is_punct(";") && self.is_kw_at(1, "ELSE") {
        self.pos += 1
      }
      let else_ = if self.eat_kw("ELSE") { Some(self.single()) } else { None }
      If(c, then_, else_)
    }
    "WHILE" => {
      self.pos += 1
      let c = self.cond()
      While(c, self.single())
    }
    "BEGIN" => self.begin_stmt()
    "BREAK" => {
      self.pos += 1
      Break
    }
    "CONTINUE" => {
      self.pos += 1
      Continue
    }
    "RETURN" => {
      self.pos += 1
      if self.can_start_expr() {
        Return(Some(self.scalar()))
      } else {
        Return(None)
      }
    }
    "GOTO" => {
      self.pos += 1
      Goto(self.ident())
    }
    "WAITFOR" => {
      self.pos += 1
      let w = self.peek()
      if !(w.is_kw("DELAY") || w.is_kw("TIME")) {
        raise self.error()
      }
      self.pos += 1
      WaitFor(upper(w), self.scalar())
    }
    "THROW" => {
      self.pos += 1
      if self.can_start_expr() {
        let a = self.scalar()
        self.expect_punct(",")
        let b = self.scalar()
        self.expect_punct(",")
        let c = self.scalar()
        Throw([a, b, c])
      } else {
        Throw([])
      }
    }
    "RAISERROR" => {
      self.pos += 1
      self.expect_punct("(")
      // RAISERROR arguments are constants or variables only: no NULL, no
      // signs, no expressions (msduck raiserror-arguments captures: NULL is
      // 156, '16' as severity, 1+2, (1), +1, -@x are 102).
      let args = [self.raiserror_arg(true, false)]
      while self.eat_punct(",") {
        let substitution = args.length() >= 3
        args.push(self.raiserror_arg(substitution, substitution))
      }
      self.expect_punct(")")
      let options = []
      if self.eat_kw("WITH") {
        while true {
          let o = self.peek()
          if !(o.is_kw("NOWAIT") || o.is_kw("LOG") || o.is_kw("SETERROR")) {
            raise self.error()
          }
          self.pos += 1
          options.push(upper(o))
          if !self.eat_punct(",") {
            break
          }
        }
      }
      RaisError(args, options~)
    }
    "PRINT" => {
      self.pos += 1
      Print(self.scalar())
    }
    "EXEC" | "EXECUTE" => {
      self.pos += 1
      if self.is_punct("(") {
        self.pos += 1
        let parts = [self.scalar()]
        while self.eat_punct(",") {
          parts.push(self.scalar())
        }
        self.expect_punct(")")
        ExecString(parts)
      } else {
        Exec(self.exec_body())
      }
    }
    "COMMIT" | "ROLLBACK" | "SAVE" => {
      let u = upper(t)
      self.pos += 1
      let tran = self.eat_kw("TRAN") || self.eat_kw("TRANSACTION")
      if !tran && u != "SAVE" {
        ignore(self.eat_kw("WORK"))
      }
      if u == "SAVE" && !tran {
        raise self.error()
      }
      let name = if tran { self.tran_name() } else { None }
      if u == "COMMIT" && self.is_kw("WITH") && self.is_punct_at(1, "(") {
        ignore(self.with_options())
      }
      match u {
        "COMMIT" => Commit(name~)
        "ROLLBACK" => Rollback(name~)
        _ =>
          match name {
            Some(_) => Save(name~)
            None => raise self.error()
          }
      }
    }
    "OPEN" => {
      self.pos += 1
      let global = self.eat_kw("GLOBAL")
      OpenCursor(self.cursor_name(), global~)
    }
    "CLOSE" => {
      self.pos += 1
      let global = self.eat_kw("GLOBAL")
      CloseCursor(self.cursor_name(), global~)
    }
    "DEALLOCATE" => {
      self.pos += 1
      let global = self.eat_kw("GLOBAL")
      Deallocate(self.cursor_name(), global~)
    }
    "FETCH" => Fetch(self.fetch())
    "USE" => {
      self.pos += 1
      Use(self.any_ident())
    }
    _ => raise self.error()
  }
}

///|
/// True when the current token can begin an expression (RETURN / THROW
/// operands), without swallowing the next statement's keyword.
fn Parser::can_start_expr(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    Eof => false
    Punct => t.text == "(" || t.text == "-" || t.text == "+" || t.text == "~"
    Word =>
      if is_reserved(t.text) {
        match upper(t) {
          "CASE"
          | "NULL"
          | "COALESCE"
          | "NULLIF"
          | "CONVERT"
          | "TRY_CONVERT"
          | "CURRENT_TIMESTAMP"
          | "CURRENT_USER"
          | "SESSION_USER"
          | "SYSTEM_USER"
          | "USER"
          | "LEFT"
          | "RIGHT" => true
          _ => false
        }
      } else {
        // A label (`x:`) is a statement, not an operand.
        !self.is_punct_at(1, ":")
      }
    _ => true
  }
}

///|
fn Parser::tran_name(self : Parser) -> @ast.Expr? {
  let t = self.peek()
  match t.kind {
    Variable => {
      self.pos += 1
      Some(mk(Var(t.text), t.span))
    }
    Word if !is_reserved(t.text) && !self.is_punct_at(1, ":") => {
      self.pos += 1
      Some(mk(Column([tok_ident(t)]), t.span))
    }
    QuotedIdent => {
      self.pos += 1
      Some(mk(Column([tok_ident(t)]), t.span))
    }
    _ => None
  }
}

///|
fn Parser::cursor_name(self : Parser) -> @ast.Ident raise @ast.SyntaxError {
  let t = self.peek()
  if t.kind is Variable {
    self.pos += 1
    { name: t.text, quoted: false, span: t.span, }
  } else {
    self.ident()
  }
}

///|
fn Parser::fetch(self : Parser) -> @ast.Fetch raise @ast.SyntaxError {
  self.expect_kw("FETCH")
  let t = self.peek()
  let mut orientation : @ast.FetchOrientation = Next
  let mut explicit = true
  match upper(t) {
    "NEXT" => {
      self.pos += 1
      orientation = Next
    }
    "PRIOR" => {
      self.pos += 1
      orientation = Prior
    }
    "FIRST" => {
      self.pos += 1
      orientation = First
    }
    "LAST" => {
      self.pos += 1
      orientation = Last
    }
    "ABSOLUTE" => {
      self.pos += 1
      orientation = Absolute(self.scalar())
    }
    "RELATIVE" => {
      self.pos += 1
      orientation = Relative(self.scalar())
    }
    _ => explicit = false
  }
  if explicit {
    self.expect_kw("FROM")
  } else {
    ignore(self.eat_kw("FROM"))
  }
  let global = self.eat_kw("GLOBAL")
  let cursor = self.cursor_name()
  let into = []
  if self.eat_kw("INTO") {
    while true {
      let v = self.peek()
      if !(v.kind is Variable) {
        raise self.error()
      }
      self.pos += 1
      into.push(v.text)
      if !self.eat_punct(",") {
        break
      }
    }
  }
  { orientation, cursor, global, into, }
}

///|
/// After `EXEC`: `[@rc =] proc|@var [args] [WITH RECOMPILE]`.
fn Parser::exec_body(self : Parser) -> @ast.Exec raise @ast.SyntaxError {
  let t = self.peek()
  let mut return_var = None
  if t.kind is Variable && self.is_punct_at(1, "=") {
    self.pos += 2
    return_var = Some(t.text)
  }
  let p = self.peek()
  let target : @ast.ExecTarget = if p.kind is Variable {
    self.pos += 1
    ExecVar(p.text)
  } else {
    ExecProc(self.object_name())
  }
  let args = []
  if self.at_exec_arg() {
    while true {
      args.push(self.exec_arg())
      if !self.eat_punct(",") {
        break
      }
    }
  }
  let with_recompile = if self.is_kw("WITH") && self.is_kw_at(1, "RECOMPILE") {
    self.pos += 2
    true
  } else {
    false
  }
  { return_var, target, args, with_recompile, }
}

///|
fn Parser::at_exec_arg(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    Variable
    | GlobalVariable
    | Str
    | NStr
    | IntNum
    | DecimalNum
    | FloatNum
    | Money
    | BinaryLit
    | QuotedIdent => true
    Punct => t.text == "-" || t.text == "+"
    Word =>
      t.is_kw("DEFAULT") ||
      t.is_kw("NULL") ||
      (!is_reserved(t.text) && !self.is_punct_at(1, ":"))
    Eof => false
  }
}

///|
fn Parser::exec_arg(self : Parser) -> @ast.ExecArg raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  let name = if t.kind is Variable && self.is_punct_at(1, "=") {
    self.pos += 2
    Some(t.text)
  } else {
    None
  }
  let value = self.exec_value()
  let output = self.eat_kw("OUTPUT") || self.eat_kw("OUT")
  { name, value, output, span: self.span_from(start), }
}

///|
/// EXEC argument values are restricted to constants, variables, DEFAULT and
/// bare words (passed as strings), like SQL Server.
fn Parser::exec_value(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  let t = self.peek()
  if t.is_punct("-") || t.is_punct("+") {
    self.pos += 1
    let n = self.peek()
    match n.kind {
      IntNum | DecimalNum | FloatNum | Money => {
        let e = self.primary()
        let op : @ast.UnaryOp = if t.text == "-" { Neg } else { Plus }
        return mk(Unary(op, e), self.span_from(start))
      }
      _ => raise self.error()
    }
  }
  match t.kind {
    Word if t.is_kw("DEFAULT") => {
      self.pos += 1
      mk(Default, t.span)
    }
    Word if t.is_kw("NULL") => {
      self.pos += 1
      mk(Null, t.span)
    }
    Word | QuotedIdent => {
      self.pos += 1
      mk(Column([tok_ident(t)]), t.span)
    }
    Variable
    | GlobalVariable
    | Str
    | NStr
    | IntNum
    | DecimalNum
    | FloatNum
    | Money
    | BinaryLit => self.primary()
    _ => raise self.error()
  }
}

///|
fn Parser::begin_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  self.expect_kw("BEGIN")
  if self.eat_kw("TRAN") || self.eat_kw("TRANSACTION") {
    let name = self.tran_name()
    self.with_mark()
    return BeginTran(name~, distributed=false)
  }
  if self.is_kw("DISTRIBUTED") {
    self.pos += 1
    if !self.eat_kw("TRAN") {
      self.expect_kw("TRANSACTION")
    }
    let name = self.tran_name()
    return BeginTran(name~, distributed=true)
  }
  if self.eat_kw("TRY") {
    let body = self.stmt_list(at_end)
    // An empty TRY block is error 102 near the TRY of `END TRY`
    // (msduck try-completion-tokens capture).
    if body.length() == 0 && self.is_kw("END") {
      self.pos += 1
      raise self.error()
    }
    self.expect_kw("END")
    self.expect_kw("TRY")
    self.expect_kw("BEGIN")
    self.expect_kw("CATCH")
    let handler = self.stmt_list(at_end)
    self.expect_kw("END")
    self.expect_kw("CATCH")
    return TryCatch(body, handler)
  }
  let body = self.stmt_list(at_end)
  if body.length() == 0 {
    raise self.error()
  }
  self.expect_kw("END")
  Block(body)
}

///|
fn Parser::with_mark(self : Parser) -> Unit {
  if self.is_kw("WITH") && self.is_kw_at(1, "MARK") {
    self.pos += 2
    let t = self.peek()
    if t.kind is Str || t.kind is NStr {
      self.pos += 1
    }
  }
}

///|
fn Parser::declare_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  self.expect_kw("DECLARE")
  let t = self.peek()
  if !(t.kind is Variable) {
    return DeclareCursor(self.cursor_decl())
  }
  if self.is_kw_at(1, "TABLE") ||
    (self.is_kw_at(1, "AS") && self.is_kw_at(2, "TABLE")) {
    self.pos += 1
    ignore(self.eat_kw("AS"))
    self.pos += 1
    let body = self.table_body()
    return DeclareTable(t.text, body)
  }
  let vars : Array[@ast.DeclareVar] = []
  while true {
    let start = self.start()
    let v = self.peek()
    if !(v.kind is Variable) {
      raise self.error()
    }
    self.pos += 1
    ignore(self.eat_kw("AS"))
    if self.is_kw("TABLE") {
      // A table variable must be declared on its own.
      raise self.error()
    }
    let type_ = self.type_name()
    let init = if self.eat_punct("=") { Some(self.scalar()) } else { None }
    vars.push({ name: v.text, type_, init, span: self.span_from(start), })
    if !self.eat_punct(",") {
      break
    }
  }
  Declare(vars)
}

///|
fn Parser::cursor_decl(self : Parser) -> @ast.Cursor raise @ast.SyntaxError {
  let name = self.ident()
  let options = []
  // ISO syntax: [INSENSITIVE] [SCROLL] CURSOR FOR
  while self.is_kw("INSENSITIVE") || self.is_kw("SCROLL") {
    options.push(upper(self.advance()))
  }
  self.expect_kw("CURSOR")
  while true {
    let t = self.peek()
    match upper(t) {
      "LOCAL"
      | "GLOBAL"
      | "FORWARD_ONLY"
      | "SCROLL"
      | "STATIC"
      | "KEYSET"
      | "DYNAMIC"
      | "FAST_FORWARD"
      | "READ_ONLY"
      | "SCROLL_LOCKS"
      | "OPTIMISTIC"
      | "TYPE_WARNING" =>
        if t.kind is Word {
          self.pos += 1
          options.push(upper(t))
        } else {
          break
        }
      _ => break
    }
  }
  self.expect_kw("FOR")
  let query = self.query()
  let mut for_update = false
  let update_columns = []
  if self.is_kw("FOR") && self.is_kw_at(1, "UPDATE") {
    self.pos += 2
    for_update = true
    if self.eat_kw("OF") {
      update_columns.push(self.ident())
      while self.eat_punct(",") {
        update_columns.push(self.ident())
      }
    }
  } else if self.is_kw("FOR") && self.is_kw_at(1, "READ") {
    self.pos += 2
    self.expect_kw("ONLY")
    options.push("READ ONLY")
  }
  { name, options, query, for_update, update_columns, }
}

///|
fn Parser::set_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  self.expect_kw("SET")
  let t = self.peek()
  if t.kind is Variable {
    self.pos += 1
    let op = match assign_op(self.peek()) {
      Some(op) => op
      None => raise self.error()
    }
    self.pos += 1
    return SetVar(t.text, op, self.scalar())
  }
  if !(t.kind is Word) {
    raise self.error()
  }
  if t.is_kw("IDENTITY_INSERT") {
    self.pos += 1
    let name = self.object_name()
    let on = if self.eat_kw("ON") {
      true
    } else {
      self.expect_kw("OFF")
      false
    }
    return SetIdentityInsert(name, on)
  }
  if t.is_kw("TRANSACTION") && self.is_kw_at(1, "ISOLATION") {
    self.pos += 2
    self.expect_kw("LEVEL")
    let level = if self.eat_kw("READ") {
      if self.eat_kw("COMMITTED") {
        "READ COMMITTED"
      } else {
        self.expect_kw("UNCOMMITTED")
        "READ UNCOMMITTED"
      }
    } else if self.eat_kw("REPEATABLE") {
      self.expect_kw("READ")
      "REPEATABLE READ"
    } else if self.eat_kw("SERIALIZABLE") {
      "SERIALIZABLE"
    } else {
      self.expect_kw("SNAPSHOT")
      "SNAPSHOT"
    }
    return SetIsolation(level)
  }
  // Generic: SET opt [, opt ...] ON|OFF|word|expr
  let options = []
  let statistics = t.is_kw("STATISTICS")
  if statistics {
    self.pos += 1
  }
  while true {
    let o = self.peek()
    if !(o.kind is Word) {
      raise self.error()
    }
    self.pos += 1
    options.push(if statistics { "STATISTICS " + upper(o) } else { upper(o) })
    if !self.eat_punct(",") {
      break
    }
  }
  let v = self.peek()
  let value : @ast.SetValue = if v.is_kw("ON") {
    self.pos += 1
    On
  } else if v.is_kw("OFF") {
    self.pos += 1
    Off
  } else if ((v.kind is Word && !is_reserved(v.text)) || v.kind is QuotedIdent) &&
    !self.is_punct_at(1, "(") &&
    !self.is_punct_at(1, ".") {
    self.pos += 1
    Word(v.text)
  } else {
    ValueExpr(self.scalar())
  }
  SetOption(options, value)
}

///|
fn Parser::permission(self : Parser) -> @ast.Permission raise @ast.SyntaxError {
  let t = self.advance()
  let action : @ast.PermissionAction = match upper(t) {
    "GRANT" => Grant
    "DENY" => Deny
    _ => Revoke
  }
  if action is Revoke && self.is_kw("GRANT") && self.is_kw_at(1, "OPTION") {
    self.pos += 2
    self.expect_kw("FOR")
  }
  let permissions = []
  while true {
    let words = []
    while self.peek().kind is Word &&
          !self.is_kw("ON") &&
          !self.is_kw("TO") &&
          !self.is_kw("FROM") {
      words.push(upper(self.advance()))
    }
    if words.length() == 0 {
      raise self.error()
    }
    permissions.push(words.join(" "))
    if !self.eat_punct(",") {
      break
    }
  }
  let mut on_class = None
  let mut on = None
  let mut columns = []
  if self.eat_kw("ON") {
    if self.is_punct_at(1, "::") {
      on_class = Some(upper(self.advance()))
      self.pos += 1
    }
    on = Some(self.object_name())
    if self.is_punct("(") {
      columns = self.paren_idents()
    }
  }
  if !self.eat_kw("TO") {
    self.expect_kw("FROM")
  }
  let principals = [self.any_ident()]
  while self.eat_punct(",") {
    principals.push(self.any_ident())
  }
  let mut grant_option = false
  if self.is_kw("WITH") && self.is_kw_at(1, "GRANT") {
    self.pos += 2
    self.expect_kw("OPTION")
    grant_option = true
  }
  let cascade = self.eat_kw("CASCADE")
  if self.eat_kw("AS") {
    ignore(self.any_ident())
  }
  {
    action,
    permissions,
    on_class,
    on,
    columns,
    principals,
    grant_option,
    cascade,
  }
}

///|
/// `CREATE ...` / `ALTER ...` / `CREATE OR ALTER ...`.
fn Parser::create_or_alter(
  self : Parser,
  first : Bool,
) -> @ast.StmtKind raise @ast.SyntaxError {
  let start = self.start()
  let is_alter = self.is_kw("ALTER")
  self.pos += 1
  let mode : @ast.CreateMode = if is_alter {
    Alter
  } else if self.is_kw("OR") && self.is_kw_at(1, "ALTER") {
    self.pos += 2
    CreateOrAlter
  } else {
    Create
  }
  let t = self.peek()
  let u = upper(t)
  let verb = match mode {
    Create => "CREATE"
    Alter => "ALTER"
    CreateOrAlter => "CREATE OR ALTER"
  }
  let must_be_first = fn(what : String) raise @ast.SyntaxError {
    if !first {
      raise syntax_error(
        111,
        "'\{what}' must be the first statement in a query batch.",
        start,
      )
    }
  }
  match u {
    "TABLE" if mode is Create => {
      self.pos += 1
      CreateTable(self.create_table())
    }
    "TABLE" if mode is Alter => {
      self.pos += 1
      self.alter_table()
    }
    "UNIQUE" | "CLUSTERED" | "NONCLUSTERED" | "INDEX" | "COLUMNSTORE" if mode
      is Create => CreateIndex(self.create_index())
    "VIEW" => {
      must_be_first("\{verb} VIEW")
      self.pos += 1
      let name = self.object_name()
      let columns = if self.is_punct("(") { self.paren_idents() } else { [] }
      let attributes = self.module_options()
      self.expect_kw("AS")
      let query = self.query()
      let check_option = if self.is_kw("WITH") && self.is_kw_at(1, "CHECK") {
        self.pos += 2
        self.expect_kw("OPTION")
        true
      } else {
        false
      }
      self.expect_batch_end()
      let definition = self.slice(self.span_from(start))
      CreateView({
        mode,
        name,
        columns,
        attributes,
        query,
        check_option,
        definition,
      })
    }
    "PROC" | "PROCEDURE" => {
      must_be_first("CREATE/ALTER PROCEDURE")
      self.pos += 1
      let name = self.object_name()
      if self.eat_punct(";") {
        // ;number procedure groups
        if !(self.peek().kind is IntNum) {
          raise self.error()
        }
        self.pos += 1
      }
      let params = self.params(false)
      let options = self.module_options()
      if self.is_kw("FOR") && self.is_kw_at(1, "REPLICATION") {
        self.pos += 2
        options.push("FOR REPLICATION")
      }
      self.expect_kw("AS")
      let body = self.module_body()
      let definition = self.slice(self.span_from(start))
      CreateProcedure({ mode, name, params, options, body, definition, })
    }
    "FUNCTION" => {
      must_be_first("\{verb} FUNCTION")
      self.pos += 1
      let name = self.object_name()
      let params = self.params(true)
      self.expect_kw("RETURNS")
      if self.is_kw("TABLE") {
        self.pos += 1
        let options = self.module_options()
        ignore(self.eat_kw("AS"))
        self.expect_kw("RETURN")
        let q = self.query()
        let q = match q {
          {
            body: Nested(inner),
            order_by: [],
            offset: None,
            fetch: None,
            for_clause: None,
            options: [],
            ctes: [],
            ..
          } => inner
          _ => q
        }
        self.expect_batch_end()
        let definition = self.slice(self.span_from(start))
        return CreateFunction({
          mode,
          name,
          params,
          returns: InlineTable(q),
          options,
          definition,
        })
      } else if self.peek().kind is Variable {
        let v = self.advance()
        self.expect_kw("TABLE")
        let body = self.table_body()
        let options = self.module_options()
        ignore(self.eat_kw("AS"))
        let stmts = self.func_block()
        let definition = self.slice(self.span_from(start))
        return CreateFunction({
          mode,
          name,
          params,
          returns: TableVariable(v.text, body, stmts),
          options,
          definition,
        })
      } else {
        let ty = self.type_name()
        let options = self.module_options()
        ignore(self.eat_kw("AS"))
        let stmts = self.func_block()
        let definition = self.slice(self.span_from(start))
        return CreateFunction({
          mode,
          name,
          params,
          returns: Scalar(ty, stmts),
          options,
          definition,
        })
      }
    }
    "TRIGGER" => {
      must_be_first("\{verb} TRIGGER")
      self.pos += 1
      let name = self.object_name()
      self.expect_kw("ON")
      let table = self.object_name()
      let options = self.module_options()
      let timing : @ast.TriggerTiming = if self.eat_kw("AFTER") {
        After
      } else if self.eat_kw("FOR") {
        For
      } else {
        self.expect_kw("INSTEAD")
        self.expect_kw("OF")
        InsteadOf
      }
      let events : Array[@ast.DmlEvent] = []
      while true {
        let e = self.peek()
        let ev : @ast.DmlEvent = match upper(e) {
          "INSERT" => OnInsert
          "UPDATE" => OnUpdate
          "DELETE" => OnDelete
          _ => raise self.error()
        }
        self.pos += 1
        events.push(ev)
        if !self.eat_punct(",") {
          break
        }
      }
      if self.is_kw("WITH") && self.is_kw_at(1, "APPEND") {
        self.pos += 2
        options.push("APPEND")
      }
      let not_for_replication = self.not_for_replication()
      self.expect_kw("AS")
      let body = self.module_body()
      let definition = self.slice(self.span_from(start))
      CreateTrigger({
        mode,
        name,
        table,
        timing,
        events,
        options,
        not_for_replication,
        body,
        definition,
      })
    }
    "DATABASE" if mode is Create => {
      self.pos += 1
      let name = self.ident()
      let mut collate = None
      // skip ON/LOG ON/WITH/CONTAINMENT clauses up to the statement end
      let mut depth = 0
      while !(self.peek().kind is Eof) {
        if depth == 0 && self.is_punct(";") {
          break
        }
        if depth == 0 && self.is_kw("COLLATE") {
          self.pos += 1
          collate = Some(self.any_ident())
          continue
        }
        if self.is_punct("(") {
          depth += 1
        } else if self.is_punct(")") {
          depth -= 1
        } else if depth == 0 &&
          (
            self.is_kw("USE") ||
            self.is_kw("CREATE") ||
            self.is_kw("ALTER") ||
            self.is_kw("DROP") ||
            self.is_kw("SELECT") ||
            self.is_kw("INSERT") ||
            self.is_kw("IF") ||
            self.is_kw("EXEC") ||
            self.is_kw("EXECUTE") ||
            self.is_kw("DECLARE") ||
            self.is_kw("SET") ||
            self.is_kw("PRINT") ||
            self.is_kw("BEGIN")
          ) {
          break
        }
        self.pos += 1
      }
      CreateDatabase(name, collate~)
    }
    "SCHEMA" if mode is Create => {
      must_be_first("CREATE SCHEMA")
      self.pos += 1
      let name = self.ident()
      let authorization = if self.eat_kw("AUTHORIZATION") {
        Some(self.any_ident())
      } else {
        None
      }
      CreateSchema(name, authorization~)
    }
    "TYPE" if mode is Create => {
      self.pos += 1
      let name = self.object_name()
      if self.eat_kw("FROM") {
        let base = self.type_name()
        let nullable = if self.eat_kw("NULL") {
          Some(true)
        } else if self.is_kw("NOT") && self.is_kw_at(1, "NULL") {
          self.pos += 2
          Some(false)
        } else {
          None
        }
        CreateType({ name, base: Some(base), nullable, table: None, })
      } else {
        self.expect_kw("AS")
        self.expect_kw("TABLE")
        let body = self.table_body()
        CreateType({ name, base: None, nullable: None, table: Some(body), })
      }
    }
    "SEQUENCE" if mode is Create => {
      self.pos += 1
      let name = self.object_name()
      let type_ = if self.eat_kw("AS") { Some(self.type_name()) } else { None }
      let options = self.sequence_options()
      CreateSequence(name, type_~, options~)
    }
    "SEQUENCE" if mode is Alter => {
      self.pos += 1
      let name = self.object_name()
      AlterSequence(name, self.sequence_options())
    }
    _ => raise self.error()
  }
}

///|
/// `BEGIN stmts END` of a scalar / multi-statement function, then end of
/// batch.
fn Parser::func_block(self : Parser) -> Array[@ast.Stmt] raise @ast.SyntaxError {
  self.expect_kw("BEGIN")
  let body = self.stmt_list(at_end)
  self.expect_kw("END")
  self.expect_batch_end()
  body
}

///|
/// Modules that end before the batch does (views, functions) must still be
/// alone in the batch: anything but `;` after them is a syntax error.
fn Parser::expect_batch_end(self : Parser) -> Unit raise @ast.SyntaxError {
  let save = self.pos
  while self.eat_punct(";") {

  }
  if !(self.peek().kind is Eof) {
    raise near(self.peek())
  }
  self.pos = save
}

///|
/// Procedure / trigger body: the rest of the batch, at least one statement.
fn Parser::module_body(
  self : Parser,
) -> Array[@ast.Stmt] raise @ast.SyntaxError {
  let body = self.stmt_list(never)
  if body.length() == 0 {
    raise self.error()
  }
  body
}

///|
/// One RAISERROR argument: a constant (optionally negative number) or a
/// variable. `strings_ok` allows non-integer constants (message and
/// substitution arguments); `null_ok` allows NULL (substitution arguments
/// only). Captured: `+1`, `-@x`, `1+2`, `(1)` are 102; NULL as message or
/// severity is 156; `-1` is accepted everywhere.
fn Parser::raiserror_arg(
  self : Parser,
  strings_ok : Bool,
  null_ok : Bool,
) -> @ast.Expr raise @ast.SyntaxError {
  let start = self.start()
  if self.is_punct("-") &&
    self.peek_at(1).kind is (IntNum | DecimalNum | FloatNum | Money) {
    self.pos += 1
    let inner = self.primary()
    if !(self.is_punct(",") || self.is_punct(")")) {
      raise self.error()
    }
    return mk(Unary(Neg, inner), self.span_from(start))
  }
  let t = self.peek()
  let ok = match t.kind {
    IntNum | Variable => true
    Str | NStr | DecimalNum | FloatNum | Money | BinaryLit => strings_ok
    Word => null_ok && t.is_kw("NULL")
    _ => false
  }
  if !ok {
    raise self.error()
  }
  let e = self.primary()
  if !(self.is_punct(",") || self.is_punct(")")) {
    raise self.error()
  }
  e
}

///|
/// CREATE/ALTER SEQUENCE options, normalized to upper-case text:
/// `START WITH n`, `RESTART [WITH n]`, `INCREMENT BY n`, `MINVALUE n`,
/// `MAXVALUE n`, `NO MINVALUE|MAXVALUE|CYCLE|CACHE`, `CYCLE`, `CACHE [n]`.
fn Parser::sequence_options(
  self : Parser,
) -> Array[String] raise @ast.SyntaxError {
  let options = []
  while true {
    if self.is_kw("START") && self.is_kw_at(1, "WITH") {
      self.pos += 2
      options.push("START WITH " + self.signed_number())
    } else if self.eat_kw("RESTART") {
      if self.eat_kw("WITH") {
        options.push("RESTART WITH " + self.signed_number())
      } else {
        options.push("RESTART")
      }
    } else if self.is_kw("INCREMENT") && self.is_kw_at(1, "BY") {
      self.pos += 2
      options.push("INCREMENT BY " + self.signed_number())
    } else if self.is_kw("MINVALUE") || self.is_kw("MAXVALUE") {
      let o = upper(self.advance())
      options.push(o + " " + self.signed_number())
    } else if self.is_kw("NO") &&
      (
        self.is_kw_at(1, "MINVALUE") ||
        self.is_kw_at(1, "MAXVALUE") ||
        self.is_kw_at(1, "CYCLE") ||
        self.is_kw_at(1, "CACHE")
      ) {
      self.pos += 1
      options.push("NO " + upper(self.advance()))
    } else if self.eat_kw("CYCLE") {
      options.push("CYCLE")
    } else if self.eat_kw("CACHE") {
      if self.peek().kind is IntNum {
        options.push("CACHE " + self.advance().text)
      } else {
        options.push("CACHE")
      }
    } else {
      break
    }
  }
  options
}
