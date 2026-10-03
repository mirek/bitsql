///|
/// An explicit transaction: the committed state it started from, its private
/// view including its own writes, the temp database at BEGIN (temp tables
/// roll back; table variables do not) and named savepoints.
priv struct Tx {
  database : String
  base : @store.Db
  mut view : @store.Db
  temp_at_begin : @store.Db
  savepoints : Map[String, (@store.Db, @store.Db)]
}

///|
/// Current database for a scope: 0 = user database (transaction view or last
/// committed), 1 = session temp database (#tables), 3 = table variables.
fn Session::db_of(self : Session, scope : Int) -> @store.Db {
  match scope {
    1 => self.temp
    3 => self.tvars
    _ =>
      match self.tx {
        Some(tx) if tx.database == self.rt.database.to_lower() => tx.view
        _ => self.server.get_db(self.rt.database)
      }
  }
}

///|
/// Rows of a bound table source: scope 2 are the virtual catalog views.
fn Session::source(
  self : Session,
  scope : Int,
  id : Int,
) -> Array[(Int64, Array[@types.Value])] {
  if scope == 2 {
    self.sys_view_rows(id)
  } else {
    self.db_of(scope).rows(id)
  }
}

///|
/// Applies a database write for a scope (autocommit or into the transaction).
fn Session::write(self : Session, scope : Int, db : @store.Db) -> Unit {
  match scope {
    1 => self.temp = db
    3 => self.tvars = db
    _ =>
      match self.tx {
        Some(tx) if tx.database == self.rt.database.to_lower() => tx.view = db
        _ => self.server.set_db(self.rt.database, db)
      }
  }
}

///|
/// Begins an explicit transaction (outermost BEGIN TRAN).
fn Session::begin_tx(self : Session) -> Unit {
  if self.tx is None {
    let db = self.server.get_db(self.rt.database)
    self.tx = Some({
      database: self.rt.database.to_lower(),
      base: db,
      view: db,
      temp_at_begin: self.temp,
      savepoints: Map([]),
    })
  }
}

///|
/// Commits the outermost transaction. Concurrent commits that would require
/// merging are not supported yet (phase 6: lock manager + write log).
fn Session::commit_tx(self : Session) -> Unit raise @types.SqlError {
  match self.tx {
    Some(tx) => {
      let current = self.server.get_db(tx.database)
      if !physical_equal(tx.base, current) && !physical_equal(tx.base, tx.view) {
        self.tx = None
        raise @types.emulator_error(
          50107, "Emulator: concurrent transactions writing the same database are not supported yet",
        )
      }
      self.server.set_db(tx.database, tx.view)
      self.tx = None
    }
    None => ()
  }
  self.implicit_tx = false
  self.release_locks()
}

///|
fn Session::rollback_tx(self : Session) -> Unit {
  match self.tx {
    Some(tx) => self.temp = tx.temp_at_begin
    None => ()
  }
  self.tx = None
  self.implicit_tx = false
  self.release_locks()
}

///|
fn table_columns(t : @store.Table) -> Array[@bind.ColumnRef] {
  t.columns.map(c => @bind.ColumnRef::{
    qualifier: t.name.to_lower(),
    name: c.name,
    ty: c.ty,
    nullable: c.nullable,
    origin: if c.computed is Some(_) {
      Computed
    } else {
      BaseColumn(identity=c.identity is Some(_))
    },
  })
}

///|
/// Splits a (possibly qualified) object name into (schema, name); temp
/// tables keep their '#' prefix.
fn split_name(name : @ast.ObjectName) -> (String, String) {
  let n = name.parts.length()
  let base = name.parts[n - 1].name
  let schema = if n >= 2 { name.parts[n - 2].name } else { "dbo" }
  (schema, base)
}

///|
/// Finds a table: '#temp' names in the session temp database, others in the
/// user database. Returns (scope, table).
fn Session::find_table(
  self : Session,
  name : @ast.ObjectName,
) -> (Int, @store.Table)? {
  let (schema, base) = split_name(name)
  if base.has_prefix("#") {
    match self.temp.lookup("dbo", base) {
      Some(id) => self.temp.table(id).map(t => (1, t))
      None => None
    }
  } else {
    let db = self.db_of(0)
    match db.lookup(schema, base) {
      Some(id) => db.table(id).map(t => (0, t))
      None => None
    }
  }
}

