///|
/// How a result column was produced; decides the COLMETADATA flags word.
/// Captured (traps/metadata-not-from-values): base table columns 0x08|null,
/// computed expressions 0x20|null, UNION outputs 0, aggregates 0x01 only.
pub(all) enum Origin {
  BaseColumn(identity~ : Bool)
  /// An identity column of the table under SET IDENTITY_INSERT ON: 0x10
  /// with the updateable bit 0x08 (captured: msduck identity-insert-*,
  /// flags 24 instead of 16).
  InsertableIdentity
  Computed
  /// A table's computed column (flags as Computed; keeps 0x20 under a
  /// hidden ORDER BY key, unlike view-computed columns).
  TableComputed
  SetOperation
  Aggregate
  /// The context column of an xml `nodes()` table: usable only as a method
  /// target or in IS [NOT] NULL (493 otherwise).
  XmlNodes
} derive(Debug, Eq)

///|
/// A bound expression: every node knows its SQL type and nullability. The
/// executor never infers types from values.
pub(all) struct Expr {
  kind : ExprKind
  ty : @types.SqlType
  nullable : Bool
} derive(Debug)

///|
pub(all) enum ExprKind {
  Lit(@types.Value)
  /// Variable slot in the current frame.
  Var(Int)
  /// Column of the current row (after FROM).
  Col(Int)
  /// Column of an enclosing query's row: (levels out, index).
  OuterCol(Int, Int)
  Cast(Expr, try_~ : Bool, style~ : Int?)
  /// `expr COLLATE name`: the collation is in this node's type; the marker
  /// gives the expression explicit collation coercibility.
  Collate(Expr)
  Arith(@types.ArithOp, Expr, Expr)
  Neg(Expr)
  BitNot(Expr)
  BitOp(BitOp, Expr, Expr)
  Concat(Expr, Expr)
  Cmp(CmpOp, Expr, Expr, @types.Collation?)
  And(Expr, Expr)
  Or(Expr, Expr)
  Not(Expr)
  IsNull(Expr, negated~ : Bool)
  Like(
    Expr,
    Expr,
    escape~ : Expr?,
    negated~ : Bool,
    collation~ : @types.Collation?
  )
  InList(Expr, Array[Expr], negated~ : Bool, collation~ : @types.Collation?)
  Case(Array[(Expr, Expr)], Expr?)
  Call(Fn, Array[Expr])
  Global(Global)
  /// Scalar subquery: first column of at most one row (512 if more).
  Subquery(Plan)
  Exists(Plan)
  InQuery(Expr, Plan, negated~ : Bool, collation~ : @types.Collation?)
  /// `x op ALL|ANY (subquery)`; `all` false means ANY/SOME.
  Quantified(CmpOp, Expr, Plan, all~ : Bool, collation~ : @types.Collation?)
  /// Scalar user-defined function call: object id and arguments already
  /// converted to the parameter types. Evaluated by the session through
  /// `@exec.Ctx::user_fn` (the body is procedural; session/udf.mbt).
  UserFn(Int, Array[Expr])
} derive(Debug)

///|
pub(all) enum CmpOp {
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
} derive(Debug, Eq)

///|
pub(all) enum BitOp {
  And
  Or
  Xor
} derive(Debug, Eq)

///|
/// Session globals (@@ROWCOUNT etc.) and niladic session functions.
pub(all) enum Global {
  RowCount
  Error
  TranCount
  Identity
  FetchStatus
  Spid
  Version
  ServerName
  ServiceName
  NestLevel
  Options
  Language
  DateFirst
  TextSize
  MaxPrecision
  DbTs
  ProcId
  CursorRows
  LockTimeout
} derive(Debug, Eq)

///|
/// Resolved built-in functions. Each has a binder rule for its result type
/// (bind/functions.mbt) and an implementation (exec/functions.mbt).
pub(all) enum Fn {
  Len
  DataLength
  Upper
  Lower
  LTrim
  RTrim
  Trim
  Left
  Right
  Substring
  Replace
  Replicate
  Reverse
  CharIndex
  Concat
  ConcatWs
  Space
  Str
  Nchar
  Char
  Ascii
  Unicode
  Abs
  Ceiling
  Floor
  Round
  Sign
  Power
  Sqrt
  IsNull
  NullIf
  Iif
  XactState
  ErrorNumber
  ErrorMessage
  ErrorSeverity
  ErrorState
  ErrorLine
  ErrorProcedure
  ScopeIdentity
  NewId
  GetDate
  SysDateTime
  SysUtcDateTime
  GetUtcDate
  SysDateTimeOffset
  DbName
  SchemaName
  ObjectId
  ObjectName
  JsonValue
  JsonQuery
  IsJson
  /// Functions implemented in the "more functions" files, dispatched by
  /// upper-case name (bind/functions_more.mbt, exec/functions_more.mbt).
  /// Lets function families grow without touching this enum.
  Named(String)
} derive(Debug, Eq)

