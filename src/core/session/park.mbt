///|
/// Session state at the start of a request, restored when the request
/// parks (decisions.md: request restart).
priv struct RequestSnapshot {
  dbs : Map[String, @store.Db]
  db_names : Map[String, String]
  temp : @store.Db
  tvars : @store.Db
  tx : Tx?
  trancount : Int
  xact_state : Int
  error : Int
  rowcount : Int64
  identity : @types.Value
  scope_identity : @types.Value
  database : String
  nocount : Bool
  xact_abort : Bool
  identity_insert : Int?
  dbts : Int64
}

///|
fn[K : Hash + Eq, V] copy_map(m : Map[K, V]) -> Map[K, V] {
  let out = Map([])
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn Session::snapshot_request(self : Session) -> RequestSnapshot {
  {
    dbs: copy_map(self.server.dbs),
    db_names: copy_map(self.server.db_names),
    temp: self.temp,
    tvars: self.tvars,
    tx: match self.tx {
      Some(tx) =>
        Some({
          database: tx.database,
          base: tx.base,
          view: tx.view,
          temp_at_begin: tx.temp_at_begin,
          savepoints: copy_map(tx.savepoints),
        })
      None => None
    },
    trancount: self.rt.trancount,
    xact_state: self.rt.xact_state,
    error: self.rt.error,
    rowcount: self.rt.rowcount,
    identity: self.rt.identity,
    scope_identity: self.rt.scope_identity,
    database: self.rt.database,
    nocount: self.nocount,
    xact_abort: self.xact_abort,
    identity_insert: self.identity_insert,
    dbts: self.server.dbts,
  }
}

///|
fn Session::restore_request(self : Session, s : RequestSnapshot) -> Unit {
  self.server.dbs.clear()
  for k, v in s.dbs {
    self.server.dbs[k] = v
  }
  self.server.db_names.clear()
  for k, v in s.db_names {
    self.server.db_names[k] = v
  }
  self.temp = s.temp
  self.tvars = s.tvars
  self.tx = s.tx
  self.rt.trancount = s.trancount
  self.rt.xact_state = s.xact_state
  self.rt.error = s.error
  self.rt.rowcount = s.rowcount
  self.rt.identity = s.identity
  self.rt.scope_identity = s.scope_identity
  self.rt.database = s.database
  self.nocount = s.nocount
  self.xact_abort = s.xact_abort
  self.identity_insert = s.identity_insert
  self.server.dbts = s.dbts
  self.out.clear()
  self.frames.clear()
  self.try_depth = 0
  self.rt.nest_level = 0
  // statement-duration locks of the abandoned attempt
  self.server.wake_all(self.server.locks.release_statement(self.rt.spid))
}

///|
/// Releases this session's locks (transaction end) and records woken
/// sessions for the engine.
fn Session::release_locks(self : Session) -> Unit {
  self.server.wake_all(self.server.locks.release_all(self.rt.spid))
}

///|
/// Called by the engine for a parked deadlock victim before re-running its
/// request: abandon the wait and fail at the next one with 1205.
pub fn Session::make_victim(self : Session) -> Unit {
  match self.waiting {
    Some(r) => self.server.wake_all(self.server.locks.cancel(r))
    None => ()
  }
  self.waiting = None
  self.fail_next_wait = Some(1205)
}

///|
/// Abandons a parked request (ATTENTION, disconnect).
pub fn Session::cancel_wait(self : Session) -> Unit {
  match self.waiting {
    Some(r) => self.server.wake_all(self.server.locks.cancel(r))
    None => ()
  }
  self.waiting = None
  self.parked = false
}

///|
/// Session end: roll back and release everything.
pub fn Session::close(self : Session) -> Unit {
  self.cancel_wait()
  self.tx = None
  self.release_locks()
}

///|
pub fn Session::is_parked(self : Session) -> Bool {
  self.parked
}
