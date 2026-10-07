// INSERT, UPDATE and DELETE execution. Statement shape (captures:
// harness/corpus/output/*, views/*): bind everything (compile errors complete
// with 253), then set the DML CurCmd and send the OUTPUT COLMETADATA, then
// process rows one at a time. A run-time error sends the OUTPUT rows of the
// rows processed before it.

///|
fn rowversion_bytes(v : Int64) -> Bytes {
  Bytes::makei(8, i => (v >> (8 * (7 - i))).to_byte())
}

///|
fn table_target(scope : Int, t : @store.Table, qualifier : String) -> Target {
  {
    scope,
    table: t,
    display: if scope == 1 {
      t.name
    } else {
      t.schema + "." + t.name
    },
    qualifier,
  }
}

///|
/// UPDATE/DELETE target: a one-part name naming a FROM alias refers to that
/// FROM item (a table, view, CTE or derived table).
fn Session::resolve_dml_target(
  self : Session,
  env0 : @bind.Env,
  r : @ast.TableRef,
  from : Array[@ast.TableRef],
  purpose : DmlPurpose,
) -> (Target, ViewTarget?) raise {
  if r.kind is Table(name, alias_=None, ..) && name.parts.length() == 1 {
    let wanted = name.parts[0].name.to_lower()
    for leaf in from_leaves(from) {
      match leaf.kind {
        Table(real, alias_=Some(a), hints~) if a.name.to_lower() == wanted =>
          return self.resolve_named_target(
            env0,
            { ..leaf, kind: Table(real, alias_=Some(a), hints~), },
            from,
            purpose,
          )
        // `UPDATE i ... FROM @t AS i` (captured: msduck gaps-temp_tables
        // #035)
        TableVar(_, alias_=Some(a), ..) if a.name.to_lower() == wanted =>
          return (self.dml_target(leaf), None)
        Derived(q, alias_=Some(a), columns~) if a.name.to_lower() == wanted => {
          let v = self.view_target(env0, q, columns, a.name, KDerived, purpose)
          return (table_target(v.scope, v.table, wanted), Some(v))
        }
        _ => ()
      }
    }
  }
  self.resolve_named_target(env0, r, from, purpose)
}

///|
fn Session::resolve_named_target(
  self : Session,
  env0 : @bind.Env,
  r : @ast.TableRef,
  from : Array[@ast.TableRef],
  purpose : DmlPurpose,
) -> (Target, ViewTarget?) raise {
  guard r.kind is Table(name, alias_~, ..) else {
    return (self.dml_target(r), None)
  }
  let q = match alias_ {
    Some(a) => a.name.to_lower()
    None => name.base().to_lower()
  }
  match env0.find_cte(name) {
    Some(cte) => {
      let v = self.view_target(
        cte.env,
        cte.def.query,
        cte.def.columns,
        cte.def.name.name,
        KCte,
        purpose,
      )
      return (table_target(v.scope, v.table, q), Some(v))
    }
    None => ()
  }
  match self.find_view(name) {
    Some((m, vq, vnames)) => {
      let v = self.view_target(
        self.view_env(),
        vq,
        vnames,
        m.name,
        KView(check=m.check_option),
        purpose,
      )
      return (table_target(v.scope, v.table, q), Some(v))
    }
    None => ()
  }
  let target = self.dml_target(r)
  if alias_ is Some(_) || from.is_empty() {
    return (target, None)
  }
  // An unaliased target binds to an unaliased occurrence of its table in
  // FROM, else to its only aliased occurrence; two aliased ones are 8154
  // (captured: output/join-targets).
  let mut unaliased = false
  let aliased = []
  for leaf in from_leaves(from) {
    guard leaf.kind is Table(n, alias_=la, ..) else { continue }
    guard self.find_table(n) is Some((sc, t2)) &&
      sc == target.scope &&
      t2.id == target.table.id else {
      continue
    }
    match la {
      Some(a) => aliased.push(a.name.to_lower())
      None => unaliased = true
    }
  }
  if !unaliased && aliased.length() == 1 {
    return ({ ..target, qualifier: aliased[0], }, None)
  }
  if !unaliased && aliased.length() > 1 {
    raise @types.sql_error(
      8154,
      "The table '\{name.parts.map(p => p.name).join(".")}' is ambiguous.",
    )
  }
  (target, None)
}

///|
fn dml_source(
  env0 : @bind.Env,
  target : Target,
  view : ViewTarget?,
  from : Array[@ast.TableRef],
) -> @bind.DmlSource raise {
  match view {
    Some(v) =>
      @bind.bind_dml_source(
        env0,
        from,
        base_binding(v.scope, v.table),
        [target.qualifier],
        view=Some(v.leaf),
      )
    None =>
      @bind.bind_dml_source(
        env0,
        from,
        base_binding(target.scope, target.table),
        [target.qualifier, target.table.name.to_lower()],
      )
  }
}

///|
/// Columns of the FROM sources other than the target, as OUTPUT sees them
/// (the target's own alias is not visible; aliases named inserted/deleted
/// are shadowed by the pseudo-tables), with their positions in the row.
fn output_extra(
  src : @bind.DmlSource,
  from : Array[@ast.TableRef],
) -> (Array[@bind.ColumnRef], Array[Int]) {
  let cols = []
  let idx = []
  if from.is_empty() {
    return (cols, idx)
  }
  for i, c in src.columns {
    if i >= src.leaf_start && i < src.leaf_start + src.leaf_width {
      continue
    }
    if c.qualifier.has_prefix("%") ||
      c.qualifier == "inserted" ||
      c.qualifier == "deleted" {
      continue
    }
    cols.push(c)
    idx.push(i)
  }
  (cols, idx)
}

