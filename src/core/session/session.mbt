///|
/// A stored procedure definition (until the catalog lands in core/store).
pub(all) struct Proc {
  name : String
  def : @ast.CreateProcedure
  /// SET ANSI_NULLS at CREATE / ALTER PROCEDURE: the body runs with it.
  ansi_nulls : Bool
}

///|
/// State shared by every session of one engine (the "server").
pub struct Server {
  procs : Map[String, Proc] // key: lowercased schema-less name
  /// Committed state of every database (lowercased name → Db).
  dbs : Map[String, @store.Db]
  /// Display names as created.
  db_names : Map[String, String]
  /// Row ids and object ids are never reused or rolled back.
  mut next_rowid : Int64
  mut next_object_id : Int
  /// Last identity value per table id (not rolled back, like SQL Server).
  idents : Map[Int, Int64]
  /// Database-wide rowversion counter (@@DBTS).
  mut dbts : Int64
  /// emulator.snapshot / emulator.restore states.
  priv snapshots : Map[String, ServerSnapshot]
  /// Key-range lock manager shared by all sessions (session id = spid).
  locks : @sched.LockManager[LockKey]
  /// Sequence generators by "database:object id" (not transactional).
  priv seqs : Map[String, SeqState]
  /// First rowversion assigned by each session's open transaction
  /// (MIN_ACTIVE_ROWVERSION).
  active_rv : Map[Int, Int64]
  /// NEWSEQUENTIALID() counter.
  mut seq_guid : Int64
  /// Sessions by spid (sys.dm_exec_sessions / requests / connections).
  live : Map[Int, Session]
  /// SET DEADLOCK_PRIORITY by spid (absent: 0, NORMAL).
  priorities : Map[Int, Int]
  /// Sessions woken by lock releases (spid), to be re-run by the engine.
  woken : Array[Int]
  /// Parked sessions chosen as deadlock victims.
  victims : Array[Int]
  /// Parsed user-defined functions by object id (session/udf.mbt).
  priv udfs : Map[Int, UdfDef]
  /// ALTER DATABASE settings by lowercased database name (absent: the
  /// defaults of `DbOptions::default`).
  priv db_options : Map[String, DbOptions]
}

///|
priv struct ServerSnapshot {
  dbs : Map[String, @store.Db]
  db_names : Map[String, String]
  idents : Map[Int, Int64]
  dbts : Int64
  procs : Map[String, Proc]
  db_options : Map[String, DbOptions]
}

///|
pub fn Server::new() -> Server {
  let priorities : Map[Int, Int] = Map([])
  let dbs = Map([])
  let names = Map([])
  for n in ["master", "tempdb", "model", "msdb"] {
    dbs[n] = @store.Db::empty()
    names[n] = n
  }
  {
    procs: Map([]),
    dbs,
    db_names: names,
    next_rowid: 1L,
    // the first user object id of a fresh SQL Server 2025 database (every
    // capture printing object ids agrees: msduck-runs alter-named-default,
    // table-type-catalog, system-all-columns)
    next_object_id: 1221579390,
    idents: Map([]),
    dbts: 2000L,
    snapshots: Map([]),
    locks: new_lock_manager(priorities),
    seqs: Map([]),
    priorities,
    live: Map([]),
    seq_guid: 0L,
    active_rv: Map([]),
    woken: [],
    victims: [],
    udfs: Map([]),
    db_options: Map([]),
  }
}

///|
fn Server::wake_all(self : Server, pairs : Array[(Int, Int)]) -> Unit {
  for p in pairs {
    if !self.woken.contains(p.0) {
      self.woken.push(p.0)
    }
  }
}

///|
/// Sessions woken since the last call (engine re-runs their requests).
pub fn Server::take_woken(self : Server) -> Array[Int] {
  let w = self.woken.copy()
  self.woken.clear()
  w
}

///|
/// Parked sessions chosen as deadlock victims since the last call.
pub fn Server::take_victims(self : Server) -> Array[Int] {
  let v = self.victims.copy()
  self.victims.clear()
  v
}

///|
pub fn Server::has_database(self : Server, name : String) -> Bool {
  self.dbs.contains(name.to_lower())
}

///|
pub fn Server::create_database(self : Server, name : String) -> Unit {
  if !self.has_database(name) {
    self.dbs[name.to_lower()] = @store.Db::empty()
    self.db_names[name.to_lower()] = name
  }
}

