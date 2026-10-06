///|
/// Error states that depend on the argument: SQL Server reports different
/// states for a max (LOB) document (captured json3 probes: 13609/13608
/// state 1 for nvarchar(n) and literals, 2 for nvarchar(max)/varchar(max);
/// 13623/13624 the other way round; 13624 for several values 3 / 4).
priv struct States {
  doc : Int
  missing : Int
  scalar : Int
  container : Int
  many : Int
}

///|
fn states(lob : Bool, json_type : Bool) -> States {
  // json-type documents (captured json4/type-functions): 13608 state 5,
  // 13623/13624 state 2, several values 13623/13624 state 2
  if json_type {
    { doc: 1, missing: 5, scalar: 2, container: 2, many: 2, }
  } else if lob {
    { doc: 2, missing: 2, scalar: 1, container: 1, many: 4, }
  } else {
    { doc: 1, missing: 1, scalar: 2, container: 2, many: 3, }
  }
}

///|
/// The single value a multi-value path selected, or the error/NULL it
/// yields (captured: msduck json-extraction-wildcard, json-advanced-path).
/// A JSON null anywhere among the values is NULL even under strict; no
/// value, or a value of the wrong kind, is 13608 under strict; several
/// values are 13608 (JSON_VALUE) or 13624 (JSON_QUERY).
fn multi_hit(
  doc : String,
  p : Path,
  st : States,
  value : Bool,
  lob : Bool,
  json_type : Bool,
) -> Hit? raise JsonError {
  let hits = match select_all(doc, p, st.doc, lob~) {
    NullHit => return None
    Hits(h) => h
  }
  let wanted = (h : Hit) => {
    if value {
      !(h.kind is (Object | Array))
    } else {
      h.kind is (Object | Array)
    }
  }
  match hits {
    [h] if wanted(h) => Some(h)
    [_, _, ..] if p.strict && json_type =>
      if value {
        raise JsonError(13623, st.many, SCALAR_MESSAGE)
      } else {
        raise JsonError(13624, st.many, CONTAINER_MESSAGE)
      }
    [_, _, ..] if p.strict =>
      if value {
        raise JsonError(13608, st.missing, MISSING_MESSAGE)
      } else {
        raise JsonError(13624, st.many, CONTAINER_MESSAGE)
      }
    _ if p.strict => raise JsonError(13608, st.missing, MISSING_MESSAGE)
    _ => None
  }
}

///|
/// JSON_VALUE(doc, path): scalar as text (nvarchar(4000)), or None (NULL).
/// `lob` tells whether the document argument is a max type.
pub fn json_value(
  doc : String,
  path : String,
  lob? : Bool = false,
  json_type? : Bool = false,
) -> String? raise JsonError {
  let p = parse_path(path)
  let st = states(lob, json_type)
  let hit = if p.is_multi() {
    match multi_hit(doc, p, st, true, lob, json_type) {
      Some(h) => h
      None => return None
    }
  } else {
    match select(doc, p, st.doc, lob~) {
      None =>
        if p.strict {
          raise JsonError(13608, st.missing, MISSING_MESSAGE)
        } else {
          return None
        }
      Some(hit) =>
        if hit.kind is (Object | Array) {
          if p.strict {
            raise JsonError(13623, st.scalar, SCALAR_MESSAGE)
          } else {
            return None
          }
        } else {
          hit
        }
    }
  }
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

///|
/// JSON_QUERY(doc [, path]): the original object/array fragment, or None.
pub fn json_query(
  doc : String,
  path? : String = "$",
  lob? : Bool = false,
  json_type? : Bool = false,
) -> String? raise JsonError {
  let p = parse_path(path)
  let st = states(lob, json_type)
  if p.is_multi() {
    return multi_hit(doc, p, st, false, lob, json_type).map(h => {
      doc.unsafe_substring(start=h.start, end=h.end)
    })
  }
  match select(doc, p, st.doc, lob~) {
    None =>
      if p.strict {
        raise JsonError(13608, st.missing, MISSING_MESSAGE)
      } else {
        None
      }
    Some(hit) =>
      if hit.kind is (Object | Array) {
        Some(doc.unsafe_substring(start=hit.start, end=hit.end))
      } else if hit.kind is Null {
        // captured: JSON_QUERY('[null]', 'strict $[0]') is NULL
        None
      } else if p.strict {
        raise JsonError(13624, st.container, CONTAINER_MESSAGE)
      } else {
        None
      }
  }
}

///|
/// JSON_PATH_EXISTS(doc, path): 1 when the path reaches a value (also a
/// JSON null), 0 when it does not or when the document is not a valid
/// JSON object or array (captured json3 probes: `{"a":1,"b":x}` with `$.a`
/// is 0). Nesting deeper than 128 still raises 13606. Strict and lax agree.
pub fn json_path_exists(
  doc : String,
  path : String,
  native? : Bool = false,
) -> Int raise JsonError {
  if native {
    return if contains_values(doc, path) is Some(_) { 1 } else { 0 }
  }
  let p = { ..parse_path(path), strict: false, }
  let s : Scanner = { text: doc, pos: 0, doc_state: 1, }
  s.ws()
  if !(s.peek() is (0x7B | 0x5B)) {
    return 0
  }
  let valid = try {
    ignore(s.skip_value(0))
    s.ws()
    s.pos == doc.length()
  } catch {
    JsonError(13606, _, _) as e => raise e
    _ => false
  }
  if !valid {
    return 0
  }
  let found = if p.is_multi() {
    match select_all(doc, p, 1) {
      NullHit => true
      Hits(h) => !h.is_empty()
    }
  } else {
    select(doc, p, 1) is Some(_)
  }
  if found {
    1
  } else {
    0
  }
}

///|
/// The kind code (0 null .. 5 object) of the single value a lax path
/// selects, or None (OPENJSON WITH json columns parse only strings).
pub fn json_value_kind(doc : String, path : String) -> Int? raise JsonError {
  let p = parse_path(path)
  if p.is_multi() {
    return None
  }
  select(doc, { ..p, strict: false, }, 1).map(h => h.kind.code())
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
  json_type? : Bool = false,
) -> Array[OpenJsonRow] raise JsonError {
  let p = parse_path(path)
  if p.is_multi() {
    raise JsonError(
      13660, 2, "OpenJson with default schema not yet supported for advanced JSON array accessors.",
    )
  }
  // captured (harness/corpus/query/table-functions, probes): the root must
  // be an object or array (a scalar fails at its first character) and text
  // after the root value is ignored
  let s : Scanner = { text: doc, pos: 0, doc_state: 4, }
  s.ws()
  if !(s.peek() is (0x7B | 0x5B)) {
    raise s.fail()
  }
  ignore(s.skip_value(0))
  let hit = match select(doc, p, 4) {
    None =>
      if p.strict {
        // json-type documents report state 7 (captured json4)
        raise JsonError(13608, if json_type { 7 } else { 3 }, MISSING_MESSAGE)
      } else {
        return []
      }
    Some(h) => h
  }
  let rows = []
  // captured (json4): a strict path to a scalar is 13611 (state 3 for a
  // json-type document)
  if p.strict && !(hit.kind is (Object | Array)) {
    raise JsonError(
      13611,
      if json_type {
        3
      } else {
        1
      },
      "Value referenced by JSON path is not an array or object and cannot be opened with OPENJSON.",
    )
  }
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
