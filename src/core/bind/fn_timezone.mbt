// `expr AT TIME ZONE zone`: bound as the named call "AT TIME ZONE"
// (evaluated in exec/fn_timezone.mbt). Captures: msduck at-time-zone*,
// harness/corpus/timezone/.

///|
/// Argument 1 must be datetime, smalldatetime, datetime2 or datetimeoffset
/// (or a bare NULL); argument 2 a character string (or a bare NULL). Anything
/// else is 8116 at compile time. The result is datetimeoffset with the
/// input's fractional scale (datetime 3, smalldatetime 0, NULL 7), always
/// nullable.
fn bind_at_time_zone(
  env : Env,
  x : @ast.Expr,
  z : @ast.Expr,
) -> @ir.Expr raise @types.SqlError {
  let fname = "AT TIME ZONE"
  let a = bind_expr(env, x)
  let scale = if is_null_lit(a) {
    7
  } else {
    match a.ty {
      DateTime2(s) | DateTimeOffset(s) => s
      DateTime => 3
      SmallDateTime => 0
      t => raise bad_arg_type(t, 1, fname)
    }
  }
  let b = bind_expr(env, z)
  if !is_null_lit(b) && b.ty.family() != FString {
    raise bad_arg_type(b.ty, 2, fname)
  }
  named(fname, [a, b], DateTimeOffset(scale))
}
