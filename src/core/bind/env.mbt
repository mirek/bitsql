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
  scope : Int // 0 database, 1 session (temp tables, table variables), 2 catalog views
  id : Int
  schema : String
  name : String
  columns : Array[ColumnRef]
}

///|
/// How the binder finds tables. Provided by the session.
pub(all) struct Catalog {
  /// Resolves a (possibly schema-qualified) table name. May raise for
  /// objects that exist but cannot be used (emulator limits).
  table : (@ast.ObjectName) -> TableBinding? raise @types.SqlError
  /// Resolves a table variable `@t`.
  table_var : (String) -> TableBinding?
  /// Resolves a view to its query and declared column names (bound like a
  /// derived table, in an environment of its own).
  view : (@ast.ObjectName) -> (@ast.Query, Array[@ast.Ident])? raise @types.SqlError
  /// Resolves a sequence for NEXT VALUE FOR: (session key, type).
  sequence : (@ast.ObjectName) -> (String, @types.SqlType)?
}

///|
pub fn Catalog::empty() -> Catalog {
  {
    table: _ => None,
    table_var: _ => None,
    view: _ => None,
    sequence: _ => None,
  }
}

///|
/// Binding environment: variables of the current frame, visible columns and
/// the enclosing query scope for correlated references. Every query level
/// (SELECT, derived table, APPLY right side) adds one `with_columns` level;
/// at run time the executor pushes one outer row per level
/// (`@exec.Ctx::push_outer`), so `OuterCol(depth, i)` lines up.
pub(all) struct Env {
  vars : Map[String, VarInfo] // key: lowercased name including '@'
  columns : Array[ColumnRef]
  outer : Env?
  collation : @types.Collation
  catalog : Catalog
  /// Common table expressions in scope, innermost last.
  ctes : Array[CteDef]
  /// OPTION (MAXRECURSION n) of the statement (default 100, 0 = unlimited).
  maxrecursion : Int
  /// Counter for plan-local ids (recursive CTE work tables).
  ids : Ref[Int]
}

///|
/// A CTE visible to FROM: its definition and the environment it binds in
/// (earlier CTEs of the same WITH). `work` is set while binding a recursive
/// CTE's recursive member: references then read work table `id` with the
/// anchor's columns.
pub(all) struct CteDef {
  name : String // lowercased
  def : @ast.Cte
  env : Env
  work : (Int, Array[ColumnRef])?
}

///|
pub fn Env::new(
  vars : Map[String, VarInfo],
  collation? : @types.Collation = @types.default_collation,
  catalog? : Catalog = Catalog::empty(),
) -> Env {
  {
    vars,
    columns: [],
    outer: None,
    collation,
    catalog,
    ctes: [],
    maxrecursion: 100,
    ids: Ref(0),
  }
}

///|
pub fn Env::with_columns(self : Env, columns : Array[ColumnRef]) -> Env {
  { ..self, columns, outer: Some(self), }
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
