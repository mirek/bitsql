// The xml data type: conversions to and from character and binary types
// (captured: harness/corpus/xml/type; docs/reference/xml.md). Parsing,
// serialization and XQuery live in core/xml.

///|
/// SQL error for an XML parse/XQuery error (or the emulator error for an
/// unsupported XML feature).
pub fn xml_error(e : @xml.XmlError) -> SqlError {
  match e {
    Sql(n, state, m) => sql_error(n, m, state~)
    Unsupported(what) => not_supported(what, number=EMU_XML_NOT_SUPPORTED)
  }
}

///|
/// Parses an xml value from text (CONVERT style 1 keeps insignificant
/// whitespace).
pub fn parse_xml(s : String, preserve? : Bool = false) -> Value raise SqlError {
  Xml(@xml.parse(s, preserve~)) catch {
    e => raise xml_error(e)
  }
}

///|
/// Binary to text for xml: UTF-16LE with a byte order mark, otherwise
/// UTF-8 (an EF BB BF mark is skipped).
fn xml_bytes_text(b : Bytes) -> String raise SqlError {
  let n = b.length()
  if n >= 2 && b[0] == b'\xFF' && b[1] == b'\xFE' {
    return utf16le_string(b[2:].to_owned())
  }
  if n >= 2 && b[0] == b'\xFE' && b[1] == b'\xFF' {
    raise not_supported(
      "big-endian UTF-16 xml input",
      number=EMU_XML_NOT_SUPPORTED,
    )
  }
  let start = if n >= 3 && b[0] == b'\xEF' && b[1] == b'\xBB' && b[2] == b'\xBF' {
    3
  } else {
    0
  }
  let sb = StringBuilder()
  let mut i = start
  while i < n {
    let c = b[i].to_int()
    let (cp, len) = if c < 0x80 {
      (c, 1)
    } else if c >= 0xC0 && c < 0xE0 && i + 1 < n {
      (((c & 0x1F) << 6) | (b[i + 1].to_int() & 0x3F), 2)
    } else if c >= 0xE0 && c < 0xF0 && i + 2 < n {
      (
        ((c & 0x0F) << 12) |
        ((b[i + 1].to_int() & 0x3F) << 6) |
        (b[i + 2].to_int() & 0x3F),
        3,
      )
    } else if c >= 0xF0 && i + 3 < n {
      (
        ((c & 0x07) << 18) |
        ((b[i + 1].to_int() & 0x3F) << 12) |
        ((b[i + 2].to_int() & 0x3F) << 6) |
        (b[i + 3].to_int() & 0x3F),
        4,
      )
    } else {
      raise not_supported(
        "invalid UTF-8 xml input",
        number=EMU_XML_NOT_SUPPORTED,
      )
    }
    if cp >= 0x10000 {
      let u = cp - 0x10000
      sb.write_char((0xD800 + (u >> 10)).unsafe_to_char())
      sb.write_char((0xDC00 + (u & 0x3FF)).unsafe_to_char())
    } else {
      sb.write_char(cp.unsafe_to_char())
    }
    i += len
  }
  sb.to_string()
}

///|
/// CAST/CONVERT with xml on either side (called by `cast`).
fn cast_xml(
  v : Value,
  from : SqlType,
  to : SqlType,
  style : Int?,
) -> Value raise SqlError {
  let style = style.unwrap_or(0)
  if to is Xml && style != 0 && style != 1 {
    raise not_supported(
      "CONVERT to xml with style \{style}",
      number=EMU_XML_NOT_SUPPORTED,
    )
  }
  match (v, to) {
    (Null, _) => Null
    (Xml(_), Xml) => v
    (String(s), Xml) => parse_xml(s, preserve=style == 1)
    (Binary(b), Xml) => parse_xml(xml_bytes_text(b), preserve=style == 1)
    (Xml(x), _) => {
      let text = x.to_text()
      match to.family() {
        FString => {
          let text = if to.is_unicode() {
            text
          } else {
            to_code_page(text, to.collation().unwrap_or(default_collation))
          }
          match char_capacity(to) {
            // captured: no truncation, 6354 state 10
            Some(cap) if text.length() > cap =>
              raise sql_error(
                6354,
                "Target string size is too small to represent the XML instance",
                state=10,
              )
            _ => ()
          }
          match to {
            Char(n, _) | NChar(n, _) if text.length() < n =>
              String(text + String::make(n - text.length(), ' '))
            _ => String(text)
          }
        }
        FBinary => {
          // captured: UTF-16LE with a byte order mark
          let body = utf16le_bytes(text)
          let out = Bytes::makei(body.length() + 2, i => {
            if i == 0 {
              b'\xFF'
            } else if i == 1 {
              b'\xFE'
            } else {
              body[i - 2]
            }
          })
          match to {
            Binary(n) | VarBinary(Some(n)) if out.length() > n =>
              raise sql_error(
                6354,
                "Target string size is too small to represent the XML instance",
                state=10,
              )
            _ => ()
          }
          Binary(out)
        }
        _ => raise explicit_conversion_error(from, to)
      }
    }
    _ => raise internal("xml cast of \{from.to_sql()} to \{to.to_sql()}")
  }
}
