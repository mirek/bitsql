///|
/// Parses a parameter declaration list such as "@a int, @b nvarchar(10) OUTPUT".
fn Server::parse_param_decls(
  self : Server,
  decls : String,
) -> Array[@ast.Param] raise {
  if decls.trim().is_empty() {
    return []
  }
  // parenthesized: a trailing comma is 102 near ')' (captured:
  // gaps-rpc-procedures #077)
  let stmt = self.parse_statement(
    "CREATE PROCEDURE __bitsql_params (" + decls + ") AS RETURN",
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
  /// A table-valued argument (session/tabletypes.mbt).
  table : TableArg?
}

///|
/// A table-valued argument of the wrong type (206): reported at line 0 and
/// completes the EXEC with DONEPROC, without RETURNSTATUS (captured:
/// tabletypes/readonly-params).
priv suberror ParamClash {
  ParamClash(@types.SqlError)
}

///|
/// Parameters bound in a new frame: their types and variable slots (-1 for
/// table-valued parameters, which live in the frame's tables).
priv struct Bound {
  frame : Frame
  types : Array[@types.SqlType]
  slots : Array[Int]
}

///|
/// How a module (procedure, EXEC string, sp_executesql text) ended.
priv enum ModuleEnd {
  /// Ran to its end, or RETURN (with a status for RETURN <expr>).
  Completed(Int?)
  /// An error ended only the module (AbortScope): no return status.
  ScopeAborted
}

///|
priv struct ModuleRun {
  end : ModuleEnd
  /// Highest severity of the module's own errors (Frame::worst).
  worst : Int
  /// Final values and types of the parameters, by parameter index.
  values : Array[@types.Value]
  types : Array[@types.SqlType]
  /// The module's frame (CURSOR OUTPUT parameters).
  frame : Frame
}

///|
priv suberror ModulePark {
  ModulePark(() -> ModuleRun raise)
}

///|
priv suberror RpcPark {
  RpcPark(() -> Unit raise)
}

///|
fn Session::continue_rpc_module(
  self : Session,
  body : () -> ModuleRun raise,
  finish : (ModuleRun) -> Unit raise,
) -> Unit raise {
  let run = body() catch {
    ModulePark(next) =>
      raise RpcPark(() => self.continue_rpc_module(next, finish))
    e => raise e
  }
  finish(run)
}

///|
/// The return status of a procedure or EXEC string: RETURN's value, else
/// 10 - severity of its worst own error (11 → -1 … 18 → -8), else 0
/// (captured: proc/return-status, gaps-procedures #044-#066). None when
/// an error ended the module.
fn ModuleRun::status(self : ModuleRun) -> Int? {
  match self.end {
    Completed(Some(s)) => Some(s)
    Completed(None) => Some(if self.worst > 10 { 10 - self.worst } else { 0 })
    ScopeAborted => None
  }
}

///|
/// A system procedure (sp_executesql, prepared statements) failing before
/// or around its batch: the error, its line and the return status sent
/// after it (None: no RETURNSTATUS).
priv suberror ProcFail {
  ProcFail(@types.SqlError, Int, Int?)
}

///|
/// 8114 for an argument that does not convert to its parameter's type
/// (captured: state 5 in batches and sp_executesql, 1 for procedure RPCs;
/// overflow too: "int to tinyint").
fn arg_conversion_error(
  from : @types.SqlType,
  to : @types.SqlType,
  state : Int,
) -> @types.SqlError {
  @types.sql_error(
    8114,
    "Error converting data type \{from.message_name()} to \{to.message_name()}.",
    state~,
  )
}

///|
/// A new frame holding the parameters, bound to `bound` (by parameter
/// index; None, also for DEFAULT: the declared default, else NULL). Raises
/// 8114 when an argument does not convert, ParamClash for a table-valued
/// parameter given something else.
fn Session::bind_params(
  self : Session,
  params : Array[@ast.Param],
  bound : Array[Arg?],
  owner~ : String?,
  conv_state~ : Int,
) -> Bound raise {
  let frame = Frame::new(proc_name=owner)
  let types : Array[@types.SqlType] = []
  let slots = []
  for i, p in params {
    let arg = match bound.get(i) {
      Some(a) => a
      None => None
    }
    if is_cursor_type(p.type_) {
      frame.cursor_vars[p.name.to_lower()] = None
      frame.cursor_params.add(p.name.to_lower())
      types.push(@types.SqlType::Int)
      slots.push(-1)
      continue
    }
    let ty = match self.decl_type(p.type_, self.db_collation()) {
      ScalarDecl(ty, _, _) => ty
      TableDecl(ut) => {
        self.bind_table_param(frame, p, ut, arg) catch {
          @types.SqlError(number=206, ..) as e => raise ParamClash(e)
          e => raise e
        }
        types.push(@types.SqlType::Int)
        slots.push(-1)
        continue
      }
    }
    types.push(ty)
    let slot = frame.add_var(p.name, ty)
    slots.push(slot)
    match arg {
      Some(a) =>
        frame.values[slot] = @types.assign(
          a.value,
          a.ty,
          ty,
          dates=self.rt.dates,
        ) catch {
          // captured (json4/procs): text that is not JSON keeps its 13609
          @types.SqlError(number=13609 | 13645 | 1007, ..) as e if ty is Json =>
            raise e
          _ => raise arg_conversion_error(a.ty, ty, conv_state)
        }
      _ =>
        match p.default_ {
          Some(d) => {
            let b = @bind.bind_expr(@bind.Env::new(Map([])), d)
            let v = @exec.eval(self.ctx_with(frame), b)
            frame.values[slot] = @types.assign(v, b.ty, ty, dates=self.rt.dates)
          }
          None => ()
        }
    }
  }
  { frame, types, slots, }
}

///|
/// Runs a module body in `frame` (from `bind_params`) at @@NESTLEVEL +
/// `levels` (sp_executesql text runs two levels down: the procedure and its
/// batch; captured: proc/nest-levels). SET options it changes revert when
/// it ends (captured: also for EXEC strings and sp_executesql). A TRY of the
/// caller catching an error inside unwinds through the module, which then
/// completes with DONEPROC / DONEINPROC 224 (captured: gaps-procedures #058,
/// #073).
fn Session::run_module(
  self : Session,
  bound : Bound,
  levels~ : Int,
  ansi_nulls? : Bool? = None,
  body : () -> Unit raise,
) -> ModuleRun raise {
  let frame = bound.frame
  let saved_temp_refs = self.temp_db_refs
  let saved = (
    self.nocount,
    self.xact_abort,
    self.rt.option_bits,
    self.isolation,
    self.rt.datefirst,
    self.try_base,
    self.rt.dates,
  )
  // SET IDENTITY_INSERT inside a procedure or dynamic SQL (also an
  // sp_executesql RPC) reverts when it ends, and SCOPE_IDENTITY() is per
  // scope (captured: msduck identity-insert-rpc)
  let saved_identity_insert = self.identity_insert
  let saved_scope_identity = self.rt.scope_identity
  // SET ANSI_WARNINGS / ARITHABORT revert too (captured: msduck
  // session-property-context, after sp_executesql N'SET … OFF')
  let saved_flags = Map::from_array(self.session_flags.iter().to_array())
  // local temp tables created by the module are dropped when it ends
  // (captured: msduck gaps-temp_tables #022/#023, an sp_executesql RPC)
  let temps_before : Set[Int] = Set([])
  for t in self.temp.tables() {
    temps_before.add(t.id)
  }
  self.frames.push(frame)
  self.rt.nest_level += levels
  self.try_base = self.try_depth
  // a procedure runs with its CREATE-time ANSI_NULLS (reverted below with
  // the other options)
  if ansi_nulls is Some(on) {
    frame.module_settings = true
    self.set_ansi_nulls(on)
  }
  let leave = () => {
    self.temp_db_refs = saved_temp_refs
    self.frames.pop() |> ignore
    // LOCAL cursors and cursor variables end with the module
    self.release_frame_cursors(frame)
    self.rt.nest_level -= levels
    self.nocount = saved.0
    self.xact_abort = saved.1
    self.rt.option_bits = saved.2
    self.isolation = saved.3
    self.rt.datefirst = saved.4
    self.try_base = saved.5
    self.rt.dates = saved.6
    self.identity_insert = saved_identity_insert
    self.rt.scope_identity = saved_scope_identity
    self.session_flags.clear()
    for k, v in saved_flags {
      self.session_flags[k] = v
    }
    // the calling EXEC statement's own state (its errors complete with 253)
    self.cur_cmd = 253
    self.ddl_cmd = 0
    self.throwing = false
    self.uncatchable = false
    self.error_line = None
    self.error_module = None
    for t in self.temp.tables() {
      if !temps_before.contains(t.id) && !t.name.has_prefix("##") {
        self.temp = self.temp.drop_object(t.id)
      }
    }
    // TVPs loaded for this call die with it
    for k in frame.owned {
      match frame.tables.get(k) {
        Some(id) => self.tvars = self.tvars.drop_object(id)
        None => ()
      }
    }
  }
  fn drive(execute : () -> Unit raise) -> ModuleRun raise {
    let end = try {
      execute()
      Completed(None)
    } catch {
      Return(s) => Completed(s)
      AbortScope => ScopeAborted
      Caught(_, _, _, _) as c => {
        leave()
        self.module_done(error=false)
        raise c
      }
      Park if self.batch_resume is Some(_) && self.rpc =>
        raise ModulePark(() => drive(() => self.continue_statements()))
      e => {
        leave()
        raise e
      }
    }
    leave()
    {
      end,
      worst: frame.worst,
      values: bound.slots.map(k => if k < 0 { Null } else { frame.values[k] }),
      types: bound.types,
      frame,
    }
  }
  drive(body)
}

///|
fn Session::ctx_with(self : Session, frame : Frame) -> @exec.Ctx {
  {
    rt: self.rt,
    vars: frame.values,
    row: [],
    outer: [],
    scan_row: (scope, id, row) => self.configuration_scan_row(scope, id, row),
    source: (scope, id) => self.source(scope, id),
    ext: (name, args) => self.catalog_fn(name, args),
    user_fn: (id, args) => self.call_scalar_udf(id, args),
    user_table: (id, args) => self.call_table_udf(id, args),
    seek: (scope, id, key) => self.seek(scope, id, key),
    seek_json: (scope, id, column, path) => {
      self.seek_json(scope, id, column, path)
    },
    vector_search: (scope, id, index_id, query, top, width, expansion) => {
      self.search_vector_index(
        scope, id, index_id, query, top, width, expansion,
      )
    },
    stamp: self.stamp_reader(),
  }
}

///|
/// 2812 for a missing procedure (captured: state 62).
fn missing_proc_error(name : String) -> @types.SqlError {
  @types.sql_error(2812, "Could not find stored procedure '\{name}'.", state=62)
}

///|
/// 266 "Transaction count after EXECUTE ..." (line 0; captured state 2).
fn tran_count_error(before : Int, after : Int) -> @types.SqlError {
  @types.sql_error(
    266,
    "Transaction count after EXECUTE indicates a mismatching number of BEGIN and COMMIT statements. Previous count = \{before}, current count = \{after}.",
    state=2,
  )
}

///|
/// Runs an RPC request (sp_executesql, or a procedure by name).
pub fn Session::run_rpc(
  self : Session,
  call : @tds.RpcCall,
  now : Int64,
) -> Array[@reply.Item] {
  let continuation = self.rpc_continuation
  self.rpc_continuation = None
  self.rt.now = now
  self.rt.begin_attempt(self.parked)
  self.rt.work_done = 0L
  let snap = self.snapshot_request()
  if continuation is None {
    self.dateformat_set = false
    self.datefirst_set = false
  }
  if !self.parked {
    self.waits_done = 0 // a new request (not a re-run of a parked one)
    self.configuration_reads.clear()
    self.embeddings.clear()
    self.embedding_pending = None
  }
  self.waits_seen = 0
  self.configuration_reads_seen = 0
  self.embeddings_seen = 0
  self.in_waitfor = false
  self.parked = false
  self.waiting = None
  self.wait_ms = None
  self.attn.reset()
  self.rpc = true
  if continuation is None {
    self.out.clear()
    self.frames.clear()
    self.frames.push(Frame::new())
    self.batch_resuming = false
  }
  self.abort_cmd = None
  self.error_line = None
  self.error_module = None
  let wire : Array[(@tds.RpcParam, Arg)] = call.params.map(p => {
    let ty = param_type(p.type_info)
    match tvp_arg(p) {
      Some(a) => (p, a)
      None =>
        (
          p,
          Arg::{
            value: param_value(ty, p.value),
            ty,
            output: p.by_ref,
            table: None,
          },
        )
    }
  })
  // Errors that end the request: ERROR + DONEPROC with the error bit, no
  // RETURNSTATUS (captured: gaps-rpc-procedures #045-#055). The final
  // DONEPROC is rendered after the items (reply/response.mbt) and carries
  // the error bit of a preceding error.
  let fail = (e : @types.SqlError) => {
    self.message(e, self.error_line.unwrap_or(1))
  }
  self.parked = try {
    if continuation is Some(next) {
      next()
    } else {
      check_variant_params(call.params)
      match call.proc.canonical_name() {
        "sp_executesql" => self.rpc_executesql(wire)
        "sp_reset_connection" => self.out.push(ReturnStatus(0))
        "sp_prepare" | "sp_prepexec" as which => self.rpc_prepare(which, wire)
        "sp_execute" => self.rpc_execute(wire)
        "sp_unprepare" => {
          let handle = match wire.get(0) {
            Some((_, a)) => a.value.as_int64().unwrap_or(0L).to_int()
            None => 0
          }
          if self.prepared.contains(handle) {
            self.prepared.remove(handle)
            self.out.push(ReturnStatus(0))
          } else {
            // captured: state 8 here, 4 from sp_execute
            raise ProcFail(
              @types.sql_error(
                8179,
                "Could not find prepared statement with handle \{handle}.",
                state=8,
              ),
              1,
              Some(8179),
            )
          }
        }
        _ => self.rpc_proc(call, wire)
      }
    }
    false
  } catch {
    RpcPark(next) => {
      self.rpc_continuation = Some(next)
      true
    }
    ProcFail(e, line, status) => {
      self.rpc_fail(e, line, status, wire)
      false
    }
    @types.SqlError(..) as e if self.tvp_error => {
      // a TVP's rows violate its table type (captured: 2627 at line 0,
      // then 3621)
      self.tvp_error = false
      self.message(e, 0)
      self.info(3621, 0, "The statement has been terminated.", 1)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
      false
    }
    ParamClash(e) => {
      self.message(e, 1)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
      false
    }
    @types.SqlError(..) as e => {
      fail(e)
      false
    }
    AbortBatch | AbortScope => false
    Park => true
    _ => false
  }
  self.abort_cmd = None
  if self.parked && !self.attn.hit {
    if self.rpc_continuation is None {
      self.restore_request(snap)
    }
    return []
  }
  self.parked = false
  self.batch_resume = None
  self.batch_resuming = false
  self.rpc_continuation = None
  self.attn.cancelling = false
  self.fail_next_wait = None
  self.applock_waited = false
  self.waits_done = 0
  self.configuration_reads.clear()
  self.rt.finish_attempt()
  self.embeddings.clear()
  self.embedding_pending = None
  if self.attn.hit {
    self.finish_attention()
  } else {
    self.end_of_request()
  }
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}

///|
/// A failing system procedure RPC: ERROR, RETURNSTATUS (when it has one),
/// the OUTPUT parameters with their input values, DONEPROC with the error
/// bit (captured: gaps-rpc-procedures #073-#080, #091, #106, #113).
fn Session::rpc_fail(
  self : Session,
  e : @types.SqlError,
  line : Int,
  status : Int?,
  wire : Array[(@tds.RpcParam, Arg)],
) -> Unit {
  self.rt.error = e.number()
  self.message(e, line)
  if status is Some(s) {
    self.out.push(ReturnStatus(s))
    self.echo_outputs(wire, 0)
  }
}

///|
/// RETURNVALUEs carrying the input values of OUTPUT parameters from wire
/// position `from` on.
fn Session::echo_outputs(
  self : Session,
  wire : Array[(@tds.RpcParam, Arg)],
  from : Int,
) -> Unit {
  for i, pair in wire {
    let (p, _) = pair
    if i >= from && p.by_ref {
      self.out.push(
        ReturnValue(
          ordinal=i,
          name=p.name,
          type_info=p.type_info,
          value=p.value,
        ),
      )
    }
  }
}

///|
/// RETURNVALUEs of OUTPUT parameters after a module ran: each in the type
/// the client declared (captured: gaps-rpc-procedures #030-#041: bigint,
/// nvarchar(n) truncation). A value that does not fit is 8114 state 2
/// (line 0) and the request fails without RETURNSTATUS (#038, #079).
/// `index` maps a wire position to its parameter index.
fn Session::output_values(
  self : Session,
  wire : Array[(@tds.RpcParam, Arg)],
  index : Array[Int?],
  run : ModuleRun,
) -> Array[@reply.Item] raise {
  let items = []
  for i, pair in wire {
    let (p, _) = pair
    guard p.by_ref && index.get(i) is Some(Some(k)) else { continue }
    let from = run.types[k]
    let to = param_type(p.type_info)
    let v = @types.assign(run.values[k], from, to, dates=self.rt.dates) catch {
      _ => {
        self.error_line = Some(0)
        raise arg_conversion_error(from, to, 2)
      }
    }
    items.push(
      @reply.Item::ReturnValue(
        ordinal=i,
        name=p.name,
        type_info=p.type_info,
        value=wire_value(v),
      ),
    )
  }
  items
}

///|
/// Procedure RPC by name.
fn Session::rpc_proc(
  self : Session,
  call : @tds.RpcCall,
  wire : Array[(@tds.RpcParam, Arg)],
) -> Unit raise {
  let name = match call.proc {
    Name(n) => n
    Id(_) => call.proc.canonical_name()
  }
  let obj = @parse.parse_statement("EXEC " + name) catch {
    _ => raise missing_proc_error(name)
  }
  guard obj.kind is Exec({ target: ExecProc(on), .. }) else {
    raise missing_proc_error(name)
  }
  // system procedures of the sp_help family (sysprocs_help.mbt)
  match
    self.rpc_help_proc(
      on.base().to_lower(),
      wire.map(pair => (pair.0.name, pair.1.value)),
    ) {
    Some(status) => {
      self.out.push(ReturnStatus(status))
      return
    }
    None => ()
  }
  let on = self.deref_synonym(on)
  guard self.server.procs.get(on.base().to_lower()) is Some(proc) else {
    // system procedures take the request's parameters as variables of the
    // request frame (captured: gaps-rpc-procedures #066-#071)
    let span : @ast.Span = { start: 0, end: 0, line: 1, col: 1, }
    let args = wire.mapi((i, pair) => {
      let (p, a) = pair
      let vname = "@__rpc_param\{i}"
      let slot = self.frame().add_var(vname, a.ty)
      self.frame().values[slot] = a.value
      @ast.ExecArg::{
        name: if p.name == "" {
          None
        } else {
          Some(p.name)
        },
        value: { kind: Var(vname), span, },
        output: p.by_ref,
        span,
      }
    })
    if self.exec_system_proc(on, args, None) {
      return
    }
    raise missing_proc_error(name)
  }
  // arguments: named by name, unnamed by their position
  let params = proc.def.params
  let bound : Array[Arg?] = Array::make(params.length(), None)
  let index : Array[Int?] = Array::make(wire.length(), None)
  self.error_line = Some(0)
  for i, pair in wire {
    let (p, a) = pair
    let k = if p.name == "" {
      if i >= params.length() {
        raise @types.sql_error(
          8144,
          "Procedure or function \{proc.name} has too many arguments specified.",
          state=2,
        )
      }
      i
    } else {
      match params.search_by(x => x.name.to_lower() == p.name.to_lower()) {
        Some(k) => k
        None =>
          raise @types.sql_error(
            8145,
            "\{p.name} is not a parameter for procedure \{proc.name}.",
          )
      }
    }
    if bound[k] is Some(_) {
      raise @types.sql_error(
        8143,
        "Parameter '\{params[k].name}' was supplied multiple times.",
      )
    }
    if a.output && !params[k].output {
      raise @types.sql_error(
        8162,
        "The formal parameter \"\{params[k].name}\" was not declared as an OUTPUT parameter, but the actual parameter passed in requested output.",
        state=2,
      )
    }
    bound[k] = Some(a)
    index[i] = Some(k)
  }
  for k, p in params {
    if bound[k] is None && p.default_ is None {
      raise @types.sql_error(
        201,
        "Procedure or function '\{proc.name}' expects parameter '\{p.name}', which was not supplied.",
        state=4,
      )
    }
  }
  let b = self.bind_params(params, bound, owner=Some(proc.name), conv_state=1)
  self.error_line = None
  let before = self.rt.trancount
  self.continue_rpc_module(
    () => {
      self.run_module(b, levels=1, ansi_nulls=Some(proc.ansi_nulls), () => {
        self.hoist_declares(proc.def.body)
        self.exec_list(proc.def.body)
      })
    },
    run => {
      guard run.status() is Some(status) else { return }
      let outs = self.output_values(wire, index, run)
      if !self.xml_aborted() {
        self.out.push(ReturnStatus(status))
      }
      for x in outs {
        self.out.push(x)
      }
      // captured: RETURNSTATUS, then 266, then DONEPROC with the error bit
      // (gaps-rpc-procedures #058)
      if self.rt.trancount != before {
        self.message(tran_count_error(before, self.rt.trancount), 0)
      }
    },
  )
}

///|
/// sp_executesql arguments: the statement, the declarations and the
/// parameter values, validated like SQL Server (captured: gaps-procedures
/// #107-#117, gaps-rpc-procedures #073-#080). `args` are the arguments
/// after the first two with their names; `line` is the line errors report
/// when they have one. Returns the parameters and the bound arguments,
/// and the wire index of each argument's parameter.
fn Session::executesql_args(
  self : Session,
  stmt : (@types.Value, @types.SqlType)?,
  decls : String,
  args : Array[(String?, Arg)],
  rpc~ : Bool,
  line~ : Int,
) -> (String, Array[@ast.Param], Array[Arg?], Array[Int?]) raise {
  let sql = match stmt {
    Some((String(s), ty)) if ty.is_unicode() => s
    _ =>
      raise ProcFail(
        @types.sql_error(
          214,
          "Procedure expects parameter '@statement' of type 'ntext/nchar/nvarchar'.",
          state=2,
        ),
        line,
        Some(214),
      )
  }
  let params = self.server.parse_param_decls(decls) catch {
    e => {
      let err = match e {
        @ast.SyntaxError(..) as se =>
          @types.sql_error(
            se.number(),
            se.message(),
            state=se.state(),
            severity=15,
          )
        @types.SqlError(..) as se => se
        _ => @types.sql_error(102, "Incorrect syntax.", severity=15)
      }
      raise ProcFail(err, line, Some(err.number()))
    }
  }
  // 352 / 346 end the dynamic batch like a compile error (captured:
  // ERROR, RETURNSTATUS = the error number; tabletypes)
  ignore(
    self.check_param_decls(params) catch {
      e => raise ProcFail(e, 1, Some(e.number()))
    },
  )
  // SQL Server compiles the text behind its declarations, so CREATE
  // PROCEDURE is no longer first: 156 near the keyword (captured:
  // gaps-procedures #122)
  if !decls.trim().is_empty() {
    match proc_keyword_at_start(sql) {
      Some(word) => {
        let e = @types.sql_error(
          156,
          "Incorrect syntax near the keyword '\{word}'.",
          severity=15,
        )
        raise ProcFail(e, 1, Some(156))
      }
      None => ()
    }
  }
  if args.length() > params.length() {
    let e = @types.sql_error(
      8144,
      "Procedure or function  has too many arguments specified.",
      state=2,
    )
    if rpc {
      raise ProcFail(e, 0, Some(8144))
    }
    // a batch compile error (captured: gaps-procedures #112)
    self.error_line = Some(0)
    raise e
  }
  let bound : Array[Arg?] = Array::make(params.length(), None)
  let index : Array[Int?] = Array::make(args.length(), None)
  let mut unmatched = false
  for i, pair in args {
    let (name, a) = pair
    let k = match name {
      None => Some(i)
      Some(n) => params.search_by(x => x.name.to_lower() == n.to_lower())
    }
    guard k is Some(k) else {
      unmatched = true
      continue
    }
    if a.output && !params[k].output {
      raise ProcFail(
        @types.sql_error(
          8162,
          "The formal parameter \"\{params[k].name}\" was not declared as an OUTPUT parameter, but the actual parameter passed in requested output.",
          state=2,
        ),
        0,
        Some(8162),
      )
    }
    bound[k] = Some(a)
    index[i] = Some(k)
  }
  for k, p in params {
    if bound[k] is None && p.default_ is None {
      // status 1, or the error number when an argument named no parameter
      // (captured: gaps-procedures #110 / #111)
      raise ProcFail(
        @types.sql_error(
          8178,
          "The parameterized query '(\{decls})\{sql}' expects the parameter '\{p.name}', which was not supplied.",
        ),
        0,
        Some(if unmatched { 8178 } else { 1 }),
      )
    }
  }
  (sql, params, bound, index)
}

///|
/// Binds sp_executesql parameters; a conversion failure is a ProcFail
/// with the error number as status.
fn Session::executesql_frame(
  self : Session,
  params : Array[@ast.Param],
  bound : Array[Arg?],
) -> Bound raise {
  self.bind_params(params, bound, owner=None, conv_state=5) catch {
    @types.SqlError(..) as e => raise ProcFail(e, 0, Some(e.number()))
    e => raise e
  }
}

///|
/// Runs dynamic SQL text as a module (EXEC string, sp_executesql and the
/// prepared-statement procedures).
fn Session::run_dynamic(
  self : Session,
  sql : String,
  bound : Bound,
  levels~ : Int,
) -> ModuleRun raise {
  let saved_text = self.text
  // a USE inside dynamic SQL lasts until the end of that scope (captured:
  // corpus orm/object-ids, orm/dynamic-use)
  let saved_db = self.rt.database
  self.text = sql
  self.outer_dbs.push(saved_db)
  let cleanup = () => {
    self.text = saved_text
    self.rt.database = saved_db
    ignore(self.outer_dbs.pop())
  }
  fn finish(execute : () -> ModuleRun raise) -> ModuleRun raise {
    let run = execute() catch {
      ModulePark(next) => raise ModulePark(() => finish(next))
      e => {
        cleanup()
        raise e
      }
    }
    cleanup()
    run
  }
  finish(() => self.run_module(bound, levels~, () => self.run_text(sql)))
}

///|
/// sp_executesql over RPC: RETURNSTATUS is the last @@ERROR (also after an
/// error that ended the text: then the OUTPUT parameters keep their input
/// values; captured: gaps-rpc-procedures #087-#093).
fn Session::rpc_executesql(
  self : Session,
  wire : Array[(@tds.RpcParam, Arg)],
) -> Unit raise {
  let stmt = wire.get(0).map(x => (x.1.value, x.1.ty))
  let decls = match wire.get(1) {
    Some((_, { value: String(d), .. })) => d
    _ => ""
  }
  let args = []
  for i in 2..<wire.length() {
    let (p, a) = wire[i]
    args.push((if p.name == "" { None } else { Some(p.name) }, a))
  }
  let (sql, params, bound, arg_index) = self.executesql_args(
    stmt,
    decls,
    args,
    rpc=true,
    line=1,
  )
  let b = self.executesql_frame(params, bound)
  let before = self.rt.trancount
  let index : Array[Int?] = Array::makei(wire.length(), i => {
    if i >= 2 {
      arg_index[i - 2]
    } else {
      None
    }
  })
  self.continue_rpc_module(() => self.run_dynamic(sql, b, levels=2), run => {
    self.rpc_module_end(run, wire, index, before)
  })
}

///|
/// The end of an sp_executesql / prepared-statement RPC.
fn Session::rpc_module_end(
  self : Session,
  run : ModuleRun,
  wire : Array[(@tds.RpcParam, Arg)],
  index : Array[Int?],
  before : Int,
  prefix? : Array[@reply.Item] = [],
) -> Unit raise {
  let status = self.rt.error
  if run.end is ScopeAborted {
    self.out.push(ReturnStatus(status))
    for x in prefix {
      self.out.push(x)
    }
    self.echo_outputs(wire, 2)
    return
  }
  let outs = self.output_values(wire, index, run)
  // captured: 266 before RETURNSTATUS here (gaps-procedures #088,
  // proc/abort-tokens)
  let mismatch = self.rt.trancount != before
  if mismatch {
    self.message(tran_count_error(before, self.rt.trancount), 0)
    self.rt.error = 266
  }
  if !self.xml_aborted() {
    self.out.push(ReturnStatus(if mismatch { 266 } else { status }))
  }
  for x in prefix {
    self.out.push(x)
  }
  for x in outs {
    self.out.push(x)
  }
}

///|
/// sp_prepare / sp_prepexec: @handle int OUTPUT, @params, @stmt[, values].
/// RETURNSTATUS precedes the handle (captured: gaps-rpc-procedures #099,
/// #103); a batch-aborting error discards the handle (#104, #106).
fn Session::rpc_prepare(
  self : Session,
  which : String,
  wire : Array[(@tds.RpcParam, Arg)],
) -> Unit raise {
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
  let handle_item = @reply.Item::ReturnValue(
    ordinal=0,
    name=handle_name,
    type_info=IntN(4),
    value=Int(handle.to_int64()),
  )
  if which == "sp_prepare" {
    // captured: one DONEINPROC (193, count 0) for a non-query statement
    self.out.push(InProcDone(cmd=193, count=Some(0L), error=false))
    self.out.push(ReturnStatus(0))
    self.out.push(handle_item)
    return
  }
  let args = []
  for i in 3..<wire.length() {
    let (p, a) = wire[i]
    args.push((if p.name == "" { None } else { Some(p.name) }, a))
  }
  let discard = () => {
    self.prepared.remove(handle)
    self.next_handle = handle
  }
  let (_, params, bound, arg_index) = self.executesql_args(
    Some((String(sql), NVarChar(None, @types.default_collation))),
    decls,
    args,
    rpc=true,
    line=1,
  )
  let b = self.executesql_frame(params, bound)
  let before = self.rt.trancount
  fn execute(body : () -> ModuleRun raise) -> ModuleRun raise {
    body() catch {
      ModulePark(next) => raise ModulePark(() => execute(next))
      e => {
        discard()
        raise e
      }
    }
  }
  let index : Array[Int?] = Array::makei(wire.length(), i => {
    if i >= 3 {
      arg_index[i - 3]
    } else {
      None
    }
  })
  self.continue_rpc_module(
    () => execute(() => self.run_dynamic(sql, b, levels=2)),
    run => self.rpc_module_end(run, wire, index, before, prefix=[handle_item]),
  )
}

///|
/// sp_execute: @handle, values.
fn Session::rpc_execute(
  self : Session,
  wire : Array[(@tds.RpcParam, Arg)],
) -> Unit raise {
  let handle = match wire.get(0) {
    Some((_, a)) => a.value.as_int64().unwrap_or(0L).to_int()
    None => 0
  }
  guard self.prepared.get(handle) is Some((decls, sql)) else {
    raise ProcFail(
      @types.sql_error(
        8179,
        "Could not find prepared statement with handle \{handle}.",
        state=4,
      ),
      1,
      Some(8179),
    )
  }
  let args = []
  for i in 1..<wire.length() {
    let (p, a) = wire[i]
    args.push((if p.name == "" { None } else { Some(p.name) }, a))
  }
  let (_, params, bound, arg_index) = self.executesql_args(
    Some((String(sql), NVarChar(None, @types.default_collation))),
    decls,
    args,
    rpc=true,
    line=1,
  )
  let b = self.executesql_frame(params, bound)
  let before = self.rt.trancount
  let index : Array[Int?] = Array::makei(wire.length(), i => {
    if i >= 1 {
      arg_index[i - 1]
    } else {
      None
    }
  })
  self.continue_rpc_module(() => self.run_dynamic(sql, b, levels=2), run => {
    self.rpc_module_end(run, wire, index, before)
  })
}

///|
/// An error of an EXEC itself (missing procedure, argument errors) in a
/// batch: ERROR, then the EXEC's 224 completion with the error bit, and
/// the batch continues; an enclosing TRY catches it after a plain 224
/// completion (captured: gaps-procedures #042, proc/exec-errors).
/// `module` is ERROR_PROCEDURE() (the called procedure for argument
/// errors).
fn Session::callee_error(
  self : Session,
  e : @types.SqlError,
  line : Int,
  owner : String?,
) -> Unit raise {
  self.rt.error = e.number()
  if self.try_depth > 0 && e.severity() > 10 && e.severity() < 20 {
    self.module_done(error=false)
    raise Caught(e, line, owner, max_nest_level + 1)
  }
  self.message(e, line, procedure=Some(owner.unwrap_or("")))
  self.module_done(error=true)
}

///|
/// Value of an EXEC argument: bare words are nvarchar strings (captured:
/// proc/exec-args, `EXEC p abc` passes N'abc'); a table variable passes the
/// table; DEFAULT is None (the parameter's default applies).
fn Session::exec_arg_value(self : Session, a : @ast.ExecArg) -> Arg? raise {
  match self.table_var_arg(a.value) {
    Some(t) => return Some(t)
    None => ()
  }
  match a.value.kind {
    Default => None
    // a cursor variable: OUTPUT CURSOR parameters hand their cursor back
    // (write_back_outputs)
    Var(n) if self.frame().cursor_vars.contains(n.to_lower()) =>
      Some({ value: Null, ty: Int, output: a.output, table: None, })
    Column([id]) =>
      Some({
        value: String(id.name),
        ty: NVarChar(
          Some(if id.name.length() < 1 { 1 } else { id.name.length() }),
          @types.default_collation,
        ),
        output: a.output,
        table: None,
      })
    _ => {
      let (v, ty) = self.eval(a.value)
      Some({ value: v, ty, output: a.output, table: None, })
    }
  }
}

///|
/// The end of an EXEC of an EXEC string or procedure in a batch: the
/// return status (unless an error ended the module) and the 224
/// completion, or 266 when the module changed @@TRANCOUNT: RETURNSTATUS,
/// ERROR (line 0), DONEPROC with the error bit (captured: gaps-procedures
/// #086, #087, proc/abort-tokens). 266 belongs to the called procedure
/// (ERROR_PROCEDURE()) and a TRY catches it.
fn Session::exec_module_end(
  self : Session,
  status : Int?,
  before : Int,
  owner : String?,
) -> Unit raise {
  guard status is Some(st) else {
    self.module_done(error=true)
    return
  }
  if self.rt.trancount == before {
    self.proc_done(st)
    return
  }
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(st))
  }
  self.callee_error(tran_count_error(before, self.rt.trancount), 0, owner)
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
  if self.rt.nest_level >= max_nest_level {
    raise nesting_error()
  }
  self.rt.error = 0
  let before = self.rt.trancount
  // EXEC (string) returns a status like a procedure (captured:
  // gaps-procedures #095, #101)
  let run = self.run_dynamic(
    sb.to_string(),
    { frame: Frame::new(), types: [], slots: [], },
    levels=1,
  )
  self.exec_module_end(run.status(), before, None)
}