///|
/// Logical query plan. Rows are `Array[@types.Value]`.
pub(all) enum Plan {
  /// One empty row (SELECT without FROM).
  OneRow
  /// All rows of a table. `scope` 0 = database, 1 = session (temp tables,
  /// table variables). With `rowid`, each row gets a trailing BigInt row id
  /// (UPDATE/DELETE targets).
  Scan(scope~ : Int, id~ : Int, rowid~ : Bool)
  /// Nested-loop join; the output row is left ++ right.
  Join(JoinKind, Plan, Plan, Expr?, left_width~ : Int, right_width~ : Int)
  Values(Array[Array[Expr]])
  Project(Plan, Array[Expr])
  Filter(Plan, Expr)
  /// ORDER BY keys (expression, descending, collation).
  Sort(Plan, Array[SortKey])
  /// TOP / OFFSET-FETCH: offset, count (None = all), with_ties unsupported.
  Limit(Plan, Expr?, Expr?)
  Distinct(Plan, Array[@types.Collation?])
  UnionAll(Array[Plan])
  /// GROUP BY: output rows are keys ++ aggregate values (++ a BigInt
  /// grouping id when `sets` is non-empty). `sets` lists the key positions
  /// active in each grouping set (ROLLUP/CUBE/GROUPING SETS); empty means a
  /// single set of all keys. Without keys and sets: one row, even for empty
  /// input (scalar aggregate).
  Aggregate(Plan, Array[Expr], Array[AggCall], sets~ : Array[Array[Int]])
  /// Window functions: output rows are the input row ++ one value per call.
  Window(Plan, Array[WindowCall])
  /// CROSS/OUTER APPLY: `right` runs once per left row with that row pushed
  /// as the innermost outer row.
  Apply(Plan, Plan, outer~ : Bool, right_width~ : Int)
  /// UNION (distinct), EXCEPT, INTERSECT (distinct semantics).
  SetOp(SetOpKind, Plan, Plan, Array[@types.Collation?])
  /// TOP n [PERCENT] [WITH TIES]; `ties` are the ORDER BY keys evaluated on
  /// the input rows (empty without WITH TIES).
  Top(Plan, Expr, percent~ : Bool, ties~ : Array[SortKey])
  /// Recursive CTE: anchor rows, then `recursive` repeatedly with work table
  /// `id` bound to the previous level's rows. `max` recursion levels
  /// (0 = unlimited) before error 530.
  Recursive(id~ : Int, Plan, Plan, max~ : Int)
  /// Rows of a recursive CTE's current work table.
  WorkTable(Int)
  /// Table-valued function rows (OPENJSON, STRING_SPLIT).
  TableFunc(TableFn, Array[Expr])
  /// Inline table-valued function: the arguments are evaluated in the
  /// caller's context and become the variable slots of the function's
  /// query, which runs without the caller's rows or variables.
  WithParams(Array[Expr], Plan)
  /// Multi-statement table-valued function: object id and arguments; the
  /// session runs the body and returns the table variable's rows
  /// (`@exec.Ctx::user_table`).
  UserTable(Int, Array[Expr])
  /// FOR JSON PATH/AUTO: formats the input rows (described by `columns`)
  /// as one JSON text, returned in rows of 2033 characters.
  ForJson(
    Plan,
    Array[ResultColumn],
    root~ : String?,
    include_nulls~ : Bool,
    without_array_wrapper~ : Bool,
    shape~ : JsonShape
  )
  /// Runs the input without raising warning 8153 for NULLs its aggregates
  /// eliminate (PIVOT's aggregates; captured: analytic/pivot).
  NoNullWarning(Plan)
  /// UNPIVOT: per input row and per `columns` entry (in order) whose value
  /// is not NULL, one row `keep` values ++ [value, names[i]].
  Unpivot(
    Plan,
    keep~ : Array[Int],
    columns~ : Array[Int],
    names~ : Array[String]
  )
  /// FOR XML RAW/AUTO/PATH: formats the input rows (described by
  /// `columns`) as XML. `chunked`: the top-level text form, rows of 2033
  /// characters (none for empty text); otherwise one row with the whole
  /// value (nvarchar(max) text, or xml with TYPE), none for no input rows.
  ForXml(Plan, Array[ResultColumn], ForXmlSpec, chunked~ : Bool)
  /// The first column of every input row concatenated into one row (no
  /// rows for no input): FOR JSON in a subquery.
  Concat(Plan)
} derive(Debug)

///|
pub(all) enum XmlMode {
  XmlRaw
  XmlAuto
  XmlPath
} derive(Debug, Eq)

///|
/// How FOR JSON lays out its columns (resolved by the binder): `raw` marks
/// columns whose text is JSON (embedded as is); `levels` is FOR JSON AUTO's
/// nesting level per column (empty for PATH, which nests by dotted names)
/// and `names` the name of each level (used for the arrays below the first).
pub(all) struct JsonShape {
  raw : Array[Bool]
  levels : Array[Int]
  /// AUTO: whether the column is a source column (expressions do not take
  /// part in grouping a level's rows)
  keys : Array[Bool]
  names : Array[String]
} derive(Debug)

