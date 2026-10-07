///|
/// ATTENTION (TDS cancel) of a parked request. The engine re-runs the
/// parked request with `cancelling` set; the first wait it reaches (lock,
/// application lock, WAITFOR) cancels instead of parking. The interrupted
/// statement is rolled back (statement level), earlier statements keep
/// their effects (an open transaction stays open), XACT_ABORT ON rolls the
/// transaction back, and the request ends with SQL Server's cancel
/// completion; the engine then sends DONE_ATTN as a separate message.
///
/// Captured from SQL Server 17.0.5005.3 (wire probes, harness/test/
/// attention.test.mjs):
/// - the request's own response ends with DONE(ERROR) (batch) or
///   DONEPROC(ERROR, 224) (RPC); no ERROR token;
/// - SQL Server holds back the last statement completion (its MORE bit is
///   not known yet). In a batch it becomes the final DONE(ERROR, its
///   CurCmd, no count); without one the CurCmd is 253. In an RPC it is
///   dropped. A SELECT whose COLMETADATA went out completes as
///   DONE(ERROR, 193) instead;
/// - a DML statement waiting on a lock adds INFO 3621 before that final
///   completion (not under XACT_ABORT ON, which rolls back and puts the
///   ROLLBACK ENVCHANGE before DONE(ERROR, 253));
/// - inside TRY the interrupted statement completes with its own CurCmd
///   (no CATCH runs); inside a procedure in TRY its DONEINPROC stays and
///   the request ends with DONEPROC(ERROR, 224).
priv struct Attention {
  /// Set by the engine before re-running a parked request.
  mut cancelling : Bool
  /// A wait was cancelled in the current request.
  mut hit : Bool
  /// The interrupted statement did its bookkeeping (innermost exec_one).
  mut handled : Bool
  /// CurCmd of the interrupted statement's own completion (253: none).
  mut cmd : Int
  /// INFO 3621 follows (a DML statement, no XACT_ABORT).
  mut terminated : Bool
  mut in_try : Bool
  mut line : Int
}

///|
fn Attention::new() -> Attention {
  {
    cancelling: false,
    hit: false,
    handled: false,
    cmd: 253,
    terminated: false,
    in_try: false,
    line: 1,
  }
}

///|
fn Attention::reset(self : Attention) -> Unit {
  self.hit = false
  self.handled = false
  self.cmd = 253
  self.terminated = false
  self.in_try = false
  self.line = 1
}

///|
/// ATTENTION for a parked request: abandon its wait; the engine re-runs it
/// and the re-run stops at the wait it parked in (completed WAITFORs are
/// passed again).
pub fn Session::attention(self : Session) -> Unit {
  self.attn.cancelling = true
  match self.waiting {
    Some(r) => self.server.wake_all(self.server.locks.cancel(r))
    None => ()
  }
  self.waiting = None
  self.in_waitfor = false
}

///|
/// True when the last request was ended by ATTENTION (the engine renders an
/// RPC's final DONEPROC with the error bit).
pub fn Session::was_cancelled(self : Session) -> Bool {
  self.attn.hit
}

///|
/// Called where a request would park: under ATTENTION the wait is
/// cancelled instead (its lock request withdrawn) and the request unwinds.
fn Session::cancel_at_wait(self : Session, request : Int?) -> Unit raise {
  guard self.attn.cancelling else { return }
  match request {
    Some(r) => self.server.wake_all(self.server.locks.cancel(r))
    None => ()
  }
  self.attn.hit = true
  raise Park
}

///|
/// The innermost statement interrupted by ATTENTION (after its
/// statement-level rollback, see exec_one).
fn Session::statement_attention(
  self : Session,
  out_mark : Int,
  line : Int,
) -> Unit {
  self.attn.handled = true
  self.attn.line = line
  let dml = (self.cur_cmd >= 195 && self.cur_cmd <= 197) ||
    self.cur_cmd == 279 ||
    self.cur_cmd == 125 ||
    self.cur_cmd == 126
  self.attn.terminated = dml && !self.xact_abort
  self.attn.in_try = self.try_depth > 0
  let mark = @cmp.minimum(out_mark, self.out.length())
  let result_started = self.out[mark:].iter().any(x => x is ResultSet(_))
  if self.rt.cancel_pending {
    self.attn.in_try = false
    if self.cur_cmd == 193 {
      self.attn.cmd = 193
    }
  } else if self.try_depth > 0 {
    self.done(self.cur_cmd)
  } else if result_started {
    self.attn.cmd = self.cur_cmd
  }
  if self.xact_abort && self.rt.trancount > 0 {
    self.abort_transaction()
  }
}

///|
/// Ends the response of a cancelled request (see `Attention`).
fn Session::finish_attention(self : Session) -> Unit {
  for f in self.frames {
    self.release_frame_cursors(f)
  }
  self.try_depth = 0
  self.rt.nest_level = 0
  let terminated = () => {
    if self.attn.terminated {
      self.out.push(
        Message({
          number: 3621,
          state: 0,
          class: 0,
          message: "The statement has been terminated.",
          procedure: "",
          line: self.attn.line,
        }),
      )
    }
  }
  let held : (Int, Bool)? = match self.out.last() {
    Some(StatementDone(cmd~, ..)) => Some((cmd, false))
    Some(InProcDone(cmd~, ..)) => Some((cmd, true))
    _ => None
  }
  if self.rpc {
    if held is Some(_) && !self.attn.in_try {
      ignore(self.out.pop())
    }
    terminated()
    // the final DONEPROC(ERROR, 224) is rendered by the engine
    return
  }
  if self.attn.cmd != 253 {
    terminated()
    self.out.push(StatementDone(cmd=self.attn.cmd, count=None, error=true))
    return
  }
  match held {
    Some((_, true)) if self.attn.in_try => {
      terminated()
      self.out.push(ProcDone(cmd=224, count=None, error=true))
    }
    Some((cmd, _)) => {
      ignore(self.out.pop())
      terminated()
      self.out.push(StatementDone(cmd~, count=None, error=true))
    }
    None => {
      terminated()
      self.out.push(StatementDone(cmd=253, count=None, error=true))
    }
  }
}
