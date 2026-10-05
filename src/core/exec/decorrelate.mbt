// Unnesting of correlated subqueries whose correlation is an integer
// equality `inner column = outer column` (EXISTS, scalar and IN subqueries
// of the ORM "children of this row" kind).
//
// Re-running such a subquery per outer row costs a lookup per row at best.
// Following Neumann & Kemper, "Unnesting Arbitrary Queries" (BTW 2015), the
// part below the correlated predicate (the Filter's uncorrelated input) is
// evaluated once and partitioned on the inner key, which turns the
// dependent join into a hash join; the operators above the Filter (Project,
// Aggregate, TOP, ORDER BY, ...) then run per outer row over just its
// bucket, which is Galindo-Legaria & Joshi's (SIGMOD 2001) Apply with the
// selection pushed into a keyed lookup. When the subquery reads no other
// outer column, the result is a function of the key value alone and is
// kept per key (Neumann's "magic set" domain: each distinct outer key value
// is evaluated once).
//
// Faithfulness: the bucket rows come in input order and the whole
// predicate is re-applied to them unless it is just the key conjunct, so
// the rows the upper operators see are exactly the Filter's; the upper
// operators are the original ones, run per outer row in the same order, so
// errors (512, overflows, conversions) surface at the same outer row. As
// with index seeks (decisions.md), predicate conjuncts are evaluated on
// candidate rows only. Only integer keys are partitioned (hash equality is
// numeric equality there; strings need collation-aware keys and keep the
// sorted lookup cache of memo.mbt). Results are kept only while the tables
// and variables the subquery reads are unchanged, and the input's and each
// run's side effects on the runtime (8153 flag, row counter) are replayed.

///|
/// The result of one per-key run, replayed for later outer rows with the
/// same key value.
priv struct KeyResult {
  rows : Array[Row]
  null_eliminated : Bool
  row_seq : Int64
}

///|
priv struct Decor {
  /// the subquery plan with the Filter replaced by `WorkTable(work_id)`
  upper : @ir.Plan
  work_id : Int
  /// the Filter's uncorrelated input and predicate
  input : @ir.Plan
  pred : @ir.Expr
  /// the predicate is exactly the key conjunct (no re-check needed)
  exact : Bool
  /// input column and outer-row column of the key conjunct
  inner_col : Int
  outer_col : Int
  /// the subquery reads no outer column but the key: results per key
  /// (switched off when keys do not repeat)
  mut per_key : Bool
  mut key_hits : Int
  mut key_misses : Int
  /// the operators above the Filter turn no input rows into no rows
  /// without evaluating anything (Project, Sort, DISTINCT)
  empty_on_empty : Bool
  /// tables and variables the whole subquery reads
  deps : Deps
  mut stamps : Array[Int64]
  mut var_values : Array[@types.Value]
  /// input rows and their partition (`build_partition`; None until built)
  mut rows : Array[Row]
  mut heads : IntTable?
  mut next : FixedArray[Int]
  mut input_null_eliminated : Bool
  mut input_row_seq : Int64
  results : Map[Int64, KeyResult]
  mut null_result : KeyResult?
}

///|
/// Work table ids of unnested subqueries: negative, never a plan id.
let decor_work_base = -1000

///|
/// Tables, variables and outer-row columns a subquery reads, when it reads
/// no session state, no randomness and no row further out than its own
/// outer row.
fn plan_correlation(plan : @ir.Plan) -> (Deps, Array[Int])? {
  let w : DepsWalk = {
    tables: [],
    vars: [],
    work_tables: [],
    ok: true,
    outer_cols: [],
    correlated: true,
  }
  w.plan(plan, 0, true)
  if w.ok {
    Some(({ tables: w.tables, vars: w.vars, }, w.outer_cols))
  } else {
    None
  }
}

///|
/// Top-level AND conjuncts of a predicate.
fn conjuncts(e : @ir.Expr, out : Array[@ir.Expr]) -> Unit {
  match e.kind {
    And(a, b) => {
      conjuncts(a, out)
      conjuncts(b, out)
    }
    _ => out.push(e)
  }
}

///|
/// `inner column = outer column` with both sides integers (bit excluded:
/// `=` against an integer converts the bit side): (input column, outer
/// expression).
fn int_key(e : @ir.Expr) -> (Int, @ir.Expr)? {
  guard e.kind is Cmp(Eq, a, b, _) else { return None }
  guard a.ty.family() == FInteger && b.ty.family() == FInteger else {
    return None
  }
  match (a.kind, b.kind) {
    (Col(i), OuterCol(1, _)) => Some((i, b))
    (OuterCol(1, _), Col(i)) => Some((i, a))
    _ => None
  }
}

