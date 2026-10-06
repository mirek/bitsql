// Shared helpers for the built-in function binders (fn_*.mbt). Result types,
// lengths and nullability follow captures in harness/corpus/functions and
// msduck imports; see the t-sql skill findings for the rules.

///|
/// Builds a `Fn::Named` call.
fn named(
  name : String,
  args : Array[@ir.Expr],
  ty : @types.SqlType,
  nullable? : Bool = true,
) -> @ir.Expr {
  mk(Call(Named(name), args), ty, nullable)
}

///|
/// Error 8116: argument type not accepted (compile time, state 1 unless
/// captured otherwise).
fn bad_arg_type(
  t : @types.SqlType,
  index : Int,
  fname : String,
  state? : Int = 1,
) -> @types.SqlError {
  err(
    8116,
    "Argument data type \{t.base_name()} is invalid for argument \{index} of \{fname} function.",
    state~,
  )
}

///|
/// Error 8116 for a bare NULL literal argument.
fn null_arg(index : Int, fname : String, state? : Int = 1) -> @types.SqlError {
  err(
    8116,
    "Argument data type NULL is invalid for argument \{index} of \{fname} function.",
    state~,
  )
}

///|
/// A bare `NULL` literal (typed int by the binder, but SQL Server treats it
/// as typeless in function arguments).
fn is_null_lit(e : @ir.Expr) -> Bool {
  e.kind is Lit(Null) && e.ty is Int
}

///|
/// A literal (or negated literal) that is not NULL.
fn is_literal(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(v) => !(v is Null)
    Neg(inner) => is_literal(inner)
    _ => false
  }
}

