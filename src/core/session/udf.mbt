// User-defined functions: the binder's catalog hook, scalar and
// multi-statement table-valued function execution, and CREATE FUNCTION body
// validation. Captures: harness/corpus/udf/*.sql.
//
// Calls reach the session from the executor through `@exec.Ctx::user_fn` /
// `user_table` (the body is procedural, so exec cannot run it). A call runs
// in a frame of its own (parameters, local variables, table variables) at
// @@NESTLEVEL + 1; its statements produce no tokens, and an error inside
// propagates to the calling statement, reported at the caller's line
// (captured: ERROR_LINE is the caller's, ERROR_PROCEDURE NULL).

///|
/// A parsed function definition, cached per object id while its definition
/// text is unchanged (ALTER FUNCTION replaces the text).
priv struct UdfDef {
  definition : String
  def : @ast.CreateFunction
  info : @bind.UserFunction
}

///|
/// Nesting limit of procedures, functions and triggers (error 217).
let max_nest_level : Int = 32

///|
fn is_function_kind(k : @store.ObjectKind) -> Bool {
  k is (ScalarFunction | InlineFunction | TableFunction)
}

///|
/// Catalog hook: a user function by (possibly unqualified) name.
fn Session::find_function(
  self : Session,
  name : @ast.ObjectName,
) -> @bind.UserFunction? raise @types.SqlError {
  if name.base().has_prefix("#") {
    return None
  }
  match self.find_module(name) {
    Some(m) if is_function_kind(m.kind) => Some(self.function_def(m).info)
    _ => None
  }
}

///|
fn Session::function_def(
  self : Session,
  m : @store.Module,
) -> UdfDef raise @types.SqlError {
  match self.server.udfs.get(m.id) {
    Some(d) if physical_equal(d.definition, m.definition) => return d
    _ => ()
  }
  let stmts = @parse.parse_batch(m.definition) catch {
    _ =>
      raise @types.not_supported(
        "function \{m.name} (definition does not parse)",
      )
  }
  guard stmts.iter().find_first(s => s.kind is CreateFunction(_))
    is Some({ kind: CreateFunction(def), .. }) else {
    raise @types.not_supported(
      "function \{m.name} (no CREATE FUNCTION in definition)",
    )
  }
  let params : Array[@bind.UserParam] = def.params.map(p => {
    match self.decl_type(p.type_, self.db_collation()) {
      ScalarDecl(ty, _, _) =>
        { name: p.name, ty, default_: p.default_, table_type: None, }
      TableDecl(ut) =>
        { name: p.name, ty: Int, default_: None, table_type: Some(ut.name), }
    }
  })
  let kind : @bind.UserFunctionKind = match def.returns {
    Scalar(t, _) => Scalar(self.scalar_type(t, self.db_collation()))
    InlineTable(q) => Inline(q)
    TableVariable(_, body, _) => {
      // the declared return table, built like DECLARE @t TABLE (unsaved);
      // its spans index the definition text
      let saved_text = self.text
      self.text = m.definition
      let t = self.table_from_body(0, "dbo", "@result", body, self.tvars, 3) catch {
        @types.SqlError(..) as e => {
          self.text = saved_text
          raise e
        }
        _ => {
          self.text = saved_text
          raise @types.not_supported("function \{m.name} return table")
        }
      }
      self.text = saved_text
      MultiStatement(table_columns(t))
    }
  }
  let d : UdfDef = {
    definition: m.definition,
    def,
    info: { id: m.id, params, kind, ansi_nulls: m.ansi_nulls, },
  }
  self.server.udfs[m.id] = d
  d
}

///|
/// The stored function `id` (dropped between bind and run: not supported).
fn Session::function_by_id(
  self : Session,
  id : Int,
) -> UdfDef raise @types.SqlError {
  match self.db_of(0).get_module(id) {
    Some(m) if is_function_kind(m.kind) => self.function_def(m)
    _ => raise @types.not_supported("a function dropped while being called")
  }
}

///|
/// 217: more than 32 nested procedure/function/trigger levels (captured:
/// ends the batch).
fn nesting_error() -> @types.SqlError {
  @types.sql_error(
    217, "Maximum stored procedure, function, trigger, or view nesting level exceeded (limit 32).",
  )
}

