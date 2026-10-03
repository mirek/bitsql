// XML text → tree, as SQL Server's CAST/CONVERT to untyped xml does it:
// fragments (several top-level nodes, text) are allowed, the XML
// declaration is dropped, CDATA becomes text, entities and character
// references are expanded, end-of-line and attribute-value normalization
// apply, and whitespace-only text nodes are dropped unless `preserve`
// (CONVERT style 1) or xml:space="preserve" is in effect. Error numbers and
// "line L, character C" positions follow captures (harness corpus xml/type).

///|
priv struct Parser {
  s : String
  mut pos : Int
}

///|
fn Parser::eof(self : Parser) -> Bool {
  self.pos >= self.s.length()
}

///|
fn Parser::peek(self : Parser) -> Int {
  if self.pos < self.s.length() {
    self.s.code_unit_at(self.pos).to_int()
  } else {
    -1
  }
}

///|
fn Parser::peek_at(self : Parser, k : Int) -> Int {
  let i = self.pos + k
  if i < self.s.length() {
    self.s.code_unit_at(i).to_int()
  } else {
    -1
  }
}

///|
fn Parser::starts(self : Parser, lit : String) -> Bool {
  if self.pos + lit.length() > self.s.length() {
    return false
  }
  for i in 0..<lit.length() {
    if self.s.code_unit_at(self.pos + i) != lit.code_unit_at(i) {
      return false
    }
  }
  true
}

///|
fn Parser::fail(
  self : Parser,
  number : Int,
  at : Int,
  text : String,
) -> XmlError {
  parse_error(number, self.s, at, text)
}

///|
fn Parser::eoi(self : Parser) -> XmlError {
  self.fail(9400, self.s.length() - 1, "unexpected end of input")
}

///|
fn is_ws(c : Int) -> Bool {
  c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
}

///|
/// XML name start character (approximation: ASCII letters, '_', ':' and
/// every non-ASCII character except the few excluded ranges).
pub fn is_name_start(c : Int) -> Bool {
  (c >= 0x41 && c <= 0x5A) ||
  (c >= 0x61 && c <= 0x7A) ||
  c == 0x5F ||
  c == 0x3A ||
  (c >= 0xC0 && c != 0xD7 && c != 0xF7 && !(c >= 0x2000 && c <= 0x206F))
}

///|
pub fn is_name_char(c : Int) -> Bool {
  is_name_start(c) ||
  (c >= 0x30 && c <= 0x39) ||
  c == 0x2E ||
  c == 0x2D ||
  c == 0xB7
}

///|
/// Characters allowed in XML 1.0 documents (surrogates are allowed in
/// pairs; lone surrogates are not checked).
fn is_xml_char(c : Int) -> Bool {
  c == 0x09 ||
  c == 0x0A ||
  c == 0x0D ||
  (c >= 0x20 && c != 0xFFFE && c != 0xFFFF)
}

///|
fn Parser::skip_ws(self : Parser) -> Bool {
  let start = self.pos
  while !self.eof() && is_ws(self.peek()) {
    self.pos += 1
  }
  self.pos > start
}

///|
fn Parser::name(self : Parser) -> String raise XmlError {
  if self.eof() {
    raise self.eoi()
  }
  if !is_name_start(self.peek()) {
    raise self.fail(9421, self.pos, "illegal name character")
  }
  let start = self.pos
  while !self.eof() && is_name_char(self.peek()) {
    self.pos += 1
  }
  self.s.unsafe_substring(start~, end=self.pos)
}

///|
fn split_qname(n : String) -> (String, String) {
  match n.find(":") {
    Some(i) =>
      (
        n.unsafe_substring(start=0, end=i),
        n.unsafe_substring(start=i + 1, end=n.length()),
      )
    None => ("", n)
  }
}

