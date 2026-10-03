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
  ignore(ctx)
  ignore(v)
  ignore(args)
  ignore(e)
  raise @types.not_supported("function \{name}")
}
