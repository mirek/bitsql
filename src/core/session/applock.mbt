///|
/// An application lock held by this session (sp_getapplock). Requests are
/// counted: each successful sp_getapplock needs one sp_releaseapplock.
priv struct AppLock {
  mut mode : String
  mut count : Int
}

///|
fn rtrim_spaces(s : String) -> String {
  s.trim_end(chars=" ").to_owned()
}

///|
/// Lock modes sp_getapplock and APPLOCK_TEST accept; case-insensitive,
/// trailing spaces ignored (captured: msduck gaps-applock #010, #067).
fn applock_mode(name : String) -> (String, @sched.LockMode)? {
  match rtrim_spaces(name).to_lower() {
    "shared" => Some(("Shared", S))
    "update" => Some(("Update", U))
    "intentshared" => Some(("IntentShared", IS))
    "intentexclusive" => Some(("IntentExclusive", IX))
    "exclusive" => Some(("Exclusive", X))
    _ => None
  }
}

///|
/// Fixed database principals an application lock may name (bitsql has no
/// user-defined users or roles); compared case-insensitively. Each
/// principal has its own lock space (captured: gaps-applock #035, #036).
let applock_principals : Array[String] = [
  "public", "dbo", "guest", "sys", "information_schema", "db_owner", "db_accessadmin",
  "db_securityadmin", "db_ddladmin", "db_backupoperator", "db_datareader", "db_datawriter",
  "db_denydatareader", "db_denydatawriter",
]

///|
fn applock_principal_known(p : String) -> Bool {
  applock_principals.contains(rtrim_spaces(p).to_lower())
}

///|
/// Lock resources are nvarchar(255): longer names are truncated (captured:
/// gaps-applock #072, #073) and compared exactly, case and trailing spaces
/// included (#070).
fn applock_truncate(resource : String) -> String {
  if resource.length() > 255 {
    resource.unsafe_substring(start=0, end=255)
  } else {
    resource
  }
}

///|
/// Lock resource of an application lock: its own lock space per database
/// and principal (table id -1), the resource name compared exactly.
fn Session::applock_resource(
  self : Session,
  principal : String,
  resource : String,
) -> @sched.Resource[LockKey] {
  let key : LockKey = {
    values: [
      String(self.rt.database.to_lower()),
      String(principal),
      String(resource),
    ],
    colls: [None, None, @types.Collation::parse("Latin1_General_BIN2")],
  }
  KeyRange(table=-1, index=0, @sched.Interval::point(key))
}

///|
/// Key of a held lock: owner, principal (lower case) and resource.
fn applock_key(
  transaction_owner : Bool,
  principal : String,
  resource : String,
) -> String {
  (if transaction_owner { "t:" } else { "s:" }) + principal + "\u{0}" + resource
}

///|
/// Lock owner: Some(true) = Transaction, Some(false) = Session, None =
/// invalid. Case-insensitive, trailing spaces ignored (#010).
fn applock_owner(owner : String?) -> Bool? {
  match owner.map(o => rtrim_spaces(o).to_lower()) {
    Some("transaction") => Some(true)
    Some("session") => Some(false)
    _ => None
  }
}

///|
/// Parameters of sp_getapplock / sp_releaseapplock: name, type, default
/// (None: required).
fn applock_params(
  name : String,
) -> Array[(String, @types.SqlType, @types.Value?)] {
  let resource : (String, @types.SqlType, @types.Value?) = (
    "@Resource",
    NVarChar(Some(255), @types.default_collation),
    Some(Null),
  )
  let owner : (String, @types.SqlType, @types.Value?) = (
    "@LockOwner",
    VarChar(Some(32), @types.default_collation),
    Some(String("Transaction")),
  )
  let principal : (String, @types.SqlType, @types.Value?) = (
    "@DbPrincipal",
    NVarChar(Some(128), @types.default_collation),
    Some(String("public")),
  )
  if name == "sp_getapplock" {
    [
      resource,
      ("@LockMode", VarChar(Some(32), @types.default_collation), None),
      owner,
      ("@LockTimeout", Int, Some(Null)),
      principal,
    ]
  } else {
    [resource, owner, principal]
  }
}