///|
/// Parses an untyped xml value. `preserve` keeps whitespace-only text
/// (CONVERT(xml, s, 1)).
pub fn parse(s : String, preserve? : Bool = false) -> Xml raise XmlError {
  let p : Parser = { s, pos: 0, }
  if p.peek() == 0xFEFF {
    p.pos += 1
  }
  if p.starts("<?xml") && (is_ws(p.peek_at(5)) || p.peek_at(5) == 0x3F) {
    p.xml_decl()
  }
  let scopes : Array[Map[String, String]] = [Map([("xml", xml_ns), ("", "")])]
  let nodes = p.content(None, scopes, preserve)
  Xml::of_nodes(nodes)
}

///|
fn Parser::xml_decl(self : Parser) -> Unit raise XmlError {
  let start = self.pos
  while !self.starts("?>") {
    if self.eof() {
      raise self.eoi()
    }
    self.pos += 1
  }
  let decl = self.s.unsafe_substring(start~, end=self.pos).to_lower()
  self.pos += 2
  match decl.find("encoding") {
    Some(i) => {
      let rest = decl.unsafe_substring(start=i, end=decl.length())
      if !(rest.contains("utf-16") || rest.contains("ucs-2")) {
        // captured: an nvarchar string declaring a single-byte encoding
        raise Sql(
          9402,
          1,
          "XML parsing: line 1, character \{self.pos}, unable to switch the encoding",
        )
      }
    }
    None => ()
  }
}

///|
fn lookup_ns(scopes : Array[Map[String, String]], prefix : String) -> String? {
  let mut i = scopes.length() - 1
  while i >= 0 {
    match scopes[i].get(prefix) {
      Some(u) => return Some(u)
      None => ()
    }
    i -= 1
  }
  None
}

///|
/// Content up to the end tag of `open` (or end of input at top level).
fn Parser::content(
  self : Parser,
  open : String?,
  scopes : Array[Map[String, String]],
  preserve : Bool,
) -> Array[Node] raise XmlError {
  let out : Array[Node] = []
  let text = StringBuilder()
  let mut has_text = false
  let mut significant = false
  fn flush() {
    if has_text {
      if significant || preserve {
        out.push(Text(text.to_string()))
      }
      text.reset()
      has_text = false
      significant = false
    }
  }

  while true {
    if self.eof() {
      if open is Some(_) {
        raise self.eoi()
      }
      flush()
      // top level: leading/trailing whitespace is never kept
      if !preserve {
        return out
      }
      return out
    }
    let c = self.peek()
    if c == 0x3C {
      if self.peek_at(1) == 0x2F {
        // end tag
        match open {
          None =>
            raise self.fail(9430, self.pos + 1, "incorrect document syntax")
          Some(name) => {
            self.pos += 2
            let n = self.name()
            self.skip_ws() |> ignore
            if self.eof() {
              raise self.eoi()
            }
            if self.peek() != 0x3E {
              raise self.fail(9412, self.pos, "'>' expected")
            }
            self.pos += 1
            if n != name {
              raise self.fail(
                9436,
                self.pos - 1,
                "end tag does not match start tag",
              )
            }
            flush()
            return out
          }
        }
      } else if self.starts("<!--") {
        flush()
        self.pos += 4
        let start = self.pos
        while !self.starts("-->") {
          if self.eof() {
            raise self.eoi()
          }
          if self.starts("--") {
            // captured: `--` must end the comment (9412 at the next char)
            raise self.fail(9412, self.pos + 2, "'>' expected")
          }
          self.pos += 1
        }
        out.push(Comment(self.s.unsafe_substring(start~, end=self.pos)))
        self.pos += 3
      } else if self.starts("<![CDATA[") {
        self.pos += 9
        let start = self.pos
        while !self.starts("]]>") {
          if self.eof() {
            raise self.eoi()
          }
          self.pos += 1
        }
        let raw = self.s.unsafe_substring(start~, end=self.pos)
        self.pos += 3
        append_eol(text, raw)
        has_text = true
        if raw.length() > 0 {
          significant = true
        }
      } else if self.starts("<!DOCTYPE") {
        // captured: xml/type#067
        raise Sql(
          6359, 1, "Parsing XML with internal subset DTDs not allowed. Use CONVERT with style option 2 to enable limited internal subset DTD support.",
        )
      } else if self.starts("<!") {
        raise self.fail(9430, self.pos + 1, "incorrect document syntax")
      } else if self.starts("<?") {
        flush()
        self.pos += 2
        let target = self.name()
        if target.to_lower() == "xml" {
          raise self.fail(
            9438,
            self.pos - 1,
            "text/xmldecl not at the beginning of input",
          )
        }
        let has_ws = self.skip_ws()
        let start = self.pos
        while !self.starts("?>") {
          if self.eof() {
            raise self.eoi()
          }
          if !has_ws {
            raise self.fail(9410, self.pos, "whitespace expected")
          }
          self.pos += 1
        }
        out.push(Pi(target, self.s.unsafe_substring(start~, end=self.pos)))
        self.pos += 2
      } else {
        flush()
        out.push(self.element(scopes, preserve))
      }
    } else if c == 0x26 {
      let (ch, _) = self.reference()
      text.write_string(ch)
      has_text = true
      significant = true
    } else {
      // character data
      if !is_xml_char(c) {
        raise self.fail(9420, self.pos, "illegal xml character")
      }
      if c == 0x0D {
        text.write_char('\n')
        if self.peek_at(1) == 0x0A {
          self.pos += 1
        }
      } else {
        text.write_char(c.unsafe_to_char())
        if !is_ws(c) {
          significant = true
        }
      }
      has_text = true
      self.pos += 1
    }
  }
  out
}

