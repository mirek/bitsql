///|
/// Source text of a node (definitions are stored as text, like SQL Server).
fn Session::slice(self : Session, span : @ast.Span) -> String {
  if span.start >= 0 && span.end <= self.text.length() && span.start <= span.end {
    self.text.unsafe_substring(start=span.start, end=span.end)
  } else {
    ""
  }
}

///|
fn parse_i64(s : String?, default : Int64) -> Int64 {
  match s {
    None => default
    Some(t) => {
      let neg = t.has_prefix("-")
      let mut v = 0L
      for c in t {
        if c >= '0' && c <= '9' {
          v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
        }
      }
      if neg {
        -v
      } else {
        v
      }
    }
  }
}

///|
fn ref_action(a : @ast.RefAction?) -> @store.RefAction {
  match a {
    Some(Cascade) => Cascade
    Some(SetNull) => SetNull
    Some(SetDefault) => SetDefault
    _ => NoAction
  }
}

///|
/// Random 16-hex-digit suffix of system-named PRIMARY KEY / UNIQUE
/// constraints (SQL Server: `PK__t__3213E83FD6586145`).
fn Session::name_suffix(self : Session) -> String {
  let r = self.rt.next_random()
  let s = r.to_string(radix=16).to_upper()
  if s.length() >= 16 {
    s.unsafe_substring(start=0, end=16)
  } else {
    "0".repeat(16 - s.length()) + s
  }
}

///|
/// DEFAULT / CHECK / FOREIGN KEY system names end with the constraint's
/// object id in hex (captured: `DF__p__v__4BAC3F29` has object_id
/// 0x4BAC3F29).
fn hex_id(id : Int) -> String {
  let s = id.to_string(radix=16).to_upper()
  if s.length() >= 8 {
    s
  } else {
    "0".repeat(8 - s.length()) + s
  }
}

///|
fn short(name : String, n : Int) -> String {
  if name.length() > n {
    name.unsafe_substring(start=0, end=n)
  } else {
    name
  }
}

///|
/// Constraint/index errors come as a pair: the cause, then 1750.
fn Session::constraint_error(
  self : Session,
  cause : @types.SqlError,
) -> @types.SqlError {
  self.pending.push(cause)
  // captured: state 1 after 2714 / 1505, state 0 after 1779 / 1911
  let state = if cause.number() == 2714 || cause.number() == 1505 {
    1
  } else {
    0
  }
  @types.sql_error(
    1750,
    "Could not create constraint or index. See previous errors.",
    state~,
  )
}

///|
/// A table definition under construction (CREATE TABLE, ALTER TABLE ADD).
priv struct Builder {
  id : Int
  schema : String
  /// Table name as used in generated constraint names ("" for variables).
  display : String
  scope : Int
  /// Table name as written in the statement (messages such as 2705).
  written : String
  columns : Array[@store.Column]
  indexes : Array[@store.Index]
  checks : Array[@store.Check]
  fks : Array[@store.ForeignKey]
  mut max_column_id : Int
  /// Lowercased constraint names created by this statement.
  names : Set[String]
}

///|
fn Builder::of_table(
  t : @store.Table,
  scope : Int,
  written : String,
) -> Builder {
  {
    id: t.id,
    schema: t.schema,
    display: if t.name.has_prefix("@") {
      ""
    } else {
      t.name
    },
    scope,
    written,
    columns: t.columns.copy(),
    indexes: t.indexes.copy(),
    checks: t.checks.copy(),
    fks: t.foreign_keys.copy(),
    max_column_id: t.max_column_id,
    names: Set([]),
  }
}

///|
fn Builder::col_index(self : Builder, name : String) -> Int {
  let k = name.to_lower()
  for i, c in self.columns {
    if c.name.to_lower() == k {
      return i
    }
  }
  -1
}