///|
/// Canonical spelling of a database name (as created).
pub fn Server::database_name(self : Server, name : String) -> String {
  self.db_names.get(name.to_lower()).unwrap_or(name)
}

///|
fn Server::get_db(self : Server, name : String) -> @store.Db {
  match self.dbs.get(name.to_lower()) {
    Some(db) => db
    None => @store.Db::empty()
  }
}

///|
fn Server::set_db(self : Server, name : String, db : @store.Db) -> Unit {
  self.dbs[name.to_lower()] = db
}

///|
fn Server::rowid(self : Server) -> Int64 {
  let r = self.next_rowid
  self.next_rowid = r + 1L
  r
}

///|
fn Server::object_id(self : Server) -> Int {
  let r = self.next_object_id
  // stride modulo 2^31-1 (prime): positive, no repeats for 2^31 objects
  self.next_object_id = ((r.to_int64() + 16000057L) % 2147483647L).to_int()
  r
}

///|
/// One variable frame (batch, procedure or dynamic SQL scope).
priv struct Frame {
  vars : Map[String, @bind.VarInfo]
  values : Array[@types.Value]
  /// Table variables: lowercased name → id in the session's temp database.
  tables : Map[String, Int]
  /// LOCAL cursors of this scope.
  cursors : Map[String, CursorState]
  /// Cursor variables (`DECLARE @c CURSOR`, CURSOR parameters): None until
  /// a cursor is assigned (lowercased name).
  cursor_vars : Map[String, CursorState?]
  /// CURSOR parameters (lowercased): their cursors outlive the module (an
  /// OUTPUT argument takes them over).
  cursor_params : Set[String]
  /// Line of the last statement of this scope that set the current line
  /// (0 before the first): OPEN/FETCH of a missing cursor report it
  /// (captured: stmts/cursor-lines).
  mut line_mark : Int
  /// READONLY table-valued parameters (lowercased names); unless also in
  /// `owned` they share the caller's table variable.
  read_only_tvps : Set[String]
  /// Table-valued parameters whose table this frame created.
  owned : Set[String]
  /// Name of the stored procedure whose body runs in this frame
  /// (ERROR_PROCEDURE(), message procedure names); None for batches and
  /// dynamic SQL.
  proc_name : String?
  /// A procedure, function or trigger body: SET ANSI_NULLS inside it has
  /// no effect (the module's CREATE-time setting holds; probed:
  /// tail/settings-ansi-nulls).
  mut module_settings : Bool
  /// Highest severity (> 10) of the errors raised by this scope's own
  /// statements, caught or not: a procedure that ends without RETURN
  /// returns 10 - severity (captured: proc/return-status).
  mut worst : Int
  /// Declared variables (lowercased) → the offset of their DECLARE: SQL
  /// Server declares at compile time, so a DECLARE runs again in a loop
  /// without 134 and a variable declared in a branch not taken exists
  /// (declare_hoist.mbt).
  decl_sites : Map[String, Int]
}

///|
fn Frame::new(proc_name? : String? = None) -> Frame {
  {
    vars: Map([]),
    values: [],
    tables: Map([]),
    cursors: Map([]),
    cursor_vars: Map([]),
    cursor_params: Set([]),
    line_mark: 0,
    read_only_tvps: Set([]),
    owned: Set([]),
    proc_name,
    module_settings: false,
    worst: 0,
    decl_sites: Map([]),
  }
}

///|
fn Frame::add_var(self : Frame, name : String, ty : @types.SqlType) -> Int {
  let slot = self.values.length()
  self.values.push(Null)
  self.vars[name.to_lower()] = { slot, ty, }
  slot
}

///|
/// Control transfer out of a statement list.
priv suberror Flow {
  Break
  Continue
  Return(Int?)
  /// Uncaught error that ends the batch after it was reported. Inside a
  /// module no completion token is sent for the failed statement; the
  /// outermost level sends `abort_cmd` (batch) or DONEPROC (RPC).
  AbortBatch
  /// Uncaught error that ends only the current module (procedure, EXEC
  /// string, sp_executesql text): compile-time errors such as 208 or a
  /// syntax error in dynamic SQL. The module completes with DONEPROC /
  /// DONEINPROC 224 and the error bit, without a return status.
  AbortScope
  /// A DML statement compiled for sp_prepare stops here (`compile_only`).
  CompiledOnly
}

