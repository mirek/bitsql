///|
/// Model lookup precedes argument type checks. The native JSON result is
/// exposed as UTF-8 varchar by TDS, but retains type 244 in SELECT INTO.
fn bind_embedding(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.Expr raise @types.SqlError {
  guard call.args[0].kind is StrLit(model, ..) else {
    raise @types.not_supported("embedding model expression")
  }
  if !(env.catalog.external_model)(model) {
    raise err(
      15151,
      "Cannot find the external model '\{model}', because it does not exist or you do not have permission.",
      state=10,
    )
  }
  let args = call.args.map(a => bind_expr(env, a))
  if is_untyped_null(args[1]) {
    raise null_arg(2, "ai_generate_embeddings")
  }
  if !(args[1].ty is (Char(_, _) | NChar(_, _) | VarChar(_, _) | NVarChar(_, _))) {
    if args[1].ty is VarBinary(None) {
      raise err(
        8116, "Argument data type varbinary(max) is invalid for argument 2 of ai_generate_embeddings function.",
      )
    }
    raise bad_arg_type(args[1].ty, 2, "ai_generate_embeddings")
  }
  if args.length() > 2 && !(args[2].ty is Json) && !is_untyped_null(args[2]) {
    raise bad_arg_type(args[2].ty, 3, "ai_generate_embeddings")
  }
  named("AI_GENERATE_EMBEDDINGS", args, Json)
}
