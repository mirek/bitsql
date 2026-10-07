// ALTER DATABASE (captured: harness/corpus/settings/alter-database*.sql).

///|
/// ALTER DATABASE SET options SQL Server's grammar knows. Any other word
/// after SET is 102 state 6 near it (captured: settings/alter-database).
let database_option_names : Set[String] = Set([
  "ACCELERATED_DATABASE_RECOVERY", "ALLOW_SNAPSHOT_ISOLATION", "ANSI_NULL_DEFAULT",
  "ANSI_NULLS", "ANSI_PADDING", "ANSI_WARNINGS", "ARITHABORT", "AUTO_CLOSE", "AUTO_CREATE_STATISTICS",
  "AUTO_SHRINK", "AUTO_UPDATE_STATISTICS", "AUTO_UPDATE_STATISTICS_ASYNC", "AUTOMATIC_TUNING",
  "CHANGE_TRACKING", "COMPATIBILITY_LEVEL", "CONCAT_NULL_YIELDS_NULL", "CONTAINMENT",
  "CURSOR_CLOSE_ON_COMMIT", "CURSOR_DEFAULT", "DATA_RETENTION", "DATE_CORRELATION_OPTIMIZATION",
  "DB_CHAINING", "DEFAULT_FULLTEXT_LANGUAGE", "DEFAULT_LANGUAGE", "DELAYED_DURABILITY",
  "DISABLE_BROKER", "EMERGENCY", "ENABLE_BROKER", "ENCRYPTION", "ERROR_BROKER_CONVERSATIONS",
  "FILESTREAM", "HADR", "HONOR_BROKER_PRIORITY", "MEMORY_OPTIMIZED_ELEVATE_TO_SNAPSHOT",
  "MIXED_PAGE_ALLOCATION", "MULTI_USER", "NESTED_TRIGGERS", "NEW_BROKER", "NUMERIC_ROUNDABORT",
  "OFFLINE", "ONLINE", "OPTIMIZED_LOCKING", "PAGE_VERIFY", "PARAMETERIZATION", "PARTNER",
  "QUERY_STORE", "QUOTED_IDENTIFIER", "READ_COMMITTED_SNAPSHOT", "READ_ONLY", "READ_WRITE",
  "RECOVERY", "RECURSIVE_TRIGGERS", "REMOTE_DATA_ARCHIVE", "RESTRICTED_USER", "SINGLE_USER",
  "SUPPLEMENTAL_LOGGING", "SUSPEND_FOR_SNAPSHOT_BACKUP", "TARGET_RECOVERY_TIME",
  "TEMPORAL_HISTORY_RETENTION", "TORN_PAGE_DETECTION", "TRANSFORM_NOISE_WORDS", "TRUSTWORTHY",
  "TWO_DIGIT_YEAR_CUTOFF", "WITNESS",
])

///|
/// Options that take no value.
let bare_database_options : Set[String] = Set([
  "SINGLE_USER", "RESTRICTED_USER", "MULTI_USER", "READ_ONLY", "READ_WRITE", "ONLINE",
  "OFFLINE", "EMERGENCY", "ENABLE_BROKER", "DISABLE_BROKER", "NEW_BROKER", "ERROR_BROKER_CONVERSATIONS",
])

///|
/// True at a token that ends an ALTER DATABASE clause: `;`, end of input or
/// a keyword that starts the next statement.
fn Parser::at_statement_end(self : Parser) -> Bool {
  let t = self.peek()
  t.kind is Eof ||
  t.is_punct(";") ||
  [
    "USE", "CREATE", "ALTER", "DROP", "SELECT", "INSERT", "UPDATE", "DELETE", "IF",
    "EXEC", "EXECUTE", "DECLARE", "SET", "PRINT", "BEGIN", "COMMIT", "ROLLBACK",
    "DBCC", "WHILE", "RETURN", "GO",
  ]
  .iter()
  .any(k => t.is_kw(k))
}