///|
/// EXEC proc statement inside a batch.
fn Session::exec_proc_stmt(
  self : Session,
  e : @ast.Exec,
  line : Int,
) -> Unit raise {
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
      let parsed = @parse.parse_statement("EXEC " + text) catch {
        _ => {
          self.callee_error(missing_proc_error(text), line, None)
          return
        }
      }
      match parsed {
        { kind: Exec({ target: ExecProc(n), .. }), .. } => n
        _ => {
          self.callee_error(missing_proc_error(text), line, None)
          return
        }
      }
    }
  }
  if name.parts.length() >= 2 &&
    name.parts[name.parts.length() - 2].name.to_lower() == "emulator" &&
    self.exec_emulator_proc(name.base(), e.args) {
    self.rt.error = self.stmt_error
    return
  }
  if name.base().to_lower() == "sp_executesql" {
    self.exec_executesql(e, line)
    return
  }
  let sys_schema = name.parts.length() == 1 ||
    name.parts[name.parts.length() - 2].name.to_lower() == "sys"
  match name.base().to_lower() {
    "sp_prepare" | "sp_execute" | "sp_unprepare" as which if sys_schema => {
      self.exec_prepare_proc(which, e, line)
      return
    }
    _ => ()
  }
  // system procedures emulate their T-SQL bodies' completions, not their
  // @@ERROR: a successful EXEC leaves 0 (captured: gaps-applock #005)
  if self.exec_system_proc(name, e.args, e.return_var) {
    self.rt.error = self.stmt_error
    return
  }
  if self.exec_scalar_function(name, e) {
    self.rt.error = self.stmt_error
    return
  }
  let name = self.deref_synonym(name)
  guard self.server.procs.get(name.base().to_lower()) is Some(proc) else {
    self.callee_error(
      missing_proc_error(name.parts.map(p => p.name).join(".")),
      line,
      None,
    )
    return
  }
  if !self.check_proc_args(proc.name, proc.def.params, e.args) {
    return
  }
  if self.rt.nest_level >= max_nest_level {
    // the call fails on entering level 33: under TRY it unwinds that level
    // too (captured: gaps-procedures #084, #089)
    if self.try_depth > 0 {
      self.rt.error = 217
      self.module_done(error=false)
      raise Caught(nesting_error(), line, Some(proc.name), max_nest_level + 1)
    }
    raise nesting_error()
  }
  let params = proc.def.params
  let bound : Array[Arg?] = Array::make(params.length(), None)
  for i, a in e.args {
    let k = match a.name {
      None => Some(i)
      Some(n) => params.search_by(p => p.name.to_lower() == n.to_lower())
    }
    if k is Some(k) {
      bound[k] = self.exec_arg_value(a)
    }
  }
  let b = self.bind_params(params, bound, owner=Some(proc.name), conv_state=5) catch {
    // captured (json4/procs): a json argument that does not parse is a
    // batch-level error (ERROR, DONE 253; no DONEPROC)
    @types.SqlError(number=13609 | 13645 | 1007, ..) as err => {
      self.error_line = Some(0)
      raise err
    }
    @types.SqlError(..) as err => {
      self.callee_error(err, 0, Some(proc.name))
      return
    }
    ParamClash(err) => {
      self.callee_error(err, 0, Some(proc.name))
      return
    }
    err => raise err
  }
  self.rt.error = 0
  let saved_rpc = self.rpc
  let before = self.rt.trancount
  let run = self.run_module(b, levels=1, ansi_nulls=Some(proc.ansi_nulls), () => {
    self.hoist_declares(proc.def.body)
    self.exec_list(proc.def.body)
  })
  self.rpc = saved_rpc
  let status = run.status()
  if status is Some(st) {
    self.write_back_outputs(e, params, run)
    self.set_return_var(e.return_var, st)
  }
  self.exec_module_end(status, before, Some(proc.name))
}

