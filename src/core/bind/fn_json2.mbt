// JSON_OBJECT, JSON_ARRAY (SQL Server 2022 constructors) and JSON_MODIFY.
// Captures: harness/corpus/json2/*.sql. The parser encodes the
// NULL/ABSENT ON NULL and RETURNING clauses in the call name
// (parse/json_ctor.mbt). Each bound call gets a leading (constructors) or
// trailing (JSON_MODIFY) string literal of flags: 'A'/'N' for ABSENT/NULL
// ON NULL, then one 'j' (JSON text, embedded raw) or 's' per value.

///|
fn json_flag(env : Env, e : @ir.Expr) -> String {
  if is_json_expr(env, e) {
    "j"
  } else {
    "s"
  }
}

///|
fn bind_json2_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let object = name.has_prefix("JSON_OBJECT")
  if object || name.has_prefix("JSON_ARRAY") {
    if name.has_suffix(" RETURNING JSON") {
      raise @types.not_supported("JSON_OBJECT/JSON_ARRAY RETURNING json")
    }
    let base = if object { "JSON_OBJECT" } else { "JSON_ARRAY" }
    // defaults: JSON_OBJECT NULL ON NULL, JSON_ARRAY ABSENT ON NULL
    let absent = if name.has_suffix(" ABSENT ON NULL") {
      true
    } else if name.has_suffix(" NULL ON NULL") {
      false
    } else {
      !object
    }
    let bound = call.args.map(a => bind_expr(env, a))
    let flags = StringBuilder()
    flags.write_char(if absent { 'A' } else { 'N' })
    for i, b in bound {
      if !object || i % 2 == 1 {
        flags.write_string(json_flag(env, b))
      }
    }
    let args : Array[@ir.Expr] = [
      @ir.Expr::lit(String(flags.to_string()), nvarchar(Some(4000))),
    ]
    return Some(
      named(base, args + bound, NVarChar(None, @types.default_collation)),
    )
  }
  if name == "JSON_PATH_EXISTS" {
    return Some(bind_json_path_exists(env, call))
  }
  if name != "JSON_MODIFY" {
    return None
  }
  arity(name, call.args, 3)
  let b = call.args.map(a => bind_expr(env, a))
  let is_string = (t : @types.SqlType) => {
    t is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _))
  }
  if !is_null_lit(b[0]) && !is_string(b[0].ty) {
    raise bad_arg_type(b[0].ty, 1, "json_modify")
  }
  if is_null_lit(b[1]) {
    raise null_arg(2, "json_modify")
  }
  if !is_string(b[1].ty) {
    raise bad_arg_type(b[1].ty, 2, "json_modify")
  }
  // captured: strings, exact and approximate numerics and bit; money,
  // date/time, binary, LOB, sql_variant and uniqueidentifier are 8116
  let value_ok = is_null_lit(b[2]) ||
    is_string(b[2].ty) ||
    b[2].ty
    is (TinyInt
    | SmallInt
    | Int
    | BigInt
    | Decimal(_, _)
    | Numeric(_, _)
    | Float
    | Real
    | Bit)
  if !value_ok {
    raise bad_arg_type(b[2].ty, 3, "json_modify")
  }
  let flag = @ir.Expr::lit(String(json_flag(env, b[2])), nvarchar(Some(4000)))
  Some(
    named("JSON_MODIFY", b + [flag], NVarChar(None, @types.default_collation)),
  )
}

///|
/// ISJSON's second argument (see the ISJSON binder).
fn isjson_type_arg(a : @ast.Expr) -> String raise @types.SqlError {
  match a.kind {
    Column([id]) =>
      match id.name.to_upper() {
        "VALUE" | "ARRAY" | "OBJECT" | "SCALAR" => id.name.to_upper()
        _ =>
          raise err(
            155,
            "'\{id.name}' is not a recognized isjson option.",
            severity=15,
          )
      }
    _ =>
      raise err(1023, "Invalid parameter 2 specified for isjson.", severity=15)
  }
}

///|
/// JSON_PATH_EXISTS(doc, path) (SQL Server 2022): int, NULL for a NULL
/// document; non-character arguments are 8116 at compile time, a NULL path
/// 8116 state 8 at run time (captured json3 probes).
fn bind_json_path_exists(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.Expr raise @types.SqlError {
  arity("JSON_PATH_EXISTS", call.args, 2)
  let b = call.args.map(a => bind_expr(env, a))
  for i, x in b {
    if !is_null_lit(x) && x.ty.family() != FString {
      raise bad_arg_type(x.ty, i + 1, "json_path_exists")
    }
  }
  constant_json_check(named("JSON_PATH_EXISTS", b, Int))
}
