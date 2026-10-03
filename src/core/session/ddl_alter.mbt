// ALTER TABLE, CREATE INDEX, DROP INDEX. Errors and completions follow
// captures in harness/corpus/catalog/alter-*.sql.

///|
fn Session::alter_target(
  self : Session,
  name : @ast.ObjectName,
) -> (Int, @store.Table) raise {
  match self.find_table(name) {
    Some(x) => x
    None => {
      self.uncatchable = true
      raise @types.sql_error(
        4902,
        "Cannot find the object \"\{object_text(name)}\" because it does not exist or you do not have permissions.",
      )
    }
  }
}

///|
fn display_name(scope : Int, t : @store.Table) -> String {
  if scope == 1 {
    t.name
  } else {
    t.schema + "." + t.name
  }
}

///|
fn Session::exec_alter_table(
  self : Session,
  name : @ast.ObjectName,
  action : @ast.AlterTableAction,
) -> Unit raise {
  let (scope, t) = self.alter_target(name)
  match action {
    Add(body, with_check~) =>
      self.alter_add(
        scope,
        t,
        body,
        with_check.unwrap_or(true),
        object_text(name),
      )
    DropItems(items) => self.alter_drop(scope, t, items)
    AlterColumn(col, ty, collate~, nullable~, ..) =>
      self.alter_column(scope, t, col, ty, collate, nullable)
    CheckConstraints(enable~, names, with_check~) =>
      self.alter_check_constraints(scope, t, enable, names, with_check)
    EnableTriggers(enable~, names) => self.alter_triggers(t, enable, names)
    SetOptions(_) => ()
  }
  self.rt.rowcount = 0
  self.done(216)
}

///|
/// Duplicate key check for a new unique index over existing rows (1505).
fn Session::check_unique_build(
  self : Session,
  scope : Int,
  t : @store.Table,
  ix : @store.Index,
  rows : Array[(Int64, @store.Row)],
  constraint : Bool,
) -> Unit raise {
  let types = ix.columns.map(c => t.columns[c.0].ty)
  let cmp = @store.key_comparator(types, ix.columns.map(c => c.1))
  let keys = []
  for r in rows {
    if ix.not_null_filter.iter().any(c => r.1[c] is Null) {
      continue
    }
    keys.push(ix.columns.map(c => r.1[c.0]))
  }
  keys.sort_by(cmp)
  for k = 1; k < keys.length(); k = k + 1 {
    if cmp(keys[k - 1], keys[k]) == 0 {
      let vals = keys[k].mapi((j, v) => key_text(v, types[j])).join(", ")
      let e = @types.sql_error(
        1505,
        "The CREATE UNIQUE INDEX statement terminated because a duplicate key was found for the object name '\{display_name(scope, t)}' and the index name '\{ix.name}'. The duplicate key value is (\{vals}).",
      )
      raise self.terminated(
        if constraint {
          self.constraint_error(e)
        } else {
          e
        },
      )
    }
  }
}

///|
/// Validates CHECK / FOREIGN KEY constraints added WITH CHECK (547).
fn Session::validate_constraints(
  self : Session,
  scope : Int,
  t : @store.Table,
  checks : Array[@store.Check],
  fks : Array[@store.ForeignKey],
  rows : Array[(Int64, @store.Row)],
) -> Unit raise {
  if checks.is_empty() && fks.is_empty() {
    return
  }
  let target : Target = {
    scope,
    table: {
      ..t,
      checks,
      foreign_keys: fks,
      columns: t.columns.map(c => { ..c, nullable: true, }),
    },
    display: display_name(scope, t),
    qualifier: t.name.to_lower(),
  }
  let db = self.db_of(scope)
  let ctarget = { ..target, table: { ..target.table, foreign_keys: [], }, }
  for r in rows {
    for c in checks {
      let v = self.eval_text(ctarget, c.expr, r.1, Bit)
      if v is Bit(false) {
        let cols = check_columns(c.expr)
        let suffix = if cols.length() == 1 {
          ", column '\{cols[0]}'"
        } else {
          ""
        }
        raise @types.sql_error(
          547,
          "The ALTER TABLE statement conflicted with the CHECK constraint \"\{c.name}\". The conflict occurred in database \"\{if scope == 0 { self.rt.database } else { "tempdb" }}\", table \"\{target.display}\"\{suffix}.",
          state=0,
        )
      }
    }
  }
  let target = { ..target, table: { ..target.table, checks: [], }, }
  for r in rows {
    self.check_row(target, db, r.1, "ALTER TABLE")
  }
}

