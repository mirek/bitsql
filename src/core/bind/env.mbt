///|
pub(all) struct VarInfo {
  slot : Int
  ty : @types.SqlType
} derive(Debug)

///|
/// A column visible to expressions (from FROM, or a derived table).
pub(all) struct ColumnRef {
  qualifier : String // lowercased table alias or name; "" if none
  name : String
  ty : @types.SqlType
  nullable : Bool
  origin : @ir.Origin
} derive(Debug)

///|
/// A table visible to queries.
pub(all) struct TableBinding {
  scope : Int // 0 database, 1 session (temp tables, table variables)
  id : Int
  schema : String
  name : String
  columns : Array[ColumnRef]
}

///|
/// How the binder finds tables. Provided by the session.
pub(all) struct Catalog {
  /// Resolves a (possibly schema-qualified) table name.
  table : (@ast.ObjectName) -> TableBinding?
  /// Resolves a table variable `@t`.
  table_var : (String) -> TableBinding?
}

///|
pub fn Catalog::empty() -> Catalog {
  { table: _ => None, table_var: _ => None, }
}

///|
/// Binding environment: variables of the current frame, visible columns and
/// the enclosing query scope for correlated references.
pub(all) struct Env {
  vars : Map[String, VarInfo] // key: lowercased name including '@'
  columns : Array[ColumnRef]
  outer : Env?
  collation : @types.Collation
  catalog : Catalog
}

///|
pub fn Env::new(
  vars : Map[String, VarInfo],
  collation? : @types.Collation = @types.default_collation,
  catalog? : Catalog = Catalog::empty(),
) -> Env {
  { vars, columns: [], outer: None, collation, catalog, }
}

///|
pub fn Env::with_columns(self : Env, columns : Array[ColumnRef]) -> Env {
  {
    vars: self.vars,
    columns,
    outer: Some(self),
    collation: self.collation,
    catalog: self.catalog,
  }
}

///|
fn err(
  number : Int,
  message : String,
  state? : Int = 1,
  severity? : Int = 16,
) -> @types.SqlError {
  @types.sql_error(number, message, state~, severity~)
}
