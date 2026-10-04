// Virtual catalog views (sys.*, INFORMATION_SCHEMA.*): bound as scope-2
// table sources whose rows are computed from the current database value on
// every scan. Descriptors come from sysviews_data.mbt (generated from
// captures); this file computes the rows.

///|
priv struct ViewCol {
  name : String
  ty : @types.SqlType
  nullable : Bool
  computed : Bool
}

///|
priv struct ViewDef {
  schema : String
  name : String
  columns : Array[ViewCol]
}

///|
fn vc(
  name : String,
  ty : @types.SqlType,
  nullable : Bool,
  computed : Bool,
) -> ViewCol {
  { name, ty, nullable, computed, }
}

///|
let coll_default : @types.Collation = @types.default_collation

///|
/// Collation of sys.objects.type / type_desc and similar internal columns.
let coll_ks_ws : @types.Collation = @types.Collation::parse(
  "Latin1_General_CI_AS_KS_WS",
).unwrap()

///|
/// Index into `view_defs` for a catalog view name.
fn view_index(schema : String, name : String) -> Int? {
  let s = schema.to_lower()
  let n = name.to_lower()
  for i, v in view_defs {
    if v.schema.to_lower() == s && v.name.to_lower() == n {
      return Some(i)
    }
  }
  None
}

///|
/// Binds `sys.x` / `INFORMATION_SCHEMA.x` (optionally database-qualified
/// with the current database or master) to a virtual table.
fn Session::sys_view_binding(
  self : Session,
  name : @ast.ObjectName,
) -> @bind.TableBinding? raise @types.SqlError {
  let n = name.parts.length()
  if n < 2 {
    return None
  }
  let schema = name.parts[n - 2].name
  let s = schema.to_lower()
  if s != "sys" && s != "information_schema" {
    return None
  }
  let base = name.parts[n - 1].name
  // `tempdb.sys.#t` names a temp table (2701), not a catalog view
  if base.has_prefix("#") {
    return None
  }
  let mut tempdb = false
  if n >= 3 {
    let db = name.parts[n - 3].name.to_lower()
    if db == "tempdb" && self.rt.database.to_lower() != "tempdb" {
      tempdb = true
    } else if db != "" && db != self.rt.database.to_lower() {
      raise @types.not_supported("catalog views of another database")
    }
  }
  // the files of tempdb, model and msdb are not modelled (tempdb has one
  // data file per core, msdb other names and growth)
  if base.to_lower() == "database_files" &&
    (tempdb || self.rt.database.to_lower() is ("tempdb" | "model" | "msdb")) {
    raise @types.not_supported("sys.database_files of a system database")
  }
  match view_index(schema, base) {
    Some(i) => {
      let v = view_defs[i]
      // a database's catalog views report its default collation (captured:
      // settings/alter-database); server-level views keep master's
      let server_level = v.name
        is ("databases" | "time_zone_info" | "syslanguages") ||
        v.name.has_prefix("dm_")
      let db_coll = self.db_collation()
      let col_type = (t : @types.SqlType) => {
        if server_level || db_coll == coll_default {
          t
        } else {
          match t.collation() {
            Some(c) if c == coll_default => t.with_collation(db_coll)
            _ => t
          }
        }
      }
      Some({
        scope: 2,
        id: if tempdb {
          i + TEMPDB_VIEW_OFFSET
        } else {
          i
        },
        schema: v.schema,
        name: v.name,
        columns: v.columns.map(c => @bind.ColumnRef::{
          qualifier: v.name.to_lower(),
          name: c.name,
          ty: col_type(c.ty),
          nullable: c.nullable,
          origin: if c.computed {
            Computed
          } else {
            BaseColumn(identity=false)
          },
        }),
      })
    }
    None => raise @types.not_supported("catalog view \{schema}.\{base}")
  }
}

///|
/// One catalog row under construction: lowercased column name → value.
type VRow = Map[String, @types.Value]

///|
fn vrow(pairs : Array[(String, @types.Value)]) -> VRow {
  let m : Map[String, @types.Value] = Map([])
  for p in pairs {
    m[p.0] = p.1
  }
  m
}

///|
/// Orders a row by the view's columns. Columns not set default to NULL
/// when nullable (false for nullable bits), else to zero / empty.
fn project_row(v : ViewDef, r : VRow) -> Array[@types.Value] {
  v.columns.map(c => {
    match r.get(c.name.to_lower()) {
      Some(x) => x
      None =>
        match c.ty {
          Bit => Bit(false)
          _ if c.nullable => Null
          Variant => Null
          TinyInt => TinyInt(0)
          SmallInt => SmallInt(0)
          Int => Int(0)
          BigInt => BigInt(0L)
          _ => String("")
        }
    }
  })
}

///|
fn s(x : String) -> @types.Value {
  String(x)
}

///|
fn b(x : Bool) -> @types.Value {
  Bit(x)
}

///|
fn i(x : Int) -> @types.Value {
  Int(x)
}

///|
fn opt_s(x : String?) -> @types.Value {
  match x {
    Some(t) => String(t)
    None => Null
  }
}