///|
/// EXEC [@r =] sp_executesql in a batch: the status is the last @@ERROR
/// (captured: gaps-procedures #115-#117).
fn Session::exec_executesql(
  self : Session,
  e : @ast.Exec,
  line : Int,
) -> Unit raise {
  let values = e.args.map(a => {
    let arg = match self.exec_arg_value(a) {
      Some(x) => x
      None => { value: Null, ty: Int, output: a.output, table: None, }
    }
    (a, arg)
  })
  let stmt = values.get(0).map(x => (x.1.value, x.1.ty))
  let decls = match values.get(1) {
    Some((_, { value: String(d), .. })) => d
    _ => ""
  }
  let args = []
  for i in 2..<values.length() {
    let (a, arg) = values[i]
    args.push((a.name, arg))
  }
  if self.rt.nest_level + 2 > max_nest_level {
    raise nesting_error()
  }
  let (sql, params, b) = try {
    let (sql, params, bound, _) = self.executesql_args(
      stmt,
      decls,
      args,
      rpc=false,
      line~,
    )
    let b = self.executesql_frame(params, bound)
    (sql, params, b)
  } catch {
    ProcFail(err, eline, status) => {
      // ERROR, RETURNSTATUS, DONEPROC with the error bit (captured:
      // gaps-procedures #107, #110, #113)
      self.rt.error = err.number()
      if self.try_depth > 0 {
        self.module_done(error=false)
        raise Caught(err, eline, None, max_nest_level + 1)
      }
      self.message(err, eline, procedure=Some(""))
      if self.rt.nest_level == 0 && status is Some(s) {
        self.out.push(ReturnStatus(s))
      }
      self.module_done(error=true)
      return
    }
    err => raise err
  }
  self.rt.error = 0
  let before = self.rt.trancount
  let run = self.run_dynamic(sql, b, levels=2)
  let scope_aborted = run.end is ScopeAborted
  if !scope_aborted {
    self.write_back_outputs(e, params, run, skip=2)
  }
  let mismatch = self.rt.trancount != before
  if mismatch {
    self.rt.error = 266
  }
  let status = self.rt.error
  self.set_return_var(e.return_var, status)
  // captured: ERROR 266 before RETURNSTATUS here (gaps-procedures #088)
  if mismatch {
    let err = tran_count_error(before, self.rt.trancount)
    if self.try_depth > 0 {
      self.module_done(error=false)
      raise Caught(err, 0, None, max_nest_level + 1)
    }
    self.message(err, 0, procedure=Some(""))
  }
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=mismatch || scope_aborted)
}

