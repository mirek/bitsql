// DATE_BUCKET(datepart, width, date [, origin]) (SQL Server 2022). Evaluated
// in exec/fn_date_bucket.mbt. Captures: harness/corpus/analytic/date-bucket*.

///|
/// Precedence rank of a DATE_BUCKET date type: when the date and origin
/// types differ, SQL Server reports 8116 for the lower-ranked argument
/// (captured: date + datetime2 origin names argument 3 `date`, datetime2 +
/// date origin argument 4 `date`, datetime + smalldatetime origin argument
/// 4 `smalldatetime`).
fn bucket_rank(t : @types.SqlType) -> Int {
  match t {
    DateTimeOffset(_) => 6
    DateTime2(_) => 5
    DateTime => 4
    SmallDateTime => 3
    Date => 2
    Time(_) => 1
    _ => 0
  }
}

///|
fn same_bucket_base(a : @types.SqlType, b : @types.SqlType) -> Bool {
  match (a, b) {
    (DateTimeOffset(_), DateTimeOffset(_))
    | (DateTime2(_), DateTime2(_))
    | (Time(_), Time(_))
    | (DateTime, DateTime)
    | (SmallDateTime, SmallDateTime)
    | (Date, Date) => true
    _ => false
  }
}

///|
fn bind_date_bucket(
  env : Env,
  name : String,
  call : @ast.FuncCall,
) -> @ir.Expr? raise @types.SqlError {
  guard name == "DATE_BUCKET" else { return None }
  let fname = "Date_Bucket"
  let args = call.args
  if args.length() < 3 || args.length() > 4 {
    raise err(
      189,
      "The \{fname} function requires 3 to 4 arguments.",
      severity=15,
    )
  }
  let part = datepart_arg(args[0], fname)
  let width = bind_expr(env, args[1])
  if is_null_lit(width) {
    raise null_arg(2, fname)
  }
  match width.ty.family() {
    FInteger | FDecimal | FFloat | FMoney | FBit => ()
    _ => raise bad_arg_type(width.ty, 2, fname)
  }
  let d = bind_expr(env, args[2])
  if is_null_lit(d) {
    raise null_arg(3, fname)
  }
  if bucket_rank(d.ty) == 0 {
    raise bad_arg_type(d.ty, 3, fname)
  }
  let mut ty = d.ty
  let out = [part, width, d]
  if args.length() == 4 {
    let o = bind_expr(env, args[3])
    // an untyped NULL origin is the default origin (captured)
    if !is_null_lit(o) {
      if bucket_rank(o.ty) == 0 {
        raise bad_arg_type(o.ty, 4, fname)
      }
      if !same_bucket_base(d.ty, o.ty) {
        if bucket_rank(d.ty) < bucket_rank(o.ty) {
          raise bad_arg_type(d.ty, 3, fname)
        } else {
          raise bad_arg_type(o.ty, 4, fname)
        }
      }
      // result precision: the larger of the two (captured: datetime2(0)
      // with a datetime2(1) origin is datetime2(1))
      ty = match (d.ty, o.ty) {
        (DateTime2(a), DateTime2(b)) => DateTime2(@cmp.maximum(a, b))
        (Time(a), Time(b)) => Time(@cmp.maximum(a, b))
        (DateTimeOffset(a), DateTimeOffset(b)) =>
          DateTimeOffset(@cmp.maximum(a, b))
        _ => d.ty
      }
      out.push(o)
    }
  }
  // dateparts that do not fit the type fail at compile time (captured:
  // hour on date, day/month on time); unsupported ones at run time
  let p = match part.kind {
    Lit(String(s)) => s
    _ => ""
  }
  let time_part = p is ("hour" | "minute" | "second" | "millisecond")
  let date_part = p is ("year" | "quarter" | "month" | "week" | "day")
  match d.ty {
    Date if time_part => raise date_bucket_part(p, d.ty)
    Time(_) if date_part => raise date_bucket_part(p, d.ty)
    _ => ()
  }
  Some(named("DATE_BUCKET", out, ty))
}

///|
fn date_bucket_part(p : String, t : @types.SqlType) -> @types.SqlError {
  err(
    9810,
    "The datepart \{p} is not supported by date function Date_Bucket for data type \{t.base_name()}.",
  )
}
