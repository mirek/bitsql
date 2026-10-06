// Database-level settings: ALTER DATABASE, CREATE DATABASE … COLLATE and
// what reads them (literal/variable/column collations, RCSI, snapshot
// isolation, read-only databases, DATABASEPROPERTYEX, sys.databases).
// Captured: harness/corpus/settings/alter-database*.sql.

///|
/// Settings of one database. Immutable: ALTER DATABASE stores a new value.
priv struct DbOptions {
  collation : @types.Collation
  compat_level : Int
  /// READ_COMMITTED_SNAPSHOT
  rcsi : Bool
  /// ALLOW_SNAPSHOT_ISOLATION
  snapshot : Bool
  /// CURSOR_DEFAULT LOCAL
  local_cursors : Bool
  read_only : Bool
  /// MULTI_USER, SINGLE_USER or RESTRICTED_USER
  user_access : String
  /// FULL, SIMPLE or BULK_LOGGED
  recovery : String
  /// ON/OFF options set by ALTER DATABASE (copy on write), by option name;
  /// absent: `default_flag`.
  flags : Map[String, Bool]
  /// (logical name, physical path) of the data and log files when they
  /// differ from the defaults (RESTORE … WITH MOVE; session/backup.mbt).
  files : Array[(String, String)]?
  /// Backup family GUID: assigned by the first BACKUP, carried by RESTORE
  /// (3154 compares it).
  family : Bytes?
}

///|
/// Default of an ON/OFF database option (captured: settings/alter-database
/// sys.databases of the system databases and a fresh user database).
fn default_flag(db : String, name : String) -> Bool {
  let key = db.to_lower()
  match name {
    "AUTO_CREATE_STATISTICS" | "AUTO_UPDATE_STATISTICS" => true
    "DB_CHAINING" => key is ("master" | "tempdb" | "msdb")
    "TRUSTWORTHY" => key == "msdb"
    "ENABLE_BROKER" => !(key is ("master" | "model"))
    _ => false
  }
}

///|
fn DbOptions::flag(self : DbOptions, db : String, name : String) -> Bool {
  match self.flags.get(name) {
    Some(v) => v
    None => default_flag(db, name)
  }
}

///|
fn DbOptions::with_flag(self : DbOptions, name : String, v : Bool) -> DbOptions {
  let flags = Map([])
  for k, x in self.flags {
    flags[k] = x
  }
  flags[name] = v
  { ..self, flags, }
}

///|
/// Defaults of a database: user databases and model are FULL recovery,
/// the other system databases SIMPLE (captured: properties/database).
fn DbOptions::default(name : String) -> DbOptions {
  let key = name.to_lower()
  {
    collation: @types.default_collation,
    compat_level: 170,
    rcsi: false,
    snapshot: key is ("master" | "msdb"),
    local_cursors: false,
    read_only: false,
    user_access: "MULTI_USER",
    recovery: if key is ("master" | "tempdb" | "msdb") {
      "SIMPLE"
    } else {
      "FULL"
    },
    flags: Map([]),
    files: None,
    family: None,
  }
}

///|
fn Server::db_options(self : Server, name : String) -> DbOptions {
  match self.db_options.get(name.to_lower()) {
    Some(o) => o
    None => DbOptions::default(name)
  }
}

///|
/// The current database's default collation: literals, variables, new
/// columns and the database's catalog views use it.
fn Session::db_collation(self : Session) -> @types.Collation {
  self.server.db_options(self.rt.database).collation
}

///|
/// Default collation of new columns of a table in `scope`: temp tables
/// live in tempdb and take its collation, everything else (tables, table
/// variables, table types) the current database's.
fn Session::scope_collation(self : Session, scope : Int) -> @types.Collation {
  if scope == 1 {
    self.server.db_options("tempdb").collation
  } else {
    self.db_collation()
  }
}

///|
/// A SNAPSHOT transaction may only read or write a database that allows
/// snapshot isolation: 3952, which ends the batch and rolls the
/// transaction back (captured: settings/alter-database).
fn Session::check_snapshot_allowed(self : Session) -> Unit raise {
  if self.isolation == "SNAPSHOT" &&
    !self.server.db_options(self.rt.database).snapshot {
    raise @types.sql_error(
      3952,
      "Snapshot isolation transaction failed accessing database '\{self.rt.database}' because snapshot isolation is not allowed in this database. Use ALTER DATABASE to allow snapshot isolation.",
    )
  }
}

