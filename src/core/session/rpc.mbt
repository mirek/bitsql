///|
/// Parses a parameter declaration list such as "@a int, @b nvarchar(10) OUTPUT".
fn parse_param_decls(decls : String) -> Array[@ast.Param] raise {
  if decls.trim().is_empty() {
    return []
  }
  let stmt = @parse.parse_statement(
    "CREATE PROCEDURE __bitsql_params " + decls + " AS RETURN",
  )
  match stmt.kind {
    CreateProcedure(p) => p.params
    _ => []
  }
}

///|
/// One bound argument for a procedure or sp_executesql parameter.
priv struct Arg {
  value : @types.Value
  ty : @types.SqlType
  output : Bool
}

///|
/// Runs a body in a fresh frame with parameters, in RPC mode, and returns the
/// return status and the final values of OUTPUT parameters.
fn Session::run_with_params(
  self : Session,
  params : Array[@ast.Param],
  args : Map[String, Arg],
  positional : Array[Arg],
  body : () -> Bool raise,
) -> (Int, Array[(String, @types.SqlType, @types.Value, Bool)]) raise {
  let frame = Frame::new()
  let outs = []
  for i, p in params {
    let ty = @bind.resolve_type(p.type_, Declaration, @types.default_collation)
    let slot = frame.add_var(p.name, ty)
    let arg = match args.get(p.name.to_lower()) {
      Some(a) => Some(a)
      None => positional.get(i)
    }
    match arg {
      Some(a) => frame.values[slot] = @types.assign(a.value, a.ty, ty)
      None =>
        match p.default_ {
          Some(d) => {
            let b = @bind.bind_expr(@bind.Env::new(Map([])), d)
            let v = @exec.eval(self.ctx_with(frame), b)
            frame.values[slot] = @types.assign(v, b.ty, ty)
          }
          None => ()
        }
    }
    if p.output {
      outs.push((p.name, ty, slot, arg is Some({ output: true, .. })))
    }
  }
  self.frames.push(frame)
  self.rt.nest_level += 1
  let status = try {
    // Without RETURN, the status is the last statement's @@ERROR (0 after
    // a success; e.g. 8134 after a trailing divide by zero; msduck
    // error-continuation-rpc, error-metadata).
    ignore(body())
    self.rt.error
  } catch {
    Return(s) => s.unwrap_or(0)
    e => {
      self.frames.pop() |> ignore
      self.rt.nest_level -= 1
      raise e
    }
  }
  self.frames.pop() |> ignore
  self.rt.nest_level -= 1
  (status, outs.map(o => (o.0, o.1, frame.values[o.2], o.3)))
}

///|
fn Session::ctx_with(self : Session, frame : Frame) -> @exec.Ctx {
  {
    rt: self.rt,
    vars: frame.values,
    row: [],
    outer: [],
    source: (scope, id) => self.source(scope, id),
    ext: (name, args) => self.catalog_fn(name, args),
    user_fn: (id, args) => self.call_scalar_udf(id, args),
    user_table: (id, args) => self.call_table_udf(id, args),
    seek: (scope, id, key) => self.seek(scope, id, key),
  }
}

///|
fn Session::find_proc(self : Session, name : @ast.ObjectName) -> Proc raise {
  match self.server.procs.get(name.base().to_lower()) {
    Some(p) => p
    None =>
      raise @types.sql_error(
        2812,
        "Could not find stored procedure '\{name.parts.map(p => p.name).join(".")}'.",
      )
  }
}