///|
fn Session::set_return_var(self : Session, rv : String?, status : Int) -> Unit {
  guard rv is Some(rv) else { return }
  match self.frame().vars.get(rv.to_lower()) {
    Some(info) =>
      self.frame().values[info.slot] = @types.cast(Int(status), Int, info.ty) catch {
        _ => self.frame().values[info.slot]
      }
    None => ()
  }
}

///|
/// Copies OUTPUT parameter values back into the caller's variables
/// (positional arguments map by position; `skip` leading arguments are not
/// parameters, as for sp_executesql). A value that does not fit the
/// variable is 8114 state 2 (line 0), which ends the batch (captured:
/// gaps-procedures #093).
fn Session::write_back_outputs(
  self : Session,
  e : @ast.Exec,
  params : Array[@ast.Param],
  run : ModuleRun,
  skip? : Int = 0,
) -> Unit raise {
  for i, a in e.args {
    guard i >= skip && a.output && a.value.kind is Var(vname) else { continue }
    let k = match a.name {
      None => Some(i - skip)
      Some(n) => params.search_by(p => p.name.to_lower() == n.to_lower())
    }
    guard k is Some(k) && k < run.values.length() && params[k].output else {
      continue
    }
    // CURSOR VARYING OUTPUT: the caller's variable takes the cursor over
    // (captured: msduck-runs/cursor #075)
    if is_cursor_type(params[k].type_) {
      match self.frame().cursor_vars.get(vname.to_lower()) {
        Some(old) => {
          let c = run.frame.cursor_vars
            .get(params[k].name.to_lower())
            .unwrap_or(None)
          match c {
            Some(x) => x.refs += 1
            None => ()
          }
          self.release_ref(old)
          self.frame().cursor_vars[vname.to_lower()] = c
        }
        None => ()
      }
      continue
    }
    match self.frame().vars.get(vname.to_lower()) {
      Some(info) => {
        let from = run.types[k]
        self.frame().values[info.slot] = @types.assign(
          run.values[k],
          from,
          info.ty,
          dates=self.rt.dates,
        ) catch {
          _ => {
            self.error_line = Some(0)
            raise arg_conversion_error(from, info.ty, 2)
          }
        }
      }
      None => ()
    }
  }
}

