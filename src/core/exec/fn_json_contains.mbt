///|
fn json_contains(
  v : Array[@types.Value],
  args : Array[@ir.Expr],
) -> @types.Value raise @types.SqlError {
  if v[2] is Null {
    raise @types.sql_error(
      8116,
      "Argument data type NULL is invalid for argument 2 of JSON_CONTAINS function.",
      state=8,
    )
  }
  if v[0] is Null {
    return Null
  }
  let mode = match v[3] {
    Int(n) => n
    _ => 0
  }
  if mode != 0 && mode != 1 {
    raise @types.sql_error(
      13692, "The comparison_mode argument of JSON_CONTAINS must be 0 or 1.",
    )
  }
  guard v[0] is NativeJson(data) && v[2] is String(path) else {
    raise @types.not_supported("JSON_CONTAINS argument representation")
  }
  data.validate_path(path)
  data.validate_raw_path(path)
  let selections = match
    json(() => @json.contains_values(data.navigation_text(), path)) {
    None => return Null
    Some(values) => values
  }
  for selected in selections {
    let matched = match (selected.ty, selected.value, v[1]) {
      (1, Some(text), String(search)) => {
        let coll = args[1].ty.collation().unwrap_or(@types.default_collation)
        if mode == 1 {
          like_match(text, search, None, coll, false)
        } else {
          @types.compare_strings(text, search, coll) == 0
        }
      }
      (3, Some(text), Bit(b)) => (text == "true") == b
      (2, Some(text), TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_) | Decimal(_)
      ) =>
        match @types.Decimal::parse(text[:]) {
          Some(d) => @types.compare(Decimal(d), v[1]) == Some(0)
          None => false
        }
      _ => false
    }
    if matched {
      return Int(1)
    }
  }
  Int(0)
}
