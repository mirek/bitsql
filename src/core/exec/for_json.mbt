///|
/// FOR JSON PATH / AUTO formatting (captured: harness/corpus/query/for-json).
/// The text is returned in rows of at most 2033 characters; an empty input
/// returns no rows.

///|
let json_chunk : Int = 2033

///|
priv enum JsonNode {
  Leaf(String)
  Obj(Array[(String, JsonNode)])
}

///|
fn json_escape(s : String, buf : StringBuilder) -> Unit {
  buf.write_char('"')
  for i in 0..<s.length() {
    let u = s.code_unit_at(i).to_int()
    match u {
      0x22 => buf.write_string("\\\"")
      0x5C => buf.write_string("\\\\")
      0x2F => buf.write_string("\\/")
      0x08 => buf.write_string("\\b")
      0x0C => buf.write_string("\\f")
      0x0A => buf.write_string("\\n")
      0x0D => buf.write_string("\\r")
      0x09 => buf.write_string("\\t")
      _ =>
        if u < 0x20 {
          let h = u.to_string(radix=16)
          buf.write_string("\\u")
          for _ in h.length()..<4 {
            buf.write_char('0')
          }
          buf.write_string(h)
        } else {
          buf.write_char(u.unsafe_to_char())
        }
    }
  }
  buf.write_char('"')
}

///|
let base64_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
fn base64(b : Bytes) -> String {
  let out = StringBuilder()
  let n = b.length()
  let mut i = 0
  while i < n {
    let b0 = b[i].to_int()
    let b1 = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    let b2 = if i + 2 < n { b[i + 2].to_int() } else { 0 }
    let triple = (b0 << 16) | (b1 << 8) | b2
    for k in 0..<4 {
      if i + k - 1 < n {
        out.write_char(
          base64_alphabet[(triple >> (18 - 6 * k)) & 63]
          .to_int()
          .unsafe_to_char(),
        )
      } else {
        out.write_char('=')
      }
    }
    i += 3
  }
  out.to_string()
}

///|
fn json_scalar(
  v : @types.Value,
  ty : @types.SqlType,
) -> String raise @types.SqlError {
  match v {
    // formatted as its base type (captured: variant/for-json.sql)
    Variant(inner, base) => json_scalar(inner, base)
    Bit(b) => if b { "true" } else { "false" }
    TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_) | Decimal(_) =>
      @types.render(v, ty, None)
    // captured (variant/for-json.sql): money with 4 decimals, real with 8
    // significant digits, float with 16
    Money(_) => @types.render(v, ty, Some(2))
    Float(_) => @types.render(v, ty, Some(if ty is Real { 1 } else { 2 }))
    Binary(b) =>
      // The base64 alphabet needs no JSON escaping; SQL Server leaves its
      // slash literal, unlike a slash in a character value.
      "\"" + base64(b) + "\""
    NativeJson(data) => data.text()
    String(s) => {
      let buf = StringBuilder()
      json_escape(s, buf)
      buf.to_string()
    }
    Date(_)
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_, _)
    | DateTime(_, _)
    | SmallDateTime(_, _) => {
      // Style 126 preserves the offset and declared nonzero fractions,
      // while omitting an all-zero fraction (including smalldatetime).
      let rendered = @types.render(v, ty, Some(126))
      let t = if v is DateTimeOffset(_, 0) {
        rendered[:rendered.length() - 6].to_owned() + "Z"
      } else {
        rendered
      }
      let buf = StringBuilder()
      json_escape(t, buf)
      buf.to_string()
    }
    _ => {
      let buf = StringBuilder()
      json_escape(@types.render(v, ty, None), buf)
      buf.to_string()
    }
  }
}

///|
fn json_insert(
  node : Array[(String, JsonNode)],
  path : Array[String],
  leaf : String,
) -> Unit {
  if path.length() == 1 {
    node.push((path[0], Leaf(leaf)))
    return
  }
  for entry in node {
    if entry.0 == path[0] && entry.1 is Obj(children) {
      json_insert(children, path[1:].to_owned(), leaf)
      return
    }
  }
  let children = []
  json_insert(children, path[1:].to_owned(), leaf)
  node.push((path[0], Obj(children)))
}

///|
fn json_write(node : Array[(String, JsonNode)], buf : StringBuilder) -> Unit {
  buf.write_char('{')
  for i, entry in node {
    if i > 0 {
      buf.write_char(',')
    }
    json_escape(entry.0, buf)
    buf.write_char(':')
    match entry.1 {
      Leaf(t) => buf.write_string(t)
      Obj(children) => json_write(children, buf)
    }
  }
  buf.write_char('}')
}

