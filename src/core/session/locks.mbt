///|
/// Lock key: index key values with the collations used to compare them.
pub(all) struct LockKey {
  values : Array[@types.Value]
  colls : Array[@types.Collation?]
}

///|
fn lock_key_cmp(a : LockKey, b : LockKey) -> Int {
  let n = @cmp.minimum(a.values.length(), b.values.length())
  for i in 0..<n {
    let c = match (a.values[i], b.values[i]) {
      (Null, Null) => 0
      (Null, _) => -1
      (_, Null) => 1
      (x, y) => {
        let coll = if i < a.colls.length() { a.colls[i] } else { None }
        (@types.compare(x, y, collation?=coll) catch { _ => None }).unwrap_or(0)
      }
    }
    if c != 0 {
      return c
    }
  }
  a.values.length().compare(b.values.length())
}

///|
/// The deadlock victim is the session with the lowest DEADLOCK_PRIORITY
/// (the manager picks the lowest cost; ties: longest waiter).
fn new_lock_manager(priorities : Map[Int, Int]) -> @sched.LockManager[LockKey] {
  @sched.LockManager::new(lock_key_cmp, cost=s => {
    priorities.get(s).unwrap_or(0).to_int64()
  })
}

///|
/// Raised to park the current request until a lock is granted.
priv suberror Park

///|
fn deadlock_error(spid : Int) -> @types.SqlError {
  @types.sql_error(
    1205,
    "Transaction (Process ID \{spid}) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.",
    state=51,
    severity=13,
  )
}

///|
/// Acquires a lock for this session or parks the request (see
/// decisions.md, request restart). Only database tables (scope 0) lock.
fn Session::acquire(
  self : Session,
  resource : @sched.Resource[LockKey],
  mode : @sched.LockMode,
  duration : @sched.Duration,
) -> Unit raise {
  let me = self.rt.spid
  // autocommit statements hold their locks only for the statement
  let duration : @sched.Duration = if self.tx is None {
    Statement
  } else {
    duration
  }
  match self.server.locks.request(me, resource, mode, duration) {
    Granted => ()
    Waiting(request~) => {
      match self.fail_next_wait {
        Some(n) => {
          self.fail_next_wait = None
          self.server.wake_all(self.server.locks.cancel(request))
          raise self.wait_failure(n)
        }
        None => ()
      }
      if self.lock_timeout == 0 {
        self.server.wake_all(self.server.locks.cancel(request))
        raise self.wait_failure(1222)
      }
      self.waiting = Some(request)
      raise Park
    }
    Deadlock(victim~, request~) =>
      if victim == me {
        raise self.wait_failure(1205)
      } else if self.fail_next_wait is Some(n) {
        // already chosen as the victim of this cycle: fail now
        self.fail_next_wait = None
        match request {
          Some(r) => self.server.wake_all(self.server.locks.cancel(r))
          None => ()
        }
        raise self.wait_failure(n)
      } else {
        // another (parked) session is the victim: it re-runs its request
        // and fails with 1205 at its waiting statement; we wait.
        self.server.victims.push(victim)
        match request {
          Some(r) => self.waiting = Some(r)
          None => ()
        }
        raise Park
      }
  }
}

///|
/// 1205 (deadlock victim: the transaction is rolled back and the batch
/// ends) or 1222 (lock timeout: the statement fails).
fn Session::wait_failure(self : Session, n : Int) -> @types.SqlError {
  if n == 1205 {
    // exec_one rolls the transaction back after reporting the error
    self.throwing = true // ends the batch
    deadlock_error(self.rt.spid)
  } else {
    // statement-level; followed by 3621 (captured: locking/lock-timeout)
    self.terminated(
      @types.sql_error(1222, "Lock request time out period exceeded.", state=51),
    )
  }
}

///|
fn index_colls(t : @store.Table, ix : @store.Index) -> Array[@types.Collation?] {
  ix.columns.map(c => t.columns[c.0].ty.collation())
}

///|
/// The point lock resource identifying a row: its primary key, or its row id.
fn row_resource(
  t : @store.Table,
  rowid : Int64,
  row : Array[@types.Value],
) -> @sched.Resource[LockKey] {
  for i, ix in t.indexes {
    if ix.primary {
      let key = {
        values: ix.columns.map(c => row[c.0]),
        colls: index_colls(t, ix),
      }
      return KeyRange(table=t.id, index=i, @sched.Interval::point(key))
    }
  }
  KeyRange(
    table=t.id,
    index=-1,
    @sched.Interval::point({ values: [BigInt(rowid)], colls: [None], }),
  )
}

///|
/// X locks on rows a DML statement modifies (database tables only).
fn Session::lock_rows(
  self : Session,
  target : Target,
  rows : Array[(Int64, Array[@types.Value])],
) -> Unit raise {
  if target.scope != 0 {
    return
  }
  for r in rows {
    self.acquire(row_resource(target.table, r.0, r.1), X, Transaction)
  }
}

///|
/// Lock mode implied by table hints of a read, if any.
fn hint_lock(hints : Array[@ast.TableHint]) -> (@sched.LockMode, Bool)? {
  let names = hints.map(h => h.name.to_upper())
  let range = names.contains("HOLDLOCK") || names.contains("SERIALIZABLE")
  if names.contains("XLOCK") || names.contains("TABLOCKX") {
    Some((X, range))
  } else if names.contains("UPDLOCK") {
    Some((U, range))
  } else if range {
    Some((S, true))
  } else {
    None
  }
}

