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
fn is_max(t : @types.SqlType) -> Bool {
  t is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None))
}

///|
fn nvarchar(n : Int?) -> @types.SqlType {
  NVarChar(n, @types.default_collation)
}

///|
/// Result type of string functions that return their argument's family.
fn string_like(t : @types.SqlType, env : Env) -> @types.SqlType {
  match t.family() {
    FString => t
    _ => VarChar(Some(8000), env.collation)
  }
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
  let any_null = (bs : Array[@ir.Expr]) => bs.iter().any(b => b.nullable)
  match name {
    "COUNT" | "COUNT_BIG" | "SUM" | "AVG" | "MIN" | "MAX" | "STRING_AGG" =>
      // Aggregates are bound by the query binder; reaching here means the
      // query shape is not supported yet (never report SQL Server's 147).
      raise @types.not_supported("aggregate functions")
    "LEN" => {
      arity(name, args, 1)
      let b = bound()
      let ty : @types.SqlType = if is_max(b[0].ty) { BigInt } else { Int }
      mk(Call(Len, b), ty, true)
    }
    "DATALENGTH" => {
      arity(name, args, 1)
      let b = bound()
      let ty : @types.SqlType = if is_max(b[0].ty) { BigInt } else { Int }
      mk(Call(DataLength, b), ty, true)
    }
    "UPPER" | "LOWER" | "LTRIM" | "RTRIM" | "TRIM" | "REVERSE" => {
      let fnid : @ir.Fn = match name {
        "UPPER" => Upper
        "LOWER" => Lower
        "LTRIM" => LTrim
        "RTRIM" => RTrim
        "TRIM" => Trim
        _ => Reverse
      }
      if name == "UPPER" || name == "LOWER" || name == "REVERSE" {
        arity(name, args, 1)
      } else {
        arity_range(name, args, 1, 2)
      }
      let b = bound()
      mk(Call(fnid, b), string_like(b[0].ty, env), true)
    }
    "LEFT" | "RIGHT" => {
      arity(name, args, 2)
      let b = bound()
      mk(
        Call(if name == "LEFT" { Left } else { Right }, b),
        string_like(b[0].ty, env),
        true,
      )
    }
    "SUBSTRING" => {
      arity(name, args, 3)
      let b = bound()
      mk(Call(Substring, b), string_like(b[0].ty, env), true)
    }
    "REPLACE" => {
      arity(name, args, 3)
      let b = bound()
      ignore(resolve_collation(env, "replace", b))
      let ty : @types.SqlType = if is_max(b[0].ty) {
        b[0].ty
      } else if b.iter().any(x => x.ty.is_unicode()) {
        nvarchar(Some(4000))
      } else {
        VarChar(Some(8000), env.collation)
      }
      mk(Call(Replace, b), ty, any_null(b))
    }
    "REPLICATE" => {
      arity(name, args, 2)
      let b = bound()
      let ty : @types.SqlType = if is_max(b[0].ty) {
        b[0].ty
      } else if b[0].ty.is_unicode() {
        nvarchar(Some(4000))
      } else {
        VarChar(Some(8000), env.collation)
      }
      mk(Call(Replicate, b), ty, true)
    }
    "CHARINDEX" => {
      arity_range(name, args, 2, 3)
      let b = bound()
      let ty : @types.SqlType = if is_max(b[1].ty) { BigInt } else { Int }
      mk(Call(CharIndex, b), ty, any_null(b))
    }
    "CONCAT" => {
      if args.length() < 2 {
        raise err(
          189,
          "The concat function requires 2 to 254 arguments.",
          severity=15,
        )
      }
      let b = bound()
      let unicode = b.iter().any(x => x.ty.is_unicode())
      let mut total = 0
      let mut max = false
      for x in b {
        match x.ty {
          Char(n, _)
          | NChar(n, _)
          | VarChar(Some(n), _)
          | NVarChar(Some(n), _) => total += n
          VarChar(None, _) | NVarChar(None, _) | VarBinary(None) => max = true
          _ => total += 30
        }
      }
      let cap = if unicode { 4000 } else { 8000 }
      let n = if max || total > cap { None } else { Some(total) }
      let ty : @types.SqlType = if unicode {
        nvarchar(n)
      } else {
        VarChar(n, env.collation)
      }
      mk(Call(Concat, b), ty, false)
    }
    "SPACE" => {
      arity(name, args, 1)
      mk(Call(Space, bound()), VarChar(Some(8000), env.collation), true)
    }
    "NCHAR" => {
      arity(name, args, 1)
      mk(Call(Nchar, bound()), NChar(1, env.collation), true)
    }
    "CHAR" => {
      arity(name, args, 1)
      mk(Call(Char, bound()), Char(1, env.collation), true)
    }
    "ASCII" | "UNICODE" => {
      arity(name, args, 1)
      mk(
        Call(if name == "ASCII" { Ascii } else { Unicode }, bound()),
        Int,
        true,
      )
    }
    "ABS" | "CEILING" | "FLOOR" | "SIGN" => {
      arity(name, args, 1)
      let b = bound()
      let fnid : @ir.Fn = match name {
        "ABS" => Abs
        "CEILING" => Ceiling
        "FLOOR" => Floor
        _ => Sign
      }
      let ty : @types.SqlType = match (fnid, b[0].ty) {
        (Ceiling | Floor, Decimal(p, _)) => Decimal(p, 0)
        (Ceiling | Floor, Numeric(p, _)) => Numeric(p, 0)
        (_, TinyInt | SmallInt | Bit) => Int
        (_, t) if t.family() == FString => Float
        (_, t) => t
      }
      mk(Call(fnid, b), ty, b[0].nullable)
    }
    "ROUND" => {
      arity_range(name, args, 2, 3)
      let b = bound()
      let ty : @types.SqlType = match b[0].ty {
        Decimal(p, s) => Decimal(@cmp.minimum(38, p + 1), s)
        Numeric(p, s) => Numeric(@cmp.minimum(38, p + 1), s)
        TinyInt | SmallInt | Bit => Int
        t if t.family() == FString => Float
        t => t
      }
      mk(Call(Round, b), ty, b[0].nullable)
    }
    "POWER" => {
      arity(name, args, 2)
      let b = bound()
      let ty : @types.SqlType = match b[0].ty {
        TinyInt | SmallInt | Bit => Int
        t if t.family() == FString => Float
        t => t
      }
      mk(Call(Power, b), ty, true)
    }
    "SQRT" => {
      arity(name, args, 1)
      mk(Call(Sqrt, bound()), Float, true)
    }
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
      mk(Call(NewId, []), UniqueIdentifier, false)
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
      mk(Call(DbName, bound()), nvarchar(Some(128)), true)
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