///|
/// EXEC argument checks (captured: msduck gaps-procedures). Compile-time
/// errors (119, 179, 8144) end the batch; the others fail the EXEC (ERROR
/// at line 0 + DONEPROC with the error bit) and return false.
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
    self.error_line = Some(0)
    raise @types.sql_error(
      8144,
      "Procedure or function \{proc} has too many arguments specified.",
      state=2,
    )
  }
  let fail = (e : @types.SqlError) => {
    self.callee_error(e, 0, Some(proc))
    false
  }
  let supplied = Array::make(params.length(), false)
  // a missing parameter (201) is reported before an unknown name (8145),
  // a repeated one (8143) or a bad OUTPUT (8162) (probed: tail/
  // views-refreshview, `EXEC p @b = 1, @x = 1` is 201)
  let mut first : @types.SqlError? = None
  let note = (e : @types.SqlError) => if first is None { first = Some(e) }
  for i, a in args {
    let k = match a.name {
      None => i
      Some(n) =>
        match params.search_by(p => p.name.to_lower() == n.to_lower()) {
          Some(k) => k
          None => {
            note(
              @types.sql_error(
                8145,
                "\{n} is not a parameter for procedure \{proc}.",
              ),
            )
            continue
          }
        }
    }
    if supplied[k] {
      note(
        @types.sql_error(
          8143,
          "Parameter '\{params[k].name}' was supplied multiple times.",
        ),
      )
      continue
    }
    supplied[k] = true
    if a.output && !params[k].output {
      note(
        @types.sql_error(
          8162,
          "The formal parameter \"\{params[k].name}\" was not declared as an OUTPUT parameter, but the actual parameter passed in requested output.",
          state=2,
        ),
      )
    }
  }
  for k, p in params {
    // DEFAULT for a parameter without a default is 201 (captured:
    // proc/exec-args)
    let mut defaulted = false
    for i, a in args {
      if a.value.kind is Default {
        match a.name {
          None => if i == k { defaulted = true }
          Some(n) => if n.to_lower() == p.name.to_lower() { defaulted = true }
        }
      }
    }
    // an omitted READONLY table-valued parameter is an empty table
    if (!supplied[k] || defaulted) && p.default_ is None && !p.read_only {
      return fail(
        @types.sql_error(
          201,
          "Procedure or function '\{proc}' expects parameter '\{p.name}', which was not supplied.",
          state=4,
        ),
      )
    }
  }
  match first {
    Some(e) => fail(e)
    None => true
  }
}

