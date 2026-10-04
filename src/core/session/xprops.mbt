// Extended properties: sp_addextendedproperty, sp_updateextendedproperty,
// sp_dropextendedproperty, sys.extended_properties and
// sys.fn_listextendedproperty. knex writes column/table comments with
// them; Sequelize's describeTable joins sys.extended_properties.
//
// Rules captured from SQL Server 17 (corpus orm/extended-properties):
//
// - levels: SCHEMA, then TABLE / VIEW / PROCEDURE / FUNCTION, then COLUMN
//   (other valid level types raise an Emulator error). A property on a
//   schema is class 3 (major_id = schema_id), on an object or column
//   class 1 (major_id = object_id, minor_id = column_id or 0).
// - a NULL @name is a plain procedure error: 15600 class 15 line 22,
//   return status 1, the batch runs on. Every other failure comes from
//   the internal call: class 16, line 37 (add) / 36 (update) / 28 (drop),
//   ERROR_PROCEDURE() the procedure; it ends the batch and rolls back the
//   transaction (inside TRY the CATCH runs).
//   15600 state 1: a lower level without the one above it; state 2: a
//   level type without its name; state 3 / 11: unknown level 0 / 2 type.
//   15135 'Object is invalid. Extended properties are not permitted on
//   '<path>', or the object does not exist.': state 4 schema, 8 object, 9
//   object of another type, 15 column. 15233 duplicate on add; 15217
//   missing property on update (state 2) and drop (state 1).
// - the procedures' token streams (internal DONEINPROCs, BEGIN/ROLLBACK
//   ENVCHANGEs) are not reproduced: the corpus masks them.

///|
/// Where a property lives: (class, major_id, minor_id, path text for
/// messages, objtype for fn_listextendedproperty, objname).
priv struct XTarget {
  class : Int
  major : Int
  minor : Int
  path : String
}

///|
priv suberror XFail {
  XFail(Int, Int, String) // number, state, message
}

///|
fn xprop_invalid(proc : String, state : Int) -> XFail {
  XFail(
    15600,
    state,
    "An invalid parameter or option was specified for procedure '\{proc}'.",
  )
}

///|
fn xprop_missing(path : String, state : Int) -> XFail {
  XFail(
    15135,
    state,
    "Object is invalid. Extended properties are not permitted on '\{path}', or the object does not exist.",
  )
}

///|
let level1_types : Array[String] = [
  "AGGREGATE", "DEFAULT", "FUNCTION", "LOGICAL FILE NAME", "PROCEDURE", "QUEUE",
  "RULE", "SEQUENCE", "SYNONYM", "TABLE", "TABLE_TYPE", "TYPE", "VIEW", "XML SCHEMA COLLECTION",
]

///|
let level0_types : Array[String] = [
  "ASSEMBLY", "CONTRACT", "EVENT NOTIFICATION", "FILEGROUP", "MESSAGE TYPE", "PARTITION FUNCTION",
  "PARTITION SCHEME", "PLAN GUIDE", "REMOTE SERVICE BINDING", "ROUTE", "SCHEMA",
  "SERVICE", "USER", "TRIGGER", "TYPE",
]

///|
let level2_types : Array[String] = [
  "COLUMN", "CONSTRAINT", "EVENT NOTIFICATION", "INDEX", "PARAMETER", "TRIGGER",
]

///|
/// Does module/table kind `kind` match level-1 type `t` (upper case)?
fn xprop_kind_matches(t : String, kind : @store.ObjectKind) -> Bool {
  match t {
    "TABLE" => kind is UserTable
    "VIEW" => kind is View
    "PROCEDURE" => kind is Procedure
    "FUNCTION" => kind is (ScalarFunction | InlineFunction | TableFunction)
    _ => false
  }
}

