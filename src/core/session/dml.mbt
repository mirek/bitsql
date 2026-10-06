///|
/// A resolved DML target.
priv struct Target {
  scope : Int
  table : @store.Table
  /// "schema.name" as SQL Server prints it in messages.
  display : String
  /// Name used to qualify columns (alias or table name).
  qualifier : String
}

///|
fn Session::dml_target(self : Session, r : @ast.TableRef) -> Target raise {
  match r.kind {
    Table(name, alias_~, ..) =>
      match self.find_table(self.deref_synonym(name)) {
        Some((scope, t)) => {
          if scope >= OTHER_DB_SCOPE {
            self.check_other_db_target(scope, t)
          }
          {
            scope,
            table: t,
            display: if scope == 1 {
              t.name
            } else {
              t.schema + "." + t.name
            },
            qualifier: match alias_ {
              Some(a) => a.name.to_lower()
              None => name.base().to_lower()
            },
          }
        }
        None => {
          self.check_other_db_module(name)
          if self.find_module(name) is Some({ kind: View, .. }) {
            raise @types.not_supported("INSERT/UPDATE/DELETE through a view")
          }
          raise @bind.missing_object_error(name)
        }
      }
    TableVar(name, alias_~, ..) =>
      match self.find_table_var(name) {
        Some(t) =>
          {
            scope: 3,
            table: t,
            display: name,
            qualifier: match alias_ {
              Some(a) => a.name.to_lower()
              None => name.to_lower()
            },
          }
        None =>
          raise @types.sql_error(
            1087,
            "Must declare the table variable \"\{name}\".",
            severity=15,
          )
      }
    _ => raise @types.not_supported("this DML target")
  }
}

///|
/// DML on a table of another database runs its constraints in the
/// session; what would bind names in the wrong database is not emulated:
/// triggers (they run in their own database) and defaults, computed
/// columns and CHECK constraints calling user functions or sequences.
fn Session::check_other_db_target(
  self : Session,
  scope : Int,
  t : @store.Table,
) -> Unit raise @types.SqlError {
  let db = self.db_of(scope)
  if db.modules().iter().any(m => m.kind is Trigger && m.parent == Some(t.id)) {
    raise @types.not_supported(
      "DML on a table with triggers in another database",
    )
  }
  let exprs : Array[String] = t.checks.map(c => c.expr)
  for c in t.columns {
    if c.default_ is Some(e) {
      exprs.push(e)
    }
    if c.computed is Some(e) {
      exprs.push(e)
    }
  }
  for e in exprs {
    let low = e.to_lower()
    // user functions are schema-qualified (`[dbo].[f](`)
    if low.contains("next value for") || low.contains("].[") {
      raise @types.not_supported(
        "DML on a table of another database whose defaults, computed columns or CHECK constraints call functions or sequences",
      )
    }
  }
}

///|
fn Session::full_name(self : Session, target : Target) -> String {
  if target.scope == 1 {
    "tempdb.dbo." + target.table.name
  } else if target.scope == 3 {
    target.display
  } else {
    self.scope_database(target.scope) + "." + target.display
  }
}

///|
fn Session::column_env(self : Session, target : Target) -> @bind.Env {
  self
  .env()
  .with_columns(
    table_columns(target.table).map(c => { ..c, qualifier: target.qualifier, }),
  )
}

///|
/// Text of a value for duplicate-key messages.
fn key_text(v : @types.Value, ty : @types.SqlType) -> String {
  match v {
    Null => "<NULL>"
    // captured: GUIDs lower-case, binary as 0x + lower-case hex (msduck
    // gaps-keys message-values)
    Guid(_) =>
      try
        @types.cast(v, ty, NVarChar(Some(4000), @types.default_collation))
      catch {
        _ => ""
      } noraise {
        String(s) => s.to_lower()
        _ => ""
      }
    Binary(b) => {
      let sb = StringBuilder()
      sb.write_string("0x")
      for x in b {
        let h = x.to_int().to_string(radix=16)
        if h.length() < 2 {
          sb.write_string("0")
        }
        sb.write_string(h)
      }
      sb.to_string()
    }
    _ =>
      try
        @types.cast(v, ty, NVarChar(Some(4000), @types.default_collation))
      catch {
        _ => ""
      } noraise {
        String(s) => s
        _ => ""
      }
  }
}