///|
/// datetime value of a stamp (100 ns ticks since 0001-01-01).
fn dt(ticks : Int64) -> @types.Value {
  let days = (ticks / @types.TICKS_PER_DAY).to_int() - @types.DAYS_TO_1900
  let t = ticks % @types.TICKS_PER_DAY
  DateTime(days, @types.ticks_to_datetime_units(t).to_int())
}

///|
/// A schema-scoped object as sys.objects lists it.
priv struct CatObj {
  id : Int
  name : String
  schema_id : Int
  parent : Int
  code : String
  desc : String
  created : Int64
  modified : Int64
}

///|
fn constraint_objs(t : @store.Table, sid : Int) -> Array[CatObj] {
  let out = []
  let mk = (id, name, code, desc) => CatObj::{
    id,
    name,
    schema_id: sid,
    parent: t.id,
    code,
    desc,
    created: t.created,
    modified: t.created,
  }
  for ix in t.indexes {
    if ix.is_constraint {
      out.push(
        if ix.primary {
          mk(ix.object_id, ix.name, "PK", "PRIMARY_KEY_CONSTRAINT")
        } else {
          mk(ix.object_id, ix.name, "UQ", "UNIQUE_CONSTRAINT")
        },
      )
    }
  }
  for c in t.checks {
    out.push(mk(c.id, c.name, "C", "CHECK_CONSTRAINT"))
  }
  for c in t.columns {
    if c.default_id != 0 {
      out.push(
        mk(
          c.default_id,
          c.default_name.unwrap_or(""),
          "D",
          "DEFAULT_CONSTRAINT",
        ),
      )
    }
  }
  for f in t.foreign_keys {
    out.push(mk(f.id, f.name, "F", "FOREIGN_KEY_CONSTRAINT"))
  }
  out
}

///|
/// User objects of a database: tables, modules and constraints.
fn user_objects(db : @store.Db) -> Array[CatObj] {
  let out = []
  for t in db.tables() {
    let sid = db.schema_id(t.schema).unwrap_or(1)
    out.push({
      id: t.id,
      name: t.name,
      schema_id: sid,
      parent: 0,
      code: "U",
      desc: "USER_TABLE",
      created: t.created,
      modified: t.modified,
    })
    for o in constraint_objs(t, sid) {
      out.push(o)
    }
  }
  for m in db.modules() {
    let (code, desc) = m.kind.code()
    out.push({
      id: m.id,
      name: m.name,
      schema_id: db.schema_id(m.schema).unwrap_or(1),
      parent: m.parent.unwrap_or(0),
      code,
      desc,
      created: m.created,
      modified: m.modified,
    })
  }
  out
}

///|
fn object_row(o : CatObj) -> VRow {
  vrow([
    ("name", s(o.name)),
    ("object_id", i(o.id)),
    ("schema_id", i(o.schema_id)),
    ("parent_object_id", i(o.parent)),
    ("type", s(pad2(o.code))),
    ("type_desc", s(o.desc)),
    ("create_date", dt(o.created)),
    ("modify_date", dt(o.modified)),
  ])
}

///|
/// char(2) type codes are blank padded (`U `).
fn pad2(code : String) -> String {
  if code.length() < 2 {
    code + " "
  } else {
    code
  }
}

///|
/// Seed system objects (is_ms_shipped) as rows of sys.objects.
fn system_object_rows() -> Array[VRow] {
  seed_system_objects.map(r => {
    let m : Map[String, @types.Value] = Map([])
    for j, c in seed_system_object_columns {
      m[c] = r[j]
    }
    m["is_ms_shipped"] = Bit(true)
    m
  })
}

///|
/// sys.columns facts of a type: (system_type_id, user_type_id, max_length,
/// precision, scale).
fn type_ids(t : @types.SqlType) -> (Int, Int, Int, Int, Int) {
  let dec_len = (p : Int) => {
    if p <= 9 {
      5
    } else if p <= 19 {
      9
    } else if p <= 28 {
      13
    } else {
      17
    }
  }
  let time_len = (sc : Int, base : Int) => {
    base + (if sc <= 2 { 0 } else if sc <= 4 { 1 } else { 2 })
  }
  match t {
    Bit => (104, 104, 1, 1, 0)
    TinyInt => (48, 48, 1, 3, 0)
    SmallInt => (52, 52, 2, 5, 0)
    Int => (56, 56, 4, 10, 0)
    BigInt => (127, 127, 8, 19, 0)
    Decimal(p, sc) => (106, 106, dec_len(p), p, sc)
    Numeric(p, sc) => (108, 108, dec_len(p), p, sc)
    Money => (60, 60, 8, 19, 4)
    SmallMoney => (122, 122, 4, 10, 4)
    Float => (62, 62, 8, 53, 0)
    Real => (59, 59, 4, 24, 0)
    Char(n, _) => (175, 175, n, 0, 0)
    VarChar(n, _) => (167, 167, n.unwrap_or(-1), 0, 0)
    NChar(n, _) => (239, 239, n * 2, 0, 0)
    NVarChar(n, _) =>
      (
        231,
        231,
        match n {
          Some(k) => k * 2
          None => -1
        },
        0,
        0,
      )
    Binary(n) => (173, 173, n, 0, 0)
    VarBinary(n) => (165, 165, n.unwrap_or(-1), 0, 0)
    Date => (40, 40, 3, 10, 0)
    Time(sc) => (41, 41, time_len(sc, 3), if sc == 0 { 8 } else { 9 + sc }, sc)
    DateTime2(sc) =>
      (42, 42, time_len(sc, 6), if sc == 0 { 19 } else { 20 + sc }, sc)
    DateTimeOffset(sc) =>
      (43, 43, time_len(sc, 8), if sc == 0 { 26 } else { 27 + sc }, sc)
    DateTime => (61, 61, 8, 23, 3)
    SmallDateTime => (58, 58, 4, 16, 0)
    UniqueIdentifier => (36, 36, 16, 0, 0)
    RowVersion => (189, 189, 8, 0, 0)
    // sys.types: sql_variant max_length 8016 (COLMETADATA says 8009)
    Variant => (98, 98, 8016, 0, 0)
    // captured: xml/type (sys.columns, sys.types)
    Xml => (241, 241, -1, 0, 0)
    // sys.types: the 16-byte text pointer
    Text(_) => (35, 35, 16, 0, 0)
    NText(_) => (99, 99, 16, 0, 0)
    Image => (34, 34, 16, 0, 0)
  }
}

