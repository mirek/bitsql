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
  state? : Int,
) -> @types.SqlError {
  self.pending.push(cause)
  // captured (catalog/*, msduck gaps-constraints, gaps-keys): state 1
  // after 2714, 1505 and the foreign key definition errors; state 0 after
  // 1779, 1911, 1769, 1752, 1781, 8111, 1919, 1909 and a CHECK's 1764
  let state = match state {
    Some(s) => s
    None =>
      match cause.number() {
        2714
        | 1505
        | 1767
        | 1770
        | 1773
        | 1776
        | 1778
        | 1753
        | 1761
        | 1762
        | 1764
        | 1715
        | 1765
        | 1785 => 1
        _ => 0
      }
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
  /// CREATE TABLE (not ALTER TABLE ADD): the table is not in the catalog
  /// yet.
  creating : Bool
  /// Indexes that existed before the statement (ALTER TABLE ADD).
  base_indexes : Int
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
    creating: false,
    base_indexes: t.indexes.length(),
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
  // captured: two constraints named alike in one statement (msduck
  // gaps-constraints definition-errors-10, gaps-keys diagnostics-6)
  if b.names.contains(k) {
    raise @types.sql_error(
      8168,
      "Cannot create, drop, enable, or disable more than one constraint, column, index, or trigger named '\{name}' in this context. Duplicate names are not allowed.",
      state=0,
    )
  }
  // Temp-table and table-variable constraint names are not schema-scoped
  // in the emulator (SQL Server makes system names unique in tempdb). The
  // table being created already owns its name (CONSTRAINT c10 in CREATE
  // TABLE c10 is 2714).
  if b.scope == 0 &&
    (
      self.object_name_taken(db, b.schema, name) ||
      (b.creating && k == b.display.to_lower())
    ) {
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
  if expr_has_subquery(e) {
    raise @types.sql_error(
      1046,
      "Subqueries are not allowed in this context. Only scalar expressions are allowed.",
      severity=15,
    )
  }
  // a table-level CHECK over exactly one column belongs to that column
  // (parent_column_id, system name; captured: msduck gaps-constraints
  // alter-lifecycle-8)
  let column = match column {
    Some(c) => Some(c)
    None =>
      match expr_column_names(e) {
        [one] =>
          match b.col_index(one) {
            -1 => None
            i => Some(b.columns[i])
          }
        _ => None
      }
  }
  for n in expr_column_names(e) {
    let i = b.col_index(n)
    if i >= 0 && b.columns[i].computed is Some(_) && !b.columns[i].persisted {
      raise self.constraint_error(
        @types.sql_error(
          1764,
          "Computed Column '\{b.columns[i].name}' in table '\{b.display}' is invalid for use in 'CHECK CONSTRAINT' because it is not persisted.",
        ),
        state=0,
      )
    }
  }
  let id = self.server.object_id()
  let (cname, auto) = match name {
    Some(n) => (n.name, false)
    None => (system_name("CK", b.display, column.map(c => c.name), id), true)
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
/// Precision, scale and length arguments of a column type (captured:
/// corpus tail/catalog-column-types, msduck-runs table-type-catalog): a
/// zero length or precision is 1001 and a fractional-seconds scale above
/// 7 is 1002 (class 15, "Line n:"), a precision above the maximum 2750
/// naming the column ordinal, a scale above the precision 183 (class 15).
fn column_type_check(
  t : @ast.TypeName,
  column : String,
  ordinal : Int,
) -> Unit raise @types.SqlError {
  guard t.schema is None else { return }
  let num = (k : Int) => {
    match t.args.get(k) {
      Some(Num(n)) =>
        try @string.parse_int(n) catch {
          _ => None
        } noraise {
          v => Some(v)
        }
      _ => None
    }
  }
  let line = t.span.line
  let zero = () => {
    @types.sql_error(
      1001,
      "Line \{line}: Length or precision specification 0 is invalid.",
      severity=15,
    )
  }
  let too_big = (p : Int, max : Int) => {
    @types.sql_error(
      2750,
      "Column or parameter #\{ordinal}: Specified column precision \{p} is greater than the maximum precision of \{max}.",
    )
  }
  match t.name.to_lower() {
    "decimal" | "numeric" =>
      match num(0) {
        Some(0) => raise zero()
        Some(p) if p > 38 => raise too_big(p, 38)
        Some(p) =>
          match num(1) {
            Some(s) if s > p =>
              raise @types.sql_error(
                183,
                "The scale (\{s}) for column '\{column}' must be within the range 0 to \{p}.",
                severity=15,
              )
            _ => ()
          }
        None => ()
      }
    "float" =>
      match num(0) {
        Some(0) => raise zero()
        Some(p) if p > 53 => raise too_big(p, 53)
        _ => ()
      }
    "char" | "varchar" | "nchar" | "nvarchar" | "binary" | "varbinary" =>
      if num(0) == Some(0) {
        raise zero()
      }
    "time" | "datetime2" | "datetimeoffset" =>
      match num(0) {
        Some(s) if s > 7 =>
          raise @types.sql_error(
            1002,
            "Line \{line}: Specified scale \{s} is invalid.",
            severity=15,
          )
        _ => ()
      }
    _ => ()
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
  // names compare under the database collation ([Ä] and [ä] collide under
  // CI; captured: msduck-runs table-type-catalog #005)
  let coll = self.db_collation()
  if b.col_index(c.name.name) >= 0 ||
    b.columns
    .iter()
    .any(x => @types.compare_strings(x.name, c.name.name, coll) == 0) {
    raise @types.sql_error(
      2705,
      "Column names in each table must be unique. Column name '\{c.name.name}' in table '\{b.written}' is specified more than once.",
      // captured: state 3 within one CREATE TABLE / TYPE / table variable
      // (tail/catalog-column-types), 4 for ALTER TABLE ADD of an existing
      // name (catalog/ddl-errors)
      state=if b.creating { 3 } else { 4 },
    )
  }
  match c.type_ {
    Some(t) => {
      // reported at the type's line (captured)
      errdefer {
        self.error_line = Some(t.span.line)
      }
      column_type_check(t, c.name.name, b.columns.length() + 1)
    }
    None => ()
  }
  let collation = match c.collate {
    Some(i) =>
      match @types.Collation::parse(i.name) {
        Some(x) => x
        None => raise @types.unknown_collation_error(i.name)
      }
    None => self.scope_collation(b.scope)
  }
  let mut alias_type : Int? = None
  let mut alias_nullable : Bool? = None
  let (ty, computed) = match (c.type_, c.computed) {
    (Some(t), _) =>
      match self.decl_type(t, collation) {
        ScalarDecl(ty, ut, n) => {
          self.check_ansi_padding(ty)
          alias_type = ut
          alias_nullable = n
          (ty, None)
        }
        TableDecl(_) => raise missing_type(t, 6)
      }
    (None, Some(e)) => {
      // a computed column cannot use another one (captured: msduck
      // gaps-computed unicode-errors-1)
      for n in expr_column_names(e) {
        let i = b.col_index(n)
        if i >= 0 && b.columns[i].computed is Some(_) {
          raise @types.sql_error(
            1759,
            "Computed column '\{b.columns[i].name}' in table '\{b.display}' is not allowed to be used in another computed-column definition.",
            state=0,
          )
        }
      }
      if c.persisted && expr_nondeterministic(e) {
        raise @types.sql_error(
          4936,
          "Computed column '\{c.name.name}' in table '\{b.display}' cannot be persisted because the column is non-deterministic.",
        )
      }
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
  let nullable = match (c.nullable, c.computed) {
    (Some(n), _) => n
    (None, Some(e)) => computed_nullable(e, b)
    (None, None) if alias_nullable is Some(n) &&
      !pk_cols.contains(c.name.name.to_lower()) => n
    (None, None) =>
      !pk_cols.contains(c.name.name.to_lower()) &&
      c.identity is None &&
      !(ty is RowVersion)
  }
  // captured (msduck gaps-rowversion_identity #044/#045/#096/#097/#101)
  if ty is RowVersion && b.columns.iter().any(x => x.ty is RowVersion) {
    raise @types.sql_error(
      2738,
      "A table can only have one timestamp column. Because table '\{b.written}' already has one, the column '\{c.name.name}' cannot be added.",
      state=2,
    )
  }
  match c.identity {
    Some(i) => {
      let ok = match ty {
        TinyInt | SmallInt | Int | BigInt => true
        Decimal(_, 0) | Numeric(_, 0) => true
        _ => false
      }
      if !ok {
        raise @types.sql_error(
          2749,
          "Identity column '\{c.name.name}' must be of data type int, bigint, smallint, tinyint, or decimal or numeric with a scale of 0, unencrypted, and constrained to be nonnullable.",
          state=2,
        )
      }
      if c.nullable == Some(true) {
        raise @types.sql_error(
          8147,
          "Could not create IDENTITY attribute on nullable column '\{c.name.name}', table '\{b.written}'.",
        )
      }
      // identity values are Int64 here: a seed or increment beyond that
      // range (decimal(38,0)) is not emulated
      for part in [i.seed, i.increment] {
        match part {
          Some(text) if beyond_bigint(text.trim(chars="-+ ").to_owned()) =>
            raise @types.not_supported(
              "IDENTITY seed or increment beyond the bigint range",
            )
          _ => ()
        }
      }
    }
    None => ()
  }
  for k in c.constraints {
    if k.kind is ColDefault(_) {
      if c.identity is Some(_) {
        raise self.constraint_error(
          @types.sql_error(
            1754,
            "Defaults cannot be created on columns with an IDENTITY attribute. Table '\{b.written}', column '\{c.name.name}'.",
            state=0,
          ),
        )
      }
      if ty is RowVersion {
        raise self.constraint_error(
          @types.sql_error(
            1755,
            "Defaults cannot be created on columns of data type timestamp. Table '\{b.written}', column '\{c.name.name}'.",
            state=0,
          ),
        )
      }
    }
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
    result_nullable: match (c.nullable, c.computed) {
      (Some(false), Some(e)) => computed_nullable(e, b)
      _ => nullable
    },
    persisted: c.persisted,
    rowguidcol: c.rowguidcol,
    user_type: alias_type,
  }
  if col.identity is Some(_) && b.columns.iter().any(x => x.identity is Some(_)) {
    raise @types.sql_error(
      2744,
      "Multiple identity columns specified for table '\{b.display}'. Only one identity column per table is allowed.",
    )
  }
  for k in c.constraints {
    if k.kind is ColDefault(e) {
      self.check_default(e, col)
      let id = self.server.object_id()
      let (name, auto) = match k.name {
        Some(n) => (n.name, false)
        None => (system_name("DF", b.display, Some(c.name.name), id), true)
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
      // two clustered constraints in one statement (captured: msduck
      // gaps-keys clustered-conflicts-6)
      if b.indexes[b.base_indexes:].iter().any(i => i.clustered) {
        raise @types.sql_error(
          8112,
          "Cannot add more than one clustered index for constraints on table '\{b.display}'.",
          state=0,
        )
      }
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
  let seen : Array[Int] = []
  for c in cols {
    let col = b.columns[c.0]
    if seen.contains(c.0) {
      raise self.constraint_error(
        @types.sql_error(
          1909,
          "Cannot use duplicate column names in index. Column name '\{col.name}' listed more than once.",
        ),
      )
    }
    seen.push(c.0)
    if invalid_key_type(col.ty) {
      raise self.constraint_error(
        @types.sql_error(
          1919,
          "Column '\{col.name}' in table '\{b.display}' is of a type that is invalid for use as a key column in an index.",
        ),
      )
    }
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
    filter_terms: [],
    fill_factor: 0,
    ignore_dup_key: false,
    is_constraint: true,
    disabled: false,
  })
}

///|
fn next_index_id(indexes : Array[@store.Index]) -> Int {
  // the lowest free nonclustered id: a dropped index's id is reused
  // (captured: msduck-runs index-catalog #017)
  let mut k = 2
  while indexes.iter().any(ix => ix.index_id == k) {
    k += 1
  }
  k
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
  let (ref_id, ref_cols, ref_keys, ref_types) = if self_ref {
    (b.id, b.columns.map(c => c.name), b.indexes, b.columns.copy())
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
      Some(t) => (t.id, t.columns.map(c => c.name), t.indexes, t.columns)
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
  for j, i in ref_columns {
    if i < 0 {
      raise self.constraint_error(
        @types.sql_error(
          1770,
          "Foreign key '\{name.map(n => n.name).unwrap_or("")}' references invalid column '\{r.columns[j].name}' in referenced table '\{base}'.",
          state=0,
        ),
      )
    }
  }
  if ref_columns.length() != cols.length() {
    raise @types.sql_error(
      8139,
      "Number of referencing columns in foreign key differs from number of referenced columns, table '\{b.display}'.",
      state=0,
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
        "There are no primary or candidate keys in the referenced table '\{object_text(r.table)}' that match the referencing column list in the foreign key '\{name.map(n => n.name).unwrap_or("")}'.",
        state=0,
      ),
    )
  }
  let fk_label = name.map(n => n.name).unwrap_or("")
  let on_delete = ref_action(r.on_delete)
  let on_update = ref_action(r.on_update)
  for j, c in cols {
    let mine = b.columns[c]
    let theirs = ref_types[ref_columns[j]]
    match same_key_type(mine.ty, theirs.ty) {
      Some(true) => ()
      Some(false) =>
        raise self.constraint_error(
          @types.sql_error(
            1753,
            "Column '\{base}.\{theirs.name}' is not the same length or scale as referencing column '\{b.display}.\{mine.name}' in foreign key '\{fk_label}'. Columns participating in a foreign key relationship must be defined with the same length and scale.",
            state=0,
          ),
        )
      None =>
        raise self.constraint_error(
          @types.sql_error(
            1778,
            "Column '\{base}.\{theirs.name}' is not the same data type as referencing column '\{b.display}.\{mine.name}' in foreign key '\{fk_label}'.",
            state=0,
          ),
        )
    }
  }
  for c in cols {
    let mine = b.columns[c]
    if mine.computed is Some(_) {
      if !mine.persisted {
        raise self.constraint_error(
          @types.sql_error(
            1764,
            "Computed Column '\{mine.name}' in table '\{b.display}' is invalid for use in 'FOREIGN KEY CONSTRAINT' because it is not persisted.",
          ),
        )
      }
      if !(on_update is NoAction) {
        raise self.constraint_error(
          @types.sql_error(
            1715,
            "Foreign key '\{fk_label}' creation failed. Only NO ACTION referential update action is allowed for referencing computed column '\{mine.name}'.",
          ),
        )
      }
      if !(on_delete is (NoAction | Cascade)) {
        raise self.constraint_error(
          @types.sql_error(
            1765,
            "Foreign key '\{fk_label}' creation failed. Only NO ACTION and CASCADE referential delete actions are allowed for referencing computed column '\{mine.name}'.",
          ),
        )
      }
    }
  }
  if on_delete is SetNull || on_update is SetNull {
    if cols.iter().any(c => !b.columns[c].nullable) {
      raise self.constraint_error(
        @types.sql_error(
          1761,
          "Cannot create the foreign key \"\{fk_label}\" with the SET NULL referential action, because one or more referencing columns are not nullable.",
          state=0,
        ),
      )
    }
  }
  if on_delete is SetDefault || on_update is SetDefault {
    if cols
      .iter()
      .any(c => !b.columns[c].nullable && b.columns[c].default_ is None) {
      raise self.constraint_error(
        @types.sql_error(
          1762,
          "Cannot create the foreign key \"\{fk_label}\" with the SET DEFAULT referential action, because one or more referencing not-nullable columns lack a default constraint.",
          state=0,
        ),
      )
    }
  }
  let id = self.server.object_id()
  let (fk_name, auto) = match name {
    Some(n) => (n.name, false)
    None =>
      (system_name("FK", b.display, Some(b.columns[cols[0]].name), id), true)
  }
  self.claim_name(b, db, fk_name)
  // cycles or multiple cascade paths (captured: msduck gaps-constraints
  // cascade-paths, referential-actions-19..22)
  if b.scope == 0 &&
    !(on_delete is NoAction && on_update is NoAction) &&
    cascade_conflict(db, b.id, b.fks, ref_id, on_delete, on_update) {
    raise self.constraint_error(
      @types.sql_error(
        1785,
        "Introducing FOREIGN KEY constraint '\{fk_name}' on table '\{b.display}' may cause cycles or multiple cascade paths. Specify ON DELETE NO ACTION or ON UPDATE NO ACTION, or modify other FOREIGN KEY constraints.",
        state=0,
      ),
    )
  }
  {
    id,
    name: fk_name,
    columns: cols,
    ref_table: ref_id,
    ref_columns,
    on_delete,
    on_update,
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
            state=0,
          ),
        )
      }
      if b.columns[i].default_id != 0 {
        raise self.constraint_error(
          @types.sql_error(1781, "Column already has a DEFAULT bound to it."),
        )
      }
      self.check_default(e, b.columns[i])
      let id = self.server.object_id()
      let (name, auto) = match k.name {
        Some(n) => (n.name, false)
        None => (system_name("DF", b.display, Some(col.name), id), true)
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
    ansi_nulls: self.ansi_nulls(),
    lob_used: false,
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
  as_written? : String? = None,
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
    // a table variable's messages use its declared name (captured: 2705
    // "in table '@t'", msduck-runs table-variable#009)
    written: as_written.unwrap_or(name),
    columns: [],
    indexes: [],
    checks: [],
    fks: [],
    max_column_id: 0,
    names: Set([]),
    creating: true,
    base_indexes: 0,
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
    // captured: a single error, state 0 (msduck gaps-keys diagnostics-2);
    // a table type is named 'schema.name'
    raise @types.sql_error(
      8110,
      "Cannot add multiple PRIMARY KEY constraints to table '\{if scope == 4 { schema + "." + name } else { b.display }}'.",
      state=0,
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
      filter_terms: [],
      fill_factor: 0,
      ignore_dup_key: false,
      is_constraint: false,
      disabled: false,
    })
  }
  renumber_indexes(b, body)
  self.finish(b, name)
}

///|
/// Index ids of a new table: the clustered index is 1, the others are
/// numbered in reverse order of their definitions (captured with CREATE
/// TABLE and CREATE TYPE ... AS TABLE: `PK, UNIQUE (code), INDEX ix_name`
/// gives ix_name 2, the UNIQUE 3).
fn renumber_indexes(b : Builder, body : @ast.TableBody) -> Unit {
  let starts = []
  for c in body.columns {
    for k in c.constraints {
      if k.kind is (ColPrimaryKey(..) | ColUnique(..)) {
        starts.push(k.span.start)
      }
    }
  }
  for k in body.constraints {
    if k.kind is (PrimaryKey(_, ..) | Unique(_, ..)) {
      starts.push(k.span.start)
    }
  }
  for ix in body.indexes {
    starts.push(ix.0.span.start)
  }
  if starts.length() != b.indexes.length() {
    return
  }
  let order = []
  for k, ix in b.indexes {
    if !ix.clustered {
      order.push(k)
    }
  }
  order.sort_by((x, y) => starts[y].compare(starts[x]))
  for n, k in order {
    b.indexes[k] = { ..b.indexes[k], index_id: 2 + n, }
  }
  for k, ix in b.indexes {
    if ix.clustered {
      b.indexes[k] = { ..ix, index_id: 1, }
    }
  }
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
  site : Int,
) -> Unit raise {
  let key = name.to_lower()
  // DECLARE is compile-time: run again (a loop) it keeps the table and its
  // rows (captured: msduck gaps-temp_tables #039)
  match self.frame().tables.get(key) {
    Some(id) if self.tvar_sites.get(id) == Some(site) => return
    _ => ()
  }
  if self.frame().tables.contains(key) || self.frame().vars.contains(key) {
    raise @types.sql_error(
      134,
      "The variable name '\{name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
      severity=15,
    )
  }
  let id = self.server.object_id()
  let internal = "@" + id.to_string()
  let t = self.table_from_body(
    id,
    "dbo",
    internal,
    body,
    self.tvars,
    3,
    as_written=Some(name),
  )
  self.tvars = self.tvars.create_table(t)
  self.frame().tables[key] = id
  self.tvar_sites[id] = site
}

///|
/// Table variables declared in a branch that does not run still exist
/// (declarations are compile-time; captured: msduck gaps-temp_tables #040).
fn Session::declare_skipped_tables(self : Session, s : @ast.Stmt) -> Unit raise {
  match s.kind {
    DeclareTable(name, body) =>
      if !self.frame().tables.contains(name.to_lower()) {
        self.exec_declare_table(name, body, s.span.start)
      }
    Block(list) =>
      for x in list {
        self.declare_skipped_tables(x)
      }
    If(_, a, b) => {
      self.declare_skipped_tables(a)
      match b {
        Some(e) => self.declare_skipped_tables(e)
        None => ()
      }
    }
    While(_, body) => self.declare_skipped_tables(body)
    TryCatch(a, b) => {
      for x in a {
        self.declare_skipped_tables(x)
      }
      for x in b {
        self.declare_skipped_tables(x)
      }
    }
    _ => ()
  }
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
        self.not_a_synonym(n, "TABLE")
        match self.find_table(n) {
          Some((scope, t)) => {
            if scope == 0 {
              self.check_drop_references("TABLE", n, t.schema, t.name, false)
            }
            // referenced by a foreign key from another table?
            let db = self.db_of(scope)
            for other in db.tables() {
              if other.id != t.id {
                for fk in other.foreign_keys {
                  if fk.ref_table == t.id {
                    raise @types.sql_error(
                      3726,
                      "Could not drop object '\{object_text(n)}' because it is referenced by a FOREIGN KEY constraint.",
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
    DropView | DropProcedure | DropFunction | DropTrigger | DropSequence => {
      let (word, cmd) = match kind {
        DropView => ("view", 208)
        DropProcedure => ("procedure", 223)
        DropFunction => ("function", 179)
        DropSequence => ("sequence", 516)
        _ => ("trigger", 225)
      }
      self.cur_cmd = cmd
      // a missing name does not stop the rest of the list (captured:
      // gaps-procedures #144)
      let mut missing : @types.SqlError? = None
      for n in names {
        let m = match self.find_module(n) {
          Some(m) if module_matches(kind, m.kind) => Some(m)
          _ => None
        }
        match m {
          Some(m) => {
            if kind is DropFunction {
              self.check_drop_references("FUNCTION", n, m.schema, m.name, true)
            }
            self.write(0, self.db_of(0).drop_object(m.id))
            if m.kind is Procedure {
              self.server.procs.remove(m.name.to_lower())
            }
          }
          None if kind is (DropProcedure | DropFunction) &&
            self.find_table(n) is Some(_) =>
            // captured: gaps-procedures #143, gaps-functions #093
            raise @types.sql_error(
              3705,
              "Cannot use DROP \{word.to_upper()} with '\{object_text(n)}' because '\{object_text(n)}' is a table. Use DROP TABLE.",
            )
          None =>
            if !if_exists && missing is None {
              missing = Some(drop_missing(word, n))
            }
        }
      }
      // outside TRY the error does not undo the other drops: ERROR, then
      // the statement's DONE with the error bit
      if missing is Some(e) {
        if self.try_depth > 0 {
          raise e
        }
        self.message(e, self.stmt_line)
        self.stmt_error = e.number()
        self.rt.rowcount = 0
        self.done(cmd, error=true)
        return
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
    DropType => self.exec_drop_type(if_exists, names)
    DropSynonym => self.exec_drop_synonym(if_exists, names)
  }
}

///|
fn module_matches(kind : @ast.DropKind, m : @store.ObjectKind) -> Bool {
  match (kind, m) {
    (DropView, View) => true
    (DropProcedure, Procedure) => true
    (DropFunction, ScalarFunction | InlineFunction | TableFunction) => true
    (DropTrigger, Trigger) => true
    (DropSequence, Sequence) => true
    _ => false
  }
}

///|
/// Types that cannot be index key columns (1919): the max types.
fn invalid_key_type(ty : @types.SqlType) -> Bool {
  // also text/ntext/image (captured: harness/corpus/conversion/lob-table)
  ty is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None)) || ty.is_lob()
}

///|
/// Foreign key column type compatibility: Some(true) identical, Some(false)
/// same type with a different length/precision/scale (1753), None a
/// different type (1778). Captured: int vs bigint 1778, varchar(20) vs
/// varchar(10) 1753.
fn same_key_type(a : @types.SqlType, b : @types.SqlType) -> Bool? {
  match (a, b) {
    (Decimal(p, s), Decimal(q, t)) | (Numeric(p, s), Numeric(q, t)) =>
      Some(p == q && s == t)
    (Char(n, _), Char(m, _))
    | (NChar(n, _), NChar(m, _))
    | (Binary(n), Binary(m))
    | (Time(n), Time(m))
    | (DateTime2(n), DateTime2(m))
    | (DateTimeOffset(n), DateTimeOffset(m)) => Some(n == m)
    (VarChar(n, _), VarChar(m, _))
    | (NVarChar(n, _), NVarChar(m, _))
    | (VarBinary(n), VarBinary(m)) => Some(n == m)
    _ => if a == b { Some(true) } else { None }
  }
}

///|
/// System constraint name `<kind>__<table>__<column>__<object id hex>`:
/// at most 30 characters, so table and column share 14 (table 9 and column
/// 5 when both are longer; the shorter one leaves its room to the other),
/// a table-level CHECK gives the table 16 (captured: msduck gaps-catalog
/// v2-default-naming, v2-constraint-naming).
fn system_name(
  kind : String,
  table : String,
  column : String?,
  id : Int,
) -> String {
  match column {
    None => "\{kind}__\{short(table, 16)}__\{hex_id(id)}"
    Some(c) => {
      let (tl, cl) = if table.length() + c.length() <= 14 {
        (table.length(), c.length())
      } else if table.length() <= 9 {
        (table.length(), 14 - table.length())
      } else if c.length() <= 5 {
        (14 - c.length(), c.length())
      } else {
        (9, 5)
      }
      "\{kind}__\{short(table, tl)}__\{short(c, cl)}__\{hex_id(id)}"
    }
  }
}

///|
/// Would a foreign key with these actions from table `child` (built with
/// `child_fks`) to `parent` create a cycle or a second cascade path?
/// Table-level analysis: a DELETE of a table reaches a child as a DELETE
/// through ON DELETE CASCADE and as an UPDATE through ON DELETE SET
/// NULL/DEFAULT; an UPDATE reaches it as an UPDATE through any ON UPDATE
/// action; NO ACTION edges do not propagate. Reaching any table twice from
/// one starting operation, or reaching the start table, is a conflict.
fn cascade_conflict(
  db : @store.Db,
  child : Int,
  child_fks : Array[@store.ForeignKey],
  parent : Int,
  on_delete : @store.RefAction,
  on_update : @store.RefAction,
) -> Bool {
  // edges: parent id -> (child id, delete action, update action)
  let edges : Map[Int, Array[(Int, @store.RefAction, @store.RefAction)]] = Map([])
  let add = (p : Int, c : Int, d : @store.RefAction, u : @store.RefAction) => {
    match edges.get(p) {
      Some(xs) => xs.push((c, d, u))
      None => edges[p] = [(c, d, u)]
    }
  }
  let nodes : Array[Int] = [child, parent]
  for t in db.tables() {
    if !nodes.contains(t.id) {
      nodes.push(t.id)
    }
    if t.id == child {
      continue
    }
    for f in t.foreign_keys {
      add(f.ref_table, t.id, f.on_delete, f.on_update)
    }
  }
  for f in child_fks {
    add(f.ref_table, child, f.on_delete, f.on_update)
  }
  add(parent, child, on_delete, on_update)
  for start in nodes {
    for deleting in [true, false] {
      let reached : Set[Int] = Set([])
      // (table, reached by a delete)
      let stack : Array[(Int, Bool)] = [(start, deleting)]
      let mut steps = 0
      while stack.pop() is Some((t, del)) {
        steps += 1
        if steps > 100000 {
          return true
        }
        guard edges.get(t) is Some(out) else { continue }
        for e in out {
          let (c, d, u) = e
          let next : Bool? = if del {
            match d {
              Cascade => Some(true)
              SetNull | SetDefault => Some(false)
              NoAction => None
            }
          } else if u is NoAction {
            None
          } else {
            Some(false)
          }
          guard next is Some(nd) else { continue }
          if c == start || reached.contains(c) {
            return true
          }
          reached.add(c)
          stack.push((c, nd))
        }
      }
    }
  }
  false
}

///|
/// Does an expression contain a subquery (EXISTS, IN (SELECT ...), ...)?
fn expr_has_subquery(e : @ast.Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    if x.kind
      is (Subquery(_) | Exists(_) | InQuery(_, _, ..) | Quantified(_, _, _, _)) {
      found = true
    }
  })
  found
}

///|
/// Distinct (case-insensitive) column names an expression references, in
/// order of appearance.
fn expr_column_names(e : @ast.Expr) -> Array[String] {
  let out : Array[String] = []
  // datepart arguments (DATEADD(day, ...)) parse as column names
  let dateparts : Array[Int] = []
  walk_expr(e, x => {
    if x.kind is Call(c) &&
      c.args.length() > 0 &&
      is_datepart_function(c.name.base()) {
      dateparts.push(c.args[0].span.start)
    }
  })
  walk_expr(e, x => {
    if x.kind is Column(parts) && !dateparts.contains(x.span.start) {
      let n = parts[parts.length() - 1].name
      if !out.iter().any(y => y.to_lower() == n.to_lower()) {
        out.push(n)
      }
    }
  })
  out
}

///|
/// DEFAULT definitions are checked when created: no column references
/// (128), no subqueries (1046), and the value must convert implicitly to
/// the column type (captured: msduck gaps-constraints definition-errors-19,
/// gaps-computed session-default-variant-1: SESSION_CONTEXT into nvarchar
/// is 257 at CREATE TABLE).
fn Session::check_default(
  self : Session,
  e : @ast.Expr,
  col : @store.Column,
) -> Unit raise {
  match expr_column_names(e) {
    [first, ..] =>
      raise @types.sql_error(
        128,
        "The name \"\{first}\" is not permitted in this context. Valid expressions are constants, constant expressions, and (in some contexts) variables. Column names are not permitted.",
        severity=15,
      )
    [] => ()
  }
  if expr_has_subquery(e) {
    raise @types.sql_error(
      1046,
      "Subqueries are not allowed in this context. Only scalar expressions are allowed.",
      severity=15,
    )
  }
  // after 1046 (captured: tail5/b1-next-value-over)
  if @bind.has_next_value_over(e) {
    raise @types.sql_error(
      11717,
      "NEXT VALUE FOR function does not support the OVER clause in default constraints, UPDATE statements, or MERGE statements.",
      severity=15,
    )
  }
  if is_newsequentialid(self.slice(e.span)) {
    return
  }
  // binding problems surface on use, as before; only the assignment rule
  // is checked here
  let bound = @bind.bind_expr(
    @bind.Env::new(Map([]), catalog=self.catalog()),
    e,
  ) catch {
    _ => return
  }
  @types.check_assign(bound.ty, col.ty)
}

///|
/// Non-deterministic built-ins (PERSISTED computed columns reject them with
/// 4936).
fn expr_nondeterministic(e : @ast.Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    if x.kind is Call(c) {
      match c.name.base().to_lower() {
        "newid"
        | "newsequentialid"
        | "getdate"
        | "getutcdate"
        | "sysdatetime"
        | "sysutcdatetime"
        | "sysdatetimeoffset"
        | "current_timestamp"
        | "rand"
        | "host_name"
        | "app_name"
        | "suser_sname"
        | "user_name"
        | "session_context"
        | "context_info" => found = true
        _ => ()
      }
    }
  })
  found
}

///|
/// Built-ins whose first argument is a datepart keyword.
fn is_datepart_function(name : String) -> Bool {
  match name.to_lower() {
    "dateadd"
    | "datediff"
    | "datediff_big"
    | "datepart"
    | "datename"
    | "datetrunc"
    | "date_bucket" => true
    _ => false
  }
}

///|
/// sys.columns.is_nullable of a computed column (captured: msduck
/// gaps-catalog definitions-computed / v2-computed): a column reference
/// keeps the column's nullability, a non-NULL literal is NOT NULL,
/// ISNULL(x, y) follows y, CASE is NOT NULL when every branch (with an
/// ELSE) is; anything else (arithmetic, CAST, COALESCE, functions) is
/// nullable.
fn computed_nullable(e : @ast.Expr, b : Builder) -> Bool {
  match e.kind {
    Paren(x) => computed_nullable(x, b)
    Column(parts) =>
      match b.col_index(parts[parts.length() - 1].name) {
        -1 => true
        i => b.columns[i].nullable
      }
    IntLit(_)
    | DecimalLit(_)
    | FloatLit(_)
    | MoneyLit(_)
    | StrLit(_, ..)
    | BinaryLit(_) => false
    Unary(Neg, x) =>
      match x.kind {
        IntLit(_) | DecimalLit(_) | FloatLit(_) | MoneyLit(_) => false
        _ => true
      }
    Call(c) if c.name.parts.length() == 1 &&
      c.name.base().to_lower() == "isnull" &&
      c.args.length() == 2 => computed_nullable(c.args[1], b)
    Case(whens~, else_~, ..) =>
      match else_ {
        None => true
        Some(x) =>
          computed_nullable(x, b) ||
          whens.iter().any(w => computed_nullable(w.1, b))
      }
    _ => true
  }
}

///|
/// Digits of a non-negative integer literal beyond 9223372036854775807.
fn beyond_bigint(digits : String) -> Bool {
  let d = digits.trim_start(chars="0").to_owned()
  d.length() > 19 || (d.length() == 19 && d > "9223372036854775807")
}
