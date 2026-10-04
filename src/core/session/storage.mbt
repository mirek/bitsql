///|
/// An explicit transaction: the committed state it started from, its private
/// view including its own writes, the temp database at BEGIN (temp tables
/// roll back; table variables do not) and named savepoints.
priv struct Tx {
  database : String
  base : @store.Db
  mut view : @store.Db
  temp_at_begin : @store.Db
  /// Savepoints, innermost last: (name, view, temp database).
  savepoints : Array[(String, @store.Db, @store.Db)]
  /// Name of the outermost BEGIN TRANSACTION (matched case-sensitively).
  name : String?
}

///|
/// The innermost savepoint named `name` under the database collation
/// (CI_AS here: 'casename' finds CaseName; trailing spaces are ignored).
/// An empty name never matches (captured: 6401 state 2).
fn Tx::savepoint_index(self : Tx, name : String) -> Int? {
  if name == "" {
    return None
  }
  for i = self.savepoints.length() - 1; i >= 0; i = i - 1 {
    if @types.compare_strings(
        self.savepoints[i].0,
        name,
        @types.default_collation,
      ) ==
      0 {
      return Some(i)
    }
  }
  None
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
fn Session::begin_tx(self : Session, name? : String? = None) -> Unit {
  if self.tx is None {
    let db = self.server.get_db(self.rt.database)
    self.tx = Some({
      database: self.rt.database.to_lower(),
      base: db,
      view: db,
      temp_at_begin: self.temp,
      savepoints: [],
      name,
    })
  }
}

///|
/// READ COMMITTED and stronger lock-based levels see other sessions' commits
/// at each statement: the transaction's changes are re-applied onto the
/// newest committed state (SNAPSHOT keeps its start state).
fn Session::refresh_tx(self : Session) -> Unit {
  guard self.tx is Some(tx) && self.isolation != "SNAPSHOT" else { return }
  let current = self.server.get_db(tx.database)
  if physical_equal(tx.base, current) {
    return
  }
  guard tx.view.rebase(tx.base, current) is Some(view) else { return }
  let savepoints = []
  for sp in tx.savepoints {
    match sp.1.rebase(tx.base, current) {
      Some(v) => savepoints.push((sp.0, v, sp.2))
      None => return
    }
  }
  self.tx = Some({ ..tx, base: current, view, savepoints, })
}

///|
/// Commits the outermost transaction: its changes are re-applied onto the
/// newest committed state (Db::rebase; locks keep writers apart).
fn Session::commit_tx(self : Session) -> Unit raise @types.SqlError {
  match self.tx {
    Some(tx) => {
      let current = self.server.get_db(tx.database)
      match tx.view.rebase(tx.base, current) {
        Some(db) => self.server.set_db(tx.database, db)
        None => {
          self.tx = None
          self.release_locks()
          raise @types.emulator_error(
            50107, "Emulator: a concurrent transaction changed the same rows or objects without a lock conflict (not supported)",
          )
        }
      }
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
      TableComputed
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
      let real = self.deref_synonym(name)
      match self.find_table(real) {
        Some((scope, t)) => {
          // through a synonym, columns are qualified by the synonym's name
          let shown = if physical_equal(real, name) {
            t.name
          } else {
            name.base()
          }
          Some({
            scope,
            id: t.id,
            schema: t.schema,
            name: shown,
            columns: table_columns(t).map(c => {
              ..c,
              qualifier: shown.to_lower(),
              // SET IDENTITY_INSERT ON makes the identity column updateable
              // in result metadata
              origin: if c.origin is BaseColumn(identity=true) &&
                self.identity_insert == Some(t.id) {
                InsertableIdentity
              } else {
                c.origin
              },
            }),
          })
        }
        None =>
          match self.find_module(name) {
            // a table-valued function without its argument list (captured
            // 216; line: udf_error_line)
            Some(m) if m.kind is (InlineFunction | TableFunction) =>
              raise @types.sql_error(
                216,
                "Parameters were not supplied for the function '\{object_text(name)}'.",
              )
            _ => None
          }
      }
    },
    view: name => {
      if name.base().has_prefix("#") {
        return None
      }
      match self.find_module(self.deref_synonym(name)) {
        Some(m) if m.kind is View => Some(view_query(m))
        _ => None
      }
    },
    function: name => self.find_function(self.deref_synonym(name)),
    user_type: tn => self.find_user_type(tn) is Some(_),
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
    sequence: name => self.sequence_binding(name),
    system_tvf: (name, args) => self.system_tvf(name, args),
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
    // the implicit transaction of a trigger's statement ends silently
    // (captured: gaps-triggers #029, #037)
    let implicit = self.implicit_tx
    self.rollback_tx()
    self.rt.trancount = 0
    self.rt.xact_state = 0
    if !implicit {
      self.out.push(EnvChange(RollbackTransaction(d)))
    }
  }
}

///|
/// Transaction or savepoint name of BEGIN/ROLLBACK/SAVE (identifier or
/// variable); None without a name or for a NULL variable (captured:
/// msduck-runs/savepoint length run): identifiers over 32 characters are
/// 103, variables are cut to 32 and must be character strings (3914).
fn Session::tran_name(self : Session, name : @ast.Expr?) -> String? raise {
  match name {
    None => None
    Some({ kind: Column([id]), .. }) => {
      if id.name.length() > 32 {
        self.cur_cmd = 253
        raise @types.sql_error(
          103,
          "The identifier that starts with '\{id.name}' is too long. Maximum length is 32.",
          state=2,
          severity=15,
        )
      }
      Some(id.name)
    }
    Some(e) => {
      let (v, ty) = self.eval(e)
      guard ty is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _)) else {
        raise @types.sql_error(
          3914,
          "The data type \"\{ty.base_name()}\" is invalid for transaction names or savepoint names. Allowed data types are char, varchar, nchar, varchar(max), nvarchar, and nvarchar(max).",
          state=0,
        )
      }
      match v {
        String(s) if s.length() > 32 =>
          Some(s.unsafe_substring(start=0, end=32))
        String(s) => Some(s)
        _ => None
      }
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

///|
/// Unique-index lookup for the executor (`@exec.Ctx::seek`): the row whose
/// unique, unfiltered index columns equal `key`, or None when no such index
/// is fully covered by `key`.
fn Session::seek(
  self : Session,
  scope : Int,
  id : Int,
  key : Array[(Int, @types.Value)],
) -> Array[(Int64, Array[@types.Value])]? {
  if scope == 2 {
    return None
  }
  let db = self.db_of(scope)
  guard db.table(id) is Some(t) else { return None }
  for i, ix in t.indexes {
    if !ix.unique || ix.filter is Some(_) {
      continue
    }
    let vals = []
    for c in ix.columns {
      match key.search_by(k => k.0 == c.0) {
        Some(j) => vals.push(key[j].1)
        None => break
      }
    }
    if vals.length() == ix.columns.length() {
      return Some(
        match db.find_key(id, i, vals) {
          Some(rowid) =>
            match db.row(id, rowid) {
              Some(r) => [(rowid, r)]
              None => []
            }
          None => []
        },
      )
    }
  }
  None
}
