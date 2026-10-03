// CREATE/ALTER/DROP of views, procedures, functions and triggers (stored as
// store Modules: sys.objects, sys.sql_modules, OBJECT_ID), CREATE SCHEMA and
// sp_rename. Completions and errors: harness/corpus/catalog/modules*.sql.

///|
/// sys.sql_modules.definition: the whole batch text, with ALTER rewritten to
/// CREATE and `CREATE OR ALTER` to `CREATE` (captured: `CREATE OR ALTER
/// PROCEDURE` is stored as `CREATE   PROCEDURE`).
fn Session::module_definition(self : Session, start : Int) -> String {
  let text = self.text
  if start < 0 || start >= text.length() {
    return text
  }
  let rest = text.unsafe_substring(start~, end=text.length())
  let head = text.unsafe_substring(start=0, end=start)
  let upper = rest.to_upper()
  if upper.has_prefix("ALTER") {
    return head + "CREATE" + rest.unsafe_substring(start=5, end=rest.length())
  }
  if upper.has_prefix("CREATE") {
    // CREATE <ws> OR <ws> ALTER
    let mut k = 6
    while k < rest.length() && is_space(rest.code_unit_at(k)) {
      k += 1
    }
    if upper.unsafe_substring(start=k, end=rest.length()).has_prefix("OR") {
      let mut j = k + 2
      while j < rest.length() && is_space(rest.code_unit_at(j)) {
        j += 1
      }
      if upper.unsafe_substring(start=j, end=rest.length()).has_prefix("ALTER") {
        return head +
          rest.unsafe_substring(start=0, end=k) +
          " " +
          rest.unsafe_substring(start=j + 5, end=rest.length())
      }
    }
  }
  text
}

///|
fn is_space(c : UInt16) -> Bool {
  let x = c.to_int()
  x == 32 || x == 9 || x == 10 || x == 13
}

///|
/// Creates or replaces a module. `cmd` is the statement's CurCmd.
fn Session::define_module(
  self : Session,
  mode : @ast.CreateMode,
  name : @ast.ObjectName,
  kind : @store.ObjectKind,
  cmd : Int,
  start : Int,
  parent? : Int? = None,
  instead_of? : Bool = false,
  columns? : Array[@store.Column] = [],
  schema_bound? : Bool = false,
  check_option? : Bool = false,
  returns? : @types.SqlType? = None,
  done? : Bool = true,
) -> @store.Module raise {
  let (schema, base) = split_name(name)
  let db = self.db_of(0)
  if db.schema_id(schema) is None {
    raise @types.sql_error(
      2760,
      "The specified schema name \"\{schema}\" either does not exist or you do not have permission to use it.",
    )
  }
  let existing = match db.lookup(schema, base) {
    Some(id) => db.get_module(id)
    None => None
  }
  let existing = match existing {
    Some(m) if m.kind == kind ||
      (
        kind is (ScalarFunction | InlineFunction | TableFunction) &&
        m.kind is (ScalarFunction | InlineFunction | TableFunction)
      ) => Some(m)
    _ => None
  }
  match mode {
    Create =>
      if self.object_name_taken(db, schema, base) {
        self.cur_cmd = cmd
        raise @types.sql_error(
          2714,
          "There is already an object named '\{base}' in the database.",
          state=3,
        )
      }
    Alter =>
      if existing is None {
        raise @types.sql_error(
          208,
          "Invalid object name '\{object_text(name)}'.",
          state=6,
        )
      }
    CreateOrAlter =>
      if existing is None && self.object_name_taken(db, schema, base) {
        self.cur_cmd = cmd
        raise @types.sql_error(
          2714,
          "There is already an object named '\{base}' in the database.",
          state=3,
        )
      }
  }
  let m : @store.Module = match existing {
    Some(old) =>
      {
        ..old,
        kind,
        definition: self.module_definition(start),
        modified: self.rt.now,
        parent,
        instead_of,
        columns,
        schema_bound,
        check_option,
        returns,
      }
    None =>
      {
        id: self.server.object_id(),
        schema,
        name: base,
        kind,
        definition: self.module_definition(start),
        parent,
        created: self.rt.now,
        modified: self.rt.now,
        disabled: false,
        instead_of,
        columns,
        schema_bound,
        check_option,
        returns,
      }
  }
  self.write(0, db.add_module(m))
  self.rt.rowcount = 0
  if done {
    self.done(cmd)
  }
  m
}

