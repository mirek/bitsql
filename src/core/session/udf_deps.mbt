// Dependencies on functions and tables that SQL Server enforces (captured:
// msduck gaps-functions #133-#151):
//
// - a function used by a computed column or a DEFAULT constraint, and any
//   object used by a WITH SCHEMABINDING module, cannot be dropped (3729
//   state 1 "Cannot DROP FUNCTION 'dbo.inc' because it is being referenced
//   by object 'c'.", naming the table of a computed column, the DEFAULT
//   constraint, or the module) or altered (functions: 3729 state 3 "Cannot
//   ALTER 'dbo.inc' ...", a compile error);
// - a schema-bound function must name objects in two parts (4512 state 3)
//   and may only call schema-bound functions (4513 state 2).
//
// References are found in the stored definition text: two-part names
// `schema.name` (any quoting).

///|
/// Lowercased (schema, name) pairs of the two-part names in `text`.
fn two_part_names(text : String) -> Array[(String, String)] {
  let toks = @lex.lex(text) catch { _ => return [] }
  let out : Array[(String, String)] = []
  let is_name = (i : Int) => {
    match toks.get(i) {
      Some(t) => t.kind is (Word | QuotedIdent)
      None => false
    }
  }
  let is_dot = (i : Int) => {
    match toks.get(i) {
      Some(t) => t.kind is Punct && t.text == "."
      None => false
    }
  }
  for i in 0..<toks.length() {
    if is_name(i) &&
      is_dot(i + 1) &&
      is_name(i + 2) &&
      !is_dot(i + 3) &&
      !(i > 0 && is_dot(i - 1)) {
      out.push((toks[i].text.to_lower(), toks[i + 2].text.to_lower()))
    }
  }
  out
}

///|
/// The object that keeps (schema, name) from being dropped or altered:
/// computed columns and DEFAULTs (for functions) and schema-bound modules.
fn Session::referencing_object(
  self : Session,
  schema : String,
  name : String,
  function : Bool,
) -> String? {
  let key = (schema.to_lower(), name.to_lower())
  let db = self.db_of(0)
  if function {
    for t in db.tables() {
      for c in t.columns {
        match c.computed {
          Some(text) if two_part_names(text).contains(key) =>
            return Some(t.name)
          _ => ()
        }
        match (c.default_, c.default_name) {
          (Some(text), Some(dn)) if two_part_names(text).contains(key) =>
            return Some(dn)
          _ => ()
        }
      }
    }
  }
  for m in db.modules() {
    if m.schema_bound &&
      !(m.schema.to_lower() == key.0 && m.name.to_lower() == key.1) &&
      two_part_names(m.definition).contains(key) {
      return Some(m.name)
    }
  }
  None
}

///|
/// 3729 for DROP FUNCTION / DROP TABLE of a referenced object.
fn Session::check_drop_references(
  self : Session,
  verb : String,
  n : @ast.ObjectName,
  schema : String,
  name : String,
  function : Bool,
) -> Unit raise @types.SqlError {
  match self.referencing_object(schema, name, function) {
    Some(by) =>
      raise @types.sql_error(
        3729,
        "Cannot DROP \{verb} '\{object_text(n)}' because it is being referenced by object '\{by}'.",
      )
    None => ()
  }
}

///|
/// ALTER FUNCTION of a referenced function (3729 state 3), and the schema
/// binding rules of a new definition (4512, 4513).
fn Session::check_function_binding(
  self : Session,
  f : @ast.CreateFunction,
) -> Unit raise @types.SqlError {
  let (schema, base) = split_name(f.name)
  if !(f.mode is Create) {
    match self.find_module(f.name) {
      Some(m) if m.kind is (ScalarFunction | InlineFunction | TableFunction) =>
        match self.referencing_object(schema, base, true) {
          Some(by) =>
            raise @types.sql_error(
              3729,
              "Cannot ALTER '\{object_text(f.name)}' because it is being referenced by object '\{by}'.",
              state=3,
            )
          None => ()
        }
      _ => ()
    }
  }
  if !f.options.contains("SCHEMABINDING") {
    return
  }
  // one-part names after FROM / JOIN
  let toks = @lex.lex(f.definition) catch { _ => [] }
  for i in 1..<toks.length() {
    let prev = toks[i - 1]
    let t = toks[i]
    let after_from = prev.kind is Word &&
      (prev.text.to_upper() == "FROM" || prev.text.to_upper() == "JOIN")
    let next_dot = match toks.get(i + 1) {
      Some(x) => x.kind is Punct && (x.text == "." || x.text == "(")
      None => false
    }
    if after_from && t.kind is (Word | QuotedIdent) && !next_dot {
      raise @types.sql_error(
        4512,
        "Cannot schema bind function '\{object_text(f.name)}' because name '\{t.text}' is invalid for schema binding. Names must be in two-part format and an object cannot reference itself.",
        state=3,
      )
    }
  }
  let db = self.db_of(0)
  for r in two_part_names(f.definition) {
    if r.0 == schema.to_lower() && r.1 == base.to_lower() {
      continue
    }
    match db.lookup(r.0, r.1) {
      Some(id) =>
        match db.get_module(id) {
          Some(m) if m.kind is (ScalarFunction | InlineFunction | TableFunction) &&
            !m.schema_bound =>
            raise @types.sql_error(
              4513,
              "Cannot schema bind function '\{object_text(f.name)}'. '\{m.schema}.\{m.name}' is not schema bound.",
              state=2,
            )
          _ => ()
        }
      None => ()
    }
  }
}
