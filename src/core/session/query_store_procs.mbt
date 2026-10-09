///|
/// Query Store native procedures consume arguments positionally, even when
/// their labels differ. Captured in query-store/procedure-arguments.
fn Session::exec_query_store_proc(
  self : Session,
  proc_name : String,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let suffix = proc_name[15:].to_owned()
  let (minimum, maximum) = match suffix {
    "flush_db" | "clear_message_queues" | "consistency_check" => (0, 0)
    "force_plan" | "unforce_plan" => (2, 4)
    "set_hints" => (2, 3)
    "clear_hints" => (1, 2)
    "remove_plan_feedback" => (0, 2)
    _ => (1, 1)
  }
  if args.length() < minimum {
    self.query_store_arity_error(
      proc_name,
      @types.sql_error(
        313,
        "An insufficient number of arguments were supplied for the procedure or function \{proc_name}.",
        state=51,
      ),
    )
  }
  if args.length() > maximum {
    self.query_store_arity_error(
      proc_name,
      @types.sql_error(
        8144,
        "Procedure or function \{proc_name} has too many arguments specified.",
        state=if suffix == "remove_plan_feedback" { 120 } else { 51 },
      ),
    )
  }
  let values = args.map(a => self.eval(a.value).0)
  let q = self.server.db_options(self.rt.database).query_store
  let error = self.query_store_proc_error(suffix, values, q)
  self.rt.error = 0
  let status = match error {
    Some(e) if suffix == "remove_plan_feedback" && e.number() is (201 | 12468) =>
      e.number()
    Some(_) => 1
    None => 0
  }
  if error is Some(e) {
    if self.try_depth > 0 {
      self.rt.error = e.number()
      self.module_done(error=false)
      raise Caught(e, 1, Some("sys." + proc_name), max_nest_level + 1)
    }
    self.message(e, 1)
    self.stmt_error = e.number()
    self.rt.error = e.number()
  }
  if return_var is Some(rv) &&
    self.frame().vars.get(rv.to_lower()) is Some(info) {
    self.frame().values[info.slot] = @types.cast(Int(status), Int, info.ty)
  }
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=error is Some(_))
}

///|
fn query_store_integer(value : @types.Value?) -> Int64? {
  match value {
    Some(TinyInt(n) | SmallInt(n) | Int(n)) => Some(n.to_int64())
    Some(BigInt(n)) => Some(n)
    _ => None
  }
}

///|
fn query_store_param_error(
  name : String,
  ty : String,
  state : Int,
) -> @types.SqlError {
  @types.sql_error(
    214,
    "Procedure expects parameter '\{name}' of type '\{ty}'.",
    state~,
  )
}

