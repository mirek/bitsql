///|
/// One database's part of a transaction: the committed state it joined
/// from and its private view including the transaction's own writes.
priv struct TxPart {
  mut base : @store.Db
  mut view : @store.Db
}

///|
/// An explicit transaction: a part per database it touched (a transaction
/// spans databases as in SQL Server: one ROLLBACK undoes the writes to all
/// of them), the temp database at BEGIN (temp tables roll back; table
/// variables do not) and named savepoints.
priv struct Tx {
  /// Lowercased database name → part; a database joins at first use.
  parts : Map[String, TxPart]
  temp_at_begin : @store.Db
  /// Savepoints, innermost last: (name, views, temp database).
  savepoints : Array[(String, Map[String, @store.Db], @store.Db)]
  /// Name of the outermost BEGIN TRANSACTION (matched case-sensitively).
  name : String?
}

///|
fn Tx::new(
  database : String,
  base : @store.Db,
  view : @store.Db,
  temp : @store.Db,
  name : String?,
) -> Tx {
  let parts = Map([])
  parts[database.to_lower()] = { base, view, }
  { parts, temp_at_begin: temp, savepoints: [], name, }
}

///|
/// The views of every part (statement and savepoint rollback).
fn Tx::views(self : Tx) -> Map[String, @store.Db] {
  let out = Map([])
  for k, p in self.parts {
    out[k] = p.view
  }
  out
}

///|
/// Rolls the parts back to `views`; a database that joined later goes
/// back to the state it joined from.
fn Tx::restore(self : Tx, views : Map[String, @store.Db]) -> Unit {
  for k, p in self.parts {
    p.view = match views.get(k) {
      Some(v) => v
      None => p.base
    }
  }
}

///|
/// An independent copy (request snapshots).
fn Tx::copy(self : Tx) -> Tx {
  let parts = Map([])
  for k, p in self.parts {
    parts[k] = { base: p.base, view: p.view, }
  }
  { ..self, parts, savepoints: self.savepoints.copy(), }
}

///|
/// The innermost savepoint named `name` under the database collation
/// (CI_AS: 'casename' finds CaseName; trailing spaces are ignored).
/// An empty name never matches (captured: 6401 state 2).
fn Tx::savepoint_index(
  self : Tx,
  name : String,
  collation : @types.Collation,
) -> Int? {
  if name == "" {
    return None
  }
  for i = self.savepoints.length() - 1; i >= 0; i = i - 1 {
    if @types.compare_strings(self.savepoints[i].0, name, collation) == 0 {
      return Some(i)
    }
  }
  None
}

///|
/// Table scopes of database tables in another database than the session's:
/// `OTHER_DB_SCOPE + database_id` (three-part names, `db.schema.t`).
const OTHER_DB_SCOPE : Int = 100

///|
/// A scope of database tables (the session database or another one), as
/// opposed to temp tables, catalog views and table variables.
fn is_db_scope(scope : Int) -> Bool {
  scope == 0 || scope >= OTHER_DB_SCOPE
}

///|
/// Lowercased name of the database behind a table scope (0: the session
/// database; `OTHER_DB_SCOPE + id`: database `id`).
fn Session::scope_key(self : Session, scope : Int) -> String {
  if scope >= OTHER_DB_SCOPE {
    self.server.database_key(scope - OTHER_DB_SCOPE).unwrap_or("")
  } else {
    // db_of runs per scan, seek and statement-cache check: lower-case the
    // current database name once per name (strings are immutable)
    let name = self.rt.database
    match self.db_key_cache {
      Some((seen, key)) if physical_equal(seen, name) => key
      _ => {
        let key = name.to_lower()
        self.db_key_cache = Some((name, key))
        key
      }
    }
  }
}

///|
/// Display name of the database behind a table scope (messages).
fn Session::scope_database(self : Session, scope : Int) -> String {
  match scope {
    1 | 3 => "tempdb"
    _ if scope >= OTHER_DB_SCOPE =>
      self.server.database_name(self.scope_key(scope))
    _ => self.rt.database
  }
}

///|
/// The transaction's part for a database, joining it at first use.
fn Session::tx_part(self : Session, tx : Tx, key : String) -> TxPart {
  match tx.parts.get(key) {
    Some(p) => p
    None => {
      let db = self.server.get_db_key(key)
      let p = { base: db, view: db, }
      tx.parts[key] = p
      p
    }
  }
}