///|
pub struct Session {
  server : Server
  rt : @exec.Runtime
  mut nocount : Bool
  mut xact_abort : Bool
  priv frames : Array[Frame]
  priv out : Array[@reply.Item]
  /// Request mode: RPC statements complete with DONEINPROC and NOCOUNT
  /// suppresses their non-result completions.
  mut rpc : Bool
  /// Depth of enclosing TRY blocks in the current batch.
  mut try_depth : Int
  /// CurCmd of the statement being executed: 253 until it is bound.
  mut cur_cmd : Int
  /// The current statement is THROW (uncaught THROW ends the batch).
  mut throwing : Bool
  /// @@ERROR value a successful statement leaves (RAISERROR WITH SETERROR).
  mut stmt_error : Int
  /// Temp tables (#t, scope 1).
  mut temp : @store.Db
  /// Table variables (scope 3): not affected by transaction rollback.
  mut tvars : @store.Db
  /// Explicit transaction state.
  priv mut tx : Tx?
  /// Text of the batch being executed (to slice definitions by span).
  mut text : String
  /// SET IDENTITY_INSERT target table id.
  mut identity_insert : Int?
  /// Line of the statement being executed (INFO messages).
  mut stmt_line : Int
  /// GLOBAL cursors (session lifetime).
  priv cursors : Map[String, CursorState]
  /// The cursor opened last (@@CURSOR_ROWS reads 0 once it is closed).
  priv mut last_opened : CursorState?
  /// `Frame::line_mark` before the current statement.
  priv mut prev_line : Int
  /// The transaction is the implicit one of an autocommit statement whose
  /// triggers run (no ENVCHANGE when it ends).
  mut implicit_tx : Bool
  /// SET TRANSACTION ISOLATION LEVEL (upper-cased).
  mut isolation : String
  /// SET LOCK_TIMEOUT in milliseconds (-1: wait forever).
  mut lock_timeout : Int
  /// WAITFORs passed in the current request (counted while it runs) and
  /// completed before its last park; the re-run skips completed ones.
  mut waits_seen : Int
  mut waits_done : Int
  /// The request is parked in WAITFOR (its timer completes the wait).
  mut in_waitfor : Bool
  /// @@ERROR to record for the failing statement instead of the error's
  /// number (RAISERROR format errors leave 50000).
  mut error_override : Int?
  /// sp_set_session_context: key → (sql_variant value, read only).
  priv session_context : Map[String, (@types.Value, Bool)]
  /// Binder errors reported before the statement's error (Env.deferred).
  deferred : Array[@types.SqlError]
  /// SET CONTEXT_INFO (always 128 bytes once set).
  mut context_info : Bytes?
  /// LOGIN7 client library (client_interface_name) and login time.
  mut library : String
  mut login_time : Int64
  /// LOGIN7 login, host and application names.
  mut login : String
  mut host_name : String
  mut app_name : String
  /// Application locks held (sp_getapplock), by owner and resource.
  priv applocks : Map[String, AppLock]
  /// The parked request waited in sp_getapplock (its re-run returns 1).
  mut applock_waited : Bool
  /// Database-qualified temp table references (`tempdb..#t`) of the text
  /// being run whose table did not exist when it was compiled: (text
  /// offset, line, database as written). Their statement repeats INFO 2701
  /// when it is recompiled (session/temp_refs.mbt).
  priv mut temp_db_refs : Array[(Int, Int, String)]
  /// Table variable id → text offset of its DECLARE (a re-run DECLARE,
  /// in a loop, is a no-op).
  priv tvar_sites : Map[Int, Int]
  /// Data stamps for the executor's statement caches (`data_stamp`): the
  /// table data last seen per (scope, id) and its stamp.
  priv stamps : Map[(Int, Int), (@store.TableData, Int64)]
  priv mut stamp_seq : Int64
  /// Foreign key lookup indexes of recent table states (fk_actions.mbt).
  priv fk_cache : Array[KeyCache]
  /// Catalog views of tempdb are being computed (sysviews.mbt).
  priv mut view_tempdb : Bool
  /// Timeout of the current lock wait when it is not SET LOCK_TIMEOUT
  /// (sp_getapplock @LockTimeout).
  mut wait_ms : Int?
  /// Last NEXT VALUE FOR per sequence key: (row number, value).
  priv seq_row : Map[String, (Int64, @types.Value)]
  /// INSERT BULK target awaiting its BulkLoad message.
  priv mut bulk : BulkTarget?
  /// Running triggers, innermost last.
  priv triggers : Array[TriggerCtx]
  /// Lock request this session waits for (when its request is parked).
  mut waiting : Int?
  /// Re-run of a deadlock victim / timed-out request: the next wait fails
  /// with this error number (1205 or 1222) instead of parking.
  mut fail_next_wait : Int?
  /// True when the last request parked (no response yet).
  mut parked : Bool
  /// sp_prepare handles: (parameter declarations, statement text).
  prepared : Map[Int, (String, String)]
  mut next_handle : Int
  /// Messages SQL Server sends before the error that ends the statement
  /// (2714 before 1750, 5074 before 4922); dropped inside TRY.
  pending : Array[@types.SqlError]
  /// Messages sent after that error (3621 "The statement has been
  /// terminated.").
  trailing : Array[@types.SqlError]
  /// A CREATE/DROP SCHEMA ran: those send no DONE of their own; a batch
  /// with no other completion ends with DONE cmd 253 (captured).
  mut schema_ddl : Bool
  /// sp_prepare in T-SQL compiling a DML statement: the statement stops
  /// with `CompiledOnly` once bound (at its OUTPUT header).
  mut compile_only : Bool
  /// CurCmd a failed DDL statement completes with inside TRY (outside TRY
  /// it fails with 253 and ends the batch); 0 for other statements.
  mut ddl_cmd : Int
  /// The statement's error is a compile-time one TRY cannot catch
  /// (captured: 4902, 1779/1750).
  mut uncatchable : Bool
  /// SET options SESSIONPROPERTY reports that bitsql lets change without
  /// an emulator error (ARITHABORT): upper-cased name → ON.
  session_flags : Map[String, Bool]
  /// A TVP of the RPC request is being loaded (its errors are reported at
  /// line 0, followed by 3621).
  mut tvp_error : Bool
  /// CurCmd of the batch-level DONE that completes a batch aborted inside
  /// a module (the failed statement sends no DONEINPROC; captured:
  /// proc/abort-tokens).
  mut abort_cmd : Int?
  /// Line to report for the current statement's error instead of the
  /// statement's (0 for EXEC argument and transaction-count errors).
  mut error_line : Int?
  /// ERROR_PROCEDURE() for the current statement's error when it belongs
  /// to the called procedure (EXEC argument errors, 266) rather than to
  /// the frame that runs the statement.
  mut error_module : String?
  /// `try_depth` when the running module was entered: TRY blocks of
  /// calling scopes (they catch the module's compile errors).
  mut try_base : Int
  /// An error is leaving a trigger towards its firing statement.
  mut trigger_unwind : Bool
  /// A trigger ended the transaction: the firing statement's failure must
  /// not restore its snapshot (the trigger's later writes autocommitted).
  mut tx_ended_in_trigger : Bool
  /// SET DATEFORMAT / SET DATEFIRST ran earlier in the current request: a
  /// later SET LANGUAGE keeps them instead of applying the language's
  /// defaults (captured: settings/language).
  mut dateformat_set : Bool
  mut datefirst_set : Bool
  /// The current statement wrote to a READ_ONLY database (3906 when it
  /// ends; session/database_options.mbt).
  mut read_only_write : Bool
}

