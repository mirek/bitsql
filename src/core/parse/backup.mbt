///|
/// BACKUP options SQL Server accepts (anything else is 155, state 1 for a
/// bare word, 2 for `word = value`; captured: msduck gaps-backup#029,
/// tail/backup-errors).
let backup_options : Array[String] = [
  "BLOCKSIZE", "BUFFERCOUNT", "CHECKSUM", "COMPRESSION", "CONTINUE_AFTER_ERROR",
  "COPY_ONLY", "CREDENTIAL", "DESCRIPTION", "DIFFERENTIAL", "ENCRYPTION", "EXPIREDATE",
  "FILE_SNAPSHOT", "FORMAT", "INIT", "MAXTRANSFERSIZE", "MEDIADESCRIPTION", "MEDIANAME",
  "MEDIAPASSWORD", "METADATA_ONLY", "NAME", "NO_CHECKSUM", "NO_COMPRESSION", "NO_TRUNCATE",
  "NOFORMAT", "NOINIT", "NORECOVERY", "NOREWIND", "NOSKIP", "NOUNLOAD", "PASSWORD",
  "RESTART", "RETAINDAYS", "REWIND", "SKIP", "STANDBY", "STATS", "STOP_ON_ERROR",
  "UNLOAD", "BACKUP_OPTIONS",
]

///|
/// `BACKUP DATABASE|LOG name TO device [, ...] [WITH option [= value], ...]`
/// (the BACKUP keyword is consumed).
fn Parser::backup_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  let log = if self.eat_kw("DATABASE") {
    false
  } else if self.eat_kw("LOG") {
    true
  } else {
    raise self.error()
  }
  let database = self.backup_database()
  self.expect_kw("TO")
  let devices = self.backup_devices()
  let options = self.backup_options(validate=true)
  Backup(log~, database~, devices~, options~)
}

///|
/// `RESTORE kind [name] [FROM device [, ...]] [WITH option, ...]` (the
/// RESTORE keyword is consumed).
fn Parser::restore_stmt(self : Parser) -> @ast.StmtKind raise @ast.SyntaxError {
  let t = self.peek()
  if !(t.kind is Word) {
    raise self.error()
  }
  let kind = upper(t)
  self.pos += 1
  let database = if kind == "DATABASE" || kind == "LOG" {
    Some(self.backup_database())
  } else {
    None
  }
  let devices = if self.eat_kw("FROM") { self.backup_devices() } else { [] }
  let options = self.backup_options(validate=false)
  Restore(kind~, database~, devices~, options~)
}

///|
fn Parser::backup_database(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let t = self.peek()
  if t.kind is Variable {
    self.pos += 1
    return mk(Var(t.text), t.span)
  }
  let name = self.ident()
  mk(Column([name]), name.span)
}

///|
/// A string, number or variable option value.
fn Parser::backup_value(self : Parser) -> @ast.Expr raise @ast.SyntaxError {
  let v = self.peek()
  match v.kind {
    Str | NStr | Variable | IntNum => self.primary()
    Word | QuotedIdent => {
      let id = self.ident()
      mk(Column([id]), id.span)
    }
    _ => raise self.error()
  }
}

///|
/// `DISK|URL|TAPE = 'x' | @v`, or a logical device name, comma-separated.
fn Parser::backup_devices(
  self : Parser,
) -> Array[@ast.BackupDevice] raise @ast.SyntaxError {
  let out : Array[@ast.BackupDevice] = []
  while true {
    let t = self.peek()
    if t.kind is Variable {
      self.pos += 1
      out.push({ kind: "", value: mk(Var(t.text), t.span) })
    } else if t.kind is Word && self.is_punct_at(1, "=") {
      self.pos += 2
      let v = self.peek()
      if !(v.kind is (Str | NStr | Variable)) {
        raise self.error()
      }
      out.push({ kind: upper(t), value: self.primary() })
    } else {
      let id = self.ident()
      out.push({ kind: "", value: mk(Column([id]), id.span) })
    }
    if !self.eat_punct(",") {
      break
    }
  }
  out
}

///|
/// `WITH option [= value | (...)] [, ...]`; MOVE 'a' TO 'b' for RESTORE.
fn Parser::backup_options(
  self : Parser,
  validate~ : Bool,
) -> Array[@ast.BackupOption] raise @ast.SyntaxError {
  let out : Array[@ast.BackupOption] = []
  if !self.eat_kw("WITH") {
    return out
  }
  while true {
    let t = self.peek()
    if !(t.kind is Word) {
      raise self.error()
    }
    let name = upper(t)
    self.pos += 1
    let has_value = self.is_punct("=")
    if validate && !backup_options.contains(name) {
      raise @ast.SyntaxError(
        number=155,
        severity=15,
        state=if has_value { 2 } else { 1 },
        message="'\{t.text}' is not a recognized BACKUP option.",
        span=t.span,
      )
    }
    let mut value = None
    let mut move_to = None
    let mut args = false
    if name == "MOVE" {
      value = Some(self.backup_value())
      self.expect_kw("TO")
      move_to = Some(self.backup_value())
    } else if self.eat_punct("=") {
      value = Some(self.backup_value())
    } else if self.is_punct("(") {
      // COMPRESSION (ALGORITHM = ...), ENCRYPTION (...): skip to the match
      args = true
      let mut depth = 0
      while true {
        let x = self.peek()
        if x.kind is Eof {
          raise self.error()
        }
        self.pos += 1
        if x.is_punct("(") {
          depth += 1
        } else if x.is_punct(")") {
          depth -= 1
          if depth == 0 {
            break
          }
        }
      }
    }
    out.push({ name, value, move_to, args, span: t.span })
    if !self.eat_punct(",") {
      break
    }
  }
  out
}
