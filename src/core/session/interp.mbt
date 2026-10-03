///|
/// Raised inside TRY: the error was already completed; CATCH takes over.
priv suberror Caught {
  Caught(@types.SqlError, Int) // error, line
}

///|
fn Session::exec_list(self : Session, stmts : Array[@ast.Stmt]) -> Unit raise {
  for s in stmts {
    self.exec_one(s)
  }
}

///|
/// Executes one statement and applies SQL Server's error disposition.
fn Session::exec_one(self : Session, s : @ast.Stmt) -> Unit raise {
  let line = s.span.line
  self.cur_cmd = 253
  self.throwing = false
  self.stmt_error = 0
  let snap_temp = self.temp
  let snap_tx = self.tx
  let snap_db = self.server.db
  let failure = try {
    self.exec_stmt(s)
    None
  } catch {
    @types.SqlError(..) as e => Some(e)
    other => raise other
  }
  guard failure is Some(e) else {
    // a successful statement sets @@ERROR to 0, or to 50000 for
    // RAISERROR ... WITH SETERROR (stmt_error)
    if !(s.kind is (If(_, _, _) | While(_, _) | Block(_) | TryCatch(_, _))) {
      self.rt.error = self.stmt_error
    }
    return
  }
  // statement-level rollback: discard the failed statement's writes
  self.temp = snap_temp
  match snap_tx {
    Some(_) => self.tx = snap_tx
    None => if self.tx is None { self.server.db = snap_db }
  }
  self.rt.error = e.number()
  self.rt.rowcount = 0
  if self.try_depth > 0 && e.severity() > 10 && e.severity() < 20 {
    // Complete the failed statement without the error flag, then unwind
    // to the enclosing CATCH (docs/reference/completions.md).
    if self.cur_cmd != 253 {
      let rows = self.cur_cmd == 193 ||
        (self.cur_cmd >= 195 && self.cur_cmd <= 197)
      self.done(
        self.cur_cmd,
        count=if rows { Some(0L) } else { None },
        result_set=self.cur_cmd == 193,
      )
    }
    raise Caught(e, line)
  }
  self.message(e, line)
  self.done(self.cur_cmd, error=true)
  if aborts_batch(e, self.cur_cmd, self.throwing, self.xact_abort) {
    raise AbortBatch
  }
}

///|
/// Uncaught errors that end the batch rather than just the statement.
fn aborts_batch(
  e : @types.SqlError,
  cmd : Int,
  throwing : Bool,
  xact_abort : Bool,
) -> Bool {
  let n = e.number()
  throwing ||
  cmd == 253 ||
  (xact_abort && e.severity() > 10) ||
  e.severity() >= 20 ||
  n == 245 ||
  n == 8114 ||
  n == 529 ||
  (n >= 50100 && n <= 50199)
}

///|
fn Session::exec_block(self : Session, s : @ast.Stmt) -> Unit raise {
  match s.kind {
    Block(list) => self.exec_list(list)
    _ => self.exec_one(s)
  }
}

///|
fn Session::eval(
  self : Session,
  e : @ast.Expr,
) -> (@types.Value, @types.SqlType) raise {
  let b = @bind.bind_expr(self.env(), e)
  (@exec.eval(self.ctx(), b), b.ty)
}

///|
fn Session::assign(
  self : Session,
  name : String,
  op : @ast.AssignOp,
  e : @ast.Expr,
) -> Unit raise {
  let info = match self.frame().vars.get(name.to_lower()) {
    Some(v) => v
    None =>
      raise @types.sql_error(
        137,
        "Must declare the scalar variable \"\{name}\".",
        state=2,
        severity=15,
      )
  }
  let env = self.env()
  let rhs = @bind.bind_expr(env, e)
  let value_expr = match op {
    Assign => rhs
    _ => {
      let current : @ir.Expr = {
        kind: Var(info.slot),
        ty: info.ty,
        nullable: true,
      }
      let aop : @types.ArithOp = match op {
        AddAssign => Add
        SubAssign => Sub
        MulAssign => Mul
        DivAssign => Div
        _ => Mod
      }
      let ty = @types.arith_result_type(aop, info.ty, rhs.ty)
      { kind: Arith(aop, current, rhs), ty, nullable: true, }
    }
  }
  let v = @exec.eval(self.ctx(), value_expr)
  self.frame().values[info.slot] = @types.cast(v, value_expr.ty, info.ty)
}

