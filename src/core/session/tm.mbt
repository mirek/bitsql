///|
/// Isolation level names by TM code (MS-TDS 2.2.6.9).
fn tm_isolation(level : Int) -> String? {
  match level {
    1 => Some("READ UNCOMMITTED")
    2 => Some("READ COMMITTED")
    3 => Some("REPEATABLE READ")
    4 => Some("SERIALIZABLE")
    5 => Some("SNAPSHOT")
    _ => None
  }
}

///|
/// Runs a transaction manager request. Responses (captured: corpus tm/):
/// ENVCHANGE when @@TRANCOUNT crosses 0, then DONE with CurCmd 253 and no
/// count; failures are ERROR + DONE(error). The isolation level of BEGIN
/// stays the session's level after the transaction.
pub fn Session::run_tm(
  self : Session,
  req : @tds.TmRequest,
  now : Int64,
) -> Array[@reply.Item] {
  self.rt.now = now
  self.rt.work_done = 0L
  self.out.clear()
  self.rpc = false
  self.frames.clear()
  self.frames.push(Frame::new())
  let begin = (level : Int, name : String) => {
    match tm_isolation(level) {
      Some(l) => self.isolation = l
      None => ()
    }
    self.begin_tx()
    self.rt.trancount += 1
    if self.rt.xact_state != -1 {
      self.rt.xact_state = 1
    }
    ignore(name) // names are not checked (SQL BEGIN TRAN names are not either)
    if self.rt.trancount == 1 {
      self.out.push(EnvChange(BeginTransaction(self.tx_descriptor())))
    }
  }
  let result : Result[Unit, @types.SqlError] = try {
    match req {
      Begin(level, name) => begin(level, name)
      Commit(_, begin_new~) => {
        if self.rt.trancount == 0 {
          raise @types.sql_error(
            3902,
            "The COMMIT TRANSACTION request has no corresponding BEGIN TRANSACTION.",
            state=3,
          )
        }
        if self.rt.xact_state == -1 {
          raise doomed_error()
        }
        self.rt.trancount -= 1
        if self.rt.trancount == 0 {
          let d = self.tx_descriptor()
          self.commit_tx()
          self.rt.xact_state = 0
          self.out.push(EnvChange(CommitTransaction(d)))
        }
        match begin_new {
          Some((level, name)) => begin(level, name)
          None => ()
        }
      }
      Rollback(name, begin_new~) => {
        if self.rt.trancount == 0 {
          raise @types.sql_error(
            3903,
            "The ROLLBACK TRANSACTION request has no corresponding BEGIN TRANSACTION.",
            state=2,
          )
        }
        let savepoint = match self.tx {
          Some(tx) if name != "" => tx.savepoints.get(name.to_lower())
          _ => None
        }
        match (savepoint, self.tx) {
          (Some((view, temp)), Some(tx)) => {
            tx.view = view
            self.temp = temp
          }
          _ => {
            let d = self.tx_descriptor()
            self.rt.trancount = 0
            self.rt.xact_state = 0
            self.rollback_tx()
            self.out.push(EnvChange(RollbackTransaction(d)))
          }
        }
        match begin_new {
          Some((level, name)) => begin(level, name)
          None => ()
        }
      }
      Save(name) => {
        if self.rt.trancount == 0 {
          raise @types.sql_error(
            628, "Cannot issue SAVE TRANSACTION when there is no active transaction.",
          )
        }
        match self.tx {
          Some(tx) => tx.savepoints[name.to_lower()] = (tx.view, self.temp)
          None => ()
        }
      }
      Unsupported(code) =>
        raise @types.not_supported(
          "distributed transaction manager request \{code}",
        )
    }
    Ok(())
  } catch {
    e => Err(e)
  }
  match result {
    Ok(_) => self.out.push(StatementDone(cmd=253, count=None, error=false))
    Err(e) => {
      self.message(e, 1)
      self.out.push(StatementDone(cmd=253, count=None, error=true))
    }
  }
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}