///|
/// Object names compare under the database collation. Lookups are
/// case-insensitive (lowercased keys); this re-checks a found name under a
/// case- or binary-sensitive database collation.
fn Session::same_identifier(
  self : Session,
  actual : String,
  written : String,
) -> Bool {
  let c = self.db_collation()
  if c.kind is Linguistic && !c.case_sensitive {
    return true
  }
  @types.compare_strings(actual, written, c) == 0
}

///|
/// Read committed snapshot isolation is on for the current database.
fn Session::rcsi(self : Session) -> Bool {
  self.server.db_options(self.rt.database).rcsi
}

///|
/// The collation of CREATE/ALTER DATABASE … COLLATE (448 state 3 when
/// unknown; captured: settings/alter-database).
fn resolve_collation(name : @ast.Ident) -> @types.Collation raise {
  match @types.Collation::parse(name.name) {
    Some(c) => c
    None =>
      match @types.unknown_collation_error(name.name) {
        SqlError(number=448, severity~, message~, ..) =>
          raise @types.SqlError(number=448, severity~, state=3, message~)
        e => raise e
      }
  }
}

///|
/// ENVCHANGE SQL_COLLATION with the database's collation, sent when the
/// session's database collation changes (USE, ALTER DATABASE COLLATE).
fn Session::collation_envchange(self : Session) -> Unit {
  self.out.push(EnvChange(Collation(collation_bytes(self.db_collation()), b"")))
}

///|
/// ALTER DATABASE (CurCmd 215). Validation SQL Server does while compiling
/// (unknown collation 448, compatibility level 15048) ends the batch with
/// DONE 253; the rest are statement errors of CurCmd 215.
fn Session::exec_alter_database(
  self : Session,
  target : @ast.Ident?,
  action : @ast.AlterDatabaseAction,
) -> Unit raise {
  if action is PreviewFeatures(enabled) {
    self.cur_cmd = 253
    if self.rt.trancount > 0 {
      raise @types.sql_error(
        226,
        "ALTER DATABASE SCOPED CONFIGURATION statement not allowed within multi-statement transaction.",
        state=7,
      )
    }
    let name = self.rt.database
    self.server.db_options[name.to_lower()] = self.server
      .db_options(name)
      .with_flag("PREVIEW_FEATURES", enabled)
    self.done(253)
    return
  }
  // compile-time checks
  match action {
    Collate(c) => ignore(resolve_collation(c))
    SetOptions(opts) =>
      for o in opts {
        if o.name == "COMPATIBILITY_LEVEL" {
          let ok = match o.value {
            Some(v) =>
              (@string.parse_int(v) catch { _ => 0 })
              is (100 | 110 | 120 | 130 | 140 | 150 | 160 | 170)
            None => false
          }
          if !ok {
            raise @types.sql_error(
              15048, "Valid values of the database compatibility level are 100, 110, 120, 130, 140, 150, 160 or 170.",
            )
          }
        }
      }
    PreviewFeatures(_) => ()
    OtherAction(w) => raise @types.not_supported("ALTER DATABASE \{w}")
  }
  // master stays alterable: it is the case database of process-isolated
  // harness runs (docs/design/decisions.md)
  if target is None &&
    self.rt.database.to_lower() is ("tempdb" | "model" | "msdb") {
    raise @types.sql_error(
      12104,
      "ALTER DATABASE CURRENT failed because '\{self.rt.database}' is a system database. System databases cannot be altered by using the CURRENT keyword. Use the database name to alter a system database.",
      state=2,
    )
  }
  self.cur_cmd = 215
  if self.rt.trancount > 0 {
    raise @types.sql_error(
      226,
      "ALTER DATABASE statement not allowed within multi-statement transaction.",
      state=6,
    )
  }
  let name = match target {
    None => self.rt.database
    Some(t) => {
      if !self.server.has_database(t.name) {
        self.pending.push(
          @types.sql_error(
            5011,
            "User does not have permission to alter database '\{t.name}', the database does not exist, or the database is not in a state that allows access checks.",
            state=5,
            severity=14,
          ),
        )
        raise @types.sql_error(5069, "ALTER DATABASE statement failed.")
      }
      self.server.database_name(t.name)
    }
  }
  let current = name.to_lower() == self.rt.database.to_lower()
  let mut o = self.server.db_options(name)
  match action {
    Collate(c) => {
      let coll = resolve_collation(c)
      if name.to_lower() is ("master" | "tempdb" | "model" | "msdb") && !current {
        raise @types.not_supported(
          "ALTER DATABASE COLLATE of a system database",
        )
      }
      o = { ..o, collation: coll, }
      self.server.db_options[name.to_lower()] = o
      if current {
        self.collation_envchange()
      }
    }
    SetOptions(opts) => {
      for x in opts {
        o = self.database_option(o, x)
      }
      self.server.db_options[name.to_lower()] = o
    }
    PreviewFeatures(_) | OtherAction(_) => ()
  }
  self.done(215)
}