///|
/// Resolves the level arguments of the add/update/drop procedures.
fn Session::xprop_target(
  self : Session,
  proc : String,
  levels : Array[String?],
) -> XTarget raise {
  let t0 = levels[0].map(x => x.to_upper())
  let n0 = levels[1]
  let t1 = levels[2].map(x => x.to_upper())
  let n1 = levels[3]
  let t2 = levels[4].map(x => x.to_upper())
  let n2 = levels[5]
  // a level without the one above it, a type without its name
  if (t1 is Some(_) && t0 is None) || (t2 is Some(_) && t1 is None) {
    raise xprop_invalid(proc, 1)
  }
  if (t0 is Some(_) && n0 is None) ||
    (t1 is Some(_) && n1 is None) ||
    (t2 is Some(_) && n2 is None) {
    raise xprop_invalid(proc, 2)
  }
  guard t0 is Some(t0) else {
    raise @types.not_supported("database-level extended properties")
  }
  if !level0_types.contains(t0) {
    raise xprop_invalid(proc, 3)
  }
  match t1 {
    Some(t) if !level1_types.contains(t) =>
      raise @types.not_supported("extended property level1type '\{t}'")
    _ => ()
  }
  match t2 {
    Some(t) if !level2_types.contains(t) => raise xprop_invalid(proc, 11)
    _ => ()
  }
  if t0 != "SCHEMA" {
    raise @types.not_supported("extended property level0type '\{t0}'")
  }
  let db = self.db_of(0)
  let schema_name = n0.unwrap_or("")
  let schema_path = match (t1, n1) {
    (Some(_), Some(n)) => schema_name + "." + n
    _ => schema_name
  }
  guard db.schema_id(schema_name) is Some(schema_id) else {
    raise xprop_missing(schema_path, 4)
  }
  guard (t1, n1) is (Some(t1), Some(n1)) else {
    return { class: 3, major: schema_id, minor: 0, path: schema_name, }
  }
  if !(t1 is ("TABLE" | "VIEW" | "PROCEDURE" | "FUNCTION")) {
    raise @types.not_supported("extended property level1type '\{t1}'")
  }
  let canonical = db.schema_name(schema_id).unwrap_or(schema_name)
  let path = canonical + "." + n1
  guard db.lookup(canonical, n1) is Some(id) else {
    raise xprop_missing(schema_name + "." + n1, 8)
  }
  let (kind, columns) : (@store.ObjectKind, Array[@store.Column]) = match
    db.table(id) {
    Some(t) => (UserTable, t.columns)
    None =>
      match db.get_module(id) {
        Some(m) => (m.kind, m.columns)
        None => raise xprop_missing(schema_name + "." + n1, 8)
      }
  }
  if !xprop_kind_matches(t1, kind) {
    raise xprop_missing(schema_name + "." + n1, 9)
  }
  guard (t2, n2) is (Some(t2), Some(n2)) else {
    return { class: 1, major: id, minor: 0, path, }
  }
  if t2 != "COLUMN" {
    raise @types.not_supported("extended property level2type '\{t2}'")
  }
  let col_path = schema_name + "." + n1 + "." + n2
  let column = columns.search_by(c => {
    c.name.to_lower() == n2.to_lower() && self.same_identifier(c.name, n2)
  })
  guard column is Some(k) else { raise xprop_missing(col_path, 15) }
  { class: 1, major: id, minor: columns[k].column_id, path: col_path, }
}

///|
/// Arguments of an extended property procedure by position or @name.
fn Session::xprop_args(
  self : Session,
  names : Array[String],
  args : Array[@ast.ExecArg],
) -> Map[String, (@types.Value, @types.SqlType)] raise {
  let out : Map[String, (@types.Value, @types.SqlType)] = Map([])
  for k, a in args {
    let key = match a.name {
      Some(n) => n.to_lower()
      None => names.get(k).unwrap_or("")
    }
    match self.exec_arg_value(a) {
      Some(v) => out[key] = (v.value, v.ty)
      None => ()
    }
  }
  out
}

///|
/// Reports an internal-call failure: class 16 at the procedure's line; the
/// batch ends and the transaction is rolled back (inside TRY the CATCH
/// runs, the transaction doomed).
fn Session::xprop_abort(
  self : Session,
  proc : String,
  line : Int,
  number : Int,
  state : Int,
  text : String,
) -> Unit raise {
  let e = @types.sql_error(number, text, state~)
  self.rt.error = number
  if self.try_depth > 0 {
    if self.rt.trancount > 0 {
      self.rt.xact_state = -1
    }
    self.module_done(error=false)
    raise Caught(e, line, Some(proc), max_nest_level + 1)
  }
  self.message(e, line, procedure=Some(proc))
  self.abort_transaction()
  self.abort_cmd = Some(253)
  raise AbortBatch
}