///|
/// Runs an RPC request (sp_executesql, or a procedure by name).
pub fn Session::run_rpc(
  self : Session,
  call : @tds.RpcCall,
  now : Int64,
) -> Array[@reply.Item] {
  self.rt.now = now
  self.rt.work_done = 0L
  let snap = self.snapshot_request()
  if !self.parked {
    self.waits_done = 0 // a new request (not a re-run of a parked one)
  }
  self.waits_seen = 0
  self.in_waitfor = false
  self.parked = false
  self.waiting = None
  self.wait_ms = None
  self.out.clear()
  self.rpc = true
  self.frames.clear()
  self.frames.push(Frame::new())
  let positional = []
  let named : Map[String, Arg] = Map([])
  let wire : Array[(@tds.RpcParam, Arg)] = call.params.map(p => {
    let ty = param_type(p.type_info)
    (p, Arg::{ value: param_value(ty, p.value), ty, output: p.by_ref, })
  })
  let result = try {
    check_variant_params(call.params)
    match call.proc.canonical_name() {
      "sp_executesql" => {
        guard wire.get(0) is Some((_, { value: String(sql), .. })) else {
          raise @types.sql_error(
            214, "Procedure expects parameter '@statement' of type 'ntext/nchar/nvarchar'.",
          )
        }
        let decls = match wire.get(1) {
          Some((_, { value: String(d), .. })) => d
          _ => ""
        }
        let params = parse_param_decls(decls)
        for i in 2..<wire.length() {
          let (p, a) = wire[i]
          if p.name != "" {
            named[p.name.to_lower()] = a
          } else {
            positional.push(a)
          }
        }
        Some(
          self.run_with_params(params, named, positional, () => {
            self.run_text(sql)
          }),
        )
      }
      "sp_reset_connection" => Some((0, []))
      "sp_prepare" | "sp_prepexec" => {
        // @handle int OUTPUT, @params nvarchar, @stmt nvarchar[, values...]
        let decls = match wire.get(1) {
          Some((_, { value: String(d), .. })) => d
          _ => ""
        }
        guard wire.get(2) is Some((_, { value: String(sql), .. })) else {
          raise @types.sql_error(
            214, "Procedure expects parameter '@statement' of type 'ntext/nchar/nvarchar'.",
          )
        }
        let handle = self.next_handle
        self.next_handle += 1
        self.prepared[handle] = (decls, sql)
        let handle_name = match wire.get(0) {
          Some((p, _)) => p.name
          None => "@handle"
        }
        let result = if call.proc.canonical_name() == "sp_prepexec" {
          for i in 3..<wire.length() {
            let (p, a) = wire[i]
            if p.name != "" {
              named[p.name.to_lower()] = a
            } else {
              positional.push(a)
            }
          }
          self.text = sql
          let params = parse_param_decls(decls)
          self.run_with_params(params, named, positional, () => {
            self.run_text(sql)
          })
        } else {
          (0, [])
        }
        // handle first, as SQL Server sends it before RETURNSTATUS
        self.out.push(
          ReturnValue(
            ordinal=0,
            name=handle_name,
            type_info=IntN(4),
            value=Int(handle.to_int64()),
          ),
        )
        Some(result)
      }
      "sp_execute" => {
        let handle = match wire.get(0) {
          Some((_, a)) => a.value.as_int64().unwrap_or(0L).to_int()
          None => 0
        }
        guard self.prepared.get(handle) is Some((decls, sql)) else {
          raise @types.sql_error(
            8179,
            "Could not find prepared statement with handle \{handle}.",
            state=4,
          )
        }
        for i in 1..<wire.length() {
          let (p, a) = wire[i]
          if p.name != "" {
            named[p.name.to_lower()] = a
          } else {
            positional.push(a)
          }
        }
        self.text = sql
        let params = parse_param_decls(decls)
        Some(
          self.run_with_params(params, named, positional, () => {
            self.run_text(sql)
          }),
        )
      }
      "sp_unprepare" => {
        let handle = match wire.get(0) {
          Some((_, a)) => a.value.as_int64().unwrap_or(0L).to_int()
          None => 0
        }
        if self.prepared.contains(handle) {
          self.prepared.remove(handle)
        } else {
          raise @types.sql_error(
            8179,
            "Could not find prepared statement with handle \{handle}.",
            state=4,
          )
        }
        Some((0, []))
      }
      _ => {
        let name = match call.proc {
          Name(n) => n
          Id(_) => call.proc.canonical_name()
        }
        let obj = @parse.parse_statement("EXEC " + name)
        guard obj.kind is Exec({ target: ExecProc(on), .. }) else {
          raise @types.sql_error(
            2812,
            "Could not find stored procedure '\{name}'.",
          )
        }
        let proc = self.find_proc(on)
        for pair in wire {
          let (p, a) = pair
          if p.name != "" {
            named[p.name.to_lower()] = a
          } else {
            positional.push(a)
          }
        }
        Some(
          self.run_with_params(proc.def.params, named, positional, () => {
            self.exec_list(proc.def.body) catch {
              AbortBatch => return false
              e => raise e
            }
            true
          }),
        )
      }
    }
  } catch {
    @types.SqlError(..) as e => {
      self.message(e, 1)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
      None
    }
    Park => {
      self.parked = true
      None
    }
    _ => None
  }
  if self.parked {
    self.restore_request(snap)
    return []
  }
  self.fail_next_wait = None
  self.applock_waited = false
  self.waits_done = 0
  match result {
    Some((status, outs)) => {
      self.out.push(ReturnStatus(status))
      for i, o in outs {
        let (name, ty, value, requested) = o
        if requested {
          self.out.push(
            ReturnValue(
              ordinal=i,
              name~,
              type_info=type_info(ty, true),
              value=wire_value(value),
            ),
          )
        }
      }
    }
    None => ()
  }
  self.end_of_request()
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}