///|
/// TOP of UPDATE/DELETE, bound.
fn Session::dml_top(self : Session, top : @ast.Top?) -> @ir.Expr? raise {
  match top {
    Some(tp) => {
      if tp.percent || tp.with_ties {
        raise @types.not_supported("TOP PERCENT / WITH TIES in DML")
      }
      Some(@bind.coerce(@bind.bind_expr(self.env(), tp.count), BigInt))
    }
    None => None
  }
}

///|
/// Rows to modify: (rowid, base image, full source row). The WHERE is
/// evaluated row by row; an error there is returned with the rows that
/// qualified before it (they are processed first). A target row matched
/// by several source rows appears once, with its first match (which match
/// SQL Server keeps is plan-dependent: docs/design/fidelity-traps.md).
fn Session::dml_scan(
  self : Session,
  src : @bind.DmlSource,
  n : Int,
  where_ : @ir.Expr?,
  top : @ir.Expr?,
) -> (Array[(Int64, Array[@types.Value], Array[@types.Value])], Error?) raise {
  let limit = match top {
    Some(e) => {
      let k = match @exec.eval(self.ctx(), e).as_int64() {
        Some(k) => k
        None =>
          raise @types.sql_error(
            1014,
            "A TOP or FETCH clause contains an invalid value.",
            severity=15,
          )
      }
      if k < 0L {
        raise @types.sql_error(
          127,
          "A TOP N or FETCH rowcount value may not be negative.",
          severity=15,
        )
      }
      Some(k)
    }
    None => None
  }
  // a WHERE that cannot fail on any row (`id = @id`) narrows a single-table
  // scan through `Filter(Scan)`, which seeks an index when one fits: the
  // same rows in the same (row id) order, without visiting the others
  let plan = match (src.plan, where_) {
    (Scan(..), Some(w)) if never_fails(w) => @ir.Plan::Filter(src.plan, w)
    _ => src.plan
  }
  let rows = @exec.run(self.ctx(), plan)
  // Preserve one context across predicate rows: variables remain the same
  // frame's array, and callbacks still resolve live session state.
  let ctx = self.ctx()
  let out = []
  let at : Map[Int64, Int] = Map([])
  for r in rows {
    match where_ {
      Some(w) => {
        let ok = @exec.is_true(@exec.eval(ctx.with_row(r), w)) catch {
          @types.Suspend => raise @types.Suspend
          @types.SqlError(..) as e => return (out, Some(e))
        }
        if !ok {
          continue
        }
      }
      None => ()
    }
    // a target on the NULL-extended side of an outer join has no row to
    // modify (captured: msduck gaps-outer_dml #003-#005, #020)
    if r[src.rowid] is Null {
      continue
    }
    let rowid = r[src.rowid].as_int64().unwrap_or(0L)
    let rec = (rowid, r[src.base:src.base + n].to_owned(), r)
    match at.get(rowid) {
      Some(_) => ()
      None => {
        match limit {
          Some(k) if out.length().to_int64() >= k => break
          _ => ()
        }
        at[rowid] = out.length()
        out.push(rec)
      }
    }
  }
  (out, None)
}

///|
/// A predicate whose evaluation raises for no row and depends on nothing
/// but the row and the variables: AND of comparisons between columns,
/// variables and literals of one scalar type (`@types.compare` raises only
/// for mixed or non-comparable representations).
fn never_fails(e : @ir.Expr) -> Bool {
  let leaf = (x : @ir.Expr) => x.kind is (Col(_) | Var(_) | Lit(_))
  match e.kind {
    And(a, b) => never_fails(a) && never_fails(b)
    Cmp(_, a, b, _) =>
      leaf(a) &&
      leaf(b) &&
      a.ty == b.ty &&
      a.ty.family()
      is (FBit
      | FInteger
      | FDecimal
      | FMoney
      | FFloat
      | FString
      | FBinary
      | FDate
      | FTime
      | FDateTime
      | FGuid)
    _ => false
  }
}

///|
/// The database after replacing the image rows (rowid, old, new) as one
/// set: what deleting every old row and then `insert_checked` of every
/// new row in order gives, and raising when that would. Rows whose index
/// entries stay the same (`same_index_entries`) only replace their value;
/// their keys already coexisted with every other row under each unique
/// index, so whether some insert would conflict is unchanged. `deleted`
/// rows are removed first as well. On an error `unique_failure` tells
/// which row failed.
fn apply_images(
  target : Target,
  db : @store.Db,
  images : Array[(Int64, Array[@types.Value], Array[@types.Value])],
  deleted? : Array[Int64] = [],
) -> @store.Db raise {
  let t = target.table
  let keep = images.map(im => @store.same_index_entries(t, im.1, im.2))
  let gone = deleted.copy()
  for i, im in images {
    if !keep[i] {
      gone.push(im.0)
    }
  }
  let replaced = []
  for i, im in images {
    if keep[i] {
      replaced.push((im.0, im.2))
    }
  }
  let mut d = db.delete_rows(t.id, gone).replace_rows(t.id, replaced)
  for i, im in images {
    if !keep[i] {
      d = insert_checked(target, d, im.0, im.2)
    }
  }
  d
}