///|
fn is_ansi_padded(t : @types.SqlType) -> Bool {
  t
  is (Char(_, _)
  | VarChar(_, _)
  | NChar(_, _)
  | NVarChar(_, _)
  | Binary(_)
  | VarBinary(_))
}

///|
/// sys.columns row of one column of an object.
fn column_row(object_id : Int, c : @store.Column) -> VRow {
  let (st, ut, len, p, sc) = type_ids(c.ty)
  vrow([
    ("object_id", i(object_id)),
    ("name", s(c.name)),
    ("column_id", i(c.column_id)),
    ("system_type_id", TinyInt(st)),
    ("user_type_id", i(c.user_type.unwrap_or(ut))),
    ("max_length", SmallInt(len)),
    ("precision", TinyInt(p)),
    ("scale", TinyInt(sc)),
    ("collation_name", opt_s(c.ty.collation().map(x => x.name))),
    ("is_nullable", b(c.nullable)),
    ("is_ansi_padded", b(is_ansi_padded(c.ty))),
    ("is_rowguidcol", b(c.rowguidcol)),
    ("is_identity", b(c.identity is Some(_))),
    ("is_computed", b(c.computed is Some(_))),
    ("default_object_id", i(c.default_id)),
    ("generated_always_type", TinyInt(0)),
    ("generated_always_type_desc", s("NOT_APPLICABLE")),
  ])
}

///|
fn Session::catalog_name(self : Session) -> @types.Value {
  String(if self.view_tempdb { "tempdb" } else { self.rt.database })
}

///|
/// Binding ids of `tempdb.sys.x` views: the view index plus this offset.
/// Their rows describe the session's temp tables (captured: msduck
/// gaps-temp_tables #013, corpus stmts/temp-tempdb-catalog).
const TEMPDB_VIEW_OFFSET : Int = 1048576

///|
/// tempdb lists a local temp table under its internal name: the name padded
/// with '_' to 116 characters plus 12 upper-case hex digits (128 in all;
/// captured: corpus stmts/temp-tempdb-catalog). bitsql's digits are the
/// object id; SQL Server's are an internal counter.
fn tempdb_internal_name(name : String, id : Int) -> String {
  guard name.has_prefix("#") && !name.has_prefix("##") && name.length() < 116 else {
    return name
  }
  let hex = id.reinterpret_as_uint().to_string(radix=16).to_upper()
  let digits = if hex.length() >= 12 {
    hex
  } else {
    "0".repeat(12 - hex.length()) + hex
  }
  name + "_".repeat(116 - name.length()) + digits
}

///|
/// Rows of catalog view `id` (index into `view_defs`, plus
/// `TEMPDB_VIEW_OFFSET` for tempdb) from the current database view.
fn Session::sys_view_rows(
  self : Session,
  id : Int,
) -> Array[(Int64, Array[@types.Value])] {
  let tempdb = id >= TEMPDB_VIEW_OFFSET
  let id = if tempdb { id - TEMPDB_VIEW_OFFSET } else { id }
  let v = view_defs[id]
  let saved = self.view_tempdb
  self.view_tempdb = tempdb
  let rows = self.view_rows(v.schema.to_lower() + "." + v.name.to_lower())
  self.view_tempdb = saved
  if tempdb {
    for r in rows {
      for col in ["name", "table_name"] {
        match r.get(col) {
          Some(String(n)) if n.has_prefix("#") =>
            match self.temp.lookup("dbo", n) {
              Some(tid) => r[col] = String(tempdb_internal_name(n, tid))
              None => ()
            }
          _ => ()
        }
      }
    }
  }
  let out = []
  for k, r in rows {
    out.push((k.to_int64(), project_row(v, r)))
  }
  out
}

