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
  /// The current statement reads data or metadata (FROM, IDENT_CURRENT,
  /// OBJECT_ID): in autocommit its own transaction is active, so
  /// XACT_STATE() is 1 while @@TRANCOUNT is 0 (captured: msduck
  /// identity-insert-*, session-reset, gaps-merge).
  mut stmt_reads : Bool
  /// The current statement modifies data (INSERT/UPDATE/DELETE/MERGE,
  /// SELECT INTO): @@TRANCOUNT reads one more than the open transactions,
  /// counting autocommit as one (captured: stmts/trigger-trancount).
  mut stmt_dml : Bool
  mut identity : @types.Value
  mut scope_identity : @types.Value
  mut fetch_status : Int
  mut cursor_rows : Int
  mut nest_level : Int
  mut catch_error : ErrorInfo?
  mut now : Int64 // 100 ns ticks since 0001-01-01 UTC
  // Run-length encoded clock evaluations retained across request replay.
  clock_reads : Array[(Int, Int64)]
  mut clock_seen : Int
  mut clock_count : Int
  mut clock_cursor : Int
  mut record_clock : Bool
  mut rng : UInt64
  /// An interrupted external expression finishes its current row before unwind.
  mut cancel_pending : Bool
  mut cancel_null_warning : Bool
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
  /// SET DATEFIRST (1 = Monday … 7 = Sunday).
  mut datefirst : Int
  /// SET DATEFORMAT and SET LANGUAGE (string ↔ date/time conversions,
  /// month and day names).
  mut dates : @types.DateSettings
  /// SET LOCK_TIMEOUT (milliseconds, -1 = wait forever).
  mut lock_timeout : Int
  /// @@OPTIONS bits that change: 512 NOCOUNT, 16384 XACT_ABORT.
  mut option_bits : Int
  /// Work done by the current request (rows filtered, join pairs, loop
  /// iterations) and its limit (`charge`).
  mut work_done : Int64
  /// Counts rows whose expressions are evaluated; repeated NEXT VALUE FOR of
  /// one sequence within a row share a value (`Runtime::next_row`).
  mut row_seq : Int64
  mut work_limit : Int64
  spid : Int
  server_name : String
  version : String
  /// Product version (major, minor, build) reported by SERVERPROPERTY.
  build : (Int, Int, Int)
  /// Statement caches: memoized uncorrelated subqueries and lookup indexes
  /// (exec/memo.mbt); `clear_caches` at every statement start.
  memo : Memo
}

