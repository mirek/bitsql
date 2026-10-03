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
      match self.find_table(name) {
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
              None => t.name.to_lower()
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
fn Session::exec_insert(self : Session, ins : @ast.Insert) -> Unit raise {
  if !ins.ctes.is_empty() || ins.top is Some(_) {
    raise @types.not_supported("INSERT with CTE or TOP")
  }
  let target = self.dml_target(ins.target)
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  let identity_insert = self.identity_insert == Some(t.id)
  let outputs = self.bind_output(ins.output, target, false, true, [])
  let inserted_rows = []
  // target columns
  let cols : Array[Int] = if ins.columns.is_empty() {
    let out = []
    for i, c in t.columns {
      if (c.identity is None || identity_insert) &&
        c.computed is None &&
        c.ty != RowVersion {
        out.push(i)
      }
    }
    out
  } else {
    ins.columns.map(c => {
      match t.column_index(c.name) {
        Some(i) => i
        None => raise @types.sql_error(207, "Invalid column name '\{c.name}'.")
      }
    })
  }
  for i in cols {
    let c = t.columns[i]
    if c.identity is Some(_) && !identity_insert {
      raise @types.sql_error(
        544,
        "Cannot insert explicit value for identity column in table '\{t.name}' when IDENTITY_INSERT is set to OFF.",
      )
    }
    if c.computed is Some(_) {
      raise @types.sql_error(
        271,
        "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
      )
    }
  }
  // source rows with their types
  let env = match ins.source {
    InsertValues(rows) => {
      let all = []
      for r in rows {
        all.append(r)
      }
      self.simple_params_env(self.env(), target, all)
    }
    InsertQuery(q) =>
      match simple_select_exprs(q) {
        Some(xs) => self.simple_params_env(self.env(), target, xs)
        None => self.env()
      }
    _ => self.env()
  }
  let (source, types) : (Array[Array[@types.Value]], Array[@types.SqlType]) = match
    ins.source {
    InsertValues(rows) => {
      for r in rows {
        check_sequence_refs(r)
      }
      let bound = rows.map(r => {
        r.map(e => {
          if e.kind is Default {
            None
          } else {
            Some(@bind.bind_expr(env, e))
          }
        })
      })
      for r in bound {
        if r.length() != cols.length() {
          if ins.columns.is_empty() {
            raise @types.sql_error(
              213, "Column name or number of supplied values does not match table definition.",
            )
          } else if r.length() > cols.length() {
            raise @types.sql_error(
              110,
              "There are more columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
              severity=15,
            )
          } else {
            raise @types.sql_error(
              109,
              "There are more columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
              severity=15,
            )
          }
        }
      }
      let bound = unify_values_rows(bound)
      // assignment type rules are compile-time (DONE cmd 253, captured)
      if bound.length() > 0 {
        for j, e in bound[0] {
          if j < cols.length() && e is Some(b) {
            @types.check_assign(b.ty, t.columns[cols[j]].ty)
          }
        }
      }
      self.cur_cmd = 195
      let ctx = self.ctx()
      let types = []
      let values = []
      for r in bound {
        let row = []
        let tys = []
        for e in r {
          match e {
            Some(b) => {
              row.push(@exec.eval(ctx, b))
              tys.push(b.ty)
            }
            None => {
              row.push(@types.Value::Null)
              tys.push(@types.SqlType::Int) // marker: DEFAULT
            }
          }
        }
        values.push(row)
        if types.is_empty() {
          types.append(tys)
        }
      }
      // DEFAULT markers: re-evaluate below
      (
        values,
        if types.is_empty() {
          cols.map(_ => @types.SqlType::Int)
        } else {
          types
        },
      )
    }
    InsertQuery(q) => {
      let bq = @bind.bind_query(env, q, result_columns=false)
      if bq.columns.length() != cols.length() {
        raise @types.sql_error(
          120,
          "The select list for the INSERT statement contains fewer items than the insert list. The number of SELECT values must match the number of INSERT columns.",
          severity=15,
        )
      }
      for j, c in bq.columns {
        @types.check_assign(c.ty, t.columns[cols[j]].ty)
      }
      self.cur_cmd = 195
      (@exec.run(self.ctx(), bq.plan), bq.columns.map(c => c.ty))
    }
    DefaultValues => {
      self.cur_cmd = 195
      ([[]], [])
    }
    InsertExec(_) => raise @types.not_supported("INSERT ... EXEC")
  }
  let default_marks = match ins.source {
    InsertValues(rows) => rows.map(r => r.map(e => e.kind is Default))
    _ => []
  }
  // assignment type rules before any row (captured: 206/257 for
  // sql_variant columns are compile-time errors)
  for j, ci in cols {
    if j < types.length() &&
      !default_marks.iter().all(m => j < m.length() && m[j]) {
      @types.check_assign(types[j], t.columns[ci].ty)
    }
  }
  let mut db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnInsert)
  let mut last_identity : Int64? = None
  for ri, src in source {
    let row = Array::make(t.columns.length(), @types.Value::Null)
    let given = Array::make(t.columns.length(), false)
    for j, ci in cols {
      if j < src.length() {
        let is_default = ri < default_marks.length() && default_marks[ri][j]
        if !is_default {
          row[ci] = self.to_column(target, t.columns[ci], src[j], types[j])
          given[ci] = true
        }
      }
    }
    for i, c in t.columns {
      if given[i] {
        continue
      }
      match (c.identity, c.default_) {
        (Some(id), _) if !(identity_insert && given[i]) => {
          let v = self.next_identity(t, id)
          row[i] = identity_value(c.ty, v)
          last_identity = Some(v)
        }
        (_, Some(d)) if c.computed is None =>
          row[i] = self.eval_text(target, d, row, c.ty)
        _ => ()
      }
      if c.ty is RowVersion {
        self.server.dbts += 1L
        row[i] = Binary(rowversion_bytes(self.server.dbts))
      }
    }
    for i, c in t.columns {
      if c.computed is Some(expr) {
        row[i] = self.eval_text(target, expr, row, c.ty)
      }
    }
    if identity_insert {
      for i, c in t.columns {
        if c.identity is Some(_) && given[i] {
          match row[i].as_int64() {
            Some(v) => {
              let cur = self.server.idents.get(t.id)
              if cur is None || v > cur.unwrap() {
                self.server.idents[t.id] = v
              }
              last_identity = Some(v)
            }
            None => ()
          }
        }
      }
    }
    if !instead.is_empty() {
      // INSTEAD OF: the trigger sees the rows; constraints are not checked
      inserted_rows.push(row)
      continue
    }
    self.check_row(target, db, row, "INSERT")
    let rowid = self.server.rowid()
    if target.scope == 0 {
      // X on the new key: waits for another transaction's uncommitted
      // insert of the same key, or a range lock covering it
      self.acquire(row_resource(t, rowid, row), X, Transaction)
    }
    db = insert_checked(target, db, rowid, row)
    inserted_rows.push(row)
  }
  let all_columns = Array::makei(t.columns.length(), i => i)
  if !instead.is_empty() {
    self.run_triggers(target, instead, [], inserted_rows, all_columns, pre)
    let n = source.length().to_int64()
    self.rt.rowcount = n
    self.done(195, count=Some(n))
    return
  }
  self.write(target.scope, db)
  let sent = self.emit_output(outputs, inserted_rows)
  if last_identity is Some(v) {
    let iv : @types.Value = Decimal(@types.Decimal::from_int64(v))
    self.rt.identity = iv
    self.rt.scope_identity = iv
  }
  self.fire_after(target, OnInsert, [], inserted_rows, all_columns, pre)
  let n = source.length().to_int64()
  self.rt.rowcount = n
  self.done(195, count=Some(n), result_set=sent)
}

