// SQL Server's canonical text form of an xml value (captured: harness
// corpus xml/type): empty elements as `<a/>`, attributes in double quotes,
// `&amp; &lt; &gt;` in text, CR as `&#x0D;`, and a whitespace-only text
// node with its last character as a character reference (so the
// whitespace survives a re-parse).

///|
fn hex2(c : Int) -> String {
  let digits = "0123456789ABCDEF"
  let sb = StringBuilder()
  let h = c.to_string(radix=16).to_upper()
  if h.length() < 2 {
    sb.write_char('0')
  }
  ignore(digits)
  sb.write_string(h)
  sb.to_string()
}

///|
/// Escapes element text (FOR XML and xml serialization): `& < >` as
/// entities, CR and other control characters as `&#xHH;`.
pub fn escape_text(s : String, buf : StringBuilder) -> Unit {
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    match c {
      0x26 => buf.write_string("&amp;")
      0x3C => buf.write_string("&lt;")
      0x3E => buf.write_string("&gt;")
      0x0A | 0x09 => buf.write_char(c.unsafe_to_char())
      _ =>
        if c < 0x20 {
          buf.write_string("&#x" + hex2(c) + ";")
        } else {
          buf.write_char(c.unsafe_to_char())
        }
    }
  }
}

///|
/// Escapes an attribute value: `& < > "` as entities, CR, LF, TAB and other
/// control characters as `&#xHH;`; `'` stays.
pub fn escape_attr(s : String, buf : StringBuilder) -> Unit {
  for i in 0..<s.length() {
    let c = s.code_unit_at(i).to_int()
    match c {
      0x26 => buf.write_string("&amp;")
      0x3C => buf.write_string("&lt;")
      0x3E => buf.write_string("&gt;")
      0x22 => buf.write_string("&quot;")
      _ =>
        if c < 0x20 {
          buf.write_string("&#x" + hex2(c) + ";")
        } else {
          buf.write_char(c.unsafe_to_char())
        }
    }
  }
}

///|
fn all_ws(s : String) -> Bool {
  for i in 0..<s.length() {
    if !is_ws(s.code_unit_at(i).to_int()) {
      return false
    }
  }
  true
}

///|
fn write_text_node(s : String, buf : StringBuilder) -> Unit {
  // a CR is written as a character reference anyway, which already keeps
  // the node significant (captured: xml/type#005)
  if s.length() > 0 && all_ws(s) && !s.contains("\r") {
    let last = s.length() - 1
    escape_text(s.unsafe_substring(start=0, end=last), buf)
    buf.write_string("&#x" + hex2(s.code_unit_at(last).to_int()) + ";")
  } else {
    escape_text(s, buf)
  }
}

///|
pub fn write_node(n : Node, buf : StringBuilder) -> Unit {
  match n {
    Text(s) => write_text_node(s, buf)
    Comment(s) => {
      buf.write_string("<!--")
      buf.write_string(s)
      buf.write_string("-->")
    }
    Pi(t, d) => {
      buf.write_string("<?")
      buf.write_string(t)
      if d != "" {
        buf.write_char(' ')
        buf.write_string(d)
      }
      buf.write_string("?>")
    }
    Element(name, attrs, children) => {
      buf.write_char('<')
      buf.write_string(name.text())
      for a in attrs {
        buf.write_char(' ')
        buf.write_string(a.name.text())
        buf.write_string("=\"")
        escape_attr(a.value, buf)
        buf.write_char('"')
      }
      if children.is_empty() {
        buf.write_string("/>")
      } else {
        buf.write_char('>')
        for c in children {
          write_node(c, buf)
        }
        buf.write_string("</")
        buf.write_string(name.text())
        buf.write_char('>')
      }
    }
  }
}

///|
/// The text form of an xml value (a document; context references
/// serialize their whole document).
pub fn Xml::to_text(self : Xml) -> String {
  let buf = StringBuilder()
  for n in self.nodes {
    write_node(n, buf)
  }
  buf.to_string()
}

///|
pub impl Show for Xml with fn output(self, logger) {
  logger.write_string(self.to_text())
}
