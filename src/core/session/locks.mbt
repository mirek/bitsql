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
pub fn new_lock_manager() -> @sched.LockManager[LockKey] {
  @sched.LockManager::new(lock_key_cmp)
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
      self.waiting = Some(request)
      raise Park
    }
    Deadlock(victim~, request~) =>
      if victim == me {
        raise self.wait_failure(1205)
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
/// 1205 (deadlock victim: the transaction is rolled back) or 1222 (lock
/// timeout).
fn Session::wait_failure(self : Session, n : Int) -> @types.SqlError {
  if n == 1205 {
    self.abort_transaction()
    self.throwing = true // ends the batch
    deadlock_error(self.rt.spid)
  } else {
    @types.sql_error(1222, "Lock request time out period exceeded.", state=51)
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
/// Locks for reads with UPDLOCK / HOLDLOCK / SERIALIZABLE / XLOCK hints in a
/// SELECT's FROM clause (simple shapes: the WHERE pins the primary key, or
/// the whole table is locked — conservative).
fn Session::lock_hinted_reads(self : Session, q : @ast.Query) -> Unit raise {
  guard q.body is Select(sel) else { return }
  fn visit(r : @ast.TableRef) -> Unit raise {
    match r.kind {
      Table(name, alias_~, hints~) =>
        match (hint_lock(hints), self.find_table(name)) {
          (Some((mode, _)), Some((0, t))) => {
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
            self.acquire(res, mode, Transaction)
          }
          _ => ()
        }
      Join(_, l, rr, ..) => {
        visit(l)
        visit(rr)
      }
      _ => ()
    }
  }

  for r in sel.from {
    visit(r)
  }
}