///|
/// True when a schema-scoped object (table, module or constraint) already
/// has this name.
fn Session::object_name_taken(
  self : Session,
  db : @store.Db,
  schema : String,
  name : String,
) -> Bool {
  if db.lookup(schema, name) is Some(_) {
    return true
  }
  let k = name.to_lower()
  let s = schema.to_lower()
  for t in db.tables() {
    if t.schema.to_lower() != s {
      continue
    }
    for c in t.columns {
      if c.default_id != 0 && c.default_name.unwrap_or("").to_lower() == k {
        return true
      }
    }
    for ix in t.indexes {
      if ix.is_constraint && ix.name.to_lower() == k {
        return true
      }
    }
    if t.checks.iter().any(c => c.name.to_lower() == k) ||
      t.foreign_keys.iter().any(f => f.name.to_lower() == k) {
      return true
    }
  }
  ignore(self)
  false
}

///|
/// Reserves a constraint name: explicit names must be free (2714 + 1750).
fn Session::claim_name(
  self : Session,
  b : Builder,
  db : @store.Db,
  name : String,
) -> Unit raise {
  let k = name.to_lower()
  // Temp-table and table-variable constraint names are not schema-scoped
  // in the emulator (SQL Server makes system names unique in tempdb).
  if b.names.contains(k) ||
    (b.scope == 0 && self.object_name_taken(db, b.schema, name)) {
    raise self.constraint_error(
      @types.sql_error(
        2714,
        "There is already an object named '\{name}' in the database.",
        state=5,
      ),
    )
  }
  b.names.add(k)
}

///|
fn Session::new_check(
  self : Session,
  b : Builder,
  db : @store.Db,
  name : @ast.Ident?,
  e : @ast.Expr,
  column : @store.Column?,
  not_trusted : Bool,
  not_for_replication : Bool,
) -> @store.Check raise {
  let id = self.server.object_id()
  let (cname, auto) = match name {
    Some(n) => (n.name, false)
    None =>
      match column {
        Some(c) =>
          (
            "CK__\{short(b.display, 9)}__\{short(c.name, 5)}__\{hex_id(id)}",
            true,
          )
        None => ("CK__\{short(b.display, 9)}__\{hex_id(id)}", true)
      }
  }
  self.claim_name(b, db, cname)
  // a CHECK must bind against the table's columns
  let env = @bind.Env::new(Map([]), catalog=self.catalog()).with_columns(
    b.columns.map(x => @bind.ColumnRef::{
      qualifier: "",
      name: x.name,
      ty: x.ty,
      nullable: x.nullable,
      origin: Computed,
    }),
  )
  ignore(@bind.bind_expr(env, e))
  {
    id,
    name: cname,
    expr: self.slice(e.span),
    enabled: true,
    not_trusted,
    column_id: match column {
      Some(c) => c.column_id
      None => 0
    },
    auto_named: auto,
    not_for_replication,
  }
}