///|
fn Session::exec_stmt(self : Session, s : @ast.Stmt) -> Unit raise {
  match s.kind {
    Select(q) => self.exec_select(q)
    Declare(vars) =>
      for v in vars {
        let ty = @bind.resolve_type(
          v.type_,
          Declaration,
          @types.default_collation,
        )
        let existing = self.frame().vars.contains(v.name.to_lower())
        if existing {
          raise @types.sql_error(
            134,
            "The variable name '\{v.name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
            severity=15,
          )
        }
        ignore(self.frame().add_var(v.name, ty))
        if v.init is Some(init) {
          self.cur_cmd = 193
          self.assign(v.name, Assign, init)
          self.rt.rowcount = 1
          self.done(193, count=Some(1L))
        }
      }
    SetVar(name, op, e) => {
      self.cur_cmd = 193
      self.assign(name, op, e)
      self.rt.rowcount = 1
      self.done(193, count=Some(1L))
    }
    SetOption(names, value) => {
      let on = value is On
      for n in names {
        match n.to_upper() {
          "NOCOUNT" => self.nocount = on
          "XACT_ABORT" => self.xact_abort = on
          _ => ()
        }
      }
      self.done(if value is Off { 186 } else { 185 })
    }
    SetIsolation(_) => self.done(185)
    Print(e) => {
      self.cur_cmd = 247
      let (v, ty) = self.eval(e)
      let text = match
        @types.cast(v, ty, NVarChar(Some(4000), @types.default_collation)) {
        String(t) => t
        _ => ""
      }
      self.info(0, 1, text, s.span.line)
      self.rt.rowcount = 0
      self.done(247)
    }
    RaisError(args, options~) => self.exec_raiserror(args, options, s.span.line)
    Throw(args) => self.exec_throw(args)
    If(cond, then_, else_) => {
      let b = @bind.bind_expr(self.env(), cond)
      let v = @exec.eval(self.ctx(), b)
      self.done(192)
      if @exec.is_true(v) {
        self.exec_block(then_)
      } else if else_ is Some(e) {
        self.exec_block(e)
      }
    }
    While(cond, body) => {
      let b = @bind.bind_expr(self.env(), cond)
      while true {
        let v = @exec.eval(self.ctx(), b)
        self.done(192)
        if !@exec.is_true(v) {
          break
        }
        let flow = try {
          self.exec_block(body)
          0
        } catch {
          Break => 1
          Continue => 2
          other => raise other
        }
        if flow == 1 {
          break
        }
      }
    }
    Block(list) => self.exec_list(list)
    Break => {
      self.done(202)
      raise Break
    }
    Continue => {
      self.done(202)
      raise Continue
    }
    Return(e) => {
      let status = match e {
        Some(x) => {
          let (v, ty) = self.eval(x)
          match @types.cast(v, ty, Int) {
            Int(i) => Some(i)
            _ => Some(0)
          }
        }
        None => None
      }
      // Bare RETURN completes with 219; RETURN <expr> completes like an
      // assignment (193, count 1) (captured: smoke/proc-return-output,
      // msduck catch-return-rpc).
      if status is Some(_) {
        self.rt.rowcount = 1
        self.done(193, count=Some(1L))
      } else {
        self.done(219)
      }
      raise Return(status)
    }
    TryCatch(body, handler) => self.exec_try(body, handler)
    BeginTran(..) => {
      self.begin_tx()
      self.rt.trancount += 1
      self.rt.xact_state = 1
      self.out.push(EnvChange(BeginTransaction(self.tx_descriptor())))
      self.done(212)
    }
    Commit(..) => {
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          3902, "The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION.",
        )
      }
      self.rt.trancount -= 1
      if self.rt.trancount == 0 {
        let d = self.tx_descriptor()
        self.commit_tx()
        self.rt.xact_state = 0
        self.out.push(EnvChange(CommitTransaction(d)))
      }
      self.done(213)
    }
    Rollback(..) => {
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          3903, "The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.",
        )
      }
      let d = self.tx_descriptor()
      self.rt.trancount = 0
      self.rt.xact_state = 0
      self.rollback_tx()
      self.out.push(EnvChange(RollbackTransaction(d)))
      self.done(210)
    }
    CreateTable(ct) => self.exec_create_table(ct)
    DeclareTable(name, body) => self.exec_declare_table(name, body)
    Drop(kind, if_exists~, names) => self.exec_drop(kind, if_exists, names)
    Insert(ins) => self.exec_insert(ins)
    Update(u) => self.exec_update(u)
    Delete(d) => self.exec_delete(d)
    Truncate(name) => self.exec_truncate(name)
    SetIdentityInsert(name, on) =>
      match self.find_table(name) {
        Some((_, t)) => {
          if on {
            if t.columns.iter().all(c => c.identity is None) {
              raise @types.sql_error(
                8106,
                "Table '\{t.name}' does not have the identity property. Cannot perform SET operation.",
              )
            }
            self.identity_insert = Some(t.id)
          } else if self.identity_insert == Some(t.id) {
            self.identity_insert = None
          }
          self.done(if on { 185 } else { 186 })
        }
        None =>
          raise @types.sql_error(
            208,
            "Invalid object name '\{name.parts.map(p => p.name).join(".")}'.",
          )
      }
    CreateProcedure(p) => {
      let key = p.name.base().to_lower()
      if p.mode is Create && self.server.procs.contains(key) {
        raise @types.sql_error(
          2714,
          "There is already an object named '\{p.name.base()}' in the database.",
        )
      }
      self.server.procs[key] = { name: p.name.base(), def: p, }
      self.done(203)
    }
    Exec(e) => self.exec_proc_stmt(e)
    ExecString(parts) => self.exec_string(parts)
    _ => raise @types.not_supported(stmt_name(s))
  }
}

