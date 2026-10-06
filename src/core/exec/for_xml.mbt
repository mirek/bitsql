///|
/// FOR XML RAW / AUTO / PATH formatting (captured: harness/corpus/xml/path,
/// raw-auto, subquery; docs/reference/xml.md). Column names were validated
/// and classified by the binder (bind/for_xml.mbt); this file only renders.

///|
let xsi_decl : String = " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""

///|
/// How a PATH column contributes to its row (from its alias).
priv enum Leaf {
  /// `name` / `a/b`: an element (the last of `elems`) holding the value
  LElem
  /// `@a`, `x/@a`
  LAttr(String)
  /// `text()`
  LText
  /// `data()`: atomic values separated by a space
  LData
  /// unnamed, `*`, `node()`: inline (xml values unescaped)
  LInline
  LComment
  /// `processing-instruction(name)`
  LPi(String)
}

///|
priv struct PathCol {
  elems : Array[String]
  leaf : Leaf
}

///|
/// Splits a validated PATH column name (bind/for_xml.mbt checked it).
fn path_col(name : String) -> PathCol {
  match name {
    "" | "*" | "node()" => { elems: [], leaf: LInline, }
    "text()" => { elems: [], leaf: LText, }
    "data()" => { elems: [], leaf: LData, }
    "comment()" => { elems: [], leaf: LComment, }
    _ => {
      if name.has_prefix("processing-instruction(") {
        let target = name.unsafe_substring(start=23, end=name.length() - 1)
        return { elems: [], leaf: LPi(target), }
      }
      let parts = name.split("/").map(p => p.to_owned()).to_array()
      let last = parts[parts.length() - 1]
      let elems = parts[0:parts.length() - 1].to_owned()
      let leaf : Leaf = if last.has_prefix("@") {
        LAttr(last.unsafe_substring(start=1, end=last.length()))
      } else {
        match last {
          "text()" => LText
          "data()" => LData
          "*" | "node()" => LInline
          "comment()" => LComment
          _ => {
            elems.push(last)
            LElem
          }
        }
      }
      { elems, leaf, }
    }
  }
}

///|
/// A column value as XML: text to escape, or an xml value to inline.
priv enum XVal {
  XText(String)
  XNodes(@xml.Xml)
}

///|
fn strip_zero_fraction(t : String) -> String {
  // `hh:mm:ss.000…` → `hh:mm:ss` (the fraction is the digits after the
  // last '.', up to a space or the end)
  match t.rev_find(".") {
    None => t
    Some(i) => {
      let mut j = i + 1
      let mut zero = true
      while j < t.length() {
        let c = t.code_unit_at(j).to_int()
        if c < 0x30 || c > 0x39 {
          break
        }
        if c != 0x30 {
          zero = false
        }
        j += 1
      }
      if zero {
        t.unsafe_substring(start=0, end=i) +
        t.unsafe_substring(start=j, end=t.length())
      } else {
        t
      }
    }
  }
}

///|
/// ISO 8601 as FOR XML writes date/time values (captured: xml/path):
/// 'T' separator, the fraction only when non-zero (with the type's scale),
/// `Z` for a zero offset.
fn xml_temporal(
  v : @types.Value,
  ty : @types.SqlType,
) -> String raise @types.SqlError {
  let t = strip_zero_fraction(@types.render(v, ty, Some(121)))
  let sb = StringBuilder()
  let mut first = true
  for i in 0..<t.length() {
    let c = t.code_unit_at(i).to_int()
    if c == 0x20 {
      if first && !(v is Time(_)) {
        sb.write_char('T')
        first = false
      }
      // the space before a datetimeoffset offset is dropped
    } else {
      sb.write_char(c.unsafe_to_char())
    }
  }
  let s = sb.to_string()
  if v is DateTimeOffset(_, 0) && s.has_suffix("+00:00") {
    s.unsafe_substring(start=0, end=s.length() - 6) + "Z"
  } else {
    s
  }
}