///|
/// Compile-time value of a constant expression (literals, unary minus,
/// arithmetic and casts over constants). SQL Server folds such arguments
/// when deriving result lengths (captured: REPLICATE('x', 1+2) is
/// varchar(3)). Folding errors leave the expression non-constant.
fn fold(e : @ir.Expr) -> @types.Value? {
  match e.kind {
    Lit(v) => Some(v)
    Neg(inner) =>
      match fold(inner) {
        Some(v) =>
          try @types.negate(v, inner.ty) catch {
            _ => None
          } noraise {
            x => Some(x)
          }
        None => None
      }
    Cast(inner, try_~, style~) =>
      match fold(inner) {
        Some(v) =>
          try {
            if try_ {
              @types.try_cast(v, inner.ty, e.ty, style?)
            } else {
              @types.cast(v, inner.ty, e.ty, style?)
            }
          } catch {
            _ => None
          } noraise {
            x => Some(x)
          }
        None => None
      }
    Arith(op, a, b) =>
      match (fold(a), fold(b)) {
        (Some(x), Some(y)) =>
          try @types.arith(op, x, a.ty, y, b.ty) catch {
            _ => None
          } noraise {
            v => Some(v)
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Integer value of a constant integer-typed expression.
fn fold_int(e : @ir.Expr) -> Int64? {
  // integer types, and whole-number literals typed numeric(p, 0)
  // (captured: SPACE(-2147483648) is varchar(1), SPACE(2.9) varchar(8000))
  let whole = match e.ty {
    Decimal(_, 0) | Numeric(_, 0) => true
    t => t.family() == FInteger
  }
  if !whole {
    return None
  }
  match fold(e) {
    Some(Decimal(d)) =>
      if d.digits() <= 18 {
        Some(d.trunc_to_bigint().to_int64())
      } else {
        None
      }
    Some(v) => v.as_int64()
    None => None
  }
}

///|
/// Length (characters, or bytes for binary) of a value of type `t` once
/// implicitly converted to a character string. Captured with UPPER(x) on
/// every type: bit 1, tinyint 4, smallint 6, int 12, bigint 24,
/// decimal/numeric 41, money 40, float/real 23, date/time types and
/// uniqueidentifier 40. None = max.
fn string_len(t : @types.SqlType) -> Int? {
  match t {
    Char(n, _) | NChar(n, _) | Binary(n) => Some(n)
    VarChar(n, _) | NVarChar(n, _) | VarBinary(n) => n
    Bit => Some(1)
    TinyInt => Some(4)
    SmallInt => Some(6)
    Int => Some(12)
    BigInt => Some(24)
    Decimal(_, _) | Numeric(_, _) => Some(41)
    Money | SmallMoney => Some(40)
    Float | Real => Some(23)
    RowVersion => Some(8)
    Date
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_)
    | DateTime
    | SmallDateTime
    | UniqueIdentifier => Some(40)
    // variant and xml arguments are rejected before (fn_variant.mbt guard)
    Variant | Xml | Json | Vector(_, _) => None
    // LOB arguments count as max (captured: CONCAT_WS('', text) is
    // varchar(max)); functions that reject them check first (lob_args)
    Text(_) | NText(_) | Image => None
  }
}

///|
/// Length of an argument converted to a string; a bare NULL counts as 1.
fn arg_len(e : @ir.Expr) -> Int? {
  if is_null_lit(e) {
    Some(1)
  } else {
    string_len(e.ty)
  }
}

///|
/// The variable-length character type an argument becomes in a string
/// function: char → varchar, nchar → nvarchar, anything else → varchar of
/// `string_len` (binary is reinterpreted as code page 1252 text).
fn string_arg_type(e : @ir.Expr, env : Env) -> @types.SqlType {
  match e.ty {
    NChar(n, c) => NVarChar(Some(n), c)
    NVarChar(n, c) => NVarChar(n, c)
    Char(n, c) => VarChar(Some(n), c)
    VarChar(n, c) => VarChar(n, c)
    NText(c) => NVarChar(None, c)
    Text(c) => VarChar(None, c)
    _ => VarChar(arg_len(e), env.collation)
  }
}

///|
/// A character type of the same family as `t` with `n` characters, capped
/// at 8000 bytes (4000 Unicode characters) and becoming max when unknown or
/// larger.
fn sized_like(t : @types.SqlType, n : Int?) -> @types.SqlType {
  let unicode = t.is_unicode()
  let cap = if unicode { 4000 } else { 8000 }
  let c = t.collation().unwrap_or(@types.default_collation)
  let len = match n {
    Some(x) if x > cap => Some(cap)
    other => other
  }
  if unicode {
    NVarChar(len, c)
  } else {
    VarChar(len, c)
  }
}

///|
/// Whether a character type is max.
fn is_max_string(t : @types.SqlType) -> Bool {
  t is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None))
}

///|
/// Converts a bound argument to a string type for evaluation (binary values
/// keep their bytes; the executor decodes them as code page 1252).
fn as_string_arg(e : @ir.Expr, env : Env) -> @ir.Expr {
  if e.ty.family() == FString || e.ty.family() == FBinary || is_null_lit(e) {
    e
  } else {
    let t = string_arg_type(e, env)
    { kind: Cast(e, try_=false, style=None), ty: t, nullable: e.nullable, }
  }
}

///|
/// Implicit conversion to int for integer-valued arguments (positions,
/// lengths, counts); a bare NULL stays as is.
fn as_int_arg(e : @ir.Expr) -> @ir.Expr raise @types.SqlError {
  // numbers stay as they are: the executor truncates them and reports an
  // int overflow as 8115 state 2 (captured: RIGHT('abcdef', 2147483648))
  // binary converts too (captured: NCHAR(0x00AD) is U+00AD, CHAR(0x41) 'A')
  if is_null_lit(e) || !(e.ty.family() is (FString | FBinary)) {
    e
  } else {
    coerce(e, Int)
  }
}

///|
/// Integer-family argument check used by functions that reject text (e.g.
/// STUFF positions: 8116 for varchar).
fn require_numeric(
  e : @ir.Expr,
  index : Int,
  fname : String,
) -> Unit raise @types.SqlError {
  if is_null_lit(e) {
    return
  }
  match e.ty.family() {
    FBit | FInteger | FDecimal | FMoney | FFloat => ()
    _ => raise bad_arg_type(e.ty, index, fname)
  }
}

///|
/// Argument count error 174 ("requires N argument(s)").
fn arity_n(
  name : String,
  args : Array[@ast.Expr],
  n : Int,
) -> Unit raise @types.SqlError {
  if args.length() != n {
    raise err(
      174,
      "The \{name.to_lower()} function requires \{n} argument(s).",
      severity=15,
    )
  }
}

///|
/// Argument count error 189 ("requires lo to hi arguments").
fn arity_189(
  name : String,
  args : Array[@ast.Expr],
  lo : Int,
  hi : Int,
) -> Unit raise @types.SqlError {
  if args.length() < lo || args.length() > hi {
    raise err(
      189,
      "The \{name.to_lower()} function requires \{lo} to \{hi} arguments.",
      severity=15,
    )
  }
}

///|
/// Resolves the collation of a string function's operands (SQL Server
/// collation precedence, 468 on conflict; see collation.mbt) and retypes the
/// string operands with it so the executor compares under one collation.
fn collate_args(
  env : Env,
  op : String,
  bs : Array[@ir.Expr],
) -> (Array[@ir.Expr], @types.Collation?) raise @types.SqlError {
  match resolve_collation(env, op, bs) {
    Some(c) =>
      (
        bs.map(x => {
          if x.ty.family() == FString {
            { ..x, ty: with_collation(x.ty, c), }
          } else {
            x
          }
        }),
        Some(c),
      )
    None => (bs, None)
  }
}
