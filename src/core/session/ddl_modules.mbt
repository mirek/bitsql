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
    // captured: the statement completes with its CurCmd (gaps-functions
    // #100)
    self.cur_cmd = cmd
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
    // ALTER between scalar, inline and multi-statement functions is 2010
    // (captured: gaps-functions #087, #089)
    Some(m) if m.kind == kind => Some(m)
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
    Alter | CreateOrAlter if kind
      is (Procedure | ScalarFunction | InlineFunction | TableFunction) &&
      existing is None &&
      self.object_name_taken(db, schema, base) => {
      // captured: gaps-procedures #129, #130, gaps-functions #087-#092
      // (DONE with CurCmd 222; the name as written)
      self.cur_cmd = cmd
      raise @types.sql_error(
        2010,
        "Cannot perform alter on '\{object_text(name)}' because it is an incompatible object type.",
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
        ansi_nulls: self.ansi_nulls(),
        quoted_identifier: self.session_flags
        .get("QUOTED_IDENTIFIER")
        .unwrap_or(true),
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
        ansi_nulls: self.ansi_nulls(),
        quoted_identifier: self.session_flags
        .get("QUOTED_IDENTIFIER")
        .unwrap_or(true),
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
      result_nullable: c.nullable,
      persisted: false,
      rowguidcol: false,
      user_type: None,
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
  self.check_module_params(p.params, p.body)
  // compiled at CREATE (captured: gaps-procedures #133-#136)
  let vars : Map[String, @bind.VarInfo] = Map([])
  for i, prm in p.params {
    if vars.contains(prm.name.to_lower()) {
      raise redeclared_error(prm.name)
    }
    let ty = @bind.resolve_type(
      prm.type_,
      Declaration,
      @types.default_collation,
      preview=self.preview_enabled(),
    ) catch {
      _ => Int
    }
    vars[prm.name.to_lower()] = { slot: i, ty, }
  }
  match
    precheck_batch(p.body, vars, in_proc=true, preview=self.preview_enabled()) {
    Some((e, _)) => raise e
    None => ()
  }
  let m = self.define_module(p.mode, p.name, Procedure, 222, start)
  self.server.procs[m.name.to_lower()] = {
    name: m.name,
    def: p,
    ansi_nulls: m.ansi_nulls,
  }
}

///|
fn Session::exec_create_function(
  self : Session,
  f : @ast.CreateFunction,
  start : Int,
) -> Unit raise {
  self.check_module_params(
    f.params,
    match f.returns {
      Scalar(_, body) | TableVariable(_, _, body) => body
      InlineTable(_) => []
    },
  )
  let (kind, returns) : (@store.ObjectKind, @types.SqlType?) = match f.returns {
    Scalar(t, _) =>
      (ScalarFunction, Some(self.scalar_type(t, self.db_collation())))
    InlineTable(_) => (InlineFunction, None)
    TableVariable(_, _, _) => (TableFunction, None)
  }
  self.validate_function(f)
  // compiled at CREATE: undeclared variables are 137 (captured:
  // gaps-functions #101)
  let vars : Map[String, @bind.VarInfo] = Map([])
  for i, prm in f.params {
    let ty = @bind.resolve_type(
      prm.type_,
      Declaration,
      @types.default_collation,
      preview=self.preview_enabled(),
    ) catch {
      _ => Int
    }
    vars[prm.name.to_lower()] = { slot: i, ty, }
  }
  let body = match f.returns {
    Scalar(_, body) => body
    TableVariable(tv, _, body) => {
      vars[tv.to_lower()] = { slot: vars.length(), ty: Int, }
      body
    }
    InlineTable(_) => []
  }
  match
    precheck_batch(body, vars, in_proc=true, preview=self.preview_enabled()) {
    Some((e, _)) => raise e
    None => ()
  }
  self.check_function_binding(f)
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
    _ => {
      // captured: an AFTER trigger on a view is state 6, a missing object
      // state 4 (gaps-triggers #079, #095)
      let is_view = self.find_view(tr.table) is Some(_)
      if is_view && tr.timing is InsteadOf {
        raise @types.not_supported("INSTEAD OF triggers on views")
      }
      raise @types.sql_error(
        8197,
        "The object '\{object_text(tr.table)}' does not exist or is invalid for this operation.",
        state=if is_view { 6 } else { 4 },
      )
    }
  }
  // definition errors complete with the statement's CurCmd 221 (captured:
  // gaps-triggers #081, #088, #089, #049)
  if tr.name.parts.length() >= 2 {
    let (schema, _) = split_name(tr.name)
    if schema.to_lower() != t.schema.to_lower() {
      self.cur_cmd = 221
      raise @types.sql_error(
        2103,
        "Cannot create trigger '\{object_text(tr.name)}' because its schema is different from the schema of the target table or view.",
        severity=15,
      )
    }
  }
  let (_, base) = split_name(tr.name)
  let db = self.db_of(0)
  let existing = match db.lookup(t.schema, base) {
    Some(id) =>
      match db.get_module(id) {
        Some(m) if m.kind is Trigger => Some(m)
        _ => None
      }
    None => None
  }
  match (tr.mode, existing) {
    (Create, _) if self.object_name_taken(db, t.schema, base) => {
      self.cur_cmd = 221
      raise @types.sql_error(
        2714,
        "There is already an object named '\{base}' in the database.",
        state=2,
      )
    }
    (Alter | CreateOrAlter, Some(m)) if m.parent != Some(t.id) => {
      self.cur_cmd = 221
      raise @types.sql_error(
        2110,
        "Cannot alter trigger '\{object_text(tr.name)}' on '\{object_text(tr.table)}' because this trigger does not belong to this object. Specify the correct trigger name or the correct target object name.",
        severity=15,
      )
    }
    _ => ()
  }
  if tr.timing is InsteadOf {
    // captured (triggers/instead-of-cascade-ddl): foreign keys whose
    // action would delete / update this table's rows, enabled or not
    let cascading = t.foreign_keys
      .iter()
      .any(f => {
        let (del, upd) = cascade_events(f.on_delete, f.on_update)
        (del && tr.events.contains(OnDelete)) ||
        (upd && tr.events.contains(OnUpdate))
      })
    if cascading {
      self.cur_cmd = 221
      raise @types.sql_error(
        2113,
        "Cannot create INSTEAD OF DELETE or INSTEAD OF UPDATE TRIGGER '\{object_text(tr.name)}' on table '\{object_text(tr.table)}'. This is  because the table has a FOREIGN KEY with cascading DELETE or UPDATE.",
      )
    }
    for ev in tr.events {
      let other = db
        .modules()
        .iter()
        .any(m => {
          m.kind is Trigger &&
          m.parent == Some(t.id) &&
          m.instead_of &&
          (existing is None || existing.map(e => e.id) != Some(m.id)) &&
          (self.trigger_def(m).events.contains(ev) catch { _ => false })
        })
      if other {
        let evname = match ev {
          OnInsert => "INSERT"
          OnUpdate => "UPDATE"
          OnDelete => "DELETE"
        }
        self.cur_cmd = 221
        raise @types.sql_error(
          2111,
          "Cannot create trigger '\{object_text(tr.name)}' on table '\{object_text(tr.table)}' because an INSTEAD OF \{evname} trigger already exists on this object.",
        )
      }
    }
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
    "sp_set_session_context" => {
      self.exec_set_session_context(args, return_var)
      true
    }
    "sp_helpindex" => {
      self.exec_sp_helpindex(args, return_var)
      true
    }
    "sp_refreshview" => {
      self.exec_sp_refreshview(args, return_var)
      true
    }
    "sp_getapplock" | "sp_releaseapplock" as p => {
      self.exec_applock_proc(p, args, return_var)
      true
    }
    "sp_rename" => {
      self.exec_sp_rename(args, return_var)
      true
    }
    "sp_addextendedproperty"
    | "sp_updateextendedproperty"
    | "sp_dropextendedproperty" as p => {
      self.exec_xprop_proc(p, args, return_var)
      true
    }
    other => self.exec_help_proc(other, args, return_var)
  }
}