///|
fn xml_value(
  v : @types.Value,
  ty : @types.SqlType,
) -> XVal raise @types.SqlError {
  match v {
    Vector(_) => raise @types.not_supported("FOR XML serialization of vectors")
    Variant(inner, base) => xml_value(inner, base)
    Xml(x) => XNodes(x)
    String(s) => XText(s)
    Bit(b) => XText(if b { "1" } else { "0" })
    TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_) | Decimal(_) | Guid(_) =>
      XText(@types.render(v, ty, None))
    // captured: money with 4 decimals, float 16 / real 8 significant digits
    Money(_) => XText(@types.render(v, ty, Some(2)))
    Float(_) =>
      XText(@types.render(v, ty, Some(if ty is Real { 1 } else { 2 })))
    Binary(b) => XText(base64(b))
    Date(_)
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_, _)
    | DateTime(_, _)
    | SmallDateTime(_, _) => XText(xml_temporal(v, ty))
    Null => XText("")
  }
}

///|
/// Element content text: like xml serialization, a whitespace-only value
/// writes its last character as a reference (captured: xml/path#041).
fn write_xml_text(s : String, buf : StringBuilder) -> Unit {
  @xml.write_node(Text(s), buf)
}

///|
fn write_xval(x : XVal, buf : StringBuilder) -> Unit {
  match x {
    XText(s) => write_xml_text(s, buf)
    XNodes(x) =>
      for n in x.nodes {
        @xml.write_node(n, buf)
      }
  }
}

///|
fn xval_text(x : XVal) -> String {
  match x {
    XText(s) => s
    XNodes(x) => x.to_text()
  }
}

///|
/// XML name for RAW/AUTO: characters not allowed in names are written as
/// `_xHHHH_` (captured: `my col` → `my_x0020_col`, `1x` → `_x0031_x`).
pub fn encode_xml_name(s : String) -> String {
  let sb = StringBuilder()
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    let ok = if i == 0 { @xml.is_name_start(c) } else { @xml.is_name_char(c) }
    if ok {
      sb.write_char(c.unsafe_to_char())
    } else {
      let h = c.to_string(radix=16).to_upper()
      sb.write_string("_x")
      for _ in h.length()..<4 {
        sb.write_char('0')
      }
      sb.write_string(h)
      sb.write_char('_')
    }
  }
  sb.to_string()
}

///|
/// One open element of the PATH writer.
priv struct Open {
  name : String
  /// start tag still open (attributes may follow)
  mut pending : Bool
}

///|
priv struct XWriter {
  buf : StringBuilder
  stack : Array[Open]
}

///|
fn XWriter::seal(self : XWriter) -> Unit {
  match self.stack.last() {
    Some(o) if o.pending => {
      self.buf.write_char('>')
      o.pending = false
    }
    _ => ()
  }
}

///|
fn XWriter::open(self : XWriter, name : String, extra : String) -> Unit {
  self.seal()
  self.buf.write_char('<')
  self.buf.write_string(name)
  self.buf.write_string(extra)
  self.stack.push({ name, pending: true, })
}

///|
fn XWriter::close(self : XWriter) -> Unit {
  match self.stack.pop() {
    Some(o) =>
      if o.pending {
        self.buf.write_string("/>")
      } else {
        self.buf.write_string("</")
        self.buf.write_string(o.name)
        self.buf.write_char('>')
      }
    None => ()
  }
}

///|
fn XWriter::attr(self : XWriter, name : String, value : String) -> Unit {
  self.buf.write_char(' ')
  self.buf.write_string(name)
  self.buf.write_string("=\"")
  @xml.escape_attr(value, self.buf)
  self.buf.write_char('"')
}

