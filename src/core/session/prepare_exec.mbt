///|
/// EXEC sp_prepare / sp_execute / sp_unprepare inside T-SQL (a batch or
/// sp_executesql text). They share the handles of the RPC forms. Captured:
/// msduck-runs count-null-compilation #066-#071, tail/prepare-in-batch.
fn Session::exec_prepare_proc(
  self : Session,
  which : String,
  e : @ast.Exec,
  line : Int,
) -> Unit raise {
  if e.args.iter().any(a => a.name is Some(_)) {
    raise @types.not_supported("named arguments of \{which} in T-SQL")
  }
  match which {
    "sp_prepare" => self.exec_sp_prepare(e, line)
    "sp_execute" => self.exec_sp_execute(e, line)
    _ => self.exec_sp_unprepare(e, line)
  }
}

///|
/// An error of a prepared-statement procedure itself: ERROR(s), the status
/// as RETURNSTATUS (top level only), DONEPROC/DONEINPROC with the error bit.
fn Session::prepare_proc_fail(
  self : Session,
  errors : Array[@types.SqlError],
  return_var : String?,
) -> Unit raise {
  if self.try_depth > 0 {
    raise @types.not_supported(
      "errors of sp_prepare/sp_execute/sp_unprepare inside TRY",
    )
  }
  for err in errors {
    self.message(err, 1, procedure=Some(""))
  }
  let status = errors[errors.length() - 1].number()
  self.rt.error = status
  self.set_return_var(return_var, status)
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=true)
}

///|
fn handle_not_found(handle : Int, state : Int) -> @types.SqlError {
  @types.sql_error(
    8179,
    "Could not find prepared statement with handle \{handle}.",
    state~,
  )
}

///|
/// sp_prepare @handle OUTPUT, @params, @stmt [, @options = 1]: a single
/// SELECT compiles now and sends its COLMETADATA; a compile error is the
/// error plus 8180 (no handle). Text that does not parse, holds several
/// statements or a procedure call is prepared without compiling: status
/// 8182, no messages.
fn Session::exec_sp_prepare(
  self : Session,
  e : @ast.Exec,
  _line : Int,
) -> Unit raise {
  let args = e.args
  if args.length() < 3 || args.length() > 4 {
    raise @types.not_supported("sp_prepare with \{args.length()} arguments")
  }
  guard args[0].output && args[0].value.kind is Var(handle_var) else {
    raise @types.not_supported("sp_prepare without an OUTPUT handle variable")
  }
  let decls = match self.eval(args[1].value) {
    (String(d), _) => d
    (Null, _) => ""
    _ => raise @types.not_supported("sp_prepare @params of this type")
  }
  let sql = match self.eval(args[2].value) {
    (String(s), ty) if ty.is_unicode() => s
    _ => raise @types.not_supported("sp_prepare @stmt of this type")
  }
  match args.get(3).map(a => self.eval(a.value).0) {
    None | Some(Int(1)) => ()
    // captured: @options = 0 is 214 state 3 (tail/prepare-in-batch)
    Some(Int(0)) => {
      self.prepare_proc_fail(
        [
          @types.sql_error(
            214,
            "Procedure expects parameter '@options' of type 'int'.",
            state=3,
          ),
        ],
        e.return_var,
      )
      return
    }
    Some(_) => raise @types.not_supported("sp_prepare @options other than 1")
  }
  let assign = () => {
    let handle = self.next_handle
    self.next_handle += 1
    self.prepared[handle] = (decls, sql)
    self.set_return_var(Some(handle_var), handle)
  }
  let stmts = @parse.parse_batch(sql) catch { _ => [] }
  // `SELEC 1` parses as a procedure call: also deferred (captured), and so
  // are DECLARE and IF (captured: tail5/b2-prepare)
  if stmts.length() != 1 ||
    stmts[0].kind is (Exec(_) | Declare(_) | If(_, _, _)) {
    // deferred: compiled (and failing) at sp_execute
    assign()
    self.rt.error = 0
    self.set_return_var(e.return_var, 8182)
    if self.rt.nest_level == 0 {
      self.out.push(ReturnStatus(8182))
    }
    self.module_done(error=false)
    return
  }
  guard first_result_query(stmts) is Some(_) else {
    match self.prepare_compile(stmts[0], decls, sql) {
      Ok((cmd, counted)) => {
        self.out.push(
          InProcDone(
            cmd~,
            count=if counted { Some(0L) } else { None },
            error=false,
          ),
        )
        assign()
        self.rt.error = 0
        self.set_return_var(e.return_var, 0)
        self.proc_done(0)
      }
      Err(err) =>
        self.prepare_proc_fail(
          [err, @types.sql_error(8180, "Statement(s) could not be prepared.")],
          e.return_var,
        )
    }
    return
  }
  match self.describe_batch(sql, Some(decls), None) {
    Columns(_, bq) => {
      self.out.push(ResultSet(bq.columns.map(tds_column)))
      // captured: the ORDER token follows (msduck-runs order-token-expanded
      // #094-#097)
      if !bq.order.is_empty() {
        self.out.push(Order(bq.order))
      }
      self.out.push(InProcDone(cmd=193, count=Some(0L), error=false))
      assign()
      self.rt.error = 0
      self.set_return_var(e.return_var, 0)
      self.proc_done(0)
    }
    Failed(err) =>
      self.prepare_proc_fail(
        [err, @types.sql_error(8180, "Statement(s) could not be prepared.")],
        e.return_var,
      )
    NoResult =>
      raise @types.not_supported("sp_prepare of a statement other than SELECT")
  }
}

