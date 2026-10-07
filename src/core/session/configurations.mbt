///|
const REST_CONFIGURATION : Int = 16402

///|
const MASTER_SCOPE : Int = 101

///|
fn configuration_int(v : @types.Value) -> Int {
  match v {
    Variant(Int(n), Int) | Int(n) => n
    _ => abort("configuration seed type")
  }
}

///|
fn Session::configuration_values(
  self : Session,
  seed : Array[@types.Value],
) -> (Int, Int) {
  self
  .db_of(MASTER_SCOPE)
  .configuration(configuration_int(seed[0]))
  .unwrap_or((configuration_int(seed[2]), configuration_int(seed[5])))
}

///|
fn Session::rest_enabled(self : Session) -> Bool {
  self
  .db_of(MASTER_SCOPE)
  .configuration(REST_CONFIGURATION)
  .map(v => v.1 == 1)
  .unwrap_or(false)
}

///|
fn Session::reconfigure(self : Session) -> Unit raise {
  self.cur_cmd = 220
  if self.rt.trancount > 0 {
    raise @types.sql_error(
      574,
      "CONFIG statement cannot be used inside a user transaction.",
      state=0,
    )
  }
  self.configuration_lock(REST_CONFIGURATION, X)
  let db = self.db_of(MASTER_SCOPE)
  let value = db.configuration(REST_CONFIGURATION).unwrap_or((0, 0)).0
  self.write(
    MASTER_SCOPE,
    db.set_configuration(REST_CONFIGURATION, value, value),
  )
  self.rt.rowcount = 0
  self.done(220)
}

///|
fn Session::exec_sp_configure(
  self : Session,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let names = ["@configname", "@configvalue"]
  if !self.check_proc_args(
      "sp_configure",
      sysproc_params(names.map(n => (n, true))),
      args,
    ) {
    return
  }
  let vals = self.xprop_args(names, args)
  let finish = (status : Int) => {
    if return_var is Some(rv) &&
      self.frame().vars.get(rv.to_lower()) is Some(info) {
      self.frame().values[info.slot] = @types.cast(Int(status), Int, info.ty)
    }
    self.proc_done(status)
  }
  let failure = (error : @types.SqlError, line : Int) => {
    if self.try_depth > 0 {
      self.rt.error = error.number()
      self.module_done(error=false)
      raise Caught(error, line, Some("sp_configure"), max_nest_level + 1)
    }
    self.message(error, line, procedure=Some("sp_configure"))
    self.out.push(InProcDone(cmd=246, count=None, error=true))
    self.rt.error = 0
    finish(1)
  }
  guard sysproc_text(vals.get("@configname").map(p => p.0)) is Some(name) else {
    raise @types.not_supported("sp_configure without an option name")
  }
  let matches = seed_configurations.filter(row => {
    row[1] is String(s) && s.to_lower().has_prefix(name.to_lower())
  })
  if matches.is_empty() {
    failure(
      @types.sql_error(
        15123,
        "The configuration option '\{name}' does not exist, or it may be an advanced option.",
      ),
      62,
    )
    return
  }
  if matches.length() != 1 {
    raise @types.not_supported("ambiguous sp_configure option")
  }
  let seed = matches[0]
  let id = configuration_int(seed[0])
  if id != REST_CONFIGURATION {
    raise @types.not_supported("sp_configure option '\{name}'")
  }
  let canonical = "external rest endpoint enabled"
  let value = match vals.get("@configvalue") {
    None | Some((Null, _)) => None
    Some((v, ty)) => Some(configuration_int(@types.cast(v, ty, Int)))
  }
  if value is Some(_) {
    self.configuration_lock(id, X)
  }
  let current = self.configuration_values(seed)
  match value {
    None => {
      for line in [43, 81] {
        match self.configuration_read(seed) {
          Ok(_) => ()
          Err(e) => self.configuration_read_error(e, line)
        }
      }
      self.out.push(
        ResultSet([
          spc("name", nvc(35), 8),
          spc("minimum", Int, 33),
          spc("maximum", Int, 33),
          spc("config_value", Int, 33),
          spc("run_value", Int, 33),
        ]),
      )
      match self.configuration_read(seed) {
        Ok(v) => {
          self.out.push(
            Row([
              Text(canonical),
              Int(0),
              Int(1),
              Int(v.0.to_int64()),
              Int(v.1.to_int64()),
            ]),
          )
          self.out.push(InProcDone(cmd=193, count=None, error=false))
        }
        Err(e) => self.configuration_read_error(e, 90)
      }
    }
    Some(n) if n < 0 || n > 1 => {
      failure(
        @types.sql_error(
          15129,
          "'\{n}' is not a valid value for configuration option '\{canonical}'.",
        ),
        172,
      )
      return
    }
    Some(n) => {
      self.write(
        MASTER_SCOPE,
        self.db_of(MASTER_SCOPE).set_configuration(id, n, current.1),
      )
      self.info(
        15457,
        1,
        "Configuration option '\{canonical}' changed from \{current.0} to \{n}. Run the RECONFIGURE statement to install.",
        196,
      )
    }
  }
  self.rt.rowcount = 1
  finish(0)
}

///|
/// Separate lock namespace from user tables and application locks (-1).
/// Catalog reads lock even under NOLOCK/READ UNCOMMITTED.
fn Session::configuration_lock(
  self : Session,
  id : Int,
  mode : @sched.LockMode,
) -> Unit raise @types.SqlError {
  let cmd = self.cur_cmd
  self.cur_cmd = 193 // catalog timeout has no extra DML termination message
  defer {
    self.cur_cmd = cmd
  }
  let key : LockKey = { values: [Int(id)], colls: [None], }
  self.acquire(
    Key(table=-2, index=0, key),
    mode,
    if mode is X {
      Transaction
    } else {
      Statement
    },
  ) catch {
    Park => raise @types.Suspend
    @types.SqlError(..) as e => raise e
    _ => abort("unexpected configuration lock control")
  }
}

///|
fn Session::configuration_scan_row(
  self : Session,
  scope : Int,
  id : Int,
  row : Int64,
) -> Unit raise @types.SqlError {
  if scope != 2 || id < 0 {
    return
  }
  let v = view_defs[id % TEMPDB_VIEW_OFFSET]
  if v.schema != "sys" || v.name != "configurations" {
    return
  }
  self.configuration_lock(
    configuration_int(seed_configurations[row.to_int()][0]),
    S,
  )
}

///|
/// Completed procedure reads survive request replay. A later read may wait
/// independently; replay must neither wait again nor lose an earlier error.
fn Session::configuration_read(
  self : Session,
  seed : Array[@types.Value],
) -> Result[(Int, Int), @types.SqlError] raise @types.SqlError {
  let index = self.configuration_reads_seen
  self.configuration_reads_seen += 1
  if self.configuration_reads.get(index) is Some(result) {
    return result
  }
  let result = try {
    self.configuration_lock(configuration_int(seed[0]), S)
    Ok(self.configuration_values(seed))
  } catch {
    @types.SqlError(number=1222, ..) as e => Err(e)
    e => raise e
  }
  self.configuration_reads.push(result)
  result
}

///|
fn Session::configuration_read_error(
  self : Session,
  error : @types.SqlError,
  line : Int,
) -> Unit raise {
  if self.try_depth > 0 {
    self.module_done(error=false)
    raise Caught(error, line, Some("sp_configure"), max_nest_level + 1)
  }
  self.message(error, line, procedure=Some("sp_configure"))
  self.out.push(InProcDone(cmd=193, count=None, error=true))
}
