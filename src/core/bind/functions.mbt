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
      mk(Call(IsNull, [first, second]), ty, b[0].nullable && b[1].nullable)
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
      let t = unify_types(b.map(x => x.ty))
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
      let t = @types.common_type(b[0].ty, b[1].ty)
      let cond = compare_bound(env, Eq, b[0], b[1])
      mk(
        Case([(cond, mk(Lit(Null), b[0].ty, true))], Some(b[0])),
        b[0].ty,
        true,
      )
      |> ignore_type(t)
    }
    "IIF" => {
      arity(name, args, 3)
      let c = bind_expr(env, args[0])
      let a = bind_expr(env, args[1])
      let b2 = bind_expr(env, args[2])
      let t = @types.common_type(a.ty, b2.ty)
      fold_case([(c, a)], Some(b2), t, a.nullable || b2.nullable)
    }
    "XACT_STATE" => {
      arity(name, args, 0)
      mk(Call(XactState, []), SmallInt, true)
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
      mk(Call(JsonValue, bound()), nvarchar(Some(4000)), true)
    }
    "JSON_QUERY" => {
      arity_range(name, args, 1, 2)
      mk(Call(JsonQuery, bound()), nvarchar(None), true)
    }
    "ISJSON" => {
      arity_range(name, args, 1, 2)
      mk(Call(IsJson, bound()), Int, true)
    }
    _ =>
      match bind_call_more(env, name, call) {
        Some(e) => e
        None =>
          match bind_call_catalog(env, name, call) {
            Some(e) => e
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
fn ignore_type(e : @ir.Expr, _t : @types.SqlType) -> @ir.Expr {
  e
}
