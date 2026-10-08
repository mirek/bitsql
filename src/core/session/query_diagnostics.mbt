///|
/// Custom bitsql diagnostics, deliberately separate from SQL Server Query Store.
/// Only this request owns the instrumented context; failure cannot enable later
/// queries. Explain binds but never calls the executor.
fn Session::query_diagnostics(
  self : Session,
  op : String,
  args : Array[@ast.ExecArg],
) -> Unit raise {
  guard args is [arg] &&
    !arg.output &&
    (arg.name is None || arg.name.map(n => n.to_lower()) == Some("@sql")) else {
    raise @types.not_supported(
      "emulator.\{op}: expected exactly one input @sql",
    )
  }
  guard self.eval(arg.value).0 is String(sql) else {
    raise @types.not_supported("emulator.\{op}: @sql must be a non-null string")
  }
  let stmts = @parse.parse_batch(sql) catch {
    e =>
      raise @types.sql_error(
        e.number(),
        e.message(),
        state=e.state(),
        severity=e.severity(),
      )
  }
  guard stmts is [{ kind: Select(q), .. }] else {
    raise @types.not_supported(
      "query diagnostics require exactly one result-producing SELECT",
    )
  }
  diagnostic_query(q)
  let known = copy_map(self.frame().vars)
  for name, _ in self.frame().tables {
    if !known.contains(name) {
      known[name] = { slot: -1, ty: Int, }
    }
  }
  if precheck_batch(stmts, known, preview=self.preview_enabled())
    is Some((e, _)) {
    raise e
  }
  match self.precheck_hints(stmts) {
    Err(errors) => raise errors[errors.length() - 1].0
    Ok(warnings) =>
      for (name, line) in warnings {
        self.info(
          4430,
          1,
          "Warning: Index hints supplied for view '\{name}' will be ignored.",
          line,
        )
      }
  }
  let vector_errors = self.precheck_vector(stmts)
  if !vector_errors.is_empty() {
    raise vector_errors[vector_errors.length() - 1].0
  }
  let bound = @bind.bind_query(self.env(), q)
  self.check_json_index_paths(bound.plan)
  let plan = @ir.explain_plan(bound.plan, (scope, id) => {
    if scope == 2 {
      match view_defs.get(id % TEMPDB_VIEW_OFFSET) {
        Some(v) => return v.schema + "." + v.name
        None => ()
      }
    }
    match self.db_of(scope).table(id) {
      Some(t) => t.schema + "." + t.name
      None => "scope=\{scope} object=\{id}"
    }
  })
  let mut counters : Json = Json::null()
  let mut returned = 0L
  let mut work = 0L
  if op == "profile" {
    let saved_text = self.text
    let saved_reads = self.rt.stmt_reads
    self.text = sql
    self.rt.stmt_reads = statement_reads(sql)
    errdefer {
      self.text = saved_text
      self.rt.stmt_reads = saved_reads
    }
    self.rt.clear_caches()
    let profile = @exec.QueryProfile::new()
    let before = self.rt.work_done
    returned = self.exec_bound_query(q, bound, 1, profile=Some(profile))
    work = self.rt.work_done - before
    counters = profile.counters()
    self.text = saved_text
    self.rt.stmt_reads = saved_reads
  }
  let report : Json = {
    "schema_version": 1,
    "engine": "bitsql",
    "mode": op,
    "plan": plan.to_json(),
    "returned_rows": if op == "profile" {
      returned.to_string().to_json()
    } else {
      Json::null()
    },
    "work_units": if op == "profile" {
      work.to_string().to_json()
    } else {
      Json::null()
    },
    "counters": counters,
  }
  let text : @types.SqlType = NVarChar(None, @types.default_collation)
  self.sp_result([spc("plan_text", text, 0), spc("report_json", text, 0)], [
    [String(plan.text()), String(report.stringify())],
  ])
  self.proc_done(0)
}

///|
fn diagnostic_query(q : @ast.Query) -> Unit raise @types.SqlError {
  for cte in q.ctes {
    diagnostic_query(cte.query)
  }
  diagnostic_body(q.body)
}

///|
fn diagnostic_body(body : @ast.QueryBody) -> Unit raise @types.SqlError {
  match body {
    Select(s) =>
      if s.into is Some(_) || s.items.iter().any(i => i.kind is Assign(_, _, _)) {
        raise @types.not_supported(
          "query diagnostics for SELECT INTO or variable assignment",
        )
      }
    SetOperation(_, a, b) => {
      diagnostic_body(a)
      diagnostic_body(b)
    }
    Nested(q) => diagnostic_query(q)
  }
}