///|
fn rowversion_bytes(v : Int64) -> Bytes {
  Bytes::makei(8, i => (v >> (8 * (7 - i))).to_byte())
}

///|
/// Rows to modify: (rowid, target row image, full source row). Handles
/// FROM/JOIN sources, WHERE and TOP; each target row appears once.
fn Session::dml_rows(
  self : Session,
  target : Target,
  from : Array[@ast.TableRef],
  where_ : @ast.Expr?,
  top : @ast.Top?,
) -> (
  Array[(Int64, Array[@types.Value], Array[@types.Value])],
  @bind.Env,
  Array[@bind.ColumnRef],
) raise {
  let t = target.table
  let n = t.columns.length()
  let binding : @bind.TableBinding = {
    scope: target.scope,
    id: t.id,
    schema: t.schema,
    name: t.name,
    columns: table_columns(t),
  }
  let names = [target.qualifier, t.name.to_lower()]
  let (source, cols, start, rowid_at) = if from.is_empty() {
    let cols = table_columns(t).map(c => { ..c, qualifier: target.qualifier, })
    cols.push({
      qualifier: "%rowid",
      name: "%rowid",
      ty: BigInt,
      nullable: false,
      origin: Computed,
    })
    (@ir.Plan::Scan(scope=target.scope, id=t.id, rowid=true), cols, 0, n)
  } else {
    @bind.bind_dml_source(self.env(), from, binding, names)
  }
  let env = self.env().with_columns(cols)
  let mut plan : @ir.Plan = match where_ {
    Some(w) => Filter(source, @bind.bind_expr(env, w))
    None => source
  }
  match top {
    Some(tp) => {
      if tp.percent || tp.with_ties {
        raise @types.not_supported("TOP PERCENT / WITH TIES in DML")
      }
      let count = @bind.coerce(@bind.bind_expr(self.env(), tp.count), BigInt)
      plan = Limit(plan, None, Some(count))
    }
    None => ()
  }
  let seen : Set[Int64] = Set([])
  let out = []
  for r in @exec.run(self.ctx(), plan) {
    let rowid = r[rowid_at].as_int64().unwrap_or(0L)
    if seen.contains(rowid) {
      continue
    }
    seen.add(rowid)
    out.push((rowid, r[start:start + n].to_owned(), r))
  }
  (out, env, cols)
}

