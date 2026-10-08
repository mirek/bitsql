///|
/// QUERY_STORE has a separate option grammar; do not discard policy bodies.
fn Parser::query_store_options(
  self : Parser,
) -> @ast.AlterDatabaseAction raise @ast.SyntaxError {
  let eq = self.eat_punct("=")
  let action = if self.eat_kw("ON") {
    "ON"
  } else if self.eat_kw("OFF") {
    "OFF"
  } else if !eq && self.eat_kw("CLEAR") {
    if self.eat_kw("ALL") {
      "CLEAR_ALL"
    } else {
      "CLEAR"
    }
  } else if !eq && self.is_punct("(") {
    "CONFIGURE"
  } else {
    raise self.error()
  }
  let opts : Array[(String, String)] = []
  if self.is_punct("(") && action is ("ON" | "CONFIGURE") {
    self.query_store_policy("", opts)
  }
  QueryStore(action, opts)
}

///|
fn Parser::query_store_policy(
  self : Parser,
  prefix : String,
  opts : Array[(String, String)],
) -> Unit raise @ast.SyntaxError {
  self.expect_punct("(")
  while true {
    let token = self.peek()
    let name = upper(token)
    let allowed = match prefix {
      "CLEANUP_POLICY." => ["STALE_QUERY_THRESHOLD_DAYS"]
      "QUERY_CAPTURE_POLICY." =>
        [
          "STALE_CAPTURE_POLICY_THRESHOLD", "EXECUTION_COUNT", "TOTAL_COMPILE_CPU_TIME_MS",
          "TOTAL_EXECUTION_CPU_TIME_MS",
        ]
      _ =>
        [
          "OPERATION_MODE", "QUERY_CAPTURE_MODE", "INTERVAL_LENGTH_MINUTES", "DATA_FLUSH_INTERVAL_SECONDS",
          "MAX_STORAGE_SIZE_MB", "MAX_PLANS_PER_QUERY", "CLEANUP_POLICY", "SIZE_BASED_CLEANUP_MODE",
          "WAIT_STATS_CAPTURE_MODE", "QUERY_CAPTURE_POLICY",
        ]
    }
    guard token.kind is Word && allowed.contains(name) else {
      raise near(token)
    }
    self.pos += 1
    self.expect_punct("=")
    if prefix == "" && name is ("CLEANUP_POLICY" | "QUERY_CAPTURE_POLICY") {
      self.query_store_policy(name + ".", opts)
    } else {
      let v = self.peek()
      let value = upper(v)
      let valid = match name {
        "OPERATION_MODE" => value is ("READ_ONLY" | "READ_WRITE")
        "QUERY_CAPTURE_MODE" => value is ("ALL" | "AUTO" | "NONE" | "CUSTOM")
        "SIZE_BASED_CLEANUP_MODE" => value is ("AUTO" | "OFF")
        "WAIT_STATS_CAPTURE_MODE" => value is ("ON" | "OFF")
        _ => v.kind is IntNum
      }
      guard valid else { raise near(token) }
      if v.kind is IntNum && (@string.parse_int(value) catch { _ => -1 }) < 0 {
        raise near(v)
      }
      self.pos += 1
      let value = if name == "STALE_CAPTURE_POLICY_THRESHOLD" {
        self.expect_kw("HOURS")
        value
      } else {
        value
      }
      opts.push((prefix + name, value))
    }
    if !self.eat_punct(",") {
      break
    }
  }
  self.expect_punct(")")
}