///|
/// Runs dynamic SQL text in a new scope (EXEC(@sql) / sp_executesql inside
/// a batch). Its statements complete with DONEINPROC; the EXEC itself with
/// DONEPROC (captured: msduck error-metadata). An error inside ends only the
/// dynamic batch.
fn Session::exec_dynamic(
  self : Session,
  sql : String,
  params : Array[@ast.Param],
  named : Map[String, Arg],
  positional : Array[Arg],
) -> (Int, Array[(String, @types.SqlType, @types.Value, Bool)]) raise {
  let saved_text = self.text
  self.text = sql
  let saved_try = self.try_depth
  self.try_depth = 0
  errdefer {
    self.text = saved_text
    self.try_depth = saved_try
  }
  let r = self.run_with_params(params, named, positional, () => {
    self.run_text(sql)
  })
  self.text = saved_text
  self.try_depth = saved_try
  r
}

///|
fn Session::exec_string(self : Session, parts : Array[@ast.Expr]) -> Unit raise {
  let sb = StringBuilder()
  for p in parts {
    let (v, ty) = self.eval(p)
    match @types.cast(v, ty, NVarChar(None, @types.default_collation)) {
      String(s) => sb.write_string(s)
      _ => ()
    }
  }
  let (status, _) = self.exec_dynamic(sb.to_string(), [], Map([]), [])
  ignore(status)
  // EXEC (string) has no RETURNSTATUS; nested, it ends like a nested EXEC
  if self.rt.nest_level > 0 {
    self.out.push(InProcDone(cmd=224, count=None, error=false))
  } else {
    self.out.push(ProcDone(cmd=224, count=None, error=false))
  }
}

///|
/// EXEC proc statement inside a batch.
fn Session::exec_proc_stmt(self : Session, e : @ast.Exec) -> Unit raise {
  let name = match e.target {
    ExecProc(name) => name
    // EXEC @var: the variable holds the procedure name
    ExecVar(v) => {
      let text = match self.frame().vars.get(v.to_lower()) {
        Some(info) =>
          match self.frame().values[info.slot] {
            String(s) => s
            _ => ""
          }
        None => ""
      }
      let missing = @types.sql_error(
        2812,
        "Could not find stored procedure '\{text}'.",
      )
      let parsed = @parse.parse_statement("EXEC " + text) catch {
        _ => raise missing
      }
      match parsed.kind {
        Exec({ target: ExecProc(n), .. }) => n
        _ => raise missing
      }
    }
  }
  if name.parts.length() >= 2 &&
    name.parts[name.parts.length() - 2].name.to_lower() == "emulator" &&
    self.exec_emulator_proc(name.base(), e.args) {
    return
  }
  if name.base().to_lower() == "sp_executesql" {
    let values = e.args.map(a => {
      let (v, ty) = self.eval(a.value)
      (a, Arg::{ value: v, ty, output: a.output, })
    })
    guard values.get(0) is Some((_, { value: String(sql), .. })) else {
      raise @types.sql_error(
        214, "Procedure expects parameter '@statement' of type 'ntext/nchar/nvarchar'.",
      )
    }
    let decls = match values.get(1) {
      Some((_, { value: String(d), .. })) => d
      _ => ""
    }
    let params = parse_param_decls(decls)
    let named : Map[String, Arg] = Map([])
    let positional = []
    for i in 2..<values.length() {
      let (a, arg) = values[i]
      match a.name {
        Some(n) => named[n.to_lower()] = arg
        None => positional.push(arg)
      }
    }
    let (status, outs) = self.exec_dynamic(sql, params, named, positional)
    self.write_back_outputs(e, outs)
    self.proc_done(status)
    return
  }
  if self.exec_system_proc(name, e.args, e.return_var) {
    return
  }
  if self.exec_scalar_function(name, e) {
    return
  }
  let proc = self.find_proc(name)
  if !self.check_proc_args(name.base(), proc.def.params, e.args) {
    return
  }
  let named : Map[String, Arg] = Map([])
  let positional = []
  for a in e.args {
    let (v, ty) = self.eval(a.value)
    let arg : Arg = { value: v, ty, output: a.output, }
    match a.name {
      Some(n) => named[n.to_lower()] = arg
      None => positional.push(arg)
    }
  }
  let saved_rpc = self.rpc
  let trancount_before = self.rt.trancount
  // SET options a procedure changes revert when it returns
  let saved_set = (
    self.nocount,
    self.xact_abort,
    self.rt.option_bits,
    self.isolation,
    self.rt.datefirst,
  )
  let restore_set = () => {
    self.nocount = saved_set.0
    self.xact_abort = saved_set.1
    self.rt.option_bits = saved_set.2
    self.isolation = saved_set.3
    self.rt.datefirst = saved_set.4
  }
  let (status, outs) = {
    errdefer restore_set()
    self.run_with_params(proc.def.params, named, positional, () => {
      self.exec_list(proc.def.body) catch {
        AbortBatch => return false
        e => raise e
      }
      true
    })
  }
  restore_set()
  self.rpc = saved_rpc
  self.write_back_outputs(e, outs)
  if self.rt.trancount != trancount_before {
    self.proc_done(status)
    raise @types.sql_error(
      266,
      "Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements. Previous count = \{trancount_before}, current count = \{self.rt.trancount}.",
      state=2,
    )
  }
  match e.return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.proc_done(status)
}