///|
fn Session::view_rows(self : Session, key : String) -> Array[VRow] {
  let db = if self.view_tempdb { self.temp } else { self.db_of(0) }
  let tables = db.tables()
  let schema_of = (name : String) => db.schema_id(name).unwrap_or(1)
  let out : Array[VRow] = []
  match key {
    "sys.objects" => {
      for o in user_objects(db) {
        out.push(object_row(o))
      }
      // tempdb's own system objects are not modelled (their ids could
      // collide with temp table ids)
      if !self.view_tempdb {
        for r in system_object_rows() {
          out.push(r)
        }
      }
    }
    "sys.tables" =>
      for t in tables {
        let r = object_row({
          id: t.id,
          name: t.name,
          schema_id: schema_of(t.schema),
          parent: 0,
          code: "U",
          desc: "USER_TABLE",
          created: t.created,
          modified: t.modified,
        })
        let lob = t.columns
          .iter()
          .any(c => {
            // captured: xml, text, ntext and image count too (tail probe)
            c.ty
            is (VarChar(None, _)
            | NVarChar(None, _)
            | VarBinary(None)
            | Xml
            | Text(_)
            | NText(_)
            | Image)
          })
        r["lob_data_space_id"] = i(if lob { 1 } else { 0 })
        r["max_column_id_used"] = i(t.max_column_id)
        r["uses_ansi_nulls"] = b(t.ansi_nulls)
        r["text_in_row_limit"] = i(0)
        r["lock_escalation"] = TinyInt(0)
        r["lock_escalation_desc"] = s("TABLE")
        r["durability"] = TinyInt(0)
        r["durability_desc"] = s("SCHEMA_AND_DATA")
        r["temporal_type"] = TinyInt(0)
        r["temporal_type_desc"] = s("NON_TEMPORAL_TABLE")
        r["data_retention_period"] = i(-1)
        r["data_retention_period_unit"] = i(-1)
        r["data_retention_period_unit_desc"] = s("INFINITE")
        r["ledger_type"] = TinyInt(0)
        r["ledger_type_desc"] = s("NON_LEDGER_TABLE")
        out.push(r)
      }
    "sys.views" =>
      for m in db.modules() {
        guard m.kind is View else { continue }
        let r = object_row(module_obj(db, m))
        r["with_check_option"] = b(m.check_option)
        r["ledger_view_type"] = TinyInt(0)
        r["ledger_view_type_desc"] = s("NON_LEDGER_VIEW")
        out.push(r)
      }
    "sys.procedures" =>
      for m in db.modules() {
        guard m.kind is Procedure else { continue }
        out.push(object_row(module_obj(db, m)))
      }
    "sys.triggers" =>
      for m in db.modules() {
        guard m.kind is Trigger else { continue }
        out.push(
          vrow([
            ("name", s(m.name)),
            ("object_id", i(m.id)),
            ("parent_class", TinyInt(1)),
            ("parent_class_desc", s("OBJECT_OR_COLUMN")),
            ("parent_id", i(m.parent.unwrap_or(0))),
            ("type", s("TR")),
            ("type_desc", s("SQL_TRIGGER")),
            ("create_date", dt(m.created)),
            ("modify_date", dt(m.modified)),
            ("is_disabled", b(m.disabled)),
            ("is_instead_of_trigger", b(m.instead_of)),
          ]),
        )
      }
    "sys.sql_modules" =>
      for m in db.modules() {
        let fn_ = m.kind is (ScalarFunction | InlineFunction | TableFunction)
        out.push(
          vrow([
            ("object_id", i(m.id)),
            ("definition", s(m.definition)),
            ("uses_ansi_nulls", b(m.ansi_nulls)),
            ("uses_quoted_identifier", b(m.quoted_identifier)),
            ("is_schema_bound", b(m.schema_bound)),
            ("uses_database_collation", b(m.schema_bound)),
            ("null_on_null_input", b(false)),
            (
              "inline_type",
              b(fn_ && m.kind is (ScalarFunction | InlineFunction)),
            ),
            (
              "is_inlineable",
              b(fn_ && m.kind is (ScalarFunction | InlineFunction)),
            ),
          ]),
        )
      }
    "sys.columns" => {
      for t in tables {
        for c in t.columns {
          out.push(column_row(t.id, c))
        }
      }
      for m in db.modules() {
        for c in m.columns {
          out.push(column_row(m.id, c))
        }
      }
    }
    "sys.computed_columns" =>
      for t in tables {
        for c in t.columns {
          guard c.computed is Some(text) else { continue }
          let r = column_row(t.id, c)
          r["definition"] = s(definition_text(text))
          r["uses_database_collation"] = b(true)
          r["is_persisted"] = b(c.persisted)
          out.push(r)
        }
      }
    "sys.types" =>
      for r in seed_types {
        let m : Map[String, @types.Value] = Map([])
        for j, c in seed_type_columns {
          m[c] = r[j]
        }
        out.push(m)
      }
    "sys.time_zone_info" => out.append(time_zone_rows(self.rt.now))
    "sys.syslanguages" =>
      for l in @types.languages {
        out.push(
          vrow([
            ("langid", SmallInt(l.langid)),
            ("dateformat", s(l.dateformat.name())),
            ("datefirst", TinyInt(l.datefirst)),
            ("upgrade", i(0)),
            ("name", s(l.name)),
            ("alias", s(l.alias_name)),
            ("months", s(l.months.join(","))),
            ("shortmonths", s(l.short_months.join(","))),
            ("days", s(l.days.join(","))),
            ("lcid", i(l.lcid)),
            ("msglangid", SmallInt(l.msglangid)),
          ]),
        )
      }
    "sys.schemas" =>
      for sc in db.schema_names() {
        out.push(
          vrow([
            ("name", s(sc.0)),
            ("schema_id", i(sc.1)),
            (
              "principal_id",
              i(if sc.1 <= 4 || sc.1 >= 16384 { sc.1 } else { 1 }),
            ),
          ]),
        )
      }
    "sys.databases" => {
      let cur = self.rt.database.to_lower()
      let mut seen = false
      for j, r in seed_databases {
        let m : Map[String, @types.Value] = Map([])
        for k, c in seed_database_columns {
          m[c] = r[k]
        }
        if j < 4 {
          if m.get("name") == Some(String(cur)) {
            seen = true
          }
          match m.get("name") {
            Some(String(n)) => self.server.db_options(n).apply_row(n, m)
            _ => ()
          }
          out.push(m)
        } else if !seen {
          // the user database: a fresh database's settings
          m["name"] = String(self.rt.database)
          m["physical_database_name"] = String(self.rt.database)
          m["database_id"] = Int(5)
          self.server
          .db_options(self.rt.database)
          .apply_row(self.rt.database, m)
          out.push(m)
        }
      }
    }
    "sys.indexes" =>
      for t in tables {
        if !t.indexes.iter().any(ix => ix.clustered) {
          out.push(
            vrow([
              ("object_id", i(t.id)),
              ("index_id", i(0)),
              ("type", TinyInt(0)),
              ("type_desc", s("HEAP")),
              ("data_space_id", i(1)),
              ("allow_row_locks", b(true)),
              ("allow_page_locks", b(true)),
              ("fill_factor", TinyInt(0)),
            ]),
          )
        }
        for ix in t.indexes {
          out.push(
            vrow([
              ("object_id", i(t.id)),
              ("name", s(ix.name)),
              ("index_id", i(ix.index_id)),
              ("type", TinyInt(if ix.clustered { 1 } else { 2 })),
              (
                "type_desc",
                s(if ix.clustered { "CLUSTERED" } else { "NONCLUSTERED" }),
              ),
              ("is_unique", b(ix.unique)),
              ("data_space_id", i(1)),
              ("is_primary_key", b(ix.primary)),
              ("is_unique_constraint", b(ix.is_constraint && !ix.primary)),
              ("fill_factor", TinyInt(ix.fill_factor)),
              ("ignore_dup_key", b(ix.ignore_dup_key)),
              ("is_disabled", b(ix.disabled)),
              ("allow_row_locks", b(true)),
              ("allow_page_locks", b(true)),
              ("has_filter", b(ix.filter is Some(_))),
              ("filter_definition", opt_s(ix.filter.map(definition_text))),
            ]),
          )
        }
      }
    "sys.index_columns" =>
      for t in tables {
        for ix in t.indexes {
          let mut n = 0
          for k, c in ix.columns {
            n += 1
            out.push(
              vrow([
                ("object_id", i(t.id)),
                ("index_id", i(ix.index_id)),
                ("index_column_id", i(n)),
                ("column_id", i(t.columns[c.0].column_id)),
                ("key_ordinal", TinyInt(k + 1)),
                ("partition_ordinal", TinyInt(0)),
                ("is_descending_key", b(c.1)),
                ("is_included_column", b(false)),
                ("column_store_order_ordinal", TinyInt(0)),
                ("data_clustering_ordinal", TinyInt(0)),
              ]),
            )
          }
          for c in ix.included {
            n += 1
            out.push(
              vrow([
                ("object_id", i(t.id)),
                ("index_id", i(ix.index_id)),
                ("index_column_id", i(n)),
                ("column_id", i(t.columns[c].column_id)),
                ("key_ordinal", TinyInt(0)),
                ("partition_ordinal", TinyInt(0)),
                ("is_descending_key", b(false)),
                ("is_included_column", b(true)),
                ("column_store_order_ordinal", TinyInt(0)),
                ("data_clustering_ordinal", TinyInt(0)),
              ]),
            )
          }
        }
      }
    "sys.key_constraints" =>
      for t in tables {
        let sid = schema_of(t.schema)
        for ix in t.indexes {
          guard ix.is_constraint else { continue }
          let r = object_row({
            id: ix.object_id,
            name: ix.name,
            schema_id: sid,
            parent: t.id,
            code: if ix.primary {
              "PK"
            } else {
              "UQ"
            },
            desc: if ix.primary {
              "PRIMARY_KEY_CONSTRAINT"
            } else {
              "UNIQUE_CONSTRAINT"
            },
            created: t.created,
            modified: t.created,
          })
          r["unique_index_id"] = i(ix.index_id)
          r["is_system_named"] = b(ix.auto_named)
          r["is_enforced"] = b(true)
          out.push(r)
        }
      }
    "sys.check_constraints" =>
      for t in tables {
        let sid = schema_of(t.schema)
        for c in t.checks {
          let r = object_row({
            id: c.id,
            name: c.name,
            schema_id: sid,
            parent: t.id,
            code: "C",
            desc: "CHECK_CONSTRAINT",
            created: t.created,
            modified: t.created,
          })
          r["is_disabled"] = b(!c.enabled)
          r["is_not_for_replication"] = b(c.not_for_replication)
          r["is_not_trusted"] = b(c.not_trusted)
          r["parent_column_id"] = i(c.column_id)
          r["definition"] = s(definition_text(c.expr))
          r["uses_database_collation"] = b(true)
          r["is_system_named"] = b(c.auto_named)
          out.push(r)
        }
      }
    "sys.default_constraints" =>
      for t in tables {
        let sid = schema_of(t.schema)
        for c in t.columns {
          guard c.default_id != 0 else { continue }
          let r = object_row({
            id: c.default_id,
            name: c.default_name.unwrap_or(""),
            schema_id: sid,
            parent: t.id,
            code: "D",
            desc: "DEFAULT_CONSTRAINT",
            created: t.created,
            modified: t.created,
          })
          r["parent_column_id"] = i(c.column_id)
          r["definition"] = s(definition_text(c.default_.unwrap_or("")))
          r["is_system_named"] = b(c.default_auto)
          out.push(r)
        }
      }
    "sys.foreign_keys" =>
      for t in tables {
        let sid = schema_of(t.schema)
        for f in t.foreign_keys {
          let r = object_row({
            id: f.id,
            name: f.name,
            schema_id: sid,
            parent: t.id,
            code: "F",
            desc: "FOREIGN_KEY_CONSTRAINT",
            created: t.created,
            modified: t.created,
          })
          r["referenced_object_id"] = i(f.ref_table)
          r["key_index_id"] = match key_index_of(db, t, f) {
            Some(k) => i(k)
            None => Null
          }
          r["is_disabled"] = b(!f.enabled)
          r["is_not_for_replication"] = b(f.not_for_replication)
          r["is_not_trusted"] = b(f.not_trusted)
          let (dn, dd) = action_code(f.on_delete)
          let (un, ud) = action_code(f.on_update)
          r["delete_referential_action"] = TinyInt(dn)
          r["delete_referential_action_desc"] = s(dd)
          r["update_referential_action"] = TinyInt(un)
          r["update_referential_action_desc"] = s(ud)
          r["is_system_named"] = b(f.auto_named)
          out.push(r)
        }
      }
    "sys.foreign_key_columns" =>
      for t in tables {
        for f in t.foreign_keys {
          let parent = if f.ref_table == t.id {
            Some(t)
          } else {
            db.table(f.ref_table)
          }
          for k, c in f.columns {
            let rc = match parent {
              Some(p) => p.columns[f.ref_columns[k]].column_id
              None => 0
            }
            out.push(
              vrow([
                ("constraint_object_id", i(f.id)),
                ("constraint_column_id", i(k + 1)),
                ("parent_object_id", i(t.id)),
                ("parent_column_id", i(t.columns[c].column_id)),
                ("referenced_object_id", i(f.ref_table)),
                ("referenced_column_id", i(rc)),
              ]),
            )
          }
        }
      }
    "information_schema.tables" => {
      for t in tables {
        out.push(
          vrow([
            ("table_catalog", self.catalog_name()),
            ("table_schema", s(t.schema)),
            ("table_name", s(t.name)),
            ("table_type", s("BASE TABLE")),
          ]),
        )
      }
      for m in db.modules() {
        guard m.kind is View else { continue }
        out.push(
          vrow([
            ("table_catalog", self.catalog_name()),
            ("table_schema", s(m.schema)),
            ("table_name", s(m.name)),
            ("table_type", s("VIEW")),
          ]),
        )
      }
    }
    "information_schema.columns" => {
      for t in tables {
        for k, c in t.columns {
          out.push(self.info_column(t.schema, t.name, k + 1, c))
        }
      }
      for m in db.modules() {
        for k, c in m.columns {
          out.push(self.info_column(m.schema, m.name, k + 1, c))
        }
      }
    }
    "information_schema.views" =>
      for m in db.modules() {
        guard m.kind is View else { continue }
        out.push(
          vrow([
            ("table_catalog", self.catalog_name()),
            ("table_schema", s(m.schema)),
            ("table_name", s(m.name)),
            ("view_definition", s(short(m.definition, 4000))),
            ("check_option", s(if m.check_option { "CASCADE" } else { "NONE" })),
            ("is_updatable", s("NO")),
          ]),
        )
      }
    "information_schema.routines" =>
      for m in db.modules() {
        let routine_type = match m.kind {
          Procedure => "PROCEDURE"
          ScalarFunction | InlineFunction | TableFunction => "FUNCTION"
          _ => continue
        }
        let r = vrow([
          ("specific_catalog", self.catalog_name()),
          ("specific_schema", s(m.schema)),
          ("specific_name", s(m.name)),
          ("routine_catalog", self.catalog_name()),
          ("routine_schema", s(m.schema)),
          ("routine_name", s(m.name)),
          ("routine_type", s(routine_type)),
          ("routine_body", s("SQL")),
          ("routine_definition", s(short(m.definition, 4000))),
          ("is_deterministic", s("NO")),
          (
            "sql_data_access",
            s(if m.kind is Procedure { "MODIFIES" } else { "READS" }),
          ),
          ("schema_level_routine", s("YES")),
          (
            "max_dynamic_result_sets",
            SmallInt(if m.kind is Procedure { -1 } else { 0 }),
          ),
          ("is_user_defined_cast", s("NO")),
          ("is_implicitly_invocable", s("NO")),
          ("created", dt(m.created)),
          ("last_altered", dt(m.modified)),
        ])
        if m.kind is (ScalarFunction | InlineFunction | TableFunction) {
          r["is_null_call"] = s("NO")
        }
        match m.kind {
          InlineFunction | TableFunction => r["data_type"] = s("TABLE")
          ScalarFunction =>
            match m.returns {
              Some(ty) => self.fill_type_info(r, ty)
              None => ()
            }
          _ => ()
        }
        out.push(r)
      }
    "information_schema.table_constraints" =>
      for t in tables {
        let add = (name : String, kind : String) => {
          out.push(
            vrow([
              ("constraint_catalog", self.catalog_name()),
              ("constraint_schema", s(t.schema)),
              ("constraint_name", s(name)),
              ("table_catalog", self.catalog_name()),
              ("table_schema", s(t.schema)),
              ("table_name", s(t.name)),
              ("constraint_type", s(kind)),
              ("is_deferrable", s("NO")),
              ("initially_deferred", s("NO")),
            ]),
          )
        }
        for ix in t.indexes {
          if ix.is_constraint {
            add(ix.name, if ix.primary { "PRIMARY KEY" } else { "UNIQUE" })
          }
        }
        for c in t.checks {
          add(c.name, "CHECK")
        }
        for f in t.foreign_keys {
          add(f.name, "FOREIGN KEY")
        }
      }
    "information_schema.key_column_usage" =>
      for t in tables {
        let add = (name : String, col : String, ord : Int) => {
          out.push(
            vrow([
              ("constraint_catalog", self.catalog_name()),
              ("constraint_schema", s(t.schema)),
              ("constraint_name", s(name)),
              ("table_catalog", self.catalog_name()),
              ("table_schema", s(t.schema)),
              ("table_name", s(t.name)),
              ("column_name", s(col)),
              ("ordinal_position", i(ord)),
            ]),
          )
        }
        for ix in t.indexes {
          if ix.is_constraint {
            for k, c in ix.columns {
              add(ix.name, t.columns[c.0].name, k + 1)
            }
          }
        }
        for f in t.foreign_keys {
          for k, c in f.columns {
            add(f.name, t.columns[c].name, k + 1)
          }
        }
      }
    "information_schema.referential_constraints" =>
      for t in tables {
        for f in t.foreign_keys {
          let parent = if f.ref_table == t.id {
            Some(t)
          } else {
            db.table(f.ref_table)
          }
          let (uschema, uname) = match (parent, key_index_of(db, t, f)) {
            (Some(p), Some(k)) =>
              match p.indexes.iter().find_first(ix => ix.index_id == k) {
                Some(ix) if ix.is_constraint => (s(p.schema), s(ix.name))
                _ => (s(p.schema), Null)
              }
            _ => (Null, Null)
          }
          out.push(
            vrow([
              ("constraint_catalog", self.catalog_name()),
              ("constraint_schema", s(t.schema)),
              ("constraint_name", s(f.name)),
              ("unique_constraint_catalog", self.catalog_name()),
              ("unique_constraint_schema", uschema),
              ("unique_constraint_name", uname),
              ("match_option", s("SIMPLE")),
              ("update_rule", s(rule_text(f.on_update))),
              ("delete_rule", s(rule_text(f.on_delete))),
            ]),
          )
        }
      }
    // sys.all_objects = sys.objects + sys.system_objects, sys.all_columns =
    // sys.columns + sys.system_columns (captured: msduck-runs all-objects,
    // system-all-columns #011)
    "sys.system_objects" => out.append(system_objects_rows())
    "sys.all_objects" => {
      out.append(self.view_rows("sys.objects"))
      out.append(system_objects_rows())
    }
    "sys.system_columns" => out.append(system_columns_rows())
    "sys.all_columns" => {
      out.append(self.view_rows("sys.columns"))
      out.append(system_columns_rows())
    }
    "sys.server_principals" => out.append(server_principal_rows())
    "sys.database_files" => out.append(database_file_rows(self.rt.database))
    "sys.dm_exec_sessions"
    | "sys.dm_exec_requests"
    | "sys.dm_exec_connections" => out.append(self.dmv_rows(key))
    "sys.dm_exec_cursors" => out.append(self.cursor_view_rows())
    _ => {
      out.append(self.variant_view_rows(key))
      out.append(self.param_view_rows(key))
    }
  }
  // user-defined types, synonyms, parameters (sysviews_types.mbt)
  self.type_view_rows(key, db, out)
  out
}

