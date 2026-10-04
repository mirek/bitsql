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
    if !ix.covers(r.1) {
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
      columns: t.columns.map(c => {
        ..c,
        nullable: true,
        result_nullable: true,
      }),
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
  // a failing ALTER TABLE ADD consumes no object ids (captured: msduck-runs
  // alter-named-default, the table after two failed ADDs keeps the id
  // sequence)
  let ids_mark = self.server.next_object_id
  errdefer {
    self.server.next_object_id = ids_mark
  }
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
  let nt = {
    ..self.finish(b, t.name),
    created: t.created,
    ansi_nulls: t.ansi_nulls,
  }
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
        // captured: existing rows get rowversion values (msduck
        // gaps-rowversion_identity #079)
        _ if c.ty is RowVersion => self.next_rowversion()
        // a default failing for an existing row: the error, then 1750
        // state 0 (captured: msduck-runs alter-named-default #059)
        (None, Some(d)) if c.computed is None &&
          (!c.nullable || with_values[k - old_width]) =>
          self.eval_text(target, d, row + [Null], c.ty) catch {
            @types.SqlError(..) as e => {
              self.pending.push(e)
              raise @types.sql_error(
                1750,
                "Could not create constraint or index. See previous errors.",
                state=0,
              )
            }
            other => raise other
          }
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
/// 5074 / 4922: objects that depend on a column being dropped (`change` is
/// None) or altered to `Some((type, nullable))`.
///
/// Captured (corpus catalog/alter-column-dependents*): SQL Server lists
/// expression dependents first, by kind (defaults, computed columns,
/// filtered index predicates, check constraints), then index and key
/// columns in index order, then foreign keys. A filtered index whose
/// predicate names the column is listed in both phases when the column is
/// also a key that blocks the change.
/// What blocks an ALTER COLUMN:
/// - computed columns and filter predicates: always, even an ALTER that
///   changes nothing;
/// - a DEFAULT: another data type (a new length, precision, scale or
///   collation of the same type is fine);
/// - a CHECK: another data type or collation (new length/precision/scale
///   is fine);
/// - index keys/INCLUDE columns, PRIMARY KEY/UNIQUE: any type change other
///   than growing a bounded varchar/nvarchar/varbinary (collation and
///   precision changes block), NULL to NOT NULL, and NOT NULL to NULL under
///   a PRIMARY KEY;
/// - foreign keys (either side): any type change, growing included.
fn Session::column_dependents(
  self : Session,
  scope : Int,
  t : @store.Table,
  ord : Int,
  change : (@types.SqlType, Bool)?,
) -> Array[String] {
  let col = t.columns[ord]
  let name = col.name.to_lower()
  let mentions = (text : String) => expr_mentions(text, name)
  let (
    type_changed,
    base_changed,
    check_blocks,
    key_type_blocks,
    to_not_null,
    to_null,
  ) = match change {
    None => (true, true, true, true, true, true)
    Some((ty, nullable)) => {
      let changed = ty != col.ty
      let base = changed && !same_base_type(col.ty, ty)
      (
        changed,
        base,
        base || (changed && ty.collation() != col.ty.collation()),
        changed && !widens(col.ty, ty),
        col.nullable && !nullable,
        !col.nullable && nullable,
      )
    }
  }
  let out = []
  if col.default_id != 0 && base_changed {
    out.push(
      "The object '\{col.default_name.unwrap_or("")}' is dependent on column '\{col.name}'.",
    )
  }
  for c in t.columns {
    if c.computed.map(mentions).unwrap_or(false) {
      out.push("The column '\{c.name}' is dependent on column '\{col.name}'.")
    }
  }
  for ix in t.indexes {
    if !ix.is_constraint && ix.filter.map(mentions).unwrap_or(false) {
      out.push("The index '\{ix.name}' is dependent on column '\{col.name}'.")
    }
  }
  if check_blocks {
    for c in t.checks {
      if c.column_id == col.column_id || mentions(c.expr) {
        out.push("The object '\{c.name}' is dependent on column '\{col.name}'.")
      }
    }
  }
  for ix in t.indexes {
    let in_key = ix.columns.iter().any(c => c.0 == ord) ||
      ix.included.contains(ord)
    if !in_key || !(key_type_blocks || to_not_null || (to_null && ix.primary)) {
      continue
    }
    if ix.is_constraint {
      out.push("The object '\{ix.name}' is dependent on column '\{col.name}'.")
    } else {
      out.push("The index '\{ix.name}' is dependent on column '\{col.name}'.")
    }
  }
  if type_changed {
    for f in t.foreign_keys {
      if f.columns.contains(ord) {
        out.push("The object '\{f.name}' is dependent on column '\{col.name}'.")
      }
    }
    for other in self.db_of(scope).tables() {
      for f in other.foreign_keys {
        if f.ref_table == t.id &&
          other.id != t.id &&
          f.ref_columns.contains(ord) {
          out.push(
            "The object '\{f.name}' is dependent on column '\{col.name}'.",
          )
        }
      }
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
      let deps = self.column_dependents(scope, t, ord, None)
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
      // a constraint of another table (captured: msduck gaps-constraints
      // alter-lifecycle-40)
      if self.constraint_owner(scope, key) is Some(_) {
        self.pending.push(
          @types.sql_error(
            3733,
            "Constraint '\{ident.name}' does not belong to table '\{t.name}'.",
            state=2,
          ),
        )
        raise @types.sql_error(
          3727,
          "Could not drop constraint. See previous errors.",
          state=0,
        )
      }
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
        None => raise @types.unknown_collation_error(i.name)
      }
    None => self.scope_collation(scope)
  }
  let ty = @bind.resolve_type(type_, Declaration, collation)
  // captured (json4/type-columns): json → nvarchar(max) is 257 (no 3621)
  if (old.ty is Json || ty is Json) &&
    old.ty != ty &&
    !@types.can_convert_implicitly(old.ty, ty) {
    raise @types.implicit_conversion_error(old.ty, ty)
  }
  self.check_ansi_padding(ty)
  // ANSI_NULL_DFLT_ON: an unspecified nullability makes the column NULL
  let nullable = nullable.unwrap_or(true)
  let deps = self.column_dependents(scope, t, ord, Some((ty, nullable)))
  if !deps.is_empty() {
    raise self.dependents_error(deps, "ALTER COLUMN", old.name)
  }
  let ncol = { ..old, ty, nullable, result_nullable: nullable, }
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
      // a key or default constraint of the table (captured: msduck
      // gaps-constraints alter-lifecycle-35)
      if t.indexes.iter().any(ix => ix.is_constraint && ix.name.to_lower() == k) ||
        t.columns
        .iter()
        .any(c => {
          c.default_id != 0 && c.default_name.unwrap_or("").to_lower() == k
        }) {
        self.pending.push(
          @types.sql_error(
            11415,
            "Object '\{n.name}' cannot be disabled or enabled. This action applies only to foreign key and check constraints.",
          ),
        )
        raise @types.sql_error(
          4916,
          "Could not enable or disable the constraint. See previous errors.",
          state=0,
        )
      }
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
/// CREATE INDEX WITH options SQL Server accepts.
let index_options : Array[String] = [
  "PAD_INDEX", "FILLFACTOR", "SORT_IN_TEMPDB", "IGNORE_DUP_KEY", "STATISTICS_NORECOMPUTE",
  "STATISTICS_INCREMENTAL", "DROP_EXISTING", "ONLINE", "RESUMABLE", "MAX_DURATION",
  "ALLOW_ROW_LOCKS", "ALLOW_PAGE_LOCKS", "OPTIMIZE_FOR_SEQUENTIAL_KEY", "MAXDOP",
  "DATA_COMPRESSION", "XML_COMPRESSION", "COMPRESSION_DELAY",
]

///|
/// Filter conjuncts of a filtered index: `c IS [NOT] NULL` and `c <op>
/// constant` joined by AND (None for other shapes).
fn Session::filter_terms(
  self : Session,
  e : @ast.Expr,
  t : @store.Table,
  out : Array[@store.FilterTerm],
) -> Bool {
  let col = (x : @ast.Expr) => {
    match strip_parens(x).kind {
      Column(parts) => t.column_index(parts[parts.length() - 1].name)
      _ => None
    }
  }
  let constant = (x : @ast.Expr, ci : Int) => {
    if expr_column_names(x).length() > 0 || expr_has_subquery(x) {
      return None
    }
    let env = @bind.Env::new(Map([]), catalog=self.catalog())
    let v = try {
      let bx = @bind.bind_expr(env, x)
      let v = @exec.eval(self.ctx(), bx)
      Some(@types.cast(v, bx.ty, t.columns[ci].ty))
    } catch {
      _ => None
    }
    v
  }
  match e.kind {
    Paren(x) => self.filter_terms(x, t, out)
    And(l, r) => self.filter_terms(l, t, out) && self.filter_terms(r, t, out)
    IsNull(x, negated~) =>
      match col(x) {
        Some(i) => {
          // IS NOT NULL is marked FIsNull(-1 - ordinal): the caller moves
          // it to the not-null filter
          out.push(FIsNull(if negated { -1 - i } else { i }))
          true
        }
        None => false
      }
    Compare(op, l, r) => {
      let (ci, other, flip) = match (col(l), col(r)) {
        (Some(i), None) => (i, r, false)
        (None, Some(i)) => (i, l, true)
        _ => return false
      }
      let fop : @store.FilterOp = match (op, flip) {
        (Eq, _) => FEq
        (Ne, _) => FNe
        (Lt, false) | (Gt, true) => FLt
        (Le, false) | (Ge, true) => FLe
        (Gt, false) | (Lt, true) => FGt
        (Ge, false) | (Le, true) => FGe
        _ => return false
      }
      match constant(other, ci) {
        Some(v) => {
          out.push(FCompare(ci, fop, v))
          true
        }
        None => false
      }
    }
    _ => false
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
  // WITH options (captured: msduck gaps-keys diagnostics-14..17)
  let mut fill_factor = 0
  let mut ignore_dup_key = false
  let mut drop_existing = false
  for o in ci.options {
    let name = o.name.to_upper()
    if !index_options.contains(name) {
      raise @types.sql_error(
        155,
        "'\{o.name}' is not a recognized CREATE INDEX option.",
        severity=15,
      )
    }
    let on = o.value.map(v => v.to_upper() == "ON").unwrap_or(true)
    match name {
      "FILLFACTOR" => {
        let n = parse_i64(o.value, 0L)
        if n < 1L || n > 100L {
          raise @types.sql_error(
            129,
            "Fillfactor \{n} is not a valid percentage; fillfactor must be between 1 and 100.",
            severity=15,
          )
        }
        fill_factor = n.to_int()
      }
      "IGNORE_DUP_KEY" => ignore_dup_key = on
      "DROP_EXISTING" => drop_existing = on
      _ => ()
    }
  }
  if ignore_dup_key && !ci.unique {
    raise @types.sql_error(
      1916,
      "CREATE INDEX options nonunique and ignore_dup_key are mutually exclusive.",
      state=4,
    )
  }
  let existing = t.indexes.search_by(ix => {
    ix.name.to_lower() == ci.name.name.to_lower()
  })
  if drop_existing && existing is None {
    raise @types.sql_error(
      7999,
      "Could not find any index named '\{ci.name.name}' for table '\{object_text(ci.table)}'.",
      state=9,
    )
  }
  if !drop_existing && existing is Some(_) {
    raise @types.sql_error(
      1913,
      "The operation failed because an index or statistics with name '\{ci.name.name}' already exists on table '\{object_text(ci.table)}'.",
    )
  }
  // DROP_EXISTING rebuilds the index in place (same index_id)
  let base = match existing {
    Some(k) => {
      if t.indexes[k].is_constraint {
        raise @types.not_supported(
          "CREATE INDEX DROP_EXISTING of a constraint index",
        )
      }
      {
        ..t,
        indexes: t.indexes.filter(ix => ix.index_id != t.indexes[k].index_id),
      }
    }
    None => t
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
  for k, c in columns {
    let tc = t.columns[c.0]
    if columns[:k].iter().any(x => x.0 == c.0) {
      raise @types.sql_error(
        1909,
        "Cannot use duplicate column names in index. Column name '\{tc.name}' listed more than once.",
      )
    }
    // captured (json4/type-compare): CREATE INDEX on json is 1978 state 3
    if tc.ty is Json {
      raise @types.sql_error(
        1978,
        "Column '\{tc.name}' in table '\{object_text(ci.table)}' is of a type that is invalid for use as a key column in an index or statistics.",
        state=3,
      )
    }
    if invalid_key_type(tc.ty) {
      raise @types.sql_error(
        1919,
        "Column '\{tc.name}' in table '\{object_text(ci.table)}' is of a type that is invalid for use as a key column in an index.",
      )
    }
  }
  // key columns computed in float/real must be persisted (captured:
  // traps/computed-persisted-index)
  for c in columns {
    let tc = t.columns[c.0]
    // captured: msduck-runs tedious-compat-gaps#042 (GETDATE())
    let nondeterministic = match tc.computed {
      Some(text) =>
        expr_nondeterministic(@parse.parse_expr(text)) catch {
          _ => false
        }
      None => false
    }
    if nondeterministic {
      raise @types.sql_error(
        2729,
        "Column '\{tc.name}' in table '\{t.name}' cannot be used in an index or statistics or as a partition key because it is non-deterministic.",
      )
    }
    if tc.computed is Some(_) && !tc.persisted && tc.ty is (Float | Real) {
      raise @types.sql_error(
        2799,
        "Cannot create index or statistics '\{ci.name.name}' on table '\{t.name}' because the computed column '\{tc.name}' is imprecise and not persisted. Consider removing column from index or statistics key or marking computed column persisted.",
      )
    }
  }
  let included = ci.included.map(col)
  let clustered = ci.clustered.unwrap_or(false)
  if clustered && base.indexes.iter().any(ix => ix.clustered) {
    raise @types.sql_error(
      1902,
      "Cannot create more than one clustered index on table '\{object_text(ci.table)}'. Drop the existing clustered index '\{base.indexes.iter().find_first(ix => ix.clustered).map(ix => ix.name).unwrap_or("")}' before creating another.",
      state=3,
    )
  }
  let (filter, nn, terms) = match ci.where_ {
    Some(w) => {
      for n in expr_column_names(w) {
        if t.column_index(n) is None {
          raise @types.sql_error(207, "Invalid column name '\{n}'.")
        }
      }
      let terms : Array[@store.FilterTerm] = []
      if self.filter_terms(w, t, terms) {
        // IS NOT NULL conjuncts are recorded as FIsNull(-1 - ordinal)
        let nn = []
        let rest = []
        for x in terms {
          match x {
            FIsNull(i) if i < 0 => nn.push(-1 - i)
            other => rest.push(other)
          }
        }
        (Some(self.slice(w.span)), nn, rest)
      } else if ci.unique {
        raise @types.not_supported(
          "filtered UNIQUE index with a filter other than AND of column comparisons",
        )
      } else {
        // non-unique: kept as text; the index holds every row
        (Some(self.slice(w.span)), [], [])
      }
    }
    None => (None, [], [])
  }
  let ix : @store.Index = {
    index_id: match existing {
      Some(k) => t.indexes[k].index_id
      None => if clustered { 1 } else { next_index_id(t.indexes) }
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
    filter_terms: terms,
    fill_factor,
    ignore_dup_key,
    is_constraint: false,
    disabled: false,
  }
  let db = self.db_of(scope)
  if ci.unique {
    self.check_unique_build(scope, t, ix, db.rows(t.id), false)
  }
  // maximum key length warnings (captured: msduck gaps-computed
  // unicode-virtual-7, 1945 for an nvarchar(4000) key)
  let key_len = columns.fold(init=0, (acc, c) => {
    acc + type_ids(t.columns[c.0].ty).2
  })
  if clustered && key_len > 900 {
    self.info(
      1944,
      1,
      "Warning! The maximum key length for a clustered index is 900 bytes. The index '\{ci.name.name}' has maximum length of \{key_len} bytes. For some combination of large values, the insert/update operation will fail.",
      self.stmt_line,
    )
  } else if !clustered && key_len > 1700 {
    self.info(
      1945,
      1,
      "Warning! The maximum key length for a nonclustered index is 1700 bytes. The index '\{ci.name.name}' has maximum length of \{key_len} bytes. For some combination of large values, the insert/update operation will fail.",
      self.stmt_line,
    )
  }
  let indexes = base.indexes.copy()
  indexes.push(ix)
  indexes.sort_by((a, b) => a.index_id.compare(b.index_id))
  self.write(scope, db.alter_table({ ..t, indexes, }))
  self.rt.rowcount = 0
  self.done(200)
}

///|
fn Session::exec_drop_index(
  self : Session,
  if_exists : Bool,
  items : Array[(@ast.ObjectName, @ast.ObjectName?, Bool)],
) -> Unit raise {
  self.cur_cmd = 201
  let mut failure : @types.SqlError? = None
  for item in items {
    let (ixname, table) = match item {
      (ix, Some(t), _) => (ix.base(), t)
      (n, None, _) => {
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
    // a missing table is state 6, a missing index state 7 (captured:
    // msduck-runs drop-index #005, #007, #008)
    let missing = (state : Int) => {
      @types.sql_error(
        3701,
        "Cannot drop the index '\{object_text(table)}.\{ixname}', because it does not exist or you do not have permission.",
        state~,
        severity=11,
      )
    }
    let (scope, t) = match self.find_table(table) {
      Some(x) => x
      None =>
        if if_exists {
          continue
        } else {
          failure = Some(missing(6))
          break
        }
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
        if item.2 && !ix.clustered {
          // a compile-time error: the batch ends (CurCmd 253)
          self.cur_cmd = 253
          raise @types.sql_error(
            3748,
            "Cannot drop non-clustered index '\{object_text(table)}.\{ix.name}' using drop clustered index clause.",
          )
        }
        let indexes = t.indexes.filter(x => {
          x.name.to_lower() != ixname.to_lower()
        })
        self.write(scope, self.db_of(scope).alter_table({ ..t, indexes, }))
      }
      None =>
        if !if_exists {
          failure = Some(missing(7))
          break
        }
    }
  }
  // the indexes dropped before a missing one stay dropped: ERROR, then the
  // statement's DONE with the error bit (captured: drop-index #015, #018)
  if failure is Some(e) {
    if self.try_depth > 0 {
      raise e
    }
    self.message(e, self.stmt_line)
    self.stmt_error = e.number()
    self.rt.rowcount = 0
    self.done(201, error=true)
    return
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

///|
/// The table owning a constraint (key, CHECK, FOREIGN KEY, DEFAULT) named
/// `key` (lowercased).
fn Session::constraint_owner(
  self : Session,
  scope : Int,
  key : String,
) -> @store.Table? {
  for t in self.db_of(scope).tables() {
    if t.indexes.iter().any(ix => ix.is_constraint && ix.name.to_lower() == key) ||
      t.checks.iter().any(c => c.name.to_lower() == key) ||
      t.foreign_keys.iter().any(f => f.name.to_lower() == key) ||
      t.columns
      .iter()
      .any(c => {
        c.default_id != 0 && c.default_name.unwrap_or("").to_lower() == key
      }) {
      return Some(t)
    }
  }
  None
}

///|
/// A bounded variable-length type growing within its kind (varchar(10) to
/// varchar(20), not to max).
/// The same data type with another length, precision or scale (not to or
/// from max): ALTER COLUMN may change it under a DEFAULT constraint
/// (captured: corpus orm/alter-column-default; Sequelize's changeColumn).
fn same_base_type(old : @types.SqlType, new : @types.SqlType) -> Bool {
  match (old, new) {
    (VarChar(Some(_), _), VarChar(Some(_), _))
    | (NVarChar(Some(_), _), NVarChar(Some(_), _))
    | (VarBinary(Some(_)), VarBinary(Some(_)))
    | (Char(_, _), Char(_, _))
    | (NChar(_, _), NChar(_, _))
    | (Binary(_), Binary(_))
    | (Decimal(_, _), Decimal(_, _))
    | (Numeric(_, _), Numeric(_, _))
    | (Time(_), Time(_))
    | (DateTime2(_), DateTime2(_))
    | (DateTimeOffset(_), DateTimeOffset(_)) => true
    _ => false
  }
}

///|
fn widens(old : @types.SqlType, new : @types.SqlType) -> Bool {
  match (old, new) {
    (VarChar(Some(a), c1), VarChar(Some(b), c2))
    | (NVarChar(Some(a), c1), NVarChar(Some(b), c2)) => b >= a && c1 == c2
    (VarBinary(Some(a)), VarBinary(Some(b))) => b >= a
    _ => false
  }
}