///|
pub fn Session::new(
  server : Server,
  spid~ : Int,
  database~ : String,
  seed~ : Int64,
  server_name? : String = "bitsql",
  build? : (Int, Int, Int) = (17, 0, 5005),
) -> Session {
  let session : Session = {
    server,
    rt: @exec.Runtime::new(
      database~,
      spid~,
      now=0L,
      seed~,
      server_name~,
      build~,
    ),
    nocount: false,
    xact_abort: false,
    frames: [],
    out: [],
    rpc: false,
    try_depth: 0,
    cur_cmd: 253,
    throwing: false,
    stmt_error: 0,
    temp: @store.Db::empty(),
    tvars: @store.Db::empty(),
    tx: None,
    text: "",
    identity_insert: None,
    stmt_line: 1,
    cursors: Map([]),
    last_opened: None,
    prev_line: 0,
    prepared: Map([]),
    triggers: [],
    seq_row: Map([]),
    deferred: [],
    library: "",
    login_time: 0L,
    session_context: Map([]),
    error_override: None,
    context_info: None,
    waits_seen: 0,
    waits_done: 0,
    in_waitfor: false,
    login: "sa",
    host_name: "",
    app_name: "",
    applocks: Map([]),
    applock_waited: false,
    temp_db_refs: [],
    tvar_sites: Map([]),
    stamps: Map([]),
    stamp_seq: 0L,
    fk_cache: [],
    view_tempdb: false,
    wait_ms: None,
    bulk: None,
    lock_timeout: -1,
    isolation: "READ COMMITTED",
    implicit_tx: false,
    waiting: None,
    fail_next_wait: None,
    parked: false,
    next_handle: 1,
    pending: [],
    trailing: [],
    schema_ddl: false,
    compile_only: false,
    ddl_cmd: 0,
    uncatchable: false,
    session_flags: Map([]),
    tvp_error: false,
    abort_cmd: None,
    error_line: None,
    error_module: None,
    try_base: 0,
    trigger_unwind: false,
    tx_ended_in_trigger: false,
    dateformat_set: false,
    datefirst_set: false,
    read_only_write: false,
  }
  server.live[spid] = session
  session
}