///|
/// CR LF and lone CR become LF.
fn append_eol(sb : StringBuilder, raw : String) -> Unit {
  let n = raw.length()
  let mut i = 0
  while i < n {
    let c = raw.code_unit_at(i).to_int()
    if c == 0x0D {
      sb.write_char('\n')
      if i + 1 < n && raw.code_unit_at(i + 1).to_int() == 0x0A {
        i += 1
      }
    } else {
      sb.write_char(c.unsafe_to_char())
    }
    i += 1
  }
}

///|
/// `&...;` at the current position: the replacement text and whether it
/// was a character reference.
fn Parser::reference(self : Parser) -> (String, Bool) raise XmlError {
  self.pos += 1
  if self.peek() == 0x23 {
    self.pos += 1
    let hex = self.peek() == 0x78
    if hex {
      self.pos += 1
    }
    let mut v = 0
    let mut digits = 0
    while true {
      let c = self.peek()
      if c == -1 {
        raise self.eoi()
      }
      if c == 0x3B {
        break
      }
      let d = if c >= 0x30 && c <= 0x39 {
        c - 0x30
      } else if hex && c >= 0x61 && c <= 0x66 {
        c - 0x61 + 10
      } else if hex && c >= 0x41 && c <= 0x46 {
        c - 0x41 + 10
      } else {
        raise self.fail(9411, self.pos, "semicolon expected")
      }
      v = v * (if hex { 16 } else { 10 }) + d
      if v > 0x10FFFF {
        v = 0x110000
      }
      digits += 1
      self.pos += 1
    }
    self.pos += 1
    if digits == 0 || !is_xml_char(v) || v > 0x10FFFF {
      raise self.fail(9420, self.pos - 1, "illegal xml character")
    }
    let sb = StringBuilder()
    if v >= 0x10000 {
      let u = v - 0x10000
      sb.write_char((0xD800 + (u >> 10)).unsafe_to_char())
      sb.write_char((0xDC00 + (u & 0x3FF)).unsafe_to_char())
    } else {
      sb.write_char(v.unsafe_to_char())
    }
    return (sb.to_string(), true)
  }
  let n = self.name()
  if self.peek() != 0x3B {
    if self.eof() {
      raise self.eoi()
    }
    raise self.fail(9411, self.pos, "semicolon expected")
  }
  self.pos += 1
  let r = match n {
    "lt" => "<"
    "gt" => ">"
    "amp" => "&"
    "quot" => "\""
    "apos" => "'"
    _ =>
      raise self.fail(
        9448,
        self.pos - 1,
        "well formed check: undeclared entity",
      )
  }
  (r, false)
}

