///|
pub type Row = Array[@types.Value]

///|
/// Executes a plan to completion. CI-sized data makes materialization fine;
/// the statement-restart model (decisions.md) needs no suspension inside.
pub fn run(ctx : Ctx, plan : @ir.Plan) -> Array[Row] raise @types.SqlError {
  match plan {
    OneRow => [[]]
    Scan(scope~, id~, rowid~) =>
      (ctx.source)(scope, id).map(kv => {
        if rowid {
          let r = kv.1.copy()
          r.push(BigInt(kv.0))
          r
        } else {
          kv.1
        }
      })
    Join(kind, left, right, on, left_width~, right_width~) => {
      let ls = run(ctx, left)
      let rs = run(ctx, right)
      let out = []
      let right_matched = Array::make(rs.length(), false)
      for l in ls {
        let mut matched = false
        for j, r in rs {
          let row = l + r
          let ok = match on {
            Some(p) => is_true(eval(ctx.with_row(row), p))
            None => true
          }
          if ok {
            matched = true
            right_matched[j] = true
            out.push(row)
          }
        }
        if !matched && kind is (Left | Full) {
          out.push(l + Array::make(right_width, @types.Value::Null))
        }
      }
      if kind is (Right | Full) {
        for j, r in rs {
          if !right_matched[j] {
            out.push(Array::make(left_width, @types.Value::Null) + r)
          }
        }
      }
      out
    }
    Values(rows) => rows.map(r => r.map(e => eval(ctx, e)))
    Project(input, exprs) =>
      run(ctx, input).map(row => {
        let c = ctx.with_row(row)
        exprs.map(e => eval(c, e))
      })
    Filter(Scan(scope~, id~, rowid~), pred) if seek_rows(
        ctx, scope, id, rowid, pred,
      )
      is Some(rows) => rows
    Filter(input, pred) => {
      let out = []
      for row in run(ctx, input) {
        if is_true(eval(ctx.with_row(row), pred)) {
          out.push(row)
        }
      }
      out
    }
    Sort(input, keys) => {
      let rows = run(ctx, input)
      let keyed = rows.map(row => {
        (keys.map(k => eval(ctx.with_row(row), k.expr)), row)
      })
      let mut failure : @types.SqlError? = None
      keyed.sort_by((a, b) => {
        for i, k in keys {
          let c = compare_for_sort(a.0[i], b.0[i], k.collation) catch {
            e => {
              failure = Some(e)
              0
            }
          }
          if c != 0 {
            return if k.desc { -c } else { c }
          }
        }
        0
      })
      if failure is Some(e) {
        raise e
      }
      keyed.map(kv => kv.1)
    }
    Limit(input, offset, count) => {
      let rows = run(ctx, input)
      let off = match offset {
        Some(o) => eval(ctx, o).as_int64().unwrap_or(0L).to_int()
        None => 0
      }
      let cnt = match count {
        Some(c) => eval(ctx, c).as_int64().unwrap_or(0L).to_int()
        None => rows.length()
      }
      if off < 0 {
        raise @types.sql_error(
          10742, "The offset specified in a OFFSET clause may not be negative.",
        )
      }
      let start = @cmp.minimum(off, rows.length())
      let end = @cmp.minimum(start + @cmp.maximum(cnt, 0), rows.length())
      rows[start:end].to_owned()
    }
    Distinct(input, collations) => {
      let out : Array[Row] = []
      for row in run(ctx, input) {
        let mut dup = false
        for seen in out {
          if same_row(seen, row, collations) {
            prefer_representative(seen, row)
            dup = true
            break
          }
        }
        if !dup {
          out.push(row.copy())
        }
      }
      out
    }
    UnionAll(parts) => {
      let out = []
      for p in parts {
        out.append(run(ctx, p))
      }
      out
    }
    Aggregate(input, keys, aggs, sets~) =>
      run_aggregate(ctx, run(ctx, input), keys, aggs, sets)
    Window(input, calls) => run_window(ctx, run(ctx, input), calls)
    Apply(left, right, outer~, right_width~) => {
      let out = []
      for l in run(ctx, left) {
        let rs = run(ctx.push_outer(l), right)
        if rs.is_empty() {
          if outer {
            out.push(l + Array::make(right_width, @types.Value::Null))
          }
        } else {
          for r in rs {
            out.push(l + r)
          }
        }
      }
      out
    }
    SetOp(kind, left, right, collations) => {
      let ls = run(ctx, left)
      let rs = run(ctx, right)
      let out : Array[Row] = []
      let contains = (rows : Array[Row], row : Row) => {
        for x in rows {
          if same_row(x, row, collations) {
            return true
          }
        }
        false
      }
      let add = (row : Row) => {
        for x in out {
          if same_row(x, row, collations) {
            prefer_representative(x, row)
            return
          }
        }
        out.push(row.copy())
      }
      match kind {
        Union => {
          for r in ls {
            add(r)
          }
          for r in rs {
            add(r)
          }
        }
        Except =>
          for r in ls {
            if !contains(rs, r) {
              add(r)
            }
          }
        Intersect =>
          for r in ls {
            if contains(rs, r) {
              add(r)
            }
          }
      }
      out
    }
    Top(input, count, percent~, ties~) => {
      let rows = run(ctx, input)
      top_rows(ctx, rows, count, percent, ties)
    }
    Recursive(id~, anchor, recursive, max~) => {
      let out = []
      run_recursive(ctx, id, anchor, recursive, max, r => out.push(r))
      out
    }
    WorkTable(id) => ctx.rt.work.get(id).unwrap_or([])
    TableFunc(f, args) => run_table_fn(ctx, f, args)
    WithParams(args, inner) => run(params_ctx(ctx, args), inner)
    UserTable(id, args) => (ctx.user_table)(id, args.map(a => eval(ctx, a)))
    ForJson(input, columns, root~, include_nulls~, without_array_wrapper~) => {
      let rows = run(ctx, input)
      // captured: the DONE count is the number of input rows
      ctx.rt.count_override = Some(rows.length().to_int64())
      run_for_json(rows, columns, root, include_nulls, without_array_wrapper)
    }
  }
}

