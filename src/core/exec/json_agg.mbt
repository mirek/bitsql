///|
/// JSON_ARRAYAGG / JSON_OBJECTAGG over a group (captured: msduck
/// json-aggregates). No input rows give NULL; otherwise every row adds
/// its value (formatted like JSON_ARRAY / JSON_OBJECT values, JSON text
/// raw), NULLs skipped under ABSENT ON NULL (the JSON_ARRAYAGG default)
/// without warning 8153: a group of only NULLs is `[]` / `{}`. A NULL key
/// is 13638. Rows follow the call's ORDER BY, or the scope's ordered
/// aggregate (see `@bind` scope_ordered_aggs).
fn eval_json_agg(
  ctx : Ctx,
  call : @ir.AggCall,
  rows : ArrayView[Row],
) -> @types.Value raise @types.SqlError {
  if rows.is_empty() {
    return Null
  }
  let (object, absent, raw, json) = match call.func {
    JsonObjectAgg(absent~, raw~, json~) => (true, absent, raw, json)
    JsonArrayAgg(absent~, raw~, json~) => (false, absent, raw, json)
    _ => (false, true, false, false)
  }
  let ordered = if call.order.is_empty() {
    rows.to_owned()
  } else {
    sort_rows_by(ctx, rows.to_owned(), r => r, call.order)
  }
  let arg = call.arg.unwrap()
  let buf = StringBuilder()
  buf.write_char(if object { '{' } else { '[' })
  let mut first = true
  for r in ordered {
    let rc = ctx.with_row(r)
    let key = if object {
      let k = call.separator.unwrap()
      match eval(rc, k) {
        Null =>
          raise @types.sql_error(
            13638, "User error : Name parameter value in 'json_object' cannot be null",
          )
        String(s) => Some(s)
        other => Some(@types.render(other, k.ty, None))
      }
    } else {
      None
    }
    let v = eval(rc, arg)
    if v is Null && absent {
      continue
    }
    if !first {
      buf.write_char(',')
    }
    first = false
    if key is Some(k) {
      buf.write_string(@json.quote(k))
      buf.write_char(':')
    }
    match v {
      Null => buf.write_string("null")
      String(s) if raw => buf.write_string(s)
      _ => buf.write_string(json_ctor_value(v, arg.ty))
    }
  }
  buf.write_char(if object { '}' } else { ']' })
  if json {
    String(@types.json_type_normalize(buf.to_string()))
  } else {
    String(buf.to_string())
  }
}
