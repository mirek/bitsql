///|
/// An application lock held by this session (sp_getapplock). Requests are
/// counted: each successful sp_getapplock needs one sp_releaseapplock.
priv struct AppLock {
  mut mode : String
  mut count : Int
}

///|
fn applock_mode(name : String) -> (String, @sched.LockMode)? {
  match name.to_lower() {
    "shared" => Some(("Shared", S))
    "update" => Some(("Update", U))
    "intentshared" => Some(("IntentShared", IS))
    "intentexclusive" => Some(("IntentExclusive", IX))
    "exclusive" => Some(("Exclusive", X))
    _ => None
  }
}

///|
/// Lock resource of an application lock: its own lock space per database
/// (table id -1), the resource name compared exactly.
fn Session::applock_resource(
  self : Session,
  resource : String,
) -> @sched.Resource[LockKey] {
  let key : LockKey = {
    values: [String(self.rt.database.to_lower()), String(resource)],
    colls: [None, @types.Collation::parse("Latin1_General_BIN2")],
  }
  KeyRange(table=-1, index=0, @sched.Interval::point(key))
}

///|
fn applock_key(transaction_owner : Bool, resource : String) -> String {
  (if transaction_owner { "t:" } else { "s:" }) + resource
}

///|
/// sp_getapplock / sp_releaseapplock as SQL Server runs them: system T-SQL
/// procedures whose own statements produce DONEINPROC tokens. The token
/// sequences per path are captured (corpus applock/): 193 = assignment
/// (count 1), 192 = IF, 224 = the internal EXEC, 246 = RAISERROR.
fn Session::exec_applock_proc(
  self : Session,
  name : String,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let order = if name == "sp_getapplock" {
    ["@resource", "@lockmode", "@lockowner", "@locktimeout", "@dbprincipal"]
  } else {
    ["@resource", "@lockowner", "@dbprincipal"]
  }
  let vals : Map[String, @types.Value] = Map([])
  for i, a in args {
    let key = match a.name {
      Some(n) => n.to_lower()
      None => if i < order.length() { order[i] } else { "" }
    }
    vals[key] = self.eval(a.value).0
  }
  let text = (k : String) => {
    match vals.get(k) {
      Some(String(s)) => Some(s)
      _ => None
    }
  }
  self.rt.nest_level += 1
  let t193 = () => {
    self.rt.rowcount = 1
    self.done(193, count=Some(1L))
  }
  let status = {
    errdefer {
      self.rt.nest_level -= 1
    }
    if name == "sp_getapplock" {
      self.getapplock(text, vals, t193)
    } else {
      self.releaseapplock(text, t193)
    }
  }
  self.rt.nest_level -= 1
  match return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.proc_done(status)
}

