// sp_rename: tables, modules, constraints, columns and indexes. Rules
// captured from SQL Server 17 (msduck gaps-catalog #034-#045 and
// #118-#159, corpus tail/catalog-sp-rename):
//
// - arguments: @objname, @newname required (201), @objtype optional;
//   8145 / 8144 like any procedure. NULL @newname (15223 state 11, line
//   96) is checked before NULL @objname (15223 state 1, line 101), then ''
//   (15004 line 17 + 15224 state 15 line 109), then an unrecognized
//   @objtype (15249, line 90); none of these opens the transaction.
// - the rename runs in its own transaction: BEGIN and COMMIT ENVCHANGEs
//   come first when it fails a check, around the 15477 caution when it
//   succeeds, and around caution + ALTER errors (4928, 5074/4922, DONEINPROC
//   170) when the column cannot be altered.
// - @objtype is case-insensitive and echoed as written in 15248. Without
//   it a name is an object first, then table.column, then table.index.
// - a column referenced by a CHECK constraint, a computed column or a
//   schema-bound module, or a table referenced by a schema-bound module,
//   is 15336 (class 16).
// - errors are class 11 (15336 16); outside TRY @@ERROR is 0 afterwards
//   (the procedure runs on), under TRY the CATCH sees the error with
//   ERROR_PROCEDURE() 'sp_rename' and the procedure's line.

///|
/// A failed sp_rename check: number, state, class, line, message.
priv struct RenameError {
  number : Int
  state : Int
  class : Int
  line : Int
  text : String
}

///|
fn rename_error(
  number : Int,
  line : Int,
  text : String,
  state? : Int = 1,
  class? : Int = 11,
) -> RenameError {
  { number, state, class, line, text, }
}

///|
/// Parameters of a T-SQL system procedure as @ast.Param (for
/// check_proc_args): name and whether it has a default (NULL).
fn sysproc_params(params : Array[(String, Bool)]) -> Array[@ast.Param] {
  let span : @ast.Span = { start: 0, end: 0, line: 0, col: 0, }
  params.map(p => {
    name: p.0,
    type_: { schema: None, name: "nvarchar", args: [], span, },
    varying: false,
    default_: if p.1 {
      Some({ kind: Null, span, })
    } else {
      None
    },
    output: false,
    read_only: false,
    span,
  })
}

///|
/// Argument values of a system procedure by lower-cased parameter name
/// (after check_proc_args accepted them).
fn Session::sysproc_values(
  self : Session,
  names : Array[String],
  args : Array[@ast.ExecArg],
) -> Map[String, @types.Value] raise {
  let out : Map[String, @types.Value] = Map([])
  for i, a in args {
    let key = match a.name {
      Some(n) => n.to_lower()
      None => names.get(i).unwrap_or("")
    }
    if a.value.kind is Default {
      continue
    }
    match self.exec_arg_value(a) {
      Some(v) => out[key] = v.value
      None => ()
    }
  }
  out
}

///|
/// Text of a system procedure argument (numbers as their text).
fn sysproc_text(v : @types.Value?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    Some(Null) | None => None
    Some(x) => {
      let t : @types.SqlType = NVarChar(Some(4000), @types.default_collation)
      try @types.cast(x, t, t) catch {
        _ => None
      } noraise {
        String(s) => Some(s)
        _ => None
      }
    }
  }
}

