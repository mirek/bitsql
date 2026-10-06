///|
fn bind_regex_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  if !(name
    is ("REGEXP_COUNT"
    | "REGEXP_SUBSTR"
    | "REGEXP_INSTR"
    | "REGEXP_REPLACE"
    | "REGEXP_LIKE")) {
    return None
  }
  if name == "REGEXP_LIKE" && (env.catalog.compat_level)() < 170 {
    raise err(
      195,
      "'\{call.name.base()}' is not a recognized built-in function name.",
      state=10,
      severity=15,
    )
  }
  arity_189(
    name,
    call.args,
    2,
    if name == "REGEXP_LIKE" {
      3
    } else if name == "REGEXP_COUNT" {
      4
    } else if name == "REGEXP_INSTR" {
      7
    } else {
      6
    },
  )
  let args : Array[@ir.Expr] = [
    @ir.Expr::lit(Null, VarChar(Some(1), env.collation)),
    @ir.Expr::lit(Null, VarChar(Some(1), env.collation)),
    @ir.Expr::lit(Int(1), Int),
    @ir.Expr::lit(Int(if name == "REGEXP_REPLACE" { 0 } else { 1 }), Int),
    @ir.Expr::lit(String("c"), VarChar(Some(1), env.collation)),
    @ir.Expr::lit(Int(0), Int),
    @ir.Expr::lit(Int(0), Int),
    @ir.Expr::lit(String(""), VarChar(Some(1), env.collation)),
  ]
  for j in 0..<call.args.length() {
    let (slot, label) = if j < 2 {
      (j, "")
    } else {
      match name {
        "REGEXP_LIKE" => (4, "")
        "REGEXP_COUNT" => if j == 2 { (2, "START") } else { (4, "") }
        "REGEXP_REPLACE" =>
          match j {
            2 => (7, "")
            3 => (2, "START")
            4 => (3, "OCCURRENCE")
            _ => (4, "")
          }
        "REGEXP_SUBSTR" =>
          match j {
            2 => (2, "START")
            3 => (3, "OCCURRENCE")
            4 => (4, "")
            _ => (5, "GROUP")
          }
        _ =>
          match j {
            2 => (2, "START")
            3 => (3, "OCCURRENCE")
            4 => (6, "RETURN_OPTION")
            5 => (4, "")
            _ => (5, "GROUP")
          }
      }
    }
    let x = bind_expr(env, call.args[j])
    let bare_null = call.args[j].kind is Null
    if label == "" {
      if j == 1 && x.ty is (VarChar(None, _) | NVarChar(None, _)) {
        raise err(
          8116,
          "Argument data type VARCHAR(MAX)/NVARCHAR(MAX) is invalid for argument 2 of \{name.to_lower()} function.",
          state=13,
        )
      }
      if !(x.ty is (Char(_, _) | NChar(_, _) | VarChar(_, _) | NVarChar(_, _))) &&
        !bare_null {
        raise bad_arg_type(x.ty, j + 1, name.to_lower())
      }
      if slot == 4 && x.ty is (NChar(_, _) | NVarChar(_, _)) && !bare_null {
        raise bad_arg_type(x.ty, j + 1, name.to_lower())
      }
      args[slot] = if bare_null {
        coerce(x, VarChar(Some(1), env.collation))
      } else {
        x
      }
    } else {
      if !(x.ty is (TinyInt | SmallInt | Int | BigInt)) && !bare_null {
        raise bad_arg_type(x.ty, j + 1, name.to_lower())
      }
      args[slot] = coerce(x, Int)
      if fold(args[slot]) is Some(value) && value.as_int64() is Some(n) {
        @regex.validate_control(name, label, n)
      }
    }
  }
  if !args.any(a => fold(a) is Some(Null)) &&
    fold(args[1]) is Some(String(pattern)) &&
    fold(args[4]) is Some(String(flags)) {
    ignore(@regex.compile(pattern, flags))
  }
  let source = args[0].ty
  let ty : @types.SqlType = if name == "REGEXP_LIKE" {
    Bit
  } else if name is ("REGEXP_COUNT" | "REGEXP_INSTR") {
    Int
  } else if name == "REGEXP_SUBSTR" {
    string_arg_type(args[0], env)
  } else {
    match source {
      Char(_, c) => Char(8000, c)
      NChar(_, c) => NChar(4000, c)
      VarChar(n, c) => VarChar(if n is None { None } else { Some(8000) }, c)
      NVarChar(n, c) => NVarChar(if n is None { None } else { Some(4000) }, c)
      _ => VarChar(Some(8000), env.collation)
    }
  }
  Some(named(name, args, ty))
}

///|
fn bind_regex_table(
  env : Env,
  name : @ast.ObjectName,
  input : Array[@ast.Expr],
) -> (@ir.TableFn, Array[@ir.Expr], @types.SqlType) raise @types.SqlError {
  let fname = name.base().to_upper()
  if (env.catalog.compat_level)() < 170 {
    raise err(208, "Invalid object name '\{name.base()}'.")
  }
  if input.length() < 2 {
    raise err(
      313,
      "An insufficient number of arguments were supplied for the procedure or function \{fname}.",
      state=3,
    )
  }
  if input.length() > 3 {
    raise err(
      8144,
      "Procedure or function \{fname} has too many arguments specified.",
      state=3,
    )
  }
  let args : Array[@ir.Expr] = []
  for i in 0..<input.length() {
    let e = bind_expr(env, input[i])
    let bare_null = input[i].kind is Null
    if i > 0 && e.ty is (VarChar(None, _) | NVarChar(None, _)) {
      raise err(
        8116,
        "Argument data type VARCHAR(MAX)/NVARCHAR(MAX) is invalid for argument \{i + 1} of \{fname.to_lower()} function.",
        state=(if fname == "REGEXP_MATCHES" { 22 } else { 25 }) + i,
      )
    }
    if (
        !(e.ty is (Char(_, _) | NChar(_, _) | VarChar(_, _) | NVarChar(_, _))) ||
        (i == 2 && e.ty is (NChar(_, _) | NVarChar(_, _)))
      ) &&
      !bare_null {
      raise err(
        8116,
        "Argument data type \{e.ty.base_name()} is invalid for argument \{i + 1} of \{fname.to_lower()} function.",
        state=if fname == "REGEXP_MATCHES" { 25 } else { 28 },
      )
    }
    args.push(
      if bare_null {
        coerce(e, VarChar(Some(1), env.collation))
      } else {
        e
      },
    )
  }
  if args.length() == 2 {
    args.push(@ir.Expr::lit(String("c"), VarChar(Some(1), env.collation)))
  }
  (
    if fname == "REGEXP_MATCHES" {
      @ir.TableFn::RegexMatches
    } else {
      @ir.TableFn::RegexSplit
    },
    args,
    if input[0].kind is Null {
      VarChar(Some(8000), env.collation)
    } else {
      args[0].ty
    },
  )
}
