///|
/// Binder hook for function families beyond functions.mbt. Return None for
/// unknown names (error 195). Bind each family as
/// `mk(Call(Named("NAME"), args), result_type, nullable)` and implement it in
/// exec/functions_more.mbt under the same name.
fn bind_call_more(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  ignore(env)
  ignore(name)
  ignore(call)
  None
}
