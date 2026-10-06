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
    let returning = name.has_suffix(" RETURNING JSON")
    let base = if object { "JSON_OBJECT" } else { "JSON_ARRAY" }
    // defaults: JSON_OBJECT NULL ON NULL, JSON_ARRAY ABSENT ON NULL
    let absent = if name.contains(" ABSENT ON NULL") {
      true
    } else if name.contains(" NULL ON NULL") {
      false
    } else {
      !object
    }
    let bound = call.args.map(a => bind_expr(env, a))
    // captured (json4, msduck json-constructors#018/#019): RETURNING JSON
    // or a json-typed value makes the result the json type (lower-case
    // flag: the executor normalizes the text)
    let json = returning || bound.iter().any(b => b.ty is Json)
    let flags = StringBuilder()
    flags.write_char(
      match (absent, json) {
        (true, false) => 'A'
        (false, false) => 'N'
        (true, true) => 'a'
        (false, true) => 'n'
      },
    )
    for i, b in bound {
      if !object || i % 2 == 1 {
        flags.write_string(json_flag(env, b))
      }
    }
    let args : Array[@ir.Expr] = [
      @ir.Expr::lit(String(flags.to_string()), nvarchar(Some(4000))),
    ]
    return Some(
      named(
        base,
        args + bound,
        if json {
          Json
        } else {
          NVarChar(None, @types.default_collation)
        },
      ),
    )
  }
  if name == "JSON_CONTAINS" {
    return Some(bind_json_contains(env, call))
  }
  if name == "JSON_PATH_EXISTS" {
    return Some(bind_json_path_exists(env, call))
  }
  if name != "JSON_MODIFY" {
    return None
  }
  arity(name, call.args, 3)
  let b = call.args.map(a => bind_expr(env, a))
  check_json_modify_args(b, "json_modify")
  let flag = @ir.Expr::lit(String(json_flag(env, b[2])), nvarchar(Some(4000)))
  // captured (json4): JSON_MODIFY of a json document returns json
  Some(
    named(
      "JSON_MODIFY",
      b + [flag],
      if b[0].ty is Json {
        Json
      } else {
        NVarChar(None, @types.default_collation)
      },
    ),
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
    if !is_null_lit(x) && x.ty.family() != FString && !(i == 0 && x.ty is Json) {
      raise bad_arg_type(x.ty, i + 1, "json_path_exists")
    }
  }
  constant_json_check(named("JSON_PATH_EXISTS", b, Int))
}

///|
fn check_json_modify_args(
  b : Array[@ir.Expr],
  diagnostic_name : String,
) -> Unit raise @types.SqlError {
  let is_string = (t : @types.SqlType) => {
    t is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _))
  }
  if !is_null_lit(b[0]) && !is_string(b[0].ty) && !(b[0].ty is Json) {
    raise bad_arg_type(b[0].ty, 1, diagnostic_name)
  }
  if is_null_lit(b[1]) {
    raise null_arg(2, diagnostic_name)
  }
  if !is_string(b[1].ty) {
    raise bad_arg_type(b[1].ty, 2, diagnostic_name)
  }
  // captured: strings, exact and approximate numerics and bit; money,
  // date/time, binary, LOB, sql_variant and uniqueidentifier are 8116
  // captured (json4): a json new value needs a json document
  let value_ok = is_null_lit(b[2]) ||
    is_string(b[2].ty) ||
    (b[2].ty is Json && b[0].ty is Json) ||
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
    raise bad_arg_type(b[2].ty, 3, diagnostic_name)
  }
}

///|
/// Statement mutators bind separately from expression methods. The final
/// literal names the target in NULL-target runtime diagnostics.
pub fn bind_json_mutator(
  env : Env,
  current : @ir.Expr,
  meth : String,
  args : Array[@ast.Expr],
  target : String,
) -> @ir.Expr raise @types.SqlError {
  if current.ty is Xml {
    if meth == "modify" {
      arity(meth, args, 1)
    }
    raise @types.not_supported(
      "the xml \{meth}() method",
      number=@types.EMU_XML_NOT_SUPPORTED,
    )
  }
  if !(current.ty is Json) || meth.to_lower() != "modify" {
    raise err(
      258,
      "Cannot call methods on \{current.ty.clash_name()}.",
      severity=15,
    )
  }
  if args.length() < 2 {
    raise err(
      313,
      "An insufficient number of arguments were supplied for the procedure or function modify.",
      state=101,
    )
  }
  if args.length() > 2 {
    raise err(
      8144,
      "Procedure or function modify has too many arguments specified.",
      state=101,
    )
  }
  let b = [current] + args.map(a => bind_expr(env, a))
  check_json_modify_args(b, "modify")
  let flag = @ir.Expr::lit(String(json_flag(env, b[2])), nvarchar(Some(4000)))
  named(
    "JSON_MUTATE",
    b + [flag, @ir.Expr::lit(String(target), nvarchar(Some(4000)))],
    Json,
  )
}

///|
fn bind_json_contains(
  env : Env,
  call : @ast.FuncCall,
) -> @ir.Expr raise @types.SqlError {
  if call.args.length() < 2 || call.args.length() > 4 {
    raise err(
      189,
      "The json_contains function requires 2 to 4 arguments.",
      severity=15,
    )
  }
  let b = call.args.map(a => bind_expr(env, a))
  for i, x in b {
    let valid = match i {
      0 => is_null_lit(x) || x.ty is Json
      1 =>
        !is_null_lit(x) &&
        x.ty
        is (Char(_, _)
        | VarChar(_, _)
        | NChar(_, _)
        | NVarChar(_, _)
        | TinyInt
        | SmallInt
        | Int
        | BigInt
        | Decimal(_, _)
        | Numeric(_, _)
        | Bit)
      2 =>
        is_null_lit(x) ||
        x.ty is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _))
      _ => x.ty is Int
    }
    if !valid {
      if is_null_lit(x) {
        raise null_arg(i + 1, "json_contains")
      }
      raise bad_arg_type(x.ty, i + 1, "json_contains")
    }
  }
  if b.length() == 2 {
    b.push(@ir.Expr::lit(String("$[*]"), nvarchar(Some(4000))))
  }
  if b.length() == 3 {
    b.push(@ir.Expr::lit(Int(0), Int))
  }
  named("JSON_CONTAINS", b, Int)
}
