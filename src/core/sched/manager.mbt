///|
/// A granted lock. The owning session and table are implied by the `Slot`
/// holding it; `seq` orders grants across sessions (blocker lists report
/// sessions in the order of their earliest conflicting grant).
priv struct Grant[K] {
  seq : Int
  resource : Resource[K]
  mode : LockMode
  duration : Duration
}

///|
/// The grants of one session on one table, with per-duration counts so
/// statement and transaction ends release them in bulk.
priv struct Slot[K] {
  grants : Array[Grant[K]]
  /// Grants of duration `Statement` and `Session` in `grants`.
  mut statement : Int
  mut session : Int
}

///|
fn[K] Slot::count(self : Slot[K], d : Duration, delta : Int) -> Unit {
  match d {
    Statement => self.statement += delta
    Session => self.session += delta
    Transaction => ()
  }
}

///|
fn[K] Slot::retain(self : Slot[K], keep : (Grant[K]) -> Bool) -> Unit {
  self.grants.retain(g => {
    if keep(g) {
      true
    } else {
      self.count(g.duration, -1)
      false
    }
  })
}

///|
priv struct Waiter[K] {
  id : Int
  session : Int
  resource : Resource[K]
  mode : LockMode
  duration : Duration
}

///|
pub(all) enum Outcome {
  /// The lock is held; continue.
  Granted
  /// Park the session; `request` id is reported by `release_*` once granted.
  Waiting(request~ : Int)
  /// Waiting would close a cycle. `victim` must be rolled back with 1205;
  /// when the victim is not the requester, the requester is waiting.
  Deadlock(victim~ : Int, request~ : Int?)
} derive(Debug, Eq)

///|
/// Lock manager over keys `K` compared by `cmp`. Pure: no clocks, no I/O.
/// Grants are FIFO per conflict: a request also waits behind earlier
/// conflicting waiters, so writers are not starved by a stream of readers.
pub struct LockManager[K] {
  cmp : (K, K) -> Int
  /// Cost of rolling back a session; the cheapest session in a cycle is the
  /// deadlock victim (SQL Server's default DEADLOCK_PRIORITY NORMAL rule).
  cost : (Int) -> Int64
  /// Grants by table, then session. A request only scans the grants of
  /// other sessions on its own table, and set-wide DML (one key lock per
  /// row) appends to its own slot without searching.
  priv tables : Map[Int, Map[Int, Slot[K]]]
  /// Pending requests in arrival order (at most one per session).
  priv waiters : Array[Waiter[K]]
  priv mut next_id : Int
  priv mut next_seq : Int
  /// Slot of the last fast-path request (table, session): consecutive row
  /// locks of one statement skip both map lookups. Cleared on release.
  priv mut last : (Int, Int, Slot[K])?
}

///|
pub fn[K] LockManager::new(
  cmp : (K, K) -> Int,
  cost? : (Int) -> Int64 = _ => 0L,
) -> LockManager[K] {
  {
    cmp,
    cost,
    tables: Map([]),
    waiters: [],
    next_id: 1,
    next_seq: 0,
    last: None,
  }
}

///|
fn[K] LockManager::slot(
  self : LockManager[K],
  table : Int,
  session : Int,
) -> Slot[K] {
  if self.last is Some((t, s, slot)) && t == table && s == session {
    return slot
  }
  let sessions = match self.tables.get(table) {
    Some(m) => m
    None => {
      let m : Map[Int, Slot[K]] = Map([])
      self.tables[table] = m
      m
    }
  }
  let slot = match sessions.get(session) {
    Some(slot) => slot
    None => {
      let slot : Slot[K] = { grants: [], statement: 0, session: 0, }
      sessions[session] = slot
      slot
    }
  }
  self.last = Some((table, session, slot))
  slot
}

///|
fn[K] LockManager::push_grant(
  self : LockManager[K],
  slot : Slot[K],
  resource : Resource[K],
  mode : LockMode,
  duration : Duration,
) -> Unit {
  let seq = self.next_seq
  self.next_seq += 1
  slot.grants.push({ seq, resource, mode, duration, })
  slot.count(duration, 1)
}

///|
fn[K] LockManager::conflicts_with_grants(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
) -> Array[Int] {
  guard self.tables.get(resource.table()) is Some(sessions) else { return [] }
  // (earliest conflicting grant, session)
  let found : Array[(Int, Int)] = []
  for s, slot in sessions {
    if s == session {
      continue
    }
    for g in slot.grants {
      if !compatible(g.mode, mode) && g.resource.overlaps(resource, self.cmp) {
        found.push((g.seq, s))
        break
      }
    }
  }
  if found.length() > 1 {
    found.sort_by((a, b) => a.0.compare(b.0))
  }
  found.map(f => f.1)
}