///|
/// Current database for a scope: 0 = user database (transaction view or last
/// committed), 1 = session temp database (#tables), 3 = table variables,
/// `OTHER_DB_SCOPE + id` = another database.
fn Session::db_of(self : Session, scope : Int) -> @store.Db {
  match scope {
    1 => self.temp
    3 => self.tvars
    _ => {
      let key = self.scope_key(scope)
      match self.tx {
        Some(tx) => self.tx_part(tx, key).view
        None => self.server.get_db_key(key)
      }
    }
  }
}

///|
/// Rows of a bound table source: scope 2 are the virtual catalog views.
/// Table rows are materialized once per physical table data (immutable, so
/// an identical `TableData` has identical rows) and shared by later scans;
/// the executor never mutates the returned array.
fn Session::source(
  self : Session,
  scope : Int,
  id : Int,
) -> Array[(Int64, Array[@types.Value])] {
  if scope == 2 {
    return self.sys_view_rows(id)
  }
  let db = self.db_of(scope)
  if db.table(id) is Some(t) {
    let ix = t.indexes
      .search_by(ix => ix.clustered)
      .map(k => t.indexes[k].index_id)
      .unwrap_or(0)
    self.index_access(scope, id, ix, 1)
  }
  guard db.table_data(id) is Some(data) else { return db.rows(id) }
  match self.scans.get((scope, id)) {
    Some((seen, rows)) if physical_equal(seen, data) => rows
    _ => {
      let rows = db.rows(id)
      // bounded: pooled sessions that create and drop many tables must not
      // keep their old data alive
      if self.scans.length() >= 32 {
        self.scans.clear()
      }
      self.scans[(scope, id)] = (data, rows)
      rows
    }
  }
}

///|
/// Applies a database write for a scope (autocommit or into the transaction).
fn Session::write(self : Session, scope : Int, db : @store.Db) -> Unit {
  match scope {
    1 => self.temp = db
    3 => self.tvars = db
    _ => {
      let key = self.scope_key(scope)
      if self.server.db_options(key).read_only {
        self.read_only_write = Some(self.server.database_name(key))
      }
      match self.tx {
        Some(tx) => self.tx_part(tx, key).view = db
        None => self.server.set_db(key, db)
      }
    }
  }
}

///|
/// Begins an explicit transaction (outermost BEGIN TRAN).
fn Session::begin_tx(self : Session, name? : String? = None) -> Unit {
  if self.tx is None {
    let db = self.server.get_db(self.rt.database)
    self.tx = Some(Tx::new(self.rt.database, db, db, self.temp, name))
  }
}

///|
/// READ COMMITTED and stronger lock-based levels see other sessions' commits
/// at each statement: the transaction's changes are re-applied onto the
/// newest committed state (SNAPSHOT keeps its start state).
fn Session::refresh_tx(self : Session) -> Unit {
  guard self.tx is Some(tx) && self.isolation != "SNAPSHOT" else { return }
  for key, part in tx.parts {
    let current = self.server.get_db(key)
    if physical_equal(part.base, current) {
      continue
    }
    guard part.view.rebase(part.base, current) is Some(view) else { return }
    let rebased = []
    for sp in tx.savepoints {
      match sp.1.get(key) {
        Some(v) =>
          match v.rebase(part.base, current) {
            Some(v) => rebased.push(v)
            None => return
          }
        None => rebased.push(part.base)
      }
    }
    for i, sp in tx.savepoints {
      if sp.1.contains(key) {
        sp.1[key] = rebased[i]
      }
    }
    part.base = current
    part.view = view
  }
}