///|
fn Session::query_store_proc_error(
  self : Session,
  suffix : String,
  values : Array[@types.Value],
  options : QueryStoreOptions,
) -> @types.SqlError? raise @types.SqlError {
  if suffix is ("flush_db" | "clear_message_queues") {
    return None
  }
  if suffix == "consistency_check" {
    return if options.enabled {
      Some(
        @types.sql_error(
          12427,
          "Cannot perform operation on Query Store while it is enabled. Please turn off Query Store for the database and try again.",
          state=3,
        ),
      )
    } else {
      None
    }
  }
  if suffix == "remove_plan_feedback" {
    if values.is_empty() {
      return Some(
        @types.sql_error(
          201,
          "Procedure or function 'sp_query_store_remove_plan_feedback' expects parameter '@feature_id', which was not supplied.",
          state=62,
        ),
      )
    }
    guard query_store_integer(values.get(0)) is Some(feature) &&
      feature >= 0L &&
      feature <= 255L else {
      return Some(query_store_param_error("@feature_id", "tinyint", 56))
    }
    if feature == 1L {
      return Some(
        @types.sql_error(
          12468, "Removing feedback for feature_id 1 is not supported.",
        ),
      )
    }
    raise @types.not_supported("Query Store plan feedback")
  }
  let query = suffix
    is ("force_plan"
    | "unforce_plan"
    | "remove_query"
    | "set_hints"
    | "clear_hints")
  let key = if query { "query_id" } else { "plan_id" }
  guard query_store_integer(values.get(0)) is Some(id) else {
    return Some(query_store_param_error("@" + key, "bigint", 51))
  }
  if suffix is ("force_plan" | "unforce_plan") &&
    query_store_integer(values.get(1)) is None {
    return Some(query_store_param_error("@plan_id", "bigint", 51))
  }
  if suffix is ("force_plan" | "unforce_plan") && values.length() >= 3 {
    guard query_store_integer(values.get(2)) is Some(flag) else {
      return Some(
        query_store_param_error("@disable_optimized_plan_forcing", "bit", 51),
      )
    }
    if flag != 0L && flag != 1L {
      return Some(
        @types.sql_error(
          12460,
          "The value of (\{flag}) is not valid for the parameter @disable_optimized_plan_forcing. Please pass either 0 or 1.",
        ),
      )
    }
  }
  if suffix == "set_hints" && !(values.get(1) is Some(String(_))) {
    return Some(query_store_param_error("@query_hints", "nvarchar", 51))
  }
  let replica_index = match suffix {
    "force_plan" | "unforce_plan" => 3
    "set_hints" => 2
    "clear_hints" => 1
    _ => values.length()
  }
  if values.length() > replica_index &&
    query_store_integer(values.get(replica_index)) is None {
    return Some(query_store_param_error("@replica_group_id", "bigint", 51))
  }
  let database_id = self.db_id()
  if !options.enabled {
    let state = match suffix {
      "force_plan" | "unforce_plan" => 4
      "set_hints" => 6
      "clear_hints" => 7
      _ => 0
    }
    if state > 0 {
      return Some(
        @types.sql_error(
          12405,
          "The command failed because the query store is not enabled for database (\{database_id}). Make sure that the query store is enabled for the database and rerun the command.",
          state~,
        ),
      )
    }
    if suffix == "reset_exec_stats" {
      return None
    }
  }
  for history_key, entry in self.server.query_history {
    if entry.database != self.rt.database.to_lower() {
      continue
    }
    let matches = if query {
      entry.id == id
    } else {
      !entry.plan_removed && entry.plan_id == id
    }
    if !matches {
      continue
    }
    if suffix is ("remove_query" | "remove_plan" | "reset_exec_stats") {
      let runtime_keys = self.server.query_runtime.keys().to_array()
      for runtime_key in runtime_keys {
        if runtime_key.0 == entry.database && runtime_key.1 == entry.identity {
          self.server.query_runtime.remove(runtime_key)
        }
      }
      if suffix == "remove_query" {
        self.server.query_history.remove(history_key)
      }
      if suffix == "remove_plan" {
        entry.plan_removed = true
      }
      return None
    }
    return Some(
      @types.not_supported("Query Store " + suffix + " for a captured plan"),
    )
  }
  let state = match suffix {
    "force_plan" | "unforce_plan" | "reset_exec_stats" => 2
    "set_hints" => 5
    "clear_hints" => 6
    _ => 1
  }
  let subject = if query { "Query" } else { "Query plan" }
  Some(
    @types.sql_error(
      if query {
        12402
      } else {
        12403
      },
      "\{subject} with provided \{key} (\{id}) is not found in the Query Store for database (\{database_id}). Check the \{key} value and rerun the command.",
      state~,
      severity=11,
    ),
  )
}

///|
fn Session::query_store_arity_error(
  self : Session,
  proc_name : String,
  error : @types.SqlError,
) -> Unit raise {
  self.error_line = Some(1)
  if self.try_depth > 0 {
    self.rt.error = error.number()
    self.module_done(error=false)
    raise Caught(error, 1, Some("sys." + proc_name), max_nest_level + 1)
  }
  if self.rpc {
    raise ProcFail(error, 1, None)
  }
  raise error
}
