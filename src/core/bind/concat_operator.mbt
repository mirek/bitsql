///|
/// SQL Server 2025 || differs from both string + and CONCAT: null propagates,
/// at least one non-null operand must be a string/binary, mixed binary/string
/// is rejected, and metadata follows declared capacities. Corpus sql2025/concat*.
fn bind_concat_operator(
  env : Env,
  left : @ir.Expr,
  right : @ir.Expr,
) -> @ir.Expr raise @types.SqlError {
  if is_untyped_null(left) && is_untyped_null(right) {
    return mk(Lit(Null), Int, true)
  }
  let a = left.ty
  let b = right.ty
  if a is Vector(_, _) || b is Vector(_, _) {
    if (a is Vector(_, _) && b is Vector(_, _)) ||
      a.family() == FString ||
      b.family() == FString {
      raise err(
        8117, "Operand data type vector is invalid for concat operator.",
      )
    }
    raise @types.not_supported("vector concatenation with other types")
  }
  let null_a = is_untyped_null(left)
  let null_b = is_untyped_null(right)
  let binary_a = a.family() == FBinary
  let binary_b = b.family() == FBinary
  if a.is_lob() ||
    b.is_lob() ||
    a is (Xml | Json | Variant | Bit) ||
    b is (Xml | Json | Variant | Bit) ||
    (binary_a && !binary_b && !null_b) ||
    (binary_b && !binary_a && !null_a) ||
    (!binary_a && !binary_b && a.family() != FString && b.family() != FString) {
    let an = if null_a { "NULL" } else { a.clash_name() }
    let bn = if null_b { "NULL" } else { b.clash_name() }
    raise err(
      402,
      "The data types \{an} and \{bn} are incompatible in the concat operator.",
    )
  }
  let unicode = a.is_unicode() || b.is_unicode()
  let len = match (arg_len(left), arg_len(right)) {
    (Some(x), Some(y)) =>
      Some(@cmp.minimum(x + y, if unicode { 4000 } else { 8000 }))
    _ => None
  }
  let nullable = left.nullable ||
    right.nullable ||
    (!binary_a && a.family() != FString) ||
    (!binary_b && b.family() != FString)
  if binary_a || binary_b {
    let ty : @types.SqlType = if a is Binary(_) && b is Binary(_) {
      Binary(len.unwrap_or(8000))
    } else {
      VarBinary(len)
    }
    return named("CONCAT_OPERATOR", [left, right], ty, nullable~)
  }
  let coll = concat_operator_collation(env, left, right, unicode)
  let ty : @types.SqlType = if unicode {
    NVarChar(len, coll)
  } else {
    VarChar(len, coll)
  }
  let convert = (e : @ir.Expr) => {
    let t : @types.SqlType = if unicode {
      NVarChar(arg_len(e), coll)
    } else {
      VarChar(arg_len(e), coll)
    }
    if e.ty.family() == FString || is_untyped_null(e) {
      e
    } else {
      coerce(e, t)
    }
  }
  named("CONCAT_OPERATOR", [convert(left), convert(right)], ty, nullable~)
}