///|
fn Session::alter_add(
  self : Session,
  scope : Int,
  t : @store.Table,
  body : @ast.TableBody,
  with_check : Bool,
  written : String,
) -> Unit raise {
  let db = self.db_of(scope)
  let b = Builder::of_table(t, scope, written)
  let old_width = t.columns.length()
  let old_checks = t.checks.length()
  let old_fks = t.foreign_keys.length()
  let old_indexes = t.indexes.length()
  let rows = db.rows(t.id)
  let pk_cols : Set[String] = Set([])
  for c in body.columns {
    for k in c.constraints {
      if k.kind is ColPrimaryKey(..) {
        pk_cols.add(c.name.name.to_lower())
      }
    }
  }
  let with_values : Array[Bool] = []
  for c in body.columns {
    self.add_column(b, c, db, pk_cols, with_check)
    let col = b.columns[b.columns.length() - 1]
    let wv = c.constraints
      .iter()
      .any(k => {
        k.kind is ColDefault(_) &&
        self.slice(k.span).trim().to_upper().has_suffix("VALUES")
      })
    with_values.push(wv)
    if !col.nullable &&
      col.default_ is None &&
      col.identity is None &&
      col.computed is None &&
      !(col.ty is RowVersion) &&
      !rows.is_empty() {
      raise @types.sql_error(
        4901,
        "ALTER TABLE only allows columns to be added that can contain nulls, or have a DEFAULT definition specified, or the column being added is an identity or timestamp column, or alternatively if none of the previous conditions are satisfied the table must be empty to allow addition of this column. Column '\{col.name}' cannot be added to non-empty table '\{t.name}' because it does not satisfy these conditions.",
      )
    }
  }
  for k in body.constraints {
    self.add_table_constraint(b, db, k, with_check)
  }
  for ix in body.indexes {
    raise @types.not_supported("ALTER TABLE ADD INDEX (\{ix.0.name})")
  }
  let nt = { ..self.finish(b, t.name), created: t.created, }
  // new column values for existing rows
  let target : Target = {
    scope,
    table: nt,
    display: display_name(scope, nt),
    qualifier: t.name.to_lower(),
  }
  let new_rows = []
  for r in rows {
    let row = r.1.copy()
    for k in old_width..<nt.columns.length() {
      let c = nt.columns[k]
      let v : @types.Value = match (c.identity, c.default_) {
        (Some(idn), _) => identity_value(c.ty, self.next_identity(nt, idn))
        (None, Some(d)) if c.computed is None &&
          (!c.nullable || with_values[k - old_width]) =>
          self.eval_text(target, d, row + [Null], c.ty)
        _ => Null
      }
      row.push(v)
    }
    for k in old_width..<nt.columns.length() {
      let c = nt.columns[k]
      if c.computed is Some(expr) {
        row[k] = self.eval_text(target, expr, row, c.ty)
      }
    }
    new_rows.push((r.0, row))
  }
  for k in old_indexes..<nt.indexes.length() {
    let ix = nt.indexes[k]
    if ix.unique {
      self.check_unique_build(scope, nt, ix, new_rows, true)
    }
  }
  if with_check {
    self.validate_constraints(
      scope,
      nt,
      nt.checks[old_checks:].to_owned(),
      nt.foreign_keys[old_fks:].to_owned(),
      new_rows,
    )
  }
  let nt = { ..nt, modified: self.rt.now, }
  self.write(scope, db.replace_table(nt, new_rows))
}

