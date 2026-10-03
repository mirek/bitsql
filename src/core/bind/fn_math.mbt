// Math built-ins. Result types per input type are captured in
// harness/corpus/functions/math.cases.json (every numeric type through
// ABS/SIGN/CEILING/FLOOR/ROUND/POWER/SQUARE/DEGREES/RADIANS). Evaluated in
// exec/fn_math.mbt.

///|
/// Result type shared by ABS, SIGN, ROUND (and CEILING/FLOOR with scale 0):
/// small integers widen to int, bit/text/NULL become float, smallmoney
/// becomes money, real becomes float.
fn math_type(e : @ir.Expr, zero_scale : Bool) -> @types.SqlType {
  if is_null_lit(e) {
    return Float
  }
  match e.ty {
    TinyInt | SmallInt | Int => Int
    BigInt => BigInt
    Decimal(p, s) => Decimal(p, if zero_scale { 0 } else { s })
    Numeric(p, s) => Numeric(p, if zero_scale { 0 } else { s })
    Money | SmallMoney => Money
    _ => Float
  }
}

///|
/// POWER keeps the integer/money families, widens decimals to precision 38
/// and computes everything else as float.
fn power_type(e : @ir.Expr) -> @types.SqlType {
  if is_null_lit(e) {
    return Float
  }
  match e.ty {
    TinyInt | SmallInt | Int => Int
    BigInt => BigInt
    Decimal(_, s) => Decimal(38, s)
    Numeric(_, s) => Numeric(38, s)
    Money | SmallMoney => Money
    _ => Float
  }
}

///|
/// DEGREES / RADIANS: integers and money keep their type, decimals become
/// (38, 18), everything else float.
fn angle_type(e : @ir.Expr) -> @types.SqlType {
  if is_null_lit(e) {
    return Float
  }
  match e.ty {
    TinyInt | SmallInt | Int => Int
    BigInt => BigInt
    Decimal(_, _) => Decimal(38, 18)
    Numeric(_, _) => Numeric(38, 18)
    Money | SmallMoney => Money
    _ => Float
  }
}

///|
/// Arguments converted to the computation type (a bare NULL stays).
fn to_type(e : @ir.Expr, t : @types.SqlType) -> @ir.Expr raise @types.SqlError {
  if is_null_lit(e) {
    e
  } else {
    coerce(e, t)
  }
}

///|
fn bind_math_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  let bs = () => args.map(a => bind_expr(env, a))
  // SQL Server folds these with literal arguments: the result column is
  // then NOT NULL (captured: SIGN(-7.45) flags 32, ABS(-7.45) 33).
  // Only numeric literals fold; text needs a conversion and a non-integer
  // length argument too (captured: SIGN('-7.45') and ROUND(1.5, 1.9) are 33).
  let folded = (xs : Array[@ir.Expr]) => {
    let mut ok = true
    for i, x in xs {
      let fam = x.ty.family()
      if !is_literal(x) ||
        !(fam is (FInteger | FDecimal | FMoney | FFloat)) ||
        (i > 0 && fam != FInteger) {
        ok = false
      }
    }
    !ok
  }
  let r = match name {
    "ABS" | "SIGN" | "CEILING" | "FLOOR" => {
      arity_n(name, args, 1)
      let x = bs()
      let ty = math_type(x[0], name == "CEILING" || name == "FLOOR")
      let nullable = if name == "ABS" { true } else { folded(x) }
      named(name, [to_type(x[0], ty_for_input(x[0], ty))], ty, nullable~)
    }
    "ROUND" => {
      arity_189(name, args, 2, 3)
      let x = bs()
      for i in 1..<x.length() {
        if !is_null_lit(x[i]) && x[i].ty.family() == FString {
          raise bad_arg_type(x[i].ty, i + 1, "round")
        }
      }
      // captured: ROUND(1.5, NULL) is float
      let ty : @types.SqlType = if is_null_lit(x[1]) {
        Float
      } else {
        math_type(x[0], false)
      }
      let conv = [to_type(x[0], ty_for_input(x[0], ty))]
      for i in 1..<x.length() {
        conv.push(as_int_arg(x[i]))
      }
      named("ROUND", conv, ty, nullable=folded(x))
    }
    "POWER" => {
      arity_n(name, args, 2)
      let x = bs()
      let ty = power_type(x[0])
      named(
        "POWER",
        [to_type(x[0], ty_for_input(x[0], ty)), to_type(x[1], Float)],
        ty,
      )
    }
    "SQUARE"
    | "SQRT"
    | "EXP"
    | "LOG10"
    | "SIN"
    | "COS"
    | "TAN"
    | "COT"
    | "ASIN"
    | "ACOS"
    | "ATAN" => {
      arity_n(name, args, 1)
      let x = bs()
      named(name, [to_type(x[0], Float)], Float)
    }
    "LOG" => {
      arity_189(name, args, 1, 2)
      let x = bs()
      named("LOG", x.map(a => to_type(a, Float)), Float)
    }
    "ATN2" => {
      arity_n(name, args, 2)
      let x = bs()
      named("ATN2", x.map(a => to_type(a, Float)), Float)
    }
    "PI" => {
      arity_n(name, args, 0)
      named("PI", [], Float, nullable=false)
    }
    "DEGREES" | "RADIANS" => {
      arity_n(name, args, 1)
      let x = bs()
      let ty = angle_type(x[0])
      let nullable = if name == "DEGREES" { true } else { folded(x) }
      named(name, [to_type(x[0], ty_for_input(x[0], ty))], ty, nullable~)
    }
    "RAND" => {
      arity_189(name, args, 0, 1)
      let x = bs()
      named("RAND", x.map(a => as_int_arg(a)), Float)
    }
    _ => return None
  }
  Some(r)
}

///|
/// The type an argument is converted to before evaluation: the result type,
/// except that decimals keep their own precision (the executor rescales).
fn ty_for_input(e : @ir.Expr, result : @types.SqlType) -> @types.SqlType {
  match (e.ty, result) {
    (Decimal(_, _) | Numeric(_, _), Decimal(_, _) | Numeric(_, _)) => e.ty
    _ => result
  }
}