///|
fn Session::getapplock(
  self : Session,
  text : (String) -> String?,
  vals : Map[String, @types.Value],
  t193 : () -> Unit,
) -> Int raise {
  let resource = text("@resource").unwrap_or("")
  t193()
  self.done(192)
  let mode_text = text("@lockmode").unwrap_or("")
  guard applock_mode(mode_text) is Some((mode_name, mode)) else {
    self.info(
      15625,
      1,
      "Option '\{mode_text}' not recognized for '@LockMode' parameter.",
      26,
    )
    self.done(246)
    t193()
    return -999
  }
  t193()
  self.done(192)
  let owner = text("@lockowner").unwrap_or("Transaction")
  let transaction_owner = match owner.to_lower() {
    "transaction" => true
    "session" => false
    _ => raise @types.not_supported("sp_getapplock @LockOwner '\{owner}'")
  }
  self.done(192)
  let timeout = match vals.get("@locktimeout") {
    Some(Null) | None => {
      t193()
      self.lock_timeout
    }
    Some(v) =>
      match @types.cast(v, Int, Int) {
        Int(n) => n
        _ => self.lock_timeout
      }
  }
  t193()
  self.done(192)
  if transaction_owner && self.rt.trancount == 0 {
    self.info(
      15626, 1, "You attempted to acquire a transactional application lock without an active transaction.",
      52,
    )
    self.done(246)
    t193()
    return -999
  }
  let res = self.applock_resource(resource)
  let key = applock_key(transaction_owner, resource)
  let duration : @sched.Duration = if transaction_owner {
    Transaction
  } else {
    Session
  }
  let status = match
    self.server.locks.request(self.rt.spid, res, mode, duration) {
    Granted => if self.applock_waited { 1 } else { 0 }
    Waiting(request~) =>
      if timeout == 0 || self.fail_next_wait == Some(1222) {
        self.fail_next_wait = None
        self.server.wake_all(self.server.locks.cancel(request))
        -1
      } else {
        // park the request; its re-run finds the lock granted and returns 1
        self.applock_waited = true
        self.wait_ms = Some(timeout)
        self.waiting = Some(request)
        raise Park
      }
    Deadlock(victim~, request~) =>
      if victim == self.rt.spid {
        -3
      } else {
        self.server.victims.push(victim)
        self.applock_waited = true
        self.wait_ms = Some(timeout)
        match request {
          Some(r) => self.waiting = Some(r)
          None => ()
        }
        raise Park
      }
  }
  if status >= 0 {
    match self.applocks.get(key) {
      Some(l) => {
        l.count += 1
        l.mode = match applock_mode(l.mode) {
          Some((_, held)) =>
            if held.max(mode) == mode {
              mode_name
            } else {
              l.mode
            }
          None => mode_name
        }
      }
      None => self.applocks[key] = { mode: mode_name, count: 1, }
    }
  }
  self.done(224)
  t193()
  status
}

///|
fn Session::releaseapplock(
  self : Session,
  text : (String) -> String?,
  t193 : () -> Unit,
) -> Int raise {
  let resource = text("@resource").unwrap_or("")
  let owner = text("@lockowner").unwrap_or("Transaction")
  let transaction_owner = match owner.to_lower() {
    "transaction" => true
    "session" => false
    _ => raise @types.not_supported("sp_releaseapplock @LockOwner '\{owner}'")
  }
  t193()
  self.done(192)
  t193()
  let key = applock_key(transaction_owner, resource)
  match self.applocks.get(key) {
    Some(l) => {
      l.count -= 1
      if l.count == 0 {
        self.applocks.remove(key)
        self.server.wake_all(
          self.server.locks.release_resource(
            self.rt.spid,
            self.applock_resource(resource),
          ),
        )
      }
      self.done(224)
      t193()
      0
    }
    None => {
      let principal = text("@dbprincipal").unwrap_or("public")
      self.out.push(
        Message({
          number: 1223,
          state: 1,
          class: 16,
          message: "Cannot release the application lock (Database Principal: '\{principal}', Resource: '\{resource}') because it is not currently held.",
          procedure: "xp_userlock",
          line: 1,
        }),
      )
      self.rt.error = 1223
      self.out.push(InProcDone(cmd=224, count=None, error=true))
      t193()
      -999
    }
  }
}

///|
/// APPLOCK_MODE(principal, resource, owner) / APPLOCK_TEST(principal,
/// resource, mode, owner).
fn Session::applock_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? raise @types.SqlError {
  let text = (k : Int) => {
    match args.get(k) {
      Some(String(s)) => s
      _ => ""
    }
  }
  match name {
    "APPLOCK_MODE" => {
      let transaction_owner = text(2).to_lower() == "transaction"
      if transaction_owner && self.rt.trancount == 0 {
        raise @types.sql_error(
          3918,
          "The statement or function must be executed in the context of a user transaction.",
          state=2,
        )
      }
      Some(
        String(
          match self.applocks.get(applock_key(transaction_owner, text(1))) {
            Some(l) => l.mode
            None => "NoLock"
          },
        ),
      )
    }
    "APPLOCK_TEST" => {
      guard applock_mode(text(2)) is Some((_, mode)) else {
        raise @types.not_supported("APPLOCK_TEST lock mode '\{text(2)}'")
      }
      let ok = self.server.locks.can_grant(
        self.rt.spid,
        self.applock_resource(text(1)),
        mode,
      )
      Some(Int(if ok { 1 } else { 0 }))
    }
    _ => None
  }
}