///|
/// Adds a column definition (with its column-level constraints).
fn Session::add_column(
  self : Session,
  b : Builder,
  c : @ast.ColumnDef,
  db : @store.Db,
  pk_cols : Set[String],
  with_check : Bool,
) -> Unit raise {
  if b.col_index(c.name.name) >= 0 {
    raise @types.sql_error(
      2705,
      "Column names in each table must be unique. Column name '\{c.name.name}' in table '\{b.written}' is specified more than once.",
      state=4,
    )
  }
  let collation = match c.collate {
    Some(i) =>
      match @types.Collation::parse(i.name) {
        Some(x) => x
        None => raise @types.sql_error(448, "Invalid collation '\{i.name}'.")
      }
    None => @types.default_collation
  }
  let (ty, computed) = match (c.type_, c.computed) {
    (Some(t), _) => (@bind.resolve_type(t, Declaration, collation), None)
    (None, Some(e)) => {
      // computed column: type of its expression over the other columns
      let env = @bind.Env::new(Map([]), catalog=self.catalog()).with_columns(
        b.columns.map(x => @bind.ColumnRef::{
          qualifier: "",
          name: x.name,
          ty: x.ty,
          nullable: x.nullable,
          origin: Computed,
        }),
      )
      let bound = @bind.bind_expr(env, e)
      (bound.ty, Some(self.slice(e.span)))
    }
    (None, None) =>
      raise @types.sql_error(
        173,
        "The definition for column '\{c.name.name}' must include a data type.",
      )
  }
  let nullable = match c.nullable {
    Some(n) => n
    None =>
      computed is Some(_) ||
      (
        !pk_cols.contains(c.name.name.to_lower()) &&
        c.identity is None &&
        !(ty is RowVersion)
      )
  }
  b.max_column_id += 1
  let column_id = b.max_column_id
  let mut col : @store.Column = {
    column_id,
    name: c.name.name,
    ty,
    nullable,
    identity: match c.identity {
      Some(i) =>
        Some(@store.Identity::{
          seed: parse_i64(i.seed, 1L),
          increment: parse_i64(i.increment, 1L),
        })
      None => None
    },
    default_: None,
    default_name: None,
    default_id: 0,
    default_auto: false,
    computed,
    persisted: c.persisted,
    rowguidcol: c.rowguidcol,
  }
  if col.identity is Some(_) && b.columns.iter().any(x => x.identity is Some(_)) {
    raise @types.sql_error(
      2744,
      "Multiple identity columns specified for table '\{b.display}'. Only one identity column per table is allowed.",
    )
  }
  for k in c.constraints {
    if k.kind is ColDefault(e) {
      let id = self.server.object_id()
      let (name, auto) = match k.name {
        Some(n) => (n.name, false)
        None =>
          (
            "DF__\{short(b.display, 9)}__\{short(c.name.name, 5)}__\{hex_id(id)}",
            true,
          )
      }
      self.claim_name(b, db, name)
      col = {
        ..col,
        default_: Some(self.slice(e.span)),
        default_name: Some(name),
        default_id: id,
        default_auto: auto,
      }
    }
  }
  b.columns.push(col)
  let ordinal = b.columns.length() - 1
  for k in c.constraints {
    match k.kind {
      ColCheck(e, not_for_replication~) =>
        b.checks.push(
          self.new_check(
            b,
            db,
            k.name,
            e,
            Some(col),
            !with_check,
            not_for_replication,
          ),
        )
      ColPrimaryKey(clustered~, ..) =>
        self.add_key(b, db, k.name, true, [(ordinal, false)], clustered)
      ColUnique(clustered~, ..) =>
        self.add_key(b, db, k.name, false, [(ordinal, false)], clustered)
      ColReferences(r) =>
        b.fks.push(self.foreign_key(b, db, k.name, [ordinal], r, !with_check))
      ColDefault(_) => ()
    }
  }
}

///|
/// Adds a PRIMARY KEY / UNIQUE constraint with its index.
fn Session::add_key(
  self : Session,
  b : Builder,
  db : @store.Db,
  cname : @ast.Ident?,
  primary : Bool,
  cols : Array[(Int, Bool)],
  clustered : Bool?,
) -> Unit raise {
  if primary && b.indexes.iter().any(i => i.primary) {
    self.uncatchable = true
    raise self.constraint_error(
      @types.sql_error(
        1779,
        "Table '\{b.display}' already has a primary key defined on it.",
        state=0,
      ),
    )
  }
  let has_clustered = b.indexes.iter().any(i => i.clustered)
  let clustered = match clustered {
    Some(true) => {
      if has_clustered {
        raise self.constraint_error(
          @types.sql_error(
            1902,
            "Cannot create more than one clustered index on table '\{b.display}'. Drop the existing clustered index before creating another.",
            state=3,
          ),
        )
      }
      true
    }
    Some(false) => false
    None => primary && !has_clustered
  }
  if primary {
    for c in cols {
      if b.columns[c.0].nullable {
        raise self.constraint_error(
          @types.sql_error(
            8111,
            "Cannot define PRIMARY KEY constraint on nullable column in table '\{b.display}'.",
          ),
        )
      }
    }
  }
  let kind = if primary { "PK" } else { "UQ" }
  let (name, auto) = match cname {
    Some(n) => (n.name, false)
    None => ("\{kind}__\{short(b.display, 8)}__\{self.name_suffix()}", true)
  }
  self.claim_name(b, db, name)
  b.indexes.push({
    index_id: if clustered {
      1
    } else {
      next_index_id(b.indexes)
    },
    object_id: self.server.object_id(),
    name,
    auto_named: auto,
    unique: true,
    primary,
    clustered,
    columns: cols,
    included: [],
    filter: None,
    not_null_filter: [],
    is_constraint: true,
  })
}