///|
fn run_for_xml_text(
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  spec : @ir.ForXmlSpec,
) -> String raise @types.SqlError {
  let w : XWriter = { buf: StringBuilder(), stack: [], }
  let root_ns = spec.xsinil && spec.root is Some(_)
  match spec.root {
    Some(r) => w.open(r, if root_ns { xsi_decl } else { "" })
    None => ()
  }
  // namespace declaration on the elements directly below the root
  let row_ns = if spec.xsinil && !root_ns { xsi_decl } else { "" }
  match spec.mode {
    XmlPath => path_rows(w, rows, columns, spec, row_ns)
    XmlRaw => raw_rows(w, rows, columns, spec, row_ns)
    XmlAuto => auto_rows(w, rows, columns, spec, row_ns)
  }
  while !w.stack.is_empty() {
    w.close()
  }
  w.buf.to_string()
}

///|
fn path_rows(
  w : XWriter,
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  spec : @ir.ForXmlSpec,
  row_ns : String,
) -> Unit raise @types.SqlError {
  let cols = columns.map(c => path_col(c.name))
  let base = w.stack.length()
  for row in rows {
    if spec.row != "" {
      w.open(spec.row, row_ns)
    }
    let level = w.stack.length()
    // element names opened below the row element
    let mut prev_data = false
    for j, pc in cols {
      let v = row[j]
      let nil = v is Null
      if nil && !(spec.xsinil && pc.leaf is LElem) {
        continue
      }
      // align the open elements with this column's element path
      let mut common = 0
      while common < pc.elems.length() &&
            level + common < w.stack.length() &&
            w.stack[level + common].name == pc.elems[common] {
        common += 1
      }
      while w.stack.length() > level + common {
        w.close()
      }
      for k in common..<pc.elems.length() {
        let ns = if spec.row == "" && k == 0 && w.stack.length() == base {
          row_ns
        } else {
          ""
        }
        w.open(pc.elems[k], ns)
      }
      if nil {
        // ELEMENTS XSINIL: an empty element marked nil
        if w.stack.last() is Some(o) && o.pending {
          w.buf.write_string(" xsi:nil=\"true\"")
          w.close()
        }
        prev_data = false
        continue
      }
      let x = xml_value(v, columns[j].ty)
      match pc.leaf {
        LAttr(a) => w.attr(a, xval_text(x))
        LElem | LText | LInline => {
          w.seal()
          write_xval(x, w.buf)
        }
        LData => {
          w.seal()
          if prev_data {
            w.buf.write_char(' ')
          }
          write_xval(x, w.buf)
        }
        LComment => {
          w.seal()
          w.buf.write_string("<!--")
          w.buf.write_string(xval_text(x))
          w.buf.write_string("-->")
        }
        LPi(t) => {
          w.seal()
          w.buf.write_string("<?")
          w.buf.write_string(t)
          w.buf.write_char(' ')
          w.buf.write_string(xval_text(x))
          w.buf.write_string("?>")
        }
      }
      if pc.leaf is LElem {
        // an element's content: it stays open so a following column with
        // the same path continues it (captured: x, x → <x>ab</x>)
        ()
      }
      prev_data = pc.leaf is LData
    }
    while w.stack.length() > base {
      w.close()
    }
  }
}

///|
fn raw_rows(
  w : XWriter,
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  spec : @ir.ForXmlSpec,
  row_ns : String,
) -> Unit raise @types.SqlError {
  let names = columns.map(c => encode_xml_name(c.name))
  let base = w.stack.length()
  for row in rows {
    if spec.row != "" {
      w.open(spec.row, row_ns)
    }
    if spec.elements {
      element_values(
        w,
        row,
        columns,
        names,
        Array::makei(columns.length(), i => i),
        spec.xsinil,
        if spec.row == "" {
          row_ns
        } else {
          ""
        },
      )
    } else {
      attribute_values(
        w,
        row,
        columns,
        names,
        Array::makei(columns.length(), i => i),
      )
    }
    while w.stack.length() > base {
      w.close()
    }
  }
}