///|
fn Session::frame(self : Session) -> Frame {
  self.frames[self.frames.length() - 1]
}

///|
fn Session::env(self : Session) -> @bind.Env {
  @bind.Env::new(
    self.frame().vars,
    collation=self.db_collation(),
    catalog=self.catalog(),
    deferred=self.deferred,
    ansi_nulls=self.ansi_nulls(),
    options=self.bind_options(),
  )
}

///|
fn Session::ctx(self : Session) -> @exec.Ctx {
  {
    rt: self.rt,
    vars: self.frame().values,
    row: [],
    outer: [],
    source: (scope, id) => self.source(scope, id),
    ext: (name, args) => {
      match self.property_fn(name, args) {
        Some(v) => Some(v)
        None => self.catalog_fn(name, args)
      }
    },
    user_fn: (id, args) => self.call_scalar_udf(id, args),
    user_table: (id, args) => self.call_table_udf(id, args),
    seek: (scope, id, key) => self.seek(scope, id, key),
    stamp: (scope, id) => self.data_stamp(scope, id),
  }
}

///|
/// Statement completion, applying NOCOUNT and RPC visibility rules
/// (docs/reference/completions.md).
fn Session::done(
  self : Session,
  cmd : Int,
  count? : Int64? = None,
  result_set? : Bool = false,
  error? : Bool = false,
) -> Unit {
  // NOCOUNT ON drops ordinary completions inside modules (RPC requests and
  // procedures/triggers in batches; captured: triggers/after-update-columns)
  if (self.rpc || self.rt.nest_level > 0) &&
    self.nocount &&
    !result_set &&
    !error {
    return
  }
  // a pending "Null value is eliminated" warning precedes the statement's
  // DONE (captured: INSERT … SELECT MIN(v), UPDATE … SET v = (SELECT MAX(v)
  // …), SET/DECLARE @v = (SELECT MIN(v) …), and after the error and 3621
  // of a failing INSERT; msduck aggregate-warning-boundaries)
  self.emit_null_warning(self.stmt_line)
  let count = if self.nocount { None } else { count }
  if self.rt.nest_level > 0 {
    self.out.push(InProcDone(cmd~, count~, error~))
  } else {
    self.out.push(StatementDone(cmd~, count~, error~))
  }
}

///|
/// The CurCmd 224 completion of an EXEC (procedure, EXEC string,
/// sp_executesql): DONEPROC at the top level, DONEINPROC nested. NOCOUNT
/// drops a nested one without the error bit (captured: gaps-procedures
/// #081). `error` marks a module ended by an error (no return status).
fn Session::module_done(self : Session, error~ : Bool) -> Unit {
  if self.rt.nest_level > 0 {
    if self.nocount && !error {
      return
    }
    self.out.push(InProcDone(cmd=224, count=None, error~))
  } else if !self.rpc {
    // an RPC's own DONEPROC is rendered after its items (reply/response.mbt)
    self.out.push(ProcDone(cmd=224, count=None, error~))
  }
}

///|
/// End of an EXEC'd procedure: RETURNSTATUS + DONEPROC at the top level; a
/// nested call (inside a procedure, trigger or sp_executesql text) ends with
/// DONEINPROC 224 only (captured: proc/nested-exec-tokens).
fn Session::proc_done(self : Session, status : Int) -> Unit {
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=false)
}

