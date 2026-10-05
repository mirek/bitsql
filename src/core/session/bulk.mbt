///|
/// The target announced by `INSERT BULK`, awaiting the BulkLoad message.
priv struct BulkTarget {
  name : @ast.ObjectName
  options : Array[String]
}

///|
fn Session::exec_insert_bulk(
  self : Session,
  name : @ast.ObjectName,
  options : Array[String],
) -> Unit raise {
  match self.find_table(name) {
    Some(_) => ()
    None =>
      raise @types.sql_error(208, "Invalid object name '\{object_text(name)}'.")
  }
  self.bulk = Some({ name, options, })
  // captured: DONE 253 without a count
  self.done(253)
}

///|
/// Runs a BulkLoad message (tedious execBulkLoad / mssql request.bulk) into
/// the table of the preceding INSERT BULK. Defaults: CHECK and FOREIGN KEY
/// constraints and triggers are skipped, NOT NULL and keys are enforced,
/// identity values are generated (KEEP_IDENTITY keeps the sent ones), and
/// NULLs take column defaults unless KEEP_NULLS. Responds DONE CurCmd 240
/// with the row count; errors add 3621 (captured with tedious BulkLoad).
pub fn Session::run_bulk(
  self : Session,
  columns : Array[@tds.BulkColumn],
  rows : Array[Array[@tds.WireValue]],
  now : Int64,
) -> Array[@reply.Item] {
  self.rt.now = now
  self.rt.work_done = 0L
  self.out.clear()
  self.rpc = false
  self.frames.clear()
  self.frames.push(Frame::new())
  self.cur_cmd = 240
  self.refresh_tx()
  let bulk = self.bulk
  self.bulk = None
  let result : Result[Int, @types.SqlError] = try {
    guard bulk is Some(b) else {
      raise @types.not_supported("bulk load data without INSERT BULK")
    }
    let has = (o : String) => b.options.iter().any(x => x.has_prefix(o))
    let target = self.dml_target({
      kind: Table(b.name, alias_=None, hints=[]),
      span: { start: 0, end: 0, line: 1, col: 1, },
    })
    self.check_writable()
    let t = target.table
    let index = columns.map(c => {
      match t.column_index(c.name) {
        Some(i) => i
        None => raise @types.sql_error(207, "Invalid column name '\{c.name}'.")
      }
    })
    let keep_identity = has("KEEP_IDENTITY")
    let keep_nulls = has("KEEP_NULLS")
    let mut db = self.db_of(target.scope)
    let row_lock = row_lock(t)
    for src in rows {
      let row = Array::make(t.columns.length(), @types.Value::Null)
      let given = Array::make(t.columns.length(), false)
      for j, ci in index {
        let ty = param_type(columns[j].type_info)
        let v = param_value(ty, src[j])
        if v is Null && !keep_nulls {
          continue
        }
        row[ci] = self.to_column(target, t.columns[ci], v, ty)
        given[ci] = true
      }
      for i, c in t.columns {
        match c.identity {
          Some(id) =>
            if !(keep_identity && given[i]) {
              row[i] = identity_value(
                c.ty,
                self.next_identity(target.scope, t, id),
              )
            }
          None =>
            if !given[i] && c.computed is None {
              match c.default_ {
                Some(d) => row[i] = self.eval_default(target, c, d, row)
                None => ()
              }
            }
        }
      }
      for i, c in t.columns {
        if c.computed is Some(expr) {
          row[i] = self.eval_text(target, expr, row, c.ty)
        }
        if c.ty is RowVersion {
          row[i] = self.next_rowversion()
        }
      }
      self.check_row(
        target,
        db,
        row,
        "INSERT",
        constraints=has("CHECK_CONSTRAINTS"),
      )
      let rowid = self.server.rowid()
      if target.scope == 0 {
        self.acquire(row_lock.resource(rowid, row), X, Transaction)
      }
      db = insert_checked(target, db, rowid, row)
    }
    self.write(target.scope, db)
    Ok(rows.length())
  } catch {
    @types.SqlError(..) as e => Err(e)
    _ => {
      // a lock wait: bulk loads are not re-runnable requests
      self.cancel_wait()
      Err(@types.not_supported("bulk load that waits for a lock"))
    }
  }
  self.server.wake_all(self.server.locks.release_statement(self.rt.spid))
  match result {
    Ok(n) => {
      self.rt.rowcount = n.to_int64()
      self.out.push(
        StatementDone(cmd=240, count=Some(n.to_int64()), error=false),
      )
    }
    Err(e) => {
      self.message(e, 1)
      if [515, 547, 2627, 2601, 2628, 8152].contains(e.number()) {
        self.info(3621, 0, "The statement has been terminated.", 1)
      }
      self.out.push(StatementDone(cmd=240, count=None, error=true))
    }
  }
  self.frames.clear()
  let items = self.out.copy()
  self.out.clear()
  items
}
