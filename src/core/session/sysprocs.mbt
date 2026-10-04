///|
/// Catalog system procedures written in T-SQL in SQL Server; their result
/// shapes and messages are captured (corpus sysprocs/).
fn Session::exec_sp_helpindex(
  self : Session,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let name = match args.get(0) {
    Some(a) =>
      match self.eval(a.value).0 {
        String(s) => s
        _ => ""
      }
    None => ""
  }
  self.rt.nest_level += 1
  let status = self.sp_helpindex(name)
  self.rt.nest_level -= 1
  match return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.proc_done(status)
}

///|
fn Session::sp_helpindex(self : Session, name : String) -> Int {
  let table = match self.name_target(name) {
    Some((scope, schema, base)) => {
      let db = self.db_of(scope)
      match db.lookup(schema, base) {
        Some(id) => db.table(id)
        None => None
      }
    }
    None => None
  }
  guard table is Some(t) else {
    self.out.push(
      Message({
        number: 15009,
        state: 1,
        class: 16,
        message: "The object '\{name}' does not exist in database '\{self.rt.database}' or is invalid for this operation.",
        procedure: "sp_helpindex",
        line: 41,
      }),
    )
    self.rt.error = 15009
    self.out.push(InProcDone(cmd=246, count=None, error=true))
    return 1
  }
  if t.indexes.is_empty() {
    self.info(
      15472,
      1,
      "The object '\{name}' does not have any indexes, or you do not have permissions.",
      64,
    )
    return 0
  }
  let sysname : @types.SqlType = NVarChar(Some(128), @types.default_collation)
  self.out.push(
    ResultSet(
      [
        @ir.ResultColumn::{
          name: "index_name",
          ty: sysname,
          nullable: false,
          origin: BaseColumn(identity=false),
        },
        @ir.ResultColumn::{
          name: "index_description",
          ty: @types.SqlType::VarChar(Some(210), @types.default_collation),
          nullable: true,
          origin: Computed,
        },
        @ir.ResultColumn::{
          name: "index_keys",
          ty: @types.SqlType::NVarChar(Some(2126), @types.default_collation),
          nullable: true,
          origin: BaseColumn(identity=false),
        },
      ].map(tds_column),
    ),
  )
  self.out.push(Order([1]))
  let rows = helpindex_rows(t)
  for r in rows {
    self.out.push(Row([Text(r.0), Text(r.1), Text(r.2)]))
  }
  // the procedure runs with NOCOUNT ON: no count (captured)
  self.out.push(InProcDone(cmd=193, count=None, error=false))
  0
}

///|
/// sp_set_session_context @key, @value [, @read_only] (captured:
/// misc/session-context): RETURNSTATUS + DONEPROC; changing a read-only key
/// is 15664.
fn Session::exec_set_session_context(
  self : Session,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let order = ["@key", "@value", "@read_only"]
  let vals : Map[String, (@types.Value, @types.SqlType)] = Map([])
  for i, a in args {
    let k = match a.name {
      Some(n) => n.to_lower()
      None => if i < order.length() { order[i] } else { "" }
    }
    vals[k] = self.eval(a.value)
  }
  // the procedure's own checks, in this order (captured: msduck
  // session-property-context #051-#059): argument count 16903 / 16914,
  // NULL key 225, empty or over 256-byte key 15666, NULL @read_only or a
  // max-type value 15600, a read-only key 15664
  let fail = (number : Int, message : String) => (number, message)
  let failure = if args.length() > 3 {
    Some(
      fail(
        16914, "The \"sp_set_connection_context\" procedure was called with too many parameters.",
      ),
    )
  } else if !vals.contains("@key") || !vals.contains("@value") {
    Some(
      fail(
        16903, "The \"sp_set_connection_context\" procedure was called with an incorrect number of parameters.",
      ),
    )
  } else {
    match vals.get("@key") {
      Some((Null, _)) =>
        Some(
          fail(
            225, "The parameters supplied for the procedure \"sp_set_session_context\" are not valid.",
          ),
        )
      Some((String(k), _)) if k.length() == 0 || k.length() * 2 > 256 =>
        Some(
          fail(
            15666,
            "Cannot set key '\{k}' in the session context. The size of the key cannot exceed 256 bytes.",
          ),
        )
      _ => {
        let bad_value = match vals.get("@value") {
          Some((_, ty)) =>
            ty is (VarChar(None, _) | NVarChar(None, _) | VarBinary(None) | Xml)
          None => false
        }
        if vals.get("@read_only") is Some((Null, _)) || bad_value {
          Some(
            fail(
              15600, "An invalid parameter or option was specified for procedure 'sp_set_connection_context'.",
            ),
          )
        } else {
          None
        }
      }
    }
  }
  let key = match vals.get("@key") {
    Some((String(s), _)) => self.context_key(s).unwrap_or(s)
    _ => ""
  }
  let read_only = match vals.get("@read_only") {
    Some((v, _)) => v.as_int64().unwrap_or(0L) != 0L
    None => false
  }
  let failure = match failure {
    Some(f) => Some(f)
    None =>
      match self.session_context.get(key) {
        Some((_, true)) =>
          Some(
            (
              15664,
              "Cannot set key '\{key}' in the session context. The key has been set as read_only for this session.",
            ),
          )
        _ => None
      }
  }
  let status = match failure {
    Some((number, message)) => {
      // under TRY: the procedure completes, the CATCH sees
      // sys.sp_set_session_context (captured: #064)
      if self.try_depth > 0 {
        self.rt.error = number
        self.module_done(error=false)
        raise Caught(
          @types.sql_error(number, message),
          1,
          Some("sys.sp_set_session_context"),
          max_nest_level + 1,
        )
      }
      self.out.push(
        Message({
          number,
          state: 1,
          class: 16,
          message,
          procedure: "sp_set_session_context",
          line: 1,
        }),
      )
      self.stmt_error = number
      1
    }
    None => {
      match vals.get("@value") {
        Some((Null, _)) | None => self.session_context.remove(key)
        Some((Variant(_, _) as v, _)) =>
          self.session_context[key] = (v, read_only)
        Some((v, ty)) => self.session_context[key] = (Variant(v, ty), read_only)
      }
      0
    }
  }
  match return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  // a failed call returns 1 and completes with the error bit (captured:
  // #051 RETURNSTATUS 1, DONEPROC status 2; nested in sp_executesql
  // DONEINPROC with the error bit, #067)
  if self.rt.nest_level == 0 {
    self.out.push(ReturnStatus(status))
  }
  self.module_done(error=failure is Some(_))
}

