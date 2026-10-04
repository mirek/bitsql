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
  match (from, to) {
    // decimal widening that keeps every digit (captured: GREATEST(1.5,
    // 2.25) and GREATEST(1.5, 22.5) are NOT NULL, GREATEST(1, 2.5) is not)
    (Decimal(p, s) | Numeric(p, s), Decimal(q, t) | Numeric(q, t)) =>
      s <= t && p - s <= q - t
    _ =>
      match (from.family(), to.family()) {
        (FString, FString) => true
        (FInteger, FInteger) => @types.precedence(from) <= @types.precedence(to)
        // captured: GREATEST(1e0, 2) is float NOT NULL, GREATEST(1e0, 2.5)
        // nullable
        (FInteger, FFloat) => to is Float
        _ => false
      }
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
      // decimal or numeric: the first decimal/numeric argument's spelling
      // (captured: GREATEST(2.5, CAST(1 AS decimal(3,1))) is numeric(3,1),
      // GREATEST(CAST(1 AS decimal(4,1)), CAST(2 AS numeric(4,1))) decimal)
      let t : @types.SqlType = match t {
        Decimal(p, s) | Numeric(p, s) =>
          match x.search_by(v => v.ty is (Decimal(_, _) | Numeric(_, _))) {
            Some(i) if x[i].ty is Numeric(_, _) => Numeric(p, s)
            _ => Decimal(p, s)
          }
        _ => t
      }
      // an explicit COLLATE on any argument sets the result collation
      // (captured: GREATEST(N'a', 'b' COLLATE Latin1_General_CS_AS) has the
      // case-sensitive flag; conflicts name "GREATEST/LEAST")
      let t = match resolve_collation(env, "GREATEST/LEAST", x) {
        Some(c) => with_collation(t, c)
        None => t
      }
      let nullable = x.iter().any(v => v.nullable || !safe_conversion(v.ty, t))
      let conv = x.map(v => if is_null_lit(v) { v } else { coerce(v, t) })
      // max types report 8000 bytes; a longer argument is 8152 state 10 at
      // run time (captured: msduck greatest-least #049, #095)
      let rt : @types.SqlType = match t {
        VarChar(None, c) => VarChar(Some(8000), c)
        NVarChar(None, c) => NVarChar(Some(4000), c)
        VarBinary(None) => VarBinary(Some(8000))
        _ => t
      }
      named(name, conv, rt, nullable~)
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
      // captured: HASHBYTES(5, 'abc') is 8116 for argument 1
      if x[0].ty.family() != FString {
        raise bad_arg_type(x[0].ty, 1, "hashbytes")
      }
      if !(x[1].ty.family() is (FString | FBinary)) {
        raise bad_arg_type(x[1].ty, 2, "hashbytes")
      }
      named("HASHBYTES", x, VarBinary(Some(8000)))
    }
    "CHECKSUM" | "BINARY_CHECKSUM" => {
      // captured: 1076 "Function 'checksum' requires at least 1 argument(s)."
      if args.length() == 0 && !call.star {
        raise err(
          1076,
          "Function '\{name.to_lower()}' requires at least 1 argument(s).",
          severity=15,
        )
      }
      // CHECKSUM(*): every column of the FROM clause, in order; CHECKSUM
      // reports each non-comparable one (8116 state 4, text and xml), while
      // BINARY_CHECKSUM skips them (captured: hashbytes-checksum #055-#072)
      let x = if call.star {
        let cols = []
        for i, c in env.columns {
          let e = mk(Col(i), c.ty, c.nullable)
          if c.ty.is_lob() || c.ty is Xml {
            if name == "CHECKSUM" {
              env.deferred.push(bad_arg_type(c.ty, i + 1, "checksum", state=4))
            }
            continue
          }
          cols.push(e)
        }
        if !env.deferred.is_empty() && name == "CHECKSUM" {
          raise env.deferred.pop().unwrap()
        }
        cols
      } else {
        bs()
      }
      // captured: CHECKSUM(NULL) is 8116 state 4; BINARY_CHECKSUM skips NULL
      // literals and is 8184 only when nothing else is left
      for i, v in x {
        if is_null_lit(v) && name == "CHECKSUM" {
          raise null_arg(i + 1, "checksum", state=4)
        }
      }
      if name == "BINARY_CHECKSUM" && x.iter().all(is_null_lit) {
        raise err(
          8184, "Error in binarychecksum. There are no comparable columns in the binarychecksum input.",
        )
      }
      named(name, x, Int)
    }
    "COMPRESS" | "DECOMPRESS" => {
      // captured: 174 "The Compress function requires 1 argument(s).";
      // COMPRESS takes character and binary types, DECOMPRESS only binary
      // (8116 names varchar(max) with its length); both give varbinary(max)
      let label = if name == "COMPRESS" { "Compress" } else { "Decompress" }
      if args.length() != 1 {
        raise err(
          174,
          "The \{label} function requires 1 argument(s).",
          severity=15,
        )
      }
      let x = bs()[0]
      let ok = match x.ty.family() {
        FBinary => !x.ty.is_lob()
        FString => name == "COMPRESS" && !x.ty.is_lob()
        _ => is_null_lit(x)
      }
      if !ok {
        raise err(
          8116,
          "Argument data type \{x.ty.clash_name()} is invalid for argument 1 of \{label} function.",
        )
      }
      named(name, [x], VarBinary(None))
    }
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
