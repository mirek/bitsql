// BACKUP DATABASE / RESTORE DATABASE|HEADERONLY|FILELISTONLY|VERIFYONLY as
// an in-memory, process-lifetime backup store (design: decisions.md
// "BACKUP / RESTORE"). A backup file is a list of backup sets keyed by the
// normalized device path; a set holds the immutable `@store.Db` value plus
// the server-side state that belongs to the database (DbOptions, identity
// counters, sequences, procedures), so a restore is O(1) and the copy is
// independent of the original. Nothing touches the file system: a path is
// "missing" exactly when no BACKUP in this process wrote it. Messages,
// errors and result shapes are captured (corpus backup/*, msduck
// gaps-backup); page counts, sizes, LSNs, GUIDs and times are synthesized.

///|
/// Pages SQL Server reports for a fresh, empty database's data and log
/// files (captured on 17.0.5005: "Processed 360 pages … file 'x'", 2 for
/// 'x_log'). bitsql has no pages; every backup reports these.
const BACKUP_DATA_PAGES : Int = 360

///|
const BACKUP_LOG_PAGES : Int = 2

///|
/// One backup set: header facts and the database it holds.
priv struct BackupSet {
  backup_set_id : Int
  media_set_id : Int
  position : Int
  name : String?
  description : String?
  database : String
  user : String
  options : DbOptions
  /// (logical name, physical path) of the data and log files.
  files : Array[(String, String)]
  family : Bytes
  set_guid : Bytes
  binding : Bytes
  compressed : Bool
  checksum : Bool
  copy_only : Bool
  start : Int64
  first_lsn : Int64
  // payload (cleared in the msdb history copy)
  db : @store.Db
  procs : Array[Proc]
  idents : Array[(Int, Int64)]
  seqs : Array[(Int, SeqState)]
}

///|
/// A backup file: its media set and the sets in position order.
priv struct BackupMedia {
  media_set_id : Int
  media_guid : Bytes
  family_guid : Bytes
  /// The path as first written (msdb backupmediafamily).
  path : String
  /// Set when the media is formatted; later sets inherit it (captured:
  /// sets appended or INIT-written to a compressed media are compressed).
  compressed : Bool
  sets : Array[BackupSet]
}

///|
/// One msdb restorehistory row (plus its restorefile rows).
priv struct RestoreRecord {
  id : Int
  date : Int64
  database : String
  user : String
  backup_set_id : Int
  replace : Bool
  files : Array[String]
}

///|
/// The server's backup files and msdb backup history.
priv struct BackupStore {
  media : Map[String, BackupMedia]
  /// Every backup set ever written (payload cleared): msdb.dbo.backupset.
  history : Array[BackupSet]
  /// msdb.dbo.backupmediaset / backupmediafamily rows by media set.
  media_history : Array[BackupMedia]
  restores : Array[RestoreRecord]
  mut next_set_id : Int
  mut next_media_id : Int
  mut next_restore_id : Int
  mut next_lsn : Int64
}

///|
fn BackupStore::new() -> BackupStore {
  {
    media: Map([]),
    history: [],
    media_history: [],
    restores: [],
    next_set_id: 1,
    next_media_id: 1,
    next_restore_id: 1,
    next_lsn: 37000000002400000L,
  }
}