///|
/// EXEC sp_rename.
fn Session::exec_sp_rename(
  self : Session,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Unit raise {
  let names = ["@objname", "@newname", "@objtype"]
  if !self.check_proc_args(
      "sp_rename",
      sysproc_params([
        ("@objname", false),
        ("@newname", false),
        ("@objtype", true),
      ]),
      args,
    ) {
    return
  }
  let vals = self.sysproc_values(names, args)
  let objname = sysproc_text(vals.get("@objname"))
  let newname = sysproc_text(vals.get("@newname"))
  let objtype = sysproc_text(vals.get("@objtype"))
  let finish = (status : Int) => {
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
  // checks made before the transaction
  let early : Array[RenameError] = []
  match (objname, newname) {
    (_, None) =>
      early.push(
        rename_error(
          15223,
          96,
          "Error: The input parameter 'NewName' is not allowed to be null.",
          state=11,
        ),
      )
    (None, _) =>
      early.push(
        rename_error(
          15223, 101, "Error: The input parameter 'OldName' is not allowed to be null.",
        ),
      )
    (_, Some("")) => {
      early.push(rename_error(15004, 17, "Name cannot be NULL.", class=16))
      early.push(
        rename_error(
          15224,
          109,
          "Error: The value for the @newname parameter contains invalid characters or violates a basic restriction ().",
          state=15,
        ),
      )
    }
    _ => ()
  }
  let kind = objtype.map(x => x.to_upper())
  if early.is_empty() {
    match kind {
      None | Some("OBJECT" | "COLUMN" | "INDEX") => ()
      Some("DATABASE" | "USERDATATYPE" | "STATISTICS") => {
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
        finish(1)
        return
      }
      Some(_) =>
        early.push(
          rename_error(
            15249,
            90,
            "Error: Explicit @objtype '\{objtype.unwrap_or("")}' is unrecognized.",
          ),
        )
    }
  }
  if !early.is_empty() {
    self.rename_fail(early, [])
    finish(1)
    return
  }
  // the rename's own transaction
  let implicit = self.rt.trancount == 0
  let d = self.tx_descriptor()
  let begin : Array[@reply.Item] = if implicit {
    [EnvChange(BeginTransaction(d))]
  } else {
    []
  }
  let commit : Array[@reply.Item] = if implicit {
    [EnvChange(CommitTransaction(d))]
  } else {
    []
  }
  match
    self.rename_apply(
      objname.unwrap_or(""),
      newname.unwrap_or(""),
      objtype,
      kind,
    ) {
    Ok(_) => {
      self.out.append(begin)
      self.out.push(rename_caution())
      self.out.append(commit)
      finish(0)
    }
    Err((errs, after_caution)) => {
      if after_caution {
        // the ALTER step failed: caution, errors, then the commit
        self.out.append(begin)
        self.out.push(rename_caution())
        let last = errs.length() - 1
        for k, e in errs {
          self.out.push(
            Message({
              number: e.number,
              state: e.state,
              class: e.class,
              message: e.text,
              procedure: "sp_rename",
              line: e.line,
            }),
          )
          if k == last {
            self.rt.error = e.number
            self.out.push(InProcDone(cmd=170, count=None, error=true))
          }
        }
        self.out.append(commit)
        self.rt.error = 0
      } else {
        self.rename_fail(errs, begin + commit)
      }
      finish(1)
    }
  }
}

///|
fn rename_caution() -> @reply.Item {
  Message({
    number: 15477,
    state: 1,
    class: 0,
    message: "Caution: Changing any part of an object name could break scripts and stored procedures.",
    procedure: "sp_rename",
    line: 801,
  })
}

///|
/// Reports failed checks (each ERROR + DONEINPROC 246). Under TRY the
/// first error is caught: the procedure ends with a plain DONEPROC.
fn Session::rename_fail(
  self : Session,
  errs : Array[RenameError],
  prefix : Array[@reply.Item],
) -> Unit raise {
  self.out.append(prefix)
  let first = errs[0]
  if self.try_depth > 0 && first.class > 10 && first.class < 20 {
    self.rt.error = first.number
    self.module_done(error=false)
    raise Caught(
      @types.sql_error(
        first.number,
        first.text,
        state=first.state,
        severity=first.class,
      ),
      first.line,
      Some("sp_rename"),
      max_nest_level + 1,
    )
  }
  for e in errs {
    self.out.push(
      Message({
        number: e.number,
        state: e.state,
        class: e.class,
        message: e.text,
        procedure: "sp_rename",
        line: e.line,
      }),
    )
    self.out.push(InProcDone(cmd=246, count=None, error=true))
  }
  // the procedure runs on after its RAISERROR: @@ERROR is 0 (captured:
  // gaps-catalog #155)
  self.rt.error = 0
}

///|
/// Does a schema-bound module (other than `except`) mention all `words`?
fn Session::schema_bound_mentions(
  self : Session,
  words : Array[String],
  except? : Int = 0,
) -> Bool {
  for m in self.db_of(0).modules() {
    if m.schema_bound &&
      m.id != except &&
      words.iter().all(w => text_has_word(m.definition, w)) {
      return true
    }
  }
  false
}

///|
/// Does `text` contain `word` as a whole identifier (case-insensitive)?
fn text_has_word(text : String, word : String) -> Bool {
  let t = text.to_lower()
  let w = word.to_lower()
  let n = w.length()
  if n == 0 {
    return false
  }
  let ident = (c : Int) => {
    (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
    (c >= '0'.to_int() && c <= '9'.to_int()) ||
    c == '_'.to_int() ||
    c == '@'.to_int() ||
    c == '#'.to_int() ||
    c == '$'.to_int() ||
    c >= 128
  }
  let mut k = 0
  while k + n <= t.length() {
    if t.unsafe_substring(start=k, end=k + n) == w {
      let before = k == 0 || !ident(t.code_unit_at(k - 1).to_int())
      let after = k + n == t.length() || !ident(t.code_unit_at(k + n).to_int())
      if before && after {
        return true
      }
    }
    k += 1
  }
  false
}

///|
/// Applies the rename. Err carries the errors and whether they come from
/// the ALTER step (after the caution message).
fn Session::rename_apply(
  self : Session,
  objname : String,
  newname : String,
  objtype : String?,
  kind : String?,
) -> Result[Unit, (Array[RenameError], Bool)] {
  let typed = objtype.unwrap_or("(null)")
  let ambiguous = (line : Int) => {
    Err(
      (
        [
          rename_error(
            15248,
            line,
            "Either the parameter @objname is ambiguous or the claimed @objtype (\{typed}) is wrong.",
          ),
        ],
        false,
      ),
    )
  }
  let parts = split_name_text(objname)
  let owner = if parts.length() >= 2 {
    self.resolve_table_text(parts[:parts.length() - 1].to_owned().join("."))
  } else {
    None
  }
  let last = parts[parts.length() - 1]
  match kind {
    Some("COLUMN") =>
      match owner {
        Some((scope, t)) =>
          match t.column_index(last) {
            Some(ord) => self.rename_column(scope, t, ord, objname, newname)
            None => ambiguous(269)
          }
        None => ambiguous(269)
      }
    Some("INDEX") =>
      match owner {
        Some((scope, t)) =>
          match
            t.indexes.search_by(ix => ix.name.to_lower() == last.to_lower()) {
            Some(k) => self.rename_index(scope, t, k, newname)
            None => ambiguous(450)
          }
        None => ambiguous(450)
      }
    _ => {
      match self.rename_object(objname, newname) {
        Some(r) => return r
        None => ()
      }
      if kind is Some(_) {
        return ambiguous(620)
      }
      match owner {
        Some((scope, t)) => {
          match t.column_index(last) {
            Some(ord) =>
              return self.rename_column(scope, t, ord, objname, newname)
            None => ()
          }
          match
            t.indexes.search_by(ix => ix.name.to_lower() == last.to_lower()) {
            Some(k) => return self.rename_index(scope, t, k, newname)
            None => ()
          }
        }
        None => ()
      }
      Err(
        (
          [
            rename_error(
              15225,
              637,
              "No item by the name of '\{objname}' could be found in the current database '\{self.rt.database}', given that @itemtype was input as '\{typed}'.",
            ),
          ],
          false,
        ),
      )
    }
  }
}

///|
fn duplicate_name(newname : String, what : String) -> RenameError {
  rename_error(
    15335,
    738,
    "Error: The new name '\{newname}' is already in use as a \{what} name and would cause a duplicate that is not permitted.",
  )
}

///|
fn Session::rename_column(
  self : Session,
  scope : Int,
  t : @store.Table,
  ord : Int,
  objname : String,
  newname : String,
) -> Result[Unit, (Array[RenameError], Bool)] {
  let col = t.columns[ord]
  if t.column_index(newname) is Some(_) {
    return Err(([duplicate_name(newname, "COLUMN")], false))
  }
  let name = col.name.to_lower()
  let enforced = t.checks
    .iter()
    .any(c => c.column_id == col.column_id || expr_mentions(c.expr, name)) ||
    t.columns
    .iter()
    .any(c => c.computed.map(x => expr_mentions(x, name)).unwrap_or(false)) ||
    self.schema_bound_mentions([t.name, col.name])
  if enforced {
    return Err(
      (
        [
          rename_error(
            15336,
            774,
            "Object '\{objname}' cannot be renamed because the object participates in enforced dependencies.",
            class=16,
          ),
        ],
        false,
      ),
    )
  }
  if col.computed is Some(_) {
    return Err(
      (
        [
          rename_error(
            4928,
            905,
            "Cannot alter column '\{col.name}' because it is 'COMPUTED'.",
            class=16,
          ),
        ],
        true,
      ),
    )
  }
  let filtered = t.indexes.filter(ix => {
    !ix.is_constraint &&
    ix.filter.map(x => expr_mentions(x, name)).unwrap_or(false)
  })
  if !filtered.is_empty() {
    let errs = filtered.map(ix => {
      rename_error(
        5074,
        905,
        "The index '\{ix.name}' is dependent on column '\{col.name}'.",
        class=16,
      )
    })
    errs.push(
      rename_error(
        4922,
        905,
        "RENAME COLUMN \{col.name} failed because one or more objects access this column.",
        state=9,
        class=16,
      ),
    )
    return Err((errs, true))
  }
  let cols = t.columns.copy()
  cols[ord] = { ..cols[ord], name: newname, }
  self.write(
    scope,
    self
    .db_of(scope)
    .alter_table({ ..t, columns: cols, modified: self.rt.now, }),
  )
  Ok(())
}

///|
fn Session::rename_index(
  self : Session,
  scope : Int,
  t : @store.Table,
  k : Int,
  newname : String,
) -> Result[Unit, (Array[RenameError], Bool)] {
  let ix = t.indexes[k]
  if t.indexes
    .iter()
    .any(x => {
      x.index_id != ix.index_id && x.name.to_lower() == newname.to_lower()
    }) {
    return Err(([duplicate_name(newname, "INDEX")], false))
  }
  if ix.is_constraint &&
    self.object_name_taken(self.db_of(scope), t.schema, newname) {
    return Err(([duplicate_name(newname, "object")], false))
  }
  let indexes = t.indexes.copy()
  indexes[k] = { ..ix, name: newname, }
  self.write(
    scope,
    self.db_of(scope).alter_table({ ..t, indexes, modified: self.rt.now, }),
  )
  Ok(())
}

///|
/// Renames a table, module or constraint named by `objname`; None when no
/// such object exists.
fn Session::rename_object(
  self : Session,
  objname : String,
  newname : String,
) -> Result[Unit, (Array[RenameError], Bool)]? {
  guard self.name_target(objname) is Some((0, schema, base)) else {
    return None
  }
  let db = self.db_of(0)
  guard db.schema_id(schema) is Some(sid) else { return None }
  let found = user_objects(db)
    .iter()
    .find_first(o => o.schema_id == sid && o.name.to_lower() == base.to_lower())
  guard found is Some(o) else { return None }
  if o.parent == 0 && self.schema_bound_mentions([o.name], except=o.id) {
    return Some(
      Err(
        (
          [
            rename_error(
              15336,
              794,
              "Object '\{objname}' cannot be renamed because the object participates in enforced dependencies.",
              class=16,
            ),
          ],
          false,
        ),
      ),
    )
  }
  if self.object_name_taken(db, schema, newname) {
    return Some(Err(([duplicate_name(newname, "object")], false)))
  }
  let now = self.rt.now
  match db.table(o.id) {
    Some(t) => {
      self.write(0, db.alter_table({ ..t, name: newname, modified: now, }))
      return Some(Ok(()))
    }
    None => ()
  }
  match db.get_module(o.id) {
    Some(m) => {
      self.write(0, db.rename_module({ ..m, name: newname, modified: now, }))
      return Some(Ok(()))
    }
    None => ()
  }
  // a constraint of table `o.parent`
  guard db.table(o.parent) is Some(t) else { return None }
  let nt = {
    ..t,
    indexes: t.indexes.map(ix => {
      if ix.is_constraint && ix.object_id == o.id {
        { ..ix, name: newname, }
      } else {
        ix
      }
    }),
    checks: t.checks.map(c => {
      if c.id == o.id {
        { ..c, name: newname, }
      } else {
        c
      }
    }),
    foreign_keys: t.foreign_keys.map(f => {
      if f.id == o.id {
        { ..f, name: newname, }
      } else {
        f
      }
    }),
    columns: t.columns.map(c => {
      if c.default_id == o.id {
        { ..c, default_name: Some(newname), }
      } else {
        c
      }
    }),
  }
  self.write(0, db.alter_table(nt))
  Some(Ok(()))
}
