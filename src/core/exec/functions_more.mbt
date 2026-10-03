///|
/// Executor hook for `Fn::Named` functions (see bind/functions_more.mbt).
/// `v` holds the evaluated arguments, `args` their bound expressions (types),
/// `e` the call itself (result type).
fn call_more(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  if call_date(name, v, args, e) is Some(r) {
    return r
  }
  if call_string(name, v, args, e) is Some(r) {
    return r
  }
  if call_math(ctx, name, v, args, e) is Some(r) {
    return r
  }
  if name == "AT TIME ZONE" {
    return at_time_zone(v, args, e)
  }
  if call_misc(name, v, args, e) is Some(r) {
    return r
  }
  raise @types.not_supported("function \{name}")
}