///|
/// sp_execute @handle [, values]: runs the prepared text like sp_executesql
/// (status = the last @@ERROR); an unknown handle is 8179 state 4.
fn Session::exec_sp_execute(
  self : Session,
  e : @ast.Exec,
  line : Int,
) -> Unit raise {
  guard e.args.get(0) is Some(h) else {
    raise @types.not_supported("sp_execute without a handle")
  }
  let handle = self.eval(h.value).0.as_int64().unwrap_or(0L).to_int()
  guard self.prepared.get(handle) is Some((decls, sql)) else {
    self.prepare_proc_fail([handle_not_found(handle, 4)], e.return_var)
    return
  }
  let args = []
  for i in 1..<e.args.length() {
    let a = e.args[i]
    let arg = match self.exec_arg_value(a) {
      Some(x) => x
      None => { value: Null, ty: Int, output: a.output, table: None, }
    }
    args.push((a.name, arg))
  }
  if self.rt.nest_level + 2 > max_nest_level {
    raise nesting_error()
  }
  let (params, b) = try {
    let (_, params, bound, _) = self.executesql_args(
      Some((String(sql), NVarChar(None, @types.default_collation))),
      decls,
      args,
      rpc=false,
      line~,
    )
    (params, self.executesql_frame(params, bound))
  } catch {
    ProcFail(err, _, _) => {
      self.prepare_proc_fail([err], e.return_var)
      return
    }
    err => raise err
  }
  self.rt.error = 0
  let before = self.rt.trancount
  let run = self.run_dynamic(sql, b, levels=2)
  let scope_aborted = run.end is ScopeAborted
  if !scope_aborted {
    self.write_back_outputs(e, params, run, skip=1)
  }
  if self.rt.trancount != before {
    raise @types.not_supported(
      "a transaction count change inside sp_execute in T-SQL",
    )
  }
  let status = self.rt.error
  self.set_return_var(e.return_var, status)
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=scope_aborted)
}

