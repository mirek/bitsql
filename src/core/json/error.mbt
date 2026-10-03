///|
/// A SQL Server JSON error: number, state, message (severity is always 16).
pub(all) suberror JsonError {
  JsonError(Int, Int, String)
} derive(Debug, Eq)

///|
pub fn JsonError::number(self : JsonError) -> Int {
  match self {
    JsonError(n, _, _) => n
  }
}

///|
pub fn JsonError::message(self : JsonError) -> String {
  match self {
    JsonError(_, _, m) => m
  }
}

///|
pub const MISSING_MESSAGE : String = "Property cannot be found on the specified JSON path."

///|
pub const SCALAR_MESSAGE : String = "Scalar value cannot be found in the specified JSON path."

///|
pub const CONTAINER_MESSAGE : String = "Object or array cannot be found in the specified JSON path."

///|
pub const TRUNCATED_MESSAGE : String = "String value in the specified JSON path would be truncated."

///|
pub const DEPTH_MESSAGE : String = "JSON text/path that has more than 128 nesting levels cannot be parsed."

///|
/// "Unexpected character 'c' is found at position N." where N is the 0-based
/// UTF-16 index and end of input reads as '.' (captured from SQL Server).
fn unexpected(what : String, text : String, pos : Int) -> String {
  let c = if pos < text.length() {
    text.code_unit_at(pos).to_int().unsafe_to_char().to_string()
  } else {
    "."
  }
  "JSON \{what} is not properly formatted. Unexpected character '\{c}' is found at position \{pos}."
}
