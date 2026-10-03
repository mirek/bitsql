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
  option_bits : Int
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
          savepoints: tx.savepoints.copy(),
          name: tx.name,
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
    option_bits: self.rt.option_bits,
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
  self.implicit_tx = false
  self.rt.trancount = s.trancount
  self.rt.xact_state = s.xact_state
  self.rt.error = s.error
  self.rt.rowcount = s.rowcount
  self.rt.identity = s.identity
  self.rt.scope_identity = s.scope_identity
  self.rt.database = s.database
  self.nocount = s.nocount
  self.xact_abort = s.xact_abort
  self.rt.option_bits = s.option_bits
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
  self.server.active_rv.remove(self.rt.spid)
  // transaction-owned application locks end with the transaction
  let gone = []
  for k, _ in self.applocks {
    if k.has_prefix("t:") {
      gone.push(k)
    }
  }
  for k in gone {
    self.applocks.remove(k)
  }
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
  self.in_waitfor = false
  self.waits_done = 0
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
  self.applocks.clear()
  self.server.wake_all(self.server.locks.release_session(self.rt.spid))
  self.server.live.remove(self.rt.spid)
}

///|
pub fn Session::is_parked(self : Session) -> Bool {
  self.parked
}

///|
/// Milliseconds the engine should wait before failing the parked request
/// with 1222 (SET LOCK_TIMEOUT), if any.
pub fn Session::wait_timeout(self : Session) -> Int? {
  guard self.parked else { return None }
  match self.wait_ms {
    Some(ms) if ms > 0 => Some(ms)
    Some(_) => None
    None => if self.lock_timeout > 0 { Some(self.lock_timeout) } else { None }
  }
}

///|
/// The lock timeout expired: abandon the wait; the re-run fails with 1222
/// at the same statement.
pub fn Session::time_out(self : Session) -> Unit {
  if self.in_waitfor {
    // WAITFOR elapsed: the re-run passes this wait
    self.in_waitfor = false
    self.waits_done += 1
    return
  }
  match self.waiting {
    Some(r) => self.server.wake_all(self.server.locks.cancel(r))
    None => ()
  }
  self.waiting = None
  self.fail_next_wait = Some(1222)
}

///|
/// RESETCONNECTION (TDS header status 0x08, tedious `connection.reset()`):
/// roll back an open transaction, then reset session state before the
/// request runs. Returns the ENVCHANGE items that precede the request's
/// response: rollback (if any), then RESETACK (captured with tedious reset
/// against SQL Server 17.0.5005.3).
pub fn Session::reset(self : Session) -> Array[@reply.Item] {
  let items : Array[@reply.Item] = []
  if self.rt.trancount > 0 {
    let d = self.tx_descriptor()
    self.rollback_tx()
    self.rt.trancount = 0
    self.rt.xact_state = 0
    items.push(EnvChange(RollbackTransaction(d)))
  }
  items.push(EnvChange(ResetConnectionAck))
  // temp tables, cursors, SET options, context info, session-owned locks
  self.temp = @store.Db::empty()
  self.tvars = @store.Db::empty()
  self.cursors.clear()
  self.nocount = false
  self.xact_abort = false
  self.identity_insert = None
  self.isolation = "READ COMMITTED"
  self.lock_timeout = -1
  self.rt.lock_timeout = -1
  self.rt.datefirst = 7
  self.rt.option_bits = 0
  self.session_flags.clear()
  self.server.set_priority(self.rt.spid, 0)
  self.context_info = None
  self.session_context.clear()
  self.applocks.clear()
  self.server.wake_all(self.server.locks.release_session(self.rt.spid))
  self.rt.error = 0
  self.rt.rowcount = 0
  items
}
