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
  let rows = t.indexes.map(ix => {
    let parts = [if ix.clustered { "clustered" } else { "nonclustered" }]
    if ix.unique {
      parts.push("unique")
    }
    if ix.primary {
      parts.push("primary key")
    } else if ix.object_id != 0 {
      parts.push("unique key")
    }
    let keys = ix.columns.map(c => {
      t.columns[c.0].name + (if c.1 { "(-)" } else { "" })
    })
    (ix.name, parts.join(", ") + " located on PRIMARY", keys.join(", "))
  })
  rows.sort_by((a, b) => {
    (@types.compare(
      String(a.0),
      String(b.0),
      collation=@types.default_collation,
    ) catch {
      _ => None
    }).unwrap_or(0)
  })
  for r in rows {
    self.out.push(Row([Text(r.0), Text(r.1), Text(r.2)]))
  }
  // the procedure runs with NOCOUNT ON: no count (captured)
  self.out.push(InProcDone(cmd=193, count=None, error=false))
  0
}
