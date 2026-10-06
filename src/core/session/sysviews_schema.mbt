// INFORMATION_SCHEMA.PARAMETERS, CHECK_CONSTRAINTS, CONSTRAINT_COLUMN_USAGE
// and SCHEMATA (sys.parameters is in sysviews_types.mbt). Descriptors:
// harness/corpus/catalog/view-descriptors-schema.sql; values captured in
// msduck gaps-catalog v2-information-schema-*:
//
// - parameters of procedures and functions in declaration order from 1;
//   a scalar function also has its return value as ordinal 0 with an empty
//   name, mode 'OUT' and IS_RESULT 'YES'; OUTPUT parameters are 'INOUT';
// - CONSTRAINT_COLUMN_USAGE lists key, CHECK (every referenced column)
//   and FOREIGN KEY (referencing) columns; DEFAULT constraints are absent;
// - SCHEMATA: DEFAULT_CHARACTER_SET_NAME 'iso_1', owner = the schema's
//   principal.

///|
/// (name, type, output, read only) of a module's parameters; the return
/// value of a scalar function first, named "" (None when the definition
/// does not parse).
fn module_parameters(
  m : @store.Module,
) -> Array[(String, @types.SqlType?, Bool, Bool)]? {
  let stmts = @parse.parse_batch(m.definition) catch { _ => return None }
  let resolve = (t : @ast.TypeName) => {
    try
      @bind.resolve_type(t, Declaration, @types.default_collation, preview=true)
    catch {
      _ => None
    } noraise {
      ty => Some(ty)
    }
  }
  for s in stmts {
    match s.kind {
      CreateProcedure(p) =>
        return Some(
          p.params.map(x => (x.name, resolve(x.type_), x.output, x.read_only)),
        )
      CreateFunction(f) => {
        let out = []
        if f.returns is Scalar(t, _) {
          out.push(("", resolve(t), true, false))
        }
        for x in f.params {
          out.push((x.name, resolve(x.type_), x.output, x.read_only))
        }
        return Some(out)
      }
      _ => ()
    }
  }
  None
}

///|
/// Rows of the views defined in this file (empty for others).
fn Session::param_view_rows(self : Session, key : String) -> Array[VRow] {
  let db = self.db_of(0)
  let out : Array[VRow] = []
  match key {
    "information_schema.parameters" =>
      for m in db.modules() {
        guard m.kind
          is (Procedure | ScalarFunction | InlineFunction | TableFunction) else {
          continue
        }
        guard module_parameters(m) is Some(params) else { continue }
        let first = if m.kind is ScalarFunction { 0 } else { 1 }
        for k, p in params {
          let (name, ty, output, _) = p
          guard ty is Some(ty) else { continue }
          let result = m.kind is ScalarFunction && k == 0
          let r = vrow([
            ("specific_catalog", self.catalog_name()),
            ("specific_schema", s(m.schema)),
            ("specific_name", s(m.name)),
            ("ordinal_position", i(first + k)),
            (
              "parameter_mode",
              s(if result { "OUT" } else if output { "INOUT" } else { "IN" }),
            ),
            ("is_result", s(if result { "YES" } else { "NO" })),
            ("as_locator", s("NO")),
            ("parameter_name", s(name)),
          ])
          self.fill_type_info(r, ty)
          out.push(r)
        }
      }
    "information_schema.check_constraints" =>
      for t in db.tables() {
        for c in t.checks {
          out.push(
            vrow([
              ("constraint_catalog", self.catalog_name()),
              ("constraint_schema", s(t.schema)),
              ("constraint_name", s(c.name)),
              ("check_clause", s(definition_text(c.expr))),
            ]),
          )
        }
      }
    "information_schema.constraint_column_usage" =>
      for t in db.tables() {
        let add = (col : String, name : String) => {
          out.push(
            vrow([
              ("table_catalog", self.catalog_name()),
              ("table_schema", s(t.schema)),
              ("table_name", s(t.name)),
              ("column_name", s(col)),
              ("constraint_catalog", self.catalog_name()),
              ("constraint_schema", s(t.schema)),
              ("constraint_name", s(name)),
            ]),
          )
        }
        for ix in t.indexes {
          if ix.is_constraint {
            for c in ix.columns {
              add(t.columns[c.0].name, ix.name)
            }
          }
        }
        for c in t.checks {
          for n in check_columns(c.expr) {
            match t.column_index(n) {
              Some(k) => add(t.columns[k].name, c.name)
              None => ()
            }
          }
        }
        for f in t.foreign_keys {
          for c in f.columns {
            add(t.columns[c].name, f.name)
          }
        }
      }
    "information_schema.schemata" =>
      for x in db.schema_names() {
        let (name, id) = x
        // built-in schemas are owned by the principal of the same name,
        // user schemas by dbo unless AUTHORIZATION says otherwise
        let owner = if id < 5 || id >= 16384 { name } else { "dbo" }
        out.push(
          vrow([
            ("catalog_name", self.catalog_name()),
            ("schema_name", s(name)),
            ("schema_owner", s(owner)),
            ("default_character_set_name", s("iso_1")),
          ]),
        )
      }
    _ => ()
  }
  out
}