///|
fn module_obj(db : @store.Db, m : @store.Module) -> CatObj {
  let (code, desc) = m.kind.code()
  {
    id: m.id,
    name: m.name,
    schema_id: db.schema_id(m.schema).unwrap_or(1),
    parent: m.parent.unwrap_or(0),
    code,
    desc,
    created: m.created,
    modified: m.modified,
  }
}

///|
fn action_code(a : @store.RefAction) -> (Int, String) {
  match a {
    NoAction => (0, "NO_ACTION")
    Cascade => (1, "CASCADE")
    SetNull => (2, "SET_NULL")
    SetDefault => (3, "SET_DEFAULT")
  }
}

///|
fn rule_text(a : @store.RefAction) -> String {
  match a {
    NoAction => "NO ACTION"
    Cascade => "CASCADE"
    SetNull => "SET NULL"
    SetDefault => "SET DEFAULT"
  }
}

///|
/// index_id of the referenced key a foreign key uses.
fn key_index_of(
  db : @store.Db,
  t : @store.Table,
  f : @store.ForeignKey,
) -> Int? {
  let parent = if f.ref_table == t.id { Some(t) } else { db.table(f.ref_table) }
  guard parent is Some(p) else { return None }
  let want = f.ref_columns.copy()
  want.sort()
  // SQL Server prefers the primary key, then unique constraints/indexes
  let mut best : Int? = None
  for ix in p.indexes {
    if !ix.unique || ix.filter is Some(_) {
      continue
    }
    let k = ix.columns.map(c => c.0)
    k.sort()
    if k == want {
      if ix.primary {
        return Some(ix.index_id)
      }
      if best is None {
        best = Some(ix.index_id)
      }
    }
  }
  best
}