///|
/// Splits `plan` at the topmost Filter whose input is uncorrelated and
/// whose predicate has an integer key conjunct, below unary operators only
/// (each runs its input once per subquery run): (plan with the Filter
/// replaced by `WorkTable(wid)`, Filter input, predicate, key).
fn split_filter(
  plan : @ir.Plan,
  wid : Int,
) -> (@ir.Plan, @ir.Plan, @ir.Expr, Array[@ir.Expr], (Int, @ir.Expr))? {
  let under = (input : @ir.Plan, wrap : (@ir.Plan) -> @ir.Plan) => {
    match split_filter(input, wid) {
      Some((p, i, e, cs, k)) => Some((wrap(p), i, e, cs, k))
      None => None
    }
  }
  match plan {
    Filter(input, pred) => {
      let cs = []
      conjuncts(pred, cs)
      let key = for c in cs {
        if int_key(c) is Some(k) {
          break Some(k)
        }
      } nobreak {
        None
      }
      match key {
        Some(k) if plan_deps(input) is Some(_) =>
          Some((@ir.Plan::WorkTable(wid), input, pred, cs, k))
        _ => under(input, p => Filter(p, pred))
      }
    }
    Project(input, es) => under(input, p => Project(p, es))
    Aggregate(input, ks, aggs, sets~) =>
      under(input, p => Aggregate(p, ks, aggs, sets~))
    Sort(input, ks) => under(input, p => Sort(p, ks))
    Limit(input, o, c) => under(input, p => Limit(p, o, c))
    Top(input, n, percent~, ties~) =>
      under(input, p => Top(p, n, percent~, ties~))
    Distinct(input, colls) => under(input, p => Distinct(p, colls))
    NoNullWarning(input) => under(input, p => NoNullWarning(p))
    Window(input, calls) => under(input, p => Window(p, calls))
    _ => None
  }
}

///|
fn empty_on_empty(plan : @ir.Plan) -> Bool {
  match plan {
    WorkTable(_) => true
    Project(input, _)
    | Sort(input, _)
    | Distinct(input, _)
    | NoNullWarning(input) => empty_on_empty(input)
    _ => false
  }
}

///|
fn analyze_decor(plan : @ir.Plan, wid : Int) -> Decor? {
  guard plan_correlation(plan) is Some((deps, outer_cols)) else { return None }
  guard split_filter(plan, wid)
    is Some((upper, input, pred, cs, (inner_col, outer_key))) else {
    return None
  }
  guard outer_key.kind is OuterCol(_, outer_col) else { return None }
  Some({
    upper,
    work_id: wid,
    input,
    pred,
    exact: cs.length() == 1,
    inner_col,
    outer_col,
    per_key: outer_cols.iter().all(c => c == outer_col),
    key_hits: 0,
    key_misses: 0,
    empty_on_empty: empty_on_empty(upper),
    deps,
    stamps: [],
    var_values: [],
    rows: [],
    heads: None,
    next: FixedArray::make(0, -1),
    input_null_eliminated: false,
    input_row_seq: 0L,
    results: Map([]),
    null_result: None,
  })
}

