///|
fn bind_vector_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  if name == "VECTOR_DISTANCE" {
    arity_189(name, call.args, 3, 4)
    if call.args.length() != 3 {
      raise err(
        174,
        "The vector_distance function requires 3 argument(s).",
        state=6,
        severity=15,
      )
    }
    let args : Array[@ir.Expr] = []
    for i in 0..<3 {
      let mut arg = bind_expr(env, call.args[i])
      if call.args[i].kind is Null {
        arg = @ir.Expr::lit(
          Null,
          if i == 0 {
            VarChar(Some(1), env.collation)
          } else {
            Vector(1)
          },
        )
      }
      let valid = if i == 0 {
        arg.ty is (Char(_, _) | NChar(_, _) | VarChar(_, _) | NVarChar(_, _))
      } else {
        arg.ty is Vector(_)
      }
      if !valid {
        raise bad_arg_type(arg.ty, i + 1, "vector_distance")
      }
      args.push(arg)
    }
    return Some(named(name, args, Float))
  }
  if !(name is ("VECTOR_NORM" | "VECTOR_NORMALIZE" | "VECTORPROPERTY")) {
    return None
  }
  arity_n(name, call.args, 2)
  let mut source = bind_expr(env, call.args[0])
  let bare = call.args[0].kind is Null
  if bare && name == "VECTORPROPERTY" {
    raise bad_arg_type(VarBinary(Some(1)), 1, "vectorproperty", state=36)
  }
  if bare {
    source = @ir.Expr::lit(Null, Vector(1))
  }
  if !(source.ty is Vector(_)) {
    raise bad_arg_type(source.ty, 1, name.to_lower())
  }
  let mut option = bind_expr(env, call.args[1])
  if call.args[1].kind is Null {
    option = coerce(option, VarChar(Some(1), env.collation))
  }
  if !(option.ty is (Char(_, _) | NChar(_, _) | VarChar(_, _) | NVarChar(_, _))) {
    raise bad_arg_type(option.ty, 2, name.to_lower())
  }
  let ty : @types.SqlType = match name {
    "VECTORPROPERTY" => Variant
    "VECTOR_NORMALIZE" => source.ty
    _ => Float
  }
  Some(named(name, [source, option], ty))
}

///|
fn vector_not_comparable() -> @types.SqlError {
  err(
    42213, "The vector data types cannot be compared or sorted, except when using the IS NULL operator.",
  )
}
