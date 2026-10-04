///|
/// BACKUP is not emulated, but a database that does not exist fails the
/// same way whatever the device: 911 (state 11, LOG 10) then 3013, DONE
/// 228 (LOG 235) with the error bit, the batch continues and @@ERROR is
/// 3013; TRY catches only 3013 (captured: msduck gaps-backup#014,
/// tail/backup-errors). An existing database is an Emulator error, as is
/// RESTORE: whether a backup file exists cannot be known here.
fn Session::exec_backup(
  self : Session,
  log : Bool,
  database : @ast.Expr,
) -> Unit raise {
  self.cur_cmd = if log { 235 } else { 228 }
  let name = match database.kind {
    Column([id]) => id.name
    _ =>
      match self.eval(database) {
        (String(s), _) => s
        _ => raise @types.not_supported("BACKUP of this database argument")
      }
  }
  if self.server.db_names.contains(name.to_lower()) {
    raise @types.not_supported("BACKUP")
  }
  let what = if log { "BACKUP LOG" } else { "BACKUP DATABASE" }
  if self.try_depth == 0 {
    self.message(
      @types.sql_error(
        911,
        "Database '\{name}' does not exist. Make sure that the name is entered correctly.",
        state=if log { 10 } else { 11 },
      ),
      self.stmt_line,
    )
  }
  raise @types.sql_error(3013, "\{what} is terminating abnormally.")
}