///|
/// Name of the procedure running the current statement, for messages and
/// ERROR_PROCEDURE() ("" in batches and dynamic SQL).
fn Session::module_name(self : Session) -> String? {
  match self.error_module {
    Some(m) => Some(m)
    None => self.frames.last().bind(f => f.proc_name)
  }
}

///|
fn Session::message(
  self : Session,
  e : @types.SqlError,
  line : Int,
  procedure? : String? = None,
) -> Unit {
  let procedure = match procedure {
    Some(p) => p
    None => self.module_name().unwrap_or("")
  }
  self.out.push(
    Message({
      number: e.number(),
      state: e.state(),
      class: e.severity(),
      message: e.message(),
      procedure,
      line,
    }),
  )
}

///|
fn Session::info(
  self : Session,
  number : Int,
  state : Int,
  text : String,
  line : Int,
) -> Unit {
  self.out.push(
    Message({ number, state, class: 0, message: text, procedure: "", line, }),
  )
}

///|
/// Runs a SQL batch (SQLBatch message).
pub fn Session::run_batch(
  self : Session,
  text : String,
  now : Int64,
) -> Array[@reply.Item] {
  self.rt.now = now
  self.rt.work_done = 0L
  let snap = self.snapshot_request()
  self.dateformat_set = false
  self.datefirst_set = false
  if !self.parked {
    self.waits_done = 0 // a new request (not a re-run of a parked one)
  }
  self.waits_seen = 0
  self.in_waitfor = false
  self.parked = false
  self.waiting = None
  self.wait_ms = None
  self.out.clear()
  self.text = text
  self.rpc = false
  self.frames.clear()
  self.tvar_sites.clear()
  self.frames.push(Frame::new())
  self.schema_ddl = false
  self.abort_cmd = None
  let parked = try {
    self.run_text(text)
    false
  } catch {
    Park => true
    AbortBatch => {
      // a batch aborted inside a module completes with one DONE
      // (captured: proc/abort-tokens)
      match self.abort_cmd {
        Some(cmd) => self.out.push(StatementDone(cmd~, count=None, error=true))
        None => ()
      }
      false
    }
    _ => false
  }
  self.abort_cmd = None
  if parked {
    // a lock wait: discard this attempt; the engine re-runs it later
    self.restore_request(snap)
    self.parked = true
    return []
  }
  self.fail_next_wait = None
  self.applock_waited = false
  self.waits_done = 0
  self.end_of_request()
  if self.schema_ddl &&
    !self.out.iter().any(i => i is (StatementDone(..) | ProcDone(..))) {
    self.out.push(StatementDone(cmd=253, count=None, error=false))
  }
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}