///|
/// Converts a value to a column type with SQL Server's truncation check
/// (error 2628 names the table and column).
fn Session::to_column(
  self : Session,
  target : Target,
  col : @store.Column,
  v : @types.Value,
  from : @types.SqlType,
) -> @types.Value raise {
  let limit = match col.ty {
    Char(n, _)
    | NChar(n, _)
    | VarChar(Some(n), _)
    | NVarChar(Some(n), _)
    | Binary(n)
    | VarBinary(Some(n)) => Some(n)
    _ => None
  }
  // a varchar column under a UTF-8 collation holds n bytes (captured:
  // settings/utf8, 'ééééééé' into varchar(10) is 2628 with 'ééééé')
  let utf8 = !col.ty.is_unicode() &&
    col.ty.collation().map(c => c.utf8()).unwrap_or(false)
  match (limit, v) {
    (Some(n), String(s)) if utf8 &&
      from.family() == FString &&
      @types.utf8_length(rtrim(s)) > n =>
      raise @types.sql_error(
        2628,
        "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{col.name}'. Truncated value: '\{@types.utf8_prefix(s, n)}'.",
      )
    (Some(n), String(s)) if !utf8 &&
      from.family() == FString &&
      rtrim(s).length() > n => {
      // the value as the column stores it: varchar text in code page 1252
      // with best fit (captured: msduck windows-1252-best-fit, U+2000 is
      // shown as ' ', a surrogate half as '?')
      let shown = match col.ty.collation() {
        Some(c) if !col.ty.is_unicode() => @types.to_code_page(s, c)
        _ => s
      }
      raise @types.sql_error(
        2628,
        "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{col.name}'. Truncated value: '\{shown.unsafe_substring(start=0, end=n)}'.",
      )
    }
    (Some(n), Binary(b)) if b.length() > n =>
      raise @types.sql_error(
        2628,
        "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{col.name}'. Truncated value: ''.",
      )
    _ => ()
  }
  // Binding checked typed sources; a bare NULL can initialize native JSON.
  if v is Null && col.ty is Json {
    Null
  } else {
    @types.assign(v, from, col.ty, dates=self.rt.dates)
  }
}

///|
fn rtrim(s : String) -> String {
  let mut n = s.length()
  while n > 0 && s.code_unit_at(n - 1).to_int() == 0x20 {
    n -= 1
  }
  s.unsafe_substring(start=0, end=n)
}

///|
/// Evaluates a stored default/computed expression text for a row.
fn Session::eval_text(
  self : Session,
  target : Target,
  text : String,
  row : Array[@types.Value],
  ty : @types.SqlType,
) -> @types.Value raise {
  if is_newsequentialid(text) {
    return self.server.next_sequential_guid()
  }
  let e = @parse.parse_expr(text)
  let env = self.column_env(target)
  let b = @bind.bind_expr(env, e)
  let v = @exec.eval(self.ctx().with_row(row), b)
  @types.cast(v, b.ty, ty)
}

///|
/// Evaluates a column's DEFAULT for a row and stores it like an assigned
/// value: an over-long string is 2628, not silently cut (captured: msduck
/// unicode-storage *-overflow-default).
fn Session::eval_default(
  self : Session,
  target : Target,
  col : @store.Column,
  text : String,
  row : Array[@types.Value],
) -> @types.Value raise {
  if is_newsequentialid(text) {
    return self.server.next_sequential_guid()
  }
  let b = @bind.bind_expr(self.column_env(target), @parse.parse_expr(text))
  // `DEFAULT (NULL)` is the untyped NULL constant: it converts to any
  // column type (captured: constraints/default-untyped-null)
  if b.kind is Lit(Null) && b.ty is Int {
    return Null
  }
  self.to_column(target, col, @exec.eval(self.ctx().with_row(row), b), b.ty)
}

///|
/// Key of a table's identity counter in `Server::idents`: temp tables
/// ('#') and table variables ('@') by id (ids are unique per server),
/// database tables by "database:id" of the table's database `scope`
/// (RESTORE copies keep object ids).
fn Session::ident_key(self : Session, scope : Int, t : @store.Table) -> String {
  if scope == 1 ||
    scope == 3 ||
    t.name.has_prefix("#") ||
    t.name.has_prefix("@") {
    t.id.to_string()
  } else {
    self.scope_key(scope) + ":" + t.id.to_string()
  }
}

///|
fn Session::next_identity(
  self : Session,
  scope : Int,
  t : @store.Table,
  id : @store.Identity,
) -> Int64 {
  let key = self.ident_key(scope, t)
  let v = match self.server.idents.get(key) {
    Some(last) => last + id.increment
    None => id.seed
  }
  self.server.idents[key] = v
  v
}