///|
/// One FOR JSON value: JSON text columns (`raw`) are embedded as is
/// (captured: msduck gaps-json_string#039/#044, unicode-json-storage
/// for-json-fragment).
fn json_cell(
  v : @types.Value,
  c : @ir.ResultColumn,
  raw : Bool,
) -> String raise @types.SqlError {
  match v {
    String(s) if raw => s
    _ => json_scalar(v, c.ty)
  }
}

///|
fn run_for_json(
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  root : String?,
  include_nulls : Bool,
  without_array_wrapper : Bool,
  shape : @ir.JsonShape,
) -> Array[Row] raise @types.SqlError {
  if rows.is_empty() {
    return []
  }
  let buf = StringBuilder()
  if root is Some(r) {
    buf.write_char('{')
    json_escape(r, buf)
    buf.write_char(':')
  }
  if !without_array_wrapper {
    buf.write_char('[')
  }
  let raw = (j : Int) => j < shape.raw.length() && shape.raw[j]
  if shape.levels.is_empty() {
    for i, row in rows {
      if i > 0 {
        buf.write_char(',')
      }
      let node = []
      for j, c in columns {
        let v = row[j]
        let text = if v is Null {
          if !include_nulls {
            continue
          }
          "null"
        } else {
          json_cell(v, c, raw(j))
        }
        json_insert(
          node,
          c.name.split(".").map(p => p.to_owned()).to_array(),
          text,
        )
      }
      json_write(node, buf)
    }
  } else {
    let top = auto_tree(rows, columns, shape)
    for i, n in top {
      if i > 0 {
        buf.write_char(',')
      }
      auto_write(n, 0, columns, shape, include_nulls, buf)
    }
  }
  if !without_array_wrapper {
    buf.write_char(']')
  }
  if root is Some(_) {
    buf.write_char('}')
  }
  let text = buf.to_string()
  let out : Array[Row] = []
  let mut start = 0
  while start < text.length() {
    let end = if start + json_chunk < text.length() {
      start + json_chunk
    } else {
      text.length()
    }
    out.push([String(text.unsafe_substring(start~, end~))])
    start = end
  }
  out
}

///|
/// A FOR JSON AUTO object: the row that opened it and the objects of the
/// next level nested in it.
priv struct AutoNode {
  row : Row
  children : Array[AutoNode]
}

///|
/// FOR JSON AUTO nesting (captured: msduck gaps-json_string#010-#046): one
/// level per source table in the order of its first selected column; a
/// row joins the previous object of a level when that level's values equal
/// the previous row's (consecutive rows only, source columns only, compared
/// under the column's collation), else it opens a new one. The deepest level
/// never merges.
fn auto_tree(
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  shape : @ir.JsonShape,
) -> Array[AutoNode] raise @types.SqlError {
  let depth = shape.names.length()
  let top : Array[AutoNode] = []
  for row in rows {
    let mut list = top
    for l in 0..<depth {
      let node = match list.last() {
        Some(prev) if l < depth - 1 &&
          same_level(prev.row, row, l, columns, shape) => prev
        _ => {
          let n : AutoNode = { row, children: [], }
          list.push(n)
          n
        }
      }
      list = node.children
    }
  }
  top
}

///|
fn same_level(
  a : Row,
  b : Row,
  level : Int,
  columns : Array[@ir.ResultColumn],
  shape : @ir.JsonShape,
) -> Bool raise @types.SqlError {
  for j, c in columns {
    if shape.levels[j] != level || !shape.keys[j] {
      continue
    }
    match (a[j], b[j]) {
      (Null, Null) => ()
      (Null, _) | (_, Null) => return false
      (x, y) => {
        let collation = c.ty.collation().unwrap_or(@types.default_collation)
        if @types.compare(x, y, collation~) != Some(0) {
          return false
        }
      }
    }
  }
  true
}

///|
fn auto_write(
  n : AutoNode,
  level : Int,
  columns : Array[@ir.ResultColumn],
  shape : @ir.JsonShape,
  include_nulls : Bool,
  buf : StringBuilder,
) -> Unit raise @types.SqlError {
  buf.write_char('{')
  let mut first = true
  for j, c in columns {
    if shape.levels[j] != level {
      continue
    }
    let v = n.row[j]
    if v is Null && !include_nulls {
      continue
    }
    if !first {
      buf.write_char(',')
    }
    first = false
    json_escape(c.name, buf)
    buf.write_char(':')
    if v is Null {
      buf.write_string("null")
    } else {
      buf.write_string(json_cell(v, c, j < shape.raw.length() && shape.raw[j]))
    }
  }
  if level + 1 < shape.names.length() {
    if !first {
      buf.write_char(',')
    }
    json_escape(shape.names[level + 1], buf)
    buf.write_string(":[")
    for i, child in n.children {
      if i > 0 {
        buf.write_char(',')
      }
      auto_write(child, level + 1, columns, shape, include_nulls, buf)
    }
    buf.write_char(']')
  }
  buf.write_char('}')
}
