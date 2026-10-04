///|
/// `ALTER SCHEMA s TRANSFER [class::] name` (captured: tail5/b2-schema-
/// transfer, msduck-runs all-objects#029). Success sends no DONE of its own
/// (like CREATE SCHEMA); errors are statement-level and complete with
/// CurCmd 170. The object keeps its object_id; a table takes its
/// constraints and triggers along; a module's text is unchanged, so views
/// naming the old schema stop binding (208 + 4413 when used). Transferring
/// into the object's own schema does nothing. Transactional.
fn Session::exec_schema_transfer(
  self : Session,
  target : @ast.Ident,
  cls : String,
  name : @ast.ObjectName,
) -> Unit raise {
  self.cur_cmd = 170
  let (schema, base) = split_name(name)
  if base.has_prefix("#") {
    raise @types.sql_error(
      33144, "Cannot change the schema of a temporary object.",
    )
  }
  let db = self.db_of(0)
  guard db.schema_id(target.name) is Some(_) else {
    raise @types.sql_error(
      15151,
      "Cannot alter the schema '\{target.name}', because it does not exist or you do not have permission.",
    )
  }
  let new_schema = db
    .schema_name(db.schema_id(target.name).unwrap_or(1))
    .unwrap_or(target.name)
  if new_schema.to_lower() is ("sys" | "information_schema") {
    raise @types.sql_error(
      2710,
      "You are not the owner specified for the object '\{target.name}' in this statement (CREATE, ALTER, TRUNCATE, UPDATE STATISTICS or BULK INSERT).",
    )
  }
  let missing = (what : String) => {
    @types.sql_error(
      15151,
      "Cannot find the \{what} '\{base}', because it does not exist or you do not have permission.",
    )
  }
  match cls {
    "TYPE" => {
      guard db.lookup_type(schema, base) is Some(t) else {
        raise missing("type")
      }
      if t.schema.to_lower() == new_schema.to_lower() {
        return self.transferred()
      }
      if db.lookup_type(new_schema, t.name) is Some(_) {
        raise @types.not_supported(
          "ALTER SCHEMA TRANSFER of a type onto an existing name",
        )
      }
      self.write(0, db.drop_type(t.id).add_type({ ..t, schema: new_schema, }))
      return self.transferred()
    }
    "OBJECT" => ()
    _ => raise missing("xml schema collection")
  }
  guard db.lookup(schema, base) is Some(id) else { raise missing("object") }
  let (old_schema, oname) = match db.table(id) {
    Some(t) => (t.schema, t.name)
    None =>
      match db.get_module(id) {
        // triggers move with their table only
        Some(m) if m.parent is None => (m.schema, m.name)
        _ => raise missing("object")
      }
  }
  if old_schema.to_lower() == new_schema.to_lower() {
    return self.transferred()
  }
  if self.object_name_taken(db, new_schema, oname) {
    raise @types.sql_error(
      15530,
      "The object with name \"\{oname}\" already exists.",
    )
  }
  if self.schema_bound_mentions([oname], except=id) {
    raise @types.not_supported(
      "ALTER SCHEMA TRANSFER of an object with schema-bound dependents",
    )
  }
  let now = self.rt.now
  match db.table(id) {
    Some(t) => {
      let mut d = db
      for m in db.modules() {
        if m.parent == Some(id) {
          if self.object_name_taken(d, new_schema, m.name) {
            raise @types.not_supported(
              "ALTER SCHEMA TRANSFER where a trigger name exists in the target schema",
            )
          }
          d = d.rename_module({ ..m, schema: new_schema, })
        }
      }
      let names = constraint_names(t)
      for n in names {
        if self.object_name_taken(db, new_schema, n) {
          raise @types.not_supported(
            "ALTER SCHEMA TRANSFER where a constraint name exists in the target schema",
          )
        }
      }
      self.write(0, d.alter_table({ ..t, schema: new_schema, modified: now, }))
    }
    None =>
      match db.get_module(id) {
        Some(m) =>
          self.write(
            0,
            db.rename_module({ ..m, schema: new_schema, modified: now, }),
          )
        None => raise missing("object")
      }
  }
  self.transferred()
}

///|
fn Session::transferred(self : Session) -> Unit {
  self.rt.rowcount = 0
  self.cur_cmd = 253
  self.schema_ddl = true
}

///|
/// Names of a table's schema-scoped constraints (keys, checks, foreign
/// keys, defaults).
fn constraint_names(t : @store.Table) -> Array[String] {
  let out = []
  for ix in t.indexes {
    if ix.is_constraint {
      out.push(ix.name)
    }
  }
  for c in t.checks {
    out.push(c.name)
  }
  for f in t.foreign_keys {
    out.push(f.name)
  }
  for c in t.columns {
    if c.default_id != 0 {
      match c.default_name {
        Some(n) => out.push(n)
        None => ()
      }
    }
  }
  out
}