///|
/// Runs `body` as a function invocation: a new frame holding the
/// parameters, @@NESTLEVEL + 1, no tokens, and the session's per-statement
/// state restored afterwards. Only SqlErrors leave a function.
fn[T] Session::in_function(
  self : Session,
  d : UdfDef,
  args : Array[@types.Value],
  body : () -> T raise,
) -> T raise @types.SqlError {
  if self.rt.nest_level >= max_nest_level {
    raise nesting_error()
  }
  let frame = Frame::new()
  for i, p in d.info.params {
    if p.table_type is Some(_) {
      // a READONLY table-valued parameter: the caller's table variable id
      let key = p.name.to_lower()
      frame.read_only_tvps.add(key)
      match args.get(i) {
        Some(Int(id)) => frame.tables[key] = id
        _ => ()
      }
      continue
    }
    let slot = frame.add_var(p.name, p.ty)
    frame.values[slot] = args.get(i).unwrap_or(Null)
  }
  let mark = self.out.length()
  let saved_cmd = self.cur_cmd
  let saved_ddl = self.ddl_cmd
  let saved_throwing = self.throwing
  let saved_stmt_error = self.stmt_error
  let saved_uncatchable = self.uncatchable
  let saved_rowcount = self.rt.rowcount
  let saved_error = self.rt.error
  let saved_null = self.rt.null_eliminated
  let saved_override = self.rt.count_override
  // statement spans inside the body index the definition text
  let saved_text = self.text
  self.text = d.definition
  // the function's CREATE-time ANSI_NULLS
  let saved_ansi_nulls = self.session_flags.get("ANSI_NULLS")
  let saved_bits = self.rt.option_bits
  frame.module_settings = true
  self.frames.push(frame)
  self.rt.nest_level += 1
  self.set_ansi_nulls(d.info.ansi_nulls)
  let restore = () => {
    ignore(self.frames.pop())
    match saved_ansi_nulls {
      Some(v) => self.session_flags["ANSI_NULLS"] = v
      None => self.session_flags.remove("ANSI_NULLS")
    }
    self.rt.option_bits = saved_bits
    self.rt.nest_level -= 1
    // the frame's table variables die with it
    for k, id in frame.tables {
      if !frame.read_only_tvps.contains(k) || frame.owned.contains(k) {
        self.tvars = self.tvars.drop_object(id)
      }
    }
    self.out.truncate(mark)
    self.cur_cmd = saved_cmd
    self.ddl_cmd = saved_ddl
    self.throwing = saved_throwing
    self.stmt_error = saved_stmt_error
    self.uncatchable = saved_uncatchable
    self.rt.rowcount = saved_rowcount
    self.rt.error = saved_error
    self.rt.null_eliminated = saved_null
    self.rt.count_override = saved_override
    self.text = saved_text
  }
  let result = body() catch {
    @types.SqlError(..) as e => {
      restore()
      raise e
    }
    _ => {
      // lock waits and control flow cannot leave an expression
      restore()
      raise @types.not_supported(
        "this statement inside a user-defined function",
      )
    }
  }
  restore()
  result
}

///|
/// `Ctx::user_fn`: evaluates a scalar function for converted arguments.
fn Session::call_scalar_udf(
  self : Session,
  id : Int,
  args : Array[@types.Value],
) -> @types.Value raise @types.SqlError {
  let d = self.function_by_id(id)
  guard d.def.returns is Scalar(_, body) && d.info.kind is Scalar(ret) else {
    raise @types.not_supported("calling a table-valued function as a scalar")
  }
  if d.def.options.contains("RETURNS NULL ON NULL INPUT") &&
    args.iter().any(a => a is Null) {
    return Null
  }
  self.in_function(d, args, () => {
    self.hoist_declares(body)
    match self.udf_list(body, Some(ret)) {
      Returned(Some(v)) => v
      // validated at CREATE: a scalar body ends with RETURN <value>
      _ => Null
    }
  })
}