///|
/// 5074 / 4922: objects that depend on a column being dropped or altered.
fn Session::column_dependents(
  self : Session,
  scope : Int,
  t : @store.Table,
  ord : Int,
  _for_alter : Bool,
) -> Array[String] {
  let col = t.columns[ord]
  let name = col.name.to_lower()
  let mentions = (text : String) => expr_mentions(text, name)
  let out = []
  // captured order: default constraint, indexes/keys, checks, foreign keys
  if col.default_id != 0 {
    out.push(
      "The object '\{col.default_name.unwrap_or("")}' is dependent on column '\{col.name}'.",
    )
  }
  for ix in t.indexes {
    let in_key = ix.columns.iter().any(c => c.0 == ord) ||
      ix.included.contains(ord)
    if ix.is_constraint {
      if in_key {
        out.push(
          "The object '\{ix.name}' is dependent on column '\{col.name}'.",
        )
      }
    } else {
      if in_key {
        out.push("The index '\{ix.name}' is dependent on column '\{col.name}'.")
      }
      if ix.filter.map(mentions).unwrap_or(false) {
        out.push("The index '\{ix.name}' is dependent on column '\{col.name}'.")
      }
    }
  }
  for c in t.checks {
    if c.column_id == col.column_id || mentions(c.expr) {
      out.push("The object '\{c.name}' is dependent on column '\{col.name}'.")
    }
  }
  for f in t.foreign_keys {
    if f.columns.contains(ord) {
      out.push("The object '\{f.name}' is dependent on column '\{col.name}'.")
    }
  }
  for other in self.db_of(scope).tables() {
    for f in other.foreign_keys {
      if f.ref_table == t.id && other.id != t.id && f.ref_columns.contains(ord) {
        out.push("The object '\{f.name}' is dependent on column '\{col.name}'.")
      }
    }
  }
  for c in t.columns {
    if c.computed.map(mentions).unwrap_or(false) {
      out.push("The column '\{c.name}' is dependent on column '\{col.name}'.")
    }
  }
  out
}

///|
/// Does expression text reference column `name` (lowercased)?
fn expr_mentions(text : String, name : String) -> Bool {
  let e = @parse.parse_expr(text) catch { _ => return true }
  let mut found = false
  walk_columns(e, parts => {
    if parts.length() > 0 && parts[parts.length() - 1].name.to_lower() == name {
      found = true
    }
  })
  found
}

///|
fn walk_columns(e : @ast.Expr, f : (Array[@ast.Ident]) -> Unit) -> Unit {
  match e.kind {
    Column(parts) => f(parts)
    Unary(_, x) | Not(x) | Paren(x) | IsNull(x, ..) | Collate(x, _) =>
      walk_columns(x, f)
    Cast(x, _, ..) | Convert(_, x, ..) => walk_columns(x, f)
    Binary(_, l, r)
    | Compare(_, l, r)
    | And(l, r)
    | Or(l, r)
    | AtTimeZone(l, r) => {
      walk_columns(l, f)
      walk_columns(r, f)
    }
    Like(x, p, ..) => {
      walk_columns(x, f)
      walk_columns(p, f)
    }
    Between(x, lo, hi, ..) => {
      walk_columns(x, f)
      walk_columns(lo, f)
      walk_columns(hi, f)
    }
    InList(x, items, ..) => {
      walk_columns(x, f)
      for i in items {
        walk_columns(i, f)
      }
    }
    Case(operand~, whens~, else_~) => {
      if operand is Some(o) {
        walk_columns(o, f)
      }
      for w in whens {
        walk_columns(w.0, f)
        walk_columns(w.1, f)
      }
      if else_ is Some(x) {
        walk_columns(x, f)
      }
    }
    Call(c) =>
      for a in c.args {
        walk_columns(a, f)
      }
    _ => ()
  }
}

///|
/// Raises the 5074 messages then 4922.
fn Session::dependents_error(
  self : Session,
  deps : Array[String],
  verb : String,
  col : String,
) -> @types.SqlError {
  for d in deps {
    self.pending.push(@types.sql_error(5074, d))
  }
  @types.sql_error(
    4922,
    "ALTER TABLE \{verb} \{col} failed because one or more objects access this column.",
    state=9,
  )
}