///|
fn Parser::element(
  self : Parser,
  scopes : Array[Map[String, String]],
  preserve : Bool,
) -> Node raise XmlError {
  self.pos += 1
  let tag = self.name()
  let raw : Array[(String, String, Int)] = []
  let mut empty = false
  while true {
    let had_ws = self.skip_ws()
    if self.eof() {
      raise self.eoi()
    }
    let c = self.peek()
    if c == 0x3E {
      self.pos += 1
      break
    }
    if c == 0x2F {
      self.pos += 1
      if self.eof() {
        raise self.eoi()
      }
      if self.peek() != 0x3E {
        raise self.fail(9412, self.pos, "'>' expected")
      }
      self.pos += 1
      empty = true
      break
    }
    if !had_ws {
      raise self.fail(9410, self.pos, "whitespace expected")
    }
    let at = self.pos
    let an = self.name()
    self.skip_ws() |> ignore
    if self.eof() {
      raise self.eoi()
    }
    if self.peek() != 0x3D {
      raise self.fail(
        9409,
        self.pos,
        "missing equals sign between attribute and attribute value",
      )
    }
    self.pos += 1
    self.skip_ws() |> ignore
    if self.eof() {
      raise self.eoi()
    }
    let q = self.peek()
    if q != 0x22 && q != 0x27 {
      raise self.fail(9413, self.pos, "A string literal was expected")
    }
    self.pos += 1
    let v = StringBuilder()
    while true {
      if self.eof() {
        raise self.eoi()
      }
      let ch = self.peek()
      if ch == q {
        self.pos += 1
        break
      }
      if ch == 0x3C {
        raise self.fail(9420, self.pos, "illegal xml character")
      }
      if ch == 0x26 {
        let (r, _) = self.reference()
        v.write_string(r)
        continue
      }
      if !is_xml_char(ch) {
        raise self.fail(9420, self.pos, "illegal xml character")
      }
      if ch == 0x0D {
        v.write_char(' ')
        if self.peek_at(1) == 0x0A {
          self.pos += 1
        }
      } else if ch == 0x0A || ch == 0x09 {
        v.write_char(' ')
      } else {
        v.write_char(ch.unsafe_to_char())
      }
      self.pos += 1
    }
    raw.push((an, v.to_string(), at))
  }
  let tag_end = self.pos - 1
  // duplicates (by name as written), detected at the end of the start tag
  for i in 0..<raw.length() {
    for j in 0..<i {
      if raw[i].0 == raw[j].0 {
        raise self.fail(9437, tag_end, "duplicate attribute")
      }
    }
  }
  // namespace declarations of this element
  let scope : Map[String, String] = Map([])
  for a in raw {
    if a.0 == "xmlns" {
      scope.set("", a.1)
    } else if a.0.has_prefix("xmlns:") {
      scope.set(a.0.unsafe_substring(start=6, end=a.0.length()), a.1)
    }
  }
  scopes.push(scope)
  let (prefix, lname) = split_qname(tag)
  let ns = match lookup_ns(scopes, prefix) {
    Some(u) => u
    None => raise self.fail(9459, tag_end, "undeclared prefix")
  }
  let attrs : Array[Attr] = []
  let mut keep = preserve
  for a in raw {
    let (ap, al) = split_qname(a.0)
    let ans = if a.0 == "xmlns" || ap == "xmlns" {
      xmlns_ns
    } else if ap == "" {
      ""
    } else {
      match lookup_ns(scopes, ap) {
        Some(u) => u
        None => raise self.fail(9459, tag_end, "undeclared prefix")
      }
    }
    if ap == "xml" && al == "space" {
      keep = a.1 == "preserve" || (a.1 != "default" && preserve)
    }
    attrs.push({ name: { prefix: ap, lname: al, ns: ans, }, value: a.1, })
  }
  let children = if empty { [] } else { self.content(Some(tag), scopes, keep) }
  scopes.pop() |> ignore
  Element({ prefix, lname, ns, }, attrs, children)
}
