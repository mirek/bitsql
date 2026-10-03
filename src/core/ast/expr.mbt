///|
/// An identifier as written: `quoted` is true for `[x]`, `"x"` and string
/// aliases (`SELECT 1 AS 'x'`); `name` is the unescaped text.
pub(all) struct Ident {
  name : String
  quoted : Bool
  span : Span
} derive(Eq, Debug)

///|
/// Multi-part object name `server.db.schema.object`; an omitted middle part
/// (`db..t`) is an empty, unquoted `Ident`.
pub(all) struct ObjectName {
  parts : Array[Ident]
  span : Span
} derive(Eq, Debug)

///|
/// Last part of the name (the object itself).
pub fn ObjectName::base(self : ObjectName) -> String {
  self.parts[self.parts.length() - 1].name
}

///|
/// Syntactic type argument: a number kept as raw text, or `max`.
pub(all) enum TypeArg {
  Num(String)
  Max
} derive(Eq, Debug)

///|
/// Syntactic type name, unresolved: `nvarchar(max)`, `decimal(10, 2)`,
/// `dbo.MyType`. `name` keeps the source spelling (`DOUBLE PRECISION` is
/// normalised to `float` by the binder, not here).
pub(all) struct TypeName {
  schema : Ident?
  name : String
  args : Array[TypeArg]
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum UnaryOp {
  Neg
  Plus
  BitNot
} derive(Eq, Debug)

///|
/// Arithmetic / string / bitwise operators.
pub(all) enum BinOp {
  Add
  Sub
  Mul
  Div
  Mod
  BitAnd
  BitOr
  BitXor
} derive(Eq, Debug)

///|
/// Comparison operators; `NotLt`/`NotGt` are `!<` / `!>`.
pub(all) enum CmpOp {
  Eq
  Ne
  Lt
  Le
  Gt
  Ge
  NotLt
  NotGt
} derive(Eq, Debug)

///|
/// `= += -= *= /= %= &= |= ^=` in SET / SELECT @v / UPDATE SET.
pub(all) enum AssignOp {
  Assign
  AddAssign
  SubAssign
  MulAssign
  DivAssign
  ModAssign
  AndAssign
  OrAssign
  XorAssign
} derive(Eq, Debug)

///|
pub(all) enum Quantifier {
  All
  Any
  Some_
} derive(Eq, Debug)

///|
pub(all) struct Expr {
  kind : ExprKind
  span : Span
} derive(Eq, Debug)

///|
/// Expressions and search conditions share one type; the parser only builds
/// comparisons, predicates, NOT/AND/OR in condition positions (and inside
/// parentheses). Literal numbers keep their raw text.
pub(all) enum ExprKind {
  Null
  /// `DEFAULT` as a VALUES item, EXEC argument or function argument.
  Default
  IntLit(String)
  DecimalLit(String)
  FloatLit(String)
  MoneyLit(String)
  StrLit(String, national~ : Bool)
  BinaryLit(String)
  /// `@x`
  Var(String)
  /// `@@ROWCOUNT` etc.
  GlobalVar(String)
  /// `a`, `t.a`, `s.t.a`, `$action`, `$identity`
  Column(Array[Ident])
  Unary(UnaryOp, Expr)
  Binary(BinOp, Expr, Expr)
  Compare(CmpOp, Expr, Expr)
  /// `x > ALL (SELECT ...)`
  Quantified(CmpOp, Quantifier, Expr, Query)
  Not(Expr)
  And(Expr, Expr)
  Or(Expr, Expr)
  IsNull(Expr, negated~ : Bool)
  Like(Expr, Expr, escape~ : Expr?, negated~ : Bool)
  Between(Expr, Expr, Expr, negated~ : Bool)
  InList(Expr, Array[Expr], negated~ : Bool)
  InQuery(Expr, Query, negated~ : Bool)
  Exists(Query)
  Subquery(Query)
  Case(operand~ : Expr?, whens~ : Array[(Expr, Expr)], else_~ : Expr?)
  Cast(Expr, TypeName, try_~ : Bool)
  Convert(TypeName, Expr, style~ : Expr?, try_~ : Bool)
  /// `PARSE(x AS type [USING culture])`, `TRY_PARSE(...)`
  Parse(Expr, TypeName, culture~ : Expr?, try_~ : Bool)
  Call(FuncCall)
  Collate(Expr, Ident)
  AtTimeZone(Expr, Expr)
  NextValueFor(ObjectName)
  /// `(expr)` kept so the binder can see explicit grouping.
  Paren(Expr)
} derive(Eq, Debug)

///|
/// Function call. `niladic` marks parenless forms (`CURRENT_TIMESTAMP`,
/// `SYSTEM_USER`); `star` is `COUNT(*)`.
pub(all) struct FuncCall {
  name : ObjectName
  args : Array[Expr]
  distinct : Bool
  star : Bool
  niladic : Bool
  within_group : Array[OrderItem]
  over : Over?
} derive(Eq, Debug)

///|
pub(all) struct OrderItem {
  expr : Expr
  desc : Bool
  span : Span
} derive(Eq, Debug)

///|
pub(all) struct Over {
  partition_by : Array[Expr]
  order_by : Array[OrderItem]
  frame : Frame?
  span : Span
} derive(Eq, Debug)

///|
pub(all) enum FrameUnit {
  Rows
  Range
} derive(Eq, Debug)

///|
pub(all) enum FrameBound {
  UnboundedPreceding
  UnboundedFollowing
  CurrentRow
  Preceding(Expr)
  Following(Expr)
} derive(Eq, Debug)

///|
/// `ROWS start` or `ROWS BETWEEN start AND end`.
pub(all) struct Frame {
  unit : FrameUnit
  start : FrameBound
  end : FrameBound?
} derive(Eq, Debug)
