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
    Bit(b) => if b { "true" } else { "false" }
    TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_) | Decimal(_) | Money(_) =>
      @types.render(v, ty, None)
    Float(_) => @types.render(v, ty, Some(2))
    Binary(b) => {
      let buf = StringBuilder()
      json_escape(base64(b), buf)
      buf.to_string()
    }
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
      // ISO 8601: style 121 with 'T' and no space before the offset
      let t = @types.render(v, ty, Some(121))
      let sb = StringBuilder()
      let mut first = true
      for i in 0..<t.length() {
        let c = t.code_unit_at(i).to_int()
        if c == 0x20 {
          if first && !(v is Time(_)) {
            sb.write_char('T')
          }
          first = false
        } else {
          sb.write_char(c.unsafe_to_char())
        }
      }
      let buf = StringBuilder()
      json_escape(sb.to_string(), buf)
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
fn run_for_json(
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  root : String?,
  include_nulls : Bool,
  without_array_wrapper : Bool,
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
        json_scalar(v, c.ty)
      }
      json_insert(
        node,
        c.name.split(".").map(p => p.to_owned()).to_array(),
        text,
      )
    }
    json_write(node, buf)
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