///|
/// Context of an inline table-valued function's query: its parameters are
/// the variable slots; the caller's rows are not visible.
fn params_ctx(ctx : Ctx, args : Array[@ir.Expr]) -> Ctx raise @types.SqlError {
  let vars = args.map(a => eval(ctx, a))
  { ..ctx, vars, row: [], outer: [], }
}

///|
/// Context for running a subquery or APPLY right side: `row` becomes the
/// innermost outer row (bind/env.mbt depth numbering).
pub fn Ctx::push_outer(self : Ctx, row : Row) -> Ctx {
  { ..self, outer: self.outer + [row], row: [], }
}

///|
fn top_rows(
  ctx : Ctx,
  rows : Array[Row],
  count : @ir.Expr,
  percent : Bool,
  ties : Array[@ir.SortKey],
) -> Array[Row] raise @types.SqlError {
  let n = if percent {
    let p = match @types.cast(eval(ctx, count), count.ty, Float) {
      Float(f) => f
      _ => 0.0
    }
    if p < 0.0 || p > 100.0 {
      raise @types.sql_error(1031, "Percent values must be between 0 and 100.")
    }
    (p * rows.length().to_double() / 100.0).ceil().to_int()
  } else {
    match eval(ctx, count).as_int64() {
      Some(c) if c >= 0L =>
        if c > rows.length().to_int64() {
          rows.length()
        } else {
          c.to_int()
        }
      Some(_) =>
        raise @types.sql_error(
          1014, "A TOP or FETCH clause contains an invalid value.",
        )
      None => 0
    }
  }
  let mut end = if n > rows.length() { rows.length() } else { n }
  if !ties.is_empty() && end > 0 {
    let last = ties.map(k => eval(ctx.with_row(rows[end - 1]), k.expr))
    while end < rows.length() {
      let next = ties.map(k => eval(ctx.with_row(rows[end]), k.expr))
      if compare_keys(last, next, ties) != 0 {
        break
      }
      end += 1
    }
  }
  rows[0:end].to_owned()
}

///|
/// Recursive CTE: anchor rows, then each level's rows feed the next level
/// through work table `id`. Rows are emitted as produced (SQL Server streams
/// them before raising 530).
fn run_recursive(
  ctx : Ctx,
  id : Int,
  anchor : @ir.Plan,
  recursive : @ir.Plan,
  max : Int,
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  let saved = ctx.rt.work.get(id)
  let mut level = run(ctx, anchor)
  for r in level {
    emit(r)
  }
  let mut depth = 0
  while !level.is_empty() {
    ctx.rt.work.set(id, level)
    let next = run(ctx, recursive)
    if next.is_empty() {
      break
    }
    depth += 1
    if max > 0 && depth > max {
      match saved {
        Some(w) => ctx.rt.work.set(id, w)
        None => ctx.rt.work.remove(id)
      }
      raise @types.sql_error(
        530,
        "The statement terminated. The maximum recursion \{max} has been exhausted before statement completion.",
      )
    }
    for r in next {
      emit(r)
    }
    level = next
  }
  match saved {
    Some(w) => ctx.rt.work.set(id, w)
    None => ctx.rt.work.remove(id)
  }
}

