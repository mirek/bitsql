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
  /// The column is SQL Server's "NULL constant" read through a derived
  /// table, CTE or VALUES (every row NULL, reported as int): a reference
  /// binds as the untyped NULL literal, so it converts to any type
  /// (captured: query/derived-untyped-null). Views, inline functions,
  /// SELECT INTO and scalar subqueries type it int.
  untyped_null : Bool
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
  /// SET ANSI_NULLS stored with a view (its body binds with it).
  view_ansi_nulls : (@ast.ObjectName) -> Bool
  /// Resolves a sequence for NEXT VALUE FOR: (session key, type).
  sequence : (@ast.ObjectName) -> (String, @types.SqlType)?
  /// Resolves a user-defined function (scalar, inline or multi-statement
  /// table-valued) by name; unqualified names resolve in dbo.
  function : (@ast.ObjectName) -> UserFunction? raise @types.SqlError
  /// True when the name is a user-defined type of the database (CAST to
  /// it is 243 state 2 rather than state 1).
  user_type : (@ast.TypeName) -> Bool
  /// System table-valued functions computed by the session from constant
  /// arguments (sys.dm_exec_describe_first_result_set): lowercased name
  /// and argument values to columns and rows; None when unknown.
  system_tvf : (String, Array[@types.Value]) -> (
    Array[ColumnRef],
    Array[Array[@types.Value]],
  )? raise @types.SqlError
  /// The current database's compatibility level (SOUNDEX below 110 keeps
  /// the old H/W rule).
  preview_features : () -> Bool
  compat_level : () -> Int
}

///|
/// A user-defined function as the binder sees it (session/udf.mbt builds it
/// from the stored CREATE FUNCTION).
pub(all) struct UserFunction {
  id : Int
  params : Array[UserParam]
  kind : UserFunctionKind
  /// SET ANSI_NULLS stored with the function (an inline body binds with it).
  ansi_nulls : Bool
}

///|
/// A function parameter: lowercased-insensitive name (with '@'), declared
/// type and the `= default` expression, used only for a DEFAULT argument.
pub(all) struct UserParam {
  name : String
  ty : @types.SqlType
  default_ : @ast.Expr?
  /// A READONLY table-valued parameter: its table type's name (for 206).
  /// The argument must be a table variable; scalar and multi-statement
  /// functions receive its table id as an int argument.
  table_type : String?
}

///|
pub(all) enum UserFunctionKind {
  /// RETURNS type.
  Scalar(@types.SqlType)
  /// RETURNS TABLE AS RETURN query.
  Inline(@ast.Query)
  /// RETURNS @t TABLE (...): the declared columns.
  MultiStatement(Array[ColumnRef])
}

///|
pub fn Catalog::empty() -> Catalog {
  {
    table: _ => None,
    table_var: _ => None,
    view: _ => None,
    view_ansi_nulls: _ => true,
    sequence: _ => None,
    function: _ => None,
    user_type: _ => false,
    system_tvf: (_, _) => None,
    preview_features: () => false,
    compat_level: () => 170,
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
  /// Views and inline table-valued functions being expanded (nesting
  /// guard: an ALTERed module can reference itself).
  nest : Int
  /// The plan producing `columns`, when known: lets collation precedence
  /// see through derived tables, CTEs and views (bind/collation.mbt).
  from_plan : @ir.Plan?
  /// SQL Server's simple parameterization applies to the statement:
  /// string and binary literals are typed varchar(8000) / nvarchar(4000) /
  /// varbinary(8000) (visible in sql_variant base types; captured:
  /// variant/insert-values.sql). Set by the session for INSERT/UPDATE.
  literal_params : Bool
  /// Errors SQL Server reports together with a later one in the same
  /// statement (8155 then 207); shared by all copies of the Env, owned by
  /// the session, which prints them before the statement's error.
  deferred : Array[@types.SqlError]
  /// Table-valued parameters of an inline function being expanded: the
  /// parameter name (lowercased) → the caller's table variable.
  table_params : Map[String, TableBinding]
  /// SET ANSI_NULLS: OFF makes `=` / `<>` against a NULL literal or a
  /// variable two-valued (bind/ansi_nulls.mbt).
  ansi_nulls : Bool
  /// Other SET options with semantics bitsql does not model
  /// (bind/set_options.mbt).
  options : BindOptions
}

///|
/// SET options the binder checks (defaults: SQL Server's).
pub(all) struct BindOptions {
  concat_null_yields_null : Bool
  numeric_roundabort : Bool
  /// The SET options listed by error 1934 that are not at their required
  /// values (ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT,
  /// CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON; NUMERIC_ROUNDABORT OFF).
  wrong_for_indexes : Array[String]
}

///|
pub fn BindOptions::default() -> BindOptions {
  {
    concat_null_yields_null: true,
    numeric_roundabort: false,
    wrong_for_indexes: [],
  }
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
  deferred? : Array[@types.SqlError] = [],
  ansi_nulls? : Bool = true,
  options? : BindOptions = BindOptions::default(),
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
    nest: 0,
    from_plan: None,
    literal_params: false,
    deferred,
    table_params: Map([]),
    ansi_nulls,
    options,
  }
}

///|
/// A table variable `@t` (or a table-valued parameter of an inline
/// function being expanded).
pub fn Env::table_var(self : Env, name : String) -> TableBinding? {
  match self.table_params.get(name.to_lower()) {
    Some(b) => Some(b)
    None => (self.catalog.table_var)(name)
  }
}

///|
pub fn Env::with_columns(self : Env, columns : Array[ColumnRef]) -> Env {
  { ..self, columns, outer: Some(self), from_plan: None, }
}

///|
/// `with_columns` for columns produced by `plan` (row layout = columns).
fn Env::with_source(
  self : Env,
  columns : Array[ColumnRef],
  plan : @ir.Plan,
) -> Env {
  { ..self, columns, outer: Some(self), from_plan: Some(plan), }
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
