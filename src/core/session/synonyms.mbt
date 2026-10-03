// CREATE/DROP SYNONYM and name resolution through synonyms (SELECT, DML,
// EXEC, functions). Captures: harness/corpus/tabletypes/synonyms.sql.
//
// A synonym is a store Module of kind Synonym (sys.objects type SN) whose
// definition is the bracket-quoted base object name, as
// sys.synonyms.base_object_name shows it. Resolution is late: a synonym of
// a missing object fails when used (5313), not when created.

///|
fn bracket(name : String) -> String {
  "[" + name.replace_all(old="]", new="]]") + "]"
}

///|
/// CREATE SYNONYM: no DONE of its own (captured); errors complete with
/// CurCmd 170.
fn Session::exec_create_synonym(
  self : Session,
  name : @ast.ObjectName,
  base : @ast.ObjectName,
) -> Unit raise {
  self.cur_cmd = 170
  let (schema, n) = split_name(name)
  let db = self.db_of(0)
  if db.schema_id(schema) is None {
    raise @types.sql_error(
      2760,
      "The specified schema name \"\{schema}\" either does not exist or you do not have permission to use it.",
    )
  }
  if self.object_name_taken(db, schema, n) {
    raise @types.sql_error(
      2714,
      "There is already an object named '\{object_text(name)}' in the database.",
      state=8,
    )
  }
  let m : @store.Module = {
    id: self.server.object_id(),
    schema,
    name: n,
    kind: Synonym,
    definition: base.parts.map(p => bracket(p.name)).join("."),
    parent: None,
    created: self.rt.now,
    modified: self.rt.now,
    disabled: false,
    instead_of: false,
    columns: [],
    schema_bound: false,
    check_option: false,
    returns: None,
  }
  self.write(0, db.add_module(m))
  self.rt.rowcount = 0
  self.cur_cmd = 253
  self.schema_ddl = true
}

///|
/// DROP SYNONYM [IF EXISTS] (captured: DONE CurCmd 329 per statement; 3701
/// class 11 when missing; 3705 for a table).
fn Session::exec_drop_synonym(
  self : Session,
  if_exists : Bool,
  names : Array[@ast.ObjectName],
) -> Unit raise {
  self.cur_cmd = 329
  for n in names {
    match self.find_module(n) {
      Some(m) if m.kind is Synonym =>
        self.write(0, self.db_of(0).drop_object(m.id))
      _ => {
        if self.find_table(n) is Some(_) {
          raise @types.sql_error(
            3705,
            "Cannot use DROP SYNONYM with '\{object_text(n)}' because '\{object_text(n)}' is a table. Use DROP TABLE.",
          )
        }
        if !if_exists {
          raise drop_missing("synonym", n)
        }
      }
    }
  }
  self.rt.rowcount = 0
  self.done(329)
}

///|
/// DROP TABLE of a synonym is 3705 (captured).
fn Session::not_a_synonym(
  self : Session,
  name : @ast.ObjectName,
  verb : String,
) -> Unit raise @types.SqlError {
  match self.find_module(name) {
    Some(m) if m.kind is Synonym =>
      raise @types.sql_error(
        3705,
        "Cannot use DROP \{verb} with '\{object_text(name)}' because '\{object_text(name)}' is a synonym. Use DROP SYNONYM.",
      )
    _ => ()
  }
}

///|
/// The base object a synonym stands for (`name` itself when it is not a
/// synonym). A base object that does not exist is 5313 (captured for
/// SELECT and INSERT).
fn Session::deref_synonym(
  self : Session,
  name : @ast.ObjectName,
) -> @ast.ObjectName raise @types.SqlError {
  let b = name.base()
  if b.has_prefix("#") || b.has_prefix("@") {
    return name
  }
  guard self.find_module(name) is Some(m) && m.kind is Synonym else {
    return name
  }
  let base = match
    (@parse.parse_statement("DROP TABLE " + m.definition) catch {
      _ => raise @types.not_supported("synonym \{m.name}")
    }).kind {
    Drop(_, [n], ..) => n
    _ => raise @types.not_supported("synonym \{m.name}")
  }
  let k = base.parts.length()
  if k >= 3 {
    let database = base.parts[k - 3].name
    if database != "" && database.to_lower() != self.rt.database.to_lower() {
      raise @types.not_supported("synonyms of objects in another database")
    }
  }
  if k >= 4 {
    raise @types.not_supported("synonyms of objects on another server")
  }
  match self.find_module(base) {
    Some(x) if x.kind is Synonym =>
      raise @types.sql_error(
        5313,
        "Synonym '\{m.schema}.\{m.name}' refers to an invalid object.",
      )
    Some(_) => return base
    None => ()
  }
  if self.find_table(base) is None {
    raise @types.sql_error(
      5313,
      "Synonym '\{m.schema}.\{m.name}' refers to an invalid object.",
    )
  }
  base
}
