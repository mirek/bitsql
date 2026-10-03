///|
/// An XML error: a SQL Server error (number, state, message; severity 16)
/// or an XML/XQuery feature the emulator does not implement.
pub(all) suberror XmlError {
  Sql(Int, Int, String)
  Unsupported(String)
} derive(Debug, Eq)

///|
fn parse_error(number : Int, s : String, at : Int, text : String) -> XmlError {
  // "line L, character C": C counts UTF-16 units from the line start,
  // 1-based (captured: xml/type)
  let mut line = 1
  let mut start = 0
  let end = if at > s.length() { s.length() } else { at }
  for i in 0..<end {
    if s.code_unit_at(i).to_int() == 0x0A {
      line += 1
      start = i + 1
    }
  }
  Sql(
    number,
    1,
    "XML parsing: line \{line}, character \{at + 1 - start}, \{text}",
  )
}
