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
/// Deterministic constraint name suffix (SQL Server uses 16 random hex digits).
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
fn short(name : String, n : Int) -> String {
  if name.length() > n {
    name.unsafe_substring(start=0, end=n)
  } else {
    name
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
) -> @store.Table raise {
  let display = if name.has_prefix("@") { "" } else { name }
  let columns : Array[@store.Column] = []
  let indexes : Array[@store.Index] = []
  let checks : Array[@store.Check] = []
  let fks : Array[@store.ForeignKey] = []
  let pk_cols : Set[String] = Set([])
  // Collect PK columns first: they are implicitly NOT NULL.
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
  for c in body.columns {
    if columns.iter().any(x => x.name.to_lower() == c.name.name.to_lower()) {
      raise @types.sql_error(
        2705,
        "Column names in each table must be unique. Column name '\{c.name.name}' in table '\{display}' is specified more than once.",
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
        // computed column: type of its expression over the earlier columns
        let env = @bind.Env::new(Map([])).with_columns(
          columns.map(x => @bind.ColumnRef::{
            qualifier: "",
            name: x.name,
            ty: x.ty,
            nullable: x.nullable,
            origin: Computed,
          }),
        )
        let b = @bind.bind_expr(env, e)
        (b.ty, Some(self.slice(e.span)))
      }
      (None, None) =>
        raise @types.sql_error(
          173,
          "The definition for column '\{c.name.name}' must include a data type.",
        )
    }
    let nullable = match c.nullable {
      Some(n) => n
      None => !pk_cols.contains(c.name.name.to_lower()) && c.identity is None
    }
    let mut default_ = None
    let mut default_name = None
    for k in c.constraints {
      match k.kind {
        ColDefault(e) => {
          default_ = Some(self.slice(e.span))
          default_name = Some(
            match k.name {
              Some(n) => n.name
              None =>
                "DF__\{short(display, 9)}__\{short(c.name.name, 5)}__\{self.name_suffix().unsafe_substring(start=0, end=8)}"
            },
          )
        }
        ColCheck(e, ..) =>
          checks.push(@store.Check::{
            name: match k.name {
              Some(n) => n.name
              None =>
                "CK__\{short(display, 9)}__\{short(c.name.name, 5)}__\{self.name_suffix().unsafe_substring(start=0, end=8)}"
            },
            expr: self.slice(e.span),
            enabled: true,
          })
        _ => ()
      }
    }
    columns.push(@store.Column::{
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
      default_,
      default_name,
      computed,
      persisted: c.persisted,
      rowguidcol: c.rowguidcol,
    })
  }
  let col_index = (n : String) => {
    let k = n.to_lower()
    for i, c in columns {
      if c.name.to_lower() == k {
        return i
      }
    }
    -1
  }
  let index_cols = (cols : Array[@ast.IndexColumn]) => {
    let out = []
    for ic in cols {
      let i = col_index(ic.name.name)
      if i < 0 {
        raise @types.sql_error(
          1911,
          "Column name '\{ic.name.name}' does not exist in the target table or view.",
        )
      }
      out.push((i, ic.desc))
    }
    out
  }
  let add_key = (
    cname : @ast.Ident?,
    primary : Bool,
    cols : Array[(Int, Bool)],
    clustered : Bool?,
  ) => {
    let kind = if primary { "PK" } else { "UQ" }
    indexes.push(@store.Index::{
      name: match cname {
        Some(n) => n.name
        None => "\{kind}__\{short(display, 8)}__\{self.name_suffix()}"
      },
      unique: true,
      primary,
      clustered: clustered.unwrap_or(primary),
      columns: cols,
      filter: None,
      is_constraint: true,
    })
  }
  for c in body.columns {
    for k in c.constraints {
      match k.kind {
        ColPrimaryKey(clustered~, ..) =>
          add_key(k.name, true, [(col_index(c.name.name), false)], clustered)
        ColUnique(clustered~, ..) =>
          add_key(k.name, false, [(col_index(c.name.name), false)], clustered)
        ColReferences(r) =>
          fks.push(
            self.foreign_key(
              k.name,
              display,
              [col_index(c.name.name)],
              r,
              db,
              id,
              columns,
            ),
          )
        _ => ()
      }
    }
  }
  for k in body.constraints {
    match k.kind {
      PrimaryKey(cols, clustered~, ..) =>
        add_key(k.name, true, index_cols(cols), clustered)
      Unique(cols, clustered~, ..) =>
        add_key(k.name, false, index_cols(cols), clustered)
      Check(e, ..) =>
        checks.push({
          name: match k.name {
            Some(n) => n.name
            None =>
              "CK__\{short(display, 9)}__\{self.name_suffix().unsafe_substring(start=0, end=8)}"
          },
          expr: self.slice(e.span),
          enabled: true,
        })
      ForeignKey(cols, r) => {
        let idx = cols.map(c => col_index(c.name))
        fks.push(self.foreign_key(k.name, display, idx, r, db, id, columns))
      }
      DefaultFor(e, col) => {
        let i = col_index(col.name)
        if i >= 0 {
          columns[i] = {
            ..columns[i],
            default_: Some(self.slice(e.span)),
            default_name: Some(
              match k.name {
                Some(n) => n.name
                None =>
                  "DF__\{short(display, 9)}__\{self.name_suffix().unsafe_substring(start=0, end=8)}"
              },
            ),
          }
        }
      }
    }
  }
  if indexes.iter().filter(i => i.primary).count() > 1 {
    raise @types.sql_error(
      8110,
      "Cannot add multiple PRIMARY KEY constraints to table '\{display}'.",
    )
  }
  for ix in body.indexes {
    indexes.push({
      name: ix.0.name,
      unique: false,
      primary: false,
      clustered: false,
      columns: index_cols(ix.1),
      filter: None,
      is_constraint: false,
    })
  }
  {
    id,
    schema,
    name,
    columns,
    indexes,
    checks,
    foreign_keys: fks,
    created: self.rt.now,
  }
}

///|
fn Session::foreign_key(
  self : Session,
  name : @ast.Ident?,
  table : String,
  cols : Array[Int],
  r : @ast.ForeignRef,
  db : @store.Db,
  self_id : Int,
  self_columns : Array[@store.Column],
) -> @store.ForeignKey raise {
  let (schema, base) = split_name(r.table)
  // a self-reference resolves to the table being created
  let (ref_id, ref_cols, ref_pk) = if base.to_lower() == table.to_lower() {
    (self_id, self_columns.map(c => c.name), None)
  } else {
    match db.lookup(schema, base) {
      Some(id) =>
        match db.table(id) {
          Some(t) => (id, t.columns.map(c => c.name), t.primary_key())
          None =>
            raise @types.sql_error(
              1767,
              "Foreign key references invalid table '\{base}'.",
            )
        }
      None =>
        raise @types.sql_error(
          1767,
          "Foreign key references invalid table '\{base}'.",
        )
    }
  }
  let ref_columns = if r.columns.is_empty() {
    match ref_pk {
      Some(pk) => pk.columns.map(c => c.0)
      None =>
        raise @types.sql_error(
          1773,
          "Foreign key has implicit reference to object '\{base}' which does not have a primary key defined on it.",
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
  {
    name: match name {
      Some(n) => n.name
      None =>
        "FK__\{short(table, 9)}__\{short(base, 9)}__\{self.name_suffix().unsafe_substring(start=0, end=8)}"
    },
    columns: cols,
    ref_table: ref_id,
    ref_columns,
    on_delete: ref_action(r.on_delete),
    on_update: ref_action(r.on_update),
    enabled: true,
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
  if db.lookup(schema, base) is Some(_) {
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
  let t = self.table_from_body(id, schema, base, ct.body, db)
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
  let t = self.table_from_body(id, "dbo", internal, body, self.tvars)
  self.tvars = self.tvars.create_table(t)
  self.frame().tables[key] = id
}

///|
fn Session::exec_drop(
  self : Session,
  kind : @ast.DropKind,
  if_exists : Bool,
  names : Array[@ast.ObjectName],
) -> Unit raise {
  match kind {
    DropTable => {
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
            self.write(scope, db.drop_object(t.id))
            self.server.idents.remove(t.id)
          }
          None =>
            if !if_exists {
              raise @types.sql_error(
                3701,
                "Cannot drop the table '\{n.parts.map(p => p.name).join(".")}', because it does not exist or you do not have permission.",
                state=5,
                severity=11,
              )
            }
        }
      }
      self.rt.rowcount = 0
      self.done(199)
    }
    DropProcedure => {
      for n in names {
        let key = n.base().to_lower()
        if self.server.procs.contains(key) {
          self.server.procs.remove(key)
        } else if !if_exists {
          raise @types.sql_error(
            3701,
            "Cannot drop the procedure '\{n.base()}', because it does not exist or you do not have permission.",
            state=5,
            severity=11,
          )
        }
      }
      self.done(203)
    }
    _ => raise @types.not_supported("DROP of this object type")
  }
}