///|
/// EXEC sp_addextendedproperty / sp_updateextendedproperty /
/// sp_dropextendedproperty.
fn Session::exec_xprop_proc(
  self : Session,
  proc : String,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let drop = proc == "sp_dropextendedproperty"
  let levels = [
    "@level0type", "@level0name", "@level1type", "@level1name", "@level2type", "@level2name",
  ]
  let names = if drop {
    ["@name", ..levels]
  } else {
    ["@name", "@value", ..levels]
  }
  if !self.check_proc_args(
      proc,
      sysproc_params(names.mapi((k, n) => (n, k > 0))),
      args,
    ) {
    return
  }
  let vals = self.xprop_args(names, args)
  let text = (key : String) => sysproc_text(vals.get(key).map(p => p.0))
  let finish = (status : Int) => {
    match return_var {
      Some(rv) =>
        match self.frame().vars.get(rv.to_lower()) {
          Some(info) =>
            self.frame().values[info.slot] = @types.cast(
              Int(status),
              Int,
              info.ty,
            )
          None => ()
        }
      None => ()
    }
    self.proc_done(status)
  }
  let line = match proc {
    "sp_addextendedproperty" => 37
    "sp_updateextendedproperty" => 36
    _ => 28
  }
  guard text("@name") is Some(name) else {
    // a RAISERROR in the procedure: the batch runs on
    let e = @types.sql_error(
      15600,
      "An invalid parameter or option was specified for procedure '\{proc}'.",
      severity=15,
    )
    if self.try_depth > 0 {
      self.rt.error = 15600
      self.module_done(error=false)
      raise Caught(e, 22, Some(proc), max_nest_level + 1)
    }
    self.message(e, 22, procedure=Some(proc))
    self.out.push(InProcDone(cmd=246, count=None, error=true))
    self.rt.error = 0
    finish(1)
    return
  }
  let target = self.xprop_target(proc, levels.map(text)) catch {
    XFail(n, st, m) => {
      self.xprop_abort(proc, line, n, st, m)
      return
    }
    e => raise e
  }
  let db = self.db_of(0)
  let existing = db.xprop(target.class, target.major, target.minor, name)
  let value : @types.Value = match vals.get("@value") {
    Some((Null, _)) | None => Null
    Some((Variant(v, t), _)) => Variant(v, t)
    Some((v, t)) => @types.cast(v, t, Variant)
  }
  match (proc, existing) {
    ("sp_addextendedproperty", Some(_)) =>
      self.xprop_abort(
        proc,
        line,
        15233,
        1,
        "Property cannot be added. Property '\{name}' already exists for '\{target.path}'.",
      )
    ("sp_addextendedproperty", None) =>
      self.write(
        0,
        db.set_xprop({
          class: target.class,
          major_id: target.major,
          minor_id: target.minor,
          name,
          value,
        }),
      )
    (_, None) =>
      self.xprop_abort(
        proc,
        line,
        15217,
        if drop {
          1
        } else {
          2
        },
        "Property cannot be updated or deleted. Property '\{name}' does not exist for '\{target.path}'.",
      )
    (_, Some(p)) =>
      self.write(
        0,
        if drop {
          db.drop_xprop(target.class, target.major, target.minor, p.name)
        } else {
          db.set_xprop({ ..p, value, })
        },
      )
  }
  self.rt.error = 0
  finish(0)
}

///|
/// Stored properties whose object, column or schema still exists, with
/// (objtype of the object, schema name, object name, column name).
fn Session::live_xprops(
  self : Session,
) -> Array[(@store.ExtendedProperty, String, String, String, String)] {
  let db = self.db_of(0)
  let out = []
  for p in db.xprops() {
    match p.class {
      3 =>
        match db.schema_name(p.major_id) {
          Some(sn) => out.push((p, "SCHEMA", sn, "", ""))
          None => ()
        }
      1 => {
        let found : (String, String, String, Array[@store.Column])? = match
          db.table(p.major_id) {
          Some(t) => Some(("TABLE", t.schema, t.name, t.columns))
          None =>
            match db.get_module(p.major_id) {
              Some(m) => {
                let kind = match m.kind {
                  View => "VIEW"
                  Procedure => "PROCEDURE"
                  ScalarFunction | InlineFunction | TableFunction => "FUNCTION"
                  _ => ""
                }
                Some((kind, m.schema, m.name, m.columns))
              }
              None => None
            }
        }
        guard found is Some((kind, schema, name, columns)) else { continue }
        if p.minor_id == 0 {
          out.push((p, kind, schema, name, ""))
        } else {
          match columns.search_by(c => c.column_id == p.minor_id) {
            Some(k) => out.push((p, kind, schema, name, columns[k].name))
            None => ()
          }
        }
      }
      _ => ()
    }
  }
  out
}