///|
/// Column ordinal remapping after a column is removed.
fn remap_after_drop(t : @store.Table, ord : Int) -> @store.Table {
  let m = (i : Int) => if i > ord { i - 1 } else { i }
  {
    ..t,
    columns: t.columns.filter(c => c.column_id != t.columns[ord].column_id),
    indexes: t.indexes.map(ix => {
      ..ix,
      columns: ix.columns.map(c => (m(c.0), c.1)),
      included: ix.included.map(m),
      not_null_filter: ix.not_null_filter.map(m),
    }),
    foreign_keys: t.foreign_keys.map(f => {
      ..f,
      columns: f.columns.map(m),
      ref_columns: if f.ref_table == t.id {
        f.ref_columns.map(m)
      } else {
        f.ref_columns
      },
    }),
  }
}

///|
fn Session::alter_drop(
  self : Session,
  scope : Int,
  t0 : @store.Table,
  items : Array[(Bool, Bool, @ast.Ident)],
) -> Unit raise {
  let mut t = t0
  let mut rows = self.db_of(scope).rows(t.id)
  for item in items {
    let (is_column, if_exists, ident) = item
    let key = ident.name.to_lower()
    if is_column {
      guard t.column_index(ident.name) is Some(ord) else {
        if if_exists {
          continue
        }
        raise @types.sql_error(
          4924,
          "ALTER TABLE DROP COLUMN failed because column '\{ident.name}' does not exist in table '\{t.name}'.",
        )
      }
      let deps = self.column_dependents(scope, t, ord, false)
      if !deps.is_empty() {
        raise self.dependents_error(deps, "DROP COLUMN", t.columns[ord].name)
      }
      t = remap_after_drop(t, ord)
      rows = rows.map(r => {
        let row = r.1.copy()
        ignore(row.remove(ord))
        (r.0, row)
      })
      continue
    }
    // constraint
    let mut found = false
    match
      t.indexes
      .iter()
      .find_first(ix => ix.is_constraint && ix.name.to_lower() == key) {
      Some(ix) => {
        found = true
        for other in self.db_of(scope).tables() {
          if other.id == t.id {
            continue
          }
          for f in other.foreign_keys {
            if f.ref_table == t.id &&
              key_index_of(self.db_of(scope), other, f) == Some(ix.index_id) {
              self.pending.push(
                @types.sql_error(
                  3725,
                  "The constraint '\{ix.name}' is being referenced by table '\{other.name}', foreign key constraint '\{f.name}'.",
                  state=0,
                ),
              )
              raise @types.sql_error(
                3727,
                "Could not drop constraint. See previous errors.",
                state=0,
              )
            }
          }
        }
        t = { ..t, indexes: t.indexes.filter(x => x.name.to_lower() != key), }
      }
      None => ()
    }
    if !found && t.checks.iter().any(c => c.name.to_lower() == key) {
      found = true
      t = { ..t, checks: t.checks.filter(c => c.name.to_lower() != key), }
    }
    if !found && t.foreign_keys.iter().any(f => f.name.to_lower() == key) {
      found = true
      t = {
        ..t,
        foreign_keys: t.foreign_keys.filter(f => f.name.to_lower() != key),
      }
    }
    if !found {
      for k, c in t.columns {
        if c.default_id != 0 && c.default_name.unwrap_or("").to_lower() == key {
          found = true
          let cols = t.columns.copy()
          cols[k] = {
            ..c,
            default_: None,
            default_name: None,
            default_id: 0,
            default_auto: false,
          }
          t = { ..t, columns: cols, }
        }
      }
    }
    if !found && !if_exists {
      self.pending.push(
        @types.sql_error(3728, "'\{ident.name}' is not a constraint."),
      )
      raise @types.sql_error(
        3727,
        "Could not drop constraint. See previous errors.",
        state=0,
      )
    }
  }
  let t = { ..t, modified: self.rt.now, }
  self.write(scope, self.db_of(scope).replace_table(t, rows))
}