///|
fn next_index_id(indexes : Array[@store.Index]) -> Int {
  let mut m = 1
  for ix in indexes {
    if ix.index_id > m {
      m = ix.index_id
    }
  }
  m + 1
}

///|
fn Session::foreign_key(
  self : Session,
  b : Builder,
  db : @store.Db,
  name : @ast.Ident?,
  cols : Array[Int],
  r : @ast.ForeignRef,
  not_trusted : Bool,
) -> @store.ForeignKey raise {
  let (schema, base) = split_name(r.table)
  // a self-reference resolves to the table being built
  let self_ref = base.to_lower() == b.display.to_lower() &&
    schema.to_lower() == b.schema.to_lower()
  let (ref_id, ref_cols, ref_keys) = if self_ref {
    (b.id, b.columns.map(c => c.name), b.indexes)
  } else {
    let found = if b.scope == 1 {
      // temp tables can reference only temp tables (and FKs on them are
      // not enforced by SQL Server; the emulator enforces them)
      match self.temp.lookup("dbo", base) {
        Some(id) => self.temp.table(id)
        None => None
      }
    } else {
      match db.lookup(schema, base) {
        Some(id) => db.table(id)
        None => None
      }
    }
    match found {
      Some(t) => (t.id, t.columns.map(c => c.name), t.indexes)
      None =>
        raise self.constraint_error(
          @types.sql_error(
            1767,
            "Foreign key '\{name.map(n => n.name).unwrap_or("")}' references invalid table '\{object_text(r.table)}'.",
            state=0,
          ),
        )
    }
  }
  let ref_columns = if r.columns.is_empty() {
    let pk = ref_keys.iter().filter(i => i.primary).collect()
    match pk {
      [pk, ..] => pk.columns.map(c => c.0)
      [] =>
        raise self.constraint_error(
          @types.sql_error(
            1773,
            "Foreign key '\{name.map(n => n.name).unwrap_or("")}' has implicit reference to object '\{base}' which does not have a primary key defined on it.",
            state=0,
          ),
        )
    }
  } else {
    r.columns.map(c => {
      let k = c.name.to_lower()
      let mut found = -1
      for i, n in ref_cols {
        if n.to_lower() == k {
          found = i
        }
      }
      found
    })
  }
  if ref_columns.iter().any(i => i < 0) {
    raise self.constraint_error(
      @types.sql_error(
        1770,
        "Foreign key '\{name.map(n => n.name).unwrap_or("")}' references invalid column in referenced table '\{base}'.",
        state=0,
      ),
    )
  }
  // the referenced columns must be a PRIMARY KEY or UNIQUE key
  let sorted = ref_columns.copy()
  sorted.sort()
  let keyed = ref_keys
    .iter()
    .any(ix => {
      if !ix.unique || ix.filter is Some(_) {
        return false
      }
      let k = ix.columns.map(c => c.0)
      k.sort()
      k == sorted
    })
  if !keyed {
    raise self.constraint_error(
      @types.sql_error(
        1776,
        "There are no primary or candidate keys in the referenced table '\{schema}.\{base}' that match the referencing column list in the foreign key '\{name.map(n => n.name).unwrap_or("")}'.",
        state=0,
      ),
    )
  }
  let id = self.server.object_id()
  let (fk_name, auto) = match name {
    Some(n) => (n.name, false)
    None =>
      (
        "FK__\{short(b.display, 9)}__\{short(b.columns[cols[0]].name, 5)}__\{hex_id(id)}",
        true,
      )
  }
  self.claim_name(b, db, fk_name)
  {
    id,
    name: fk_name,
    columns: cols,
    ref_table: ref_id,
    ref_columns,
    on_delete: ref_action(r.on_delete),
    on_update: ref_action(r.on_update),
    enabled: true,
    not_trusted,
    auto_named: auto,
    not_for_replication: r.not_for_replication,
  }
}