///|
fn Session::exec_update(self : Session, u : @ast.Update) -> Unit raise {
  if !u.ctes.is_empty() || u.current_of is Some(_) {
    raise @types.not_supported("UPDATE with CTE or CURRENT OF")
  }
  let target = self.dml_target(resolve_alias(u.target, u.from))
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  let (rows, env, cols) = self.dml_rows(target, u.from, u.where_, u.top)
  let env = if u.from.is_empty() && u.top is None {
    let xs = []
    for s in u.sets {
      xs.push(s.value)
    }
    if u.where_ is Some(w) {
      xs.push(w)
    }
    self.simple_params_env(env, target, xs)
  } else {
    env
  }
  // bind SET clauses against the full source row
  let sets = []
  for s in u.sets {
    match s.target {
      SetColumn(parts) => {
        let name = parts[parts.length() - 1].name
        let ci = match t.column_index(name) {
          Some(i) => i
          None => raise @types.sql_error(207, "Invalid column name '\{name}'.")
        }
        let c = t.columns[ci]
        if c.identity is Some(_) {
          raise @types.sql_error(
            8102,
            "Cannot update identity column '\{c.name}'.",
          )
        }
        if c.computed is Some(_) {
          raise @types.sql_error(
            271,
            "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
          )
        }
        if @bind.has_aggregate(s.value) {
          raise @types.sql_error(
            157,
            "An aggregate may not appear in the set list of an UPDATE statement.",
            severity=15,
          )
        }
        let rhs = if s.value.kind is Default {
          None
        } else {
          Some(@bind.bind_expr(env, s.value))
        }
        if rhs is Some(b) && s.op is Assign {
          @types.check_assign(b.ty, c.ty)
        }
        sets.push((ci, s.op, rhs))
      }
      SetVariable(_) | SetVarColumn(_, _) =>
        raise @types.not_supported("UPDATE SET @variable")
    }
  }
  let extra = if u.from.is_empty() { [] } else { cols }
  let outputs = self.bind_output(u.output, target, true, true, extra)
  self.cur_cmd = 197
  self.lock_rows(target, rows.map(r => (r.0, r.1)))
  let mut db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnUpdate)
  let images = []
  let output_rows = []
  for rec in rows {
    let (rowid, old, full) = rec
    let row = old.copy()
    let ctx = self.ctx().with_row(full)
    for s in sets {
      let (ci, op, rhs) = s
      let c = t.columns[ci]
      let (v, ty) = match rhs {
        None =>
          match c.default_ {
            Some(d) => (self.eval_text(target, d, old, c.ty), c.ty)
            None => (@types.Value::Null, c.ty)
          }
        Some(b) =>
          match op {
            Assign => (@exec.eval(ctx, b), b.ty)
            _ => {
              let aop : @types.ArithOp = match op {
                AddAssign => Add
                SubAssign => Sub
                MulAssign => Mul
                DivAssign => Div
                _ => Mod
              }
              let rt = @types.arith_result_type(aop, c.ty, b.ty)
              (@types.arith(aop, old[ci], c.ty, @exec.eval(ctx, b), b.ty), rt)
            }
          }
      }
      row[ci] = self.to_column(target, c, v, ty)
    }
    for i, c in t.columns {
      if c.computed is Some(expr) {
        row[i] = self.eval_text(target, expr, row, c.ty)
      }
      if c.ty is RowVersion {
        self.server.dbts += 1L
        row[i] = Binary(rowversion_bytes(self.server.dbts))
      }
    }
    if instead.is_empty() {
      self.check_row(target, db, row, "UPDATE")
    }
    images.push((rowid, old, row))
    output_rows.push(
      old + row + (if extra.is_empty() { [] } else { full.filter(_ => true) }),
    )
  }
  let updated = sets.map(s => s.0)
  if !instead.is_empty() {
    self.run_triggers(
      target,
      instead,
      images.map(x => x.1),
      images.map(x => x.2),
      updated,
      pre,
    )
    let n = images.length().to_int64()
    self.rt.rowcount = n
    self.done(197, count=Some(n))
    return
  }
  // OUTPUT rows are streamed before end-of-statement constraint checks
  let sent = self.emit_output(
    outputs,
    output_rows.map(r => strip_rowid(r, cols, t.columns.length() * 2)),
  )
  // OUTPUT INTO may have written to the same database
  db = self.db_of(target.scope)
  self.check_references(
    target,
    db,
    images.map(x => x.1),
    images.map(x => Some(x.2)),
    "UPDATE",
  )
  // statement-level uniqueness: remove old images, then insert new ones
  for im in images {
    db = db.delete_row(t.id, im.0)
  }
  for im in images {
    db = insert_checked(target, db, im.0, im.2)
  }
  self.write(target.scope, db)
  self.fire_after(
    target,
    OnUpdate,
    images.map(x => x.1),
    images.map(x => x.2),
    updated,
    pre,
  )
  let n = images.length().to_int64()
  self.rt.rowcount = n
  self.done(197, count=Some(n), result_set=sent)
}

