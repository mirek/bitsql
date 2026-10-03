// Logical, conversion and hashing built-ins: CHOOSE, GREATEST, LEAST,
// ISNUMERIC, HASHBYTES, CHECKSUM, BINARY_CHECKSUM, NEWSEQUENTIALID.
// Captures: harness/corpus/functions/logic.cases.json, hash.cases.json.

///|
/// Whether converting `from` to `to` can never fail, so GREATEST/LEAST keep
/// a non-null result (captured: LEAST(N'a', 'B') flags 32, GREATEST(1, 2.5)
/// and GREATEST(1, '5') 33). Unverified beyond those shapes: string
/// widening and integer widening count as safe.
fn safe_conversion(from : @types.SqlType, to : @types.SqlType) -> Bool {
  if from == to {
    return true
  }
  match (from.family(), to.family()) {
    (FString, FString) => true
    (FInteger, FInteger) => @types.precedence(from) <= @types.precedence(to)
    _ => false
  }
}

///|
fn bind_misc_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  let bs = () => args.map(a => bind_expr(env, a))
  let r = match name {
    "CHOOSE" => {
      if args.length() < 2 {
        raise err(
          1076,
          "Function 'choose' requires at least 2 argument(s).",
          severity=15,
        )
      }
      let x = bs()
      let values = x[1:].to_owned()
      let t = unify_args(values)
      let index = if is_null_lit(x[0]) { x[0] } else { coerce(x[0], Int) }
      // CHOOSE is a CASE over the index: only the chosen value is converted
      // (captured: CHOOSE(1, 2, 'a') is 2, CHOOSE(1, 'a', 2) fails on 'a').
      let branches = []
      for i, v in values {
        let k = @ir.Expr::lit(Int(i + 1), Int)
        branches.push((compare_bound(env, Eq, index, k), coerce(v, t)))
      }
      mk(Case(branches, None), t, true)
    }
    "GREATEST" | "LEAST" => {
      if args.length() < 1 || args.length() > 254 {
        raise err(
          189,
          "The \{name.to_lower()} function requires 1 to 254 arguments.",
          severity=15,
        )
      }
      let x = bs()
      let t = unify_args(x)
      // an explicit COLLATE on any argument sets the result collation
      // (captured: GREATEST(N'a', 'b' COLLATE Latin1_General_CS_AS) has the
      // case-sensitive flag)
      let t = match resolve_collation(env, name.to_lower(), x) {
        Some(c) => with_collation(t, c)
        None => t
      }
      let nullable = x.iter().any(v => v.nullable || !safe_conversion(v.ty, t))
      let conv = x.map(v => if is_null_lit(v) { v } else { coerce(v, t) })
      named(name, conv, t, nullable~)
    }
    "ISNUMERIC" => {
      arity_n(name, args, 1)
      let x = bs()[0]
      if x.ty.family() is (FDate | FTime | FDateTime | FGuid | FBinary) &&
        !is_null_lit(x) {
        raise bad_arg_type(x.ty, 1, "isnumeric")
      }
      named("ISNUMERIC", [x], Int)
    }
    "NEWSEQUENTIALID" =>
      raise err(
        302,
        "The newsequentialid() built-in function can only be used in a DEFAULT expression for a column of type 'uniqueidentifier' in a CREATE TABLE or ALTER TABLE statement. It cannot be combined with other operators to form a complex scalar expression.",
        state=0,
      )
    "HASHBYTES" => {
      arity_n(name, args, 2)
      let x = bs()
      for i in 0..<2 {
        if is_null_lit(x[i]) {
          raise null_arg(i + 1, "hashbytes")
        }
      }
      if !(x[1].ty.family() is (FString | FBinary)) {
        raise bad_arg_type(x[1].ty, 2, "hashbytes")
      }
      named("HASHBYTES", x, VarBinary(Some(8000)))
    }
    "CHECKSUM" | "BINARY_CHECKSUM" => {
      if args.length() == 0 {
        raise err(
          189,
          "The \{name.to_lower()} function requires 1 to 255 arguments.",
          severity=15,
        )
      }
      if call.star {
        raise @types.not_supported("\{name}(*)")
      }
      let x = bs()
      for i, v in x {
        if is_null_lit(v) {
          raise if name == "CHECKSUM" {
            null_arg(i + 1, "checksum", state=4)
          } else {
            err(
              8184, "Error in binarychecksum. There are no comparable columns in the binarychecksum input.",
            )
          }
        }
      }
      named(name, x, Int)
    }
    "COMPRESS" | "DECOMPRESS" => raise @types.not_supported(name)
    _ => return None
  }
  Some(r)
}

///|
/// Common type of arguments, ignoring bare NULL literals (captured:
/// CHOOSE(1, NULL, 'b') is varchar(1)); int when all are NULL.
fn unify_args(xs : Array[@ir.Expr]) -> @types.SqlType raise @types.SqlError {
  let xs = xs.filter(x => !is_null_lit(x))
  // Integer literals next to a decimal count as numeric(digits, 0)
  // (captured: CHOOSE(1, 1, 2.5) and GREATEST(1, 2.5) are numeric(2,1)).
  let has_decimal = xs.iter().any(x => x.ty is (Decimal(_, _) | Numeric(_, _)))
  let tys = xs.map(x => {
    match (has_decimal, fold(x)) {
      (true, Some(Int(n))) if is_literal(x) =>
        @types.SqlType::Numeric(
          @cmp.maximum(1, n.abs().to_string().length()),
          0,
        )
      _ => x.ty
    }
  })
  if tys.length() == 0 {
    Int
  } else {
    unify_types(tys)
  }
}