///|
/// Applies one SET option. Options whose non-default value changes
/// behaviour bitsql does not model raise an emulator error; options without
/// observable effect in a memory-only engine are accepted.
fn Session::database_option(
  self : Session,
  o : DbOptions,
  x : @ast.DatabaseOption,
) -> DbOptions raise {
  ignore(self)
  let v = x.value.unwrap_or("")
  let on_off = () => {
    match v {
      "ON" => true
      "OFF" => false
      _ => raise @types.not_supported("ALTER DATABASE SET \{x.name} \{v}")
    }
  }
  let unsupported = () => {
    @types.not_supported(
      "ALTER DATABASE SET \{x.name}" +
      (match x.value {
        Some(v) => " " + v
        None => ""
      }),
    )
  }
  match x.name {
    "COMPATIBILITY_LEVEL" =>
      { ..o, compat_level: @string.parse_int(v) catch { _ => o.compat_level }, }
    "READ_COMMITTED_SNAPSHOT" => { ..o, rcsi: on_off(), }
    "ALLOW_SNAPSHOT_ISOLATION" => { ..o, snapshot: on_off(), }
    "CURSOR_DEFAULT" =>
      match v {
        "LOCAL" => { ..o, local_cursors: true, }
        "GLOBAL" => { ..o, local_cursors: false, }
        _ => raise unsupported()
      }
    "READ_ONLY" => { ..o, read_only: true, }
    "READ_WRITE" => { ..o, read_only: false, }
    "SINGLE_USER" | "RESTRICTED_USER" | "MULTI_USER" =>
      { ..o, user_access: x.name, }
    "RECOVERY" =>
      match v {
        "FULL" | "SIMPLE" | "BULK_LOGGED" => { ..o, recovery: v, }
        _ => raise unsupported()
      }
    // no observable effect in a memory-only engine (statistics, files,
    // checkpoints, logging, brokers, ownership chaining)
    "AUTO_CLOSE"
    | "AUTO_SHRINK"
    | "AUTO_CREATE_STATISTICS"
    | "AUTO_UPDATE_STATISTICS"
    | "AUTO_UPDATE_STATISTICS_ASYNC"
    | "DB_CHAINING"
    | "TRUSTWORTHY"
    | "DATE_CORRELATION_OPTIMIZATION"
    // database defaults of SET options: clients set every one of them at
    // login (tedious getInitialSql; corpus set/tedious-initial), so the
    // database default is never observed by a session
    | "ANSI_NULLS"
    | "ANSI_PADDING"
    | "ANSI_WARNINGS"
    | "ARITHABORT"
    | "CONCAT_NULL_YIELDS_NULL"
    | "QUOTED_IDENTIFIER"
    | "ANSI_NULL_DEFAULT"
    | "NUMERIC_ROUNDABORT"
    | "CURSOR_CLOSE_ON_COMMIT" => o.with_flag(x.name, on_off())
    // a change of trigger semantics bitsql does not model
    "RECURSIVE_TRIGGERS" => if on_off() { raise unsupported() } else { o }
    "PAGE_VERIFY"
    | "TARGET_RECOVERY_TIME"
    | "DELAYED_DURABILITY"
    | "ACCELERATED_DATABASE_RECOVERY"
    | "QUERY_STORE"
    | "AUTOMATIC_TUNING"
    | "NEW_BROKER"
    | "ERROR_BROKER_CONVERSATIONS"
    | "HONOR_BROKER_PRIORITY"
    | "MIXED_PAGE_ALLOCATION"
    | "TORN_PAGE_DETECTION"
    | "ONLINE" => o
    "ENABLE_BROKER" => o.with_flag("ENABLE_BROKER", true)
    "DISABLE_BROKER" => o.with_flag("ENABLE_BROKER", false)
    "PARAMETERIZATION" =>
      match v {
        "SIMPLE" => o
        _ => raise unsupported()
      }
    _ => raise unsupported()
  }
}

