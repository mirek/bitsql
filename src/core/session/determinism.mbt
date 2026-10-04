///|
/// Non-deterministic built-ins by name: PERSISTED computed columns reject
/// them with 4936 (captured: constraints/persisted-determinism). Besides
/// the clock and randomness, SQL Server counts every metadata, security,
/// session and error function, every `@@` global, FORMAT, DATENAME, ISDATE,
/// PARSE, AT TIME ZONE and the DATEFIRST-dependent DATEPART parts. RAND
/// with a seed is deterministic.
fn expr_nondeterministic(e : @ast.Expr) -> Bool {
  let mut found = false
  walk_expr(e, x => {
    match x.kind {
      GlobalVar(_) | Parse(_, _, ..) | AtTimeZone(_, _) => found = true
      Call(c) =>
        match c.name.base().to_lower() {
          "rand" => if c.args.is_empty() { found = true }
          "datepart" =>
            if c.args.length() > 0 &&
              c.args[0].kind is Column([p]) &&
              p.name.to_lower() is ("week" | "wk" | "ww" | "weekday" | "dw") {
              found = true
            }
          name => if nondeterministic_function(name) { found = true }
        }
      _ => ()
    }
  })
  found
}

///|
fn nondeterministic_function(name : String) -> Bool {
  match name {
    "newid"
    | "newsequentialid"
    | "getdate"
    | "getutcdate"
    | "sysdatetime"
    | "sysutcdatetime"
    | "sysdatetimeoffset"
    | "current_timestamp"
    | "current_date"
    | "current_timezone"
    | "current_timezone_id"
    | "current_transaction_id"
    | "crypt_gen_random"
    | "compress"
    | "format"
    | "formatmessage"
    | "datename"
    | "isdate"
    | "host_name"
    | "host_id"
    | "app_name"
    | "suser_sname"
    | "suser_name"
    | "suser_id"
    | "suser_sid"
    | "user_name"
    | "user_id"
    | "current_user"
    | "session_user"
    | "system_user"
    | "user"
    | "original_login"
    | "is_member"
    | "is_srvrolemember"
    | "is_rolemember"
    | "has_perms_by_name"
    | "session_context"
    | "context_info"
    | "sessionproperty"
    | "connectionproperty"
    | "serverproperty"
    | "databasepropertyex"
    | "collationproperty"
    | "objectproperty"
    | "objectpropertyex"
    | "columnproperty"
    | "typeproperty"
    | "indexproperty"
    | "object_id"
    | "object_name"
    | "object_schema_name"
    | "schema_id"
    | "schema_name"
    | "db_id"
    | "db_name"
    | "type_id"
    | "type_name"
    | "col_name"
    | "col_length"
    | "ident_current"
    | "ident_seed"
    | "ident_incr"
    | "scope_identity"
    | "xact_state"
    | "error_number"
    | "error_message"
    | "error_severity"
    | "error_state"
    | "error_line"
    | "error_procedure"
    | "getansinull"
    | "applock_mode"
    | "applock_test"
    | "sql_variant_property" => true
    _ => false
  }
}

///|
/// Conversions that depend on session settings (language, DATEFORMAT),
/// found on the bound expression so implicit conversions count too
/// (`d > N'2020-01-01'`, `COALESCE(d, s)`): character data to or from a
/// date/time type without a deterministic style, and anything read out of
/// a sql_variant.
fn bound_nondeterministic(e : @ir.Expr) -> Bool {
  match e.kind {
    Cast(x, style~, ..) => {
      let from = x.ty.family()
      let to = e.ty.family()
      let temporal = (f : @types.TypeFamily) => f is (FDate | FTime | FDateTime)
      if from is FVariant && !(to is FVariant) {
        return true
      }
      if (
          (from is FString && temporal(to)) || (temporal(from) && to is FString)
        ) &&
        !deterministic_style(style) {
        return true
      }
      bound_nondeterministic(x)
    }
    Collate(x) | Neg(x) | BitNot(x) | Not(x) | IsNull(x, ..) =>
      bound_nondeterministic(x)
    Arith(_, a, b)
    | BitOp(_, a, b)
    | Concat(a, b)
    | Cmp(_, a, b, _)
    | And(a, b)
    | Or(a, b) => bound_nondeterministic(a) || bound_nondeterministic(b)
    Like(a, b, escape~, ..) =>
      bound_nondeterministic(a) ||
      bound_nondeterministic(b) ||
      escape.map(bound_nondeterministic).unwrap_or(false)
    InList(a, xs, ..) =>
      bound_nondeterministic(a) || xs.iter().any(bound_nondeterministic)
    Case(whens, else_) =>
      whens
      .iter()
      .any(w => bound_nondeterministic(w.0) || bound_nondeterministic(w.1)) ||
      else_.map(bound_nondeterministic).unwrap_or(false)
    // a date function reading character data converts it like CAST
    // (captured: YEAR(s), DATEADD(day, 1, s) are 4936)
    Call(Named(name), args) if string_date_arg(name, args) => true
    Call(_, args) | UserFn(_, args) => args.iter().any(bound_nondeterministic)
    _ => false
  }
}

///|
/// CONVERT styles that read and write dates the same way under every
/// language and DATEFORMAT: 20 and 21 below 100, everything from 100 up
/// except 106, 107, 109 and 113 (month names).
fn deterministic_style(style : Int?) -> Bool {
  match style {
    Some(20 | 21) => true
    Some(106 | 107 | 109 | 113) => false
    Some(s) => s >= 100
    None => false
  }
}

///|
fn string_date_arg(name : String, args : Array[@ir.Expr]) -> Bool {
  let first = match name {
    "DATEADD"
    | "DATEDIFF"
    | "DATEDIFF_BIG"
    | "DATEPART"
    | "DATENAME"
    | "DATETRUNC"
    | "DATE_BUCKET" => 1
    "YEAR"
    | "MONTH"
    | "DAY"
    | "EOMONTH"
    | "SWITCHOFFSET"
    | "TODATETIMEOFFSET" => 0
    _ => return false
  }
  for i in first..<args.length() {
    if args[i].ty.family() is FString {
      // the offset argument of SWITCHOFFSET / TODATETIMEOFFSET is text
      return !(name is ("SWITCHOFFSET" | "TODATETIMEOFFSET") && i == 1)
    }
  }
  false
}
