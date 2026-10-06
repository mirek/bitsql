///|
/// SQL Server 2025 Base64 functions; corpus sql2025/base64.sql.
fn bind_base64_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  if !(name is ("BASE64_ENCODE" | "BASE64_DECODE")) {
    return None
  }
  let encode = name == "BASE64_ENCODE"
  if encode {
    arity_189(name, call.args, 1, 2)
  } else {
    arity_n(name, call.args, 1)
  }
  let x = bind_expr(env, call.args[0])
  let valid = if encode {
    x.ty is (Binary(_) | VarBinary(_))
  } else {
    x.ty is (Char(_, _) | VarChar(_, _))
  }
  if !valid && !is_null_lit(x) {
    raise bad_arg_type(x.ty, 1, name.to_lower())
  }
  let max = match x.ty {
    VarBinary(None) | VarChar(None, _) => true
    Binary(n) | VarBinary(Some(n)) if encode && n > 6000 => true
    _ => false
  }
  let ty : @types.SqlType = if encode {
    VarChar(if max { None } else { Some(8000) }, env.collation)
  } else {
    VarBinary(if max { None } else { Some(8000) })
  }
  let args = [x]
  if call.args.length() == 2 {
    let flag = bind_expr(env, call.args[1])
    if !(flag.ty is (Int | Bit)) && !is_null_lit(flag) {
      raise bad_arg_type(flag.ty, 2, "base64_encode")
    }
    args.push(coerce(flag, Bit))
  }
  Some(named(name, args, ty))
}