///|
/// Applies new row images with statement-level uniqueness. On a duplicate
/// key, also returns how many rows SQL Server processed before failing:
/// the first row whose new key collides when rows are applied one at a
/// time (captured: `SET id=10` outputs row 10 first, `SET id=30` nothing).
fn unique_failure(
  target : Target,
  db : @store.Db,
  images : Array[(Int64, Array[@types.Value], Array[@types.Value])],
) -> (Int, Error)? {
  let t = target.table
  let mut d = db
  for im in images {
    d = d.delete_row(t.id, im.0)
  }
  let failed = for im in images {
    d = insert_checked(target, d, im.0, im.2) catch { e => break Some(e) }
  } nobreak {
    None
  }
  guard failed is Some(whole) else { return None }
  let mut s = db
  for i, im in images {
    s = s.delete_row(t.id, im.0)
    s = insert_checked(target, s, im.0, im.2) catch { e => return Some((i, e)) }
  }
  Some((images.length(), whole))
}

///|
fn Session::exec_update(self : Session, u : @ast.Update) -> Unit raise {
  // positioned UPDATE (WHERE CURRENT OF) completes with CurCmd 125
  let cmd = if u.current_of is Some(_) { 125 } else { 197 }
  let env0 = self.env().with_ctes(u.ctes)
  let set_names = []
  for s in u.sets {
    if s.target is SetColumn(parts) {
      set_names.push(parts[parts.length() - 1].name.to_lower())
    }
  }
  let (target, view) = self.resolve_dml_target(
    env0,
    u.target,
    u.from,
    PUpdate(set_names),
  )
  if view is None {
    // 650 completes like a run-time error of the statement (a caught one
    // sends its DONE; captured: tail5/b2-readpast)
    errdefer {
      self.cur_cmd = cmd
    }
    self.readpast_target(
      u.target,
      u.from,
      u.where_,
      Some(target.table),
      merge=false,
    )
  }
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  check_vector_dml(t)
  if u.sets.any(s => s.mutator) && duplicate_set_column(u.sets) is Some(name) {
    let name = t.column_index(name).map(i => t.columns[i].name).unwrap_or(name)
    raise duplicate_mutator_column(name)
  }
  let n = t.columns.length()
  let src = dml_source(env0, target, view, u.from)
  let env = env0.with_columns(src.columns)
  let env = if u.from.is_empty() && u.top is None {
    let xs = []
    for s in u.sets {
      xs.push(s.value)
    }
    if u.where_ is Some(w) {
      xs.push(w)
    }
    self.simple_params_env(env, target, xs)
  } else {
    env
  }
  let where_ = match u.current_of {
    Some(cursor) => {
      self.cur_cmd = cmd
      Some(
        self.current_of_predicate(
          cursor,
          u.current_of_global,
          target.scope,
          t.id,
          src.rowid,
          Some(set_names),
        ),
      )
    }
    None => u.where_.map(w => @bind.bind_expr(env, w))
  }
  let top = self.dml_top(u.top)
  // bind SET clauses against the full source row
  let width = env.columns.length()
  let sets = []
  for s in u.sets {
    match s.target {
      SetColumn(parts) => {
        let name = parts[parts.length() - 1].name
        let ci = match view {
          Some(v) => {
            let vi = v.result.search_by(c => {
              c.name.to_lower() == name.to_lower()
            })
            match vi.map(i => v.base_of[i]) {
              Some(Some(i)) => i
              _ => raise @types.sql_error(207, "Invalid column name '\{name}'.")
            }
          }
          None =>
            match t.column_index(name) {
              Some(i) => i
              None =>
                raise @types.sql_error(207, "Invalid column name '\{name}'.")
            }
        }
        let c = t.columns[ci]
        if c.identity is Some(_) {
          raise @types.sql_error(
            8102,
            "Cannot update identity column '\{c.name}'.",
          )
        }
        // captured: also SET rv = DEFAULT (msduck gaps-rowversion_identity
        // #027/#028)
        if c.ty is RowVersion {
          raise @types.sql_error(272, "Cannot update a timestamp column.")
        }
        if c.computed is Some(_) {
          raise @types.sql_error(
            271,
            "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
          )
        }
        if @bind.null_aggregate_error(s.value) is Some(e) {
          raise e
        }
        if @bind.has_aggregate(s.value) {
          raise @types.sql_error(
            157,
            "An aggregate may not appear in the set list of an UPDATE statement.",
            severity=15,
          )
        }
        // `col op= e` is `col = col op e`: the current value is appended to
        // the source row (slot `width`) while it is evaluated
        let rhs = if s.value.kind is Default {
          None
        } else {
          let current : @ir.Expr = {
            kind: Col(width),
            ty: c.ty,
            nullable: c.nullable,
          }
          Some(
            if s.mutator {
              guard s.value.kind is MethodCall(_, meth, args) else {
                raise @types.emulator_error(
                  @types.EMU_INTERNAL,
                  "invalid column mutator AST",
                )
              }
              @bind.bind_json_mutator(env, current, meth.name, args, c.name)
            } else {
              @bind.compound_assignment(
                env,
                s.op,
                current,
                @bind.bind_expr(env, s.value),
              )
            },
          )
        }
        if rhs is Some(b) {
          if !(b.kind is Lit(Null) && b.ty is Int) {
            @types.check_store(b.ty, c.ty)
          }
        }
        sets.push((ci, s.op, rhs))
      }
      SetVariable(_) | SetVarColumn(_, _) =>
        raise @types.not_supported("UPDATE SET @variable")
    }
  }
  self.check_vector_cascades(target.scope, t.id, Some(sets.map(s => s.0)))
  let (extra, extra_idx) = output_extra(src, u.from)
  let outputs = self.bind_output(u.output, target, view, true, true, extra)
  self.cur_cmd = cmd
  let sent = self.output_header(outputs)
  let (rows, deferred) = self.dml_scan(src, n, where_, top)
  self.lock_rows(target, rows, r => r.0, r => r.1)
  let db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnUpdate)
  let touched = touched_columns(t, sets.map(s => s.0))
  let images = []
  let evaluated = []
  {
    errdefer self.output_send(outputs, evaluated[:])
    for rec in rows {
      self.rt.next_row()
      let (rowid, old, full) = rec
      let row = old.copy()
      self.update_row(
        target,
        view,
        src,
        sets,
        old,
        full,
        row,
        instead.is_empty(),
        touched,
      )
      if instead.is_empty() {
        let out_row = self.update_output_row(
          view, src, extra_idx, old, full, row,
        )
        evaluated.push(self.output_eval(outputs, out_row))
      }
      images.push((rowid, old, row))
    }
    match deferred {
      Some(e) => raise e
      None => ()
    }
  }
  let updated = sets.map(s => s.0)
  if !instead.is_empty() {
    self.run_triggers(
      target,
      instead,
      images.map(x => x.1),
      images.map(x => x.2),
      updated,
      pre,
    )
    let count = images.length().to_int64()
    self.rt.rowcount = count
    self.done(cmd, count=Some(count))
    return
  }
  let applied = apply_images(target, db, images) catch {
    e =>
      match unique_failure(target, db, images) {
        Some((k, first)) => {
          self.output_send(outputs, evaluated[0:k])
          raise first
        }
        None => raise e
      }
  }
  // foreign keys against the statement's final state: rows before the
  // first conflicting one are output
  let has_refs = fk_referencing(db, t.id)
  let changes : Array[RowChange] = images.map(im => (im.0, im.1, Some(im.2)))
  let mut cascaded = []
  let fin = if has_refs {
    let (fin, nodes) = self.cascade_actions(
      target.scope,
      t.id,
      applied,
      changes,
      "UPDATE",
    )
    cascaded = nodes
    fin
  } else {
    applied
  }
  if has_refs {
    let refs = referencing_fks(fin, target.table.id)
    for k, im in images {
      let failed = try {
        self.check_self_references(target, fin, im.2, Some(touched), "UPDATE")
        self.check_references(
          target,
          fin,
          [im.1],
          [Some(im.2)],
          "UPDATE",
          refs~,
        )
        None
      } catch {
        e => Some(e)
      }
      if failed is Some(e) {
        self.output_send(outputs, evaluated[0:k])
        raise e
      }
    }
  }
  self.output_finish(outputs, evaluated)
  // OUTPUT INTO may have written to the same database
  let now = self.db_of(target.scope)
  let db = if physical_equal(now, db) {
    fin
  } else {
    let mut d = now.delete_rows(t.id, images.map(im => im.0))
    for im in images {
      d = insert_checked(target, d, im.0, im.2)
    }
    if has_refs {
      let (fin, nodes) = self.cascade_actions(
        target.scope,
        t.id,
        d,
        changes,
        "UPDATE",
      )
      d = fin
      cascaded = nodes
    }
    d
  }
  self.write(target.scope, db)
  self.fire_cascade_triggers(target.scope, cascaded, pre)
  self.fire_after(
    target,
    OnUpdate,
    images.map(x => x.1),
    images.map(x => x.2),
    updated,
    pre,
  )
  let count = images.length().to_int64()
  self.rt.rowcount = count
  self.done(cmd, count=Some(count), result_set=sent)
}