///|
fn Session::alter_column(
  self : Session,
  scope : Int,
  t : @store.Table,
  col : @ast.Ident,
  type_ : @ast.TypeName,
  collate : @ast.Ident?,
  nullable : Bool?,
) -> Unit raise {
  guard t.column_index(col.name) is Some(ord) else {
    raise @types.sql_error(
      4924,
      "ALTER TABLE ALTER COLUMN failed because column '\{col.name}' does not exist in table '\{t.name}'.",
    )
  }
  let old = t.columns[ord]
  if old.computed is Some(_) {
    raise @types.sql_error(
      4928,
      "Cannot alter column '\{old.name}' because it is 'COMPUTED'.",
    )
  }
  let collation = match collate {
    Some(i) =>
      match @types.Collation::parse(i.name) {
        Some(x) => x
        None => raise @types.sql_error(448, "Invalid collation '\{i.name}'.")
      }
    None => @types.default_collation
  }
  let ty = @bind.resolve_type(type_, Declaration, collation)
  // ANSI_NULL_DFLT_ON: an unspecified nullability makes the column NULL
  let nullable = nullable.unwrap_or(true)
  if ty != old.ty {
    let deps = self.column_dependents(scope, t, ord, true)
    if !deps.is_empty() {
      raise self.dependents_error(deps, "ALTER COLUMN", old.name)
    }
  } else if nullable && !old.nullable {
    if t.indexes
      .iter()
      .any(ix => ix.primary && ix.columns.iter().any(c => c.0 == ord)) {
      raise self.dependents_error(
        self.column_dependents(scope, t, ord, true),
        "ALTER COLUMN",
        old.name,
      )
    }
  }
  let ncol = { ..old, ty, nullable, }
  let cols = t.columns.copy()
  cols[ord] = ncol
  let nt = { ..t, columns: cols, modified: self.rt.now, }
  let target : Target = {
    scope,
    table: nt,
    display: display_name(scope, nt),
    qualifier: t.name.to_lower(),
  }
  let db = self.db_of(scope)
  let rows = []
  for r in db.rows(t.id) {
    let row = r.1.copy()
    let v = self.to_column(target, ncol, row[ord], old.ty) catch {
      @types.SqlError(number=2628, ..) =>
        // ALTER COLUMN reports an empty truncated value (captured)
        raise self.terminated(
          @types.sql_error(
            2628,
            "String or binary data would be truncated in table '\{self.full_name(target)}', column '\{ncol.name}'. Truncated value: ''.",
          ),
        )
      @types.SqlError(..) as e => raise self.terminated(e)
      e => raise e
    }
    if v is Null && !nullable {
      raise self.terminated(
        @types.sql_error(
          515,
          "Cannot insert the value NULL into column '\{ncol.name}', table '\{self.full_name(target)}'; column does not allow nulls. UPDATE fails.",
          state=2,
        ),
      )
    }
    row[ord] = v
    rows.push((r.0, row))
  }
  self.write(scope, db.replace_table(nt, rows))
}

