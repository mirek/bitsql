///|
/// A stored procedure definition (until the catalog lands in core/store).
pub(all) struct Proc {
  name : String
  def : @ast.CreateProcedure
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
  /// Sessions woken by lock releases (spid), to be re-run by the engine.
  woken : Array[Int]
  /// Parked sessions chosen as deadlock victims.
  victims : Array[Int]
  /// Parsed user-defined functions by object id (session/udf.mbt).
  priv udfs : Map[Int, UdfDef]
}

///|
priv struct ServerSnapshot {
  dbs : Map[String, @store.Db]
  db_names : Map[String, String]
  idents : Map[Int, Int64]
  dbts : Int64
  procs : Map[String, Proc]
}

///|
pub fn Server::new() -> Server {
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
    next_object_id: 245575913,
    idents: Map([]),
    dbts: 2000L,
    snapshots: Map([]),
    locks: new_lock_manager(),
    seqs: Map([]),
    woken: [],
    victims: [],
    udfs: Map([]),
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
}

///|
fn Frame::new() -> Frame {
  { vars: Map([]), values: [], tables: Map([]), cursors: Map([]), }
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
  /// Uncaught error that ends the batch (or procedure) after it was reported.
  AbortBatch
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
  /// GLOBAL cursors (session lifetime).
  priv cursors : Map[String, CursorState]
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
  /// SET CONTEXT_INFO (always 128 bytes once set).
  mut context_info : Bytes?
  /// LOGIN7 login, host and application names.
  mut login : String
  mut host_name : String
  mut app_name : String
  /// Application locks held (sp_getapplock), by owner and resource.
  priv applocks : Map[String, AppLock]
  /// The parked request waited in sp_getapplock (its re-run returns 1).
  mut applock_waited : Bool
  /// Timeout of the current lock wait when it is not SET LOCK_TIMEOUT
  /// (sp_getapplock @LockTimeout).
  mut wait_ms : Int?
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
  /// CurCmd a failed DDL statement completes with inside TRY (outside TRY
  /// it fails with 253 and ends the batch); 0 for other statements.
  mut ddl_cmd : Int
  /// The statement's error is a compile-time one TRY cannot catch
  /// (captured: 4902, 1779/1750).
  mut uncatchable : Bool
}

///|
pub fn Session::new(
  server : Server,
  spid~ : Int,
  database~ : String,
  seed~ : Int64,
) -> Session {
  {
    server,
    rt: @exec.Runtime::new(database~, spid~, now=0L, seed~),
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
    cursors: Map([]),
    prepared: Map([]),
    triggers: [],
    context_info: None,
    waits_seen: 0,
    waits_done: 0,
    in_waitfor: false,
    login: "sa",
    host_name: "",
    app_name: "",
    applocks: Map([]),
    applock_waited: false,
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
    ddl_cmd: 0,
    uncatchable: false,
  }
}

///|
fn Session::frame(self : Session) -> Frame {
  self.frames[self.frames.length() - 1]
}

///|
fn Session::env(self : Session) -> @bind.Env {
  @bind.Env::new(self.frame().vars, catalog=self.catalog())
}

///|
fn Session::ctx(self : Session) -> @exec.Ctx {
  {
    rt: self.rt,
    vars: self.frame().values,
    row: [],
    outer: [],
    source: (scope, id) => self.source(scope, id),
    ext: (name, args) => self.catalog_fn(name, args),
    user_fn: (id, args) => self.call_scalar_udf(id, args),
    user_table: (id, args) => self.call_table_udf(id, args),
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
  let count = if self.nocount { None } else { count }
  if self.rt.nest_level > 0 {
    self.out.push(InProcDone(cmd~, count~, error~))
  } else {
    self.out.push(StatementDone(cmd~, count~, error~))
  }
}

///|
/// End of an EXEC'd procedure: RETURNSTATUS + DONEPROC at the top level; a
/// nested call (inside a procedure, trigger or sp_executesql text) ends with
/// DONEINPROC 224 only (captured: proc/nested-exec-tokens).
fn Session::proc_done(self : Session, status : Int) -> Unit {
  if self.rt.nest_level > 0 {
    self.out.push(InProcDone(cmd=224, count=None, error=false))
  } else {
    self.out.push(ReturnStatus(status))
    self.out.push(ProcDone(cmd=224, count=None, error=false))
  }
}

///|
fn Session::message(self : Session, e : @types.SqlError, line : Int) -> Unit {
  self.out.push(
    Message({
      number: e.number(),
      state: e.state(),
      class: e.severity(),
      message: e.message(),
      procedure: "",
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
  self.text = text
  self.rpc = false
  self.frames.clear()
  self.frames.push(Frame::new())
  self.schema_ddl = false
  try self.run_text(text) |> ignore catch {
    _ => {
      // a lock wait: discard this attempt; the engine re-runs it later
      self.restore_request(snap)
      self.parked = true
      return []
    }
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
/// Parses and executes batch text in the current frame. Returns false when an
/// uncaught error ended it.
fn Session::run_text(self : Session, text : String) -> Bool raise Park {
  let stmts = @parse.parse_batch(text) catch {
    e => {
      self.out.push(
        Message({
          number: e.number(),
          state: 1,
          class: 15,
          message: e.message(),
          procedure: "",
          line: e.line(),
        }),
      )
      if !self.rpc || self.rt.nest_level > 1 {
        self.out.push(StatementDone(cmd=253, count=None, error=true))
      }
      self.rt.error = e.number()
      return false
    }
  }
  // Compile-time checks that SQL Server performs for the whole batch.
  match precheck_batch(stmts, self.frame().vars) {
    Some((e, line)) => {
      self.message(e, line)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
      self.rt.error = e.number()
      return false
    }
    None => ()
  }
  try self.exec_list(stmts) catch {
    AbortBatch => false
    Return(_) => true
    Break | Continue => true
    Park => raise Park
    _ => false
  } noraise {
    _ => true
  }
}

///|
/// A doomed transaction still open at the end of a request (batch or RPC) is
/// rolled back with error 3998 (msduck transaction-recovery; the exact
/// completion shape is unverified).
fn Session::end_of_request(self : Session) -> Unit {
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
    if !self.rpc {
      self.out.push(StatementDone(cmd=0, count=None, error=true))
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
) -> Unit {
  self.login = login
  self.host_name = host_name
  self.app_name = app_name
}