///|
/// Result columns of a view: bound when the binder supports the query;
/// empty (no sys.columns rows) when the binder reports an emulator limit.
fn Session::view_columns(
  self : Session,
  cv : @ast.CreateView,
) -> Array[@store.Column] raise {
  let bound = @bind.bind_query(self.env(), cv.query) catch {
    @types.SqlError(number~, ..) as e =>
      if number >= 50100 && number <= 50199 {
        return []
      } else {
        raise e
      }
  }
  let out : Array[@store.Column] = []
  for k, c in bound.columns {
    let name = if k < cv.columns.length() { cv.columns[k].name } else { c.name }
    if name == "" {
      raise @types.sql_error(
        4511,
        "Create View or Function failed because no column name was specified for column \{k + 1}.",
      )
    }
    if out.iter().any(x => x.name.to_lower() == name.to_lower()) {
      raise @types.sql_error(
        4506,
        "Column names in each view or function must be unique. Column name '\{name}' in view or function '\{cv.name.base()}' is specified more than once.",
      )
    }
    out.push({
      column_id: k + 1,
      name,
      ty: c.ty,
      nullable: c.nullable,
      identity: None,
      default_: None,
      default_name: None,
      default_id: 0,
      default_auto: false,
      computed: None,
      persisted: false,
      rowguidcol: false,
    })
  }
  out
}

///|
fn Session::exec_create_view(
  self : Session,
  cv : @ast.CreateView,
  start : Int,
) -> Unit raise {
  let columns = self.view_columns(cv)
  ignore(
    self.define_module(
      cv.mode,
      cv.name,
      View,
      207,
      start,
      columns~,
      schema_bound=cv.attributes.contains("SCHEMABINDING"),
      check_option=cv.check_option,
    ),
  )
}

///|
fn Session::exec_create_procedure(
  self : Session,
  p : @ast.CreateProcedure,
  start : Int,
) -> Unit raise {
  let m = self.define_module(p.mode, p.name, Procedure, 222, start)
  self.server.procs[m.name.to_lower()] = { name: m.name, def: p, }
}

///|
fn Session::exec_create_function(
  self : Session,
  f : @ast.CreateFunction,
  start : Int,
) -> Unit raise {
  let (kind, returns) : (@store.ObjectKind, @types.SqlType?) = match f.returns {
    Scalar(t, _) =>
      (
        ScalarFunction,
        Some(@bind.resolve_type(t, Declaration, @types.default_collation)),
      )
    InlineTable(_) => (InlineFunction, None)
    TableVariable(_, _, _) => (TableFunction, None)
  }
  ignore(
    self.define_module(
      f.mode,
      f.name,
      kind,
      222,
      start,
      returns~,
      schema_bound=f.options.contains("SCHEMABINDING"),
    ),
  )
}

///|
fn Session::exec_create_trigger(
  self : Session,
  tr : @ast.CreateTrigger,
  start : Int,
) -> Unit raise {
  let t = match self.find_table(tr.table) {
    Some((0, t)) => t
    _ =>
      raise @types.sql_error(
        8197,
        "The object '\{object_text(tr.table)}' does not exist or is invalid for this operation.",
        state=4,
      )
  }
  ignore(
    self.define_module(
      tr.mode,
      tr.name,
      Trigger,
      221,
      start,
      parent=Some(t.id),
      instead_of=tr.timing is InsteadOf,
    ),
  )
}

///|
fn Session::exec_create_schema(self : Session, name : @ast.Ident) -> Unit raise {
  let db = self.db_of(0)
  if db.schema_id(name.name) is Some(_) ||
    self.object_name_taken(db, "dbo", name.name) {
    self.pending.push(
      @types.sql_error(
        2714,
        "There is already an object named '\{name.name}' in the database.",
        state=6,
      ),
    )
    raise @types.sql_error(
      2759,
      "CREATE SCHEMA failed due to previous errors.",
      state=0,
    )
  }
  self.write(0, db.add_schema(name.name, db.next_schema_id()))
  self.rt.rowcount = 0
  // CREATE / DROP SCHEMA send no completion of their own (captured:
  // catalog/schema-rpc, docs/reference/completions.md)
  self.schema_ddl = true
}

