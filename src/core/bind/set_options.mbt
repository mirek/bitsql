// SET options whose non-default values change expression semantics that
// bitsql does not model: expressions they would affect raise Emulator
// errors instead of silently computing the default behaviour (probed:
// tail/settings-options). CONCAT_NULL_YIELDS_NULL OFF makes `'a' + NULL`
// 'a'; NUMERIC_ROUNDABORT ON turns any loss of decimal precision into
// 8115 state 7; XML methods (like DML on filtered or computed-column
// indexes) need ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT,
// CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON and NUMERIC_ROUNDABORT
// OFF, else error 1934 ends the batch.

///|
fn check_bind_options(env : Env, x : @ir.Expr) -> Unit raise @types.SqlError {
  let o = env.options
  if o.concat_null_yields_null && !o.numeric_roundabort {
    return
  }
  if !o.concat_null_yields_null &&
    x.kind is Arith(Add, _, _) &&
    x.ty.family() is FString {
    raise @types.not_supported(
      "string concatenation under SET CONCAT_NULL_YIELDS_NULL OFF",
    )
  }
  if o.numeric_roundabort && rounding_type(x.ty) {
    raise @types.not_supported(
      "decimal, money or float values under SET NUMERIC_ROUNDABORT ON",
    )
  }
}

///|
/// Types whose values may lose decimal precision in conversions or
/// arithmetic (NUMERIC_ROUNDABORT).
pub fn rounding_type(t : @types.SqlType) -> Bool {
  t is (Decimal(_, _) | Numeric(_, _) | Money | SmallMoney | Float | Real)
}

///|
/// XML data type methods need the index SET options (1934 otherwise).
fn check_xml_options(env : Env) -> Unit raise @types.SqlError {
  if !env.options.wrong_for_indexes.is_empty() {
    raise @types.not_supported(
      "XML data type methods with SET " +
      env.options.wrong_for_indexes.join(", ") +
      " at a non-default value (SQL Server error 1934)",
    )
  }
}