///|
fn[K] LockManager::conflicts_with_waiters_before(
  self : LockManager[K],
  limit : Int,
  session : Int,
  resource : Resource[K],
  mode : LockMode,
) -> Array[Int] {
  let out = []
  if limit == 0 {
    return out
  }
  // A conversion (the session already holds this resource, e.g. U -> X) is
  // served before new waiters, as in SQL Server's conversion queue.
  // Otherwise UPDLOCK upserts would deadlock against their own waiters.
  if self.holds(session, resource) {
    return out
  }
  for i in 0..<limit {
    let w = self.waiters[i]
    if w.session != session &&
      !compatible(w.mode, mode) &&
      w.resource.overlaps(resource, self.cmp) &&
      !out.contains(w.session) {
      out.push(w.session)
    }
  }
  out
}

///|
fn[K] LockManager::grant(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
  duration : Duration,
) -> Unit {
  let slot = self.slot(resource.table(), session)
  // Upgrade in place when the same session already holds this exact resource.
  for i, g in slot.grants {
    if g.resource.same(resource, self.cmp) {
      let d : Duration = match (g.duration, duration) {
        (Session, _) | (_, Session) => Session
        (Transaction, _) | (_, Transaction) => Transaction
        _ => Statement
      }
      slot.count(g.duration, -1)
      slot.count(d, 1)
      slot.grants[i] = { ..g, mode: g.mode.max(mode), duration: d, }
      return
    }
  }
  self.push_grant(slot, resource, mode, duration)
}

///|
pub fn[K] LockManager::request(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
  duration : Duration,
) -> Outcome {
  // fast path: nobody else on this table, so nothing can conflict. Append
  // without the in-place upgrade search: duplicate entries of one session
  // never conflict with each other and releases remove them all.
  let table = resource.table()
  if self.alone(table, session) {
    self.push_grant(self.slot(table, session), resource, mode, duration)
    return Granted
  }
  let blockers = self.conflicts_with_grants(session, resource, mode)
  for
    s in self.conflicts_with_waiters_before(
      self.waiters.length(),
      session,
      resource,
      mode,
    ) {
    if !blockers.contains(s) {
      blockers.push(s)
    }
  }
  if blockers.is_empty() {
    self.grant(session, resource, mode, duration)
    return Granted
  }
  let id = self.next_id
  self.next_id += 1
  self.waiters.push({ id, session, resource, mode, duration, })
  match self.find_cycle(session) {
    None => Waiting(request=id)
    Some(cycle) => {
      // Cheapest session; ties go to the session that has waited longest,
      // not the requester that closed the cycle (captured:
      // locking/deadlock-two-tables).
      let waited_since = (s : Int) => {
        let mut at = self.waiters.length()
        for i, w in self.waiters {
          if w.session == s {
            at = i
            break
          }
        }
        at
      }
      let mut victim = cycle[0]
      for s in cycle {
        let c = (self.cost)(s)
        let vc = (self.cost)(victim)
        if c < vc || (c == vc && waited_since(s) < waited_since(victim)) {
          victim = s
        }
      }
      if victim == session {
        self.waiters.pop() |> ignore
        Deadlock(victim~, request=None)
      } else {
        Deadlock(victim~, request=Some(id))
      }
    }
  }
}

///|
/// Sessions `session` waits for (wait-for graph edges).
fn[K] LockManager::waits_for(
  self : LockManager[K],
  session : Int,
) -> Array[Int] {
  let out = []
  for i, w in self.waiters {
    if w.session != session {
      continue
    }
    for s in self.conflicts_with_grants(w.session, w.resource, w.mode) {
      if !out.contains(s) {
        out.push(s)
      }
    }
    for
      s in self.conflicts_with_waiters_before(i, w.session, w.resource, w.mode) {
      if !out.contains(s) {
        out.push(s)
      }
    }
  }
  out
}

///|
/// A cycle through `start` in the wait-for graph, as the list of sessions on it.
fn[K] LockManager::find_cycle(
  self : LockManager[K],
  start : Int,
) -> Array[Int]? {
  let path = [start]
  let visited : Set[Int] = Set([])
  fn dfs(node : Int) -> Bool {
    for next in self.waits_for(node) {
      if next == start {
        return true
      }
      if visited.contains(next) {
        continue
      }
      visited.add(next)
      path.push(next)
      if dfs(next) {
        return true
      }
      path.pop() |> ignore
    }
    false
  }

  if dfs(start) {
    Some(path)
  } else {
    None
  }
}

///|
/// Grants every waiter that became grantable, in FIFO order. Returns
/// (session, request id) pairs the engine must resume.
fn[K] LockManager::wake(self : LockManager[K]) -> Array[(Int, Int)] {
  let woken = []
  let mut progress = true
  while progress {
    progress = false
    for i in 0..<self.waiters.length() {
      let w = self.waiters[i]
      if self.conflicts_with_grants(w.session, w.resource, w.mode).is_empty() &&
        self
        .conflicts_with_waiters_before(i, w.session, w.resource, w.mode)
        .is_empty() {
        self.waiters.remove(i) |> ignore
        self.grant(w.session, w.resource, w.mode, w.duration)
        woken.push((w.session, w.id))
        progress = true
        break
      }
    }
  }
  woken
}

