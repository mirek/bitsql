///|
/// Native OPENJSON has distinct root and WITH-column selection contracts.
fn native_openjson_row(
  doc : String,
  path : String,
  column : Bool,
) -> OpenJsonRow? raise JsonError {
  let p = parse_path(path, native=true)
  let reversed = p.steps.any(s => {
    match s {
      Elements(ranges) => ranges.any(r => r.0 < 0L && r.1 >= 0L)
      _ => false
    }
  })
  let reversed_zero = p.steps.any(s => {
    match s {
      Elements(ranges) => ranges.any(r => r.0 < 0L && r.1 == 0L)
      _ => false
    }
  })
  if reversed && (!column || (p.strict && reversed_zero)) {
    raise JsonError(13660, 1, ADVANCED_REVERSED)
  }
  if reversed ||
    p.steps.any(s => {
      match s {
        AnyKey | AnyIndex | Range(_, _) => true
        Elements(ranges) => ranges.any(r => r.0 != r.1)
        _ => false
      }
    }) {
    raise JsonError(
      13665,
      if column {
        3
      } else {
        5
      },
      "OpenJson support with complex path parameters not yet supported for JSON native data type.",
    )
  }
  let rows = contains_values(doc, path, ordered=true).unwrap_or([])
  if rows.is_empty() || (column && rows[0].ty == 0) {
    if p.strict {
      raise JsonError(13608, if column { 8 } else { 7 }, MISSING_MESSAGE)
    }
    return None
  }
  if !column && (rows.length() != 1 || rows[0].ty < 4) {
    if p.strict {
      raise JsonError(
        13611, 3, "Value referenced by JSON path is not an array or object and cannot be opened with OPENJSON.",
      )
    }
    return None
  }
  Some(rows[0])
}

///|
pub fn openjson_fragment(
  doc : String,
  path : String,
) -> String? raise JsonError {
  match native_openjson_row(doc, path, false) {
    Some(row) => row.value
    None => None
  }
}

///|
pub fn openjson_column(
  doc : String,
  path : String,
  as_json : Bool,
) -> String? raise JsonError {
  guard native_openjson_row(doc, path, true) is Some(row) else { return None }
  if (row.ty >= 4) != as_json {
    if parse_path(path, native=true).strict {
      raise JsonError(13624, 5, CONTAINER_MESSAGE)
    }
    return None
  }
  row.value
}
