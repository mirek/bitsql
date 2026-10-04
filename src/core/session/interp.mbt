///|
/// Raised inside TRY: the error was already completed; CATCH takes over.
/// Fields: error, line, procedure (ERROR_PROCEDURE()), and the nesting
/// level below which a TRY may catch it: a compile error is caught only by
/// a TRY of a calling scope (captured: msduck try-binding-error,
/// gaps-procedures #061).
priv suberror Caught {
  Caught(@types.SqlError, Int, String?, Int)
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
  self.stmt_line = line
  // the current line as SQL Server reports it for errors raised before a
  // statement sets its own (OPEN/FETCH of a missing cursor): DECLARE
  // without initializers and blocks do not set it
  let f = self.frame()
  // after a failed statement the next one reports its own line (captured:
  // stmts/cursor-lines, FETCH after a failed OPEN)
  self.prev_line = if f.line_mark < 0 { line } else { f.line_mark }
  match s.kind {
    Declare(vars) if vars.iter().all(v => v.init is None) => ()
    Block(_) => ()
    _ => f.line_mark = line
  }
  self.recompile_temp_refs(s)
  self.rt.stmt_reads = statement_reads(self.slice(s.span))
  self.rt.stmt_dml = match s.kind {
    Insert(_) | Update(_) | Delete(_) | Merge(_) => true
    Select({ body: Select({ into: Some(_), .. }), .. }) => true
    _ => false
  }
  self.rt.null_eliminated = false
  self.tx_ended_in_trigger = false
  self.cur_cmd = 253
  self.ddl_cmd = 0
  self.uncatchable = false
  self.error_line = None
  self.error_module = None
  self.throwing = false
  self.stmt_error = 0
  self.rt.next_row()
  self.deferred.clear()
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
  let out_mark = self.out.length()
  self.read_only_write = false
  let failure = try {
    self.exec_stmt(s)
    // a write to a READ_ONLY database: 3906 instead of the statement's own
    // output, ending the batch (captured: settings/alter-database)
    if self.read_only_write {
      self.read_only_write = false
      self.out.truncate(out_mark)
      self.cur_cmd = 253
      raise @types.sql_error(
        3906,
        "Failed to update database \"\{self.rt.database}\" because the database is read-only.",
      )
    }
    // a deferred binder error no later error reported (bound outside
    // bind_query): still an error
    if !self.deferred.is_empty() {
      raise self.deferred.remove(0)
    }
    None
  } catch {
    @types.SqlError(..) as e => Some(e)
    // An error leaving a trigger: the firing statement completes like a
    // caught statement (count 0) when a TRY catches it, and is terminated
    // (3621) when it ends the batch, except after THROW (captured:
    // gaps-triggers #033, #037, #029).
    Caught(_, _, _, _) as c if self.trigger_unwind => {
      self.trigger_unwind = false
      // MERGE too (captured: gaps-triggers #137)
      let rows = (self.cur_cmd >= 195 && self.cur_cmd <= 197) ||
        self.cur_cmd == 279
      if self.cur_cmd != 253 {
        self.done(self.cur_cmd, count=if rows { Some(0L) } else { None })
      }
      raise c
    }
    AbortBatch if self.trigger_unwind => {
      self.trigger_unwind = false
      let dml = (self.cur_cmd >= 195 && self.cur_cmd <= 197) ||
        self.cur_cmd == 279 ||
        self.cur_cmd == 125 ||
        self.cur_cmd == 126
      // no 3621 after the nesting limit 217 (captured: gaps-triggers #076)
      if dml && !self.throwing && self.rt.error != 217 {
        self.out.push(
          Message({
            number: 3621,
            state: 0,
            class: 0,
            message: "The statement has been terminated.",
            procedure: "",
            line,
          }),
        )
      }
      raise AbortBatch
    }
    other => raise other
  }
  // statement-duration locks (and all locks in autocommit) end here
  self.server.wake_all(self.server.locks.release_statement(self.rt.spid))
  guard failure is Some(e) else {
    // a successful statement sets @@ERROR to 0, or to 50000 for
    // RAISERROR ... WITH SETERROR (stmt_error); after EXEC it is the
    // module's last @@ERROR (captured: gaps-procedures #101)
    if !(s.kind
      is (If(_, _, _) | While(_, _) | Block(_) | Exec(_) | ExecString(_))) {
      self.rt.error = self.stmt_error
    }
    return
  }
  let line = match self.error_line {
    Some(l) => l
    None => udf_error_line(e, line)
  }
  self.frame().line_mark = -1
  // under SET ANSI_WARNINGS OFF SQL Server truncates strings silently and,
  // with ARITHABORT OFF, makes overflow and division by zero NULL: not
  // modelled; with ARITHABORT ON those errors stay (captured: 8115 and 8134
  // under OFF, msduck aggregate-warning-boundaries)
  let e = if !self.ansi_warnings() &&
    (
      [2628, 8152].contains(e.number()) ||
      (
        [8115, 8134].contains(e.number()) &&
        !self.session_flags.get("ARITHABORT").unwrap_or(true)
      )
    ) {
    @types.not_supported("\{e.number()} under SET ANSI_WARNINGS OFF")
  } else {
    e
  }
  let owner = self.module_name()
  // a module's own errors decide its return status (EXEC errors belong to
  // the callee; captured: proc/return-status)
  if e.severity() > 10 && !(s.kind is (Exec(_) | ExecString(_))) {
    let f = self.frame()
    if e.severity() > f.worst {
      f.worst = e.severity()
    }
  }
  // statement-level rollback: discard the failed statement's writes
  self.temp = snap_temp
  self.tvars = snap_tvars
  match (snap_tx, self.tx, snap_view) {
    (Some(_), Some(tx), Some(v)) => tx.view = v
    (None, None, _) if self.tx_ended_in_trigger =>
      self.tx_ended_in_trigger = false
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
  // batch-aborting conversion errors roll back (or doom) the transaction
  // even without XACT_ABORT (captured: savepoint errors/catch runs)
  // and so does MERGE's 8672 (captured: gaps-merge #022: ERROR, then the
  // rollback ENVCHANGE)
  let conversion_abort = [241, 245, 295, 8114, 8672, 3952].contains(e.number()) ||
    is_identity_overflow(e)
  let xact_rollback = (
      (self.xact_abort && !raiserror && e.severity() > 10) || conversion_abort
    ) &&
    self.rt.trancount > 0
  if xact_rollback && self.try_depth > 0 {
    self.rt.xact_state = -1
  }
  // compile errors (raised while binding, before the statement runs) are
  // not caught by TRY in the same scope (captured: msduck try-binding-error)
  if (self.cur_cmd == 253 && is_compile_error(e.number())) ||
    e.number() == @types.EMU_WORK_BUDGET {
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
    // to the enclosing CATCH (docs/reference/completions.md). Its warnings
    // are dropped (captured: no 8153 for a caught MIN(CONVERT(…)) failure).
    self.rt.null_eliminated = false
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
    raise Caught(e, line, owner, max_nest_level + 1)
  }
  // a compile error that the TRY of its own scope cannot catch is caught by
  // a TRY of a calling scope: the module ends and that CATCH runs
  if self.uncatchable &&
    self.try_base > 0 &&
    e.severity() > 10 &&
    e.severity() < 20 &&
    e.number() != @types.EMU_WORK_BUDGET {
    self.pending.clear()
    self.trailing.clear()
    raise Caught(e, line, owner, self.rt.nest_level)
  }
  // A DML statement failing at run time ends with 3621 "The statement has
  // been terminated." unless the error ends the batch (captured:
  // catalog/filtered-unique, output/dml-error-completion). A batch-ending
  // error completes with 253 unless an OUTPUT result set had started.
  // positioned UPDATE/DELETE (WHERE CURRENT OF) complete with 125/126
  // (captured: msduck-runs/cursor #037-#048)
  let dml = (self.cur_cmd >= 195 && self.cur_cmd <= 197) ||
    self.cur_cmd == 279 ||
    self.cur_cmd == 125 ||
    self.cur_cmd == 126
  let ends_batch = aborts_batch(
    e,
    self.cur_cmd,
    self.throwing,
    self.xact_abort && !raiserror,
  )
  // IDENTITY_INSERT errors (544, 545, 339) come without 3621 (captured:
  // msduck identity-insert-*)
  if dml &&
    !ends_batch &&
    self.trailing.is_empty() &&
    ![544, 545, 339].contains(e.number()) {
    ignore(self.terminated(e))
  }
  let mark = @cmp.minimum(out_mark, self.out.length())
  if dml && ends_batch && !self.out[mark:].iter().any(x => x is ResultSet(_)) {
    self.cur_cmd = 253
  }
  self.flush_pending(line)
  for d in self.deferred {
    self.message(d, line)
  }
  self.deferred.clear()
  self.message(e, line)
  // a deadlock victim's transaction is rolled back after the error
  // (captured order: ERROR, ENVCHANGE; locking/deadlock-two-tables), and so
  // is the transaction under XACT_ABORT (captured: proc/xact-abort)
  if e.number() == 1205 || (xact_rollback && self.try_depth == 0) {
    self.abort_transaction()
  }
  self.flush_trailing(line)
  // A batch-ending error completes with 253 unless the statement had sent
  // a result set: uncaught THROW, assignments, IF conditions, PRINT,
  // transaction statements under XACT_ABORT (captured: msduck
  // nocount-completions, datestrings/implicit#009, savepoint abort run)
  let result_started = self.out[mark:].iter().any(x => x is ResultSet(_))
  let cmd = if self.throwing || (ends_batch && !result_started) {
    253
  } else {
    self.cur_cmd
  }
  // Inside a module an aborting error sends no completion of its own: a
  // compile-time error ends the module (AbortScope), any other ends the
  // whole batch, whose outermost level completes it (captured:
  // gaps-procedures #057, #060, proc/abort-tokens, gaps-triggers #029).
  if ends_batch && self.rt.nest_level > 0 {
    if scope_abort(
        e,
        self.cur_cmd,
        self.throwing,
        self.xact_abort && !raiserror,
      ) {
      raise AbortScope
    }
    self.abort_cmd = Some(cmd)
    raise AbortBatch
  }
  // an XML parse error in an RPC request has no DONEINPROC: DONEPROC
  // follows the ERROR (captured: xml/rpc#001); so has a JSON error
  // (captured: msduck isjson-depth, json-constructors#087/#091)
  if !(self.rpc &&
    ((e.number() >= 9400 && e.number() < 9500) || json_aborts_batch(e))) {
    self.done(cmd, error=true)
  }
  if ends_batch {
    raise AbortBatch
  }
}

///|
/// An aborting error that ends only the current module: a compile-time
/// (cmd 253) error that no other rule makes batch-aborting.
fn scope_abort(
  e : @types.SqlError,
  cmd : Int,
  throwing : Bool,
  xact_abort : Bool,
) -> Bool {
  cmd == 253 && !aborts_batch(e, 0, throwing, xact_abort)
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
  n == 241 ||
  n == 245 ||
  n == 3952 ||
  n == 295 ||
  n == 8114 ||
  n == 8672 ||
  n == 529 ||
  n == 11728 ||
  n == 217 ||
  is_identity_overflow(e) ||
  // XML parse errors (captured: xml/type#059, xml/rpc#001)
  (n >= 9400 && n < 9500) ||
  json_aborts_batch(e) ||
  (n >= 50100 && n <= 50199)
}

///|
/// JSON run-time errors (136xx, and the NULL path 8116 state 8 of the JSON
/// functions) end the batch (captured json3 probes: the next statement does
/// not run; a TRY still catches them).
fn json_aborts_batch(e : @types.SqlError) -> Bool {
  let n = e.number()
  (n >= 13600 && n < 13700) || (n == 8116 && e.state() == 8)
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
  // compile-time in SQL Server: the error's DONE has CurCmd 253 (captured)
  // (an untyped NULL literal is assignable to anything, xml included)
  let failed = try {
    if !(value_expr.kind is Lit(Null) && value_expr.ty is Int) {
      @types.check_assign(value_expr.ty, info.ty)
    }
  } catch {
    e => Some(e)
  } noraise {
    _ => None
  }
  if failed is Some(e) {
    self.cur_cmd = 253
    raise e
  }
  let v = @exec.eval(self.ctx(), value_expr)
  self.frame().values[info.slot] = @types.assign(
    v,
    value_expr.ty,
    info.ty,
    dates=self.rt.dates,
  )
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
        if is_cursor_type(v.type_) {
          // a cursor variable: no cursor until SET assigns one
          self.frame().cursor_vars[v.name.to_lower()] = None
          continue
        }
        let ty = match self.declared_var_type(v.name, v.type_) {
          ScalarDecl(ty, _, _) => ty
          TableDecl(ut) => {
            self.declare_typed_table(v.name, ut)
            continue
          }
        }
        if ty.is_lob() {
          raise @types.lob_variable_error()
        }
        let existing = self.frame().vars.contains(v.name.to_lower()) ||
          self.frame().tables.contains(v.name.to_lower())
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
    SetVarMethod(_, m, _) => {
      self.cur_cmd = 193
      raise @types.not_supported(
        "the xml \{m.name}() method",
        number=@types.EMU_XML_NOT_SUPPORTED,
      )
    }
    SetVar(name, _, e) if self.frame().cursor_vars.contains(name.to_lower()) =>
      self.assign_cursor_var(name, e)
    SetVar(name, op, e) => {
      self.cur_cmd = 193
      self.assign(name, op, e)
      self.rt.rowcount = 1
      self.done(193, count=Some(1L))
    }
    SetOption(names, value) => {
      // captured: SET resets @@ROWCOUNT (traps/rowcount-reset)
      self.rt.rowcount = 0
      match self.set_options(names, value, s.span.line) {
        Some(cmd) => self.done(cmd)
        None => self.schema_ddl = true // no DONE (batch-final DONE if alone)
      }
    }
    SetIsolation(level) => {
      self.rt.rowcount = 0
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
      // captured: PRINT of a sql_variant is 257 (no implicit conversion)
      let text = match @types.assign(v, ty, limit) {
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
      // captured: IF resets @@ROWCOUNT (traps/rowcount-reset)
      self.rt.rowcount = 0
      self.done(192)
      if @exec.is_true(v) {
        self.exec_block(then_)
        match else_ {
          Some(e) => self.declare_skipped_tables(e)
          None => ()
        }
      } else {
        self.declare_skipped_tables(then_)
        if else_ is Some(e) {
          self.exec_block(e)
        }
      }
    }
    While(cond, body) => {
      self.lock_expr_reads(cond)
      let b = @bind.bind_expr(self.env(), cond)
      while true {
        self.rt.charge(10L)
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
      self.declare_skipped_tables(body)
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
            _ => {
              // captured: gaps-procedures #025 (INFO before the DONEINPROC)
              let name = self.module_name().unwrap_or("")
              self.info(
                282,
                1,
                "The '\{name}' procedure attempted to return a status of NULL, which is not allowed. A status of 0 will be returned instead.",
                s.span.line,
              )
              Some(0)
            }
          }
        }
        None => None
      }
      // Bare RETURN completes with 219 and resets @@ROWCOUNT; RETURN <expr>
      // completes like an assignment (193, count 1) (captured:
      // smoke/proc-return-output, msduck catch-return-rpc, gaps-procedures
      // #031).
      if status is Some(_) {
        self.rt.rowcount = 1
        self.done(193, count=Some(1L))
      } else {
        self.rt.rowcount = 0
        self.done(219)
      }
      raise Return(status)
    }
    TryCatch(body, handler) => self.exec_try(body, handler)
    BeginTran(name~, ..) => {
      self.rt.rowcount = 0 // captured: traps/rowcount-reset
      let name = self.tran_name(name)
      self.begin_tx(name~)
      self.rt.trancount += 1
      self.rt.xact_state = if self.rt.xact_state == -1 { -1 } else { 1 }
      if self.rt.trancount == 1 {
        self.out.push(EnvChange(BeginTransaction(self.tx_descriptor())))
      }
      self.done(212)
    }
    Commit(..) => {
      self.rt.rowcount = 0 // captured: traps/rowcount-reset
      self.cur_cmd = 213
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
      self.rt.rowcount = 0 // captured: traps/rowcount-reset
      self.cur_cmd = 210
      if self.rt.trancount == 0 {
        raise @types.sql_error(
          3903, "The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.",
        )
      }
      // Savepoints first (innermost, names compared under the collation;
      // rolling back to one also removes it and later ones), then the
      // outermost transaction's name (case-sensitive), else 6401; no name
      // or NULL rolls back everything (captured: msduck-runs/savepoint).
      match (self.tran_name(name), self.tx) {
        (Some(n), Some(tx)) =>
          match tx.savepoint_index(n, self.db_collation()) {
            Some(i) => {
              if self.rt.xact_state == -1 {
                raise @types.sql_error(
                  3931, "The current transaction cannot be committed and cannot be rolled back to a savepoint. Roll back the entire transaction.",
                )
              }
              let (_, view, temp) = tx.savepoints[i]
              tx.view = view
              self.temp = temp
              tx.savepoints.truncate(i)
              self.done(210)
              return
            }
            None =>
              if tx.name != Some(n) {
                raise @types.sql_error(
                  6401,
                  "Cannot roll back \{n}. No transaction or savepoint of that name was found.",
                  state=if n == "" { 2 } else { 1 },
                )
              }
          }
        _ => ()
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
      self.rt.rowcount = 0 // captured: traps/rowcount-reset
      self.cur_cmd = 214
      let name = self.tran_name(name)
      if self.rt.trancount == 0 {
        // ends the batch (DONE 253) unless caught; a TRY completes the
        // SAVE with 214 (captured: savepoint none/catch runs)
        self.cur_cmd = 253
        self.ddl_cmd = 214
        raise @types.sql_error(
          628,
          "Cannot issue SAVE TRANSACTION when there is no active transaction.",
          state=0,
        )
      }
      if self.rt.xact_state == -1 {
        raise doomed_error()
      }
      match (name, self.tx) {
        (Some(sp), Some(tx)) => tx.savepoints.push((sp, tx.view, self.temp))
        _ => ()
      }
      self.done(214)
    }
    CreateTable(ct) => {
      self.ddl_cmd = 198
      self.exec_create_table(ct)
    }
    DeclareTable(name, body) =>
      self.exec_declare_table(name, body, s.span.start)
    Drop(kind, if_exists~, names) => self.exec_drop(kind, if_exists, names)
    Insert(ins) => self.exec_insert(ins)
    Update(u) => self.exec_update(u)
    Delete(d) => self.exec_delete(d)
    Merge(m) => self.exec_merge(m)
    CreateDatabase(name, collate~) => self.exec_create_database(name, collate)
    AlterDatabase(target~, action) => self.exec_alter_database(target, action)
    Use(name) => self.exec_use(name)
    Truncate(name) => self.exec_truncate(name)
    SetIdentityInsert(name, on) =>
      match self.find_table(name) {
        Some((_, t)) => {
          // the name as written (captured: msduck
          // identity-insert-name-errors, 'DbO.PLAIN'); also for OFF
          // (gaps-rowversion_identity #180)
          if t.columns.iter().all(c => c.identity is None) {
            raise @types.sql_error(
              8106,
              "Table '\{object_text(name)}' does not have the identity property. Cannot perform SET operation.",
            )
          }
          if on {
            // captured: another table's ON is 8107 naming it in three
            // parts (gaps-rowversion_identity #166)
            match self.identity_insert {
              Some(other) if other != t.id => {
                let full = match self.db_of(0).table(other) {
                  Some(o) => "\{self.rt.database}.\{o.schema}.\{o.name}"
                  None =>
                    match self.temp.table(other) {
                      Some(o) => "tempdb.\{o.schema}.\{o.name}"
                      None => "?"
                    }
                }
                raise @types.sql_error(
                  8107,
                  "IDENTITY_INSERT is already ON for table '\{full}'. Cannot perform SET operation for table '\{object_text(name)}'.",
                )
              }
              _ => ()
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
            1088,
            "Cannot find the object \"\{object_text(name)}\" because it does not exist or you do not have permissions.",
            state=11,
          )
      }
    // catalog DDL (ddl*.mbt)
    CreateProcedure(p) => self.exec_create_procedure(p, s.span.start)
    CreateView(v) => self.exec_create_view(v, s.span.start)
    CreateFunction(f) => self.exec_create_function(f, s.span.start)
    CreateTrigger(t) => self.exec_create_trigger(t, s.span.start)
    CreateSchema(name, ..) => self.exec_create_schema(name)
    CreateType(ct) => self.exec_create_type(ct)
    CreateSynonym(name, base) => self.exec_create_synonym(name, base)
    CreateSequence(name, type_~, options~) =>
      self.exec_create_sequence(name, type_, options, s.span.start, s.span.line)
    InsertBulk(name, _, options) => self.exec_insert_bulk(name, options)
    AlterSequence(name, options) =>
      self.exec_alter_sequence(name, options, s.span.line)
    EnableTrigger(enable~, names, table) =>
      self.exec_enable_trigger(enable, names, table)
    AlterTable(name, action) => {
      self.ddl_cmd = 216
      self.exec_alter_table(name, action)
    }
    CreateIndex(ci) => {
      self.ddl_cmd = 200
      self.exec_create_index(ci)
    }
    DropIndex(if_exists~, items) => self.exec_drop_index(if_exists, items)
    Exec(e) => self.exec_proc_stmt(e, s.span.line)
    ExecString(parts) => self.exec_string(parts)
    DeclareCursor(c) => self.exec_declare_cursor(c)
    SetCursor(c) => self.exec_set_cursor(c)
    OpenCursor(name, global~) => self.exec_open_cursor(name, global)
    Fetch(f) => self.exec_fetch(f)
    CloseCursor(name, global~) => self.exec_close_cursor(name, global)
    Deallocate(name, global~) => self.exec_deallocate(name, global)
    WaitFor(kind, e) => self.exec_waitfor(kind, e)
    Dbcc(name, args, options) =>
      self.exec_dbcc(name, args, options, s.span.line)
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
    Caught(e, line, procedure, below) if self.rt.nest_level < below =>
      Some((e, line, procedure))
    other => {
      self.try_depth -= 1
      raise other
    }
  }
  self.try_depth -= 1
  match caught {
    None => ()
    Some((e, line, procedure)) => {
      self.done(350)
      let saved = self.rt.catch_error
      self.rt.catch_error = Some({
        number: e.number(),
        severity: e.severity(),
        state: e.state(),
        message: e.message(),
        line,
        procedure,
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

///|
/// Does a statement that calls XACT_STATE() also read data or metadata (a
/// FROM clause, IDENT_CURRENT, OBJECT_ID)? Token-level, so string literals
/// and comments do not count.
fn statement_reads(text : String) -> Bool {
  if !text.to_upper().contains("XACT_STATE") {
    return false
  }
  let toks = @lex.lex(text) catch { _ => return false }
  for k, t in toks {
    if t.is_kw("FROM") {
      return true
    }
    if (t.is_kw("IDENT_CURRENT") || t.is_kw("OBJECT_ID")) &&
      k + 1 < toks.length() &&
      toks[k + 1].is_punct("(") {
      return true
    }
  }
  false
}
