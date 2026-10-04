///|
/// Dynamic management views over the live sessions (Server.live). Only user
/// sessions are listed: SQL Server's ~40 system sessions (is_user_process 0)
/// are not modelled, so unfiltered counts differ. Column values follow a
/// tedious session on the oracle (captured 2026-10-03).
fn Session::dmv_rows(self : Session, key : String) -> Array[VRow] {
  let out : Array[VRow] = []
  let spids = self.server.live.keys().collect()
  spids.sort()
  for spid in spids {
    guard self.server.live.get(spid) is Some(x) else { continue }
    let me = spid == self.rt.spid
    let isolation = match x.isolation {
      "READ UNCOMMITTED" => 1
      "REPEATABLE READ" => 3
      "SERIALIZABLE" => 4
      "SNAPSHOT" => 5
      _ => 2
    }
    let db_id = x.db_id()
    let common = [
      ("session_id", @types.Value::SmallInt(spid)),
      ("text_size", i(2147483647)),
      ("language", s("us_english")),
      ("date_format", s("mdy")),
      ("date_first", SmallInt(x.rt.datefirst)),
      ("quoted_identifier", Bit(true)),
      ("arithabort", Bit(true)),
      ("ansi_null_dflt_on", Bit(true)),
      ("ansi_defaults", Bit(false)),
      ("ansi_warnings", Bit(true)),
      ("ansi_padding", Bit(true)),
      ("ansi_nulls", Bit(true)),
      ("concat_null_yields_null", Bit(true)),
      ("transaction_isolation_level", SmallInt(isolation)),
      ("lock_timeout", i(x.lock_timeout)),
      ("deadlock_priority", i(self.server.priorities.get(spid).unwrap_or(0))),
      ("row_count", BigInt(x.rt.rowcount)),
      ("prev_error", i(x.rt.error)),
      ("database_id", SmallInt(db_id)),
      ("open_transaction_count", i(x.rt.trancount)),
    ]
    match key {
      "sys.dm_exec_sessions" => {
        let r = vrow(common)
        r["login_time"] = dt(x.login_time)
        r["host_name"] = s(x.host_name)
        r["program_name"] = s(x.app_name)
        r["client_version"] = i(7)
        r["client_interface_name"] = s(x.library)
        r["security_id"] = Binary(b"\\x01")
        r["original_security_id"] = Binary(b"\\x01")
        r["login_name"] = s(x.login)
        r["original_login_name"] = s(x.login)
        r["status"] = s(if me { "running" } else { "sleeping" })
        r["is_user_process"] = Bit(true)
        r["endpoint_id"] = i(4)
        r["authenticating_database_id"] = i(1)
        r["last_request_start_time"] = dt(x.rt.now)
        r["last_request_end_time"] = dt(x.rt.now)
        match x.context_info {
          Some(b) => r["context_info"] = Binary(b)
          None => ()
        }
        out.push(r)
      }
      "sys.dm_exec_requests" => {
        // the running request (this one) and parked ones
        guard me || x.parked else { continue }
        let r = vrow(common)
        r["request_id"] = i(0)
        r["blocking_session_id"] = SmallInt(0)
        r["start_time"] = dt(x.rt.now)
        r["user_id"] = i(1)
        r["nest_level"] = i(if me { 1 } else { 0 })
        r["status"] = s(if me { "running" } else { "suspended" })
        r["command"] = s(
          match x.cur_cmd {
            195 => "INSERT"
            196 => "DELETE"
            197 => "UPDATE"
            279 => "MERGE"
            243 => "WAITFOR"
            _ => "SELECT"
          },
        )
        if !me {
          // a suspended statement counts its own transaction on top
          // (captured: 2 in autocommit and inside BEGIN TRAN)
          r["open_transaction_count"] = i(@cmp.maximum(x.rt.trancount, 1) + 1)
          match x.waiting {
            Some(req) =>
              match self.server.locks.waiting_on(req) {
                Some((mode, blockers)) => {
                  r["wait_type"] = s(
                    match mode {
                      S => "LCK_M_S"
                      U => "LCK_M_U"
                      X => "LCK_M_X"
                      IS => "LCK_M_IS"
                      IX => "LCK_M_IX"
                    },
                  )
                  match blockers.get(0) {
                    Some(b) => r["blocking_session_id"] = SmallInt(b)
                    None => ()
                  }
                }
                None => ()
              }
            None => if x.in_waitfor { r["wait_type"] = s("WAITFOR") }
          }
        }
        out.push(r)
      }
      "sys.dm_exec_connections" =>
        out.push(
          vrow([
            ("session_id", i(spid)),
            ("most_recent_session_id", i(spid)),
            ("connect_time", dt(x.login_time)),
            ("net_transport", s("TCP")),
            ("protocol_type", s("TSQL")),
            ("protocol_version", i(1946157060)),
            ("endpoint_id", i(4)),
            ("encrypt_option", s(if x.encrypted { "TRUE" } else { "FALSE" })),
            ("auth_scheme", s("SQL")),
            ("node_affinity", SmallInt(0)),
          ]),
        )
      _ => ()
    }
  }
  out
}
