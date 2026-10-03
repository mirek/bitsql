///|
/// Binder hook for catalog/metadata functions (OBJECT_ID, COL_LENGTH, ...).
/// Bind as `Call(Named("NAME"), args)`; the session evaluates them through
/// `Ctx::ext` because they need the database (exec cannot see it).
fn bind_call_catalog(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  ignore(env)
  ignore(call)
  if name == "" {
    raise err(
      195,
      "'' is not a recognized built-in function name.",
      state=10,
      severity=15,
    )
  }
  None
}