///|
/// Adds a table-level constraint.
fn Session::add_table_constraint(
  self : Session,
  b : Builder,
  db : @store.Db,
  k : @ast.TableConstraint,
  with_check : Bool,
) -> Unit raise {
  let index_cols = (cols : Array[@ast.IndexColumn]) => {
    let out = []
    for ic in cols {
      let i = b.col_index(ic.name.name)
      if i < 0 {
        raise self.constraint_error(
          @types.sql_error(
            1911,
            "Column name '\{ic.name.name}' does not exist in the target table, index or view.",
          ),
        )
      }
      out.push((i, ic.desc))
    }
    out
  }
  match k.kind {
    PrimaryKey(cols, clustered~, ..) =>
      self.add_key(b, db, k.name, true, index_cols(cols), clustered)
    Unique(cols, clustered~, ..) =>
      self.add_key(b, db, k.name, false, index_cols(cols), clustered)
    Check(e, not_for_replication~) =>
      b.checks.push(
        self.new_check(b, db, k.name, e, None, !with_check, not_for_replication),
      )
    ForeignKey(cols, r) => {
      let idx = []
      for c in cols {
        let i = b.col_index(c.name)
        if i < 0 {
          raise self.constraint_error(
            @types.sql_error(
              1769,
              "Foreign key '\{k.name.map(n => n.name).unwrap_or("")}' references invalid column '\{c.name}' in referencing table '\{b.display}'.",
            ),
          )
        }
        idx.push(i)
      }
      b.fks.push(self.foreign_key(b, db, k.name, idx, r, !with_check))
    }
    DefaultFor(e, col) => {
      let i = b.col_index(col.name)
      if i < 0 {
        raise self.constraint_error(
          @types.sql_error(
            1752,
            "Column '\{col.name}' in table '\{b.display}' is invalid for creating a default constraint.",
          ),
        )
      }
      if b.columns[i].default_id != 0 {
        raise self.constraint_error(
          @types.sql_error(1781, "Column already has a DEFAULT bound to it."),
        )
      }
      let id = self.server.object_id()
      let (name, auto) = match k.name {
        Some(n) => (n.name, false)
        None =>
          (
            "DF__\{short(b.display, 9)}__\{short(col.name, 5)}__\{hex_id(id)}",
            true,
          )
      }
      self.claim_name(b, db, name)
      b.columns[i] = {
        ..b.columns[i],
        default_: Some(self.slice(e.span)),
        default_name: Some(name),
        default_id: id,
        default_auto: auto,
      }
    }
  }
}

///|
fn Session::finish(self : Session, b : Builder, name : String) -> @store.Table {
  {
    id: b.id,
    schema: b.schema,
    name,
    columns: b.columns,
    indexes: b.indexes,
    checks: b.checks,
    foreign_keys: b.fks,
    created: self.rt.now,
    modified: self.rt.now,
    max_column_id: b.max_column_id,
  }
}