///|
/// Computes one row's new image (into `row`) and checks it: constraints,
/// references, WITH CHECK OPTION.
fn Session::update_row(
  self : Session,
  target : Target,
  view : ViewTarget?,
  src : @bind.DmlSource,
  sets : Array[(Int, @ast.AssignOp, @ir.Expr?)],
  old : Array[@types.Value],
  full : Array[@types.Value],
  row : Array[@types.Value],
  check : Bool,
  touched : Array[Int],
) -> Unit raise {
  let t = target.table
  let ctx = self.ctx().with_row(full)
  for s in sets {
    let (ci, op, rhs) = s
    let c = t.columns[ci]
    let (v, ty) = match rhs {
      None =>
        match c.default_ {
          Some(d) => (self.eval_default(target, c, d, old), c.ty)
          None => (@types.Value::Null, c.ty)
        }
      Some(b) =>
        match op {
          Assign if !(b.kind is Call(Named("JSON_MUTATE"), _)) =>
            (@exec.eval(ctx, b), b.ty)
          // compound and column mutators: `b` reads the column's current value one past the row
          _ => (@exec.eval(self.ctx().with_row(full + [old[ci]]), b), b.ty)
        }
    }
    row[ci] = self.to_column(target, c, v, ty)
  }
  for i, c in t.columns {
    if c.computed is Some(expr) {
      row[i] = self.eval_text(target, expr, row, c.ty)
    }
    if c.ty is RowVersion {
      row[i] = self.next_rowversion()
    }
  }
  if check {
    let db = self.db_of(target.scope)
    self.check_row(target, db, row, "UPDATE", touched~, self_fks=false)
  }
  match view {
    Some(v) => {
      let leaf_old = full[src.leaf_start:src.leaf_start + v.width()].to_owned()
      self.view_check(v, self.view_row_of(v, Some(leaf_old), row))
    }
    None => ()
  }
}