///|
/// Commits the outermost transaction: its changes are re-applied onto the
/// newest committed state of each database (Db::rebase; locks keep writers
/// apart). Nothing is written unless every database rebases.
fn Session::commit_tx(self : Session) -> Unit raise @types.SqlError {
  match self.tx {
    Some(tx) => {
      let merged = []
      for key, part in tx.parts {
        if physical_equal(part.base, part.view) {
          continue
        }
        let current = self.server.get_db(key)
        match part.view.rebase(part.base, current) {
          Some(db) => merged.push((key, db))
          None => {
            self.tx = None
            self.release_locks()
            raise @types.emulator_error(
              50107, "Emulator: a concurrent transaction changed the same rows or objects without a lock conflict (not supported)",
            )
          }
        }
      }
      for m in merged {
        // a database dropped meanwhile stays dropped
        if self.server.has_database(m.0) {
          self.server.set_db(m.0, m.1)
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
    untyped_null: false,
    qualifier: t.name.to_lower(),
    name: c.name,
    ty: c.ty,
    nullable: c.result_nullable,
    origin: if c.computed is Some(_) {
      TableComputed
    } else {
      BaseColumn(identity=c.identity is Some(_))
    },
  })
}

///|
/// Splits a (possibly qualified) object name into (schema, name); temp
/// tables keep their '#' prefix. An empty schema part (`db..t`, TypeORM's
/// `"db".."migrations"`) is the default schema (captured, corpus
/// orm/empty-schema-part).
fn split_name(name : @ast.ObjectName) -> (String, String) {
  let n = name.parts.length()
  let base = name.parts[n - 1].name
  let schema = if n >= 2 && name.parts[n - 2].name != "" {
    name.parts[n - 2].name
  } else {
    "dbo"
  }
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
    // `db.schema.t` names a table of another database (scope
    // OTHER_DB_SCOPE + database_id); a database that does not exist finds
    // nothing (208, captured: corpus database/cross-database)
    guard self.name_scope(name) is Some(scope) else { return None }
    let db = self.db_of(scope)
    match db.lookup(schema, base) {
      // a case- or binary-sensitive database collation also applies to
      // object names (captured: settings/database-collation, OBJECT_ID
      // 'AFTER_ALTER' is NULL under Latin1_General_100_CS_AS)
      Some(id) =>
        match db.table(id) {
          Some(t) if self.same_identifier(t.name, base) => Some((scope, t))
          _ => None
        }
      None => None
    }
  }
}

///|
/// Table scope of the database a (non-temporary) object name designates:
/// 0 for the session database or no database part, `OTHER_DB_SCOPE + id`
/// for another database, None for a database that does not exist.
fn Session::name_scope(self : Session, name : @ast.ObjectName) -> Int? {
  let n = name.parts.length()
  if n < 3 {
    return Some(0)
  }
  let d = name.parts[n - 3].name
  if d == "" || d.to_lower() == self.rt.database.to_lower() {
    return Some(0)
  }
  match self.server.database_id(d) {
    Some(id) => Some(OTHER_DB_SCOPE + id)
    None => None
  }
}

///|
/// Views, functions, procedures, synonyms, sequences and types of another
/// database are not emulated (their bodies would bind in the session's
/// database): raises when `name` designates one, so it is never mistaken
/// for an object of the session database.
fn Session::check_other_db_module(
  self : Session,
  name : @ast.ObjectName,
) -> Unit raise @types.SqlError {
  guard self.name_scope(name) is Some(scope) && scope >= OTHER_DB_SCOPE else {
    return
  }
  let (schema, base) = split_name(name)
  let db = self.db_of(scope)
  guard db.lookup(schema, base) is Some(id) && db.get_module(id) is Some(m) else {
    return
  }
  let what = match m.kind {
    View => "a view"
    Synonym => "a synonym"
    Procedure => "a procedure"
    Sequence => "a sequence"
    Trigger => "a trigger"
    _ => "a function"
  }
  raise @types.not_supported("\{what} of another database")
}

///|
fn Session::find_table_var(self : Session, name : String) -> @store.Table? {
  // only the current module's frame: dynamic SQL, procedures and triggers
  // do not see their caller's table variables (1087; captured: msduck-runs
  // table-variable #023/#024)
  let key = name.to_lower()
  match self.frames.last() {
    Some(f) =>
      match f.tables.get(key) {
        Some(id) => self.tvars.table(id)
        None => None
      }
    None => None
  }
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
      match self.msdb_binding(name) {
        Some(b) => return Some(b)
        None => ()
      }
      self.check_other_db_module(name)
      let real = self.deref_synonym(name)
      match self.find_table(real) {
        Some((scope, t)) => {
          if disabled_cluster_error(t, object_text(name)) is Some(e) {
            raise e
          }
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
      self.check_other_db_module(name)
      match self.find_module(self.deref_synonym(name)) {
        Some(m) if m.kind is View => Some(view_query(m))
        _ => None
      }
    },
    view_ansi_nulls: name => {
      let n = self.deref_synonym(name) catch { _ => name }
      match self.find_module(n) {
        Some(m) => m.ansi_nulls
        None => true
      }
    },
    function: name => {
      self.check_other_db_module(name)
      self.find_function(self.deref_synonym(name))
    },
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
    external_model: name => self.db_of(0).external_model(name) is Some(_),
    system_tvf: (name, args) => self.system_tvf(name, args),
    vector_index: (scope, id, column, metric) => {
      match self.db_of(scope).table(id) {
        Some(t) =>
          t.indexes
          .iter()
          .find_first(ix => {
            ix.vector is Some(v) &&
            v.metric.text() == metric &&
            ix.columns.any(c => c.0 == column)
          })
          .map(ix => ix.index_id)
        None => None
      }
    },
    preview_features: () => {
      self.server
      .db_options(self.rt.database)
      .flag(self.rt.database, "PREVIEW_FEATURES")
    },
    compat_level: () => self.server.db_options(self.rt.database).compat_level,
  }
}

///|
/// Finds a view, procedure, function or trigger in the user database.
fn Session::find_module(
  self : Session,
  name : @ast.ObjectName,
) -> @store.Module? {
  // never an object of the session database for a name of another one
  // (`check_other_db_module` reports those)
  guard self.name_scope(name) is Some(0) else { return None }
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
/// Index lookup for the executor (`@exec.Ctx::seek`): rows of table
/// (scope, id) whose index columns equal `key`, in row id order, or None
/// when no index is fully covered by `key`. A unique, unfiltered index
/// gives at most one row; otherwise an unfiltered non-unique index whose
/// key comparison is the predicate's (not a char/varchar column: index
/// keys compare without the code page 1252 rules of `=`) gives every row
/// with an equal key. The caller re-applies its whole predicate.
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
  let covered = (ix : @store.Index) => {
    let vals = []
    for c in ix.columns {
      match key.search_by(k => k.0 == c.0) {
        Some(j) => vals.push(key[j].1)
        None => return None
      }
    }
    Some(vals)
  }
  // a disabled index is not used (ALTER INDEX … DISABLE)
  for i, ix in t.indexes {
    if ix.vector is Some(_) ||
      ix.json is Some(_) ||
      !ix.unique ||
      ix.disabled ||
      ix.filter is Some(_) {
      continue
    }
    if covered(ix) is Some(vals) {
      self.index_access(scope, id, ix.index_id, 0)
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
  for i, ix in t.indexes {
    if ix.vector is Some(_) ||
      ix.json is Some(_) ||
      ix.unique ||
      ix.disabled ||
      ix.filter is Some(_) {
      continue
    }
    let ansi = ix.columns
      .iter()
      .any(c => {
        let ty = t.columns[c.0].ty
        ty.family() == FString && !ty.is_unicode()
      })
    if ansi {
      continue
    }
    guard covered(ix) is Some(vals) else { continue }
    self.index_access(scope, id, ix.index_id, 0)
    // non-unique keys end with the row id: the range of one key value
    let lo = vals.copy()
    lo.push(BigInt(-0x8000000000000000L))
    let hi = vals
    hi.push(BigInt(0x7FFFFFFFFFFFFFFFL))
    let rowids = db.seek(id, i, lo~, hi~)
    rowids.sort()
    let out = []
    for rowid in rowids {
      match db.row(id, rowid) {
        Some(r) => out.push((rowid, r))
        None => ()
      }
    }
    return Some(out)
  }
  None
}

///|
/// Data stamp of table (scope, id) for the executor's statement caches
/// (`@exec.Ctx::stamp`): unchanged while the table's data is physically the
/// same value (`@store.Db::table_data`), a new number after any write.
/// None for catalog views and unknown tables.
fn Session::data_stamp(self : Session, scope : Int, id : Int) -> Int64? {
  if scope == 2 {
    return None
  }
  guard self.db_of(scope).table_data(id) is Some(data) else { return None }
  match self.stamps.get((scope, id)) {
    Some((seen, stamp)) if physical_equal(seen, data) => Some(stamp)
    _ => {
      self.stamp_seq += 1L
      self.stamps[(scope, id)] = (data, self.stamp_seq)
      Some(self.stamp_seq)
    }
  }
}

///|
/// A bounded reader owned by one execution context. Resolve the database on
/// every call, but avoid table/map lookup while its immutable identity agrees.
/// A stamp denotes one immutable TableData, so reusing it after restoring the
/// identical Db is safe even if another reader observed an intervening write.
fn Session::stamp_reader(self : Session) -> (Int, Int) -> Int64? {
  let mut state : StampReadCache? = None
  (scope, id) => {
    if scope == 2 {
      return None
    }
    let db = self.db_of(scope)
    let cache = match state {
      Some(cache) => cache
      None => {
        let cache = StampReadCache::{ db, scope, stamps: Map([]), }
        state = Some(cache)
        cache
      }
    }
    if cache.scope != scope || !physical_equal(cache.db, db) {
      cache.stamps.clear()
      cache.db = db
      cache.scope = scope
    }
    match cache.stamps.get(id) {
      Some(stamp) => Some(stamp)
      None => {
        let stamp = self.data_stamp(scope, id)
        if stamp is Some(value) {
          if cache.stamps.length() >= 64 {
            cache.stamps.clear()
          }
          cache.stamps[id] = value
        }
        stamp
      }
    }
  }
}

///|
/// Allocated only when this context actually probes a table stamp.
priv struct StampReadCache {
  mut db : @store.Db
  mut scope : Int
  stamps : Map[Int, Int64]
}