///|
/// DATABASEPROPERTYEX 'ComparisonStyle': IgnoreCase 1, IgnoreAccent 2,
/// IgnoreKanaType 65536, IgnoreWidth 131072; 0 for binary collations
/// (captured: settings/alter-database, CI_AS 196609, BIN2 0).
fn comparison_style(c : @types.Collation) -> Int {
  match c.kind {
    Bin | Bin2 => 0
    Linguistic => {
      let mut n = 0
      if !c.case_sensitive {
        n += 1
      }
      if !c.accent_sensitive {
        n += 2
      }
      if !c.kana_sensitive {
        n += 65536
      }
      if !c.width_sensitive {
        n += 131072
      }
      n
    }
  }
}

///|
/// DATABASEPROPERTYEX 'SQLSortOrder': the SQL sort order id of a SQL_
/// collation, 0 for Windows collations (captured: 52 for
/// SQL_Latin1_General_CP1_CI_AS, 0 for Latin1_General_100_BIN2).
fn sql_sort_order(c : @types.Collation) -> Int {
  collation_bytes(c)[4].to_int()
}

///|
/// Overrides the settings columns of a sys.databases row.
fn DbOptions::apply_row(
  self : DbOptions,
  name : String,
  m : Map[String, @types.Value],
) -> Unit {
  m["collation_name"] = String(self.collation.name)
  m["compatibility_level"] = TinyInt(self.compat_level)
  let (ua, ua_desc) = match self.user_access {
    "SINGLE_USER" => (1, "SINGLE_USER")
    "RESTRICTED_USER" => (2, "RESTRICTED_USER")
    _ => (0, "MULTI_USER")
  }
  m["user_access"] = TinyInt(ua)
  m["user_access_desc"] = String(ua_desc)
  m["is_read_only"] = Bit(self.read_only)
  m["snapshot_isolation_state"] = TinyInt(if self.snapshot { 1 } else { 0 })
  m["snapshot_isolation_state_desc"] = String(
    if self.snapshot {
      "ON"
    } else {
      "OFF"
    },
  )
  m["is_read_committed_snapshot_on"] = Bit(self.rcsi)
  m["recovery_model"] = TinyInt(
    match self.recovery {
      "FULL" => 1
      "BULK_LOGGED" => 2
      _ => 3
    },
  )
  m["recovery_model_desc"] = String(self.recovery)
  m["is_local_cursor_default"] = Bit(self.local_cursors)
  for
    opt in [
      ("is_ansi_null_default_on", "ANSI_NULL_DEFAULT"),
      ("is_ansi_nulls_on", "ANSI_NULLS"),
      ("is_ansi_padding_on", "ANSI_PADDING"),
      ("is_ansi_warnings_on", "ANSI_WARNINGS"),
      ("is_arithabort_on", "ARITHABORT"),
      ("is_concat_null_yields_null_on", "CONCAT_NULL_YIELDS_NULL"),
      ("is_numeric_roundabort_on", "NUMERIC_ROUNDABORT"),
      ("is_quoted_identifier_on", "QUOTED_IDENTIFIER"),
      ("is_cursor_close_on_commit_on", "CURSOR_CLOSE_ON_COMMIT"),
      ("is_auto_close_on", "AUTO_CLOSE"),
      ("is_auto_shrink_on", "AUTO_SHRINK"),
      ("is_auto_create_stats_on", "AUTO_CREATE_STATISTICS"),
      ("is_auto_update_stats_on", "AUTO_UPDATE_STATISTICS"),
      ("is_auto_update_stats_async_on", "AUTO_UPDATE_STATISTICS_ASYNC"),
      ("is_trustworthy_on", "TRUSTWORTHY"),
      ("is_db_chaining_on", "DB_CHAINING"),
      ("is_date_correlation_on", "DATE_CORRELATION_OPTIMIZATION"),
      ("is_broker_enabled", "ENABLE_BROKER"),
    ] {
    if self.flags.get(opt.1) is Some(v) {
      m[opt.0] = Bit(v)
    }
  }
  ignore(name)
}

///|
fn Session::preview_enabled(self : Session) -> Bool {
  self.server
  .db_options(self.rt.database)
  .flag(self.rt.database, "PREVIEW_FEATURES")
}
