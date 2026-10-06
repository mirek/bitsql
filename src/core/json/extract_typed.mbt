///|
/// Typed JSON_VALUE uses native accessors without nvarchar(4000)'s length cap.
pub fn json_value_typed(
  doc : String,
  path : String,
) -> OpenJsonRow? raise JsonError {
  let p = parse_path(path, native=true)
  let rows = match contains_values(doc, path, ordered=true) {
    None => {
      if p.strict {
        raise JsonError(13608, 5, MISSING_MESSAGE)
      }
      return None
    }
    Some(rows) => rows
  }
  if rows.is_empty() {
    if p.strict {
      raise JsonError(13608, 5, MISSING_MESSAGE)
    }
    return None
  }
  match rows {
    [row] if row.ty < 4 => if row.ty == 0 { None } else { Some(row) }
    _ => {
      if p.strict {
        raise JsonError(13623, 2, SCALAR_MESSAGE)
      }
      None
    }
  }
}

///|
fn json_query_array(
  doc : String,
  path : String,
  lob : Bool,
  native : Bool,
) -> String? raise JsonError {
  let p = parse_path(path, native~)
  let st = states(lob, native)
  let parts : Array[String] = []
  if native {
    match contains_values(doc, path, ordered=true) {
      None => {
        if p.strict {
          raise JsonError(13608, st.missing, MISSING_MESSAGE)
        }
        return None
      }
      Some(rows) =>
        for row in rows {
          parts.push(
            match (row.ty, row.value) {
              (0, _) => "null"
              (1, Some(text)) => quote(text)
              (_, Some(text)) => text
              _ => "null"
            },
          )
        }
    }
  } else {
    let hits = match select_all(doc, p, st.doc, lob~) {
      NullHit => return None
      Hits(hits) => hits
    }
    if hits.is_empty() {
      if p.strict {
        raise JsonError(13608, st.missing, MISSING_MESSAGE)
      }
      return None
    }
    for hit in hits {
      if hit.kind is Null {
        return None
      }
      parts.push(doc.unsafe_substring(start=hit.start, end=hit.end))
    }
  }
  Some("[" + parts.join(",") + "]")
}
