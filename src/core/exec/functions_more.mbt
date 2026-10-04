///|
/// Executor hook for `Fn::Named` functions (see bind/functions_more.mbt).
/// `v` holds the evaluated arguments, `args` their bound expressions (types),
/// `e` the call itself (result type).
fn call_more(
  ctx : Ctx,
  name : String,
  v : Array[@types.Value],
  args : Array[@ir.Expr],
  e : @ir.Expr,
) -> @types.Value raise @types.SqlError {
  if name == "ROWCOUNT_BIG" {
    return BigInt(ctx.rt.rowcount)
  }
  if name is ("CONVERT_STYLE" | "TRY_CONVERT_STYLE") {
    let style = match v[1] {
      // captured: a NULL style gives NULL
      Null => return Null
      x =>
        match x.as_int64() {
          Some(n) => Some(n.to_int())
          None => raise @types.not_supported("CONVERT with a non-integer style")
        }
    }
    return if name == "TRY_CONVERT_STYLE" {
      @types.try_cast(v[0], args[0].ty, e.ty, style?)
    } else {
      @types.cast(v[0], args[0].ty, e.ty, style?)
    }
  }
  if call_date(name, v, args, e, datefirst=ctx.rt.datefirst) is Some(r) {
    return r
  }
  if call_string(name, v, args, e) is Some(r) {
    return r
  }
  if call_math(ctx, name, v, args, e) is Some(r) {
    return r
  }
  if call_json2(name, v, args) is Some(r) {
    return r
  }
  if name == "DATE_BUCKET" {
    return date_bucket(v, args, e)
  }
  if name == "FORMAT" {
    return format_value(ctx, v, args)
  }
  if name == "PARSE" {
    return parse_call(v, args, e)
  }
  if name == "AT TIME ZONE" {
    return at_time_zone(v, args, e)
  }
  if call_misc(name, v, args, e) is Some(r) {
    return r
  }
  if call_variant(ctx, name, v) is Some(r) {
    return r
  }
  if call_xml_method(name, v, args, e) is Some(r) {
    return r
  }
  raise @types.not_supported("function \{name}")
}