///|
/// `Ctx::user_table`: runs a multi-statement table-valued function and
/// returns its table variable's rows. An error inside is followed by 3621
/// (captured; inline and scalar functions do not add it).
fn Session::call_table_udf(
  self : Session,
  id : Int,
  args : Array[@types.Value],
) -> Array[Array[@types.Value]] raise @types.SqlError {
  let d = self.function_by_id(id)
  guard d.def.returns is TableVariable(tv, table, body) else {
    raise @types.not_supported("this table-valued function call")
  }
  let rows = self.in_function(d, args, () => {
    self.exec_declare_table(tv, table, -1)
    self.hoist_declares(body)
    ignore(self.udf_list(body, None))
    match self.find_table_var(tv) {
      Some(t) => self.tvars.rows(t.id).map(kv => kv.1)
      None => []
    }
  }) catch {
    e => raise self.terminated(e)
  }
  rows
}

///|
/// Control flow out of a function statement.
priv enum UdfFlow {
  Next
  Brk
  Cont
  Returned(@types.Value?)
}

///|
fn Session::udf_list(
  self : Session,
  stmts : Array[@ast.Stmt],
  ret : @types.SqlType?,
) -> UdfFlow raise {
  for s in stmts {
    match self.udf_stmt(s, ret) {
      Next => ()
      flow => return flow
    }
  }
  Next
}

///|
/// One statement of a function body. Control flow is handled here; the
/// statements CREATE FUNCTION allows (variables, SELECT assignments, table
/// variable DML) run through the interpreter with their tokens discarded.
fn Session::udf_stmt(
  self : Session,
  s : @ast.Stmt,
  ret : @types.SqlType?,
) -> UdfFlow raise {
  match s.kind {
    Return(None) => Returned(None)
    Return(Some(e)) => {
      let (v, ty) = self.eval(e)
      match ret {
        Some(t) => Returned(Some(@types.cast(v, ty, t)))
        None => Returned(None)
      }
    }
    If(cond, then_, else_) => {
      let b = @bind.bind_expr(self.env(), cond)
      if @exec.is_true(@exec.eval(self.ctx(), b)) {
        self.udf_stmt(then_, ret)
      } else {
        match else_ {
          Some(e) => self.udf_stmt(e, ret)
          None => Next
        }
      }
    }
    While(cond, body) => {
      let b = @bind.bind_expr(self.env(), cond)
      while @exec.is_true(@exec.eval(self.ctx(), b)) {
        match self.udf_stmt(body, ret) {
          Brk => break
          Next | Cont => ()
          flow => return flow
        }
      }
      Next
    }
    Block(list) => self.udf_list(list, ret)
    Break => Brk
    Continue => Cont
    Declare(_) | SetVar(_, _, _) | DeclareTable(_, _) => {
      self.exec_stmt(s)
      Next
    }
    Select(q) if assigns_only(q) => {
      self.exec_stmt(s)
      Next
    }
    Insert({ target: { kind: TableVar(_, ..), .. }, .. })
    | Update({ target: { kind: TableVar(_, ..), .. }, .. })
    | Delete({ target: { kind: TableVar(_, ..), .. }, .. }) => {
      self.exec_stmt(s)
      Next
    }
    _ => raise @types.not_supported("\{stmt_name(s)} inside a function")
  }
}

///|
/// `SELECT @v = ...` (only assignments).
fn assigns_only(q : @ast.Query) -> Bool {
  match q.body {
    Select(sel) =>
      !sel.items.is_empty() &&
      sel.items.iter().all(i => i.kind is Assign(_, _, _))
    _ => false
  }
}

///|
/// A SELECT that would send rows to the client (444 inside a function).
fn returns_data(q : @ast.Query) -> Bool {
  match q.body {
    Select(sel) => sel.into is None && !assigns_only(q)
    _ => true
  }
}

///|
/// Line SQL Server reports for an error raised while binding a statement.
/// Captured oddity: table-valued function argument errors (313/8144 state
/// 3, 216) on a schema-qualified name report line 13 whatever the
/// statement's line (harness/corpus/udf/tvf-errors.sql).
fn udf_error_line(e : @types.SqlError, line : Int) -> Int {
  let n = e.number()
  let tvf_arity = (n == 313 || n == 8144) && e.state() == 3
  // 4413 (view or function with binding errors) likewise (captured:
  // tail/views-binding-errors)
  if (tvf_arity || n == 216 || n == 4413) && qualified_in_message(e.message()) {
    13
  } else {
    line
  }
}

