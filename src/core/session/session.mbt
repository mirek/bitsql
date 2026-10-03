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
  /// Last committed database state.
  mut db : @store.Db
  /// Row ids and object ids are never reused or rolled back.
  mut next_rowid : Int64
  mut next_object_id : Int
  /// Last identity value per table id (not rolled back, like SQL Server).
  idents : Map[Int, Int64]
  /// Database-wide rowversion counter (@@DBTS).
  mut dbts : Int64
}

///|
pub fn Server::new() -> Server {
  {
    procs: Map([]),
    db: @store.Db::empty(),
    next_rowid: 1L,
    next_object_id: 245575913,
    idents: Map([]),
    dbts: 2000L,
  }
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
  self.next_object_id = r + 16000057
  r
}

///|
/// One variable frame (batch, procedure or dynamic SQL scope).
priv struct Frame {
  vars : Map[String, @bind.VarInfo]
  values : Array[@types.Value]
  /// Table variables: lowercased name → id in the session's temp database.
  tables : Map[String, Int]
}

///|
fn Frame::new() -> Frame {
  { vars: Map([]), values: [], tables: Map([]), }
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
  /// Temp tables (#t) and table variables (scope 1).
  mut temp : @store.Db
  /// Explicit transaction: the committed state it started from and its
  /// private view including its own writes.
  mut tx : (@store.Db, @store.Db)?
  /// Text of the batch being executed (to slice definitions by span).
  mut text : String
  /// SET IDENTITY_INSERT target table id.
  mut identity_insert : Int?
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
    temp: @store.Db::empty(),
    tx: None,
    text: "",
    identity_insert: None,
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
    source: (scope, id) => self.db_of(scope).rows(id),
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
  if self.rpc && self.nocount && !result_set && !error {
    return
  }
  let count = if self.nocount { None } else { count }
  self.out.push(StatementDone(cmd~, count~, error~))
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
  self.out.clear()
  self.text = text
  self.rpc = false
  self.frames.clear()
  self.frames.push(Frame::new())
  self.run_text(text) |> ignore
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}

///|
/// Parses and executes batch text in the current frame. Returns false when an
/// uncaught error ended it.
fn Session::run_text(self : Session, text : String) -> Bool {
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
      self.out.push(StatementDone(cmd=253, count=None, error=true))
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
    _ => false
  } noraise {
    _ => true
  }
}