///|
/// Removes the hidden "%rowid" column from a combined OUTPUT row, whose
/// source part starts at `offset`.
fn strip_rowid(
  row : Array[@types.Value],
  cols : Array[@bind.ColumnRef],
  offset : Int,
) -> Array[@types.Value] {
  if row.length() <= offset {
    return row
  }
  let out = row[0:offset].to_owned()
  for i, c in cols {
    if c.qualifier != "%rowid" && offset + i < row.length() {
      out.push(row[offset + i])
    }
  }
  out
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
fn Session::exec_delete(self : Session, d : @ast.Delete) -> Unit raise {
  if !d.ctes.is_empty() || d.current_of is Some(_) {
    raise @types.not_supported("DELETE with CTE or CURRENT OF")
  }
  let target = self.dml_target(resolve_alias(d.target, d.from))
  if target.scope != 3 {
    self.check_writable()
  }
  let (rows, _, cols) = self.dml_rows(target, d.from, d.where_, d.top)
  let extra = if d.from.is_empty() { [] } else { cols }
  let outputs = self.bind_output(d.output, target, true, false, extra)
  self.cur_cmd = 196
  self.lock_rows(target, rows.map(r => (r.0, r.1)))
  let mut db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnDelete)
  if !instead.is_empty() {
    self.run_triggers(target, instead, rows.map(r => r.1), [], [], pre)
    let n = rows.length().to_int64()
    self.rt.rowcount = n
    self.done(196, count=Some(n))
    return
  }
  self.check_references(
    target,
    db,
    rows.map(r => r.1),
    rows.map(_ => None),
    "DELETE",
  )
  let output_rows = rows.map(r => {
    r.1 + (if extra.is_empty() { [] } else { r.2 })
  })
  let sent = self.emit_output(
    outputs,
    output_rows.map(r => strip_rowid(r, cols, target.table.columns.length())),
  )
  db = self.db_of(target.scope)
  for r in rows {
    db = db.delete_row(target.table.id, r.0)
  }
  self.write(target.scope, db)
  self.fire_after(target, OnDelete, rows.map(r => r.1), [], [], pre)
  let n = rows.length().to_int64()
  self.rt.rowcount = n
  self.done(196, count=Some(n), result_set=sent)
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
/// `UPDATE a ... FROM t a`: a one-part target naming an alias in FROM
/// refers to that table (keeping the alias as the qualifier).
fn resolve_alias(
  target : @ast.TableRef,
  from : Array[@ast.TableRef],
) -> @ast.TableRef {
  guard target.kind is Table(name, alias_=None, hints~) &&
    name.parts.length() == 1 else {
    return target
  }
  let wanted = name.parts[0].name.to_lower()
  fn find(r : @ast.TableRef) -> @ast.TableRef? {
    match r.kind {
      Table(real, alias_=Some(a), ..) if a.name.to_lower() == wanted =>
        Some({ ..r, kind: Table(real, alias_=Some(a), hints~), })
      Join(_, l, rr, ..) =>
        match find(l) {
          Some(x) => Some(x)
          None => find(rr)
        }
      _ => None
    }
  }

  for r in from {
    match find(r) {
      Some(x) => return x
      None => ()
    }
  }
  target
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