///|
/// sp_unprepare @handle: RETURNSTATUS 0 and DONEPROC without a count; an
/// unknown handle is 8179 state 8.
fn Session::exec_sp_unprepare(
  self : Session,
  e : @ast.Exec,
  _line : Int,
) -> Unit raise {
  guard e.args.length() == 1 else {
    raise @types.not_supported("sp_unprepare with \{e.args.length()} arguments")
  }
  let handle = self.eval(e.args[0].value).0.as_int64().unwrap_or(0L).to_int()
  if !self.prepared.contains(handle) {
    self.prepare_proc_fail([handle_not_found(handle, 8)], e.return_var)
    return
  }
  self.prepared.remove(handle)
  self.rt.error = 0
  self.set_return_var(e.return_var, 0)
  self.proc_done(0)
}

///|
/// sp_prepare of one statement that returns no first result set: compiles
/// it (DML binds up to its OUTPUT header, which is sent) and returns the
/// statement's CurCmd and whether its DONEINPROC carries a count, or the
/// compile error. Captured (tail5/b2-prepare): INSERT 195, DELETE 196,
/// UPDATE 197, MERGE 279 and `SET @p =` / `SELECT @p =` 193 with count 0;
/// SET NOCOUNT ON 185, CREATE TABLE 198, BEGIN TRAN 212, PRINT 247 without.
fn Session::prepare_compile(
  self : Session,
  stmt : @ast.Stmt,
  decls : String,
  sql : String,
) -> Result[(Int, Bool), @types.SqlError] raise {
  let shape : (Int, Bool) = match stmt.kind {
    Insert(_) => (195, true)
    Delete(_) => (196, true)
    Update(_) => (197, true)
    Merge(_) => (279, true)
    SetVar(_, _, _) => (193, true)
    Select({ body: Select({ into: None, .. }), .. }) => (193, true)
    SetOption(names, On | Off as v) if !names
      .iter()
      .any(n => {
        n.to_upper() is ("QUOTED_IDENTIFIER" | "ANSI_NULLS" | "IDENTITY_INSERT")
      }) => (if v is Off { 186 } else { 185 }, false)
    CreateTable(_) => (198, false)
    BeginTran(..) => (212, false)
    Print(_) => (247, false)
    _ =>
      raise @types.not_supported(
        "sp_prepare in T-SQL of this kind of statement",
      )
  }
  let params = parse_param_decls(decls) catch {
    _ => raise @types.not_supported("sp_prepare in T-SQL with these @params")
  }
  let b = self.bind_params(params, [], owner=None, conv_state=5)
  let mut failure : @types.SqlError? = None
  let saved_text = self.text
  self.text = sql
  defer {
    self.text = saved_text
    self.compile_only = false
  }
  self.compile_only = true
  ignore(
    self.run_module(b, levels=2, () => {
      self.compile_statement(stmt) catch {
        CompiledOnly => ()
        @types.SqlError(..) as err => failure = Some(err)
        err => raise err
      }
    }),
  )
  match failure {
    Some(err) => Err(err)
    None => Ok(shape)
  }
}

///|
/// Binds (without running) a statement for `prepare_compile`.
fn Session::compile_statement(self : Session, stmt : @ast.Stmt) -> Unit raise {
  match stmt.kind {
    Insert(i) => self.exec_insert(i)
    Update(u) => self.exec_update(u)
    Delete(d) => self.exec_delete(d)
    Merge(m) => self.exec_merge(m)
    SetVar(_, _, x) | Print(x) => ignore(@bind.bind_expr(self.env(), x))
    Select({ body: Select(sel), .. } as q) => {
      if !sel.items.iter().all(i => i.kind is Assign(_, _, _)) {
        raise @types.sql_error(
          141,
          "A SELECT statement that assigns a value to a variable must not be combined with data-retrieval operations.",
          severity=15,
        )
      }
      if sel.from.is_empty() && sel.where_ is None {
        for item in sel.items {
          if item.kind is Assign(_, _, x) {
            ignore(@bind.bind_expr(self.env(), x))
          }
        }
      } else {
        ignore(@bind.bind_assignment_select(self.env(), q))
      }
    }
    _ => ()
  }
}
