///|
priv struct Grant[K] {
  session : Int
  resource : Resource[K]
  mode : LockMode
  duration : Duration
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
  priv grants : Array[Grant[K]]
  priv waiters : Array[Waiter[K]]
  priv mut next_id : Int
}

///|
pub fn[K] LockManager::new(
  cmp : (K, K) -> Int,
  cost? : (Int) -> Int64 = _ => 0L,
) -> LockManager[K] {
  { cmp, cost, grants: [], waiters: [], next_id: 1, }
}

///|
fn[K] LockManager::conflicts_with_grants(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
) -> Array[Int] {
  let out = []
  for g in self.grants {
    if g.session != session &&
      !compatible(g.mode, mode) &&
      g.resource.overlaps(resource, self.cmp) &&
      !out.contains(g.session) {
      out.push(g.session)
    }
  }
  out
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
  // Upgrade in place when the same session already holds this exact resource.
  for i, g in self.grants {
    if g.session == session && g.resource.same(resource, self.cmp) {
      let d = if g.duration == Transaction || duration == Transaction {
        Duration::Transaction
      } else {
        Statement
      }
      self.grants[i] = { ..g, mode: g.mode.max(mode), duration: d, }
      return
    }
  }
  self.grants.push({ session, resource, mode, duration, })
}

///|
pub fn[K] LockManager::request(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
  mode : LockMode,
  duration : Duration,
) -> Outcome {
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
/// Releases every lock and pending request of `session` (commit, rollback,
/// deadlock victim, disconnect).
pub fn[K] LockManager::release_all(
  self : LockManager[K],
  session : Int,
) -> Array[(Int, Int)] {
  self.grants.retain(g => g.session != session)
  self.waiters.retain(w => w.session != session)
  self.wake()
}

///|
/// Releases statement-duration locks at the end of a statement.
pub fn[K] LockManager::release_statement(
  self : LockManager[K],
  session : Int,
) -> Array[(Int, Int)] {
  self.grants.retain(g => !(g.session == session && g.duration == Statement))
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
  self.grants.filter(g => g.session == session).length()
}

///|
fn[K] LockManager::holds(
  self : LockManager[K],
  session : Int,
  resource : Resource[K],
) -> Bool {
  self.grants
  .iter()
  .any(g => g.session == session && g.resource.same(resource, self.cmp))
}
