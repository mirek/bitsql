///|
/// Malformed wire input. The message names what was wrong; the session turns
/// it into a protocol error and closes the connection.
pub(all) suberror TdsError {
  Malformed(String)
  /// A request SQL Server rejects with an error while keeping the
  /// connection: (number, state, message), e.g. 4002 for an RPC whose PLP
  /// value runs past the end of the message, 8016 for a parameter
  /// TYPE_INFO with an invalid length. The session answers ERROR + DONE and
  /// rolls back an open transaction (captured, corpus orm/rpc-stream-errors).
  RpcStream(Int, Int, String)
} derive(Debug)

///|
pub fn TdsError::message(self : TdsError) -> String {
  match self {
    Malformed(m) => m
    RpcStream(n, _, m) => "\{n}: \{m}"
  }
}