///|
/// The PROC / PROCEDURE keyword (as written) when `sql` starts with
/// CREATE [OR ALTER] PROCEDURE or ALTER PROCEDURE.
fn proc_keyword_at_start(sql : String) -> String? {
  // the first four words separated by space, LF, TAB or CR (scanned, not
  // split: the text can be long and this runs for every sp_executesql)
  let words : Array[String] = []
  let n = sql.length()
  let mut i = 0
  while i < n && words.length() < 4 {
    let c = sql.code_unit_at(i)
    if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
      i += 1
      continue
    }
    let start = i
    while i < n {
      let d = sql.code_unit_at(i)
      if d == ' ' || d == '\n' || d == '\t' || d == '\r' {
        break
      }
      i += 1
    }
    words.push(sql.unsafe_substring(start~, end=i))
  }
  let upper = words.map(w => w.to_upper())
  let at = match upper {
    ["CREATE", "OR", "ALTER", ..] => 3
    ["CREATE", ..] | ["ALTER", ..] => 1
    _ => return None
  }
  match upper.get(at) {
    Some("PROC" | "PROCEDURE") => Some(words[at])
    _ => None
  }
}

///|
/// A request ended by an XML parse error has no RETURNSTATUS (captured:
/// xml/rpc#001: COLMETADATA, ERROR 9400, DONEPROC).
fn Session::xml_aborted(self : Session) -> Bool {
  match self.out.last() {
    Some(Message(m)) => m.number >= 9400 && m.number < 9500
    _ => false
  }
}
