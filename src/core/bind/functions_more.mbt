///|
/// Binder hook for function families beyond functions.mbt. Return None for
/// unknown names (error 195). Each family binds
/// `mk(Call(Named("NAME"), args), result_type, nullable)` and is implemented
/// in exec/functions_more.mbt under the same name.
fn bind_call_more(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  if bind_vector_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_regex_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_fuzzy_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_base64_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_date_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_string_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_date_bucket(env, name, call) is Some(e) {
    return Some(e)
  }
  if bind_math_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  bind_analytic_fn(name, call)
  if bind_json2_fn(env, name, call) is Some(e) {
    return Some(e)
  }
  bind_misc_fn(env, name, call)
}