///|
fn Session::alter_check_constraints(
  self : Session,
  scope : Int,
  t : @store.Table,
  enable : Bool,
  names : Array[@ast.Ident],
  with_check : Bool?,
) -> Unit raise {
  let wanted = names.map(n => n.name.to_lower())
  for n in names {
    let k = n.name.to_lower()
    if !t.checks.iter().any(c => c.name.to_lower() == k) &&
      !t.foreign_keys.iter().any(f => f.name.to_lower() == k) {
      self.pending.push(
        @types.sql_error(
          4917,
          "Constraint '\{n.name}' does not exist.",
          state=0,
        ),
      )
      raise @types.sql_error(
        4916,
        "Could not enable or disable the constraint. See previous errors.",
        state=0,
      )
    }
  }
  let picked = (name : String) => {
    wanted.is_empty() || wanted.contains(name.to_lower())
  }
  // WITH CHECK CHECK validates and trusts; plain CHECK leaves untrusted
  let validate = enable && with_check == Some(true)
  let checks = t.checks.map(c => {
    if picked(c.name) {
      {
        ..c,
        enabled: enable,
        not_trusted: if enable {
          c.not_trusted && !validate
        } else {
          true
        },
      }
    } else {
      c
    }
  })
  let fks = t.foreign_keys.map(f => {
    if picked(f.name) {
      {
        ..f,
        enabled: enable,
        not_trusted: if enable {
          f.not_trusted && !validate
        } else {
          true
        },
      }
    } else {
      f
    }
  })
  let nt = { ..t, checks, foreign_keys: fks, }
  if validate {
    let db = self.db_of(scope)
    self.validate_constraints(
      scope,
      nt,
      checks.filter(c => picked(c.name)),
      fks.filter(f => picked(f.name)),
      db.rows(t.id),
    )
  }
  self.write(scope, self.db_of(scope).alter_table(nt))
}

///|
fn Session::alter_triggers(
  self : Session,
  t : @store.Table,
  enable : Bool,
  names : Array[@ast.Ident],
) -> Unit raise {
  let mut db = self.db_of(0)
  let triggers = db
    .modules()
    .filter(m => m.kind is Trigger && m.parent == Some(t.id))
  for n in names {
    if !triggers.iter().any(m => m.name.to_lower() == n.name.to_lower()) {
      raise @types.sql_error(
        4920,
        "ALTER TABLE failed because trigger '\{n.name}' on table '\{t.name}' does not exist.",
        state=0,
      )
    }
  }
  for m in triggers {
    if names.is_empty() ||
      names.iter().any(n => n.name.to_lower() == m.name.to_lower()) {
      db = db.add_module({ ..m, disabled: !enable, })
    }
  }
  self.write(0, db)
}

///|
/// Ordinals of `c IS NOT NULL [AND ...]` filters (None for other shapes).
fn not_null_filter(e : @ast.Expr, t : @store.Table) -> Array[Int]? {
  match e.kind {
    Paren(x) => not_null_filter(x, t)
    And(l, r) =>
      match (not_null_filter(l, t), not_null_filter(r, t)) {
        (Some(a), Some(b)) => Some(a + b)
        _ => None
      }
    IsNull({ kind: Column(parts), .. }, negated=true) =>
      match t.column_index(parts[parts.length() - 1].name) {
        Some(i) => Some([i])
        None => None
      }
    _ => None
  }
}