///|
fn Session::find_table_var(self : Session, name : String) -> @store.Table? {
  let key = name.to_lower()
  let mut i = self.frames.length() - 1
  while i >= 0 {
    match self.frames[i].tables.get(key) {
      Some(id) => return self.tvars.table(id)
      None => ()
    }
    i -= 1
  }
  None
}

///|
fn Session::catalog(self : Session) -> @bind.Catalog {
  {
    table: name => {
      match self.pseudo_binding(name) {
        Some(b) => return Some(b)
        None => ()
      }
      match self.sys_view_binding(name) {
        Some(b) => return Some(b)
        None => ()
      }
      match self.find_table(name) {
        Some((scope, t)) =>
          Some({
            scope,
            id: t.id,
            schema: t.schema,
            name: t.name,
            columns: table_columns(t),
          })
        None =>
          match self.find_module(name) {
            Some(m) if m.kind is (InlineFunction | TableFunction) =>
              raise @types.not_supported("table-valued functions")
            _ => None
          }
      }
    },
    view: name => {
      if name.base().has_prefix("#") {
        return None
      }
      match self.find_module(name) {
        Some(m) if m.kind is View => Some(view_query(m))
        _ => None
      }
    },
    table_var: name => {
      match self.find_table_var(name) {
        Some(t) =>
          Some({
            scope: 3,
            id: t.id,
            schema: "dbo",
            name,
            columns: table_columns(t),
          })
        None => None
      }
    },
  }
}

///|
/// Finds a view, procedure, function or trigger in the user database.
fn Session::find_module(
  self : Session,
  name : @ast.ObjectName,
) -> @store.Module? {
  let (schema, base) = split_name(name)
  let db = self.db_of(0)
  match db.lookup(schema, base) {
    Some(id) => db.get_module(id)
    None => None
  }
}

///|
/// Transaction descriptor sent in BEGIN/COMMIT/ROLLBACK ENVCHANGE tokens.
fn Session::tx_descriptor(self : Session) -> UInt64 {
  (self.rt.spid.to_int64() << 32).reinterpret_as_uint64() | 1UL
}

///|
/// 3930: writes and COMMIT are rejected in an uncommittable transaction.
fn doomed_error() -> @types.SqlError {
  @types.sql_error(
    3930, "The current transaction cannot be committed and cannot support operations that write to the log file. Roll back the transaction.",
  )
}

///|
/// Rolls back the whole transaction after an uncaught error under
/// XACT_ABORT ON (or a doomed transaction at batch end).
fn Session::abort_transaction(self : Session) -> Unit {
  if self.rt.trancount > 0 {
    let d = self.tx_descriptor()
    self.rollback_tx()
    self.rt.trancount = 0
    self.rt.xact_state = 0
    self.out.push(EnvChange(RollbackTransaction(d)))
  }
}

///|
/// Savepoint name of ROLLBACK/SAVE (identifier or variable); None for the
/// whole transaction.
fn Session::savepoint_name(self : Session, name : @ast.Expr?) -> String? raise {
  match name {
    None => None
    Some({ kind: Column([id]), .. }) => Some(id.name)
    Some(e) =>
      match self.eval(e) {
        (String(s), _) => Some(s)
        _ => None
      }
  }
}

///|
/// Raises 3930 when the transaction is uncommittable (called before writes).
fn Session::check_writable(self : Session) -> Unit raise @types.SqlError {
  if self.rt.xact_state == -1 {
    raise doomed_error()
  }
}

///|
/// The query of a stored view, re-parsed from its definition.
fn view_query(
  m : @store.Module,
) -> (@ast.Query, Array[@ast.Ident]) raise @types.SqlError {
  let stmts = @parse.parse_batch(m.definition) catch {
    _ =>
      raise @types.not_supported("view \{m.name} (definition does not parse)")
  }
  for s in stmts {
    if s.kind is CreateView(v) {
      return (v.query, v.columns)
    }
  }
  raise @types.not_supported("view \{m.name} (no CREATE VIEW in definition)")
}