///|
/// Builds a table definition from CREATE TABLE / DECLARE @t TABLE syntax.
fn Session::table_from_body(
  self : Session,
  id : Int,
  schema : String,
  name : String,
  body : @ast.TableBody,
  db : @store.Db,
  scope : Int,
) -> @store.Table raise {
  let b : Builder = {
    id,
    schema,
    display: if name.has_prefix("@") {
      ""
    } else {
      name
    },
    scope,
    written: name,
    columns: [],
    indexes: [],
    checks: [],
    fks: [],
    max_column_id: 0,
    names: Set([]),
  }
  let pk_cols : Set[String] = Set([])
  // PK columns are implicitly NOT NULL.
  for c in body.columns {
    for k in c.constraints {
      if k.kind is ColPrimaryKey(..) {
        pk_cols.add(c.name.name.to_lower())
      }
    }
  }
  for k in body.constraints {
    if k.kind is PrimaryKey(cols, ..) {
      for ic in cols {
        pk_cols.add(ic.name.name.to_lower())
      }
    }
  }
  let primaries = body.columns
    .iter()
    .map(c => {
      c.constraints.iter().filter(k => k.kind is ColPrimaryKey(..)).count()
    })
    .fold(init=0, (a, n) => a + n) +
    body.constraints.iter().filter(k => k.kind is PrimaryKey(_, ..)).count()
  if primaries > 1 {
    raise self.constraint_error(
      @types.sql_error(
        8110,
        "Cannot add multiple PRIMARY KEY constraints to table '\{b.display}'.",
      ),
    )
  }
  for c in body.columns {
    self.add_column(b, c, db, pk_cols, true)
  }
  for k in body.constraints {
    self.add_table_constraint(b, db, k, true)
  }
  for ix in body.indexes {
    let cols = []
    for ic in ix.1 {
      let i = b.col_index(ic.name.name)
      if i < 0 {
        raise @types.sql_error(
          1911,
          "Column name '\{ic.name.name}' does not exist in the target table or view.",
        )
      }
      cols.push((i, ic.desc))
    }
    b.indexes.push({
      index_id: next_index_id(b.indexes),
      object_id: 0,
      name: ix.0.name,
      auto_named: false,
      unique: false,
      primary: false,
      clustered: false,
      columns: cols,
      included: [],
      filter: None,
      not_null_filter: [],
      is_constraint: false,
    })
  }
  self.finish(b, name)
}

///|
fn Session::exec_create_table(
  self : Session,
  ct : @ast.CreateTable,
) -> Unit raise {
  let (schema, base) = split_name(ct.name)
  let scope = if base.has_prefix("#") { 1 } else { 0 }
  let db = self.db_of(scope)
  let schema = if scope == 1 { "dbo" } else { schema }
  if db.lookup(schema, base) is Some(_) ||
    (scope == 0 && self.object_name_taken(db, schema, base)) {
    raise @types.sql_error(
      2714,
      "There is already an object named '\{base}' in the database.",
      state=6,
    )
  }
  if scope == 0 && db.schema_id(schema) is None {
    raise @types.sql_error(
      2760,
      "The specified schema name \"\{schema}\" either does not exist or you do not have permission to use it.",
    )
  }
  let id = self.server.object_id()
  let t = self.table_from_body(id, schema, base, ct.body, db, scope)
  self.write(scope, db.create_table(t))
  self.rt.rowcount = 0
  self.done(198)
}

///|
fn Session::exec_declare_table(
  self : Session,
  name : String,
  body : @ast.TableBody,
) -> Unit raise {
  let key = name.to_lower()
  if self.frame().tables.contains(key) || self.frame().vars.contains(key) {
    raise @types.sql_error(
      134,
      "The variable name '\{name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
      severity=15,
    )
  }
  let id = self.server.object_id()
  let internal = "@" + id.to_string()
  let t = self.table_from_body(id, "dbo", internal, body, self.tvars, 3)
  self.tvars = self.tvars.create_table(t)
  self.frame().tables[key] = id
}

///|
fn object_text(name : @ast.ObjectName) -> String {
  name.parts.map(p => p.name).join(".")
}

