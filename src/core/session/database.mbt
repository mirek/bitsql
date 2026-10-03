///|
/// CREATE DATABASE (CurCmd 203), DROP DATABASE (204), USE: captured in
/// harness/corpus/database.
fn Session::exec_create_database(
  self : Session,
  name : @ast.Ident,
) -> Unit raise {
  self.cur_cmd = 203
  if self.rt.trancount > 0 {
    raise @types.sql_error(
      226, "CREATE DATABASE statement not allowed within multi-statement transaction.",
    )
  }
  if self.server.has_database(name.name) {
    raise @types.sql_error(
      1801,
      "Database '\{name.name}' already exists. Choose a different database name.",
      state=3,
    )
  }
  self.server.set_db(name.name, @store.Db::empty())
  self.server.db_names[name.name.to_lower()] = name.name
  self.done(203)
}

///|
fn Session::exec_drop_database(
  self : Session,
  if_exists : Bool,
  names : Array[@ast.ObjectName],
) -> Unit raise {
  self.cur_cmd = 204
  for n in names {
    let name = n.base()
    let key = name.to_lower()
    if !self.server.has_database(name) {
      if if_exists {
        continue
      }
      raise @types.sql_error(
        3701,
        "Cannot drop the database '\{name}', because it does not exist or you do not have permission.",
        severity=11,
      )
    }
    if key == "master" || key == "tempdb" || key == "model" || key == "msdb" {
      raise @types.sql_error(
        3708,
        "Cannot drop the database '\{name}' because it is a system database.",
      )
    }
    if key == self.rt.database.to_lower() {
      raise @types.sql_error(
        3702,
        "Cannot drop database \"\{name}\" because it is currently in use.",
        state=4,
      )
    }
    self.server.dbs.remove(key)
    self.server.db_names.remove(key)
  }
  self.done(204)
}

///|
fn Session::exec_use(self : Session, name : @ast.Ident) -> Unit raise {
  match self.server.db_names.get(name.name.to_lower()) {
    None =>
      raise @types.sql_error(
        911,
        "Database '\{name.name}' does not exist. Make sure that the name is entered correctly.",
      )
    Some(display) => {
      let old = self.rt.database
      self.rt.database = display
      self.out.push(EnvChange(Database(display, old)))
      self.info(5701, 1, "Changed database context to '\{display}'.", 1)
      // CurCmd of USE is unverified (no capture yet)
      self.done(193)
    }
  }
}

///|
/// `EXEC emulator.snapshot 'name'` / `EXEC emulator.restore 'name'`:
/// O(1) test isolation (design: storage-concurrency). Snapshots cover every
/// database, identity counters, @@DBTS and procedures; sessions' temp tables
/// are untouched. Returns true when `name` is an emulator procedure.
fn Session::exec_emulator_proc(
  self : Session,
  proc : String,
  args : Array[@ast.ExecArg],
) -> Bool raise {
  let op = proc.to_lower()
  if op != "snapshot" && op != "restore" && op != "drop_snapshot" {
    return false
  }
  if self.rt.trancount > 0 {
    raise @types.emulator_error(
      50108,
      "Emulator: emulator.\{op} cannot run inside a transaction",
    )
  }
  let name = match args.get(0) {
    Some(a) =>
      match self.eval(a.value) {
        (String(s), _) => s
        _ => "default"
      }
    None => "default"
  }
  match op {
    "snapshot" => {
      let dbs = Map([])
      for k, v in self.server.dbs {
        dbs[k] = v
      }
      let names = Map([])
      for k, v in self.server.db_names {
        names[k] = v
      }
      let idents = Map([])
      for k, v in self.server.idents {
        idents[k] = v
      }
      let procs = Map([])
      for k, v in self.server.procs {
        procs[k] = v
      }
      self.server.snapshots[name] = {
        dbs,
        db_names: names,
        idents,
        dbts: self.server.dbts,
        procs,
      }
    }
    "restore" =>
      match self.server.snapshots.get(name) {
        Some(s) => {
          self.server.dbs.clear()
          for k, v in s.dbs {
            self.server.dbs[k] = v
          }
          self.server.db_names.clear()
          for k, v in s.db_names {
            self.server.db_names[k] = v
          }
          self.server.idents.clear()
          for k, v in s.idents {
            self.server.idents[k] = v
          }
          self.server.procs.clear()
          for k, v in s.procs {
            self.server.procs[k] = v
          }
          self.server.dbts = s.dbts
        }
        None =>
          raise @types.emulator_error(
            50109,
            "Emulator: no snapshot named '\{name}'",
          )
      }
    _ => self.server.snapshots.remove(name)
  }
  self.proc_done(0)
  true
}