///|
/// Point key of `t`'s primary key fixed by equalities in `where_`
/// (`pk = <expr without columns>` conjuncts), evaluated now.
fn Session::pk_point(
  self : Session,
  t : @store.Table,
  alias_ : String,
  where_ : @ast.Expr?,
) -> (Int, LockKey)? raise {
  guard where_ is Some(w) else { return None }
  let pk_i = match t.indexes.search_by(ix => ix.primary) {
    Some(i) => i
    None => return None
  }
  let pk = t.indexes[pk_i]
  let conj = []
  fn split(e : @ast.Expr) -> Unit {
    match e.kind {
      And(a, b) => {
        split(a)
        split(b)
      }
      Paren(a) => split(a)
      _ => conj.push(e)
    }
  }

  split(w)
  let values = []
  for c in pk.columns {
    let col = t.columns[c.0].name.to_lower()
    let mut found : @ast.Expr? = None
    for e in conj {
      guard e.kind is Compare(Eq, l, r) else { continue }
      let name_of = (x : @ast.Expr) => {
        match x.kind {
          Column(parts) => {
            let n = parts[parts.length() - 1].name.to_lower()
            let q = if parts.length() >= 2 {
              parts[parts.length() - 2].name.to_lower()
            } else {
              ""
            }
            if n == col && (q == "" || q == alias_ || q == t.name.to_lower()) {
              true
            } else {
              false
            }
          }
          _ => false
        }
      }
      if name_of(l) && !mentions_column(r) {
        found = Some(r)
      } else if name_of(r) && !mentions_column(l) {
        found = Some(l)
      }
    }
    match found {
      Some(e) => {
        let (v, ty) = self.eval(e)
        values.push(@types.cast(v, ty, t.columns[c.0].ty))
      }
      None => return None
    }
  }
  Some((pk_i, { values, colls: index_colls(t, pk), }))
}

///|
fn mentions_column(e : @ast.Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => if x.kind is Column(_) { found = true })
  found
}

///|
/// Read lock for a table reference: (mode, duration), or None (NOLOCK,
/// READ UNCOMMITTED, SNAPSHOT). Unhinted reads take S for the statement under
/// READ COMMITTED and for the transaction under REPEATABLE READ/SERIALIZABLE.
fn Session::read_lock(
  self : Session,
  hints : Array[@ast.TableHint],
) -> (@sched.LockMode, @sched.Duration)? {
  let names = hints.map(h => h.name.to_upper())
  match hint_lock(hints) {
    Some((mode, _)) => return Some((mode, Transaction))
    None => ()
  }
  if names.contains("NOLOCK") || names.contains("READUNCOMMITTED") {
    return None
  }
  match self.isolation {
    "READ UNCOMMITTED" | "SNAPSHOT" => None
    "REPEATABLE READ" | "SERIALIZABLE" => Some((S, Transaction))
    _ => Some((S, Statement))
  }
}

///|
/// Takes the locks a query's reads need (database tables in FROM clauses,
/// including subqueries in WHERE): the primary-key point when the WHERE pins
/// the key by equality, otherwise the whole table (a scan).
fn Session::lock_reads(self : Session, q : @ast.Query) -> Unit raise {
  fn body(b : @ast.QueryBody) -> Unit raise {
    match b {
      Select(sel) => {
        fn visit(r : @ast.TableRef) -> Unit raise {
          match r.kind {
            Table(name, alias_~, hints~) =>
              match (self.read_lock(hints), self.find_table(name)) {
                (Some((mode, duration)), Some((0, t))) => {
                  let a = match alias_ {
                    Some(x) => x.name.to_lower()
                    None => t.name.to_lower()
                  }
                  let res : @sched.Resource[LockKey] = match
                    self.pk_point(t, a, sel.where_) {
                    Some((i, key)) =>
                      KeyRange(table=t.id, index=i, @sched.Interval::point(key))
                    None => WholeTable(t.id)
                  }
                  self.acquire(res, mode, duration)
                }
                _ => ()
              }
            Join(_, l, rr, on~, ..) => {
              visit(l)
              visit(rr)
              match on {
                Some(e) => self.lock_expr_reads(e)
                None => ()
              }
            }
            Derived(q, ..) => self.lock_reads(q)
            _ => ()
          }
        }

        for r in sel.from {
          visit(r)
        }
        match sel.where_ {
          Some(w) => self.lock_expr_reads(w)
          None => ()
        }
      }
      SetOperation(_, l, r) => {
        body(l)
        body(r)
      }
      Nested(q) => self.lock_reads(q)
    }
  }

  body(q.body)
}

///|
/// Read locks of the subqueries inside an expression.
fn Session::lock_expr_reads(self : Session, e : @ast.Expr) -> Unit raise {
  let queries = []
  walk_expr(e, x => {
    match x.kind {
      Subquery(q) | Exists(q) => queries.push(q)
      InQuery(_, q, ..) => queries.push(q)
      _ => ()
    }
  })
  for q in queries {
    self.lock_reads(q)
  }
}