///|
/// Parses and executes batch text in the current frame. Control flow and
/// aborts propagate to the caller (AbortBatch; AbortScope or Caught inside
/// a module). A syntax or batch compile error ends the text before it runs:
/// at the top of a batch with DONE 253; inside a module (EXEC string,
/// sp_executesql) it ends the module, or an enclosing TRY catches it
/// (captured: proc/dynamic-errors).
fn Session::run_text(self : Session, text : String) -> Unit raise {
  match self.quoted_identifier_scan(text) {
    Some(line) => {
      self.text_error(
        @types.not_supported(
          "double-quoted strings under SET QUOTED_IDENTIFIER OFF",
        ),
        line,
      )
      return
    }
    None => ()
  }
  let stmts = @parse.parse_batch(text) catch {
    e => {
      // errors found by the parser's error recovery come first (captured:
      // tail/tablevar-hints, 156 then 319)
      let all = @parse.batch_errors(text)
      if all.length() > 1 && self.try_depth == 0 {
        for extra in all[:all.length() - 1] {
          self.message(
            @types.sql_error(
              extra.number(),
              extra.message(),
              state=extra.state(),
              severity=extra.severity(),
            ),
            extra.line(),
          )
        }
        let e = all[all.length() - 1]
        let err = @types.sql_error(
          e.number(),
          e.message(),
          state=e.state(),
          severity=e.severity(),
        )
        self.text_error(err, e.line())
        return
      }
      let err = @types.sql_error(
        e.number(),
        e.message(),
        state=e.state(),
        severity=e.severity(),
      )
      self.text_error(err, e.line())
      return
    }
  }
  self.float_literal_messages(text)
  // Compile-time checks that SQL Server performs for the whole batch.
  // Table-valued parameters of the frame count as declared.
  let known = if self.frame().tables.is_empty() {
    self.frame().vars
  } else {
    let m = Map::from_array(self.frame().vars.iter().to_array())
    for k, _ in self.frame().tables {
      if !m.contains(k) {
        m[k] = { slot: -1, ty: Int, }
      }
    }
    m
  }
  match precheck_batch(stmts, known) {
    Some((e0, line)) => {
      // COUNT(NULL) fails the whole batch, but the statement's own binding
      // errors come first (captured: a missing table is 208, a missing
      // column 207; msduck count-null-compilation)
      let e = if e0.number() == 8117 &&
        e0.message().has_prefix("Operand data type NULL ") {
        self.count_null_error(stmts, e0)
      } else {
        e0
      }
      // 8748 inside sp_executesql ends the request without a return
      // status, like a batch-aborting error (captured: msduck string-split
      // #048)
      if e.number() == 8748 && self.rt.nest_level > 0 && self.try_depth == 0 {
        self.rt.error = e.number()
        self.message(e, line)
        raise AbortBatch
      }
      self.text_error(e, line)
    }
    None => ()
  }
  match self.precheck_hints(stmts) {
    Err(errors) => {
      for i in 0..<(errors.length() - 1) {
        self.message(errors[i].0, errors[i].1)
      }
      self.text_error(
        errors[errors.length() - 1].0,
        errors[errors.length() - 1].1,
      )
    }
    Ok(warnings) =>
      for w in warnings {
        self.info(
          4430,
          1,
          "Warning: Index hints supplied for view '\{w.0}' will be ignored.",
          w.1,
        )
      }
  }
  // dynamic SQL modifying a READONLY table-valued parameter: 10700 ends
  // it like a compile error, without a DONE (captured: tabletypes/
  // readonly-params, tvp-rpc)
  match readonly_target(stmts, self.frame().read_only_tvps) {
    Some(name) => self.text_error(readonly_error(name), 1)
    None => ()
  }
  let saved_refs = self.temp_db_refs
  self.temp_db_refs = self.compile_temp_refs(text)
  errdefer {
    self.temp_db_refs = saved_refs
  }
  self.hoist_declares(stmts)
  self.exec_list(stmts) catch {
    Return(_) if self.rt.nest_level == 0 => ()
    Break | Continue => ()
    e => raise e
  }
  self.temp_db_refs = saved_refs
}

///|
/// Parse-time float literal checks (captured: msduck
/// percentile-numeric-rounding-v2, probes): a literal beyond the double
/// range is 168 and nothing in the batch runs; a nonzero literal below the
/// smallest normal double is INFO 337 (class 0, its line) before anything
/// runs, also inside a branch that never executes.
fn Session::float_literal_messages(self : Session, text : String) -> Unit raise {
  let mut maybe = false
  for i in 1..<text.length() {
    let c = text.code_unit_at(i)
    if (c == 'e' || c == 'E') &&
      text.code_unit_at(i - 1) >= '0' &&
      text.code_unit_at(i - 1) <= '9' {
      maybe = true
      break
    }
  }
  if !maybe {
    return
  }
  let toks = @lex.lex(text) catch { _ => return }
  for t in toks {
    if !(t.kind is FloatNum) {
      continue
    }
    match @bind.float_literal_class(t.text) {
      Some((_, 2)) =>
        self.text_error(@bind.float_range_error(t.text), t.span.line)
      Some((_, 1)) =>
        self.message(
          @types.sql_error(
            337,
            "Warning: the floating point value '\{t.text}' is too small. It will be interpreted as 0.",
            severity=0,
          ),
          t.span.line,
        )
      _ => ()
    }
  }
}

///|
/// A batch-level compile error (see `run_text`).
fn Session::text_error(
  self : Session,
  e : @types.SqlError,
  line : Int,
) -> Unit raise {
  self.rt.error = e.number()
  if self.rt.nest_level == 0 {
    self.message(e, line)
    self.out.push(StatementDone(cmd=253, count=None, error=true))
    raise AbortBatch
  }
  if self.try_depth > 0 {
    raise Caught(e, line, None, max_nest_level + 1)
  }
  self.message(e, line)
  raise AbortScope
}

