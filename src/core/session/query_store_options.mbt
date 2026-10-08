///|
/// Immutable database configuration. OFF remembers the requested operation mode.
priv struct QueryStoreOptions {
  enabled : Bool
  operation : Int
  capture : Int
  cleanup : Bool
  waits : Bool
  numbers : Map[String, Int]
}

///|
fn QueryStoreOptions::default(db : String) -> QueryStoreOptions {
  {
    enabled: !(db.to_lower() is ("master" | "tempdb" | "model" | "msdb")),
    operation: 2,
    capture: 2,
    cleanup: true,
    waits: true,
    numbers: Map([
      ("DATA_FLUSH_INTERVAL_SECONDS", 900),
      ("INTERVAL_LENGTH_MINUTES", 60),
      ("MAX_STORAGE_SIZE_MB", 1000),
      ("CLEANUP_POLICY.STALE_QUERY_THRESHOLD_DAYS", 30),
      ("MAX_PLANS_PER_QUERY", 200),
      ("QUERY_CAPTURE_POLICY.EXECUTION_COUNT", 30),
      ("QUERY_CAPTURE_POLICY.TOTAL_COMPILE_CPU_TIME_MS", 1000),
      ("QUERY_CAPTURE_POLICY.TOTAL_EXECUTION_CPU_TIME_MS", 100),
      ("QUERY_CAPTURE_POLICY.STALE_CAPTURE_POLICY_THRESHOLD", 24),
    ]),
  }
}

///|
fn QueryStoreOptions::number(self : QueryStoreOptions, key : String) -> Int {
  self.numbers.get(key).unwrap_or(0)
}

///|
fn QueryStoreOptions::options_row(self : QueryStoreOptions) -> VRow {
  let state = if self.enabled { self.operation } else { 0 }
  let desc = match state {
    1 => "READ_ONLY"
    2 => "READ_WRITE"
    _ => "OFF"
  }
  let row = vrow([
    ("desired_state", i(state)),
    ("desired_state_desc", s(desc)),
    ("actual_state", i(state)),
    ("actual_state_desc", s(desc)),
    ("readonly_reason", i(0)),
    ("current_storage_size_mb", BigInt(0L)),
    ("query_capture_mode", i(self.capture)),
    (
      "query_capture_mode_desc",
      s(
        match self.capture {
          1 => "ALL"
          2 => "AUTO"
          4 => "CUSTOM"
          _ => "NONE"
        },
      ),
    ),
    ("size_based_cleanup_mode", i(if self.cleanup { 1 } else { 0 })),
    (
      "size_based_cleanup_mode_desc",
      s(if self.cleanup { "AUTO" } else { "OFF" }),
    ),
    ("wait_stats_capture_mode", i(if self.waits { 1 } else { 0 })),
    ("wait_stats_capture_mode_desc", s(if self.waits { "ON" } else { "OFF" })),
    ("actual_state_additional_info", s("")),
  ])
  for
    (column, option) in [
      ("flush_interval_seconds", "DATA_FLUSH_INTERVAL_SECONDS"),
      ("interval_length_minutes", "INTERVAL_LENGTH_MINUTES"),
      ("max_storage_size_mb", "MAX_STORAGE_SIZE_MB"),
      (
        "stale_query_threshold_days", "CLEANUP_POLICY.STALE_QUERY_THRESHOLD_DAYS",
      ),
      ("max_plans_per_query", "MAX_PLANS_PER_QUERY"),
    ] {
    row[column] = BigInt(self.number(option).to_int64())
  }
  for
    (column, option, wide) in [
      ("capture_policy_execution_count", "EXECUTION_COUNT", false),
      (
        "capture_policy_total_compile_cpu_time_ms", "TOTAL_COMPILE_CPU_TIME_MS",
        true,
      ),
      (
        "capture_policy_total_execution_cpu_time_ms", "TOTAL_EXECUTION_CPU_TIME_MS",
        true,
      ),
      (
        "capture_policy_stale_threshold_hours", "STALE_CAPTURE_POLICY_THRESHOLD",
        false,
      ),
    ] {
    let n = self.number("QUERY_CAPTURE_POLICY." + option)
    row[column] = if self.capture != 4 {
      Null
    } else if wide {
      BigInt(n.to_int64())
    } else {
      Int(n)
    }
  }
  row
}

///|
fn Session::alter_query_store(
  self : Session,
  database : String,
  action : String,
  options : Array[(String, String)],
) -> Unit raise {
  let db = self.server.db_options(database)
  if database.to_lower() is ("master" | "tempdb" | "model" | "msdb") {
    self.pending.push(
      @types.sql_error(
        12438,
        "Cannot perform action because Query Store cannot be enabled on system database \{database}.",
      ),
    )
    raise @types.sql_error(5069, "ALTER DATABASE statement failed.")
  }
  let mut q = db.query_store
  let numbers : Map[String, Int] = Map([])
  for k, v in q.numbers {
    numbers[k] = v
  }
  q = { ..q, numbers, }
  for (key, value) in options {
    match key {
      "OPERATION_MODE" =>
        q = { ..q, operation: if value == "READ_ONLY" { 1 } else { 2 }, }
      "QUERY_CAPTURE_MODE" =>
        q = {
          ..q,
          capture: match value {
            "ALL" => 1
            "AUTO" => 2
            "CUSTOM" => 4
            _ => 3
          },
        }
      "SIZE_BASED_CLEANUP_MODE" => q = { ..q, cleanup: value == "AUTO", }
      "WAIT_STATS_CAPTURE_MODE" => q = { ..q, waits: value == "ON", }
      _ => {
        let n = @string.parse_int(value) catch { _ => -1 }
        numbers[key] = n
      }
    }
  }
  if action == "ON" {
    q = { ..q, enabled: true, }
  }
  if action == "OFF" {
    q = { ..q, enabled: false, }
  }
  // CLEAR keeps settings; workload history is added in the capture layer.
  self.server.db_options[database.to_lower()] = { ..db, query_store: q, }
}

///|
/// Invalid settings are compilation errors (DONE CurCmd 253).
fn validate_query_store_options(
  options : Array[(String, String)],
) -> Unit raise @types.SqlError {
  for (key, value) in options {
    let n = @string.parse_int(value) catch { _ => -1 }
    if key == "INTERVAL_LENGTH_MINUTES" &&
      !(n is (1 | 5 | 10 | 15 | 30 | 60 | 1440)) {
      raise @types.sql_error(
        153,
        "Invalid usage of the option interval_length_minutes in the ALTER DATABASE statement.",
        state=6,
      )
    }
    if key == "DATA_FLUSH_INTERVAL_SECONDS" && n == 0 {
      raise @types.sql_error(
        153,
        "Invalid usage of the option flush_interval_seconds in the ALTER DATABASE statement.",
        state=5,
        severity=15,
      )
    }
  }
}