///|
/// 3701 for DROP of a missing object (class 11, captured per kind).
fn drop_missing(kind : String, name : @ast.ObjectName) -> @types.SqlError {
  @types.sql_error(
    3701,
    "Cannot drop the \{kind} '\{object_text(name)}', because it does not exist or you do not have permission.",
    state=5,
    severity=11,
  )
}

///|
fn Session::exec_drop(
  self : Session,
  kind : @ast.DropKind,
  if_exists : Bool,
  names : Array[@ast.ObjectName],
) -> Unit raise {
  match kind {
    DropDatabase => self.exec_drop_database(if_exists, names)
    DropTable => {
      self.cur_cmd = 199
      for n in names {
        match self.find_table(n) {
          Some((scope, t)) => {
            // referenced by a foreign key from another table?
            let db = self.db_of(scope)
            for other in db.tables() {
              if other.id != t.id {
                for fk in other.foreign_keys {
                  if fk.ref_table == t.id {
                    raise @types.sql_error(
                      3726,
                      "Could not drop object '\{t.schema}.\{t.name}' because it is referenced by a FOREIGN KEY constraint.",
                    )
                  }
                }
              }
            }
            let mut db = db.drop_object(t.id)
            // triggers go with their table
            for m in db.modules() {
              if m.parent == Some(t.id) {
                db = db.drop_object(m.id)
              }
            }
            self.write(scope, db)
            self.server.idents.remove(t.id)
          }
          None => if !if_exists { raise drop_missing("table", n) }
        }
      }
      self.rt.rowcount = 0
      self.done(199)
    }
    DropView | DropProcedure | DropFunction | DropTrigger => {
      let (word, cmd) = match kind {
        DropView => ("view", 208)
        DropProcedure => ("procedure", 223)
        DropFunction => ("function", 179)
        _ => ("trigger", 225)
      }
      self.cur_cmd = cmd
      for n in names {
        let m = match self.find_module(n) {
          Some(m) if module_matches(kind, m.kind) => Some(m)
          _ => None
        }
        match m {
          Some(m) => {
            self.write(0, self.db_of(0).drop_object(m.id))
            if m.kind is Procedure {
              self.server.procs.remove(m.name.to_lower())
            }
          }
          None => if !if_exists { raise drop_missing(word, n) }
        }
      }
      self.rt.rowcount = 0
      self.done(cmd)
    }
    DropSchema => {
      self.schema_ddl = true
      for n in names {
        let name = n.base()
        let db = self.db_of(0)
        match db.schema_id(name) {
          Some(sid) => {
            if sid < 5 || sid >= 16384 {
              raise @types.sql_error(15150, "Cannot drop the schema '\{name}'.")
            }
            for t in db.tables() {
              if t.schema.to_lower() == name.to_lower() {
                raise @types.sql_error(
                  3729,
                  "Cannot drop schema '\{name}' because it is being referenced by object '\{t.name}'.",
                )
              }
            }
            for m in db.modules() {
              if m.schema.to_lower() == name.to_lower() {
                raise @types.sql_error(
                  3729,
                  "Cannot drop schema '\{name}' because it is being referenced by object '\{m.name}'.",
                )
              }
            }
            self.write(0, db.drop_schema(name))
            self.schema_ddl = true
          }
          None =>
            if !if_exists {
              self.cur_cmd = 170
              raise @types.sql_error(
                15151,
                "Cannot drop the schema '\{name}', because it does not exist or you do not have permission.",
              )
            }
        }
      }
      self.rt.rowcount = 0
    }
    _ => raise @types.not_supported("DROP of this object type")
  }
}

///|
fn module_matches(kind : @ast.DropKind, m : @store.ObjectKind) -> Bool {
  match (kind, m) {
    (DropView, View) => true
    (DropProcedure, Procedure) => true
    (DropFunction, ScalarFunction | InlineFunction | TableFunction) => true
    (DropTrigger, Trigger) => true
    _ => false
  }
}
