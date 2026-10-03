// Date and time built-ins: DATEADD, DATEDIFF(_BIG), DATEPART, DATENAME,
// YEAR/MONTH/DAY, EOMONTH, *FROMPARTS, TODATETIMEOFFSET, SWITCHOFFSET,
// ISDATE, DATETRUNC. Evaluated in exec/fn_date.mbt. Captures:
// harness/corpus/functions/date.cases.json.

///|
/// Canonical datepart name for an abbreviation (SQL Server's spelling in
/// 9810/9806 messages), or None.
fn datepart_name(word : String) -> String? {
  match word.to_lower() {
    "year" | "yy" | "yyyy" => Some("year")
    "quarter" | "qq" | "q" => Some("quarter")
    "month" | "mm" | "m" => Some("month")
    "dayofyear" | "dy" | "y" => Some("dayofyear")
    "day" | "dd" | "d" => Some("day")
    "week" | "wk" | "ww" => Some("week")
    "weekday" | "dw" | "w" => Some("weekday")
    "hour" | "hh" => Some("hour")
    "minute" | "mi" | "n" => Some("minute")
    "second" | "ss" | "s" => Some("second")
    "millisecond" | "ms" => Some("millisecond")
    "microsecond" | "mcs" => Some("microsecond")
    "nanosecond" | "ns" => Some("nanosecond")
    "iso_week" | "isowk" | "isoww" => Some("iso_week")
    "tzoffset" | "tz" => Some("tzoffset")
    _ => None
  }
}

///|
/// The datepart argument: a bare (or quoted) identifier. Anything else is
/// 1023 (captured: DATEADD('day', ...), a variable); an unknown word is 155.
fn datepart_arg(
  e : @ast.Expr,
  fname : String,
) -> @ir.Expr raise @types.SqlError {
  match e.kind {
    Column([id]) =>
      match datepart_name(id.name) {
        Some(p) =>
          @ir.Expr::lit(
            String(p),
            VarChar(Some(p.length()), @types.default_collation),
          )
        None =>
          raise err(
            155,
            "'\{id.name}' is not a recognized \{fname} option.",
            severity=15,
          )
      }
    _ =>
      raise err(
        1023,
        "Invalid parameter 1 specified for \{fname}.",
        severity=15,
      )
  }
}

///|
fn is_temporal(t : @types.SqlType) -> Bool {
  t.family() is (FDate | FTime | FDateTime)
}

///|
/// Type a date argument takes in DATEADD/DATETRUNC/EOMONTH: temporal types
/// stay, everything else (text, numbers, a bare NULL) is datetime.
fn date_arg_type(e : @ir.Expr) -> @types.SqlType {
  if is_temporal(e.ty) && !is_null_lit(e) {
    e.ty
  } else {
    DateTime
  }
}

///|
/// Binary date arguments are reinterpreted as datetime storage bytes by SQL
/// Server; bitsql does not emulate that.
fn reject_binary_date(e : @ir.Expr) -> Unit raise @types.SqlError {
  if e.ty.family() == FBinary && !is_null_lit(e) {
    raise @types.not_supported("binary values as date/time function arguments")
  }
}