///|
/// [deleted image] ++ [inserted image] ++ [other FROM columns] for OUTPUT.
fn Session::update_output_row(
  self : Session,
  view : ViewTarget?,
  src : @bind.DmlSource,
  extra_idx : Array[Int],
  old : Array[@types.Value],
  full : Array[@types.Value],
  row : Array[@types.Value],
) -> Array[@types.Value] raise {
  let images = match view {
    Some(v) => {
      let k = v.leaf.visible
      let leaf_old = full[src.leaf_start:src.leaf_start + v.width()].to_owned()
      let leaf_new = self.view_row_of(v, Some(leaf_old), row)
      leaf_old[0:k].to_owned() + leaf_new[0:k].to_owned()
    }
    None => old + row
  }
  images + extra_idx.map(i => full[i])
}

///|
fn Session::exec_delete(self : Session, d : @ast.Delete) -> Unit raise {
  // positioned DELETE (WHERE CURRENT OF) completes with CurCmd 126
  let cmd = if d.current_of is Some(_) { 126 } else { 196 }
  let env0 = self.env().with_ctes(d.ctes)
  let (target, view) = self.resolve_dml_target(env0, d.target, d.from, PDelete)
  if view is None {
    // 650 completes like a run-time error of the statement (a caught one
    // sends its DONE; captured: tail5/b2-readpast)
    errdefer {
      self.cur_cmd = cmd
    }
    self.readpast_target(
      d.target,
      d.from,
      d.where_,
      Some(target.table),
      merge=false,
    )
  }
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  check_vector_dml(t)
  self.check_vector_cascades(target.scope, t.id, None)
  self.check_index_options(t)
  let src = dml_source(env0, target, view, d.from)
  let env = env0.with_columns(src.columns)
  let where_ = match d.current_of {
    Some(cursor) => {
      self.cur_cmd = cmd
      Some(
        self.current_of_predicate(
          cursor,
          d.current_of_global,
          target.scope,
          t.id,
          src.rowid,
          None,
        ),
      )
    }
    None => d.where_.map(w => @bind.bind_expr(env, w))
  }
  let top = self.dml_top(d.top)
  let (extra, extra_idx) = output_extra(src, d.from)
  let outputs = self.bind_output(d.output, target, view, true, false, extra)
  self.cur_cmd = cmd
  let sent = self.output_header(outputs)
  let (rows, deferred) = self.dml_scan(src, t.columns.length(), where_, top)
  self.lock_rows(target, rows, r => r.0, r => r.1)
  let mut db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnDelete)
  if !instead.is_empty() {
    match deferred {
      Some(e) => raise e
      None => ()
    }
    self.run_triggers(target, instead, rows.map(r => r.1), [], [], pre)
    let count = rows.length().to_int64()
    self.rt.rowcount = count
    self.done(cmd, count=Some(count))
    return
  }
  let evaluated = []
  // references against the statement's final state (cascades applied): a
  // self-referencing DELETE of every row succeeds
  let has_refs = fk_referencing(db, t.id)
  let changes : Array[RowChange] = rows.map(r => (r.0, r.1, None))
  let mut cascaded = []
  let fin = if has_refs {
    let fin = db.delete_rows(t.id, rows.map(r => r.0))
    let (fin, nodes) = self.cascade_actions(
      target.scope,
      t.id,
      fin,
      changes,
      "DELETE",
    )
    cascaded = nodes
    fin
  } else {
    db
  }
  {
    errdefer self.output_send(outputs, evaluated[:])
    let refs = if has_refs { referencing_fks(fin, target.table.id) } else { [] }
    for r in rows {
      let image = match view {
        Some(v) =>
          r.2[src.leaf_start:src.leaf_start + v.leaf.visible].to_owned()
        None => r.1
      }
      if has_refs {
        self.check_references(target, fin, [r.1], [None], "DELETE", refs~)
      }
      evaluated.push(
        self.output_eval(outputs, image + extra_idx.map(i => r.2[i])),
      )
    }
    match deferred {
      Some(e) => raise e
      None => ()
    }
  }
  self.output_finish(outputs, evaluated)
  // OUTPUT INTO may have written to the same database; otherwise the
  // checked final state is the result (cascades run once)
  let now = self.db_of(target.scope)
  if has_refs && physical_equal(now, db) {
    db = fin
  } else {
    db = now.delete_rows(t.id, rows.map(r => r.0))
    if has_refs {
      let (fin, nodes) = self.cascade_actions(
        target.scope,
        t.id,
        db,
        changes,
        "DELETE",
      )
      db = fin
      cascaded = nodes
    }
  }
  self.write(target.scope, db)
  self.fire_cascade_triggers(target.scope, cascaded, pre)
  self.fire_after(target, OnDelete, rows.map(r => r.1), [], [], pre)
  let count = rows.length().to_int64()
  self.rt.rowcount = count
  self.done(cmd, count=Some(count), result_set=sent)
}

