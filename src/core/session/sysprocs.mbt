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
  let key = match vals.get("@key") {
    Some((String(s), _)) => s
    _ => ""
  }
  let read_only = match vals.get("@read_only") {
    Some((v, _)) => v.as_int64().unwrap_or(0L) != 0L
    None => false
  }
  let mut status = 0
  match self.session_context.get(key) {
    Some((_, true)) => {
      self.out.push(
        Message({
          number: 15664,
          state: 1,
          class: 16,
          message: "Cannot set key '\{key}' in the session context. The key has been set as read_only for this session.",
          procedure: "sp_set_session_context",
          line: 1,
        }),
      )
      self.rt.error = 15664
      status = 1
    }
    _ =>
      match vals.get("@value") {
        Some((Null, _)) | None => self.session_context.remove(key)
        Some((Variant(_, _) as v, _)) =>
          self.session_context[key] = (v, read_only)
        Some((v, ty)) => self.session_context[key] = (Variant(v, ty), read_only)
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
  self.proc_done(status)
}
