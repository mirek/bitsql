///|
/// A host-sampled top-level statement. No clock is read inside core.
priv struct StatementSample {
  database : String
  text : String
  identity : String
  context_id : Int64
  capture : Bool
  interval_minutes : Int
  mut start : Int64
  mut cpu_start : Int64
  mut rows : Int64
  mut finished : Bool
}

///|
priv struct QueryObservation {
  id : Int64
  mut plan_id : Int64
  mut plan_removed : Bool
  database : String
  text : String
  identity : String
  context_id : Int64
  first_time : Int64
  mut last_time : Int64
  mut count : Int64
  mut rows : Int64
  mut last_rows : Int64
  mut min_rows : Int64
  mut max_rows : Int64
  mut duration : Int64
  mut last_duration : Int64
  mut min_duration : Int64
  mut max_duration : Int64
  mut cpu : Int64
  mut last_cpu : Int64
  mut min_cpu : Int64
  mut max_cpu : Int64
  interval_minutes : Int
}

///|
pub fn Server::enable_monitoring(
  self : Server,
  now : Int64,
  cpus : Int,
  memory_kb : Int64,
) -> Unit {
  self.monitoring = true
  self.monitor_start = now
  self.monitor_cpus = cpus
  self.monitor_memory = memory_kb
}

///|
pub fn Session::needs_sample(self : Session) -> Bool {
  self.sample_requested
}

///|
pub fn Session::sample(self : Session, now : Int64, _cpu : Int64) -> Unit {
  self.sample_requested = false
  guard self.statement_sample is Some(sample) else { return }
  if !sample.finished {
    if sample.start == 0L {
      sample.start = now
    }
    return
  }
  let duration = @cmp.maximum(0L, (now - sample.start) / 10L)
  let cpu = sample.cpu_start
  self.server.observe(self.server.query_statistics, sample, now, duration, cpu)
  if sample.capture {
    self.server.observe(self.server.query_history, sample, now, duration, cpu)
    let width = @cmp.maximum(1, sample.interval_minutes).to_int64() * 600000000L
    self.server.observe(
      self.server.query_runtime,
      sample,
      now,
      duration,
      cpu,
      bucket=sample.start / width * width,
    )
  }
  self.statement_sample = None
}

///|
fn Server::observe(
  self : Server,
  history : Map[(String, String, Int64), QueryObservation],
  sample : StatementSample,
  now : Int64,
  duration : Int64,
  cpu : Int64,
  bucket? : Int64 = 0L,
) -> Unit {
  let key = (sample.database, sample.identity, bucket)
  match history.get(key) {
    Some(q) => {
      if q.plan_removed {
        self.next_observation += 1L
        q.plan_id = self.next_observation
        q.plan_removed = false
      }
      q.last_time = now
      q.count += 1L
      q.rows += sample.rows
      q.last_rows = sample.rows
      q.min_rows = @cmp.minimum(q.min_rows, sample.rows)
      q.max_rows = @cmp.maximum(q.max_rows, sample.rows)
      q.duration += duration
      q.last_duration = duration
      q.min_duration = @cmp.minimum(q.min_duration, duration)
      q.max_duration = @cmp.maximum(q.max_duration, duration)
      q.cpu += cpu
      q.last_cpu = cpu
      q.min_cpu = @cmp.minimum(q.min_cpu, cpu)
      q.max_cpu = @cmp.maximum(q.max_cpu, cpu)
    }
    None => {
      // Bound instance history; cache eviction does not affect stored data.
      if physical_equal(history, self.query_statistics) &&
        history.length() >= 4096 {
        history.clear()
      }
      self.next_observation += 1L
      history[key] = {
        id: self.next_observation,
        plan_id: self.next_observation,
        plan_removed: false,
        database: sample.database,
        text: sample.text,
        identity: sample.identity,
        context_id: sample.context_id,
        first_time: sample.start,
        last_time: now,
        count: 1L,
        rows: sample.rows,
        last_rows: sample.rows,
        min_rows: sample.rows,
        max_rows: sample.rows,
        duration,
        last_duration: duration,
        min_duration: duration,
        max_duration: duration,
        cpu,
        last_cpu: cpu,
        min_cpu: cpu,
        max_cpu: cpu,
        interval_minutes: sample.interval_minutes,
      }
    }
  }
}