///|
/// Runs a plan, handing rows to `emit` as soon as the plan's pipelined
/// shape allows (projection, filter, union all, recursive CTE, scans). Rows
/// emitted before a run-time error stay emitted, like SQL Server's streaming
/// result sets (captured: 530 after 101 rows, 245 in OPENJSON WITH after 1).
pub fn stream(
  ctx : Ctx,
  plan : @ir.Plan,
  emit : (Row) -> Unit raise @types.SqlError,
) -> Unit raise @types.SqlError {
  match plan {
    Project(input, exprs) =>
      stream(ctx, input, row => {
        let c = ctx.with_row(row)
        emit(exprs.map(e => eval(c, e)))
      })
    Filter(Scan(scope~, id~, rowid~), pred) if seek_rows(
        ctx, scope, id, rowid, pred,
      )
      is Some(rows) =>
      for row in rows {
        emit(row)
      }
    Filter(input, pred) =>
      stream(ctx, input, row => {
        if is_true(eval(ctx.with_row(row), pred)) {
          emit(row)
        }
      })
    UnionAll(parts) =>
      for p in parts {
        stream(ctx, p, emit)
      }
    Recursive(id~, anchor, recursive, max~) =>
      run_recursive(ctx, id, anchor, recursive, max, emit)
    Values(rows) =>
      for r in rows {
        emit(r.map(e => eval(ctx, e)))
      }
    TableFunc(f, args) => stream_table_fn(ctx, f, args, emit)
    WithParams(args, inner) => stream(params_ctx(ctx, args), inner, emit)
    Apply(left, right, outer~, right_width~) =>
      stream(ctx, left, l => {
        let rs = run(ctx.push_outer(l), right)
        if rs.is_empty() {
          if outer {
            emit(l + Array::make(right_width, @types.Value::Null))
          }
        } else {
          for r in rs {
            emit(l + r)
          }
        }
      })
    _ =>
      for r in run(ctx, plan) {
        emit(r)
      }
  }
}

///|
/// ORDER BY comparison: NULLs sort first ascending.
fn compare_for_sort(
  a : @types.Value,
  b : @types.Value,
  collation : @types.Collation?,
) -> Int raise @types.SqlError {
  match (a, b) {
    (Null, Null) => 0
    (Null, _) => -1
    (_, Null) => 1
    _ => @types.compare(a, b, collation?).unwrap_or(0)
  }
}

///|
/// DISTINCT / GROUP BY equality: NULLs are equal to each other.
fn same_row(
  a : Row,
  b : Row,
  collations : Array[@types.Collation?],
) -> Bool raise @types.SqlError {
  for i in 0..<a.length() {
    match (a[i], b[i]) {
      (Null, Null) => continue
      (Null, _) | (_, Null) => return false
      _ =>
        if @types.compare(a[i], b[i], collation?=collations[i]) != Some(0) {
          return false
        }
    }
  }
  true
}

///|
/// A key value that does not depend on the current row and cannot fail or
/// vary per row: a literal, variable/parameter or outer column. (Casts and
/// arithmetic could raise where a scan of an empty table never evaluates
/// them.)
fn row_free(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(_) | Var(_) | OuterCol(_, _) => true
    Collate(a) => row_free(a)
    _ => false
  }
}

///|
/// `Filter(Scan)` through a unique index: when the predicate's conjuncts
/// pin all columns of a unique index with `column = value` of the column's
/// own type and collation, the session looks the key up instead of the scan
/// reading every row. The full predicate is applied to the result, so the
/// rows are exactly those of the scan (a unique key matches at most one).
/// None: no index applies; scan.
fn seek_rows(
  ctx : Ctx,
  scope : Int,
  id : Int,
  rowid : Bool,
  pred : @ir.Expr,
) -> Array[Row]? raise @types.SqlError {
  let conj = []
  fn split(e : @ir.Expr) -> Unit {
    match e.kind {
      And(a, b) => {
        split(a)
        split(b)
      }
      _ => conj.push(e)
    }
  }

  split(pred)
  let key : Array[(Int, @types.Value)] = []
  for e in conj {
    guard e.kind is Cmp(Eq, a, b, coll) else { continue }
    let pinned = match (a.kind, b.kind) {
      (Col(i), _) if row_free(b) => Some((i, a, b))
      (_, Col(i)) if row_free(a) => Some((i, b, a))
      _ => None
    }
    guard pinned is Some((i, col, value)) else { continue }
    if col.ty != value.ty {
      continue
    }
    match coll {
      Some(c) if col.ty.collation() != Some(c) => continue
      _ => ()
    }
    if key.iter().any(k => k.0 == i) {
      continue
    }
    let v = eval(ctx, value)
    if v is Null {
      // `column = NULL` is never true
      return Some([])
    }
    key.push((i, v))
  }
  if key.is_empty() {
    return None
  }
  guard (ctx.seek)(scope, id, key) is Some(found) else { return None }
  let out = []
  for kv in found {
    let row = if rowid {
      let r = kv.1.copy()
      r.push(BigInt(kv.0))
      r
    } else {
      kv.1
    }
    if is_true(eval(ctx.with_row(row), pred)) {
      out.push(row)
    }
  }
  Some(out)
}
