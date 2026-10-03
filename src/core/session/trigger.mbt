///|
/// A running trigger: its pseudo-tables live in the table-variable database
/// (scope 3) for the duration of the trigger.
priv struct TriggerCtx {
  module_id : Int
  inserted : Int
  deleted : Int
  /// Columns reported by UPDATE(col).
  updated : Array[Int]
  table : @store.Table
}

///|
fn Session::trigger_def(
  self : Session,
  m : @store.Module,
) -> @ast.CreateTrigger raise {
  ignore(self)
  let stmts = @parse.parse_batch(m.definition) catch {
    _ => raise @types.not_supported("trigger definition that does not re-parse")
  }
  match stmts.get(0) {
    Some({ kind: CreateTrigger(tr), .. }) => tr
    _ => raise @types.not_supported("trigger definition that does not re-parse")
  }
}

///|
/// Enabled triggers of a database table for an event, in creation order.
fn Session::table_triggers(
  self : Session,
  target : Target,
  ev : @ast.DmlEvent,
) -> Array[(@store.Module, @ast.CreateTrigger)] raise {
  if target.scope != 0 {
    return []
  }
  let out = []
  for m in self.db_of(0).modules() {
    if m.kind is Trigger && m.parent == Some(target.table.id) && !m.disabled {
      let tr = self.trigger_def(m)
      if tr.events.contains(ev) {
        out.push((m, tr))
      }
    }
  }
  out
}

///|
fn Session::has_enabled_trigger(self : Session, target : Target) -> Bool {
  target.scope == 0 &&
  self
  .db_of(0)
  .modules()
  .iter()
  .any(m => {
    m.kind is Trigger && m.parent == Some(target.table.id) && !m.disabled
  })
}

///|
/// The INSTEAD OF trigger for an event, unless it is already running (an
/// INSTEAD OF trigger's own DML on its table goes to the table).
fn Session::instead_of_trigger(
  self : Session,
  target : Target,
  ev : @ast.DmlEvent,
) -> Array[(@store.Module, @ast.CreateTrigger)] raise {
  self
  .table_triggers(target, ev)
  .filter(x => {
    x.0.instead_of && !self.triggers.iter().any(c => c.module_id == x.0.id)
  })
}

///|
/// Fires the AFTER triggers of a statement that changed `target`.
fn Session::fire_after(
  self : Session,
  target : Target,
  ev : @ast.DmlEvent,
  deleted : Array[Array[@types.Value]],
  inserted : Array[Array[@types.Value]],
  updated : Array[Int],
  pre : @store.Db,
) -> Unit raise {
  let trs = self.table_triggers(target, ev).filter(x => !x.0.instead_of)
  self.run_triggers(target, trs, deleted, inserted, updated, pre)
}

///|
/// Copies rows into a pseudo-table. SQL Server returns them newest first
/// (captured: triggers/after-insert-audit).
fn Session::pseudo_table(
  self : Session,
  t : @store.Table,
  rows : Array[Array[@types.Value]],
) -> Int {
  let id = self.server.object_id()
  let pt : @store.Table = {
    ..t,
    id,
    schema: "dbo",
    name: "@pseudo" + id.to_string(),
    indexes: [],
    checks: [],
    foreign_keys: [],
  }
  let mut db = self.tvars.create_table(pt)
  for i = rows.length() - 1; i >= 0; i = i - 1 {
    db = db.insert_row(id, self.server.rowid(), rows[i])
  }
  self.tvars = db
  id
}