///|
/// Copies OUTPUT parameter values back into the caller's variables.
fn Session::write_back_outputs(
  self : Session,
  e : @ast.Exec,
  outs : Array[(String, @types.SqlType, @types.Value, Bool)],
) -> Unit raise {
  for a in e.args {
    guard a.output && a.value.kind is Var(vname) else { continue }
    let pname = match a.name {
      Some(n) => n.to_lower()
      None => ""
    }
    for o in outs {
      if o.0.to_lower() == pname {
        match self.frame().vars.get(vname.to_lower()) {
          Some(info) =>
            self.frame().values[info.slot] = @types.assign(o.2, o.1, info.ty)
          None => ()
        }
      }
    }
  }
}

///|
/// EXEC argument checks (captured: msduck gaps-procedures). Compile-time
/// errors (119, 179, 8144) end the batch; the others fail the EXEC with
/// ERROR + DONEPROC (error) and return false.
fn Session::check_proc_args(
  self : Session,
  proc : String,
  params : Array[@ast.Param],
  args : Array[@ast.ExecArg],
) -> Bool raise {
  let mut named_seen = false
  let mut positional = 0
  for i, a in args {
    match a.name {
      Some(_) => named_seen = true
      None => {
        if named_seen {
          raise @types.sql_error(
            119,
            "Must pass parameter number \{i + 1} and subsequent parameters as '@name = value'. After the form '@name = value' has been used, all subsequent parameters must be passed in the form '@name = value'.",
            severity=15,
          )
        }
        positional += 1
      }
    }
    if a.output &&
      a.value.kind
      is (IntLit(_)
      | DecimalLit(_)
      | FloatLit(_)
      | MoneyLit(_)
      | StrLit(_, ..)
      | BinaryLit(_)
      | Null) {
      raise @types.sql_error(
        179,
        "Cannot use the OUTPUT option when passing a constant to a stored procedure.",
        severity=15,
      )
    }
  }
  if positional > params.length() {
    raise @types.sql_error(
      8144,
      "Procedure or function \{proc} has too many arguments specified.",
      state=2,
    )
  }
  let fail = (e : @types.SqlError) => {
    self.message(e, 1)
    self.stmt_error = e.number()
    if self.rt.nest_level > 0 {
      self.out.push(InProcDone(cmd=224, count=None, error=true))
    } else {
      self.out.push(ProcDone(cmd=224, count=None, error=true))
    }
    false
  }
  let supplied = Array::make(params.length(), false)
  for i, a in args {
    let k = match a.name {
      None => i
      Some(n) =>
        match params.search_by(p => p.name.to_lower() == n.to_lower()) {
          Some(k) => k
          None =>
            return fail(
              @types.sql_error(
                8145,
                "\{n} is not a parameter for procedure \{proc}.",
              ),
            )
        }
    }
    if supplied[k] {
      return fail(
        @types.sql_error(
          8143,
          "Parameter '\{params[k].name}' was supplied multiple times.",
        ),
      )
    }
    supplied[k] = true
    if a.output && !params[k].output {
      return fail(
        @types.sql_error(
          8162,
          "The formal parameter \"\{params[k].name}\" was not declared as an OUTPUT parameter, but the actual parameter passed in requested output.",
          state=2,
        ),
      )
    }
  }
  for k, p in params {
    if !supplied[k] && p.default_ is None {
      return fail(
        @types.sql_error(
          201,
          "Procedure or function '\{proc}' expects parameter '\{p.name}', which was not supplied.",
          state=4,
        ),
      )
    }
  }
  true
}
