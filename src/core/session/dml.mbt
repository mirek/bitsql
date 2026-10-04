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
        Some((scope, t)) =>
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
        None => {
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
fn Session::full_name(self : Session, target : Target) -> String {
  if target.scope == 1 {
    "tempdb.dbo." + target.table.name
  } else if target.scope == 3 {
    target.display
  } else {
    self.rt.database + "." + target.display
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
  match (limit, v) {
    (Some(n), String(s)) if from.family() == FString && rtrim(s).length() > n =>
      raise @types.sql_error(
        2628,
        "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{col.name}'. Truncated value: '\{s.unsafe_substring(start=0, end=n)}'.",
      )
    (Some(n), Binary(b)) if b.length() > n =>
      raise @types.sql_error(
        2628,
        "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{col.name}'. Truncated value: ''.",
      )
    _ => ()
  }
  @types.assign(v, from, col.ty)
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
fn Session::next_identity(
  self : Session,
  t : @store.Table,
  id : @store.Identity,
) -> Int64 {
  let v = match self.server.idents.get(t.id) {
    Some(last) => last + id.increment
    None => id.seed
  }
  self.server.idents[t.id] = v
  v
}

///|
/// The value the next generated identity would take, without consuming it.
fn Session::peek_identity(
  self : Session,
  t : @store.Table,
  id : @store.Identity,
) -> Int64 {
  match self.server.idents.get(t.id) {
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
        "The \{verb} statement conflicted with the CHECK constraint \"\{ck.name}\". The conflict occurred in database \"\{if target.scope == 1 { "tempdb" } else { self.rt.database }}\", table \"\{target.display}\"\{check_column_suffix(t, ck.expr)}.",
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
    if !fk_has_key(db, parent, fk.ref_columns, key) {
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
      let vals = ix.columns
        .map(c => key_text(row[c.0], t.columns[c.0].ty))
        .join(", ")
      if ix.is_constraint {
        let kind = if ix.primary { "PRIMARY KEY" } else { "UNIQUE KEY" }
        raise @types.sql_error(
          2627,
          "Violation of \{kind} constraint '\{ix.name}'. Cannot insert duplicate key in object '\{target.display}'. The duplicate key value is (\{vals}).",
          severity=14,
        )
      } else {
        raise @types.sql_error(
          2601,
          "Cannot insert duplicate key row in object '\{target.display}' with unique index '\{ix.name}'. The duplicate key value is (\{vals}).",
          severity=14,
        )
      }
    }
  }
  db.insert_row(t.id, rowid, row)
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
      self.server.idents.remove(t.id)
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
