///|
/// One MERGE action selected for a row.
priv enum MergeOp {
  MUpdate(Int64, Array[@types.Value], Array[@types.Value], Array[@types.Value]) // rowid, old, new, source
  MDelete(Int64, Array[@types.Value], Array[@types.Value]) // rowid, old, source
  MInsert(Array[@types.Value], Array[@types.Value]) // new, source
}

///|
/// MERGE (msduck docs/gaps-merge.md, captures merge-*.json): every joined row
/// takes the first clause of its family whose condition holds; everything is
/// materialized before any write; a target row matched by several source
/// rows fails with 8672 when an UPDATE is selected for it.
fn Session::exec_merge(self : Session, m : @ast.Merge) -> Unit raise {
  if !m.ctes.is_empty() {
    raise @types.not_supported("MERGE with a CTE")
  }
  let target = self.dml_target(m.target)
  if self.has_enabled_trigger(target) {
    raise @types.not_supported("MERGE on a table with triggers")
  }
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  let n = t.columns.length()
  let env0 = self.env()
  let (source_plan, source_cols) = @bind.bind_sources(env0, [m.source])
  let target_cols = table_columns(t).map(c => {
    ..c,
    qualifier: target.qualifier,
  })
  let env = env0.with_columns(target_cols + source_cols)
  let on = @bind.bind_expr(env, m.on)
  // bind clauses
  let bound_whens = m.whens.map(w => {
    let cond = match w.condition {
      Some(c) => Some(@bind.bind_expr(env, c))
      None => None
    }
    (w, cond)
  })
  let target_rows = self.db_of(target.scope).rows(t.id)
  let source_rows = @exec.run(self.ctx(), source_plan)
  let width_s = source_cols.length()
  let null_target = Array::make(n, @types.Value::Null)
  let null_source = Array::make(width_s, @types.Value::Null)
  let pick = (family : (@ast.MergeMatch) -> Bool, row : Array[@types.Value]) => {
    let ctx = self.ctx().with_row(row)
    for bw in bound_whens {
      let (w, cond) = bw
      if !family(w.match_) {
        continue
      }
      match cond {
        Some(c) => if !@exec.is_true(@exec.eval(ctx, c)) { continue }
        None => ()
      }
      return Some(w)
    }
    None
  }
  // OUTPUT: deleted ++ inserted ++ source columns ++ $action
  let action_col : @bind.ColumnRef = {
    qualifier: "",
    name: "$action",
    ty: NVarChar(Some(10), @types.default_collation),
    nullable: false,
    origin: SetOperation,
  }
  let outputs = self.bind_output(
    m.output,
    target,
    None,
    true,
    true,
    source_cols + [action_col],
    null_deleted=m.whens.iter().any(w => w.action is MergeInsert(..)),
    null_inserted=m.whens.iter().any(w => w.action is MergeDelete),
  )
  let ops : Array[MergeOp] = []
  let matched_target : Set[Int64] = Set([])
  let update_targets : Map[Int64, Int] = Map([])
  self.cur_cmd = 279
  // Match every (target, source) pair first; actions are then produced in
  // target order, then inserts in source order (captured: dml/merge-upsert
  // OUTPUT order UPDATE, DELETE, INSERT).
  let source_matched = Array::make(source_rows.length(), false)
  let matches : Array[Array[Int]] = target_rows.map(_ => [])
  for ti, tr in target_rows {
    for si, s in source_rows {
      if @exec.is_true(@exec.eval(self.ctx().with_row(tr.1 + s), on)) {
        matches[ti].push(si)
        source_matched[si] = true
      }
    }
  }
  for ti, tr in target_rows {
    let (rowid, trow) = tr
    if matches[ti].is_empty() {
      match pick(x => x is NotMatchedBySource, trow + null_source) {
        Some(w) =>
          match w.action {
            MergeUpdate(_) => ops.push(MUpdate(rowid, trow, [], null_source))
            MergeDelete => ops.push(MDelete(rowid, trow, null_source))
            MergeInsert(..) => ()
          }
        None => ()
      }
      continue
    }
    matched_target.add(rowid)
    for si in matches[ti] {
      let s = source_rows[si]
      match pick(x => x is Matched, trow + s) {
        Some(w) =>
          match w.action {
            MergeUpdate(_) => {
              update_targets[rowid] = update_targets.get(rowid).unwrap_or(0) + 1
              ops.push(MUpdate(rowid, trow, [], s))
            }
            MergeDelete => ops.push(MDelete(rowid, trow, s))
            MergeInsert(..) => ()
          }
        None => ()
      }
    }
  }
  for si, s in source_rows {
    if !source_matched[si] {
      match pick(x => x is NotMatchedByTarget, null_target + s) {
        Some(w) => if w.action is MergeInsert(..) { ops.push(MInsert([], s)) }
        None => ()
      }
    }
  }
  // repeated matches with an UPDATE
  let mut repeated = false
  for kv in update_targets {
    if kv.1 > 1 {
      repeated = true
    }
  }
  if repeated {
    self.cur_cmd = 253
    self.abort_transaction()
    self.throwing = true // ends the batch
    raise @types.sql_error(
      8672, "The MERGE statement attempted to UPDATE or DELETE the same row more than once. This happens when a target row matches more than one source row. A MERGE statement cannot UPDATE/DELETE the same row of the target table multiple times. Refine the ON clause to ensure a target row matches at most one source row, or use the GROUP BY clause to group the source rows.",
    )
  }
  // TOP (n): keep the first n action rows
  let ops = match m.top {
    Some(tp) => {
      if tp.percent {
        raise @types.not_supported("MERGE TOP PERCENT")
      }
      let (v, _) = self.eval(tp.count)
      let k = v.as_int64().unwrap_or(0L).to_int()
      if k < 0 {
        raise @types.sql_error(
          127,
          "A TOP N or FETCH rows count value may not be negative.",
          severity=15,
        )
      }
      ops[0:@cmp.minimum(k, ops.length())].to_owned()
    }
    None => ops
  }
  let sent = self.output_header(outputs)
  let evaluated = []
  // lock the target rows MERGE changes
  let locked = []
  for o in ops {
    match o {
      MUpdate(rowid, old, _, _) | MDelete(rowid, old, _) =>
        locked.push((rowid, old))
      MInsert(_, _) => ()
    }
  }
  self.lock_rows(target, locked)
  // build new images
  let deleted_rows : Set[Int64] = Set([])
  for o in ops {
    if o is MDelete(rowid, _, _) {
      deleted_rows.add(rowid)
    }
  }
  let mut db = self.db_of(target.scope)
  let final_ops = []
  {
    errdefer self.output_send(outputs, evaluated[:])
    for o in ops {
      match o {
        MUpdate(rowid, old, _, s) => {
          let w = match
            pick(
              x => {
                if matched_target.contains(rowid) {
                  x is Matched
                } else {
                  x is NotMatchedBySource
                }
              },
              old + s,
            ) {
            Some(w) => w
            None => continue
          }
          guard w.action is MergeUpdate(sets) else { continue }
          let row = old.copy()
          let ctx = self.ctx().with_row(old + s)
          for sc in sets {
            guard sc.target is SetColumn(parts) else {
              raise @types.not_supported("MERGE SET @variable")
            }
            let name = parts[parts.length() - 1].name
            let ci = match t.column_index(name) {
              Some(i) => i
              None =>
                raise @types.sql_error(207, "Invalid column name '\{name}'.")
            }
            let b = @bind.bind_expr(env, sc.value)
            let v = @exec.eval(ctx, b)
            row[ci] = self.to_column(target, t.columns[ci], v, b.ty)
          }
          for i, c in t.columns {
            if c.computed is Some(expr) {
              row[i] = self.eval_text(target, expr, row, c.ty)
            }
          }
          self.check_row(target, db, row, "MERGE")
          self.merge_push(
            final_ops,
            evaluated,
            outputs,
            MUpdate(rowid, old, row, s),
            null_target,
          )
        }
        MDelete(_, _, _) =>
          self.merge_push(final_ops, evaluated, outputs, o, null_target)
        MInsert(_, s) => {
          let w = match pick(x => x is NotMatchedByTarget, null_target + s) {
            Some(w) => w
            None => continue
          }
          guard w.action is MergeInsert(columns~, values~, default_values~) else {
            continue
          }
          let row = Array::make(n, @types.Value::Null)
          let given = Array::make(n, false)
          if !default_values {
            let cols = if columns.is_empty() {
              let out = []
              for i, c in t.columns {
                if c.identity is None &&
                  c.computed is None &&
                  c.ty != RowVersion {
                  out.push(i)
                }
              }
              out
            } else {
              columns.map(c => {
                match t.column_index(c.name) {
                  Some(i) => i
                  None =>
                    raise @types.sql_error(
                      207,
                      "Invalid column name '\{c.name}'.",
                    )
                }
              })
            }
            let ctx = self.ctx().with_row(null_target + s)
            for j, e in values {
              if j < cols.length() && !(e.kind is Default) {
                let b = @bind.bind_expr(env, e)
                row[cols[j]] = self.to_column(
                  target,
                  t.columns[cols[j]],
                  @exec.eval(ctx, b),
                  b.ty,
                )
                given[cols[j]] = true
              }
            }
          }
          for i, c in t.columns {
            if given[i] {
              continue
            }
            match (c.identity, c.default_) {
              (Some(id), _) => {
                let v = self.next_identity(t, id)
                row[i] = identity_value(c.ty, v)
                let iv : @types.Value = Decimal(@types.Decimal::from_int64(v))
                self.rt.identity = iv
                self.rt.scope_identity = iv
              }
              (_, Some(d)) if c.computed is None =>
                row[i] = self.eval_text(target, d, row, c.ty)
              _ => ()
            }
          }
          for i, c in t.columns {
            if c.computed is Some(expr) {
              row[i] = self.eval_text(target, expr, row, c.ty)
            }
          }
          self.check_row(target, db, row, "MERGE")
          self.merge_push(
            final_ops,
            evaluated,
            outputs,
            MInsert(row, s),
            null_target,
          )
        }
      }
    }
  }
  self.output_finish(outputs, evaluated)
  db = self.db_of(target.scope)
  // apply: references, removals, then inserts with unique checks
  let removed = []
  let removed_new = []
  for o in final_ops {
    match o {
      MUpdate(_, old, new, _) => {
        removed.push(old)
        removed_new.push(Some(new))
      }
      MDelete(_, old, _) => {
        removed.push(old)
        removed_new.push(None)
      }
      MInsert(_, _) => ()
    }
  }
  self.check_references(target, db, removed, removed_new, "MERGE")
  for o in final_ops {
    match o {
      MUpdate(rowid, _, _, _) | MDelete(rowid, _, _) =>
        db = db.delete_row(t.id, rowid)
      MInsert(_, _) => ()
    }
  }
  for o in final_ops {
    match o {
      MUpdate(rowid, _, new, _) => db = insert_checked(target, db, rowid, new)
      MInsert(new, _) => {
        let rowid = self.server.rowid()
        if target.scope == 0 {
          self.acquire(row_resource(t, rowid, new), X, Transaction)
        }
        db = insert_checked(target, db, rowid, new)
      }
      MDelete(_, _, _) => ()
    }
  }
  self.write(target.scope, db)
  let count = final_ops.length().to_int64()
  self.rt.rowcount = count
  self.done(279, count=Some(count), result_set=sent)
}

///|
/// Records a MERGE action and evaluates its OUTPUT row (streamed: rows
/// before a failing action are still sent; captured: output/stream-errors).
fn Session::merge_push(
  self : Session,
  ops : Array[MergeOp],
  evaluated : Array[Array[Array[@types.Value]]],
  outputs : Array[OutputSpec],
  op : MergeOp,
  null_target : Array[@types.Value],
) -> Unit raise {
  ops.push(op)
  if outputs.is_empty() {
    return
  }
  let row = match op {
    MUpdate(_, old, new, s) => old + new + s + [@types.Value::String("UPDATE")]
    MDelete(_, old, s) =>
      old + null_target + s + [@types.Value::String("DELETE")]
    MInsert(new, s) => null_target + new + s + [@types.Value::String("INSERT")]
  }
  evaluated.push(self.output_eval(outputs, row))
}