///|
/// sp_getapplock / sp_releaseapplock as SQL Server runs them: system T-SQL
/// procedures whose own statements produce DONEINPROC tokens. The token
/// sequences per path are captured (corpus applock/, msduck gaps-applock):
/// 193 = assignment (count 1), 192 = IF, 224 = the internal EXEC of
/// xp_userlock, 246 = RAISERROR.
///
/// sp_getapplock: 193, 192 [bad @LockMode (NULL prints '(null)'): INFO
/// 15625 line 26, 246, 193, return -999], 193, 192 [bad @LockOwner: INFO
/// 15625 line 39, 246, 193, -999], 192, [193 when @LockTimeout is NULL],
/// 193, 192 [Transaction owner without a transaction: INFO 15626 line 52,
/// 246, 193, -999], 224, 193. An xp_userlock error replaces the plain 224
/// by ERROR + DONEINPROC 224 with the error bit, then 193 and -999:
/// time-out < -1 1227 state 2, NULL resource 1224 state 5, NULL principal
/// 1230, unknown principal 1202, in that order (#025-#033).
///
/// sp_releaseapplock: 193, 192 [bad owner: INFO 15625 line 20, 246, 193,
/// -999], 193, 224, 193; xp_userlock errors, in order: NULL resource 1224,
/// NULL principal 1230, Transaction owner outside a transaction 3918 state
/// 1, unknown principal 1202, lock not held 1223 (#005, #024, #027, #034;
/// corpus stmts/applock-validation).
///
/// Under TRY an xp_userlock error leaves both modules with plain 224
/// completions and the CATCH sees ERROR_PROCEDURE() 'sys.xp_userlock'
/// (#042). Argument errors are those of any procedure (8145, 119, 8144,
/// 201, 8114 state 1; #037-#041); DEFAULT takes the parameter default.
fn Session::exec_applock_proc(
  self : Session,
  name : String,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let params = applock_params(name)
  let span : @ast.Span = { start: 0, end: 0, line: 0, col: 0, }
  let ast_params : Array[@ast.Param] = params.map(p => {
    name: p.0,
    type_: { schema: None, name: "sql_variant", args: [], span, },
    varying: false,
    default_: match p.2 {
      Some(_) => Some({ kind: Null, span, })
      None => None
    },
    output: false,
    read_only: false,
    span,
  })
  if !self.check_proc_args(name, ast_params, args) {
    return
  }
  let vals : Map[String, @types.Value] = Map([])
  for p in params {
    match p.2 {
      Some(d) => vals[p.0.to_lower()] = d
      None => ()
    }
  }
  for i, a in args {
    let k = match a.name {
      None => Some(i)
      Some(n) => params.search_by(p => p.0.to_lower() == n.to_lower())
    }
    guard k is Some(k) else { continue }
    let (pname, pty, pdefault) = params[k]
    match self.exec_arg_value(a) {
      None => vals[pname.to_lower()] = pdefault.unwrap_or(Null)
      Some(arg) => {
        let v = @types.assign(arg.value, arg.ty, pty) catch {
          _ => {
            self.callee_error(
              arg_conversion_error(arg.ty, pty, 1),
              0,
              Some(name),
            )
            return
          }
        }
        vals[pname.to_lower()] = v
      }
    }
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
/// An error raised by xp_userlock inside sp_getapplock/sp_releaseapplock.
/// Outside TRY: ERROR + DONEINPROC 224 with the error bit, and the
/// procedure goes on (193, return -999). Under TRY both modules complete
/// with a plain 224 and the CATCH runs (captured: gaps-applock #042).
fn Session::xp_userlock_error(
  self : Session,
  number : Int,
  state : Int,
  message : String,
  t193 : () -> Unit,
) -> Int raise {
  self.rt.error = number
  if self.try_depth > 0 {
    let e = @types.sql_error(number, message, state~)
    self.module_done(error=false)
    self.rt.nest_level -= 1
    self.module_done(error=false)
    // exec_applock_proc's errdefer decrements nest_level again
    self.rt.nest_level += 1
    raise Caught(e, 1, Some("sys.xp_userlock"), max_nest_level + 1)
  }
  self.out.push(
    Message({
      number,
      state,
      class: 16,
      message,
      procedure: "xp_userlock",
      line: 1,
    }),
  )
  self.out.push(InProcDone(cmd=224, count=None, error=true))
  t193()
  -999
}

///|
/// The text of an option argument in 15625 messages: NULL prints '(null)'.
fn applock_option_text(v : String?) -> String {
  v.unwrap_or("(null)")
}

///|
fn Session::getapplock(
  self : Session,
  text : (String) -> String?,
  vals : Map[String, @types.Value],
  t193 : () -> Unit,
) -> Int raise {
  let resource = text("@resource")
  t193()
  self.done(192)
  let mode_text = text("@lockmode")
  guard mode_text.bind(applock_mode) is Some((mode_name, mode)) else {
    self.info(
      15625,
      1,
      "Option '\{applock_option_text(mode_text)}' not recognized for '@LockMode' parameter.",
      26,
    )
    self.done(246)
    t193()
    return -999
  }
  t193()
  self.done(192)
  let owner = text("@lockowner")
  guard applock_owner(owner) is Some(transaction_owner) else {
    self.info(
      15625,
      1,
      "Option '\{applock_option_text(owner)}' not recognized for '@LockOwner' parameter.",
      39,
    )
    self.done(246)
    t193()
    return -999
  }
  self.done(192)
  let timeout = match vals.get("@locktimeout") {
    Some(Int(n)) => n
    _ => {
      t193()
      self.lock_timeout
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
  if timeout < -1 {
    return self.xp_userlock_error(
      1227, 2, "An invalid application lock time-out was passed to xp_userlock.",
      t193,
    )
  }
  guard resource is Some(resource) else {
    return self.xp_userlock_error(
      1224, 5, "An invalid application lock resource was passed to xp_userlock.",
      t193,
    )
  }
  let resource = applock_truncate(resource)
  guard text("@dbprincipal") is Some(principal) else {
    return self.xp_userlock_error(
      1230, 1, "An invalid database principal was passed to xp_userlock.", t193,
    )
  }
  if !applock_principal_known(principal) {
    return self.xp_userlock_error(
      1202,
      1,
      "The database-principal '\{principal}' does not exist or user is not a member.",
      t193,
    )
  }
  let principal = rtrim_spaces(principal).to_lower()
  let res = self.applock_resource(principal, resource)
  let key = applock_key(transaction_owner, principal, resource)
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
        l.mode = applock_union(l.mode, mode_name)
      }
      None => self.applocks[key] = { mode: mode_name, count: 1, }
    }
  }
  self.done(224)
  t193()
  status
}

///|
/// The mode an application lock holds after another request on it: the
/// union of the requests, kept until the last release (captured:
/// gaps-applock #074-#099). Shared-ness (none < Shared < Update) and
/// IntentExclusive combine and Exclusive wins: Shared + IntentExclusive is
/// SharedIntentExclusive; Update + IntentExclusive (also
/// SharedIntentExclusive + Update) is UpdateIntentExclusive.
fn applock_union(held : String, requested : String) -> String {
  let parts = (m : String) => {
    match m {
      "IntentShared" => (0, false, false)
      "Shared" => (1, false, false)
      "Update" => (2, false, false)
      "IntentExclusive" => (0, true, false)
      "SharedIntentExclusive" => (1, true, false)
      "UpdateIntentExclusive" => (2, true, false)
      _ => (0, false, true)
    }
  }
  let (s1, ix1, x1) = parts(held)
  let (s2, ix2, x2) = parts(requested)
  if x1 || x2 {
    return "Exclusive"
  }
  let s = if s1 > s2 { s1 } else { s2 }
  match (s, ix1 || ix2) {
    (0, false) => "IntentShared"
    (1, false) => "Shared"
    (2, false) => "Update"
    (0, true) => "IntentExclusive"
    (1, true) => "SharedIntentExclusive"
    _ => "UpdateIntentExclusive"
  }
}

///|
fn Session::releaseapplock(
  self : Session,
  text : (String) -> String?,
  t193 : () -> Unit,
) -> Int raise {
  let resource = text("@resource")
  t193()
  self.done(192)
  let owner = text("@lockowner")
  guard applock_owner(owner) is Some(transaction_owner) else {
    self.info(
      15625,
      1,
      "Option '\{applock_option_text(owner)}' not recognized for '@LockOwner' parameter.",
      20,
    )
    self.done(246)
    t193()
    return -999
  }
  t193()
  guard resource is Some(resource) else {
    return self.xp_userlock_error(
      1224, 5, "An invalid application lock resource was passed to xp_userlock.",
      t193,
    )
  }
  let resource = applock_truncate(resource)
  guard text("@dbprincipal") is Some(principal) else {
    return self.xp_userlock_error(
      1230, 1, "An invalid database principal was passed to xp_userlock.", t193,
    )
  }
  // 3918 comes before an unknown principal (corpus stmts/applock-validation)
  if transaction_owner && self.rt.trancount == 0 {
    return self.xp_userlock_error(
      3918, 1, "The statement or function must be executed in the context of a user transaction.",
      t193,
    )
  }
  if !applock_principal_known(principal) {
    return self.xp_userlock_error(
      1202,
      1,
      "The database-principal '\{principal}' does not exist or user is not a member.",
      t193,
    )
  }
  let lower = rtrim_spaces(principal).to_lower()
  let key = applock_key(transaction_owner, lower, resource)
  match self.applocks.get(key) {
    Some(l) => {
      l.count -= 1
      if l.count == 0 {
        self.applocks.remove(key)
        self.server.wake_all(
          self.server.locks.release_resource(
            self.rt.spid,
            self.applock_resource(lower, resource),
          ),
        )
      }
      self.done(224)
      t193()
      0
    }
    None =>
      self.xp_userlock_error(
        1223,
        1,
        "Cannot release the application lock (Database Principal: '\{principal}', Resource: '\{resource}') because it is not currently held.",
        t193,
      )
  }
}

///|
/// APPLOCK_MODE(principal, resource, owner) / APPLOCK_TEST(principal,
/// resource, mode, owner). Run-time checks, in order (captured:
/// gaps-applock #049-#066): NULL principal 1230 state 3, unknown principal
/// 1202, NULL resource 1225 state 1 (the message says "mode"), for
/// APPLOCK_TEST a NULL mode 1225 state 2 and an invalid one 1225 state 3,
/// invalid owner 1226, Transaction owner (also NULL) outside a transaction
/// 3918 state 2. NULL literals and non-string arguments are compile-time
/// 8116 (bind/functions_catalog.mbt).
fn Session::applock_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? raise @types.SqlError {
  let text = (k : Int) => {
    match args.get(k) {
      Some(String(s)) => Some(s)
      _ => None
    }
  }
  let fname = name.to_lower()
  let is_test = name == "APPLOCK_TEST"
  guard name == "APPLOCK_MODE" || is_test else { return None }
  guard text(0) is Some(principal) else {
    raise @types.sql_error(
      1230,
      "An invalid database principal was passed to \{fname}.",
      state=3,
    )
  }
  if !applock_principal_known(principal) {
    raise @types.sql_error(
      1202,
      "The database-principal '\{principal}' does not exist or user is not a member.",
    )
  }
  guard text(1) is Some(resource) else {
    raise @types.sql_error(
      1225,
      "An invalid application lock mode was passed to \{fname}.",
    )
  }
  let resource = applock_truncate(resource)
  let mut mode : @sched.LockMode = S
  if is_test {
    guard text(2) is Some(m) else {
      raise @types.sql_error(
        1225,
        "An invalid application lock mode was passed to \{fname}.",
        state=2,
      )
    }
    guard applock_mode(m) is Some((_, lm)) else {
      raise @types.sql_error(
        1225,
        "An invalid application lock mode was passed to \{fname}.",
        state=3,
      )
    }
    mode = lm
  }
  let owner = text(if is_test { 3 } else { 2 })
  let transaction_owner = match owner {
    None => true
    Some(_) =>
      match applock_owner(owner) {
        Some(t) => t
        None =>
          raise @types.sql_error(
            1226,
            "An invalid application lock owner was passed to \{fname}.",
          )
      }
  }
  if transaction_owner && self.rt.trancount == 0 {
    raise @types.sql_error(
      3918,
      "The statement or function must be executed in the context of a user transaction.",
      state=2,
    )
  }
  let principal = rtrim_spaces(principal).to_lower()
  if is_test {
    let ok = self.server.locks.can_grant(
      self.rt.spid,
      self.applock_resource(principal, resource),
      mode,
    )
    return Some(Int(if ok { 1 } else { 0 }))
  }
  Some(
    String(
      match
        self.applocks.get(applock_key(transaction_owner, principal, resource)) {
        Some(l) => l.mode
        None => "NoLock"
      },
    ),
  )
}
