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
          raise @types.sql_error(
            208,
            "Invalid object name '\{name.parts.map(p => p.name).join(".")}'.",
          )
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
/// Constraint checks for a new row image (INSERT or UPDATE).
fn Session::check_row(
  self : Session,
  target : Target,
  db : @store.Db,
  row : Array[@types.Value],
  verb : String,
  constraints? : Bool = true,
) -> Unit raise {
  let t = target.table
  for i, c in t.columns {
    if !c.nullable && row[i] is Null {
      raise @types.sql_error(
        515,
        "Cannot insert the value NULL into column '\{c.name}', table '\{self.full_name(target)}'; column does not allow nulls. \{verb} fails.",
        state=2,
      )
    }
  }
  // bulk loads skip CHECK and FOREIGN KEY constraints unless
  // CHECK_CONSTRAINTS (captured with tedious BulkLoad)
  if !constraints {
    return
  }
  for ck in t.checks {
    if !ck.enabled {
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
  for fk in t.foreign_keys {
    if !fk.enabled {
      continue
    }
    let key = fk.columns.map(i => row[i])
    if key.iter().any(v => v is Null) {
      continue
    }
    let parent_db = db
    guard parent_db.table(fk.ref_table) is Some(parent) else { continue }
    let mut found = false
    for kv in parent_db.rows(parent.id) {
      let mut eq = true
      for j, pc in fk.ref_columns {
        let ty = parent.columns[pc].ty
        if @types.compare(kv.1[pc], key[j], collation?=ty.collation()) !=
          Some(0) {
          eq = false
          break
        }
      }
      if eq {
        found = true
        break
      }
    }
    if !found {
      raise @types.sql_error(
        547,
        "The \{verb} statement conflicted with the FOREIGN KEY constraint \"\{fk.name}\". The conflict occurred in database \"\{self.rt.database}\", table \"\{parent.schema}.\{parent.name}\", column '\{parent.columns[fk.ref_columns[0]].name}'.",
        state=0,
      )
    }
  }
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
    if !ix.unique {
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
/// Rows of other tables referencing `target` rows being deleted or whose
/// key changes (REFERENCE constraint, error 547). `after` is None for
/// deletes.
fn Session::check_references(
  self : Session,
  target : Target,
  db : @store.Db,
  before : Array[Array[@types.Value]],
  after : Array[Array[@types.Value]?],
  verb : String,
) -> Unit raise {
  let t = target.table
  for child in db.tables() {
    for fk in child.foreign_keys {
      if fk.ref_table != t.id || !fk.enabled {
        continue
      }
      for i, old in before {
        let key = fk.ref_columns.map(c => old[c])
        // key unchanged by an UPDATE: nothing to check
        match after[i] {
          Some(new) => {
            let mut same = true
            for c in fk.ref_columns {
              if @types.compare(
                  old[c],
                  new[c],
                  collation?=t.columns[c].ty.collation(),
                ) !=
                Some(0) {
                same = false
              }
            }
            if same {
              continue
            }
          }
          None => ()
        }
        for kv in db.rows(child.id) {
          let mut eq = true
          for j, cc in fk.columns {
            if @types.compare(
                kv.1[cc],
                key[j],
                collation?=child.columns[cc].ty.collation(),
              ) !=
              Some(0) {
              eq = false
              break
            }
          }
          if eq {
            raise @types.sql_error(
              547,
              "The \{verb} statement conflicted with the REFERENCE constraint \"\{fk.name}\". The conflict occurred in database \"\{self.rt.database}\", table \"\{child.schema}.\{child.name}\", column '\{child.columns[fk.columns[0]].name}'.",
              state=0,
            )
          }
        }
      }
    }
  }
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
              "Cannot truncate table '\{t.schema}.\{t.name}' because it is being referenced by a FOREIGN KEY constraint.",
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
