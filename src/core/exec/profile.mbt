///|
/// Request-local observations. Created only by an explicit diagnostic request.
/// These count calls/rows at the executor's storage boundary, not physical I/O.
pub struct QueryProfile {
  events : Array[Json]
  mut events_truncated : Bool
  mut source_calls : Int64
  mut source_rows : Int64
  mut scan_rows : Int64
  mut seek_attempts : Int64
  mut seek_hits : Int64
  mut seek_candidates : Int64
  mut json_seek_attempts : Int64
  mut json_seek_hits : Int64
  mut json_seek_candidates : Int64
  mut vector_searches : Int64
  mut vector_candidates : Int64
  mut scalar_function_calls : Int64
  mut table_function_calls : Int64
}

///|
pub fn QueryProfile::new() -> QueryProfile {
  {
    events: [],
    events_truncated: false,
    source_calls: 0L,
    source_rows: 0L,
    scan_rows: 0L,
    seek_attempts: 0L,
    seek_hits: 0L,
    seek_candidates: 0L,
    json_seek_attempts: 0L,
    json_seek_hits: 0L,
    json_seek_candidates: 0L,
    vector_searches: 0L,
    vector_candidates: 0L,
    scalar_function_calls: 0L,
    table_function_calls: 0L,
  }
}

///|
/// Wrap only the explicitly profiled context. Normal Ctx construction and the
/// ordinary row-processing loops contain no profiling branches or callbacks.
/// The plan is unchanged, preserving seek, memoization and fused fast paths.
pub fn QueryProfile::wrap(self : QueryProfile, ctx : Ctx) -> Ctx {
  {
    ..ctx,
    profile: Some(self),
    source: (scope, id) => {
      self.source_calls += 1L
      let rows = (ctx.source)(scope, id)
      self.source_rows += rows.length().to_int64()
      rows
    },
    scan_row: (scope, id, row) => {
      (ctx.scan_row)(scope, id, row)
      self.scan_rows += 1L
    },
    seek: (scope, id, key) => {
      self.seek_attempts += 1L
      let found = (ctx.seek)(scope, id, key)
      if found is Some(rows) {
        self.seek_hits += 1L
        self.seek_candidates += rows.length().to_int64()
      }
      found
    },
    seek_json: (scope, id, column, path) => {
      self.json_seek_attempts += 1L
      let found = (ctx.seek_json)(scope, id, column, path)
      if found is Some(rows) {
        self.json_seek_hits += 1L
        self.json_seek_candidates += rows.length().to_int64()
      }
      found
    },
    vector_search: (scope, id, index, query, top, width, expansion) => {
      self.vector_searches += 1L
      let rows = (ctx.vector_search)(
        scope, id, index, query, top, width, expansion,
      )
      self.vector_candidates += rows.length().to_int64()
      rows
    },
    user_fn: (id, args) => {
      self.scalar_function_calls += 1L
      (ctx.user_fn)(id, args)
    },
    user_table: (id, args) => {
      self.table_function_calls += 1L
      (ctx.user_table)(id, args)
    },
  }
}

///|
/// Integer counters are strings in JSON to preserve Int64 precision in clients.
/// Calls into procedural functions are counted, but their separate execution
/// contexts are not wrapped; the report explicitly identifies partial coverage.
pub fn QueryProfile::counters(self : QueryProfile) -> Json {
  {
    "physical_events": self.events.to_json(),
    "physical_events_truncated": self.events_truncated,
    "source_calls": self.source_calls.to_string(),
    "source_rows": self.source_rows.to_string(),
    "scan_rows": self.scan_rows.to_string(),
    "seek_attempts": self.seek_attempts.to_string(),
    "seek_hits": self.seek_hits.to_string(),
    "seek_candidates": self.seek_candidates.to_string(),
    "json_seek_attempts": self.json_seek_attempts.to_string(),
    "json_seek_hits": self.json_seek_hits.to_string(),
    "json_seek_candidates": self.json_seek_candidates.to_string(),
    "vector_searches": self.vector_searches.to_string(),
    "vector_candidates": self.vector_candidates.to_string(),
    "scalar_function_calls": self.scalar_function_calls.to_string(),
    "table_function_calls": self.table_function_calls.to_string(),
    "includes_procedural_function_internals": false,
  }
}

///|
/// Bounded execution-order observations, not SQL Server optimizer estimates.
fn QueryProfile::record(
  self : QueryProfile,
  algorithm : String,
  left : Int,
  right : Int,
) -> Unit {
  if self.events.length() >= 128 {
    self.events_truncated = true
    return
  }
  self.events.push({
    "algorithm": algorithm,
    "input_rows": left,
    "right_rows": if algorithm.has_suffix("_join") {
      right.to_json()
    } else {
      Json::null()
    },
    "limit_rows": if algorithm.has_prefix("top_") {
      right.to_json()
    } else {
      Json::null()
    },
  })
}