///|
fn Session::exec_insert(self : Session, ins : @ast.Insert) -> Unit raise {
  if ins.top is Some(_) {
    raise @types.not_supported("INSERT with TOP")
  }
  let env0 = self.env().with_ctes(ins.ctes)
  let (target, view) = self.resolve_named_target(
    env0,
    ins.target,
    [],
    PInsert(ins.columns.map(c => c.name.to_lower())),
  )
  if target.scope != 3 {
    self.check_writable()
  }
  let t = target.table
  check_vector_dml(t)
  let identity_insert = self.identity_insert == Some(t.id)
  let outputs = self.bind_output(ins.output, target, view, false, true, [])
  // target columns
  let cols : Array[Int] = match view {
    Some(v) => {
      let names = if ins.columns.is_empty() {
        v.result.map(c => c.name.to_lower())
      } else {
        ins.columns.map(c => c.name.to_lower())
      }
      names.map(nm => {
        match v.result.search_by(c => c.name.to_lower() == nm) {
          Some(i) =>
            match v.base_of[i] {
              Some(b) => b
              None => raise view_error(KView(check=false), 4406, v.name)
            }
          None => raise @types.sql_error(207, "Invalid column name '\{nm}'.")
        }
      })
    }
    None =>
      if ins.columns.is_empty() {
        // without a column list the identity column is never a target,
        // even under IDENTITY_INSERT ON (a value for it is 8101)
        let out = []
        for i, c in t.columns {
          // captured: the timestamp column is a target of an INSERT
          // without a column list (DEFAULT or NULL for it; msduck
          // gaps-rowversion_identity #022/#025)
          if c.identity is None && c.computed is None {
            out.push(i)
          }
        }
        out
      } else {
        let out = []
        for c in ins.columns {
          match t.column_index(c.name) {
            Some(i) => {
              if out.contains(i) {
                raise @types.sql_error(
                  264,
                  "The column name '\{t.columns[i].name}' is specified more than once in the SET clause or column list of an INSERT. A column cannot be assigned more than one value in the same clause. Modify the clause to make sure that a column is updated only once. If this statement updates or inserts columns into a view, column aliasing can conceal the duplication in your code.",
                )
              }
              out.push(i)
            }
            None =>
              raise @types.sql_error(207, "Invalid column name '\{c.name}'.")
          }
        }
        out
      }
  }
  // a value for the identity column without a column list (compile time,
  // captured: msduck identity-insert-shapes)
  let has_identity = t.columns.iter().any(c => c.identity is Some(_))
  // the table name as written (captured: 'dbo.alpha', 't')
  let written = match ins.target.kind {
    Table(name, ..) => object_text(name)
    _ => target.display
  }
  let identity_8101 = () => {
    @types.sql_error(
      8101,
      "An explicit value for the identity column in table '\{written}' can only be specified when a column list is used and IDENTITY_INSERT is ON.",
    )
  }
  // IDENTITY_INSERT errors are raised when the statement starts executing
  // (DONE CurCmd 195, before the source is evaluated): 544 for an explicit
  // value while OFF, 545 for a missing one while ON
  let mut identity_error : @types.SqlError? = None
  for i in cols {
    let c = t.columns[i]
    if c.identity is Some(_) && !identity_insert && identity_error is None {
      identity_error = Some(
        @types.sql_error(
          544,
          "Cannot insert explicit value for identity column in table '\{t.name}' when IDENTITY_INSERT is set to OFF.",
        ),
      )
    }
    if c.computed is Some(_) {
      raise @types.sql_error(
        271,
        "The column \"\{c.name}\" cannot be modified because it is either a computed column or is the result of a UNION operator.",
      )
    }
  }
  if identity_insert &&
    view is None &&
    identity_error is None &&
    !cols.iter().any(i => t.columns[i].identity is Some(_)) {
    identity_error = Some(
      @types.sql_error(
        545,
        "Explicit value must be specified for identity column in table '\{t.name}' either when IDENTITY_INSERT is set to ON or when a replication user is inserting into a NOT FOR REPLICATION identity column.",
      ),
    )
  }
  let start_rows = () => {
    self.cur_cmd = 195
    match identity_error {
      Some(e) if !self.compile_only => raise e
      _ => ()
    }
  }
  let identity_pos = cols.search_by(i => t.columns[i].identity is Some(_))
  let mut sent = false
  // source rows with their types
  let env = match ins.source {
    InsertValues(rows) => {
      let all = []
      for r in rows {
        all.append(r)
      }
      self.simple_params_env(env0, target, all)
    }
    InsertQuery(q) =>
      match simple_select_exprs(q) {
        Some(xs) => self.simple_params_env(env0, target, xs)
        None => env0
      }
    _ => env0
  }
  let (source, types) : (Array[Array[@types.Value]], Array[@types.SqlType]) = match
    ins.source {
    InsertValues(rows) => {
      let bound = rows.map(r => {
        r.map(e => {
          if e.kind is Default {
            None
          } else {
            Some(@bind.bind_expr(env, e))
          }
        })
      })
      for r in bound {
        if r.length() != cols.length() {
          if ins.columns.is_empty() &&
            view is None &&
            has_identity &&
            r.length() == cols.length() + 1 {
            raise identity_8101()
          }
          if ins.columns.is_empty() {
            raise @types.sql_error(
              213, "Column name or number of supplied values does not match table definition.",
            )
          } else if r.length() > cols.length() {
            raise @types.sql_error(
              110,
              "There are more columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
              severity=15,
            )
          } else {
            raise @types.sql_error(
              109,
              "There are more columns in the INSERT statement than values specified in the VALUES clause. The number of values in the VALUES clause must match the number of columns specified in the INSERT statement.",
              severity=15,
            )
          }
        }
      }
      // a column given only untyped NULLs takes any type
      let all_null = (j : Int) => {
        bound
        .iter()
        .all(r => {
          match r.get(j) {
            Some(Some(b)) => b.kind is Lit(Null) && b.ty is Int
            _ => true
          }
        })
      }
      let bound = unify_values_rows(bound)
      // assignment type rules are compile-time (DONE cmd 253, captured)
      if bound.length() > 0 {
        for j, e in bound[0] {
          if j < cols.length() && e is Some(b) && !all_null(j) {
            @types.check_store(b.ty, t.columns[cols[j]].ty)
          }
        }
      }
      // DEFAULT or a NULL literal for the identity column is a compile-time
      // error (captured: msduck identity-insert-conversion, CurCmd 253)
      match identity_pos {
        Some(j) if identity_insert =>
          for r in bound {
            match r[j] {
              None | Some({ kind: Lit(Null), .. }) =>
                raise @types.sql_error(
                  339, "DEFAULT or NULL are not allowed as explicit identity values.",
                )
              _ => ()
            }
          }
        _ => ()
      }
      for r in bound {
        for j, e in r {
          if j < cols.length() &&
            t.columns[cols[j]].ty is RowVersion &&
            !(e is (None | Some({ kind: Lit(Null), .. }))) {
            raise timestamp_insert_error()
          }
        }
      }
      start_rows()
      sent = self.output_header(outputs)
      let ctx = self.ctx()
      let types = []
      let values = []
      for r in bound {
        self.rt.next_row()
        let row = []
        let tys = []
        // under IDENTITY_INSERT the explicit identity value counts even
        // when another column of the row then fails (captured: msduck
        // identity-insert-errors, IDENT_CURRENT 400 after a 245 on v)
        let early = match identity_pos {
          Some(j) if identity_insert && r[j] is Some(b) => {
            let v = @exec.eval(ctx, b)
            let cv = self.to_column(target, t.columns[cols[j]], v, b.ty)
            match identity_int64(cv) {
              Some(n) => self.bump_identity(target.scope, t, n)
              None => ()
            }
            Some((j, v))
          }
          _ => None
        }
        for k, e in r {
          if early is Some((j, v)) && j == k {
            row.push(v)
            tys.push(e.map(b => b.ty).unwrap_or(@types.SqlType::Int))
            continue
          }
          match e {
            Some(b) => {
              row.push(@exec.eval(ctx, b))
              tys.push(b.ty)
            }
            None => {
              row.push(@types.Value::Null)
              tys.push(@types.SqlType::Int) // marker: DEFAULT
            }
          }
        }
        values.push(row)
        if types.is_empty() {
          types.append(tys)
        }
      }
      // DEFAULT markers: re-evaluate below
      (
        values,
        if types.is_empty() {
          cols.map(_ => @types.SqlType::Int)
        } else {
          types
        },
      )
    }
    InsertQuery(q) => {
      let bq = @bind.bind_query(env, q, result_columns=false)
      if ins.columns.is_empty() &&
        view is None &&
        has_identity &&
        bq.columns.length() == cols.length() + 1 {
        raise identity_8101()
      }
      if bq.columns.length() != cols.length() {
        raise @types.sql_error(
          120,
          "The select list for the INSERT statement contains fewer items than the insert list. The number of SELECT values must match the number of INSERT columns.",
          severity=15,
        )
      }
      for j, c in bq.columns {
        // an untyped NULL column (also through derived tables, VALUES and
        // set operations) takes any type (captured: query/derived-untyped-null)
        let untyped = @bind.untyped_null_column(bq.plan, j)
        if t.columns[cols[j]].ty is RowVersion {
          if !untyped {
            raise timestamp_insert_error()
          }
          continue
        }
        if !untyped {
          @types.check_store(c.ty, t.columns[cols[j]].ty)
        }
      }
      start_rows()
      sent = self.output_header(outputs)
      (@exec.run(self.ctx(), bq.plan), bq.columns.map(c => c.ty))
    }
    DefaultValues => {
      start_rows()
      sent = self.output_header(outputs)
      ([[]], [])
    }
    InsertExec(_) => raise @types.not_supported("INSERT ... EXEC")
  }
  let default_marks = match ins.source {
    InsertValues(rows) => rows.map(r => r.map(e => e.kind is Default))
    _ => []
  }
  // assignment type rules before any row (captured: 206/257 for
  // sql_variant columns are compile-time errors)
  for j, ci in cols {
    let untyped_json_null = t.columns[ci].ty is Json &&
      (match ins.source {
        InsertValues(rows) =>
          rows.all(r => {
            r
            .get(j)
            .map(e => @bind.is_null_argument(e) || e.kind is Default)
            .unwrap_or(false)
          })
        _ => false
      })
    if j < types.length() &&
      !untyped_json_null &&
      !(t.columns[ci].ty is RowVersion) &&
      !default_marks.iter().all(m => j < m.length() && m[j]) {
      @types.check_assign(types[j], t.columns[ci].ty)
    }
  }
  let mut db = self.db_of(target.scope)
  let pre = db
  let instead = self.instead_of_trigger(target, OnInsert)
  let mut last_identity : Int64? = None
  let inserted_rows = []
  let evaluated = []
  let mut dup_ignored = false
  // many rows are checked against the starting state plus a pending set
  // and written at the end, unless a later row's checks could read an
  // earlier row of this statement (self-references, IGNORE_DUP_KEY)
  let pending = PendingInserts::new(t)
  let mut buffered = source.length() >= 64 &&
    instead.is_empty() &&
    !t.foreign_keys.iter().any(fk => fk.ref_table == t.id) &&
    !t.indexes.iter().any(ix => ix.unique && ix.ignore_dup_key)
  let row_lock = row_lock(t)
  for ri, src in source {
    self.rt.next_row()
    let row = Array::make(t.columns.length(), @types.Value::Null)
    let step = () => {
      errdefer self.output_send(outputs, evaluated[:])
      let given = Array::make(t.columns.length(), false)
      for j, ci in cols {
        if j < src.length() {
          let is_default = ri < default_marks.length() && default_marks[ri][j]
          // captured: msduck identity-insert-conversion (339)
          if t.columns[ci].identity is Some(_) && (is_default || src[j] is Null) {
            raise @types.sql_error(
              339, "DEFAULT or NULL are not allowed as explicit identity values.",
            )
          }
          if !is_default && !(t.columns[ci].ty is RowVersion) {
            row[ci] = self.to_column(target, t.columns[ci], src[j], types[j])
            given[ci] = true
          }
        }
      }
      for i, c in t.columns {
        if given[i] {
          continue
        }
        match (c.identity, c.default_) {
          // an INSTEAD OF INSERT trigger sees 0 for the identity column
          // and consumes no value (captured: gaps-triggers #045)
          (Some(_), _) if !instead.is_empty() =>
            row[i] = identity_value(c.ty, 0L)
          (Some(id), _) if !(identity_insert && given[i]) => {
            let v = self.peek_identity(target.scope, t, id)
            if !identity_fits(c.ty, v) {
              raise self.identity_overflow(c.ty)
            }
            ignore(self.next_identity(target.scope, t, id))
            row[i] = identity_value(c.ty, v)
            last_identity = Some(v)
          }
          (_, Some(d)) if c.computed is None =>
            row[i] = self.eval_default(target, c, d, row)
          _ => ()
        }
        if c.ty is RowVersion {
          row[i] = self.next_rowversion()
        }
      }
      for i, c in t.columns {
        if c.computed is Some(expr) {
          row[i] = self.eval_text(target, expr, row, c.ty)
        }
      }
      if identity_insert {
        for i, c in t.columns {
          if c.identity is Some(_) && given[i] {
            match identity_int64(row[i]) {
              Some(v) => {
                self.bump_identity(target.scope, t, v)
                last_identity = Some(v)
              }
              None => ()
            }
          }
        }
      }
      if !instead.is_empty() {
        // INSTEAD OF: the trigger sees the rows; constraints are not checked
        inserted_rows.push(row)
        return
      }
      self.check_row(target, db, row, "INSERT")
      let image = match view {
        Some(v) => {
          let leaf = self.view_row_of(v, None, row)
          self.view_check(v, leaf)
          leaf[0:v.leaf.visible].to_owned()
        }
        None => row
      }
      if dup_key_ignored(t, db, row) {
        dup_ignored = true
        return
      }
      let rowid = self.server.rowid()
      if is_db_scope(target.scope) {
        // X on the new key: waits for another transaction's uncommitted
        // insert of the same key, or a range lock covering it
        self.acquire(row_lock.resource(rowid, row), X, Transaction)
      }
      if buffered && !pending.add(target, db, rowid, row) {
        db = pending.flush(db, t.id)
        buffered = false
      }
      if !buffered {
        db = insert_checked(target, db, rowid, row)
      }
      evaluated.push(self.output_eval(outputs, image))
      inserted_rows.push(row)
    }
    step()
  }
  db = pending.flush(db, t.id)
  let all_columns = Array::makei(t.columns.length(), i => i)
  if !instead.is_empty() {
    self.run_triggers(target, instead, [], inserted_rows, all_columns, pre)
    let count = source.length().to_int64()
    self.rt.rowcount = count
    self.done(195, count=Some(count))
    return
  }
  self.write(target.scope, db)
  self.output_finish(outputs, evaluated)
  if last_identity is Some(v) {
    let iv : @types.Value = Decimal(@types.Decimal::from_int64(v))
    self.rt.identity = iv
    self.rt.scope_identity = iv
  } else if !has_identity {
    // captured: an INSERT into a table without an identity column (even
    // of no rows, also a table variable) makes SCOPE_IDENTITY() and
    // @@IDENTITY NULL (msduck gaps-rowversion_identity #125/#137)
    self.rt.identity = Null
    self.rt.scope_identity = Null
  }
  if dup_ignored {
    self.info(3604, 0, "Duplicate key was ignored.", self.stmt_line)
  }
  self.fire_after(target, OnInsert, [], inserted_rows, all_columns, pre)
  let count = inserted_rows.length().to_int64()
  self.rt.rowcount = count
  self.done(195, count=Some(count), result_set=sent)
}