///|
/// Skips tokens up to the end of the statement (balanced parentheses).
fn Parser::skip_clause(self : Parser) -> Unit {
  let mut depth = 0
  while !(self.peek().kind is Eof) {
    if depth == 0 && self.at_statement_end() {
      break
    }
    if self.is_punct("(") {
      depth += 1
    } else if self.is_punct(")") {
      depth -= 1
    }
    self.pos += 1
  }
}

///|
/// `ALTER DATABASE { name | CURRENT } { COLLATE c | SET options | ... }`,
/// positioned after DATABASE.
fn Parser::alter_database(
  self : Parser,
) -> @ast.StmtKind raise @ast.SyntaxError {
  // ALTER DATABASE SCOPED CONFIGURATION is a different statement
  if self.is_kw("SCOPED") && self.is_kw_at(1, "CONFIGURATION") {
    self.pos += 2
    if self.is_kw("SET") && self.is_kw_at(1, "PREVIEW_FEATURES") {
      self.pos += 2
      self.expect_punct("=")
      let enabled = if self.eat_kw("ON") {
        true
      } else if self.eat_kw("OFF") {
        false
      } else {
        raise self.error()
      }
      return AlterDatabase(target=None, PreviewFeatures(enabled))
    }
    if self.is_kw("SET") && self.is_kw_at(1, "ALLOW_STALE_VECTOR_INDEX") {
      self.pos += 1
      raise self.error()
    }
    self.skip_clause()
    return AlterDatabase(target=None, OtherAction("SCOPED CONFIGURATION"))
  }
  let target = if self.eat_kw("CURRENT") { None } else { Some(self.ident()) }
  if self.eat_kw("COLLATE") {
    return AlterDatabase(target~, Collate(self.any_ident()))
  }
  if !self.eat_kw("SET") {
    let t = self.peek()
    if !(t.kind is Word) {
      raise self.error()
    }
    let words = upper(t)
    self.skip_clause()
    return AlterDatabase(target~, OtherAction(words))
  }
  let opts : Array[@ast.DatabaseOption] = []
  while true {
    let t = self.peek()
    guard t.kind is Word && database_option_names.contains(upper(t)) else {
      raise @ast.SyntaxError(
        number=102,
        severity=15,
        state=6,
        message="Incorrect syntax near '\{t.text}'.",
        span=t.span,
      )
    }
    self.pos += 1
    let name = upper(t)
    let mut value : String? = None
    if !bare_database_options.contains(name) {
      // captured: `COMPATIBILITY_LEVEL 150` is 102 near '150'
      if !self.eat_punct("=") && name == "COMPATIBILITY_LEVEL" {
        raise self.error()
      }
      let v = self.peek()
      match v.kind {
        Word | IntNum | QuotedIdent | Str | NStr if !v.is_kw("WITH") => {
          self.pos += 1
          value = Some(v.text.to_upper())
        }
        _ => raise self.error()
      }
      // QUERY_STORE = ON (...), CHANGE_TRACKING = ON (...): sub-options
      if self.is_punct("(") {
        let mut depth = 0
        while !(self.peek().kind is Eof) {
          if self.is_punct("(") {
            depth += 1
          } else if self.is_punct(")") {
            depth -= 1
            if depth == 0 {
              self.pos += 1
              break
            }
          }
          self.pos += 1
        }
      }
      // TARGET_RECOVERY_TIME = 60 SECONDS
      if self.is_kw("SECONDS") || self.is_kw("MINUTES") {
        self.pos += 1
      }
    }
    opts.push({ name, value, span: t.span.to(self.prev()), })
    if !self.eat_punct(",") {
      break
    }
  }
  // WITH ROLLBACK IMMEDIATE | ROLLBACK AFTER n [SECONDS] | NO_WAIT
  if self.eat_kw("WITH") {
    if self.eat_kw("ROLLBACK") {
      if self.eat_kw("AFTER") {
        if !(self.peek().kind is IntNum) {
          raise self.error()
        }
        self.pos += 1
        ignore(self.eat_kw("SECONDS"))
      } else {
        self.expect_kw("IMMEDIATE")
      }
    } else {
      self.expect_kw("NO_WAIT")
    }
  }
  AlterDatabase(target~, SetOptions(opts))
}