///|
pub fn Runtime::new(
  database~ : String,
  spid~ : Int,
  now~ : Int64,
  seed~ : Int64,
  server_name? : String = "bitsql",
  version? : String = "Microsoft SQL Server 2025 (bitsql emulator \{bitsql_version})",
  build? : (Int, Int, Int) = (17, 0, 5005),
) -> Runtime {
  {
    rowcount: 0,
    error: 0,
    trancount: 0,
    xact_state: 0,
    stmt_reads: false,
    stmt_dml: false,
    identity: Null,
    scope_identity: Null,
    fetch_status: 0,
    cursor_rows: 0,
    nest_level: 0,
    catch_error: None,
    now,
    clock_reads: [],
    clock_seen: 0,
    clock_count: 0,
    clock_cursor: 0,
    record_clock: false,
    rng: seed.reinterpret_as_uint64() ^ 0x9E3779B97F4A7C15UL,
    cancel_pending: false,
    cancel_null_warning: false,
    null_eliminated: false,
    count_override: None,
    work: Map([]),
    rand_s1: 0L,
    rand_s2: 0L,
    database,
    datefirst: 7,
    dates: @types.default_date_settings,
    lock_timeout: -1,
    option_bits: 0,
    work_done: 0L,
    row_seq: 0L,
    work_limit: default_work_limit,
    spid,
    server_name,
    version,
    build,
    memo: Memo::new(),
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
  /// Present only for explicitly requested diagnostics.
  profile : QueryProfile?
  rt : Runtime
  vars : Array[@types.Value]
  row : Array[@types.Value]
  outer : Array[Array[@types.Value]] // innermost last
  /// Table rows by (scope, id), as (rowid, row) pairs. Supplied by the
  /// session from its current database view.
  source : (Int, Int) -> Array[(Int64, Array[@types.Value])]
  /// Called before consuming each scan row, including rows later filtered
  /// out. Catalog row locks can suspend or time out at this exact position.
  scan_row : (Int, Int, Int64) -> Unit raise @types.SqlError
  /// Session-provided functions that need the database (catalog/metadata
  /// functions). Returns None for names it does not implement.
  ext : (String, Array[@types.Value]) -> @types.Value? raise @types.SqlError
  /// Scalar user-defined function call (object id, converted arguments):
  /// the session runs the body in a frame of its own.
  user_fn : (Int, Array[@types.Value]) -> @types.Value raise @types.SqlError
  /// Multi-statement table-valued function call: the rows of its return
  /// table after the body ran.
  user_table : (Int, Array[@types.Value]) -> Array[Array[@types.Value]] raise @types.SqlError
  /// Index lookup: rows of table (scope, id) whose columns equal the given
  /// (column ordinal, value) pairs, possibly more (the caller re-applies its
  /// predicate), in row id order; None when no index applies (the caller
  /// scans). See `seek_rows` in plan.mbt.
  seek : (Int, Int, Array[(Int, @types.Value)]) -> Array[
    (Int64, Array[@types.Value]),
  ]?
  /// JSON index path candidates, with the full predicate applied afterward.
  seek_json : (Int, Int, Int, String) -> Array[(Int64, Array[@types.Value])]?
  /// Data version of table (scope, id): equal stamps identify the same
  /// immutable table data; None when the table's rows cannot be
  /// tracked (catalog views), which disables statement caches for it.
  vector_search : (Int, Int, Int, @types.VectorData, Int64, Int64, Int64) -> Array[
    Row,
  ] raise @types.SqlError
  stamp : (Int, Int) -> Int64?
}

///|
/// `seek` for contexts without a database: always scan.
pub fn no_seek(
  _scope : Int,
  _id : Int,
  _key : Array[(Int, @types.Value)],
) -> Array[(Int64, Array[@types.Value])]? {
  None
}

///|
/// `stamp` for contexts without a database: nothing is cached.
pub fn no_stamp(_scope : Int, _id : Int) -> Int64? {
  None
}

///|
/// `user_fn` / `user_table` for contexts without a session (constant
/// folding, tests): user functions are never constant.
pub fn no_user_fn(
  _id : Int,
  _args : Array[@types.Value],
) -> @types.Value raise @types.SqlError {
  raise @types.not_supported("user-defined functions outside a session")
}

///|
pub fn no_user_table(
  _id : Int,
  _args : Array[@types.Value],
) -> Array[Array[@types.Value]] raise @types.SqlError {
  raise @types.not_supported("user-defined functions outside a session")
}

///|
pub fn Ctx::with_row(self : Ctx, row : Array[@types.Value]) -> Ctx {
  { ..self, row, }
}

///|
/// Default request work budget: ~minutes of CPU at worst. Single-threaded
/// execution cannot be preempted, so a runaway request would otherwise block
/// every session (host `--max-request-work`).
pub let default_work_limit : Int64 = 300_000_000L

///|
/// Accounts `n` units of work; past the limit the request fails with 50108
/// (aborts the batch; TRY cannot catch it).
pub fn Runtime::charge(self : Runtime, n : Int64) -> Unit raise @types.SqlError {
  self.work_done += n
  if self.work_done > self.work_limit {
    raise @types.emulator_error(
      @types.EMU_WORK_BUDGET,
      "the request exceeded the work budget of \{self.work_limit} units (a runaway loop or join?); see --max-request-work",
    )
  }
}

///|
/// Starts evaluating a new row's expressions.
pub fn Runtime::next_row(self : Runtime) -> Unit {
  self.row_seq += 1L
}

///|
pub fn no_json_seek(
  _scope : Int,
  _id : Int,
  _column : Int,
  _path : String,
) -> Array[(Int64, Array[@types.Value])]? {
  None
}

///|
pub fn no_vector_search(
  _scope : Int,
  _id : Int,
  _index_id : Int,
  _query : @types.VectorData,
  _top : Int64,
  _width : Int64,
  _expansion : Int64,
) -> Array[Row] raise @types.SqlError {
  raise @types.not_supported("vector search outside a session")
}

///|
pub fn Runtime::begin_attempt(self : Runtime, replay : Bool) -> Unit {
  self.cancel_pending = false
  self.cancel_null_warning = false
  if !replay {
    self.clock_reads.clear()
    self.clock_count = 0
  }
  self.clock_seen = 0
  self.clock_cursor = 0
  self.record_clock = true
}

///|
pub fn Runtime::finish_attempt(self : Runtime) -> Unit {
  self.clock_reads.clear()
  self.clock_count = 0
  self.record_clock = false
}

///|
/// Previously evaluated expressions keep their time after a suspension;
/// an expression first reached on this attempt sees the current event time.
fn Runtime::read_clock(self : Runtime) -> Int64 {
  if !self.record_clock {
    return self.now
  }
  let index = self.clock_seen
  self.clock_seen += 1
  if index == self.clock_count {
    if self.clock_reads.last() is Some((_, time)) && time == self.now {
      ()
    } else {
      self.clock_reads.push((index, self.now))
    }
    self.clock_count += 1
  }
  while self.clock_cursor + 1 < self.clock_reads.length() &&
        self.clock_reads[self.clock_cursor + 1].0 <= index {
    self.clock_cursor += 1
  }
  self.clock_reads[self.clock_cursor].1
}

///|
/// Poll after the current row has reached its consumer. An aggregate can
/// account for NULLs before cancellation; a SELECT can emit the final row.
pub fn Runtime::check_cancel(self : Runtime) -> Unit raise @types.SqlError {
  if self.cancel_pending {
    raise @types.Suspend
  }
}
