///|
/// How a result column was produced; decides the COLMETADATA flags word.
/// Captured (traps/metadata-not-from-values): base table columns 0x08|null,
/// computed expressions 0x20|null, UNION outputs 0, aggregates 0x01 only.
pub(all) enum Origin {
  BaseColumn(identity~ : Bool)
  Computed
  SetOperation
  Aggregate
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
