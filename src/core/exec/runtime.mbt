///|
/// Error information visible to ERROR_xxx() inside a CATCH block.
pub(all) struct ErrorInfo {
  number : Int
  severity : Int
  state : Int
  message : String
  line : Int
  procedure : String?
} derive(Debug)

///|
/// Session state that expressions can observe. Owned by the session; the
/// executor reads it and never performs I/O.
pub(all) struct Runtime {
  mut rowcount : Int64
  mut error : Int
  mut trancount : Int
  mut xact_state : Int
  mut identity : @types.Value
  mut scope_identity : @types.Value
  mut fetch_status : Int
  mut cursor_rows : Int
  mut nest_level : Int
  mut catch_error : ErrorInfo?
  mut now : Int64 // 100 ns ticks since 0001-01-01 UTC
  mut rng : UInt64
  /// Set when an aggregate skipped a NULL input; the session turns it into
  /// INFO 8153 after the statement's rows, then clears it.
  mut null_eliminated : Bool
  /// Row count to report instead of the number of result rows (FOR JSON
  /// counts its input rows); the session reads and clears it.
  mut count_override : Int64?
  /// Recursive CTE work tables by plan id (exec/plan.mbt `Recursive`).
  work : Map[Int, Array[Array[@types.Value]]]
  /// RAND state (L'Ecuyer s1, s2); 0 until first use or RAND(seed).
  mut rand_s1 : Int64
  mut rand_s2 : Int64
  mut database : String
  spid : Int
  server_name : String
  version : String
}

///|
pub fn Runtime::new(
  database~ : String,
  spid~ : Int,
  now~ : Int64,
  seed~ : Int64,
  server_name? : String = "bitsql",
  version? : String = "Microsoft SQL Server 2025 (bitsql emulator)",
) -> Runtime {
  {
    rowcount: 0,
    error: 0,
    trancount: 0,
    xact_state: 0,
    identity: Null,
    scope_identity: Null,
    fetch_status: -1,
    cursor_rows: 0,
    nest_level: 0,
    catch_error: None,
    now,
    rng: seed.reinterpret_as_uint64() ^ 0x9E3779B97F4A7C15UL,
    null_eliminated: false,
    count_override: None,
    work: Map([]),
    rand_s1: 0L,
    rand_s2: 0L,
    database,
    spid,
    server_name,
    version,
  }
}

///|
/// SplitMix64: deterministic randomness from the engine seed (NEWID, RAND).
pub fn Runtime::next_random(self : Runtime) -> UInt64 {
  self.rng = self.rng + 0x9E3779B97F4A7C15UL
  let mut z = self.rng
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL
  z ^ (z >> 31)
}

///|
/// Evaluation context: variable slots, the current row and enclosing rows.
pub(all) struct Ctx {
  rt : Runtime
  vars : Array[@types.Value]
  row : Array[@types.Value]
  outer : Array[Array[@types.Value]] // innermost last
  /// Table rows by (scope, id), as (rowid, row) pairs. Supplied by the
  /// session from its current database view.
  source : (Int, Int) -> Array[(Int64, Array[@types.Value])]
  /// Session-provided functions that need the database (catalog/metadata
  /// functions). Returns None for names it does not implement.
  ext : (String, Array[@types.Value]) -> @types.Value? raise @types.SqlError
}

///|
pub fn Ctx::with_row(self : Ctx, row : Array[@types.Value]) -> Ctx {
  { ..self, row, }
}