///|
/// The value the next generated identity would take, without consuming it.
fn Session::peek_identity(
  self : Session,
  scope : Int,
  t : @store.Table,
  id : @store.Identity,
) -> Int64 {
  match self.server.idents.get(self.ident_key(scope, t)) {
    Some(last) => last + id.increment
    None => id.seed
  }
}

///|
/// Whether a generated identity value fits the column type.
fn identity_fits(ty : @types.SqlType, v : Int64) -> Bool {
  match ty {
    TinyInt => v >= 0L && v <= 255L
    SmallInt => v >= -32768L && v <= 32767L
    Int => v >= -2147483648L && v <= 2147483647L
    Decimal(p, _) | Numeric(p, _) if p < 19 => {
      let mut limit = 1L
      for _ in 0..<p {
        limit = limit * 10L
      }
      v < limit && v > -limit
    }
    _ => true
  }
}

///|
/// 8115 for a generated identity that overflows its column (captured:
/// msduck gaps-rowversion_identity #105/#109, corpus stmts/rowversion-*):
/// batch-ending, rolls back an open transaction, followed by INFO 3606;
/// the identity counter does not advance.
fn Session::identity_overflow(
  self : Session,
  ty : @types.SqlType,
) -> @types.SqlError {
  self.trailing.push(
    @types.sql_error(3606, "Arithmetic overflow occurred.", state=0, severity=0),
  )
  @types.sql_error(
    8115,
    "Arithmetic overflow error converting IDENTITY to data type \{ty.base_name()}.",
  )
}

///|
/// True for the identity-overflow 8115 (batch-ending, unlike other 8115s).
fn is_identity_overflow(e : @types.SqlError) -> Bool {
  e.number() == 8115 &&
  e.message().has_prefix("Arithmetic overflow error converting IDENTITY")
}

///|
/// An identity column value as Int64 (integers and scale-0 decimals).
fn identity_int64(v : @types.Value) -> Int64? {
  match v {
    Decimal(_) =>
      try @types.cast(v, @types.SqlType::Decimal(38, 0), BigInt) catch {
        _ => None
      } noraise {
        BigInt(n) => Some(n)
        _ => None
      }
    _ => v.as_int64()
  }
}

///|
fn identity_value(ty : @types.SqlType, v : Int64) -> @types.Value {
  match ty {
    TinyInt => TinyInt(v.to_int())
    SmallInt => SmallInt(v.to_int())
    Int => Int(v.to_int())
    BigInt => BigInt(v)
    Decimal(_, _) | Numeric(_, _) => Decimal(@types.Decimal::from_int64(v))
    _ => BigInt(v)
  }
}

///|
/// Constraint checks for a new row image (INSERT or UPDATE). `touched`
/// limits CHECK and FOREIGN KEY constraints to those over these columns
/// (UPDATE checks only constraints whose columns it sets, captured: a
/// NOCHECK-violating row can still be updated elsewhere). `self_fks`
/// false skips self-referencing foreign keys (UPDATE checks them against
/// the statement's final state).
fn Session::check_row(
  self : Session,
  target : Target,
  db : @store.Db,
  row : Array[@types.Value],
  verb : String,
  constraints? : Bool = true,
  touched? : Array[Int],
  fks? : Bool = true,
  self_fks? : Bool = true,
) -> Unit raise {
  let t = target.table
  self.check_index_options(t)
  // captured: MERGE reports "UPDATE fails." for its INSERT and UPDATE
  // actions alike (msduck gaps-merge #028, #029)
  let fails = if verb == "MERGE" { "UPDATE" } else { verb }
  for i, c in t.columns {
    if !c.nullable && row[i] is Null {
      raise @types.sql_error(
        515,
        "Cannot insert the value NULL into column '\{c.name}', table '\{self.full_name(target)}'; column does not allow nulls. \{fails} fails.",
        state=2,
      )
    }
  }
  // bulk loads skip CHECK and FOREIGN KEY constraints unless
  // CHECK_CONSTRAINTS (captured with tedious BulkLoad)
  if !constraints {
    return
  }
  let uses = (cols : Array[Int]) => {
    match touched {
      None => true
      Some(ts) => cols.iter().any(c => ts.contains(c))
    }
  }
  for ck in t.checks {
    if !ck.enabled {
      continue
    }
    if touched is Some(_) && !uses(check_ordinals(t, ck.expr)) {
      continue
    }
    let v = self.eval_text(target, ck.expr, row, Bit)
    if v is Bit(false) {
      raise @types.sql_error(
        547,
        "The \{verb} statement conflicted with the CHECK constraint \"\{ck.name}\". The conflict occurred in database \"\{self.scope_database(target.scope)}\", table \"\{target.display}\"\{check_column_suffix(t, ck.expr)}.",
        state=0,
      )
    }
  }
  if !fks {
    return
  }
  for fk in t.foreign_keys {
    if !fk.enabled || !uses(fk.columns) {
      continue
    }
    if fk.ref_table == t.id && !self_fks {
      continue
    }
    let key = fk.columns.map(i => row[i])
    if key.iter().any(v => v is Null) {
      continue
    }
    guard db.table(fk.ref_table) is Some(parent) else { continue }
    if !self.fk_has_key(db, parent, fk.ref_columns, key) {
      raise self.fk_child_error(target.scope, verb, fk, t.id, parent)
    }
  }
}

