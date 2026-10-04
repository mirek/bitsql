///|
/// DBCC statements complete with CurCmd 230. Only USEROPTIONS is emulated
/// (captured: msduck gaps-transactions #004–#026, corpus stmts/tx-dbcc-*):
/// a two-column nvarchar result of the options that are ON, then INFO 2528
/// and a second DONE 230 unless WITH NO_INFOMSGS. Other known commands are
/// Emulator errors; an unknown name is 2526 state 3.
fn Session::exec_dbcc(
  self : Session,
  name : String,
  args : Array[@ast.Expr],
  options : Array[String],
  line : Int,
) -> Unit raise {
  self.cur_cmd = 230
  match name {
    "USEROPTIONS" => ()
    "CHECKIDENT"
    | "CHECKDB"
    | "CHECKTABLE"
    | "CHECKCONSTRAINTS"
    | "CHECKALLOC"
    | "CHECKCATALOG"
    | "CHECKFILEGROUP"
    | "CLEANTABLE"
    | "DBREINDEX"
    | "DROPCLEANBUFFERS"
    | "FREEPROCCACHE"
    | "FREESESSIONCACHE"
    | "FREESYSTEMCACHE"
    | "HELP"
    | "INDEXDEFRAG"
    | "INPUTBUFFER"
    | "OPENTRAN"
    | "OUTPUTBUFFER"
    | "PROCCACHE"
    | "SHOWCONTIG"
    | "SHOW_STATISTICS"
    | "SHRINKDATABASE"
    | "SHRINKFILE"
    | "SQLPERF"
    | "TRACEOFF"
    | "TRACEON"
    | "TRACESTATUS"
    | "UPDATEUSAGE"
    | "PDW_SHOWSPACEUSED"
    | "CLONEDATABASE" => raise @types.not_supported("DBCC \{name}")
    _ =>
      raise @types.sql_error(
        2526,
        "Incorrect DBCC statement. Check the documentation for the correct DBCC syntax and options.",
        state=3,
      )
  }
  if !args.is_empty() {
    raise @types.sql_error(
      2583,
      "An incorrect number of parameters was given to the DBCC statement.",
      state=3,
    )
  }
  if options.iter().any(o => o != "NO_INFOMSGS") {
    raise @types.sql_error(
      2532, "One or more WITH options specified are not valid for this command.",
    )
  }
  let col = (n : String, len : Int) => @ir.ResultColumn::{
    name: n,
    ty: @types.SqlType::NVarChar(Some(len), @types.default_collation),
    nullable: true,
    origin: Aggregate,
  }
  self.out.push(
    ResultSet([col("Set Option", 128), col("Value", 46)].map(tds_column)),
  )
  let rows = self.user_options()
  for r in rows {
    self.out.push(Row([Text(r.0), Text(r.1)]))
  }
  let n = rows.length().to_int64()
  self.rt.rowcount = n
  self.done(230, count=Some(n), result_set=true)
  if !options.contains("NO_INFOMSGS") {
    self.info(
      2528, 1, "DBCC execution completed. If DBCC printed error messages, contact your system administrator.",
      line,
    )
    self.done(230)
  }
}

///|
/// DBCC USEROPTIONS rows: settings, then the ON flags in SQL Server's order
/// (captured on 17.0.5005.3 with every flag toggled), then the isolation
/// level. Options bitsql pins (textsize, ANSI_*) are reported at their only
/// supported value.
fn Session::user_options(self : Session) -> Array[(String, String)] {
  let flag = (k : String, default : Bool) => {
    self.session_flags.get(k).unwrap_or(default)
  }
  let rows : Array[(String, String)] = [
    ("textsize", "2147483647"),
    ("language", @types.language(self.rt.dates.language).name),
    ("dateformat", self.rt.dates.format.name()),
    ("datefirst", self.rt.datefirst.to_string()),
    ("lock_timeout", self.lock_timeout.to_string()),
    ("quoted_identifier", "SET"),
  ]
  let flags = [
    ("arithabort", flag("ARITHABORT", true)),
    ("arithignore", flag("ARITHIGNORE", false)),
    ("nocount", self.nocount),
    ("ansi_null_dflt_on", true),
    ("xact_abort", self.xact_abort),
    ("ansi_warnings", flag("ANSI_WARNINGS", true)),
    ("ansi_padding", true),
    ("ansi_nulls", true),
    ("concat_null_yields_null", true),
  ]
  for f in flags {
    if f.1 {
      rows.push((f.0, "SET"))
    }
  }
  // READ COMMITTED under READ_COMMITTED_SNAPSHOT (captured: settings/rcsi)
  rows.push(
    (
      "isolation level",
      if self.isolation == "READ COMMITTED" && self.rcsi() {
        "read committed snapshot"
      } else {
        self.isolation.to_lower()
      },
    ),
  )
  rows
}

///|
/// DBCC WITH options SQL Server recognizes (any other is 195).
let dbcc_options : Array[String] = [
  "NO_INFOMSGS", "TABLERESULTS", "ALL_ERRORMSGS", "ALL_LEVELS", "COUNT_ROWS", "ESTIMATEONLY",
  "PHYSICAL_ONLY", "DATA_PURITY", "EXTENDED_LOGICAL_CHECKS", "TABLOCK", "STAT_HEADER",
  "DENSITY_VECTOR", "HISTOGRAM", "STATS_STREAM", "MAXDOP", "NORESEED", "FAST", "NOINDEX",
  "REPAIR_ALLOW_DATA_LOSS", "REPAIR_REBUILD", "REPAIR_FAST", "NO_STATS", "MARK_IN_USE_FOR_REMOVAL",
]
