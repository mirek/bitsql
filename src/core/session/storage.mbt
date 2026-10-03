///|
/// Current database view for a scope: 0 = user database (transaction view
/// or last committed), 1 = session temp database.
fn Session::db_of(self : Session, scope : Int) -> @store.Db {
  if scope == 1 {
    self.temp
  } else {
    match self.tx {
      Some((_, view)) => view
      None => self.server.db
    }
  }
}

///|
/// Applies a database write for a scope (autocommit or into the transaction).
fn Session::write(self : Session, scope : Int, db : @store.Db) -> Unit {
  if scope == 1 {
    self.temp = db
  } else {
    match self.tx {
      Some((base, _)) => self.tx = Some((base, db))
      None => self.server.db = db
    }
  }
}

///|
/// Begins an explicit transaction (outermost BEGIN TRAN).
fn Session::begin_tx(self : Session) -> Unit {
  if self.tx is None {
    self.tx = Some((self.server.db, self.server.db))
  }
}

///|
/// Commits the outermost transaction. Concurrent commits that would require
/// merging are not supported yet (phase 6: lock manager + write log).
fn Session::commit_tx(self : Session) -> Unit raise @types.SqlError {
  match self.tx {
    Some((base, view)) => {
      if !physical_equal(base, self.server.db) && !physical_equal(base, view) {
        self.tx = None
        raise @types.emulator_error(
          50107, "Emulator: concurrent transactions writing the same database are not supported yet",
        )
      }
      self.server.db = view
      self.tx = None
    }
    None => ()
  }
}

///|
fn Session::rollback_tx(self : Session) -> Unit {
  self.tx = None
}

///|
fn table_columns(t : @store.Table) -> Array[@bind.ColumnRef] {
  t.columns.map(c => @bind.ColumnRef::{
    qualifier: t.name.to_lower(),
    name: c.name,
    ty: c.ty,
    nullable: c.nullable,
    origin: BaseColumn(identity=c.identity is Some(_)),
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
      Some(id) => return self.temp.table(id)
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
      match self.find_table(name) {
        Some((scope, t)) =>
          Some({
            scope,
            id: t.id,
            schema: t.schema,
            name: t.name,
            columns: table_columns(t),
          })
        None => None
      }
    },
    table_var: name => {
      match self.find_table_var(name) {
        Some(t) =>
          Some({
            scope: 1,
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
/// Transaction descriptor sent in BEGIN/COMMIT/ROLLBACK ENVCHANGE tokens.
fn Session::tx_descriptor(self : Session) -> UInt64 {
  (self.rt.spid.to_int64() << 32).reinterpret_as_uint64() | 1UL
}