///|
/// Ordinals of the columns a CHECK expression references.
fn check_ordinals(t : @store.Table, expr : String) -> Array[Int] {
  check_columns(expr).filter_map(n => t.column_index(n))
}

///|
/// INSERT into a unique index WITH (IGNORE_DUP_KEY = ON) holding the row's
/// key: the row is skipped with INFO 3604 (captured: msduck gaps-keys
/// ignore-dup-key-4; UPDATE still fails with 2601).
fn dup_key_ignored(
  t : @store.Table,
  db : @store.Db,
  row : Array[@types.Value],
) -> Bool {
  for i, ix in t.indexes {
    if ix.unique &&
      ix.ignore_dup_key &&
      ix.covers(row) &&
      db.find_key(t.id, i, ix.columns.map(c => row[c.0])) is Some(_) {
      return true
    }
  }
  false
}

///|
/// Inserts one row checking unique keys; returns the new database.
fn insert_checked(
  target : Target,
  db : @store.Db,
  rowid : Int64,
  row : Array[@types.Value],
) -> @store.Db raise {
  let t = target.table
  for i, ix in t.indexes {
    // rows outside a filtered index's predicate are not in it
    if !ix.unique || !ix.covers(row) {
      continue
    }
    let key = ix.columns.map(c => row[c.0])
    if db.find_key(t.id, i, key) is Some(_) {
      raise duplicate_key(target, ix, row)
    }
  }
  db.insert_row(t.id, rowid, row)
}

///|
/// 2627 / 2601 for a row whose key `ix` already holds.
fn duplicate_key(
  target : Target,
  ix : @store.Index,
  row : Array[@types.Value],
) -> @types.SqlError {
  let t = target.table
  let vals = ix.columns
    .map(c => key_text(row[c.0], t.columns[c.0].ty))
    .join(", ")
  // temp tables (scope 1) and table variables (3) are 'dbo.#t' / 'dbo.@t'
  // (captured: catalog/inline-index-options, traps/duplicate-key-session-tables)
  let object = if target.scope is (1 | 3) {
    t.schema + "." + target.display
  } else {
    target.display
  }
  if ix.is_constraint {
    let kind = if ix.primary { "PRIMARY KEY" } else { "UNIQUE KEY" }
    @types.sql_error(
      2627,
      "Violation of \{kind} constraint '\{ix.name}'. Cannot insert duplicate key in object '\{object}'. The duplicate key value is (\{vals}).",
      severity=14,
    )
  } else {
    @types.sql_error(
      2601,
      "Cannot insert duplicate key row in object '\{object}' with unique index '\{ix.name}'. The duplicate key value is (\{vals}).",
      severity=14,
    )
  }
}

///|
/// Rows an INSERT has checked but not yet written: `insert_checked` of
/// each in turn equals checking each against the statement's starting
/// state plus the pending keys, then one `Db::insert_rows`. Pending keys
/// are exact sort keys under the index columns' collations, equal exactly
/// when the index comparator calls them equal.
priv struct PendingInserts {
  rows : Array[(Int64, Array[@types.Value])]
  keys : Array[Set[Array[@types.SortKey]]]
}

///|
fn PendingInserts::new(t : @store.Table) -> PendingInserts {
  { rows: [], keys: t.indexes.map(_ => Set([])), }
}

