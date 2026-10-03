///|
/// JSON_VALUE(doc, path): scalar as text (nvarchar(4000)), or None (NULL).
pub fn json_value(doc : String, path : String) -> String? raise JsonError {
  let p = parse_path(path)
  match select(doc, p, 1) {
    None =>
      if p.strict {
        raise JsonError(13608, 1, MISSING_MESSAGE)
      } else {
        None
      }
    Some(hit) =>
      if hit.kind is (Object | Array) {
        if p.strict {
          raise JsonError(13623, 2, SCALAR_MESSAGE)
        } else {
          None
        }
      } else {
        match scalar_text(doc, hit) {
          Some(t) if t.length() > 4000 =>
            if p.strict {
              raise JsonError(13625, 1, TRUNCATED_MESSAGE)
            } else {
              None
            }
          other => other
        }
      }
  }
}

///|
/// JSON_QUERY(doc [, path]): the original object/array fragment, or None.
pub fn json_query(
  doc : String,
  path? : String = "$",
) -> String? raise JsonError {
  let p = parse_path(path)
  match select(doc, p, 1) {
    None =>
      if p.strict {
        raise JsonError(13608, 1, MISSING_MESSAGE)
      } else {
        None
      }
    Some(hit) =>
      if hit.kind is (Object | Array) {
        Some(doc.unsafe_substring(start=hit.start, end=hit.end))
      } else if p.strict {
        raise JsonError(13624, 2, CONTAINER_MESSAGE)
      } else {
        None
      }
  }
}

///|
pub(all) enum IsJsonType {
  Default // object or array
  Value
  Array
  Object
  Scalar // string or number
} derive(Debug, Eq)

///|
/// ISJSON(doc [, type]): 1 or 0. Raises 13606 for a value nested deeper than
/// 128 containers (SQL Server raises rather than returning 0).
pub fn isjson(doc : String, ty? : IsJsonType = Default) -> Int raise JsonError {
  let s : Scanner = { text: doc, pos: 0, doc_state: 1, }
  s.ws()
  let kind = s.skip_value(0) catch {
    JsonError(13606, _, _) as e => raise e
    _ => return 0
  }
  s.ws()
  if s.pos < doc.length() {
    return 0
  }
  let ok = match ty {
    Default => kind is (Object | Array)
    Value => true
    Array => kind is Array
    Object => kind is Object
    Scalar => kind is (String | Number)
  }
  if ok {
    1
  } else {
    0
  }
}

///|
/// One row of OPENJSON's default schema.
pub(all) struct OpenJsonRow {
  key : String // nvarchar(4000)
  value : String? // nvarchar(max)
  ty : Int // 0 null .. 5 object
} derive(Debug, Eq)

///|
/// OPENJSON(doc [, path]) with the default schema. Validates the whole
/// document (unlike JSON_VALUE). A missing lax path or a scalar selection
/// yields no rows.
pub fn openjson(
  doc : String,
  path? : String = "$",
) -> Array[OpenJsonRow] raise JsonError {
  let p = parse_path(path, state=22)
  validate_document(doc, 4)
  let hit = match select(doc, p, 4) {
    None =>
      if p.strict {
        raise JsonError(13608, 3, MISSING_MESSAGE)
      } else {
        return []
      }
    Some(h) => h
  }
  let rows = []
  guard hit.kind is (Object | Array) else { return rows }
  let s : Scanner = { text: doc, pos: hit.start + 1, doc_state: 4, }
  s.ws()
  let close = if hit.kind is Object { 0x7D } else { 0x5D }
  let mut idx = 0
  while s.peek() != close {
    let key = if hit.kind is Object {
      let k = s.string_value()
      s.ws()
      s.expect(0x3A)
      s.ws()
      k
    } else {
      idx.to_string()
    }
    let start = s.pos
    let kind = s.skip_value(0)
    let h : Hit = { start, end: s.pos, kind, }
    let value = if kind is (Object | Array) {
      Some(doc.unsafe_substring(start~, end=s.pos))
    } else {
      scalar_text(doc, h)
    }
    rows.push({ key, value, ty: kind.code(), })
    idx += 1
    s.ws()
    if s.peek() == 0x2C {
      s.pos += 1
      s.ws()
    }
  }
  rows
}
