// DATABASEPROPERTYEX, CONNECTIONPROPERTY and SESSIONPROPERTY (bound in
// bind/fn_variant.mbt, results are sql_variant). Values captured from the
// oracle (corpus properties/*.sql; docs/reference/sql-variant.md).

///|
fn prop_string(s : String, len? : Int = 128) -> @types.Value {
  Variant(String(s), NVarChar(Some(len), @types.default_collation))
}

///|
fn prop_int(n : Int) -> @types.Value {
  Variant(Int(n), Int)
}

///|
fn prop_tinyint(n : Int) -> @types.Value {
  Variant(TinyInt(n), TinyInt)
}

///|
/// Session-evaluated property functions. None = not one of them.
fn Session::property_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? raise @types.SqlError {
  let text = (k : Int) => {
    match args.get(k) {
      Some(String(t)) => Some(t)
      _ => None
    }
  }
  match name {
    "DATABASEPROPERTYEX" =>
      Some(
        match (text(0), text(1)) {
          (Some(db), Some(p)) if self.server.has_database(db) =>
            database_property(db, p)
          _ => Null
        },
      )
    "CONNECTIONPROPERTY" =>
      Some(
        match text(0) {
          Some(p) => connection_property(p)
          None => Null
        },
      )
    "SESSIONPROPERTY" =>
      Some(
        match text(0) {
          Some(p) => self.session_property(p)
          None => Null
        },
      )
    _ => None
  }
}

///|
/// DATABASEPROPERTYEX of an existing database, captured on the oracle for a
/// fresh user database and the system databases: they differ only in
/// Recovery (user and model FULL, others SIMPLE) and IsFulltextEnabled
/// (user and msdb 1). IsReadCommittedSnapshotOn is not a DATABASEPROPERTYEX
/// property (NULL on the oracle; sys.databases has the column).
fn database_property(db : String, p : String) -> @types.Value {
  let system = db.to_lower() is ("master" | "tempdb" | "model" | "msdb")
  match p.to_lower() {
    "recovery" =>
      prop_string(
        if system && db.to_lower() != "model" {
          "SIMPLE"
        } else {
          "FULL"
        },
      )
    "isfulltextenabled" =>
      prop_int(if system && db.to_lower() != "msdb" { 0 } else { 1 })
    "collation" => prop_string(@types.default_collation.name)
    "comparisonstyle" => prop_int(196609)
    "isautocreatestatistics" | "isautoupdatestatistics" => prop_int(1)
    "isansinulldefault"
    | "isansinullsenabled"
    | "isansipaddingenabled"
    | "isansiwarningsenabled"
    | "isarithmeticabortenabled"
    | "isautoclose"
    | "isautocreatestatisticsincremental"
    | "isautoshrink"
    | "isclosecursorsoncommitenabled"
    | "isinstandby"
    | "islocalcursorsdefault"
    | "ismemoryoptimizedelevatetosnapshotenabled"
    | "ismergepublished"
    | "isnullconcat"
    | "isnumericroundabortenabled"
    | "isparameterizationforced"
    | "isquotedidentifiersenabled"
    | "ispublished"
    | "isrecursivetriggersenabled"
    | "issubscribed"
    | "issyncwithbackup"
    | "istornpagedetectionenabled" => prop_int(0)
    "isclone" | "isdatabasesuspendedforsnapshotbackup" | "isverifiedclone" =>
      prop_tinyint(0)
    "isxtpsupported" => prop_tinyint(1)
    // 1900-01-01 00:00:00.000
    "lastgoodcheckdbtime" => Variant(DateTime(0, 0), DateTime)
    "lcid" => prop_int(1033)
    "sqlsortorder" => prop_tinyint(52)
    "status" => prop_string("ONLINE")
    "updateability" => prop_string("READ_WRITE")
    "useraccess" => prop_string("MULTI_USER")
    "version" => prop_int(998)
    _ => Null
  }
}

///|
/// CONNECTIONPROPERTY: bitsql connections are TCP with SQL authentication.
/// Addresses and the local port belong to the host and are not known to
/// the engine: explicit emulator errors rather than invented values.
fn connection_property(p : String) -> @types.Value raise @types.SqlError {
  match p.to_lower() {
    "net_transport" | "physical_net_transport" => prop_string("TCP", len=40)
    "protocol_type" => prop_string("TSQL", len=40)
    "auth_scheme" => prop_string("SQL", len=20)
    "local_net_address" | "local_tcp_port" | "client_net_address" =>
      raise @types.not_supported("CONNECTIONPROPERTY('\{p}')")
    _ => Null
  }
}

///|
/// SESSIONPROPERTY: the SET options of this session. bitsql only lets
/// ARITHABORT change (the other options' non-default values raise emulator
/// errors in SET), so the rest report the defaults: NUMERIC_ROUNDABORT OFF,
/// the others ON.
fn Session::session_property(self : Session, p : String) -> @types.Value {
  let key = p.to_upper()
  let default = match key {
    "ANSI_NULLS"
    | "ANSI_PADDING"
    | "ANSI_WARNINGS"
    | "ARITHABORT"
    | "CONCAT_NULL_YIELDS_NULL"
    | "QUOTED_IDENTIFIER" => true
    "NUMERIC_ROUNDABORT" => false
    _ => return Null
  }
  prop_int(if self.session_flags.get(key).unwrap_or(default) { 1 } else { 0 })
}