///|
/// FOR XML options, resolved by the binder.
pub(all) struct ForXmlSpec {
  mode : XmlMode
  /// row element name; "" omits it (PATH('') / RAW(''))
  row : String
  root : String?
  elements : Bool
  xsinil : Bool
  /// TYPE: the result is an xml value
  type_ : Bool
  /// the statement's result (DONE counts the input rows; TYPE over no rows
  /// is one NULL row) rather than a subquery
  top_level : Bool
  /// AUTO: element name of each table level, and the level of each input
  /// column
  auto_names : Array[String]
  auto_levels : Array[Int]
} derive(Debug)

///|
pub(all) enum SetOpKind {
  Union
  Except
  Intersect
} derive(Debug, Eq)

///|
pub(all) enum AggFn {
  Count
  CountBig
  Sum
  Avg
  Min
  Max
  StringAgg
  Stdev
  StdevP
  Var
  VarP
  /// GROUPING(key): 1 when the key is aggregated away in this grouping set.
  Grouping(Int)
  /// GROUPING_ID(keys...)
  GroupingId(Array[Int])
  /// CHECKSUM_AGG: XOR of the int values.
  ChecksumAgg
  /// APPROX_COUNT_DISTINCT (bigint; exact for small cardinalities).
  ApproxCountDistinct
  /// JSON_ARRAYAGG: `absent` skips NULLs; `raw` embeds the argument's JSON
  /// text as is.
  JsonArrayAgg(absent~ : Bool, raw~ : Bool)
  /// JSON_OBJECTAGG: the key is the call's `separator`, the value its `arg`.
  JsonObjectAgg(absent~ : Bool, raw~ : Bool)
} derive(Debug, Eq)

///|
/// An aggregate call: `arg` is None for COUNT(*); `separator` is
/// STRING_AGG's (JSON_OBJECTAGG's key); `order` its WITHIN GROUP keys. `ty`
/// is the result type.
pub(all) struct AggCall {
  func : AggFn
  arg : Expr?
  separator : Expr?
  distinct : Bool
  order : Array[SortKey]
  ty : @types.SqlType
} derive(Debug)

///|
pub(all) enum WinFn {
  RowNumber
  Rank
  DenseRank
  Ntile
  Lag
  Lead
  FirstValue
  LastValue
  PercentRank
  CumeDist
  Agg(AggFn, distinct~ : Bool)
  /// PERCENTILE_CONT / PERCENTILE_DISC: args = [percentile]; the WITHIN
  /// GROUP key is the call's `order`, which then does not order the window.
  PercentileCont
  PercentileDisc
  /// NEXT VALUE FOR seq OVER (ORDER BY ...): args = [the bound NEXT VALUE
  /// FOR call], evaluated once per row in the window's order
  NextValue
} derive(Debug, Eq)

///|
pub(all) enum FrameBound {
  UnboundedPreceding
  Preceding(Expr)
  CurrentRow
  Following(Expr)
  UnboundedFollowing
} derive(Debug)

///|
pub(all) struct WindowFrame {
  rows : Bool
  start : FrameBound
  end : FrameBound
} derive(Debug)

///|
pub(all) struct WindowCall {
  func : WinFn
  args : Array[Expr]
  partition : Array[Expr]
  partition_collations : Array[@types.Collation?]
  order : Array[SortKey]
  frame : WindowFrame?
  ty : @types.SqlType
  /// IGNORE NULLS (LAG, LEAD, FIRST_VALUE, LAST_VALUE)
  ignore_nulls : Bool
} derive(Debug)

///|
pub(all) enum TableFn {
  /// OPENJSON default schema (key, value, type); args: json [, path].
  OpenJsonDefault
  /// OPENJSON WITH schema; args: json [, path].
  OpenJsonWith(Array[OpenJsonColumn])
  /// STRING_SPLIT; args: string, separator; `ordinal` adds the column.
  StringSplit(ordinal~ : Bool)
  /// GENERATE_SERIES; args: start, stop, step (all of the `value` type).
  GenerateSeries(@types.SqlType)
  /// xml `nodes()`; args: the xml value, the XQuery text, sql:variable /
  /// sql:column values. One xml context reference per result node.
  XmlNodes
} derive(Debug)

///|
pub(all) struct OpenJsonColumn {
  path : String
  as_json : Bool
  ty : @types.SqlType
} derive(Debug)

///|
pub(all) enum JoinKind {
  Inner
  Left
  Right
  Full
  Cross
} derive(Debug, Eq)

///|
pub(all) struct SortKey {
  expr : Expr
  desc : Bool
  collation : @types.Collation?
} derive(Debug)

///|
/// A result column description: name plus type, nullability and origin.
pub(all) struct ResultColumn {
  name : String
  ty : @types.SqlType
  nullable : Bool
  origin : Origin
} derive(Debug)

///|
pub fn Expr::lit(v : @types.Value, ty : @types.SqlType) -> Expr {
  { kind: Lit(v), ty, nullable: v is Null, }
}

///|
/// Function name for messages.
pub fn debug_fn(f : Fn) -> String {
  match f {
    Abs => "ABS"
    Ceiling => "CEILING"
    Floor => "FLOOR"
    Round => "ROUND"
    Sign => "SIGN"
    Power => "POWER"
    Sqrt => "SQRT"
    _ => "function"
  }
}