///|
/// System procedures the emulator implements in-process. Returns false
/// when `name` is not one of them.
fn Session::exec_system_proc(
  self : Session,
  name : @ast.ObjectName,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Bool raise {
  match name.base().to_lower() {
    "sp_rename" => {
      let vals = args.map(a => self.eval(a.value).0)
      let text = (k : Int) => {
        match vals.get(k) {
          Some(String(s)) => Some(s)
          _ => None
        }
      }
      // sp_rename runs its own transaction: BEGIN/COMMIT ENVCHANGEs come
      // first (captured, also when it fails)
      let implicit = self.rt.trancount == 0
      let d = self.tx_descriptor()
      if implicit {
        self.out.push(EnvChange(BeginTransaction(d)))
      }
      let mark = self.out.length()
      let status = self.sp_rename(text(0), text(1), text(2))
      if implicit {
        // the commit precedes the messages of the procedure body
        let tail = self.out[mark:].to_owned()
        self.out.truncate(mark)
        if status != 0 {
          self.out.push(EnvChange(CommitTransaction(d)))
          for x in tail {
            self.out.push(x)
          }
        } else {
          for x in tail {
            self.out.push(x)
          }
          self.out.push(EnvChange(CommitTransaction(d)))
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
      self.out.push(ReturnStatus(status))
      self.out.push(ProcDone(cmd=224, count=None, error=false))
      true
    }
    _ => false
  }
}

///|
/// Error raised inside a system procedure (class 11/16, procedure name and
/// line inside the procedure as captured).
fn Session::proc_error(
  self : Session,
  proc : String,
  number : Int,
  severity : Int,
  line : Int,
  text : String,
) -> Unit {
  self.out.push(
    Message({
      number,
      state: 1,
      class: severity,
      message: text,
      procedure: proc,
      line,
    }),
  )
  self.rt.error = number
  self.out.push(InProcDone(cmd=246, count=None, error=true))
}

///|
/// sp_rename for tables (and other objects) and columns. Returns the
/// procedure's return status.
fn Session::sp_rename(
  self : Session,
  objname : String?,
  newname : String?,
  objtype : String?,
) -> Int {
  let objname = objname.unwrap_or("")
  let newname = newname.unwrap_or("")
  let kind = objtype.map(x => x.to_upper())
  let db = self.db_of(0)
  if kind == Some("COLUMN") {
    let parts = split_name_text(objname)
    let col = parts[parts.length() - 1]
    let tname = parts[:parts.length() - 1].to_owned().join(".")
    let table = if parts.length() >= 2 {
      self.resolve_table_text(tname)
    } else {
      None
    }
    match table {
      Some((scope, t)) =>
        match t.column_index(col) {
          Some(ord) => {
            if t.column_index(newname) is Some(_) {
              self.proc_error(
                "sp_rename",
                15335,
                11,
                738,
                "Error: The new name '\{newname}' is already in use as a COLUMN name and would cause a duplicate that is not permitted.",
              )
              return 1
            }
            let cols = t.columns.copy()
            cols[ord] = { ..cols[ord], name: newname, }
            self.write(
              scope,
              self
              .db_of(scope)
              .alter_table({ ..t, columns: cols, modified: self.rt.now, }),
            )
          }
          None => {
            self.proc_error(
              "sp_rename", 15248, 11, 269, "Either the parameter @objname is ambiguous or the claimed @objtype (COLUMN) is wrong.",
            )
            return 1
          }
        }
      None => {
        self.proc_error(
          "sp_rename", 15248, 11, 269, "Either the parameter @objname is ambiguous or the claimed @objtype (COLUMN) is wrong.",
        )
        return 1
      }
    }
  } else if kind is (None | Some("OBJECT")) {
    match self.name_target(objname) {
      Some((0, schema, base)) =>
        match db.lookup(schema, base) {
          Some(id) => {
            if self.object_name_taken(db, schema, newname) {
              self.proc_error(
                "sp_rename",
                15335,
                11,
                738,
                "Error: The new name '\{newname}' is already in use as a object name and would cause a duplicate that is not permitted.",
              )
              return 1
            }
            match db.table(id) {
              Some(t) =>
                self.write(
                  0,
                  db.alter_table({ ..t, name: newname, modified: self.rt.now, }),
                )
              None =>
                match db.get_module(id) {
                  Some(m) =>
                    self.write(
                      0,
                      db.rename_module({
                        ..m,
                        name: newname,
                        modified: self.rt.now,
                      }),
                    )
                  None => ()
                }
            }
          }
          None => {
            self.rename_missing(objname, objtype)
            return 1
          }
        }
      _ => {
        self.rename_missing(objname, objtype)
        return 1
      }
    }
  } else {
    self.out.push(
      Message({
        number: 50100,
        state: 1,
        class: 16,
        message: "Emulator: sp_rename @objtype '\{objtype.unwrap_or("")}' is not supported",
        procedure: "",
        line: 1,
      }),
    )
    self.rt.error = 50100
    self.out.push(InProcDone(cmd=246, count=None, error=true))
    return 1
  }
  self.out.push(
    Message({
      number: 15477,
      state: 1,
      class: 0,
      message: "Caution: Changing any part of an object name could break scripts and stored procedures.",
      procedure: "sp_rename",
      line: 801,
    }),
  )
  0
}

///|
fn Session::rename_missing(
  self : Session,
  objname : String,
  objtype : String?,
) -> Unit {
  self.proc_error(
    "sp_rename",
    15225,
    11,
    637,
    "No item by the name of '\{objname}' could be found in the current database '\{self.rt.database}', given that @itemtype was input as '\{objtype.unwrap_or("(null)")}'.",
  )
}