///|
fn Session::exec_create_index(
  self : Session,
  ci : @ast.CreateIndex,
) -> Unit raise {
  if ci.columnstore {
    raise @types.not_supported("columnstore indexes")
  }
  let (scope, t) = match self.find_table(ci.table) {
    Some(x) => x
    None =>
      raise @types.sql_error(
        1088,
        "Cannot find the object \"\{object_text(ci.table)}\" because it does not exist or you do not have permissions.",
        state=12,
      )
  }
  if t.indexes.iter().any(ix => ix.name.to_lower() == ci.name.name.to_lower()) {
    raise @types.sql_error(
      1913,
      "The operation failed because an index or statistics with name '\{ci.name.name}' already exists on table '\{display_name(scope, t)}'.",
    )
  }
  let col = (n : @ast.Ident) => {
    match t.column_index(n.name) {
      Some(i) => i
      None =>
        raise @types.sql_error(
          1911,
          "Column name '\{n.name}' does not exist in the target table, index or view.",
        )
    }
  }
  let columns = ci.columns.map(c => (col(c.name), c.desc))
  // key columns computed in float/real must be persisted (captured:
  // traps/computed-persisted-index)
  for c in columns {
    let tc = t.columns[c.0]
    if tc.computed is Some(_) && !tc.persisted && tc.ty is (Float | Real) {
      raise @types.sql_error(
        2799,
        "Cannot create index or statistics '\{ci.name.name}' on table '\{t.name}' because the computed column '\{tc.name}' is imprecise and not persisted. Consider removing column from index or statistics key or marking computed column persisted.",
      )
    }
  }
  let included = ci.included.map(col)
  let clustered = ci.clustered.unwrap_or(false)
  if clustered && t.indexes.iter().any(ix => ix.clustered) {
    raise @types.sql_error(
      1902,
      "Cannot create more than one clustered index on table '\{display_name(scope, t)}'. Drop the existing clustered index '\{t.indexes.iter().find_first(ix => ix.clustered).map(ix => ix.name).unwrap_or("")}' before creating another.",
      state=3,
    )
  }
  let (filter, nn) = match ci.where_ {
    Some(w) =>
      match not_null_filter(w, t) {
        Some(cols) => (Some(self.slice(w.span)), cols)
        None if ci.unique =>
          raise @types.not_supported(
            "filtered UNIQUE index with a filter other than IS NOT NULL",
          )
        None => (Some(self.slice(w.span)), [])
      }
    None => (None, [])
  }
  let ix : @store.Index = {
    index_id: if clustered {
      1
    } else {
      next_index_id(t.indexes)
    },
    object_id: 0,
    name: ci.name.name,
    auto_named: false,
    unique: ci.unique,
    primary: false,
    clustered,
    columns,
    included,
    filter,
    not_null_filter: nn,
    is_constraint: false,
  }
  let db = self.db_of(scope)
  if ci.unique {
    self.check_unique_build(scope, t, ix, db.rows(t.id), false)
  }
  let indexes = t.indexes.copy()
  indexes.push(ix)
  self.write(scope, db.alter_table({ ..t, indexes, }))
  self.rt.rowcount = 0
  self.done(200)
}

///|
fn Session::exec_drop_index(
  self : Session,
  if_exists : Bool,
  items : Array[(@ast.ObjectName, @ast.ObjectName?)],
) -> Unit raise {
  self.cur_cmd = 201
  for item in items {
    let (ixname, table) = match item {
      (ix, Some(t)) => (ix.base(), t)
      (n, None) => {
        // legacy `t.ix` / `schema.t.ix`
        let parts = n.parts
        if parts.length() < 2 {
          raise @types.not_supported("DROP INDEX without a table")
        }
        (
          parts[parts.length() - 1].name,
          @ast.ObjectName::{
            parts: parts[:parts.length() - 1].to_owned(),
            span: n.span,
          },
        )
      }
    }
    let missing = () => {
      @types.sql_error(
        3701,
        "Cannot drop the index '\{object_text(table)}.\{ixname}', because it does not exist or you do not have permission.",
        state=7,
        severity=11,
      )
    }
    let (scope, t) = match self.find_table(table) {
      Some(x) => x
      None => if if_exists { continue } else { raise missing() }
    }
    match
      t.indexes.iter().find_first(ix => ix.name.to_lower() == ixname.to_lower()) {
      Some(ix) => {
        if ix.is_constraint {
          self.cur_cmd = 253
          raise @types.sql_error(
            3723,
            "An explicit DROP INDEX is not allowed on index '\{object_text(table)}.\{ix.name}'. It is being used for \{if ix.primary { "PRIMARY KEY" } else { "UNIQUE KEY" }} constraint enforcement.",
            state=4,
          )
        }
        let indexes = t.indexes.filter(x => {
          x.name.to_lower() != ixname.to_lower()
        })
        self.write(scope, self.db_of(scope).alter_table({ ..t, indexes, }))
      }
      None => if !if_exists { raise missing() }
    }
  }
  self.rt.rowcount = 0
  self.done(201)
}

///|
/// Distinct column names a CHECK expression references (source spelling).
fn check_columns(text : String) -> Array[String] {
  let e = @parse.parse_expr(text) catch { _ => return [] }
  let out : Array[String] = []
  walk_columns(e, parts => {
    let n = parts[parts.length() - 1].name
    if !out.iter().any(x => x.to_lower() == n.to_lower()) {
      out.push(n)
    }
  })
  out
}