///|
/// Attribute-centric values of `idx`: attributes first, then xml-typed
/// values as sub-elements (captured: xml/raw-auto#025).
fn attribute_values(
  w : XWriter,
  row : Row,
  columns : Array[@ir.ResultColumn],
  names : Array[String],
  idx : Array[Int],
) -> Unit raise @types.SqlError {
  for j in idx {
    if row[j] is Null || columns[j].ty is Xml {
      continue
    }
    w.attr(names[j], xval_text(xml_value(row[j], columns[j].ty)))
  }
  for j in idx {
    if row[j] is Xml(x) {
      w.open(names[j], "")
      w.seal()
      write_xval(XNodes(x), w.buf)
      w.close()
    }
  }
}

///|
/// Element-centric values of `idx` (ELEMENTS): one element per non-NULL
/// value, unnamed values inline, NULLs omitted or nil (XSINIL).
fn element_values(
  w : XWriter,
  row : Row,
  columns : Array[@ir.ResultColumn],
  names : Array[String],
  idx : Array[Int],
  xsinil : Bool,
  ns : String,
) -> Unit raise @types.SqlError {
  for j in idx {
    let v = row[j]
    if v is Null {
      if xsinil && names[j] != "" {
        w.open(names[j], ns)
        w.buf.write_string(" xsi:nil=\"true\"")
        w.close()
      }
      continue
    }
    let x = xml_value(v, columns[j].ty)
    if names[j] == "" {
      w.seal()
      write_xval(x, w.buf)
    } else {
      w.open(names[j], ns)
      w.seal()
      write_xval(x, w.buf)
      // `<x></x>` for an empty string (captured: xml/raw-auto#023)
      w.close()
    }
  }
}

///|
fn auto_rows(
  w : XWriter,
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  spec : @ir.ForXmlSpec,
  row_ns : String,
) -> Unit raise @types.SqlError {
  let names = columns.map(c => encode_xml_name(c.name))
  let levels = spec.auto_names.length()
  let by_level : Array[Array[Int]] = Array::makei(levels, _ => [])
  for j, l in spec.auto_levels {
    by_level[l].push(j)
  }
  let base = w.stack.length()
  // the row whose values the open element of each level shows
  let open_rows : Array[Row?] = []
  for row in rows {
    // first level whose values differ from the open element's
    let mut k = 0
    while k < open_rows.length() {
      match open_rows[k] {
        Some(prev) if by_level[k].iter().all(j => same_value(prev[j], row[j])) =>
          k += 1
        _ => break
      }
    }
    while open_rows.length() > k {
      ignore(open_rows.pop())
      w.close()
    }
    for l in k..<levels {
      let ns = if w.stack.length() == base { row_ns } else { "" }
      w.open(spec.auto_names[l], ns)
      if spec.elements {
        element_values(w, row, columns, names, by_level[l], spec.xsinil, "")
      } else {
        attribute_values(w, row, columns, names, by_level[l])
      }
      open_rows.push(Some(row))
    }
  }
  while w.stack.length() > base {
    w.close()
  }
}

///|
fn same_value(a : @types.Value, b : @types.Value) -> Bool {
  a == b
}

///|
/// The FOR XML plan: the text, chunked for the top-level text form, or a
/// single value.
fn run_for_xml(
  rows : Array[Row],
  columns : Array[@ir.ResultColumn],
  spec : @ir.ForXmlSpec,
  chunked : Bool,
) -> Array[Row] raise @types.SqlError {
  if rows.is_empty() {
    // captured: a top-level TYPE result is one NULL row; text has no rows;
    // a subquery has no row (NULL)
    return if spec.type_ && spec.top_level { [[Null]] } else { [] }
  }
  let text = run_for_xml_text(rows, columns, spec)
  if spec.type_ {
    // the generated text has no insignificant whitespace: parse preserving
    return [[@types.parse_xml(text, preserve=true)]]
  }
  if !chunked {
    return [[String(text)]]
  }
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