///|
/// Backup device paths compare case-insensitively and ignore repeated
/// slashes (captured: tail of corpus backup/headeronly, VERIFYONLY of
/// `…/BKZ.bak` and `…//bkz.bak` find `…/bkz.bak`).
fn backup_path_key(path : String) -> String {
  let sb = StringBuilder()
  let mut prev_slash = false
  for c in path.to_lower() {
    if c == '/' {
      if prev_slash {
        continue
      }
      prev_slash = true
    } else {
      prev_slash = false
    }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
/// Default files of a database (sys.database_files): `name` / `name_log`
/// in /var/opt/mssql/data; the system databases' captured names.
fn default_db_files(name : String) -> Array[(String, String)] {
  let dir = "/var/opt/mssql/data/"
  match name.to_lower() {
    "master" =>
      [("master", dir + "master.mdf"), ("mastlog", dir + "mastlog.ldf")]
    "tempdb" =>
      [("tempdev", dir + "tempdb.mdf"), ("templog", dir + "templog.ldf")]
    "model" =>
      [("modeldev", dir + "model.mdf"), ("modellog", dir + "modellog.ldf")]
    "msdb" =>
      [("MSDBData", dir + "MSDBData.mdf"), ("MSDBLog", dir + "MSDBLog.ldf")]
    _ => [(name, dir + name + ".mdf"), (name + "_log", dir + name + "_log.ldf")]
  }
}

///|
/// The data and log files of a database (as restored, or the defaults).
fn Server::db_files(self : Server, name : String) -> Array[(String, String)] {
  match self.db_options(name).files {
    Some(f) => f
    None => default_db_files(name)
  }
}

///|
/// The object id after `prefix` in a "database:id" key.
fn key_id(k : String, prefix : String) -> Int? {
  guard k.has_prefix(prefix) else { return None }
  let mut n = 0
  let mut neg = false
  let mut any = false
  for i in prefix.length()..<k.length() {
    let c = k.code_unit_at(i).to_int()
    if c == 45 && i == prefix.length() {
      neg = true
    } else if c >= 48 && c <= 57 {
      n = n * 10 + (c - 48)
      any = true
    } else {
      return None
    }
  }
  if any {
    Some(if neg { -n } else { n })
  } else {
    None
  }
}

///|
fn Session::random_guid(self : Session) -> Bytes {
  let a = self.rt.next_random()
  let b = self.rt.next_random()
  let arr = FixedArray::make(16, b'\x00')
  for k in 0..<16 {
    let w = if k < 8 { a } else { b }
    arr[k] = ((w >> (8 * (k % 8))) & 0xFFUL).to_byte()
  }
  arr[7] = (arr[7] & b'\x0f') | b'\x40'
  arr[8] = (arr[8] & b'\x3f') | b'\x80'
  Bytes::from_array(arr)
}

///|
/// Emits the errors that precede 3013 (outside TRY only: a TRY block
/// catches just the 3013; captured: tail/backup-errors, backup/errors)
/// and returns the 3013 to raise.
fn Session::backup_abort(
  self : Session,
  what : String,
  errs : Array[@types.SqlError],
) -> @types.SqlError {
  if self.try_depth == 0 {
    for e in errs {
      self.message(e, self.stmt_line)
    }
  }
  @types.sql_error(3013, "\{what} is terminating abnormally.")
}

///|
/// A string argument (database name, device path, option value).
fn Session::backup_string(
  self : Session,
  e : @ast.Expr,
  what : String,
) -> String raise {
  match e.kind {
    Column([id]) => id.name
    _ =>
      match self.eval(e) {
        (String(s), _) => s
        _ => raise @types.not_supported("\{what} of this kind")
      }
  }
}

///|
/// An integer option value (FILE = n, STATS = n).
fn Session::backup_int(
  self : Session,
  e : @ast.Expr,
  what : String,
) -> Int raise {
  match self.eval(e) {
    (TinyInt(n) | SmallInt(n) | Int(n), _) => n
    (BigInt(n), _) if n >= 0L && n <= 2147483647L => n.to_int()
    _ => raise @types.not_supported("\{what} of this kind")
  }
}

///|
/// The single DISK device of a BACKUP/RESTORE; other device kinds and
/// striped (several) devices are not supported.
fn Session::backup_device(
  self : Session,
  devices : Array[@ast.BackupDevice],
) -> String raise {
  match devices {
    [{ kind: "DISK", value, }] => self.backup_string(value, "a backup device")
    [{ kind: "DISK", .. }, ..] =>
      raise @types.not_supported("BACKUP/RESTORE with several devices")
    [] => raise @types.not_supported("RESTORE without FROM")
    [{ kind: "", .. }, ..] =>
      raise @types.not_supported("logical backup devices")
    [d, ..] => raise @types.not_supported("\{d.kind} backup devices")
  }
}

///|
/// STATS = n: "n percent processed." messages, each closing an internal
/// statement. SQL Server reports the percentages it actually reached
/// (STATS=10 printed 11, 20, 32, …); bitsql prints exact multiples of n
/// and 100 (decisions.md).
fn Session::backup_stats(self : Session, step : Int?, cmd : Int) -> Unit {
  guard step is Some(n) && n > 0 else { return }
  let mut p = n
  let mut last = 0
  while p <= 100 {
    self.info(3211, 1, "\{p} percent processed.", self.stmt_line)
    self.done(cmd)
    last = p
    p += n
  }
  if last != 100 {
    self.info(3211, 1, "100 percent processed.", self.stmt_line)
    self.done(cmd)
  }
}

///|
/// "… in 0.001 seconds (x MB/sec)." for `pages` pages (bitsql's backups
/// take no measurable time; the rate follows from the page count).
fn backup_rate_text(pages : Int) -> String {
  // pages * 8192 bytes / 2^20 / 0.001 s = pages * 7.8125 MB/s
  let milli = pages.to_int64() * 15625L / 2L
  let frac = (milli % 1000L).to_string()
  let pad = "0".repeat(3 - frac.length())
  "in 0.001 seconds (\{milli / 1000L}.\{pad}\{frac} MB/sec)"
}

///|
/// The per-file "Processed n pages" messages and the closing summary of
/// a BACKUP DATABASE / RESTORE DATABASE (captured: each 4035 closes an
/// internal statement; RESTORE's recovery runs in its own transaction,
/// BEGIN/COMMIT ENVCHANGE before the summary).
fn Session::backup_report(
  self : Session,
  what : String,
  database : String,
  files : Array[(String, String)],
  position : Int,
  cmd : Int,
  restore : Bool,
) -> Unit {
  let pages = [BACKUP_DATA_PAGES, BACKUP_LOG_PAGES]
  let mut total = 0
  for k, f in files {
    let n = pages.get(k).unwrap_or(0)
    total += n
    self.info(
      4035,
      1,
      "Processed \{n} pages for database '\{database}', file '\{f.0}' on file \{position}.",
      self.stmt_line,
    )
    self.done(cmd)
  }
  if restore {
    let d = self.tx_descriptor()
    self.out.push(EnvChange(BeginTransaction(d)))
    self.out.push(EnvChange(CommitTransaction(d)))
  }
  self.info(
    3014,
    1,
    "\{what} successfully processed \{total} pages \{backup_rate_text(total)}.",
    self.stmt_line,
  )
  self.done(cmd)
}

///|
/// Options a BACKUP DATABASE accepts here; the others (DIFFERENTIAL,
/// ENCRYPTION, MEDIANAME, EXPIREDATE, BLOCKSIZE, …) change what is stored
/// or checked and are Emulator errors.
let backup_supported_options : Array[String] = [
  "FORMAT", "NOFORMAT", "INIT", "NOINIT", "NAME", "DESCRIPTION", "COMPRESSION", "NO_COMPRESSION",
  "COPY_ONLY", "CHECKSUM", "NO_CHECKSUM", "STATS", "SKIP", "NOSKIP", "REWIND", "NOREWIND",
  "UNLOAD", "NOUNLOAD", "BUFFERCOUNT", "MAXTRANSFERSIZE", "STOP_ON_ERROR",
]

///|
/// BACKUP DATABASE|LOG (CurCmd 228 / 235). Captured: msduck gaps-backup,
/// corpus tail/backup-errors and backup/*.
fn Session::exec_backup(
  self : Session,
  log : Bool,
  database : @ast.Expr,
  devices : Array[@ast.BackupDevice],
  options : Array[@ast.BackupOption],
) -> Unit raise {
  self.cur_cmd = if log { 235 } else { 228 }
  let what = if log { "BACKUP LOG" } else { "BACKUP DATABASE" }
  let name = self.backup_string(database, "BACKUP of a database argument")
  let key = name.to_lower()
  if self.rt.trancount > 0 {
    raise self.backup_abort(what, [
      @types.sql_error(
        3021,
        "Cannot perform a backup or restore operation within a transaction.",
        state=0,
      ),
    ])
  }
  if !self.server.db_names.contains(key) {
    raise self.backup_abort(what, [
      @types.sql_error(
        911,
        "Database '\{name}' does not exist. Make sure that the name is entered correctly.",
        state=if log { 10 } else { 11 },
      ),
    ])
  }
  if key == "tempdb" {
    raise self.backup_abort(what, [
      @types.sql_error(
        3147,
        "Backup and restore operations are not allowed on database tempdb.",
        state=3,
      ),
    ])
  }
  let display = self.server.database_name(name)
  let opts = self.server.db_options(display)
  if log {
    if opts.recovery == "SIMPLE" {
      raise self.backup_abort(what, [
        @types.sql_error(
          4208, "The statement BACKUP LOG is not allowed while the recovery model is SIMPLE. Use BACKUP DATABASE or change the recovery model using ALTER DATABASE.",
        ),
      ])
    }
    raise @types.not_supported("BACKUP LOG")
  }
  if key is ("master" | "model" | "msdb") {
    raise @types.not_supported("BACKUP of a system database")
  }
  let path = self.backup_device(devices)
  let mut format = false
  let mut init = false
  let mut set_name = None
  let mut description = None
  let mut compression : Bool? = None
  let mut checksum = false
  let mut copy_only = false
  let mut stats = None
  for o in options {
    if !backup_supported_options.contains(o.name) || o.args {
      raise @types.not_supported("BACKUP option \{o.name}")
    }
    match o.name {
      "FORMAT" => format = true
      "INIT" => init = true
      "NOINIT" => init = false
      "NAME" =>
        set_name = o.value.map(v => self.backup_string(v, "a backup set name"))
      "DESCRIPTION" =>
        description = o.value.map(v => {
          self.backup_string(v, "a backup description")
        })
      "COMPRESSION" => compression = Some(true)
      "NO_COMPRESSION" => compression = Some(false)
      "CHECKSUM" => checksum = true
      "NO_CHECKSUM" => checksum = false
      "COPY_ONLY" => copy_only = true
      "STATS" =>
        stats = Some(
          match o.value {
            Some(v) => self.backup_int(v, "STATS")
            None => 10
          },
        )
      _ => ()
    }
  }
  // the database family: assigned at the first backup, kept by restores
  let family = match opts.family {
    Some(f) => f
    None => {
      let f = self.random_guid()
      self.server.db_options[key] = { ..opts, family: Some(f), }
      f
    }
  }
  let opts = self.server.db_options(display)
  let store = self.server.backups
  let pkey = backup_path_key(path)
  let media = match store.media.get(pkey) {
    Some(m) if !format => m
    _ => {
      let m : BackupMedia = {
        media_set_id: store.next_media_id,
        media_guid: self.random_guid(),
        family_guid: self.random_guid(),
        path,
        compressed: compression.unwrap_or(false),
        sets: [],
      }
      store.next_media_id += 1
      store.media_history.push(m)
      m
    }
  }
  if compression is Some(c) && c != media.compressed {
    raise @types.not_supported(
      "BACKUP with a compression setting other than the media's",
    )
  }
  let compressed = media.compressed
  let position = if format || init { 1 } else { media.sets.length() + 1 }
  let idents = []
  let seqs = []
  let prefix = key + ":"
  for k, v in self.server.idents {
    if k.has_prefix(prefix) {
      match key_id(k, prefix) {
        Some(id) => idents.push((id, v))
        None => ()
      }
    }
  }
  for k, v in self.server.seqs {
    if k.has_prefix(prefix) {
      match key_id(k, prefix) {
        Some(id) => seqs.push((id, { ..v, }))
        None => ()
      }
    }
  }
  let db = self.server.get_db(display)
  let procs = []
  for m in db.modules() {
    if m.kind is Procedure {
      match self.server.procs.get(m.name.to_lower()) {
        Some(p) => procs.push(p)
        None => ()
      }
    }
  }
  let set : BackupSet = {
    backup_set_id: store.next_set_id,
    media_set_id: media.media_set_id,
    position,
    name: set_name,
    description,
    database: display,
    user: self.login,
    options: opts,
    files: self.server.db_files(display),
    family,
    set_guid: self.random_guid(),
    binding: self.random_guid(),
    compressed,
    checksum,
    copy_only,
    start: self.rt.now,
    first_lsn: store.next_lsn,
    db,
    procs,
    idents,
    seqs,
  }
  store.next_set_id += 1
  store.next_lsn += 10000000L
  let sets = if position == 1 { [] } else { media.sets.copy() }
  sets.push(set)
  store.media[pkey] = { ..media, sets, }
  store.history.push({
    ..set,
    db: @store.Db::empty(),
    procs: [],
    idents: [],
    seqs: [],
  })
  self.backup_stats(stats, 228)
  self.backup_report(
    "BACKUP DATABASE",
    display,
    set.files,
    position,
    228,
    false,
  )
}

///|
/// RESTORE options accepted here; the others (NORECOVERY, STANDBY,
/// STOPAT, PARTIAL, RESTRICTED_USER, KEEP_*, ENABLE_BROKER, …) are
/// Emulator errors.
let restore_supported_options : Array[String] = [
  "FILE", "REPLACE", "MOVE", "RECOVERY", "STATS", "CHECKSUM", "NO_CHECKSUM", "REWIND",
  "NOREWIND", "UNLOAD", "NOUNLOAD", "BUFFERCOUNT", "MAXTRANSFERSIZE", "STOP_ON_ERROR",
]

///|
/// RESTORE DATABASE (229), HEADERONLY (250), FILELISTONLY (376),
/// VERIFYONLY (377).
fn Session::exec_restore(
  self : Session,
  kind : String,
  database : @ast.Expr?,
  devices : Array[@ast.BackupDevice],
  options : Array[@ast.BackupOption],
) -> Unit raise {
  let (cmd, what) = match kind {
    "DATABASE" => (229, "RESTORE DATABASE")
    "HEADERONLY" => (250, "RESTORE HEADERONLY")
    "FILELISTONLY" => (376, "RESTORE FILELIST")
    "VERIFYONLY" => (377, "VERIFY DATABASE")
    _ => raise @types.not_supported("RESTORE \{kind}")
  }
  self.cur_cmd = cmd
  let mut file = None
  let mut replace = false
  let moves : Array[(String, String)] = []
  let mut stats = None
  for o in options {
    if !restore_supported_options.contains(o.name) || o.args {
      raise @types.not_supported("RESTORE option \{o.name}")
    }
    match (o.name, o.value, o.move_to) {
      ("FILE", Some(v), _) => file = Some(self.backup_int(v, "FILE"))
      ("REPLACE", _, _) => replace = true
      ("MOVE", Some(l), Some(p)) =>
        moves.push(
          (
            self.backup_string(l, "a logical file name"),
            self.backup_string(p, "a physical file name"),
          ),
        )
      ("STATS", v, _) =>
        stats = Some(
          match v {
            Some(v) => self.backup_int(v, "STATS")
            None => 10
          },
        )
      ("FILE", None, _) | ("MOVE", _, _) =>
        raise @types.not_supported("RESTORE option \{o.name} without a value")
      _ => ()
    }
  }
  if kind != "DATABASE" && (replace || !moves.is_empty() || stats is Some(_)) {
    raise @types.not_supported("RESTORE \{kind} with REPLACE, MOVE or STATS")
  }
  let target = match database {
    Some(d) => Some(self.backup_string(d, "RESTORE of a database argument"))
    None => None
  }
  if kind == "DATABASE" && self.rt.trancount > 0 {
    raise self.backup_abort(what, [
      @types.sql_error(
        3021,
        "Cannot perform a backup or restore operation within a transaction.",
        state=0,
      ),
    ])
  }
  match target {
    Some(t) if t.to_lower() == "tempdb" =>
      raise self.backup_abort(what, [
        @types.sql_error(
          3147,
          "Backup and restore operations are not allowed on database tempdb.",
          state=3,
        ),
      ])
    Some(t) if t.to_lower() is ("master" | "model" | "msdb") =>
      raise @types.not_supported("RESTORE of a system database")
    _ => ()
  }
  let path = self.backup_device(devices)
  guard self.server.backups.media.get(backup_path_key(path)) is Some(media) else {
    raise self.backup_abort(what, [
      @types.sql_error(
        3201,
        "Cannot open backup device '\{path}'. Operating system error 2(The system cannot find the file specified.).",
        state=2,
      ),
    ])
  }
  let pick = (n : Int) => if n >= 1 { media.sets.get(n - 1) } else { None }
  match kind {
    "HEADERONLY" => {
      let sets = match file {
        None => media.sets
        Some(n) =>
          match pick(n) {
            Some(s) => [s]
            None =>
              raise self.backup_abort(what, [
                @types.sql_error(
                  4038,
                  "Cannot find file ID \{n} on device '\{path}'.",
                  state=3,
                ),
              ])
          }
      }
      self.restore_headeronly(sets)
      self.done(250)
      return
    }
    _ => ()
  }
  let n = file.unwrap_or(1)
  guard pick(n) is Some(set) else {
    let e = if kind == "DATABASE" {
      @types.sql_error(
        3287,
        "The file ID \{n} on device '\{path}' is incorrectly formed and can not be read.",
      )
    } else {
      @types.sql_error(4038, "Cannot find file ID \{n} on device '\{path}'.")
    }
    raise self.backup_abort(what, [e])
  }
  match kind {
    "FILELISTONLY" => {
      self.restore_filelistonly(set)
      self.done(376)
    }
    "VERIFYONLY" => {
      self.info(
        3262,
        1,
        "The backup set on file \{n} is valid.",
        self.stmt_line,
      )
      self.done(377)
    }
    _ =>
      self.restore_database(
        target.unwrap_or(""),
        set,
        replace,
        moves,
        stats,
        path,
      )
  }
}

///|
/// RESTORE DATABASE target from one backup set. Check order as captured:
/// 3102 / 3101 (database in use), 3154 / 3159 (an existing database of
/// another family / a FULL-recovery one without REPLACE), 3234 (MOVE of an
/// unknown logical file), 1834 + 3156 per file used by another database,
/// then 3119.
fn Session::restore_database(
  self : Session,
  target : String,
  set : BackupSet,
  replace : Bool,
  moves : Array[(String, String)],
  stats : Int?,
  path : String,
) -> Unit raise {
  let what = "RESTORE DATABASE"
  let key = target.to_lower()
  let exists = self.server.db_names.contains(key)
  if exists {
    if self.rt.database.to_lower() == key {
      raise self.backup_abort(what, [
        @types.sql_error(
          3102,
          "RESTORE cannot process database '\{target}' because it is in use by this session. It is recommended that the master database be used when performing this operation.",
        ),
      ])
    }
    // another session's own database counts, not a USE inside dynamic
    // SQL it is running (captured: a RESTORE succeeded while a second
    // session waited in `EXEC('USE copy; WAITFOR …')`)
    for spid, other in self.server.live {
      let own = other.outer_dbs.get(0).unwrap_or(other.rt.database)
      if spid != self.rt.spid && own.to_lower() == key {
        raise self.backup_abort(what, [
          @types.sql_error(
            3101, "Exclusive access could not be obtained because the database is in use.",
          ),
        ])
      }
    }
    if !replace {
      let opts = self.server.db_options(target)
      let same_family = match opts.family {
        Some(f) => f == set.family
        None => false
      }
      if !same_family {
        raise self.backup_abort(what, [
          @types.sql_error(
            3154,
            "The backup set holds a backup of a database other than the existing '\{target}' database.",
            state=4,
          ),
        ])
      }
      if opts.recovery != "SIMPLE" {
        raise self.backup_abort(what, [
          @types.sql_error(
            3159,
            "The tail of the log for the database \"\{target}\" has not been backed up. Use BACKUP LOG WITH NORECOVERY to backup the log if it contains work you do not want to lose. Use the WITH REPLACE or WITH STOPAT clause of the RESTORE statement to just overwrite the contents of the log.",
          ),
        ])
      }
    }
  }
  // MOVE: logical names compare case-insensitively (captured: MOVE
  // N'BKY_SRC' moved file 'bky_src')
  // over an existing database the files land where that database keeps
  // them (by file id), else at the backup's paths (captured: RESTORE …
  // WITH REPLACE without MOVE over a restored copy kept the copy's files)
  let current = if exists { self.server.db_files(target) } else { [] }
  let files = set.files.mapi((k, f) => {
    match current.get(k) {
      Some(c) => (f.0, c.1)
      None => f
    }
  })
  for mv in moves {
    match files.search_by(f => f.0.to_lower() == mv.0.to_lower()) {
      Some(k) => files[k] = (files[k].0, mv.1)
      None =>
        raise self.backup_abort(what, [
          @types.sql_error(
            3234,
            "Logical file '\{mv.0}' is not part of database '\{target}'. Use RESTORE FILELISTONLY to list the logical file names.",
            state=2,
          ),
        ])
    }
  }
  // a physical file of another database cannot be overwritten (paths
  // compare case-insensitively, captured)
  let errs = []
  for f in files {
    let p = f.1.to_lower()
    for k, owner in self.server.db_names {
      if k == key {
        continue
      }
      if self.server.db_files(owner).iter().any(x => x.1.to_lower() == p) {
        errs.push(
          @types.sql_error(
            1834,
            "The file '\{f.1}' cannot be overwritten.  It is being used by database '\{owner}'.",
          ),
        )
        errs.push(
          @types.sql_error(
            3156,
            "File '\{f.0}' cannot be restored to '\{f.1}'. Use WITH MOVE to identify a valid location for the file.",
            state=4,
          ),
        )
        break
      }
    }
  }
  if !errs.is_empty() {
    errs.push(
      @types.sql_error(
        3119, "Problems were identified while planning for the RESTORE statement. Previous messages provide details.",
      ),
    )
    raise self.backup_abort(what, errs)
  }
  let display = if exists { self.server.database_name(target) } else { target }
  // procedures are server-wide by name (session.mbt): the old database's
  // ones that no other database defines go, the backup's come back
  if exists {
    for m in self.server.get_db(display).modules() {
      if m.kind is Procedure {
        let pname = m.name.to_lower()
        let elsewhere = self.server.dbs
          .iter()
          .any(e => {
            e.0 != key &&
            e.1
            .modules()
            .iter()
            .any(x => x.kind is Procedure && x.name.to_lower() == pname)
          })
        if !elsewhere {
          self.server.procs.remove(pname)
        }
      }
    }
  }
  for p in set.procs {
    self.server.procs[p.name.to_lower()] = p
  }
  // a new database takes the next free database_id; one restored over
  // keeps its id
  if !exists {
    self.server.create_database(display)
  }
  self.server.set_db(display, set.db)
  self.server.db_options[key] = {
    ..set.options,
    files: Some(files),
    family: Some(set.family),
  }
  let prefix = key + ":"
  let stale = []
  for k, _ in self.server.idents {
    if k.has_prefix(prefix) {
      stale.push(k)
    }
  }
  for k in stale {
    self.server.idents.remove(k)
  }
  for x in set.idents {
    self.server.idents[prefix + x.0.to_string()] = x.1
  }
  let stale = []
  for k, _ in self.server.seqs {
    if k.has_prefix(prefix) {
      stale.push(k)
    }
  }
  for k in stale {
    self.server.seqs.remove(k)
  }
  for x in set.seqs {
    self.server.seqs[prefix + x.0.to_string()] = { ..x.1, }
  }
  let store = self.server.backups
  store.restores.push({
    id: store.next_restore_id,
    date: self.rt.now,
    database: display,
    user: self.login,
    backup_set_id: set.backup_set_id,
    replace,
    files: files.map(f => f.1),
  })
  store.next_restore_id += 1
  ignore(path)
  self.backup_stats(stats, 229)
  self.backup_report(
    "RESTORE DATABASE",
    display,
    files,
    set.position,
    229,
    true,
  )
}

///|
fn dec0(n : Int64) -> @types.Value {
  Decimal(@types.Decimal::from_int64(n))
}

///|
fn str_or_null(x : String?) -> @types.Value {
  match x {
    Some(v) => String(v)
    None => Null
  }
}

///|
/// BackupSize: the pages plus 9 header pages, in bytes (captured: 394
/// pages → 3301376, 418 → 3497984).
fn backup_size(set : BackupSet) -> Int64 {
  ignore(set)
  (BACKUP_DATA_PAGES + BACKUP_LOG_PAGES + 9).to_int64() * 8192L
}

///|
/// Flags of a backup set: 512, +16 with CHECKSUM, +1024 COPY_ONLY
/// (captured: 512, 528, 1536, 1552).
fn backup_flags(set : BackupSet) -> Int {
  512 +
  (if set.checksum { 16 } else { 0 }) +
  (if set.copy_only { 1024 } else { 0 })
}

///|
let headeronly_columns : Array[(String, @types.SqlType)] = [
  ("BackupName", nvc(128)),
  ("BackupDescription", nvc(255)),
  ("BackupType", TinyInt),
  ("ExpirationDate", DateTime),
  ("Compressed", TinyInt),
  ("Position", SmallInt),
  ("DeviceType", TinyInt),
  ("UserName", nvc(128)),
  ("ServerName", nvc(128)),
  ("DatabaseName", nvc(128)),
  ("DatabaseVersion", Int),
  ("DatabaseCreationDate", DateTime),
  ("BackupSize", BigInt),
  ("FirstLSN", Numeric(25, 0)),
  ("LastLSN", Numeric(25, 0)),
  ("CheckpointLSN", Numeric(25, 0)),
  ("DatabaseBackupLSN", Numeric(25, 0)),
  ("BackupStartDate", DateTime),
  ("BackupFinishDate", DateTime),
  ("SortOrder", SmallInt),
  ("CodePage", SmallInt),
  ("UnicodeLocaleId", Int),
  ("UnicodeComparisonStyle", Int),
  ("CompatibilityLevel", TinyInt),
  ("SoftwareVendorId", Int),
  ("SoftwareVersionMajor", Int),
  ("SoftwareVersionMinor", Int),
  ("SoftwareVersionBuild", Int),
  ("MachineName", nvc(128)),
  ("Flags", Int),
  ("BindingID", UniqueIdentifier),
  ("RecoveryForkID", UniqueIdentifier),
  ("Collation", nvc(128)),
  ("FamilyGUID", UniqueIdentifier),
  ("HasBulkLoggedData", Bit),
  ("IsSnapshot", Bit),
  ("IsReadOnly", Bit),
  ("IsSingleUser", Bit),
  ("HasBackupChecksums", Bit),
  ("IsDamaged", Bit),
  ("BeginsLogChain", Bit),
  ("HasIncompleteMetaData", Bit),
  ("IsForceOffline", Bit),
  ("IsCopyOnly", Bit),
  ("FirstRecoveryForkID", UniqueIdentifier),
  ("ForkPointLSN", Numeric(25, 0)),
  ("RecoveryModel", nvc(60)),
  ("DifferentialBaseLSN", Numeric(25, 0)),
  ("DifferentialBaseGUID", UniqueIdentifier),
  ("BackupTypeDescription", nvc(128)),
  ("BackupSetGUID", UniqueIdentifier),
  ("CompressedBackupSize", BigInt),
  ("Containment", TinyInt),
  ("KeyAlgorithm", nvc(32)),
  ("EncryptorThumbprint", VarBinary(Some(20))),
  ("EncryptorType", nvc(32)),
  ("LastValidRestoreTime", DateTime),
  ("TimeZone", SmallInt),
  ("CompressionAlgorithm", nvc(32)),
]

///|
fn Session::restore_result(
  self : Session,
  cols : Array[(String, @types.SqlType)],
  rows : Array[Array[@types.Value]],
) -> Unit {
  self.out.push(ResultSet(cols.map(c => spc(c.0, c.1, 1))))
  for r in rows {
    self.out.push(Row(r.map(wire_value)))
  }
  self.done(230, count=Some(rows.length().to_int64()), result_set=true)
}

///|
/// RESTORE HEADERONLY: one row per backup set (captured: 59 columns, all
/// nullable; DONE 230 with the count, then 250).
fn Session::restore_headeronly(self : Session, sets : Array[BackupSet]) -> Unit {
  let (major, minor, build) = self.rt.build
  let rows = sets.map(set => {
    let size = backup_size(set)
    let row : Array[@types.Value] = [
      str_or_null(set.name),
      str_or_null(set.description),
      TinyInt(1),
      Null,
      TinyInt(if set.compressed { 1 } else { 0 }),
      SmallInt(set.position),
      TinyInt(2),
      String(set.user),
      String(self.rt.server_name),
      String(set.database),
      Int(998),
      dt(set.start),
      BigInt(size),
      dec0(set.first_lsn),
      dec0(set.first_lsn + 2400000L),
      dec0(set.first_lsn),
      dec0(0L),
      dt(set.start),
      dt(set.start),
      SmallInt(52),
      SmallInt(0),
      Int(1033),
      Int(196609),
      TinyInt(set.options.compat_level),
      Int(4608),
      Int(major),
      Int(minor),
      Int(build),
      String(self.rt.server_name),
      Int(backup_flags(set)),
      Guid(set.binding),
      Guid(set.family),
      String(set.options.collation.name),
      Guid(set.family),
      Bit(false),
      Bit(false),
      Bit(false),
      Bit(false),
      Bit(set.checksum),
      Bit(false),
      Bit(false),
      Bit(false),
      Bit(false),
      Bit(set.copy_only),
      Guid(set.family),
      Null,
      String(set.options.recovery),
      Null,
      Null,
      String("Database"),
      Guid(set.set_guid),
      BigInt(size),
      TinyInt(0),
      Null,
      Null,
      Null,
      Null,
      SmallInt(0),
      if set.compressed {
        String("MS_XPRESS")
      } else {
        Null
      },
    ]
    row
  })
  self.restore_result(headeronly_columns, rows)
}

///|
let filelistonly_columns : Array[(String, @types.SqlType)] = [
  ("LogicalName", nvc(128)),
  ("PhysicalName", nvc(260)),
  ("Type", NChar(1, @types.default_collation)),
  ("FileGroupName", nvc(128)),
  ("Size", BigInt),
  ("MaxSize", BigInt),
  ("FileId", BigInt),
  ("CreateLSN", Numeric(25, 0)),
  ("DropLSN", Numeric(25, 0)),
  ("UniqueId", UniqueIdentifier),
  ("ReadOnlyLSN", Numeric(25, 0)),
  ("ReadWriteLSN", Numeric(25, 0)),
  ("BackupSizeInBytes", BigInt),
  ("SourceBlockSize", Int),
  ("FileGroupId", Int),
  ("LogGroupGUID", UniqueIdentifier),
  ("DifferentialBaseLSN", Numeric(25, 0)),
  ("DifferentialBaseGUID", UniqueIdentifier),
  ("IsReadOnly", Bit),
  ("IsPresent", Bit),
  ("TDEThumbprint", VarBinary(Some(20))),
  ("SnapshotUrl", nvc(336)),
]

///|
/// RESTORE FILELISTONLY: the data and log file of the set (captured: a
/// fresh file is 1024 pages, data max size 2^45 bytes, log 2 TB).
fn Session::restore_filelistonly(self : Session, set : BackupSet) -> Unit {
  let rows = set.files.mapi((k, f) => {
    let data = k == 0
    let row : Array[@types.Value] = [
      String(f.0),
      String(f.1),
      String(if data { "D" } else { "L" }),
      if data {
        String("PRIMARY")
      } else {
        Null
      },
      BigInt(8388608L),
      BigInt(if data { 35184372080640L } else { 2199023255552L }),
      BigInt((k + 1).to_int64()),
      dec0(0L),
      dec0(0L),
      name_guid(set.database, k + 1),
      dec0(0L),
      dec0(0L),
      BigInt(if data { (BACKUP_DATA_PAGES + 8).to_int64() * 8192L } else { 0L }),
      Int(4096),
      Int(if data { 1 } else { 0 }),
      Null,
      dec0(if data { set.first_lsn } else { 0L }),
      if data {
        Guid(set.set_guid)
      } else {
        Guid(Bytes::make(16, b'\x00'))
      },
      Bit(false),
      Bit(true),
      Null,
      Null,
    ]
    row
  })
  self.restore_result(filelistonly_columns, rows)
}