///|
fn stmt_name(s : @ast.Stmt) -> String {
  let text = s.to_sexp()
  let end = match text.find(" ") {
    Some(i) => i
    None => text.length()
  }
  "statement " + text.unsafe_substring(start=1, end~)
}

///|
fn Session::exec_select(self : Session, q : @ast.Query) -> Unit raise {
  // SELECT @v = expr assignments
  if q.body is Select(sel) &&
    sel.items.iter().any(i => i.kind is Assign(_, _, _)) {
    if !sel.items.iter().all(i => i.kind is Assign(_, _, _)) {
      raise @types.sql_error(
        141,
        "A SELECT statement that assigns a value to a variable must not be combined with data-retrieval operations.",
        severity=15,
      )
    }
    if !sel.from.is_empty() || sel.where_ is Some(_) {
      raise @types.not_supported("SELECT assignment with FROM/WHERE")
    }
    self.cur_cmd = 193
    for item in sel.items {
      guard item.kind is Assign(name, op, e) else { continue }
      self.assign(name, op, e)
    }
    self.rt.rowcount = 1
    self.done(193, count=Some(1L))
    return
  }
  let bound = @bind.bind_query(self.env(), q)
  let cols = bound.columns.map(tds_column)
  self.out.push(ResultSet(cols))
  self.cur_cmd = 193
  if !bound.order.is_empty() {
    self.out.push(Order(bound.order))
  }
  let rows = @exec.run(self.ctx(), bound.plan)
  for r in rows {
    self.out.push(Row(r.map(wire_value)))
  }
  self.rt.rowcount = rows.length().to_int64()
  self.done(193, count=Some(rows.length().to_int64()), result_set=true)
}

///|
fn Session::exec_raiserror(
  self : Session,
  args : Array[@ast.Expr],
  options : Array[String],
  line : Int,
) -> Unit raise {
  self.cur_cmd = 246
  let values = args.map(a => self.eval(a))
  let (msg_v, _) = values[0]
  let severity = values
    .get(1)
    .map(x => x.0.as_int64().unwrap_or(0L).to_int())
    .unwrap_or(16)
  let state = values
    .get(2)
    .map(x => x.0.as_int64().unwrap_or(0L).to_int())
    .unwrap_or(1)
  let (number, text) = match msg_v {
    String(fmt) =>
      (50000, format_raiserror(fmt, values[3:].to_owned().map(x => x.0)))
    _ => raise @types.not_supported("RAISERROR with a message id")
  }
  let severity = if severity < 0 { 0 } else { severity }
  let state = if state < 0 { 1 } else { state }
  if options.contains("SETERROR") {
    self.stmt_error = number
  }
  if severity <= 10 {
    // Informational: INFO token with class 0 (captured), statement succeeds.
    self.info(number, state, text, line)
    self.rt.rowcount = 0
    self.done(246)
    return
  }
  raise @types.sql_error(number, text, state~, severity~)
}

///|
fn Session::exec_throw(self : Session, args : Array[@ast.Expr]) -> Unit raise {
  self.cur_cmd = 246
  self.throwing = true
  if args.is_empty() {
    match self.rt.catch_error {
      Some(err) =>
        raise @types.sql_error(
          err.number,
          err.message,
          state=err.state,
          severity=err.severity,
        )
      None =>
        raise @types.sql_error(
          10704,
          "To rethrow an error, a THROW statement must be used inside a CATCH block. Insert the THROW statement inside a CATCH block, or add error handling to the existing THROW statement.",
          severity=15,
        )
    }
  }
  let number = self.eval(args[0]).0.as_int64().unwrap_or(0L).to_int()
  let text = match self.eval(args[1]) {
    (String(t), _) => t
    (v, ty) =>
      match @types.cast(v, ty, NVarChar(Some(2048), @types.default_collation)) {
        String(t) => t
        _ => ""
      }
  }
  let state = self.eval(args[2]).0.as_int64().unwrap_or(1L).to_int()
  if number < 50000 {
    raise @types.sql_error(
      35100,
      "Error number \{number} in the THROW statement is outside the valid range. Specify an error number in the valid range of 50000 to 2147483647.",
    )
  }
  raise @types.sql_error(number, text, state~, severity=16)
}

///|
fn Session::exec_try(
  self : Session,
  body : Array[@ast.Stmt],
  handler : Array[@ast.Stmt],
) -> Unit raise {
  self.done(349)
  self.try_depth += 1
  let caught = try {
    self.exec_list(body)
    None
  } catch {
    Caught(e, line) => Some((e, line))
    other => {
      self.try_depth -= 1
      raise other
    }
  }
  self.try_depth -= 1
  match caught {
    None => ()
    Some((e, line)) => {
      self.done(350)
      let saved = self.rt.catch_error
      self.rt.catch_error = Some({
        number: e.number(),
        severity: e.severity(),
        state: e.state(),
        message: e.message(),
        line,
        procedure: None,
      })
      errdefer {
        self.rt.catch_error = saved
      }
      self.exec_list(handler)
      self.rt.catch_error = saved
    }
  }
  // The construct completes with 351 whether or not CATCH ran (captured:
  // msduck control-completion-tokens #10/#11).
  self.done(351)
}