///|
/// Rows of sys.extended_properties.
fn Session::xprop_view_rows(self : Session) -> Array[VRow] {
  self
  .live_xprops()
  .map(x => {
    let p = x.0
    vrow([
      ("class", TinyInt(p.class)),
      (
        "class_desc",
        s(if p.class == 3 { "SCHEMA" } else { "OBJECT_OR_COLUMN" }),
      ),
      ("major_id", i(p.major_id)),
      ("minor_id", i(p.minor_id)),
      ("name", s(p.name)),
      ("value", p.value),
    ])
  })
}

///|
/// Collation of sys.fn_listextendedproperty's columns (captured: flags 15,
/// sort id 0).
let coll_ci_ai : @types.Collation = @types.Collation::parse(
  "Latin1_General_CI_AI",
).unwrap()

///|
/// sys.fn_listextendedproperty(property, level0type, level0name,
/// level1type, level1name, level2type, level2name): the properties at the
/// deepest level given; NULL names match every object of that level.
fn Session::fn_listextendedproperty(
  self : Session,
  args : Array[@types.Value],
) -> (Array[@bind.ColumnRef], Array[Array[@types.Value]]) raise @types.SqlError {
  let col = (n : String, ty : @types.SqlType, nullable : Bool) => @bind.ColumnRef::{
    untyped_null: false,
    qualifier: "fn_listextendedproperty",
    name: n,
    ty,
    nullable,
    origin: BaseColumn(identity=false),
  }
  let cols = [
    col("objtype", VarChar(Some(128), coll_ci_ai), true),
    col("objname", NVarChar(Some(128), coll_ci_ai), true),
    col("name", NVarChar(Some(128), coll_ci_ai), false),
    col("value", Variant, true),
  ]
  if args.length() != 7 {
    raise @types.sql_error(
      216, "Parameters supplied for object 'fn_listextendedproperty' does not match the parameters expected.",
    )
  }
  // the string 'default' is a name like any other (captured: no rows)
  let a = args.map(v => sysproc_text(Some(v)))
  let prop = a[0]
  let up = (x : String?) => x.map(t => t.to_upper())
  let (t0, t1, t2) = (up(a[1]), up(a[3]), up(a[5]))
  let eq = (x : String?, y : String) => {
    match x {
      None => true
      Some(v) => v.to_lower() == y.to_lower() && self.same_identifier(y, v)
    }
  }
  let rows = []
  guard t0 is Some(t0) else { return (cols, rows) }
  for x in self.live_xprops() {
    let (p, kind, schema, name, column) = x
    if !eq(prop, p.name) {
      continue
    }
    let row = match (t1, t2) {
      (None, _) =>
        if t0 == "SCHEMA" && p.class == 3 && eq(a[2], schema) {
          Some(("SCHEMA", schema))
        } else {
          None
        }
      (Some(t1), None) =>
        if t0 == "SCHEMA" &&
          p.class == 1 &&
          column == "" &&
          kind == t1 &&
          eq(a[2], schema) &&
          eq(a[4], name) {
          Some((t1, name))
        } else {
          None
        }
      (Some(t1), Some(t2)) =>
        if t0 == "SCHEMA" &&
          t2 == "COLUMN" &&
          p.class == 1 &&
          column != "" &&
          kind == t1 &&
          eq(a[2], schema) &&
          eq(a[4], name) &&
          eq(a[6], column) {
          Some(("COLUMN", column))
        } else {
          None
        }
    }
    match row {
      Some((objtype, objname)) =>
        rows.push([s(objtype), s(objname), s(p.name), p.value])
      None => ()
    }
  }
  (cols, rows)
}