///|
/// sp_refreshview @viewname (probed: tail/views-refreshview). A T-SQL
/// procedure calling sys.sp_refreshsqlmodule_internal: its completions
/// (193 counts, 192s, its own transaction 212/349/351/213, the inner
/// procedure's 224) are replayed; a name that is not a view of the current
/// database is 15165 at line 62 with return status 15165. bitsql binds
/// views when they are used, so a refresh only checks that the view still
/// binds; a view that no longer binds, and a missing view under TRY (whose
/// CATCH sees the internal procedure), are Emulator errors.
fn Session::exec_sp_refreshview(
  self : Session,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let span : @ast.Span = { start: 0, end: 0, line: 0, col: 0, }
  let param : @ast.Param = {
    name: "@viewname",
    type_: { schema: None, name: "nvarchar", args: [], span, },
    varying: false,
    default_: None,
    output: false,
    read_only: false,
    span,
  }
  if !self.check_proc_args("sp_refreshview", [param], args) {
    return
  }
  let name = match self.exec_arg_value(args[0]) {
    Some(a) =>
      match a.value {
        Null => "(null)"
        v =>
          match @types.cast(v, a.ty, NVarChar(Some(776), self.db_collation())) {
            String(s) => s
            _ => "(null)"
          }
      }
    None => "(null)"
  }
  let view = match self.name_target(name) {
    Some((0, schema, base)) => {
      let db = self.db_of(0)
      match db.lookup(schema, base) {
        Some(id) =>
          match db.get_module(id) {
            Some(m) if m.kind is View => Some(m)
            _ => None
          }
        None => None
      }
    }
    _ => None
  }
  if view is None && self.try_depth > 0 {
    raise @types.not_supported("sp_refreshview of a missing view inside TRY")
  }
  match view {
    Some(m) => {
      let (q, _) = view_query(m)
      ignore(@bind.bind_query(self.env(), q)) catch {
        _ =>
          raise @types.not_supported(
            "sp_refreshview of a view that no longer binds",
          )
      }
    }
    None => ()
  }
  self.rt.nest_level += 1
  let t193 = (n : Int64) => {
    self.rt.rowcount = n
    self.done(193, count=Some(n))
  }
  t193(1L)
  self.done(192)
  self.done(192)
  let status = match view {
    Some(_) => {
      t193(1L)
      self.done(192)
      self.done(192)
      let implicit = self.rt.trancount == 0
      let d = self.tx_descriptor()
      if implicit {
        self.out.push(EnvChange(BeginTransaction(d)))
      }
      self.done(212)
      self.done(349)
      self.done(192)
      self.done(192)
      self.done(351)
      if implicit {
        self.out.push(EnvChange(CommitTransaction(d)))
      }
      self.done(213)
      0
    }
    None => {
      t193(0L)
      self.done(192)
      self.done(192)
      self.out.push(
        Message({
          number: 15165,
          state: 1,
          class: 16,
          message: "Could not find object '\{name}' or you do not have permission.",
          procedure: "sys.sp_refreshsqlmodule_internal",
          line: 62,
        }),
      )
      self.done(246, error=true)
      15165
    }
  }
  t193(1L)
  self.done(224)
  t193(1L)
  self.rt.error = 0
  self.rt.nest_level -= 1
  match return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.proc_done(status)
}

///|
/// The stored session-context key equal to `k`. SQL Server compares keys
/// ignoring trailing spaces and case, except that the last character must
/// match exactly (probed: 'email' is found by 'Email', 'eMail', 'EMAIl',
/// 'email ' but not by 'EMAIL' or 'emaiL'; 'x' not by 'X'; captured: msduck
/// session-property-context #042, #068, gaps-computed
/// session-default-values-6). Setting uses the same equality.
fn Session::context_key(self : Session, k : String) -> String? {
  if self.session_context.contains(k) {
    return Some(k)
  }
  let want = k.trim_end(chars=" ").to_owned()
  if want.length() == 0 {
    return None
  }
  let last = want[want.length() - 1]
  let lower = want.to_lower()
  for key, _ in self.session_context {
    let have = key.trim_end(chars=" ").to_owned()
    if have.length() == want.length() &&
      have[have.length() - 1] == last &&
      have.to_lower() == lower {
      return Some(key)
    }
  }
  None
}