///|
/// Runs triggers as nested modules: new frame and nesting level, SET
/// options restored afterwards, XACT_ABORT implied. An autocommit statement
/// runs them in an implicit transaction (@@TRANCOUNT = 1) whose base is the
/// pre-statement state, so ROLLBACK in a trigger undoes the statement; a
/// trigger that ends the transaction aborts the batch with 3609.
fn Session::run_triggers(
  self : Session,
  target : Target,
  trs : Array[(@store.Module, @ast.CreateTrigger)],
  deleted : Array[Array[@types.Value]],
  inserted : Array[Array[@types.Value]],
  updated : Array[Int],
  pre : @store.Db,
) -> Unit raise {
  // RECURSIVE_TRIGGERS OFF: a trigger does not fire itself directly
  let trs = trs.filter(x => {
    match self.triggers.last() {
      Some(c) => c.module_id != x.0.id
      None => true
    }
  })
  if trs.is_empty() {
    return
  }
  if self.rt.nest_level >= 32 {
    raise @types.sql_error(
      217, "Maximum stored procedure, function, trigger, or view nesting level exceeded (limit 32).",
    )
  }
  let implicit = self.tx is None
  if implicit {
    let current = self.server.get_db(self.rt.database)
    self.tx = Some({
      database: self.rt.database.to_lower(),
      base: pre,
      view: current,
      temp_at_begin: self.temp,
      savepoints: [],
      name: None,
    })
    self.server.set_db(self.rt.database, pre)
    self.implicit_tx = true
    self.rt.trancount = 1
    self.rt.xact_state = 1
  }
  let nocount = self.nocount
  let xact_abort = self.xact_abort
  let option_bits = self.rt.option_bits
  let scope_identity = self.rt.scope_identity
  let rowcount = self.rt.rowcount
  let cur_cmd = self.cur_cmd
  let ddl_cmd = self.ddl_cmd
  let stmt_error = self.stmt_error
  let finish = () => {
    if implicit && self.tx is Some(_) {
      self.commit_tx() catch {
        _ => ()
      }
      self.rt.trancount = 0
      self.rt.xact_state = 0
    }
    self.nocount = nocount
    self.xact_abort = xact_abort
    self.rt.option_bits = option_bits
    self.rt.scope_identity = scope_identity
    self.rt.rowcount = rowcount
    self.cur_cmd = cur_cmd
    self.ddl_cmd = ddl_cmd
    self.stmt_error = stmt_error
  }
  let mut ended = false
  for x in trs {
    let ins = self.pseudo_table(target.table, inserted)
    let del = self.pseudo_table(target.table, deleted)
    self.triggers.push({
      module_id: x.0.id,
      inserted: ins,
      deleted: del,
      updated,
      table: target.table,
    })
    self.frames.push(Frame::new())
    self.rt.nest_level += 1
    self.xact_abort = true
    let failure = try {
      self.exec_list(x.1.body)
      None
    } catch {
      Return(_) => None
      e => Some(e)
    }
    self.frames.pop() |> ignore
    self.rt.nest_level -= 1
    self.triggers.pop() |> ignore
    self.tvars = self.tvars.drop_object(ins).drop_object(del)
    self.nocount = nocount
    self.rt.option_bits = option_bits
    match failure {
      Some(e) => {
        finish()
        if e is (Caught(_, _, _, _) | AbortBatch) {
          self.trigger_unwind = true
        }
        raise e
      }
      None => ()
    }
    if self.rt.trancount == 0 {
      ended = true
      break
    }
  }
  finish()
  if ended {
    self.throwing = true // completes with 253 and ends the batch
    raise @types.sql_error(
      3609, "The transaction ended in the trigger. The batch has been aborted.",
    )
  }
}

///|
/// Binding of `inserted` / `deleted` inside a trigger.
fn Session::pseudo_binding(
  self : Session,
  name : @ast.ObjectName,
) -> @bind.TableBinding? {
  guard name.parts.length() == 1 && self.triggers.last() is Some(c) else {
    return None
  }
  let n = name.parts[0].name.to_lower()
  let id = match n {
    "inserted" => c.inserted
    "deleted" => c.deleted
    _ => return None
  }
  match self.tvars.table(id) {
    Some(t) =>
      Some({
        scope: 3,
        id,
        schema: "dbo",
        name: n,
        columns: table_columns(t).map(col => { ..col, qualifier: n, }),
      })
    None => None
  }
}

///|
/// Session-evaluated trigger functions (UPDATE(col), TRIGGER_NESTLEVEL()).
fn Session::trigger_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? {
  match name {
    "UPDATE" =>
      match (self.triggers.last(), args.get(0)) {
        (Some(c), Some(String(col))) =>
          Some(
            Bit(
              match c.table.column_index(col) {
                Some(i) => c.updated.contains(i)
                None => false
              },
            ),
          )
        _ => Some(Bit(false))
      }
    "TRIGGER_NESTLEVEL" => Some(Int(self.triggers.length()))
    // captured: one bit per column (column_id - 1, low bit first) in
    // ceil(columns / 8) bytes; empty for DELETE; NULL outside a trigger
    // (harness/corpus/conversion/columns-updated)
    "COLUMNS_UPDATED" =>
      match self.triggers.last() {
        None => Some(Null)
        Some(c) if c.updated.is_empty() => Some(Binary(b""))
        Some(c) => {
          let n = (c.table.columns.length() + 7) / 8
          let bits = FixedArray::make(n, 0)
          for i in c.updated {
            bits[i / 8] = bits[i / 8] | (1 << (i % 8))
          }
          Some(Binary(Bytes::makei(n, k => bits[k].to_byte())))
        }
      }
    _ => None
  }
}
