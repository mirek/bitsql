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
/// Binding environment: variables of the current frame, visible columns and
/// the enclosing query scope for correlated references.
pub(all) struct Env {
  vars : Map[String, VarInfo] // key: lowercased name including '@'
  columns : Array[ColumnRef]
  outer : Env?
  collation : @types.Collation
}

///|
pub fn Env::new(
  vars : Map[String, VarInfo],
  collation? : @types.Collation = @types.default_collation,
) -> Env {
  { vars, columns: [], outer: None, collation, }
}

///|
pub fn Env::with_columns(self : Env, columns : Array[ColumnRef]) -> Env {
  { vars: self.vars, columns, outer: Some(self), collation: self.collation, }
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
