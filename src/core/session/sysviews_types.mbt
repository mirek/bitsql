// Catalog rows of user-defined types (sys.types, sys.table_types, the type
// tables' sys.columns / sys.indexes rows), synonyms (sys.synonyms) and
// procedure / function parameters (sys.parameters). Captures:
// harness/corpus/tabletypes/{create-table-type,alias-types,synonyms,
// parameters}.sql. A type table is a system-shipped sys.objects row in
// schema sys named TT_<type>_<object id hex> (captured: msduck-runs
// table-type-catalog #011).

///|
/// The sys.objects entry of a table type's table: TT_<type>_<object id as
/// 8 upper-case hex digits> in schema sys.
fn type_table_obj(ut : @store.UserType, t : @store.Table) -> CatObj {
  let hex = t.id.reinterpret_as_uint().to_string(radix=16).to_upper()
  let hex = "0".repeat(8 - hex.length()) + hex
  {
    id: t.id,
    name: "TT_\{ut.name}_\{hex}",
    schema_id: 4,
    parent: 0,
    code: "TT",
    desc: "TYPE_TABLE",
    created: ut.created,
    modified: ut.created,
  }
}

///|
/// sys.types row of a user-defined type.
fn user_type_row(db : @store.Db, ut : @store.UserType) -> VRow {
  let sid = db.schema_id(ut.schema).unwrap_or(1)
  let (st, len, p, sc, coll) = match ut.base {
    Some(t) => {
      let (st, _, len, p, sc) = type_ids(t)
      (st, len, p, sc, opt_s(t.collation().map(x => x.name)))
    }
    // table types: system_type_id 243, max_length -1
    None => (243, -1, 0, 0, @types.Value::Null)
  }
  vrow([
    ("name", s(ut.name)),
    ("system_type_id", TinyInt(st)),
    ("user_type_id", i(ut.id)),
    ("schema_id", i(sid)),
    ("principal_id", Null),
    ("max_length", SmallInt(len)),
    ("precision", TinyInt(p)),
    ("scale", TinyInt(sc)),
    ("collation_name", coll),
    ("is_nullable", b(ut.nullable)),
    ("is_user_defined", b(true)),
    ("is_assembly_type", b(false)),
    ("default_object_id", i(0)),
    ("rule_object_id", i(0)),
    ("is_table_type", b(ut.table is Some(_))),
  ])
}

///|
/// sys.parameters rows of a procedure or function (parameter_id 0 is a
/// scalar function's return value, captured with an empty name).
fn Session::parameter_rows(self : Session, m : @store.Module) -> Array[VRow] {
  let out = []
  let row = (id : Int, name : String, t : @types.SqlType?, ut : Int?) => {
    let (st, uid, len, p, sc) = match t {
      Some(t) => type_ids(t)
      None => (243, 0, -1, 0, 0)
    }
    vrow([
      ("object_id", i(m.id)),
      ("name", s(name)),
      ("parameter_id", i(id)),
      ("system_type_id", TinyInt(st)),
      ("user_type_id", i(ut.unwrap_or(uid))),
      ("max_length", SmallInt(len)),
      ("precision", TinyInt(p)),
      ("scale", TinyInt(sc)),
      ("is_readonly", b(t is None)),
      ("is_nullable", b(true)),
      ("xml_collection_id", i(0)),
    ])
  }
  if m.kind is ScalarFunction && m.returns is Some(r) {
    let x = row(0, "", Some(r), None)
    x["is_output"] = b(true)
    out.push(x)
  }
  let stmts = @parse.parse_batch(m.definition) catch { _ => return out }
  let params = match
    stmts
    .iter()
    .find_first(s => s.kind is (CreateProcedure(_) | CreateFunction(_))) {
    Some({ kind: CreateProcedure(p), .. }) => p.params
    Some({ kind: CreateFunction(f), .. }) => f.params
    _ => return out
  }
  for k, p in params {
    let x = match
      (self.decl_type(p.type_, self.db_collation()) catch { _ => continue }) {
      ScalarDecl(t, ut, _) => row(k + 1, p.name, Some(t), ut)
      TableDecl(ut) => row(k + 1, p.name, None, Some(ut.id))
    }
    x["is_output"] = b(p.output)
    out.push(x)
  }
  out
}

///|
/// Appends the rows of user types, synonyms and parameters to catalog view
/// `key`.
fn Session::type_view_rows(
  self : Session,
  key : String,
  db : @store.Db,
  out : Array[VRow],
) -> Unit {
  match key {
    "sys.types" =>
      for ut in db.user_types() {
        out.push(user_type_row(db, ut))
      }
    "sys.objects" if !self.view_tempdb =>
      for ut in db.user_types() {
        guard ut.table is Some(t) else { continue }
        let r = object_row(type_table_obj(ut, t))
        r["is_ms_shipped"] = b(true)
        out.push(r)
      }
    "sys.table_types" =>
      for ut in db.user_types() {
        guard ut.table is Some(t) else { continue }
        let r = user_type_row(db, ut)
        r["type_table_object_id"] = i(t.id)
        r["is_memory_optimized"] = b(false)
        out.push(r)
      }
    "sys.columns" =>
      for ut in db.user_types() {
        guard ut.table is Some(t) else { continue }
        for c in t.columns {
          out.push(column_row(t.id, c))
        }
      }
    "sys.indexes" =>
      for ut in db.user_types() {
        guard ut.table is Some(t) else { continue }
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
              ("fill_factor", TinyInt(0)),
              ("allow_row_locks", b(true)),
              ("allow_page_locks", b(true)),
            ]),
          )
        }
      }
    "sys.synonyms" =>
      for m in db.modules() {
        guard m.kind is Synonym else { continue }
        let r = object_row(module_obj(db, m))
        r["base_object_name"] = s(m.definition)
        out.push(r)
      }
    "sys.parameters" =>
      for m in db.modules() {
        if m.kind
          is (Procedure | ScalarFunction | InlineFunction | TableFunction) {
          out.append(self.parameter_rows(m))
        }
      }
    _ => ()
  }
}