///|
/// Releases the locks and pending requests of `session` at transaction end
/// (commit, rollback, deadlock victim). Session-duration locks stay.
pub fn[K] LockManager::release_all(
  self : LockManager[K],
  session : Int,
) -> Array[(Int, Int)] {
  self.release_slots(session, slot => {
    if slot.session == 0 {
      false
    } else {
      slot.retain(g => g.duration == Session)
      slot.statement = 0
      true
    }
  })
  self.waiters.retain(w => w.session != session)
  self.wake()
}

///|
/// Releases everything `session` holds or waits for (disconnect).
pub fn[K] LockManager::release_session(
  self : LockManager[K],
  session : Int,
) -> Array[(Int, Int)] {
  self.release_slots(session, _ => false)
  self.waiters.retain(w => w.session != session)
  self.wake()
}

///|
/// Releases one granted resource of `session` (sp_releaseapplock).
pub fn[K] LockManager::release_resource(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
) -> Array[(Int, Int)] {
  self.last = None
  let table = resource.table()
  if self.tables.get(table) is Some(sessions) &&
    sessions.get(session) is Some(slot) {
    slot.retain(g => !g.resource.same(resource, self.cmp))
    if slot.grants.is_empty() {
      self.drop_slot(table, sessions, session)
    }
  }
  self.wake()
}

///|
/// True when `session` could be granted `mode` on `resource` now
/// (APPLOCK_TEST).
pub fn[K] LockManager::can_grant(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
) -> Bool {
  self.conflicts_with_grants(session, resource, mode).is_empty() &&
  self
  .conflicts_with_waiters_before(self.waiters.length(), session, resource, mode)
  .is_empty()
}

///|
/// Releases statement-duration locks at the end of a statement.
pub fn[K] LockManager::release_statement(
  self : LockManager[K],
  session : Int,
) -> Array[(Int, Int)] {
  self.release_slots(session, slot => {
    if slot.statement == slot.grants.length() {
      false
    } else {
      if slot.statement > 0 {
        slot.retain(g => g.duration != Statement)
      }
      true
    }
  })
  self.wake()
}

///|
/// Abandons a pending request (lock timeout 1222, attention).
pub fn[K] LockManager::cancel(
  self : LockManager[K],
  request : Int,
) -> Array[(Int, Int)] {
  self.waiters.retain(w => w.id != request)
  self.wake()
}

///|
/// Number of granted locks held by `session` (tests, diagnostics).
pub fn[K] LockManager::held(self : LockManager[K], session : Int) -> Int {
  let mut n = 0
  for _, sessions in self.tables {
    if sessions.get(session) is Some(slot) {
      n += slot.grants.length()
    }
  }
  n
}

///|
fn[K] LockManager::holds(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
) -> Bool {
  match self.tables.get(resource.table()) {
    Some(sessions) =>
      match sessions.get(session) {
        Some(slot) =>
          slot.grants.iter().any(g => g.resource.same(resource, self.cmp))
        None => false
      }
    None => false
  }
}

///|
/// A pending request's mode and the sessions it waits for
/// (sys.dm_exec_requests blocking_session_id / wait_type).
pub fn[K] LockManager::waiting_on(
  self : LockManager[K],
  request : Int,
) -> (LockMode, Array[Int])? {
  for i, w in self.waiters {
    if w.id == request {
      let blockers = self.conflicts_with_grants(w.session, w.resource, w.mode)
      for
        s in self.conflicts_with_waiters_before(
          i,
          w.session,
          w.resource,
          w.mode,
        ) {
        if !blockers.contains(s) {
          blockers.push(s)
        }
      }
      return Some((w.mode, blockers))
    }
  }
  None
}

///|
/// Applies `keep` to every slot of `session`; a slot it returns false for
/// is dropped whole (bulk release without visiting its grants).
fn[K] LockManager::release_slots(
  self : LockManager[K],
  session : Int,
  keep : (Slot[K]) -> Bool,
) -> Unit {
  self.last = None
  let drop = []
  for table, sessions in self.tables {
    if sessions.get(session) is Some(slot) && !keep(slot) {
      drop.push(table)
    }
  }
  for table in drop {
    if self.tables.get(table) is Some(sessions) {
      self.drop_slot(table, sessions, session)
    }
  }
}

///|
fn[K] LockManager::drop_slot(
  self : LockManager[K],
  table : Int,
  sessions : Map[Int, Slot[K]],
  session : Int,
) -> Unit {
  sessions.remove(session)
  if sessions.is_empty() {
    self.tables.remove(table)
  }
}

///|
/// No other session holds or waits for anything on `table`.
fn[K] LockManager::alone(
  self : LockManager[K],
  table : Int,
  session : Int,
) -> Bool {
  match self.tables.get(table) {
    None => ()
    Some(m) =>
      if m.length() > 1 || (m.length() == 1 && !m.contains(session)) {
        return false
      }
  }
  for w in self.waiters {
    if w.session != session && w.resource.table() == table {
      return false
    }
  }
  true
}
