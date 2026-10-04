///|
/// Everything the host can tell the engine.
pub(all) enum Input {
  Connected(Int) // connection id
  Received(Int, Bytes) // raw TDS bytes, arbitrary chunking
  Closed(Int)
  TimerFired(Int) // lock timeout, query timeout
  Resume // continue a time-sliced long query
} derive(Debug, Eq)

///|
/// An input plus the host clock: 100 ns ticks since 0001-01-01 UTC (the
/// datetime2 epoch). The core never reads a clock of its own.
pub(all) struct Event {
  input : Input
  now : Int64
} derive(Debug, Eq)

///|
/// Everything the engine can ask the host to do.
pub(all) enum Output {
  Send(Int, Bytes)
  Close(Int)
  SetTimer(Int, Int) // timer id, milliseconds
  CancelTimer(Int)
  Yield // host re-sends Resume on its next turn
  Log(String)
  /// The client's next bytes are a TLS handshake carried in PRELOGIN
  /// packets; once it completes, the connection's traffic is TLS. Emitted
  /// before the PRELOGIN response, which still goes out in plaintext.
  StartTls(Int)
  /// Login-only encryption ends: from here on both directions are
  /// plaintext again (no close_notify). Emitted before the LOGIN7 response.
  EndTls(Int)
} derive(Debug, Eq)

///|
/// Unix epoch (1970-01-01) in 100 ns ticks since 0001-01-01.
pub const UNIX_EPOCH_TICKS : Int64 = 621355968000000000L

///|
pub(all) struct Config {
  server_name : String
  /// Reported in PRELOGIN and LOGINACK. Default matches the oracle image
  /// (SQL Server 2025, 17.0.5005; see harness skill).
  version : (Int, Int, Int)
  default_database : String
  /// Databases created at startup (host `--database NAME`).
  databases : Array[String]
  /// Create a database on first login instead of failing with 4060
  /// (host `--auto-create-databases`). Off by default: faithful.
  auto_create_databases : Bool
  /// Work units a request may use before failing with 50108 (host
  /// `--max-request-work`).
  max_request_work : Int64
  /// The host can run TLS (PRELOGIN encryption OFF/ON/REQ are honored).
  /// Without it, ON/REQ clients are closed and OFF is answered NOT_SUP.
  tls : Bool
} derive(Debug)

///|
pub fn Config::default() -> Config {
  {
    server_name: "bitsql",
    version: (17, 0, 5005),
    default_database: "master",
    databases: [],
    auto_create_databases: false,
    max_request_work: default_max_request_work,
    tls: true,
  }
}

///|
/// Default work budget per request (see `Runtime::charge` in core/exec).
pub let default_max_request_work : Int64 = 300_000_000L
