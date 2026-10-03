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
  self.ddl_cmd = 0
  self.uncatchable = false
  self.throwing = false
  self.stmt_error = 0
  self.refresh_tx()
  let snap_temp = self.temp
  let snap_tvars = self.tvars
  let snap_tx = self.tx
  let snap_view = match self.tx {
    Some(tx) => Some(tx.view)
    None => None
  }
  let snap_db = self.server.get_db(self.rt.database)
  let snap_database = self.rt.database
  let failure = try {
    self.exec_stmt(s)
    None
  } catch {
    @types.SqlError(..) as e => Some(e)
    other => raise other
  }
  // statement-duration locks (and all locks in autocommit) end here
  self.server.wake_all(self.server.locks.release_statement(self.rt.spid))
  guard failure is Some(e) else {
    // a successful statement sets @@ERROR to 0, or to 50000 for
    // RAISERROR ... WITH SETERROR (stmt_error)
    if !(s.kind is (If(_, _, _) | While(_, _) | Block(_))) {
      self.rt.error = self.stmt_error
    }
    return
  }
  let line = udf_error_line(e, line)
  // statement-level rollback: discard the failed statement's writes
  self.temp = snap_temp
  self.tvars = snap_tvars
  match (snap_tx, self.tx, snap_view) {
    (Some(_), Some(tx), Some(v)) => tx.view = v
    (None, None, _) => self.server.set_db(snap_database, snap_db)
    _ => ()
  }
  self.rt.error = self.error_override.unwrap_or(e.number())
  self.error_override = None
  self.rt.rowcount = 0
  // XACT_ABORT ON: inside TRY the transaction becomes uncommittable
  // (XACT_STATE() = -1); outside TRY it is rolled back and the batch ends.
  // RAISERROR never honors XACT_ABORT (THROW does)
  let raiserror = self.cur_cmd == 246 && !self.throwing
  if self.xact_abort && !raiserror && e.severity() > 10 && self.rt.trancount > 0 {
    if self.try_depth > 0 {
      self.rt.xact_state = -1
    } else {
      self.abort_transaction()
    }
  }
  // compile errors (raised while binding, before the statement runs) are
  // not caught by TRY in the same scope (captured: msduck try-binding-error)
  if self.cur_cmd == 253 && is_compile_error(e.number()) {
    self.uncatchable = true
  }
  if self.try_depth > 0 && !self.uncatchable {
    self.pending.clear()
    self.trailing.clear()
  }
  if self.try_depth > 0 &&
    !self.uncatchable &&
    e.severity() > 10 &&
    e.severity() < 20 {
    // caught DDL errors complete with the statement's own CurCmd
    if self.ddl_cmd != 0 {
      self.cur_cmd = self.ddl_cmd
    }
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
    if e.number() == 1205 {
      self.abort_transaction()
    }
    raise Caught(e, line)
  }
  // DML constraint violations end with 3621 "The statement has been
  // terminated." (captured: catalog/filtered-unique, locking/same-key-insert-waits)
  if self.cur_cmd >= 195 &&
    self.cur_cmd <= 197 &&
    [2627, 2601, 515, 547, 2628, 8152].contains(e.number()) &&
    self.trailing.is_empty() {
    ignore(self.terminated(e))
  }
  self.flush_pending(line)
  self.message(e, line)
  // a deadlock victim's transaction is rolled back after the error
  // (captured order: ERROR, ENVCHANGE; locking/deadlock-two-tables)
  if e.number() == 1205 {
    self.abort_transaction()
  }
  self.flush_trailing(line)
  // an uncaught THROW completes with 253, not 246 (captured: msduck
  // nocount-completions)
  self.done(if self.throwing { 253 } else { self.cur_cmd }, error=true)
  if aborts_batch(e, self.cur_cmd, self.throwing, self.xact_abort && !raiserror) {
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
  n == 11728 ||
  n == 217 ||
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
    Select(q) => self.exec_select(q, s.span.line)
    Declare(vars) => {
      // captured (query/select-into-assign): one DONE for the whole
      // DECLARE, however many variables are initialized
      let mut initialized = false
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
          initialized = true
        }
      }
      if initialized {
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
    SetOption(names, value) =>
      match self.set_options(names, value, s.span.line) {
        Some(cmd) => self.done(cmd)
        None => self.schema_ddl = true // no DONE (batch-final DONE if alone)
      }
    SetIsolation(level) => {
      self.isolation = level.to_upper()
      // captured: CurCmd 249 (corpus set/each)
      self.done(249)
    }
    Print(e) => {
      self.cur_cmd = 247
      let (v, ty) = self.eval(e)
      // up to 8000 bytes (4000 characters of nvarchar); an empty or NULL
      // message prints one space (captured: msduck print-unicode)
      let limit : @types.SqlType = if ty.is_unicode() {
        NVarChar(Some(4000), @types.default_collation)
      } else {
        VarChar(Some(8000), @types.default_collation)
      }
      let text = match @types.cast(v, ty, limit) {
        String(t) if t != "" => t
        _ => " "
      }
      self.info(0, 1, text, s.span.line)
      self.rt.rowcount = 0
      self.done(247)
    }
    RaisError(args, options~) => self.exec_raiserror(args, options, s.span.line)
    Throw(args) => self.exec_throw(args)
    If(cond, then_, else_) => {
      self.lock_expr_reads(cond)
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
      self.lock_expr_reads(cond)
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
      self.rt.xact_state = if self.rt.xact_state == -1 { -1 } else { 1 }
      if self.rt.trancount == 1 {
        self.out.push(EnvChange(BeginTransaction(self.tx_descriptor())))
      }
      self.done(212)
    }
    Commit(..) => {
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          3902, "The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION.",
        )
      }
      if self.rt.xact_state == -1 {
        raise doomed_error()
      }
      self.rt.trancount -= 1
      if self.rt.trancount == 0 {
        let d = self.tx_descriptor()
        let implicit = self.implicit_tx
        self.commit_tx()
        self.rt.xact_state = 0
        if !implicit {
          self.out.push(EnvChange(CommitTransaction(d)))
        }
      }
      self.done(213)
    }
    Rollback(name~) => {
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          3903, "The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.",
        )
      }
      match self.savepoint_name(name) {
        Some(sp) =>
          match self.tx {
            Some(tx) =>
              match tx.savepoints.get(sp.to_lower()) {
                Some((view, temp)) => {
                  if self.rt.xact_state == -1 {
                    raise doomed_error()
                  }
                  tx.view = view
                  self.temp = temp
                  self.done(210)
                  return
                }
                None => ()
              }
            None => ()
          }
        None => ()
      }
      let d = self.tx_descriptor()
      self.rt.trancount = 0
      self.rt.xact_state = 0
      let implicit = self.implicit_tx
      self.rollback_tx()
      if !implicit {
        self.out.push(EnvChange(RollbackTransaction(d)))
      }
      self.done(210)
    }
    Save(name~) => {
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          628, "Cannot issue SAVE TRANSACTION when there is no active transaction.",
        )
      }
      if self.rt.xact_state == -1 {
        raise doomed_error()
      }
      match (self.savepoint_name(name), self.tx) {
        (Some(sp), Some(tx)) =>
          tx.savepoints[sp.to_lower()] = (tx.view, self.temp)
        _ => ()
      }
      self.done(214)
    }
    CreateTable(ct) => {
      self.ddl_cmd = 198
      self.exec_create_table(ct)
    }
    DeclareTable(name, body) => self.exec_declare_table(name, body)
    Drop(kind, if_exists~, names) => self.exec_drop(kind, if_exists, names)
    Insert(ins) => self.exec_insert(ins)
    Update(u) => self.exec_update(u)
    Delete(d) => self.exec_delete(d)
    Merge(m) => self.exec_merge(m)
    CreateDatabase(name, ..) => self.exec_create_database(name)
    Use(name) => self.exec_use(name)
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
          // captured: 183 / 184 (corpus set/each)
          self.done(if on { 183 } else { 184 })
        }
        None =>
          raise @types.sql_error(
            208,
            "Invalid object name '\{name.parts.map(p => p.name).join(".")}'.",
          )
      }
    // catalog DDL (ddl*.mbt)
    CreateProcedure(p) => self.exec_create_procedure(p, s.span.start)
    CreateView(v) => self.exec_create_view(v, s.span.start)
    CreateFunction(f) => self.exec_create_function(f, s.span.start)
    CreateTrigger(t) => self.exec_create_trigger(t, s.span.start)
    CreateSchema(name, ..) => self.exec_create_schema(name)
    CreateSequence(name, type_~, options~) =>
      self.exec_create_sequence(name, type_, options, s.span.start, s.span.line)
    InsertBulk(name, _, options) => self.exec_insert_bulk(name, options)
    AlterSequence(name, options) =>
      self.exec_alter_sequence(name, options, s.span.line)
    AlterTable(name, action) => {
      self.ddl_cmd = 216
      self.exec_alter_table(name, action)
    }
    CreateIndex(ci) => {
      self.ddl_cmd = 200
      self.exec_create_index(ci)
    }
    DropIndex(if_exists~, items) => self.exec_drop_index(if_exists, items)
    Exec(e) => self.exec_proc_stmt(e)
    ExecString(parts) => self.exec_string(parts)
    DeclareCursor(c) => self.exec_declare_cursor(c)
    OpenCursor(name, global~) => self.exec_open_cursor(name, global)
    Fetch(f) => self.exec_fetch(f)
    CloseCursor(name, global~) => self.exec_close_cursor(name, global)
    Deallocate(name, global~) => self.exec_deallocate(name, global)
    WaitFor(kind, e) => self.exec_waitfor(kind, e)
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
fn Session::exec_select(
  self : Session,
  q : @ast.Query,
  line : Int,
) -> Unit raise {
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
    if !sel.from.is_empty() ||
      sel.where_ is Some(_) ||
      !sel.group_by.is_empty() ||
      sel.having is Some(_) ||
      !q.order_by.is_empty() {
      self.exec_assignment_select(q, line)
      return
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
  if q.body is Select(sel) && sel.into is Some(into) {
    self.exec_select_into(q, sel, into, line)
    return
  }
  self.exec_query(q, line)
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
  let severity = if severity < 0 { 0 } else { severity }
  let state = if state < 0 { 1 } else { state }
  let (number, text) = match msg_v {
    String(fmt) => {
      let types : Array[@types.SqlType?] = []
      for k in 3..<args.length() {
        types.push(if args[k].kind is Null { None } else { Some(values[k].1) })
      }
      // format errors report their own number; @@ERROR becomes 50000
      // (captured: msduck raiserror-failure-counter)
      // format errors report their own number; @@ERROR becomes 50000 when
      // the RAISERROR would have set it (severity > 10 or SETERROR;
      // captured: msduck raiserror-failure-counter)
      if severity > 10 || options.contains("SETERROR") {
        self.error_override = Some(50000)
      }
      let text = format_raiserror(
        fmt,
        values[3:].to_owned().map(x => x.0),
        types~,
      )
      self.error_override = None
      (50000, text)
    }
    other =>
      match other.as_int64() {
        Some(id) if id > 50000L => {
          // no sp_addmessage: every user message id is missing (captured)
          self.error_override = Some(id.to_int())
          raise @types.sql_error(
            18054,
            "Error \{id}, severity \{severity}, state \{state} was raised, but no message with that error number was found in sys.messages. If error is larger than 50000, make sure the user-defined message is added using sp_addmessage.",
          )
        }
        _ => raise @types.not_supported("RAISERROR with a system message id")
      }
  }
  if severity > 18 && !options.contains("LOG") {
    raise @types.sql_error(
      2754, "Error severity levels greater than 18 can only be specified by members of the sysadmin role, using the WITH LOG option.",
    )
  }
  if severity > 18 {
    raise @types.not_supported("RAISERROR WITH LOG severity above 18")
  }
  if options.contains("SETERROR") {
    self.stmt_error = number
  }
  if severity <= 10 {
    // Informational: INFO token whose class is the severity, except 10 is
    // sent as 0 (captured: msduck raiserror 9 → 9, 10 → 0).
    self.out.push(
      Message({
        number,
        state,
        class: if severity == 10 {
          0
        } else {
          severity
        },
        message: text,
        procedure: "",
        line,
      }),
    )
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

///|
/// Binder errors SQL Server reports while compiling (or recompiling) a
/// statement, which TRY in the same scope cannot catch.
fn is_compile_error(n : Int) -> Bool {
  [8117, 8116, 206, 402, 207, 4104, 209, 8120, 147, 4108, 4109].contains(n)
}