///|
/// The function name in 313/8144/216 messages is as written; a '.' in it
/// means it was schema-qualified.
fn qualified_in_message(m : String) -> Bool {
  let key = "function "
  guard m.find(key) is Some(i) else { return false }
  let rest = m.unsafe_substring(start=i + key.length(), end=m.length())
  let word = match rest.find(" ") {
    Some(j) => rest.unsafe_substring(start=0, end=j)
    None => rest
  }
  // drop the closing quote / sentence period
  let mut n = word.length()
  while n > 0 && (word[n - 1] == '.' || word[n - 1] == '\'') {
    n -= 1
  }
  word.unsafe_substring(start=0, end=n).contains(".")
}

// ------------------------------------------------ CREATE FUNCTION checks

///|
/// 443: a side-effecting statement or built-in inside a function.
fn side_effect(op : String, state : Int) -> @types.SqlError {
  @types.sql_error(
    443,
    "Invalid use of a side-effecting operator '\{op}' within a function.",
    state~,
  )
}

///|
/// Compile-time checks of a function body (captured errors 443, 444, 455,
/// 178, 1075, 2772). Several 443s are all reported (pending), in order.
fn Session::validate_function(
  self : Session,
  f : @ast.CreateFunction,
) -> Unit raise @types.SqlError {
  let (body, scalar) = match f.returns {
    Scalar(_, b) => (b, true)
    TableVariable(_, _, b) => (b, false)
    InlineTable(_) => return
  }
  // temp tables and nondeterministic built-ins, found on the tokens
  let tokens = @lex.lex(f.definition) catch { _ => [] }
  for i, t in tokens {
    if t.kind is Word && t.text.has_prefix("#") {
      raise @types.sql_error(
        2772, "Cannot access temporary tables from within a function.",
      )
    }
    let call = match tokens.get(i + 1) {
      Some(n) => n.is_punct("(")
      None => false
    }
    if call &&
      (t.is_kw("NEWID") || t.is_kw("RAND") || t.is_kw("NEWSEQUENTIALID")) {
      raise side_effect(t.text.to_lower(), 1)
    }
  }
  let errors : Array[@types.SqlError] = []
  self.side_effects(body, if scalar { 3 } else { 2 }, errors)
  if !errors.is_empty() {
    let last = errors.pop().unwrap_or(side_effect("", 1))
    for e in errors {
      self.pending.push(e)
    }
    raise last
  }
  check_returns(body, scalar)
  if !ends_with_return(body) {
    raise @types.sql_error(
      455,
      "The last statement included within a function must be a return statement.",
      state=2,
    )
  }
}

///|
/// Side-effecting statements (443, captured operator names and states) and
/// SELECTs returning data (444: state 3 in scalar functions, 2 in
/// table-valued ones), in statement order.
fn Session::side_effects(
  self : Session,
  stmts : Array[@ast.Stmt],
  select_state : Int,
  out : Array[@types.SqlError],
) -> Unit {
  let walk = (list : Array[@ast.Stmt]) => {
    self.side_effects(list, select_state, out)
  }
  for s in stmts {
    match s.kind {
      Insert({ target, .. }) => self.dml_effect(target, "INSERT", out)
      Update({ target, .. }) => self.dml_effect(target, "UPDATE", out)
      Delete({ target, .. }) => self.dml_effect(target, "DELETE", out)
      Merge({ target, .. }) => self.dml_effect(target, "MERGE", out)
      Print(_) => out.push(side_effect("PRINT", 14))
      RaisError(_, ..) => out.push(side_effect("RAISERROR", 14))
      Throw(_) => out.push(side_effect("THROW", 14))
      ExecString(_) => out.push(side_effect("EXECUTE STRING", 14))
      BeginTran(..) => out.push(side_effect("BEGIN TRANSACTION", 15))
      Commit(..) => out.push(side_effect("COMMIT TRANSACTION", 15))
      Rollback(..) => out.push(side_effect("ROLLBACK TRANSACTION", 15))
      Save(..) => out.push(side_effect("SAVEPOINT", 15))
      SetOption(_, On) => out.push(side_effect("SET OPTION ON", 15))
      SetOption(_, Off) => out.push(side_effect("SET OPTION OFF", 15))
      CreateTable(_) => out.push(side_effect("CREATE TABLE", 15))
      Truncate(_) => out.push(side_effect("TRUNCATE TABLE", 15))
      TryCatch(body, handler) => {
        out.push(side_effect("BEGIN TRY", 14))
        walk(body)
        out.push(side_effect("END TRY", 14))
        out.push(side_effect("BEGIN CATCH", 14))
        walk(handler)
        out.push(side_effect("END CATCH", 14))
      }
      Select(q) if returns_data(q) =>
        out.push(
          @types.sql_error(
            444,
            "Select statements included within a function cannot return data to a client.",
            state=select_state,
          ),
        )
      Block(list) => walk(list)
      If(_, a, b) => {
        walk([a])
        match b {
          Some(x) => walk([x])
          None => ()
        }
      }
      While(_, b) => walk([b])
      _ => ()
    }
  }
}