///|
fn Session::sample_boundary(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> Unit raise {
  self.batch_resume = Some({
    remaining: stmts,
    waits_seen: self.waits_seen,
    configuration_reads_seen: self.configuration_reads_seen,
    embeddings_seen: self.embeddings_seen,
    clock_seen: self.rt.clock_seen,
    temp_db_refs: self.temp_db_refs,
  })
  self.batch_resuming = true
  self.sample_requested = true
  raise Park
}

///|
fn Session::prepare_sample(self : Session, stmt : @ast.Stmt) -> Unit {
  let options = self.server.db_options(self.rt.database).query_store
  let text = self.slice(stmt.span).trim().trim_end(chars=";").to_owned()
  let settings = self.query_store_context()
  let context = "\{settings.0}:\{settings.1}:\{settings.2}:\{settings.3}"
  let database = self.rt.database.to_lower()
  let context_key = (database, context)
  let context_id = match self.server.query_contexts.get(context_key) {
    Some(c) => c.id
    None => {
      let id = self.server.query_contexts.length().to_int64() + 1L
      self.server.query_contexts[context_key] = {
        id,
        options: settings.0,
        language: settings.1,
        format: settings.2,
        datefirst: settings.3,
      }
      id
    }
  }
  let identity = text + "\n--context:" + context
  self.statement_sample = Some({
    database,
    text,
    identity,
    context_id,
    capture: options.enabled &&
    options.operation == 2 &&
    (
      options.capture == 1 ||
      self.server.query_history.contains((database, identity, 0L))
    ),
    interval_minutes: options.number("INTERVAL_LENGTH_MINUTES"),
    start: 0L,
    cpu_start: 0L,
    rows: 0L,
    finished: false,
  })
}

///|
fn observation_handle(id : Int64, length : Int) -> @types.Value {
  Binary(
    Bytes::makei(length, k => if k < 8 { (id >> (k * 8)).to_byte() } else { 0 }),
  )
}

///|
fn QueryObservation::stats_row(self : QueryObservation) -> VRow {
  let r = vrow([
    ("sql_handle", observation_handle(self.id, 64)),
    ("plan_handle", observation_handle(self.id, 64)),
    ("query_hash", observation_handle(self.id, 8)),
    ("query_plan_hash", observation_handle(self.id, 8)),
    ("statement_start_offset", i(0)),
    ("statement_end_offset", i(-1)),
    ("plan_generation_num", BigInt(1L)),
    ("creation_time", dt(self.first_time)),
    ("last_execution_time", dt(self.last_time)),
    ("execution_count", BigInt(self.count)),
  ])
  for
    (name, total, last, min, max) in [
      (
        "elapsed_time",
        self.duration,
        self.last_duration,
        self.min_duration,
        self.max_duration,
      ),
      ("worker_time", self.cpu, self.last_cpu, self.min_cpu, self.max_cpu),
      ("rows", self.rows, self.last_rows, self.min_rows, self.max_rows),
    ] {
    r["total_" + name] = BigInt(total)
    r["last_" + name] = BigInt(last)
    r["min_" + name] = BigInt(min)
    r["max_" + name] = BigInt(max)
  }
  r
}

///|
fn Session::monitoring_rows(
  self : Session,
  key : String,
  out : Array[VRow],
) -> Unit {
  if key == "sys.query_context_settings" {
    let used = self.server.query_history
      .values()
      .to_array()
      .filter(q => q.database == self.rt.database.to_lower())
      .map(q => q.context_id)
    for k, c in self.server.query_contexts {
      if k.0 == self.rt.database.to_lower() && used.contains(c.id) {
        out.push(c.row())
      }
    }
    return
  }
  if key == "sys.dm_exec_query_stats" {
    for _, q in self.server.query_statistics {
      out.push(q.stats_row())
    }
    return
  }
  let records = if key == "sys.query_store_runtime_stats" ||
    key == "sys.query_store_runtime_stats_interval" {
    self.server.query_runtime
  } else {
    self.server.query_history
  }
  let intervals : Set[Int64] = Set([])
  for record_key, q in records {
    if q.database != self.rt.database.to_lower() {
      continue
    }
    if key == "sys.query_store_plan" && q.plan_removed {
      continue
    }
    let query_id = self.server.query_history
      .get((q.database, q.identity, 0L))
      .map(p => p.id)
      .unwrap_or(q.id)
    let plan_id = self.server.query_history
      .get((q.database, q.identity, 0L))
      .map(p => p.plan_id)
      .unwrap_or(q.plan_id)
    let bucket = record_key.2
    let interval_id = bucket / 600000000L
    if key == "sys.query_store_runtime_stats_interval" {
      if intervals.contains(interval_id) {
        continue
      }
      intervals.add(interval_id)
    }
    let r = vrow([
      ("query_text_id", BigInt(query_id)),
      ("query_id", BigInt(query_id)),
      ("plan_id", BigInt(plan_id)),
      ("runtime_stats_id", BigInt(q.id)),
      ("runtime_stats_interval_id", BigInt(interval_id)),
      ("context_settings_id", BigInt(q.context_id)),
      ("query_sql_text", s(q.text)),
      ("statement_sql_handle", observation_handle(q.id, 44)),
      ("query_hash", observation_handle(q.id, 8)),
      ("query_plan_hash", observation_handle(q.id, 8)),
      ("object_id", BigInt(0L)),
      ("query_parameterization_type_desc", s("None")),
      ("initial_compile_start_time", DateTimeOffset(q.first_time, 0)),
      ("last_compile_start_time", DateTimeOffset(q.first_time, 0)),
      ("first_execution_time", DateTimeOffset(q.first_time, 0)),
      ("last_execution_time", DateTimeOffset(q.last_time, 0)),
      ("count_executions", BigInt(q.count)),
      ("execution_type_desc", s("Regular")),
      ("start_time", DateTimeOffset(bucket, 0)),
      (
        "end_time",
        DateTimeOffset(bucket + q.interval_minutes.to_int64() * 600000000L, 0),
      ),
      ("plan_forcing_type_desc", s("NONE")),
      ("last_force_failure_reason_desc", s("NONE")),
      (
        "compatibility_level",
        SmallInt(self.server.db_options(q.database).compat_level),
      ),
    ])
    for
      (name, total, last, min, max) in [
        (
          "duration",
          q.duration,
          q.last_duration,
          q.min_duration,
          q.max_duration,
        ),
        ("cpu_time", q.cpu, q.last_cpu, q.min_cpu, q.max_cpu),
        ("rowcount", q.rows, q.last_rows, q.min_rows, q.max_rows),
      ] {
      r["avg_" + name] = Float(total.to_double() / q.count.to_double())
      r["last_" + name] = BigInt(last)
      r["min_" + name] = BigInt(min)
      r["max_" + name] = BigInt(max)
    }
    out.push(r)
  }
}

///|
fn Session::system_info_row(self : Session) -> VRow {
  let row = vrow([
    ("cpu_count", i(self.server.monitor_cpus)),
    ("scheduler_count", i(1)),
    ("scheduler_total_count", i(1)),
    ("max_workers_count", i(1)),
    ("hyperthread_ratio", i(1)),
    ("physical_memory_kb", BigInt(self.server.monitor_memory)),
    ("sqlserver_start_time", dt(self.server.monitor_start)),
    ("ms_ticks", BigInt((self.rt.now - self.server.monitor_start) / 10000L)),
    ("affinity_type_desc", s("AUTO")),
    ("time_source_desc", s("SYSTEM")),
    ("virtual_machine_type_desc", s("NONE")),
    ("softnuma_configuration_desc", s("OFF")),
    ("sql_memory_model_desc", s("CONVENTIONAL")),
    ("container_type_desc", s("NONE")),
    ("socket_count", i(1)),
    ("cores_per_socket", i(self.server.monitor_cpus)),
    ("numa_node_count", i(1)),
  ])
  let descriptor = view_defs[view_index("sys", "dm_os_sys_info").unwrap()]
  for c in descriptor.columns {
    if self.server.system_facts.get(c.name) is Some(n) {
      row[c.name] = if c.ty is BigInt { BigInt(n) } else { Int(n.to_int()) }
    }
  }
  let uptime = self.server.system_facts
    .get("sqlserver_start_time_ms_ticks")
    .unwrap_or(0L)
  row["ms_ticks"] = BigInt(
    uptime + (self.rt.now - self.server.monitor_start) / 10000L,
  )
  row["container_type_desc"] = s(
    if self.server.system_facts.get("container_type") == Some(1L) {
      "LINUX CONTAINER"
    } else {
      "NONE"
    },
  )
  row
}

///|
pub fn Session::charge_cpu(self : Session, cpu : Int64) -> Unit {
  if self.statement_sample is Some(sample) && sample.start > 0L {
    sample.cpu_start += @cmp.maximum(0L, cpu)
  }
}

///|
pub fn Session::resample(self : Session) -> Bool {
  if self.statement_sample is Some(_) {
    self.sample_requested = true
    true
  } else {
    false
  }
}

///|
pub fn Server::set_system_facts(
  self : Server,
  facts : Array[(String, Int64)],
) -> Unit {
  for (key, value) in facts {
    self.system_facts[key] = value
  }
}
