///|
/// SQL Server 2025 preview fuzzy functions. Oracle: corpus/sql2025/fuzzy-*.
fn bind_fuzzy_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  if !(name
    is ("EDIT_DISTANCE"
    | "EDIT_DISTANCE_SIMILARITY"
    | "JARO_WINKLER_DISTANCE"
    | "JARO_WINKLER_SIMILARITY")) {
    return None
  }
  if !(env.catalog.preview_features)() {
    raise err(
      195,
      "'\{call.name.base()}' is not a recognized built-in function name.",
      state=10,
      severity=15,
    )
  }
  if name == "EDIT_DISTANCE" {
    arity_189(name, call.args, 2, 3)
  } else {
    arity_n(name, call.args, 2)
  }
  let args : Array[@ir.Expr] = []
  for j in 0..<2 {
    let x = bind_expr(env, call.args[j])
    match x.ty {
      VarChar(None, _) | NVarChar(None, _) =>
        raise err(
          8116,
          "Argument data type VARCHAR(MAX)/NVARCHAR(MAX) is invalid for argument \{j + 1} of \{name.to_lower()} function.",
          state=10,
        )
      Char(_, _) | NChar(_, _) | VarChar(Some(_), _) | NVarChar(Some(_), _) =>
        ()
      _ =>
        if !(call.args[j].kind is Null) {
          raise bad_arg_type(x.ty, j + 1, name.to_lower())
        }
    }
    args.push(x)
  }
  if !(call.args[0].kind is Null) && !(call.args[1].kind is Null) {
    let first_unicode = args[0].ty is (NChar(_, _) | NVarChar(_, _))
    let second_unicode = args[1].ty is (NChar(_, _) | NVarChar(_, _))
    if first_unicode != second_unicode {
      raise bad_arg_type(args[1].ty, 2, name.to_lower())
    }
  }
  let (args, _) = collate_args(env, name.to_lower(), args)
  if call.args.length() == 3 {
    let limit = bind_expr(env, call.args[2])
    if !(limit.ty is (TinyInt | SmallInt | Int | BigInt)) && !is_null_lit(limit) {
      raise bad_arg_type(limit.ty, 3, name.to_lower())
    }
    args.push(coerce(limit, Int))
  }
  let ty : @types.SqlType = if name == "JARO_WINKLER_DISTANCE" {
    Float
  } else {
    Int
  }
  Some(named(name, args, ty))
}
