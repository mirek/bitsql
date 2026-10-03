///|
/// A full query expression: optional CTEs, a body (SELECT or set operation)
/// and the tail clauses that apply to the whole body.
pub(all) struct Query {
  ctes : Array[Cte]
  body : QueryBody
  order_by : Array[OrderItem]
  offset : Expr?
  fetch : Expr?
  for_clause : ForClause?
  options : Array[QueryHint]
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Cte {
  name : Ident
  columns : Array[Ident]
  query : Query
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum SetOp {
  Union
  UnionAll
  Except
  Intersect
} derive(Eq, Debug)

///|
/// INTERSECT binds tighter than UNION / EXCEPT; both are left-associative.
pub(all) enum QueryBody {
  Select(Select)
  SetOperation(SetOp, QueryBody, QueryBody)
  /// `( query )` as an operand of a set operation.
  Nested(Query)
} derive(Eq, Debug)

///|
pub(all) struct Top {
  count : Expr
  percent : Bool
  with_ties : Bool
  /// `TOP (expr)` rather than legacy `TOP n`.
  parenthesized : Bool
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Select {
  distinct : Bool
  top : Top?
  items : Array[SelectItem]
  into : ObjectName?
  /// Comma-separated FROM list (each element may be a join tree).
  from : Array[TableRef]
  where_ : Expr?
  group_by : Array[GroupItem]
  having : Expr?
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct SelectItem {
  kind : SelectItemKind
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum SelectItemKind {
  /// `*` (empty qualifier) or `t.*`
  Star(Array[Ident])
  /// `expr [AS] alias` or `alias = expr`
  ExprItem(Expr, alias_~ : Ident?)
  /// `@v = expr`, `@v += expr`
  Assign(String, AssignOp, Expr)
} derive(Eq, Debug)

///|
pub(all) enum GroupItem {
  GroupExpr(Expr)
  Rollup(Array[Array[Expr]])
  Cube(Array[Array[Expr]])
  GroupingSets(Array[GroupItem])
  /// `()` grand total.
  GroupEmpty
  /// `(a, b)` inside GROUPING SETS.
  GroupTuple(Array[Expr])
} derive(Eq, Debug)

///|
pub(all) enum JsonMode {
  JsonPath
  JsonAuto
} derive(Eq, Debug)

///|
pub(all) enum ForClause {
  /// `root` is `Some("root")` for a bare `ROOT`.
  ForJson(
    mode~ : JsonMode,
    root~ : String?,
    include_null_values~ : Bool,
    without_array_wrapper~ : Bool
  )
  /// FOR XML is parse-only: mode (RAW/AUTO/PATH/EXPLICIT), optional element
  /// name, and remaining options as upper-cased text (`TYPE`, `ROOT('x')`).
  ForXml(mode~ : String, element~ : String?, options~ : Array[String])
  ForBrowse
} derive(Eq, Debug)

///|
/// `OPTION (...)` hint, as upper-cased token text, e.g. `MAXRECURSION 0`.
pub(all) struct QueryHint {
  text : String
  span : Span
} derive(Eq, Debug)

///|
/// `WITH (NOLOCK, INDEX(ix))` table hint: upper-cased name plus raw args.
pub(all) struct TableHint {
  name : String
  args : Array[String]
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum JoinKind {
  Inner
  Left
  Right
  Full
  Cross
  CrossApply
  OuterApply
} derive(Eq, Debug)

///|
/// `OPENJSON(...) WITH (name type ['path'] [AS JSON])` column.
pub(all) struct OpenJsonColumn {
  name : Ident
  type_ : TypeName
  path : String?
  as_json : Bool
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct TableRef {
  kind : TableRefKind
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum TableRefKind {
  Table(ObjectName, alias_~ : Ident?, hints~ : Array[TableHint])
  /// Table variable `@t`.
  TableVar(String, alias_~ : Ident?, hints~ : Array[TableHint])
  Derived(Query, alias_~ : Ident?, columns~ : Array[Ident])
  Values(Array[Array[Expr]], alias_~ : Ident, columns~ : Array[Ident])
  /// Table-valued function; `openjson_with` is the `WITH (...)` schema of
  /// OPENJSON.
  TableFunc(
    ObjectName,
    Array[Expr],
    openjson_with~ : Array[OpenJsonColumn]?,
    alias_~ : Ident?,
    columns~ : Array[Ident]
  )
  /// `hint` is a join hint (LOOP/HASH/MERGE/REMOTE) if written.
  Join(JoinKind, TableRef, TableRef, on~ : Expr?, hint~ : String?)
  /// xml `target.nodes('xquery') [AS] alias(column)`; `target` is a
  /// variable or (possibly qualified) column.
  Nodes(Expr, Array[Expr], alias_~ : Ident?, columns~ : Array[Ident])
} derive(Eq, Debug)