///|
/// A doomed transaction still open at the end of a request (batch or RPC) is
/// rolled back with error 3998 (msduck transaction-recovery; the exact
/// completion shape is unverified).
fn Session::end_of_request(self : Session) -> Unit {
  // LOCAL cursors and cursor variables of the batch end with it
  for f in self.frames {
    self.release_frame_cursors(f)
  }
  if self.rt.xact_state == -1 && self.rt.trancount > 0 {
    self.out.push(
      Message({
        number: 3998,
        state: 1,
        class: 16,
        message: "Uncommittable transaction is detected at the end of the batch. The transaction is rolled back.",
        procedure: "",
        line: 1,
      }),
    )
    self.abort_transaction()
    // captured: DONE 253 with the error bit (savepoint catch run #12)
    if !self.rpc {
      self.out.push(StatementDone(cmd=253, count=None, error=true))
    }
  }
}

///|
/// Records the LOGIN7 identity (SYSTEM_USER, HOST_NAME(), APP_NAME()).
pub fn Session::set_login(
  self : Session,
  login : String,
  host_name : String,
  app_name : String,
  library? : String = "",
  now? : Int64 = 0L,
) -> Unit {
  self.library = library
  self.login_time = now
  self.login = login
  self.host_name = host_name
  self.app_name = app_name
}

///|
fn Server::set_priority(self : Server, spid : Int, p : Int) -> Unit {
  if p == 0 {
    self.priorities.remove(spid)
  } else {
    self.priorities[spid] = p
  }
}

///|
/// Work budget per request (host `--max-request-work`).
pub fn Session::set_work_limit(self : Session, limit : Int64) -> Unit {
  self.rt.work_limit = limit
}

///|
/// `DEFAULT NEWSEQUENTIALID()`: each value sorts after the previous one in
/// uniqueidentifier order, whose most significant bytes are 10..15.
fn Server::next_sequential_guid(self : Server) -> @types.Value {
  self.seq_guid += 1L
  let c = self.seq_guid
  Guid(
    Bytes::makei(16, i => {
      if i >= 10 {
        ((c >> ((15 - i) * 8)) & 0xFFL).to_byte()
      } else {
        // fixed node part (deterministic, like the rest of the emulator)
        (0x5A + i).to_byte()
      }
    }),
  )
}

///|
fn is_newsequentialid(text : String) -> Bool {
  let mut s = text.to_lower()
  s = s.replace_all(old=" ", new="")
  while s.has_prefix("(") && s.has_suffix(")") && s != "()" {
    s = s.unsafe_substring(start=1, end=s.length() - 1)
  }
  s == "newsequentialid()" || s == "newsequentialid("
}

///|
/// Next rowversion value (@@DBTS + 1), remembered as the transaction's first
/// active one (MIN_ACTIVE_ROWVERSION).
fn Session::next_rowversion(self : Session) -> @types.Value {
  self.server.dbts += 1L
  if self.tx is Some(_) && !self.server.active_rv.contains(self.rt.spid) {
    self.server.active_rv[self.rt.spid] = self.server.dbts
  }
  Binary(rowversion_bytes(self.server.dbts))
}

///|
/// The error the first SELECT holding COUNT(NULL) reports when bound.
fn Session::count_null_error(
  self : Session,
  stmts : Array[@ast.Stmt],
  fallback : @types.SqlError,
) -> @types.SqlError {
  for s in stmts {
    match s.kind {
      Select(q) =>
        ignore(@bind.bind_query(self.env(), q)) catch {
          e => return e
        }
      _ => ()
    }
  }
  fallback
}

///|
/// SET ANSI_WARNINGS (default ON).
fn Session::ansi_warnings(self : Session) -> Bool {
  self.session_flags.get("ANSI_WARNINGS").unwrap_or(true)
}

///|
/// SET ANSI_NULLS (default ON). Inside a procedure, function, trigger or
/// view it is the module's setting from CREATE time (probed:
/// tail/settings-ansi-nulls).
fn Session::ansi_nulls(self : Session) -> Bool {
  self.session_flags.get("ANSI_NULLS").unwrap_or(true)
}

///|
/// Sets ANSI_NULLS for SESSIONPROPERTY, the binder and @@OPTIONS (bit 32).
fn Session::set_ansi_nulls(self : Session, on : Bool) -> Unit {
  self.session_flags["ANSI_NULLS"] = on
  self.rt.option_bits = if on {
    self.rt.option_bits & (32 ^ -1)
  } else {
    self.rt.option_bits | 32
  }
}