///|
fn bind_date_fn(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  let args = call.args
  let b = (i : Int) => bind_expr(env, args[i])
  let r = match name {
    "DATEADD" => {
      arity_n(name, args, 3)
      let part = datepart_arg(args[0], "dateadd")
      let n = b(1)
      if is_null_lit(n) {
        raise null_arg(2, "dateadd")
      }
      match n.ty.family() {
        FBit | FInteger | FDecimal | FMoney | FFloat => ()
        _ => raise bad_arg_type(n.ty, 2, "dateadd")
      }
      let d = b(2)
      reject_binary_date(d)
      named("DATEADD", [part, n, d], date_arg_type(d))
    }
    "DATEDIFF" | "DATEDIFF_BIG" => {
      arity_n(name, args, 3)
      let fname = name.to_lower()
      let part = datepart_arg(args[0], fname)
      let a = b(1)
      let c = b(2)
      reject_binary_date(a)
      reject_binary_date(c)
      named(name, [part, a, c], if name == "DATEDIFF" { Int } else { BigInt })
    }
    "DATEPART" | "DATENAME" => {
      arity_n(name, args, 2)
      let part = datepart_arg(args[0], name.to_lower())
      let d = b(1)
      reject_binary_date(d)
      named(
        name,
        [part, d],
        if name == "DATEPART" {
          Int
        } else {
          NVarChar(Some(30), @types.default_collation)
        },
      )
    }
    "YEAR" | "MONTH" | "DAY" => {
      arity_n(name, args, 1)
      let d = b(0)
      reject_binary_date(d)
      let p = name.to_lower()
      named(
        "DATEPART",
        [
          @ir.Expr::lit(
            String(p),
            VarChar(Some(p.length()), @types.default_collation),
          ),
          d,
        ],
        Int,
      )
    }
    "EOMONTH" => {
      arity_189(name, args, 1, 2)
      let d = b(0)
      if d.ty is Time(_) {
        raise bad_arg_type(d.ty, 1, "eomonth")
      }
      reject_binary_date(d)
      let bs = [d]
      if args.length() == 2 {
        bs.push(b(1))
      }
      named("EOMONTH", bs, Date)
    }
    "DATEFROMPARTS" => from_parts(env, name, args, 3, Date)
    "DATETIMEFROMPARTS" => from_parts(env, name, args, 7, DateTime)
    "SMALLDATETIMEFROMPARTS" => from_parts(env, name, args, 5, SmallDateTime)
    "DATETIME2FROMPARTS" => {
      arity_n(name, args, 8)
      let p = scale_arg(env, args[7], "datetime2")
      from_parts(env, name, args, 8, DateTime2(p))
    }
    "TIMEFROMPARTS" => {
      arity_n(name, args, 5)
      let p = scale_arg(env, args[4], "time")
      from_parts(env, name, args, 5, Time(p))
    }
    "DATETIMEOFFSETFROMPARTS" => {
      arity_n(name, args, 10)
      let p = scale_arg(env, args[9], "datetimeoffset")
      from_parts(env, name, args, 10, DateTimeOffset(p))
    }
    "TODATETIMEOFFSET" | "SWITCHOFFSET" => {
      arity_n(name, args, 2)
      let d = b(0)
      reject_binary_date(d)
      let tz = b(1)
      let scale = match d.ty {
        DateTime2(s) | Time(s) | DateTimeOffset(s) => s
        DateTime => 3
        SmallDateTime => 0
        _ => 7
      }
      named(name, [d, tz], DateTimeOffset(scale))
    }
    "ISDATE" => {
      arity_n(name, args, 1)
      let d = b(0)
      if is_temporal(d.ty) {
        raise bad_arg_type(d.ty, 1, "isdate")
      }
      named("ISDATE", [as_string_arg(d, env)], Int)
    }
    "DATETRUNC" => {
      arity_n(name, args, 2)
      let part = datepart_arg(args[0], "datetrunc")
      let d = b(1)
      // captured: DATETRUNC(day, 45000) is 8116 (numbers are not dates here)
      if !is_null_lit(d) && !is_temporal(d.ty) && d.ty.family() != FString {
        raise bad_arg_type(d.ty, 2, "datetrunc")
      }
      let ty : @types.SqlType = if is_temporal(d.ty) && !is_null_lit(d) {
        d.ty
      } else {
        DateTime2(7)
      }
      named("DATETRUNC", [part, d], ty)
    }
    _ => return None
  }
  Some(r)
}

///|
/// Constant scale argument of DATETIME2FROMPARTS & co: 1002 when out of
/// range, 10760 when not an integer constant (captured, compile time).
fn scale_arg(
  env : Env,
  e : @ast.Expr,
  tname : String,
) -> Int raise @types.SqlError {
  let x = bind_expr(env, e)
  let not_constant = err(
    10760,
    "Scale argument is not valid. Valid expressions for data type \{tname} scale argument are integer constants and integer constant expressions.",
  )
  match fold_int(x) {
    Some(p) =>
      if p < 0L || p > 7L {
        raise err(1002, "Line 1: Specified scale \{p} is invalid.", state=2)
      } else {
        p.to_int()
      }
    None => raise not_constant
  }
}

///|
/// *FROMPARTS: all arguments become int; the result is nullable when any
/// argument is (captured: literal ints give flags 32, a NULL or text
/// argument 33).
fn from_parts(
  env : Env,
  name : String,
  args : Array[@ast.Expr],
  n : Int,
  ty : @types.SqlType,
) -> @ir.Expr raise @types.SqlError {
  arity_n(name, args, n)
  let bs = args.map(a => bind_expr(env, a))
  let nullable = bs
    .iter()
    .any(x => x.nullable || x.ty.family() != FInteger || is_null_lit(x))
  named(name, bs.map(x => as_int_arg(x)), ty, nullable~)
}