///|
/// Checks and queues one row as `insert_checked` would against `db` plus
/// the pending rows (raising its error). False, with nothing queued, when
/// a key has no exact sort key: the caller writes the pending rows and
/// continues with `insert_checked`.
fn PendingInserts::add(
  self : PendingInserts,
  target : Target,
  db : @store.Db,
  rowid : Int64,
  row : Array[@types.Value],
) -> Bool raise {
  let t = target.table
  let keys : Array[Array[@types.SortKey]?] = []
  for ix in t.indexes {
    // disabled indexes never receive rows, so only `db` holds their keys
    if !ix.unique || ix.disabled || !ix.covers(row) {
      keys.push(None)
      continue
    }
    let key = ix.columns.map(c => {
      @types.sort_key(row[c.0], collation?=t.columns[c.0].ty.collation())
    })
    if key.iter().any(k => k.exact_kind() < 0) {
      return false
    }
    keys.push(Some(key))
  }
  for i, ix in t.indexes {
    if !ix.unique || !ix.covers(row) {
      continue
    }
    let dup = db.find_key(t.id, i, ix.columns.map(c => row[c.0])) is Some(_) ||
      (keys[i] is Some(k) && self.keys[i].contains(k))
    if dup {
      raise duplicate_key(target, ix, row)
    }
  }
  for i, k in keys {
    if k is Some(key) {
      self.keys[i].add(key)
    }
  }
  self.rows.push((rowid, row))
  true
}

///|
/// `db` with the pending rows written; the buffer is emptied.
fn PendingInserts::flush(
  self : PendingInserts,
  db : @store.Db,
  id : Int,
) -> @store.Db {
  let out = db.insert_rows(id, self.rows)
  self.rows.clear()
  for k in self.keys {
    k.clear()
  }
  out
}

///|
fn Session::exec_truncate(self : Session, name : @ast.ObjectName) -> Unit raise {
  self.check_writable()
  match self.find_table(name) {
    Some((scope, t)) => {
      let db = self.db_of(scope)
      for other in db.tables() {
        for fk in other.foreign_keys {
          if fk.ref_table == t.id {
            raise @types.sql_error(
              4712,
              "Cannot truncate table '\{object_text(name)}' because it is being referenced by a FOREIGN KEY constraint.",
            )
          }
        }
      }
      self.write(scope, db.truncate(t.id))
      // TRUNCATE reseeds identity
      self.server.idents.remove(self.ident_key(scope, t))
      self.rt.rowcount = 0
      self.done(234)
    }
    None =>
      raise @types.sql_error(
        4701,
        "Cannot find the object \"\{name.base()}\" because it does not exist or you do not have permissions.",
      )
  }
}

///|
/// `, column 'c'` when a CHECK constraint references exactly one column
/// (captured: 547 for `CHECK (name <> 'bad')` names column 'name').
fn check_column_suffix(t : @store.Table, expr : String) -> String {
  let e = @parse.parse_expr(expr) catch { _ => return "" }
  let cols = []
  walk_expr(e, x => {
    match x.kind {
      Column(parts) => {
        let n = parts[parts.length() - 1].name.to_lower()
        if !cols.contains(n) {
          cols.push(n)
        }
      }
      _ => ()
    }
  })
  match cols {
    [one] =>
      match t.column_index(one) {
        Some(i) => ", column '\{t.columns[i].name}'"
        None => ""
      }
    _ => ""
  }
}

///|
/// Multi-row VALUES: each column has the common type of its rows (DEFAULT
/// entries excluded) and every row converts to it before the target
/// column conversion, as in SQL Server (captured: a mixed int/date column
/// of VALUES fails with 206; base types of sql_variant columns show the
/// unified type, variant/insert-values.sql).
fn unify_values_rows(
  rows : Array[Array[@ir.Expr?]],
) -> Array[Array[@ir.Expr?]] raise {
  if rows.length() < 2 {
    return rows
  }
  let width = rows[0].length()
  let out = rows.map(r => r.copy())
  for j in 0..<width {
    let tys = []
    for r in rows {
      // an untyped NULL literal takes no part (like UNION branches)
      if r[j] is Some(e) && !(e.kind is Lit(Null) && e.ty is Int) {
        tys.push(e.ty)
      }
    }
    if tys.length() < 2 {
      continue
    }
    let t = @bind.unify_types(tys)
    for r in out {
      if r[j] is Some(e) {
        // a literal that cannot convert fails while compiling (captured:
        // VALUES (1), ('abc') is 245 with DONE cmd 253)
        if e.kind is Lit(v) && e.ty != t {
          ignore(@types.cast(v, e.ty, t))
        }
        r[j] = Some(@bind.coerce(e, t))
      }
    }
  }
  out
}
