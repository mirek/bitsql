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
  // CTEs may feed the source (captured: gaps-triggers #116); a CTE as the
  // MERGE target is not modelled
  let cte_env = self.env().with_ctes(m.ctes)
  if m.target.kind is Table(tname, ..) && cte_env.find_cte(tname) is Some(_) {
    raise @types.not_supported("MERGE into a CTE")
  }
  let target = self.dml_target(m.target)
  self.readpast_target(m.target, [], None, Some(target.table), merge=true)
  let has_insert = m.whens.iter().any(w => w.action is MergeInsert(..))
  let has_update = m.whens.iter().any(w => w.action is MergeUpdate(_))
  let has_delete = m.whens.iter().any(w => w.action is MergeDelete)
  // INSTEAD OF triggers (captured: gaps-triggers #145-#159): either every
  // action present has one (they fire instead of the writes, per action in
  // INSERT, UPDATE, DELETE order; AFTER triggers do not fire) or none has
  // (5316 otherwise, a compile error naming the target as written)
  let io_ins = if has_insert {
    self.instead_of_trigger(target, OnInsert)
  } else {
    []
  }
  let io_upd = if has_update {
    self.instead_of_trigger(target, OnUpdate)
  } else {
    []
  }
  let io_del = if has_delete {
    self.instead_of_trigger(target, OnDelete)
  } else {
    []
  }
  let io_some = !io_ins.is_empty() || !io_upd.is_empty() || !io_del.is_empty()
  let io = io_some &&
    (!has_insert || !io_ins.is_empty()) &&
    (!has_update || !io_upd.is_empty()) &&
    (!has_delete || !io_del.is_empty())
  if io_some && !io {
    let written = match m.target.kind {
      Table(tname, ..) => object_text(tname)
      _ => target.table.name
    }
    raise @types.sql_error(
      5316,
      "The target '\{written}' of the MERGE statement has an INSTEAD OF trigger on some, but not all, of the actions specified in the MERGE statement. In a MERGE statement, if any action has an enabled INSTEAD OF trigger on the target, then all actions must have enabled INSTEAD OF triggers.",
    )
  }
  let pre = self.db_of(target.scope)
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  let n = t.columns.length()
  let identity_insert = self.identity_insert == Some(t.id)
  // compile-time checks of the action clauses (DONE 253; captured: msduck
  // gaps-merge #035-#037, stmts/merge-hints)
  let mut identity_error : @types.SqlError? = None
  for w in m.whens {
    match w.action {
      MergeUpdate(sets) => {
        if sets.any(s => s.mutator) && duplicate_set_column(sets) is Some(name) {
          raise duplicate_mutator_column(name)
        }
        for sc in sets {
          guard sc.target is SetColumn(parts) else { continue }
          match t.column_index(parts[parts.length() - 1].name) {
            Some(ci) => {
              let c = t.columns[ci]
              if c.identity is Some(_) {
                raise @types.sql_error(
                  8102,
                  "Cannot update identity column '\{c.name}'.",
                )
              }
              if c.computed is Some(_) {
                raise @types.sql_error(
                  271,
                  "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
                )
              }
            }
            None => ()
          }
        }
      }
      MergeInsert(columns~, values~, default_values~) if !default_values => {
        if columns.is_empty() {
          let width = t.columns
            .iter()
            .filter(c => {
              (c.identity is None || identity_insert) &&
              c.computed is None &&
              c.ty != RowVersion
            })
            .count()
          if values.length() != width {
            raise @types.sql_error(
              213, "Column name or number of supplied values does not match table definition.",
            )
          }
        } else if values.length() < columns.length() {
          raise @types.sql_error(
            109,
            "There are more columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
            severity=15,
          )
        } else if values.length() > columns.length() {
          raise @types.sql_error(
            110,
            "There are fewer columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
            severity=15,
          )
        }
        for col in columns {
          match t.column_index(col.name) {
            Some(ci) => {
              let c = t.columns[ci]
              if c.computed is Some(_) {
                raise @types.sql_error(
                  271,
                  "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
                )
              }
              if c.identity is Some(_) &&
                !identity_insert &&
                identity_error is None {
                identity_error = Some(
                  @types.sql_error(
                    544,
                    "Cannot insert explicit value for identity column in table '\{t.name}' when IDENTITY_INSERT is set to OFF.",
                  ),
                )
              }
            }
            None => ()
          }
        }
      }
      _ => ()
    }
  }
  // 544 is raised when the statement starts executing (DONE 279, no 3621;
  // captured: gaps-merge #034)
  if identity_error is Some(e) {
    self.cur_cmd = 279
    raise e
  }
  let env0 = cte_env
  let (source_plan, source_cols) = @bind.bind_sources(env0, [m.source])
  let target_cols = table_columns(t).map(c => {
    ..c,
    qualifier: target.qualifier,
  })
  let env = env0.with_columns(target_cols + source_cols)
  // Mutator diagnostics must bind even when no source/target row matches.
  let mutators : Map[Int, @ir.Expr] = Map([])
  for w in m.whens {
    guard w.action is MergeUpdate(sets) else { continue }
    for sc in sets {
      if !sc.mutator {
        continue
      }
      guard sc.target is SetColumn(parts) &&
        sc.value.kind is MethodCall(_, meth, args) else {
        raise @types.emulator_error(
          @types.EMU_INTERNAL,
          "invalid MERGE mutator AST",
        )
      }
      let name = parts[parts.length() - 1].name
      guard t.column_index(name) is Some(ci) else {
        raise @types.sql_error(207, "Invalid column name '\{name}'.")
      }
      let c = t.columns[ci]
      let current : @ir.Expr = {
        kind: Col(env.columns.length()),
        ty: c.ty,
        nullable: c.nullable,
      }
      mutators[sc.span.start] = @bind.bind_json_mutator(
        env,
        current,
        meth.name,
        args,
        c.name,
      )
    }
  }
  let on = @bind.bind_expr(env, m.on)
  // bind clauses
  let bound_whens = m.whens.map(w => {
    let cond = match w.condition {
      Some(c) => Some(@bind.bind_expr(env, c))
      None => None
    }
    (w, cond)
  })
  // compiling (batch prebind, sp_prepare) stops at the OUTPUT header
  // without reading rows, like the other DML statements
  let target_rows = if self.compile_only {
    []
  } else {
    self.db_of(target.scope).rows(t.id)
  }
  let source_rows = if self.compile_only {
    []
  } else {
    @exec.run(self.ctx(), source_plan)
  }
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
    untyped_null: false,
    qualifier: "",
    name: "$action",
    ty: NVarChar(Some(10), @types.default_collation),
    nullable: false,
    origin: SetOperation,
  }
  // OUTPUT without INTO: 334 only for an enabled trigger on an event the
  // MERGE performs, naming the target as written (captured: gaps-triggers
  // #118, #119, #121)
  if m.output.iter().any(c => c.into is None) {
    let events : Array[@ast.DmlEvent] = []
    if has_insert {
      events.push(OnInsert)
    }
    if has_update {
      events.push(OnUpdate)
    }
    if has_delete {
      events.push(OnDelete)
    }
    for ev in events {
      if !self.table_triggers(target, ev).is_empty() {
        raise @types.sql_error(
          334,
          "The target table '\{target.qualifier}' of the DML statement cannot have any enabled triggers if the statement contains an OUTPUT clause without INTO clause.",
        )
      }
    }
  }
  let outputs = self.bind_output(
    m.output,
    target,
    None,
    true,
    true,
    // source columns are NULL for NOT MATCHED BY SOURCE rows (captured:
    // gaps-merge #011 IntN flags 1)
    (if m.whens.iter().any(w => w.match_ is NotMatchedBySource) {
      source_cols.map(c => { ..c, nullable: true, })
    } else {
      source_cols
    }) +
    [action_col],
    null_deleted=m.whens.iter().any(w => w.action is MergeInsert(..)),
    null_inserted=m.whens.iter().any(w => w.action is MergeDelete),
    trigger_check=false,
  )
  let ops : Array[MergeOp] = []
  let matched_target : Set[Int64] = Set([])
  self.cur_cmd = 279
  // Match every (target, source) pair first; actions are then produced in
  // target order, then inserts in source order (captured: dml/merge-upsert
  // OUTPUT order UPDATE, DELETE, INSERT).
  let source_matched = Array::make(source_rows.length(), false)
  // (an equi-join ON is matched by key instead of over every pair)
  let matches = @exec.match_pairs(
    self.ctx(),
    on,
    target_rows.map(tr => tr.1),
    n,
    source_rows,
  )
  for ms in matches {
    for si in ms {
      source_matched[si] = true
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
            MergeUpdate(_) => ops.push(MUpdate(rowid, trow, [], s))
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
  // TOP (n): keep the first n action rows
  let ops = match m.top {
    Some(tp) => {
      let (v, vty) = self.eval(tp.count)
      if tp.percent {
        // captured (msduck-runs/merge-top-percent): ceil(n * p / 100) of
        // the action rows; NULL is 1014, outside 0..100 is 1031 (class 15)
        if v is Null {
          self.cur_cmd = 253
          raise @types.sql_error(
            1014,
            "A TOP or FETCH clause contains an invalid value.",
            severity=15,
          )
        }
        let p = match @types.cast(v, vty, Float) {
          Float(f) => f
          _ => 0.0
        }
        if p < 0.0 || p > 100.0 {
          self.cur_cmd = 253
          raise @types.sql_error(
            1031,
            "Percent values must be between 0 and 100.",
            severity=15,
          )
        }
        let k = (p * ops.length().to_double() / 100.0).ceil().to_int()
        ops[0:@cmp.minimum(k, ops.length())].to_owned()
      } else {
        let k = v.as_int64().unwrap_or(0L).to_int()
        if k < 0 {
          raise @types.sql_error(
            127,
            "A TOP N or FETCH rowcount value may not be negative.",
            severity=15,
          )
        }
        ops[0:@cmp.minimum(k, ops.length())].to_owned()
      }
    }
    None => ops
  }
  // A target row reached by several actions (captured: gaps-merge #016,
  // #017, #019): two DELETEs delete it once; any pair with an UPDATE fails
  // with 8672 at the second action, after the OUTPUT rows of the actions
  // before it were sent; the batch ends and the transaction rolls back.
  let seen : Map[Int64, Bool] = Map([])
  let kept = []
  let mut duplicate = false
  for o in ops {
    let (rowid, del) = match o {
      MUpdate(rowid, _, _, _) => (rowid, false)
      MDelete(rowid, _, _) => (rowid, true)
      MInsert(_, _) => {
        kept.push(o)
        continue
      }
    }
    match seen.get(rowid) {
      Some(true) if del => continue
      Some(_) => {
        duplicate = true
        break
      }
      None => seen[rowid] = del
    }
    kept.push(o)
  }
  let ops = kept
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
  self.lock_rows(target, locked, r => r.0, r => r.1)
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
            let c = t.columns[ci]
            let rhs = if sc.mutator {
              guard mutators.get(sc.span.start) is Some(bound) else {
                raise @types.emulator_error(
                  @types.EMU_INTERNAL,
                  "unbound MERGE mutator",
                )
              }
              bound
            } else {
              @bind.bind_expr(env, sc.value)
            }
            let (v, ty) = if sc.mutator {
              (
                @exec.eval(self.ctx().with_row(old + s + [old[ci]]), rhs),
                rhs.ty,
              )
            } else if sc.op is Assign {
              (@exec.eval(ctx, rhs), rhs.ty)
            } else {
              // `col op= e` is `col = col op e`: the column's current value
              // is read one past the target + source row
              let current : @ir.Expr = {
                kind: Col(env.columns.length()),
                ty: c.ty,
                nullable: c.nullable,
              }
              let b = @bind.compound_assignment(env, sc.op, current, rhs)
              (@exec.eval(self.ctx().with_row(old + s + [old[ci]]), b), b.ty)
            }
            row[ci] = self.to_column(target, c, v, ty)
          }
          for i, c in t.columns {
            if c.computed is Some(expr) {
              row[i] = self.eval_text(target, expr, row, c.ty)
            }
          }
          if !io {
            self.check_row(target, db, row, "MERGE")
          }
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
              // INSTEAD OF INSERT sees 0 and consumes no identity value
              (Some(_), _) if io => row[i] = identity_value(c.ty, 0L)
              (Some(id), _) => {
                let v = self.next_identity(target.scope, t, id)
                row[i] = identity_value(c.ty, v)
                let iv : @types.Value = Decimal(@types.Decimal::from_int64(v))
                self.rt.identity = iv
                self.rt.scope_identity = iv
              }
              (_, Some(d)) if c.computed is None =>
                row[i] = self.eval_default(target, c, d, row)
              _ => ()
            }
          }
          for i, c in t.columns {
            if c.computed is Some(expr) {
              row[i] = self.eval_text(target, expr, row, c.ty)
            }
          }
          if !io {
            self.check_row(target, db, row, "MERGE")
          }
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
  if duplicate {
    raise @types.sql_error(
      8672, "The MERGE statement attempted to UPDATE or DELETE the same row more than once. This happens when a target row matches more than one source row. A MERGE statement cannot UPDATE/DELETE the same row of the target table multiple times. Refine the ON clause to ensure a target row matches at most one source row, or use the GROUP BY clause to group the source rows.",
    )
  }
  if io {
    let count = final_ops.length().to_int64()
    let all = Array::makei(t.columns.length(), i => i)
    let ins = final_ops.filter_map(o => {
      match o {
        MInsert(new, _) => Some(new)
        _ => None
      }
    })
    if has_insert {
      self.run_triggers(target, io_ins, [], ins, all, pre, firing_count=count)
    }
    if has_update {
      let olds = []
      let news = []
      for o in final_ops {
        if o is MUpdate(_, old, new, _) {
          olds.push(old)
          news.push(new)
        }
      }
      self.run_triggers(
        target,
        io_upd,
        olds,
        news,
        merge_set_columns(m, t),
        pre,
        firing_count=count,
      )
    }
    if has_delete {
      let dels = final_ops.filter_map(o => {
        match o {
          MDelete(_, old, _) => Some(old)
          _ => None
        }
      })
      self.run_triggers(target, io_del, dels, [], [], pre, firing_count=count)
    }
    self.rt.rowcount = count
    self.done(279, count=Some(count), result_set=sent)
    return
  }
  db = self.db_of(target.scope)
  // apply: references, removals, then inserts with unique checks
  let removed = []
  let removed_new = []
  let row_lock = row_lock(t)
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
  // one at a time: delete every changed row, then insert in action order
  let sequential = (start : @store.Db) => {
    let mut d = start
    for o in final_ops {
      match o {
        MUpdate(rowid, _, _, _) | MDelete(rowid, _, _) =>
          d = d.delete_row(t.id, rowid)
        MInsert(_, _) => ()
      }
    }
    for o in final_ops {
      match o {
        MUpdate(rowid, _, new, _) => d = insert_checked(target, d, rowid, new)
        MInsert(new, _) => {
          let rowid = self.server.rowid()
          if is_db_scope(target.scope) {
            self.acquire(row_lock.resource(rowid, new), X, Transaction)
          }
          d = insert_checked(target, d, rowid, new)
        }
        MDelete(_, _, _) => ()
      }
    }
    d
  }
  db = if final_ops.iter().any(o => o is MInsert(_, _)) {
    sequential(db)
  } else {
    // no inserts (no row ids or locks taken): applied as one set, the
    // sequential pass names the failing row on an error
    let images = []
    let deleted = []
    for o in final_ops {
      match o {
        MUpdate(rowid, old, new, _) => images.push((rowid, old, new))
        MDelete(rowid, _, _) => deleted.push(rowid)
        MInsert(_, _) => ()
      }
    }
    let start = db
    apply_images(target, start, images, deleted~) catch {
      _ => sequential(start)
    }
  }
  let mut cascaded = []
  if fk_referencing(db, t.id) {
    let changes : Array[RowChange] = final_ops.filter_map(o => {
      match o {
        MUpdate(rowid, old, new, _) => Some((rowid, old, Some(new)))
        MDelete(rowid, old, _) => Some((rowid, old, None))
        MInsert(_, _) => None
      }
    })
    let (fin, nodes) = self.cascade_actions(
      target.scope,
      t.id,
      db,
      changes,
      "MERGE",
    )
    db = fin
    cascaded = nodes
    self.check_references(target, db, removed, removed_new, "MERGE")
  }
  self.write(target.scope, db)
  self.fire_cascade_triggers(target.scope, cascaded, pre)
  // AFTER triggers fire per action clause present, even for zero rows, in
  // the order INSERT, UPDATE, DELETE (captured: triggers/merge-after)
  if has_insert {
    let rows = final_ops.filter_map(o => {
      match o {
        MInsert(new, _) => Some(new)
        _ => None
      }
    })
    self.fire_after(
      target,
      OnInsert,
      [],
      rows,
      Array::makei(t.columns.length(), i => i),
      pre,
      firing_count=final_ops.length().to_int64(),
    )
  }
  if has_update {
    let olds = []
    let news = []
    for o in final_ops {
      if o is MUpdate(_, old, new, _) {
        olds.push(old)
        news.push(new)
      }
    }
    let updated = merge_set_columns(m, t)
    self.fire_after(
      target,
      OnUpdate,
      olds,
      news,
      updated,
      pre,
      firing_count=final_ops.length().to_int64(),
    )
  }
  if has_delete {
    let rows = final_ops.filter_map(o => {
      match o {
        MDelete(_, old, _) => Some(old)
        _ => None
      }
    })
    self.fire_after(
      target,
      OnDelete,
      rows,
      [],
      [],
      pre,
      firing_count=final_ops.length().to_int64(),
    )
  }
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

///|
/// Columns any WHEN ... UPDATE SET clause assigns (UPDATE(col) in triggers).
fn merge_set_columns(m : @ast.Merge, t : @store.Table) -> Array[Int] {
  let updated = []
  for w in m.whens {
    guard w.action is MergeUpdate(sets) else { continue }
    for s in sets {
      guard s.target is SetColumn(parts) else { continue }
      match t.column_index(parts[parts.length() - 1].name) {
        Some(i) => if !updated.contains(i) { updated.push(i) }
        None => ()
      }
    }
  }
  updated
}
