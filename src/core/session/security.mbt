///|
/// Identity and permission functions. bitsql has one login, `sa`, mapped to
/// `dbo` in every database (captured: corpus misc/security-functions).
fn Session::security_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? {
  let text = (k : Int) => {
    match args.get(k) {
      Some(String(s)) => Some(s)
      _ => None
    }
  }
  let num = (k : Int) => {
    match args.get(k) {
      Some(v) => v.as_int64().map(x => x.to_int())
      None => None
    }
  }
  let user_by_id = (id : Int) => {
    match id {
      1 => Some("dbo")
      2 => Some("guest")
      3 => Some("INFORMATION_SCHEMA")
      4 => Some("sys")
      _ => None
    }
  }
  let r : @types.Value = match name {
    "USER_NAME" =>
      match args.get(0) {
        None => String("dbo")
        Some(_) =>
          match num(0).bind(user_by_id) {
            Some(u) => String(u)
            None => Null
          }
      }
    "USER_ID" =>
      match text(0) {
        None if args.is_empty() => SmallInt(1)
        Some(n) =>
          match n.to_lower() {
            "dbo" => SmallInt(1)
            "guest" => SmallInt(2)
            "information_schema" => SmallInt(3)
            "sys" => SmallInt(4)
            _ => Null
          }
        None => Null
      }
    "SUSER_NAME" | "SUSER_SNAME" =>
      if args.is_empty() || num(0) == Some(1) || text(0) == Some("\u{01}") {
        String(self.login)
      } else {
        Null
      }
    "SUSER_ID" =>
      if args.is_empty() || text(0).map(s => s.to_lower()) == Some("sa") {
        Int(1)
      } else {
        Null
      }
    "SUSER_SID" =>
      if args.is_empty() || text(0).map(s => s.to_lower()) == Some("sa") {
        Binary(b"\x01")
      } else {
        Null
      }
    "CURRENT_USER" | "SESSION_USER" | "USER" => String("dbo")
    "SYSTEM_USER" | "ORIGINAL_LOGIN" => String(self.login)
    "APP_NAME" => String(self.app_name)
    "HOST_NAME" => String(self.host_name)
    "HOST_ID" => return None
    "@@DBTS" => Binary(rowversion_bytes(self.server.dbts))
    // the lowest rowversion an open transaction has assigned, else the next
    // one (captured: traps/rowversion-modification-time)
    "MIN_ACTIVE_ROWVERSION" => {
      let mut low = self.server.dbts + 1L
      for _, v in self.server.active_rv {
        if v < low {
          low = v
        }
      }
      Binary(rowversion_bytes(low))
    }
    "SESSION_CONTEXT" =>
      match text(0) {
        Some(k) =>
          // keys are set case-sensitively (N'LOCKED' is another key than
          // a read-only N'locked') but read case-insensitively, the exact
          // spelling first (captured: msduck session-property-context#068,
          // gaps-computed session-default-values-6)
          match self.session_context.get(k) {
            Some((v, _)) => v
            None => {
              let lower = k.to_lower()
              let mut found : @types.Value = Null
              for key, entry in self.session_context {
                if key.to_lower() == lower {
                  found = entry.0
                  break
                }
              }
              found
            }
          }
        None => Null
      }
    "CONTEXT_INFO" =>
      match self.context_info {
        Some(b) => Binary(b)
        None => Null
      }
    "IS_SRVROLEMEMBER" =>
      match text(0).map(s => s.to_lower()) {
        Some("sysadmin") => Int(1)
        Some(
          "serveradmin"
          | "securityadmin"
          | "processadmin"
          | "setupadmin"
          | "bulkadmin"
          | "diskadmin"
          | "dbcreator"
          | "public"
        ) => Int(0)
        _ => Null
      }
    "IS_MEMBER" | "IS_ROLEMEMBER" =>
      match text(0).map(s => s.to_lower()) {
        Some("db_owner" | "public") => Int(1)
        Some(
          "db_accessadmin"
          | "db_securityadmin"
          | "db_ddladmin"
          | "db_backupoperator"
          | "db_datareader"
          | "db_datawriter"
          | "db_denydatareader"
          | "db_denydatawriter"
        ) => Int(0)
        _ => Null
      }
    "HAS_DBACCESS" =>
      match text(0) {
        Some(db) if self.server.has_database(db) => Int(1)
        _ => Null
      }
    "DATABASE_PRINCIPAL_ID" =>
      match text(0).map(s => s.to_lower()) {
        None if args.is_empty() => Int(1)
        Some("dbo") => Int(1)
        Some("public") => Int(0)
        Some("guest") => Int(2)
        _ => Null
      }
    "PERMISSIONS" => if args.is_empty() { Int(50201342) } else { return None }
    _ => return None
  }
  Some(r)
}