///|
/// Columns an UPDATE changes: its SET columns plus the computed columns
/// over them (a CHECK on a computed column is checked when a column it
/// uses is set, captured: ck_t over `s AS a + b`).
fn touched_columns(t : @store.Table, set : Array[Int]) -> Array[Int] {
  let out = set.copy()
  for i, c in t.columns {
    match c.computed {
      Some(expr) if !out.contains(i) &&
        set.iter().any(j => expr_mentions(expr, t.columns[j].name.to_lower())) =>
        out.push(i)
      _ => ()
    }
  }
  out
}

///|
/// An explicit identity value (IDENTITY_INSERT ON) moves the table's
/// identity forward when it lies beyond the current value in the
/// increment's direction.
fn Session::bump_identity(
  self : Session,
  scope : Int,
  t : @store.Table,
  v : Int64,
) -> Unit {
  let increment = match
    t.columns.iter().find_first(c => c.identity is Some(_)) {
    Some({ identity: Some(id), .. }) => id.increment
    _ => 1L
  }
  let key = self.ident_key(scope, t)
  match self.server.idents.get(key) {
    None => self.server.idents[key] = v
    Some(cur) =>
      if (increment >= 0L && v > cur) || (increment < 0L && v < cur) {
        self.server.idents[key] = v
      }
  }
}

///|
/// 273 (compile time): an INSERT value for a timestamp column other than
/// DEFAULT or a NULL literal (captured: msduck gaps-rowversion_identity
/// #019/#024/#026).
fn timestamp_insert_error() -> @types.SqlError {
  @types.sql_error(
    273, "Cannot insert an explicit value into a timestamp column. Use INSERT with a column list to exclude the timestamp column, or insert a DEFAULT into the timestamp column.",
  )
}
