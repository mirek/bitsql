///|
fn arity(
  name : String,
  args : Array[@ast.Expr],
  n : Int,
) -> Unit raise @types.SqlError {
  if args.length() != n {
    raise err(
      174,
      "The \{name.to_lower()} function requires \{n} argument(s).",
      severity=15,
    )
  }
}

///|
fn arity_range(
  name : String,
  args : Array[@ast.Expr],
  lo : Int,
  hi : Int,
) -> Unit raise @types.SqlError {
  if args.length() < lo || args.length() > hi {
    raise err(
      174,
      "The \{name.to_lower()} function requires \{lo} to \{hi} arguments.",
      severity=15,
    )
  }
}

///|
fn nvarchar(n : Int?) -> @types.SqlType {
  NVarChar(n, @types.default_collation)
}

///|
fn bind_call(env : Env, call : @ast.FuncCall) -> @ir.Expr raise @types.SqlError {
  let name = call.name.base().to_upper()
  if call.over is Some(_) {
    // windowed calls are extracted by the query binder (SELECT list and
    // ORDER BY); anywhere else is 4108 (captured: msduck output-typed-stages)
    raise err(
      4108,
      "Windowed functions can only appear in the SELECT or ORDER BY clauses.",
      severity=15,
    )
  }
  let args = call.args
  concat_guard(env, name, args)
  variant_guard(env, name, args)
  xml_guard(env, name, args)
  lob_guard(env, name, args)
  let bound = () => args.map(a => bind_expr(env, a))
  match name {
    "COUNT" | "COUNT_BIG" | "SUM" | "AVG" | "MIN" | "MAX" | "STRING_AGG" =>
      // Aggregates are bound by the query binder; reaching here means the
      // query shape is not supported yet (never report SQL Server's 147).
      raise @types.not_supported("aggregate functions")
    "ISNULL" => {
      arity(name, args, 2)
      let b = bound()
      // An untyped NULL first argument takes the second's type.
      let first_null = b[0].kind is Lit(Null) && b[0].ty is Int
      let ty = if first_null { b[1].ty } else { b[0].ty }
      let first = coerce(b[0], ty)
      let second = coerce(b[1], ty)
      // a constant replacement that folds to a value makes the result NOT
      // NULL even if the replacement alone reports nullable (captured
      // probes: ISNULL(CAST(NULL AS int), CAST(1 AS int)) is int flags 32,
      // ISNULL(.., CHAR(NULL)) 33, ISNULL(.., 1/0) 33; msduck
      // character-result-flags #003, space-capacity #012)
      let known = (x : @ir.Expr) => {
        !x.nullable || (try_fold(x) is Some(v) && !(v is Null))
      }
      // captured: an xml result stays nullable (xml/type#043), as does
      // ISNULL(CAST(0x.. AS image), 'x') (text: not)
      let nullable = ty is (Xml | Image) || !(known(b[0]) || known(b[1]))
      mk(Call(IsNull, [first, second]), ty, nullable)
    }
    "COALESCE" => {
      if args.length() < 2 {
        raise err(
          4103,
          "The coalesce function requires at least 2 arguments.",
          severity=15,
        )
      }
      let b = bound()
      // captured: COALESCE(NULL, N'longer') is nvarchar(6) (msduck
      // conditional-literal-folding #021)
      let t = unify_args(b)
      let branches = []
      for i in 0..<(b.length() - 1) {
        branches.push((bit_expr(IsNull(b[i], negated=true), false), b[i]))
      }
      let last = b[b.length() - 1]
      fold_case(
        branches,
        Some(last),
        t,
        branches.iter().any(x => x.1.nullable) || last.nullable,
      )
    }
    "NULLIF" => {
      arity(name, args, 2)
      let b = bound()
      let first = nullif_operand(b[0])
      let _ = @types.common_type(first.ty, b[1].ty)
      let cond = compare_bound(env, Eq, first, b[1])
      let null_ = mk(Lit(Null), first.ty, true)
      // captured probes: a constant NULLIF folds; NULLIF(1,2) is tinyint
      // NOT NULL, NULLIF(1,1) tinyint nullable (IntN 1)
      match try_fold(cond) {
        Some(Bit(true)) => null_
        Some(_) => first
        None => mk(Case([(cond, null_)], Some(first)), first.ty, true)
      }
    }
    "IIF" => {
      arity(name, args, 3)
      let c = bind_expr(env, args[0])
      let a = bind_expr(env, args[1])
      let b2 = bind_expr(env, args[2])
      // captured: IIF(1=1, NULL, N'x') is nvarchar(1), IIF(1=2, 1, 2.5)
      // numeric(2,1) (msduck conditional-literal-folding #018, logic#022)
      let t = unify_args([a, b2])
      fold_case([(c, a)], Some(b2), t, a.nullable || b2.nullable)
    }
    "XACT_STATE" => {
      arity(name, args, 0)
      mk(Call(XactState, []), SmallInt, true)
    }
    "CURSOR_STATUS" => {
      // captured: smallint NOT NULL; evaluated by the session (cursor.mbt)
      arity(name, args, 2)
      mk(Call(Named("CURSOR_STATUS"), bound()), SmallInt, false)
    }
    "COLUMNS_UPDATED" => {
      // captured: varbinary(4000), NULL outside a trigger (trigger.mbt)
      arity(name, args, 0)
      mk(Call(Named("COLUMNS_UPDATED"), []), VarBinary(Some(4000)), true)
    }
    "ROWCOUNT_BIG" => {
      // captured: bigint NOT NULL (flags 32), the @@ROWCOUNT value
      // (msduck gaps-conversion#1322-1324)
      arity(name, args, 0)
      mk(Call(Named("ROWCOUNT_BIG"), []), BigInt, false)
    }
    "ERROR_NUMBER" | "ERROR_SEVERITY" | "ERROR_STATE" | "ERROR_LINE" => {
      arity(name, args, 0)
      let fnid : @ir.Fn = match name {
        "ERROR_NUMBER" => ErrorNumber
        "ERROR_SEVERITY" => ErrorSeverity
        "ERROR_STATE" => ErrorState
        _ => ErrorLine
      }
      mk(Call(fnid, []), Int, true)
    }
    "ERROR_MESSAGE" => {
      arity(name, args, 0)
      mk(Call(ErrorMessage, []), nvarchar(Some(4000)), true)
    }
    "ERROR_PROCEDURE" => {
      arity(name, args, 0)
      mk(Call(ErrorProcedure, []), nvarchar(Some(128)), true)
    }
    "SCOPE_IDENTITY" => {
      arity(name, args, 0)
      mk(Call(ScopeIdentity, []), Numeric(38, 0), true)
    }
    "NEWID" => {
      arity(name, args, 0)
      mk(Call(NewId, []), UniqueIdentifier, true)
    }
    "GETDATE" | "CURRENT_TIMESTAMP" | "GETUTCDATE" => {
      arity(name, args, 0)
      mk(
        Call(if name == "GETUTCDATE" { GetUtcDate } else { GetDate }, []),
        DateTime,
        false,
      )
    }
    "SYSDATETIME" | "SYSUTCDATETIME" => {
      arity(name, args, 0)
      mk(
        Call(if name == "SYSDATETIME" { SysDateTime } else { SysUtcDateTime }, []),
        DateTime2(7),
        false,
      )
    }
    "SYSDATETIMEOFFSET" => {
      arity(name, args, 0)
      mk(Call(SysDateTimeOffset, []), DateTimeOffset(7), false)
    }
    "DB_NAME" => {
      arity_range(name, args, 0, 1)
      // DB_NAME(id) needs the catalog (session, functions_catalog.mbt)
      let f : @ir.Fn = if args.is_empty() { DbName } else { Named("DB_NAME") }
      mk(Call(f, bound()), nvarchar(Some(128)), true)
    }
    "JSON_VALUE" => {
      arity(name, args, 2)
      // captured: a bare NULL path is 8116 at compile time for JSON_VALUE
      // only (JSON_QUERY reports it at run time; msduck
      // unicode-json-storage#450)
      if args[1].kind is Null {
        raise null_arg(2, "json_value")
      }
      constant_json_check(
        mk(Call(JsonValue, bound()), nvarchar(Some(4000)), true),
      )
    }
    "JSON_QUERY" => {
      arity_range(name, args, 1, 2)
      let b = bound()
      // captured probes: nvarchar(max) only for a max input, else
      // nvarchar(4000) (traps/json-lax-strict)
      let n = if is_max_string(b[0].ty) { None } else { Some(4000) }
      constant_json_check(mk(Call(JsonQuery, b), nvarchar(n), true))
    }
    "ISJSON" => {
      arity_range(name, args, 1, 2)
      // captured: a non-character argument (also a typed NULL) is 8116
      // (msduck isjson-coercion); text/ntext are rejected by lob_guard
      let x = bind_expr(env, args[0])
      if !is_null_lit(x) && x.ty.family() != FString {
        raise bad_arg_type(x.ty, 1, "isjson")
      }
      if args.length() == 2 {
        // ISJSON(x, VALUE | ARRAY | OBJECT | SCALAR): a bare (or bracketed)
        // word, case-insensitive; an unknown word is 155, anything else
        // (string, NULL, variable) 1023 (captured json3 probes)
        // captured: text/ntext are 8116 here too (msduck isjson-coercion)
        if x.ty.is_lob() {
          raise bad_arg_type(x.ty, 1, "isjson")
        }
        let ty = isjson_type_arg(args[1])
        return named(
          "ISJSON",
          [x, @ir.Expr::lit(String(ty), nvarchar(Some(10)))],
          Int,
        )
      }
      mk(Call(IsJson, [x]), Int, true)
    }
    _ =>
      match bind_call_more(env, name, call) {
        Some(e) => e
        None if bind_variant_fn(env, name, call) is Some(e) => e
        None =>
          match bind_call_catalog(env, name, call) {
            Some(e) => e
            None if bind_call_security(env, name, call) is Some(e) => e
            None if sql_server_builtins.contains(name) =>
              // a real SQL Server function bitsql does not implement: an
              // explicit unsupported error, never 195 (which would claim the
              // function does not exist)
              raise @types.not_supported("built-in function \{name}")
            None =>
              raise err(
                195,
                "'\{call.name.base()}' is not a recognized built-in function name.",
                state=10,
                severity=15,
              )
          }
      }
  }
}

///|
/// NULLIF's first argument: an integer literal is typed by its value
/// (captured probes: NULLIF(1,1) is IntN(1) = tinyint, NULLIF(300,1)
/// smallint, NULLIF(-1,-1) smallint, NULLIF(32768,0) int, NULLIF(1+1,0)
/// int; functions/logic#023).
fn nullif_operand(e : @ir.Expr) -> @ir.Expr {
  // folded arithmetic (`1+1`) is a nullable literal and keeps int
  if !(e.ty is Int) || e.nullable {
    return e
  }
  let v = match e.kind {
    Lit(Int(v)) => v
    Neg({ kind: Lit(Int(v)), .. }) => -v
    _ => return e
  }
  if v >= 0 && v <= 255 {
    { kind: Lit(TinyInt(v)), ty: TinyInt, nullable: false, }
  } else if v >= -32768 && v <= 32767 {
    { kind: Lit(SmallInt(v)), ty: SmallInt, nullable: false, }
  } else {
    { kind: Lit(Int(v)), ty: Int, nullable: false, }
  }
}