///|
/// DML on a base table is a side effect (captured state 15); on a table
/// variable, or on a name that does not resolve (deferred name resolution,
/// captured), it is not.
fn Session::dml_effect(
  self : Session,
  target : @ast.TableRef,
  verb : String,
  out : Array[@types.SqlError],
) -> Unit {
  if target.kind is Table(name, ..) && self.find_table(name) is Some(_) {
    out.push(side_effect(verb, 15))
  }
}

///|
/// RETURN forms: a scalar function returns a value (1075 otherwise), a
/// multi-statement table-valued function does not (178).
fn check_returns(
  stmts : Array[@ast.Stmt],
  scalar : Bool,
) -> Unit raise @types.SqlError {
  for s in stmts {
    match s.kind {
      Return(None) if scalar =>
        raise @types.sql_error(
          1075,
          "RETURN statements in scalar valued functions must include an argument.",
          severity=15,
        )
      Return(Some(_)) if !scalar =>
        raise @types.sql_error(
          178,
          "A RETURN statement with a return value cannot be used in this context.",
          severity=15,
        )
      Block(list) => check_returns(list, scalar)
      If(_, a, b) => {
        check_returns([a], scalar)
        match b {
          Some(x) => check_returns([x], scalar)
          None => ()
        }
      }
      While(_, b) => check_returns([b], scalar)
      _ => ()
    }
  }
}

///|
/// 455 unless the body's last statement is RETURN (a trailing BEGIN...END
/// block counts by its own last statement; IF...ELSE does not, captured).
fn ends_with_return(stmts : Array[@ast.Stmt]) -> Bool {
  match stmts.last() {
    Some({ kind: Return(_), .. }) => true
    Some({ kind: Block(list), .. }) => ends_with_return(list)
    _ => false
  }
}

///|
/// `EXEC [@r =] schema.f args`: a scalar function run like a procedure
/// (captured: DONEINPROC 193 count 1, then DONEPROC 224 and no
/// RETURNSTATUS; @r receives the function's value). Returns false when
/// `name` is not a scalar function.
fn Session::exec_scalar_function(
  self : Session,
  name : @ast.ObjectName,
  e : @ast.Exec,
) -> Bool raise {
  guard self.server.procs.get(name.base().to_lower()) is None else {
    return false
  }
  guard self.find_function(name) is Some(info) && info.kind is Scalar(_) else {
    return false
  }
  let values : Array[@types.Value?] = info.params.map(_ => None)
  for i, a in e.args {
    let slot = match a.name {
      Some(n) => info.params.search_by(p => p.name.to_lower() == n.to_lower())
      None => Some(i)
    }
    guard slot is Some(k) && k < values.length() && !a.output else {
      raise @types.not_supported("this EXEC of a scalar function")
    }
    let (v, ty) = self.eval(a.value)
    values[k] = Some(@types.cast(v, ty, info.params[k].ty))
  }
  guard values.iter().all(v => v is Some(_)) else {
    raise @types.not_supported(
      "EXEC of a scalar function with omitted arguments",
    )
  }
  let result = self.call_scalar_udf(info.id, values.map(v => v.unwrap_or(Null)))
  self.out.push(
    InProcDone(
      cmd=193,
      count=if self.nocount { None } else { Some(1L) },
      error=false,
    ),
  )
  match e.return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(var_info) => {
          let ret = match info.kind {
            Scalar(t) => t
            _ => var_info.ty
          }
          self.frame().values[var_info.slot] = @types.cast(
            result,
            ret,
            var_info.ty,
          )
        }
        None => ()
      }
    None => ()
  }
  self.out.push(ProcDone(cmd=224, count=None, error=false))
  true
}