///|
/// INFORMATION_SCHEMA.COLUMNS row.
fn Session::info_column(
  self : Session,
  schema : String,
  table : String,
  ordinal : Int,
  c : @store.Column,
) -> VRow {
  let r = vrow([
    ("table_catalog", self.catalog_name()),
    ("table_schema", s(schema)),
    ("table_name", s(table)),
    ("column_name", s(c.name)),
    ("ordinal_position", i(ordinal)),
    ("column_default", opt_s(c.default_.map(definition_text))),
    ("is_nullable", s(if c.nullable { "YES" } else { "NO" })),
  ])
  self.fill_type_info(r, c.ty)
  r
}

///|
/// DATA_TYPE / length / precision / collation columns of INFORMATION_SCHEMA
/// views.
fn Session::fill_type_info(
  self : Session,
  r : VRow,
  ty : @types.SqlType,
) -> Unit {
  ignore(self)
  r["data_type"] = s(ty.base_name())
  match ty {
    Char(n, c) | VarChar(Some(n), c) => {
      r["character_maximum_length"] = i(n)
      r["character_octet_length"] = i(n)
      r["character_set_name"] = s("iso_1")
      r["collation_name"] = s(c.name)
    }
    VarChar(None, c) => {
      r["character_maximum_length"] = i(-1)
      r["character_octet_length"] = i(-1)
      r["character_set_name"] = s("iso_1")
      r["collation_name"] = s(c.name)
    }
    NChar(n, c) | NVarChar(Some(n), c) => {
      r["character_maximum_length"] = i(n)
      r["character_octet_length"] = i(n * 2)
      r["character_set_name"] = s("UNICODE")
      r["collation_name"] = s(c.name)
    }
    NVarChar(None, c) => {
      r["character_maximum_length"] = i(-1)
      r["character_octet_length"] = i(-1)
      r["character_set_name"] = s("UNICODE")
      r["collation_name"] = s(c.name)
    }
    Binary(n) | VarBinary(Some(n)) => {
      r["character_maximum_length"] = i(n)
      r["character_octet_length"] = i(n)
    }
    // captured: xml/type#058
    VarBinary(None) | Xml => {
      r["character_maximum_length"] = i(-1)
      r["character_octet_length"] = i(-1)
    }
    // captured (harness/corpus/conversion/lob-table): text 2147483647
    // characters, ntext 1073741823 (octets 2147483646), image 2147483647
    Text(c) => {
      r["character_maximum_length"] = i(2147483647)
      r["character_octet_length"] = i(2147483647)
      r["character_set_name"] = s("iso_1")
      r["collation_name"] = s(c.name)
    }
    NText(c) => {
      r["character_maximum_length"] = i(1073741823)
      r["character_octet_length"] = i(2147483646)
      r["character_set_name"] = s("UNICODE")
      r["collation_name"] = s(c.name)
    }
    Image => {
      r["character_maximum_length"] = i(2147483647)
      r["character_octet_length"] = i(2147483647)
    }
    TinyInt
    | SmallInt
    | Int
    | BigInt
    | Decimal(_, _)
    | Numeric(_, _)
    | Money
    | SmallMoney => {
      let (_, _, _, p, sc) = type_ids(ty)
      r["numeric_precision"] = TinyInt(p)
      r["numeric_precision_radix"] = SmallInt(10)
      r["numeric_scale"] = i(sc)
    }
    Float | Real => {
      let (_, _, _, p, _) = type_ids(ty)
      r["numeric_precision"] = TinyInt(p)
      r["numeric_precision_radix"] = SmallInt(2)
    }
    Date | SmallDateTime => r["datetime_precision"] = SmallInt(0)
    DateTime => r["datetime_precision"] = SmallInt(3)
    Time(sc) | DateTime2(sc) | DateTimeOffset(sc) =>
      r["datetime_precision"] = SmallInt(sc)
    _ => ()
  }
}