///|
/// Rows of the correlated subquery of `entry` for the current outer row
/// through its unnested form; None when it has none and the caller runs
/// the plan directly. The partition is built on the first run (it costs
/// about one scan of the input, like the direct run).
fn decorrelated_rows(
  ctx : Ctx,
  entry : SubqueryMemo,
) -> Array[Row]? raise @types.SqlError {
  let decor = match entry.decor {
    Some(d) => d
    None => {
      let memo = ctx.rt.memo
      let d = analyze_decor(entry.plan, decor_work_base - memo.decor_ids)
      memo.decor_ids += 1
      entry.decor = Some(d)
      d
    }
  }
  guard decor is Some(d) else { return None }
  // unchanged tables and variables (checked without allocating)
  let mut same = d.stamps.length() == d.deps.tables.length() &&
    d.var_values.length() == d.deps.vars.length()
  for i, t in d.deps.tables {
    match (ctx.stamp)(t.0, t.1) {
      Some(s) => if same && d.stamps[i] != s { same = false }
      None => return None
    }
  }
  for i, slot in d.deps.vars {
    match ctx.vars.get(slot) {
      Some(v) => if same && d.var_values[i] != v { same = false }
      None => return None
    }
  }
  if !same {
    d.stamps = d.deps.tables.map(t => (ctx.stamp)(t.0, t.1).unwrap_or(0L))
    d.var_values = d.deps.vars.map(slot => ctx.vars[slot])
    d.rows = []
    d.heads = None
    d.next = FixedArray::make(0, -1)
    d.results.clear()
    d.null_result = None
  }
  let rt = ctx.rt
  // the subquery's `OuterCol(1, j)` is the current row's column j
  guard ctx.row.get(d.outer_col) is Some(outer) else { return None }
  let key = outer.as_int64()
  if d.per_key {
    let hit = match key {
      Some(k) => d.results.get(k)
      None => d.null_result
    }
    if hit is Some(r) {
      d.key_hits += 1
      if r.null_eliminated {
        rt.null_eliminated = true
      }
      rt.row_seq += r.row_seq
      rt.charge(1L)
      return Some(r.rows)
    }
  }
  let sub = ctx.push_outer(ctx.row)
  if d.heads is None {
    build_partition(sub, d)
  } else {
    // the input's effects, as if it ran again
    if d.input_null_eliminated {
      rt.null_eliminated = true
    }
    rt.row_seq += d.input_row_seq
  }
  let first = match (key, d.heads) {
    (Some(k), Some(heads)) => heads.get(k)
    // a NULL outer key equals no row
    _ => -1
  }
  if first < 0 && d.empty_on_empty {
    rt.charge(1L)
    return Some([])
  }
  let before = rt.null_eliminated
  let seq = rt.row_seq
  rt.null_eliminated = false
  let result = {
    errdefer {
      rt.null_eliminated = before || rt.null_eliminated
    }
    let matched = []
    let mut i = first
    while i >= 0 {
      let row = d.rows[i]
      if d.exact || is_true(eval(sub.with_row(row), d.pred)) {
        matched.push(row)
      }
      i = d.next[i]
    }
    rt.charge(matched.length().to_int64() + 1L)
    if d.upper is WorkTable(_) || (matched.is_empty() && d.empty_on_empty) {
      matched
    } else {
      rt.work.set(d.work_id, matched)
      let rows = {
        errdefer rt.work.remove(d.work_id)
        run(sub, d.upper)
      }
      rt.work.remove(d.work_id)
      rows
    }
  }
  let flag = rt.null_eliminated
  rt.null_eliminated = before || flag
  if d.per_key {
    d.key_misses += 1
    // keys that do not repeat: stop keeping results
    if d.key_misses >= 4096 && d.key_hits * 4 < d.key_misses {
      d.per_key = false
      d.results.clear()
      d.null_result = None
    }
  }
  if d.per_key {
    let r = { rows: result, null_eliminated: flag, row_seq: rt.row_seq - seq, }
    match key {
      Some(k) => d.results.set(k, r)
      None => d.null_result = Some(r)
    }
  }
  Some(result)
}

///|
/// Runs the Filter's input once and chains its rows by key value: `heads`
/// holds each key's first row and `next` the following row with the same
/// key (-1 at the end), so a bucket lists its rows in input order. Rows
/// with a NULL key are in no bucket.
fn build_partition(sub : Ctx, d : Decor) -> Unit raise @types.SqlError {
  let rt = sub.rt
  let before = rt.null_eliminated
  let seq = rt.row_seq
  rt.null_eliminated = false
  let rows = {
    errdefer {
      rt.null_eliminated = before || rt.null_eliminated
    }
    run(sub, d.input)
  }
  d.input_null_eliminated = rt.null_eliminated
  rt.null_eliminated = before || d.input_null_eliminated
  d.input_row_seq = rt.row_seq - seq
  rt.charge(rows.length().to_int64())
  let heads = IntTable::new(rows.length())
  let next = FixedArray::make(rows.length(), -1)
  let mut i = rows.length() - 1
  while i >= 0 {
    match rows[i].get(d.inner_col) {
      Some(v) if v is (Bit(_) | TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_)) => {
        let k = v.int64_or(0L)
        next[i] = heads.get(k)
        heads.set(k, i)
      }
      _ => ()
    }
    i -= 1
  }
  d.rows = rows
  d.next = next
  d.heads = Some(heads)
}
