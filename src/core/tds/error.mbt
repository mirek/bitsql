///|
/// Malformed wire input. The message names what was wrong; the session turns
/// it into a protocol error and closes the connection.
pub(all) suberror TdsError {
  Malformed(String)
} derive(Debug)

///|
pub fn TdsError::message(self : TdsError) -> String {
  match self {
    Malformed(m) => m
  }
}
