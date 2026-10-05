// Statement-scoped caches that keep per-row subqueries from making whole
// statements quadratic:
//
// - an uncorrelated subquery (no outer row references, no session state
//   or randomness) runs once; later evaluations reuse its rows while the
//   tables it reads are physically unchanged (`Ctx::stamp`) and the
//   variables it reads hold the same values. IN / NOT IN over such rows
//   searches a sorted copy of the values.
// - `column = value` lookups that a Filter(Scan) repeats (correlated
//   EXISTS / scalar subqueries on unindexed columns) build a sorted index
//   of the table on their second use, valid while the table is unchanged.
//
// The session clears both at every statement start
// (`Runtime::clear_caches`), so nothing outlives the statement that
// built it.

///|
/// Caches of the current statement (see the file comment).
struct Memo {
  subqueries : Array[SubqueryMemo]
  lookups : Array[LookupCache]
  /// work table ids handed to unnested subqueries (exec/decorrelate.mbt)
  mut decor_ids : Int
}

///|
fn Memo::new() -> Memo {
  { subqueries: [], lookups: [], decor_ids: 0, }
}

///|
/// Entries per cache before it starts over.
let memo_limit = 256

///|
/// Drops the statement caches (called at every statement start).
pub fn Runtime::clear_caches(self : Runtime) -> Unit {
  self.memo.subqueries.clear()
  self.memo.lookups.clear()
}

///|
/// What an uncorrelated subquery reads besides its own rows.
priv struct Deps {
  tables : Array[(Int, Int)]
  vars : Array[Int]
}

///|
/// Sorted non-NULL first-column values of a memoized subquery, for IN.
priv struct Members {
  collation : @types.Collation?
  values : Array[@types.Value]
  has_null : Bool
  integers : IntTable?
}

///|
priv struct SubqueryMemo {
  plan : @ir.Plan
  /// None: the plan cannot be memoized (correlated, reads session state)
  deps : Deps?
  mut valid : Bool
  mut stamps : Array[Int64]
  mut var_values : Array[@types.Value]
  mut rows : Array[Row]
  /// the run set the 8153 flag / advanced the row counter by this much:
  /// replayed on reuse so the statement observes the same state
  mut null_eliminated : Bool
  mut row_seq : Int64
  /// IN membership (built on first use; None also when sorting failed)
  mut members : Members?
  /// correlated plans: the unnesting analysis (None: not analyzed yet)
  mut decor : Decor??
}

///|
/// `Fn::Named` functions that read session state, counters or randomness:
/// a subquery calling them is never memoized.
let volatile_functions : Array[String] = [
  "RAND", "NEWSEQUENTIALID", "CRYPT_GEN_RANDOM", "NEXT VALUE FOR", "ROWCOUNT_BIG",
  "IDENT_CURRENT", "SESSION_CONTEXT", "CONTEXT_INFO", "CURSOR_STATUS", "COLUMNS_UPDATED",
  "UPDATE", "TRIGGER_NESTLEVEL", "APPLOCK_MODE", "APPLOCK_TEST", "CURRENT_TRANSACTION_ID",
  "CURRENT_REQUEST_ID", "GET_FILESTREAM_TRANSACTION_CONTEXT", "SCOPE_IDENTITY", "XACT_STATE",
  "ERROR_NUMBER", "ERROR_MESSAGE", "ERROR_SEVERITY", "ERROR_STATE", "ERROR_LINE",
  "ERROR_PROCEDURE",
]

///|
/// Walks a subquery plan collecting what it reads; None when it is not
/// memoizable. `depth` counts the outer rows pushed inside the subquery
/// (APPLY right sides, nested subqueries): an `OuterCol` reaching further
/// out is a correlation. `own_vars`: `Var` slots are the caller's variables
/// (false inside an inline function, whose slots are its arguments).
priv struct DepsWalk {
  tables : Array[(Int, Int)]
  vars : Array[Int]
  work_tables : Array[Int]
  mut ok : Bool
  /// with `correlated`, references to the subquery's own outer row (one
  /// level out) are allowed and their columns collected here
  outer_cols : Array[Int]
  mut correlated : Bool
}

///|
fn plan_deps(plan : @ir.Plan) -> Deps? {
  if plan is OneRow {
    return None
  }
  let w : DepsWalk = {
    tables: [],
    vars: [],
    work_tables: [],
    ok: true,
    outer_cols: [],
    correlated: false,
  }
  w.plan(plan, 0, true)
  if w.ok {
    Some({ tables: w.tables, vars: w.vars, })
  } else {
    None
  }
}

///|
fn DepsWalk::plan(
  self : DepsWalk,
  plan : @ir.Plan,
  depth : Int,
  own : Bool,
) -> Unit {
  if !self.ok {
    return
  }
  let exprs = (es : Array[@ir.Expr]) => {
    for e in es {
      self.expr(e, depth, own)
    }
  }
  let keys = (ks : Array[@ir.SortKey]) => {
    for k in ks {
      self.expr(k.expr, depth, own)
    }
  }
  match plan {
    OneRow => ()
    Scan(scope~, id~, ..) =>
      if !self.tables.contains((scope, id)) {
        self.tables.push((scope, id))
      }
    Join(_, l, r, on, ..) => {
      self.plan(l, depth, own)
      self.plan(r, depth, own)
      if on is Some(e) {
        self.expr(e, depth, own)
      }
    }
    Values(rows) =>
      for r in rows {
        exprs(r)
      }
    Project(input, es) => {
      self.plan(input, depth, own)
      exprs(es)
    }
    Filter(input, e) => {
      self.plan(input, depth, own)
      self.expr(e, depth, own)
    }
    Sort(input, ks) => {
      self.plan(input, depth, own)
      keys(ks)
    }
    Limit(input, o, c) => {
      self.plan(input, depth, own)
      if o is Some(e) {
        self.expr(e, depth, own)
      }
      if c is Some(e) {
        self.expr(e, depth, own)
      }
    }
    Distinct(input, _) | NoNullWarning(input) | Concat(input) =>
      self.plan(input, depth, own)
    Unpivot(input, ..) => self.plan(input, depth, own)
    UnionAll(parts) =>
      for p in parts {
        self.plan(p, depth, own)
      }
    Aggregate(input, ks, aggs, ..) => {
      self.plan(input, depth, own)
      exprs(ks)
      for a in aggs {
        if a.arg is Some(e) {
          self.expr(e, depth, own)
        }
        if a.separator is Some(e) {
          self.expr(e, depth, own)
        }
        keys(a.order)
      }
    }
    Window(input, calls) => {
      self.plan(input, depth, own)
      for c in calls {
        exprs(c.args)
        exprs(c.partition)
        keys(c.order)
        match c.frame {
          Some(f) =>
            for b in [f.start, f.end] {
              match b {
                Preceding(e) | Following(e) => self.expr(e, depth, own)
                _ => ()
              }
            }
          None => ()
        }
      }
    }
    Apply(l, r, ..) => {
      self.plan(l, depth, own)
      self.plan(r, depth + 1, own)
    }
    SetOp(_, l, r, _) => {
      self.plan(l, depth, own)
      self.plan(r, depth, own)
    }
    Top(input, count, ties~, ..) => {
      self.plan(input, depth, own)
      self.expr(count, depth, own)
      keys(ties)
    }
    Recursive(id~, anchor, recursive, ..) => {
      self.work_tables.push(id)
      self.plan(anchor, depth, own)
      self.plan(recursive, depth, own)
    }
    WorkTable(id) => if !self.work_tables.contains(id) { self.ok = false }
    TableFunc(_, args) => exprs(args)
    // the inline function's query sees no outer rows and its arguments as
    // variables
    WithParams(args, inner) => {
      exprs(args)
      let correlated = self.correlated
      self.correlated = false
      self.plan(inner, 0, false)
      self.correlated = correlated
    }
    UserTable(_, _) | ForJson(_, _, ..) | ForXml(_, _, _, ..) => self.ok = false
  }
}

///|
fn DepsWalk::expr(
  self : DepsWalk,
  e : @ir.Expr,
  depth : Int,
  own : Bool,
) -> Unit {
  if !self.ok {
    return
  }
  match e.kind {
    Lit(_) | Col(_) => ()
    Var(slot) => if own && !self.vars.contains(slot) { self.vars.push(slot) }
    OuterCol(d, i) =>
      if self.correlated && d == depth + 1 {
        if !self.outer_cols.contains(i) {
          self.outer_cols.push(i)
        }
      } else if d > depth {
        self.ok = false
      }
    Cast(a, ..) | Collate(a) | Neg(a) | BitNot(a) | Not(a) | IsNull(a, ..) =>
      self.expr(a, depth, own)
    Arith(_, a, b)
    | BitOp(_, a, b)
    | Concat(a, b)
    | Cmp(_, a, b, _)
    | And(a, b)
    | Or(a, b) => {
      self.expr(a, depth, own)
      self.expr(b, depth, own)
    }
    Like(a, b, escape~, ..) => {
      self.expr(a, depth, own)
      self.expr(b, depth, own)
      if escape is Some(x) {
        self.expr(x, depth, own)
      }
    }
    InList(a, items, ..) => {
      self.expr(a, depth, own)
      for x in items {
        self.expr(x, depth, own)
      }
    }
    Case(branches, els) => {
      for b in branches {
        self.expr(b.0, depth, own)
        self.expr(b.1, depth, own)
      }
      if els is Some(x) {
        self.expr(x, depth, own)
      }
    }
    Call(f, args) => {
      match f {
        NewId
        | ScopeIdentity
        | XactState
        | ErrorNumber
        | ErrorMessage
        | ErrorSeverity
        | ErrorState
        | ErrorLine
        | ErrorProcedure => self.ok = false
        Named(name) =>
          if name.has_prefix("@@") || volatile_functions.contains(name) {
            self.ok = false
          }
        _ => ()
      }
      for a in args {
        self.expr(a, depth, own)
      }
    }
    Global(_) | UserFn(_, _) => self.ok = false
    Subquery(p) | Exists(p) => self.plan(p, depth + 1, own)
    InQuery(a, p, ..) | Quantified(_, a, p, ..) => {
      self.expr(a, depth, own)
      self.plan(p, depth + 1, own)
    }
  }
}

///|
/// Runs subquery `plan` with the current row as its outer row.
fn run_direct(ctx : Ctx, plan : @ir.Plan) -> Array[Row] raise @types.SqlError {
  run(ctx.push_outer(ctx.row), plan)
}

///|
/// Rows of subquery `plan` run with the current row as its outer row, and
/// the memo entry when they came from (or went into) the statement memo.
fn subquery_rows(
  ctx : Ctx,
  plan : @ir.Plan,
) -> (Array[Row], SubqueryMemo?) raise @types.SqlError {
  let memo = ctx.rt.memo
  let entry = match
    memo.subqueries.search_by(e => physical_equal(e.plan, plan)) {
    Some(i) => memo.subqueries[i]
    None => {
      let e : SubqueryMemo = {
        plan,
        deps: plan_deps(plan),
        valid: false,
        stamps: [],
        var_values: [],
        rows: [],
        null_eliminated: false,
        row_seq: 0L,
        members: None,
        decor: None,
      }
      // bounded: contexts that never clear (constant folding) cannot grow it
      if memo.subqueries.length() >= memo_limit {
        memo.subqueries.clear()
      }
      memo.subqueries.push(e)
      e
    }
  }
  guard entry.deps is Some(deps) else {
    // correlated: unnested through a key partition when it can be
    // (exec/decorrelate.mbt)
    match decorrelated_rows(ctx, entry) {
      Some(rows) => return (rows, None)
      None => return (run_direct(ctx, plan), None)
    }
  }
  // a valid entry whose tables and variables are unchanged (checked
  // without allocating: this runs once per outer row)
  if entry.valid &&
    entry.stamps.length() == deps.tables.length() &&
    entry.var_values.length() == deps.vars.length() {
    let mut same = true
    for i, t in deps.tables {
      match (ctx.stamp)(t.0, t.1) {
        Some(s) => if s != entry.stamps[i] { same = false }
        None => return (run_direct(ctx, plan), None)
      }
    }
    for i, slot in deps.vars {
      match ctx.vars.get(slot) {
        Some(v) => if same && v != entry.var_values[i] { same = false }
        None => return (run_direct(ctx, plan), None)
      }
    }
    if same {
      if entry.null_eliminated {
        ctx.rt.null_eliminated = true
      }
      ctx.rt.row_seq += entry.row_seq
      return (entry.rows, Some(entry))
    }
  }
  let stamps = []
  for t in deps.tables {
    match (ctx.stamp)(t.0, t.1) {
      Some(s) => stamps.push(s)
      None => return (run_direct(ctx, plan), None)
    }
  }
  let var_values = []
  for slot in deps.vars {
    match ctx.vars.get(slot) {
      Some(v) => var_values.push(v)
      None => return (run_direct(ctx, plan), None)
    }
  }
  entry.valid = false
  let before = ctx.rt.null_eliminated
  let seq = ctx.rt.row_seq
  ctx.rt.null_eliminated = false
  let rows = {
    errdefer {
      ctx.rt.null_eliminated = before || ctx.rt.null_eliminated
    }
    run_direct(ctx, plan)
  }
  entry.null_eliminated = ctx.rt.null_eliminated
  ctx.rt.null_eliminated = before || entry.null_eliminated
  entry.row_seq = ctx.rt.row_seq - seq
  entry.stamps = stamps
  entry.var_values = var_values
  entry.rows = rows
  entry.members = None
  entry.valid = true
  (rows, Some(entry))
}

///|
/// The entry's first-column values sorted under `collation` (the IN
/// comparison's), or None when they cannot be ordered.
fn SubqueryMemo::members(
  self : SubqueryMemo,
  collation : @types.Collation?,
) -> Members? {
  match self.members {
    Some(m) if m.collation == collation => return Some(m)
    _ => ()
  }
  let values = []
  let mut has_null = false
  for r in self.rows {
    match r[0] {
      Null => has_null = true
      v => values.push(v)
    }
  }
  let mut failed = false
  values.sort_by((a, b) => {
    (@types.compare(a, b, collation?) catch {
      _ => {
        failed = true
        None
      }
    }).unwrap_or(0)
  })
  if failed {
    return None
  }
  let m = Members::new(values, has_null, collation)
  self.members = Some(m)
  Some(m)
}

///|
/// Keep the sorted values for probes requiring conversion-aware comparison.
fn Members::new(
  values : Array[@types.Value],
  has_null : Bool,
  collation : @types.Collation?,
) -> Members {
  let integers = if values
    .iter()
    .all(v => v is (TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_))) {
    let table = IntTable::new(values.length())
    for v in values {
      table.set(v.int64_or(0L), 0)
    }
    Some(table)
  } else {
    None
  }
  { collation, values, has_null, integers, }
}

///|
/// `va IN (members)`: Some(true) on an equal value, None (unknown) when
/// none is equal but the set holds a NULL, Some(false) otherwise — the
/// linear search's answer, by binary search.
fn Members::contains(
  self : Members,
  va : @types.Value,
) -> Bool? raise @types.SqlError {
  if self.integers is Some(table) &&
    va is (TinyInt(_) | SmallInt(_) | Int(_) | BigInt(_)) {
    if table.get(va.int64_or(0L)) >= 0 {
      return Some(true)
    }
    return if self.has_null { None } else { Some(false) }
  }
  let mut lo = 0
  let mut hi = self.values.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    match @types.compare(va, self.values[mid], collation?=self.collation) {
      Some(0) => return Some(true)
      Some(c) if c < 0 => hi = mid
      _ => lo = mid + 1
    }
  }
  if self.has_null {
    None
  } else {
    Some(false)
  }
}

///|
/// A lookup index over one table for `column = value` conjuncts: rows with
/// no NULL key, sorted by key (under each conjunct's collation and ansi
/// flag) and then by row id, so equal keys keep the scan order.
priv struct LookupCache {
  scope : Int
  id : Int
  columns : Array[Int]
  collations : Array[@types.Collation?]
  ansi : Array[Bool]
  mut stamp : Int64
  mut uses : Int
  mut index : Array[(Array[@types.Value], Int64, Row)]?
}

///|
/// Compares a key with the lookup's comparison.
fn LookupCache::compare(
  self : LookupCache,
  a : Array[@types.Value],
  b : Array[@types.Value],
) -> Int raise @types.SqlError {
  for i in 0..<a.length() {
    let c = @types.compare(
      a[i],
      b[i],
      collation?=self.collations[i],
      ansi=self.ansi[i],
    ).unwrap_or(0)
    if c != 0 {
      return c
    }
  }
  0
}

///|
/// Rows of table (scope, id) whose `columns` equal `values` under the
/// conjuncts' comparison, in scan order; None when the lookup has not been
/// repeated yet in this statement (one scan is cheaper than an index) or
/// the table cannot be stamped.
fn cached_lookup(
  ctx : Ctx,
  scope : Int,
  id : Int,
  columns : Array[Int],
  collations : Array[@types.Collation?],
  ansi : Array[Bool],
  values : Array[@types.Value],
) -> Array[(Int64, Row)]? raise @types.SqlError {
  guard (ctx.stamp)(scope, id) is Some(stamp) else { return None }
  let lookups = ctx.rt.memo.lookups
  let entry = match
    lookups.search_by(l => {
      l.scope == scope &&
      l.id == id &&
      l.columns == columns &&
      l.collations == collations &&
      l.ansi == ansi
    }) {
    Some(i) => lookups[i]
    None => {
      let l : LookupCache = {
        scope,
        id,
        columns,
        collations,
        ansi,
        stamp,
        uses: 0,
        index: None,
      }
      if lookups.length() >= memo_limit {
        lookups.clear()
      }
      lookups.push(l)
      l
    }
  }
  if entry.stamp != stamp {
    entry.stamp = stamp
    entry.uses = 0
    entry.index = None
  }
  entry.uses += 1
  let index = match entry.index {
    Some(ix) => ix
    None => {
      if entry.uses < 2 {
        return None
      }
      let keyed = []
      for kv in (ctx.source)(scope, id) {
        let key = columns.map(c => kv.1[c])
        if !key.iter().any(v => v is Null) {
          keyed.push((key, kv.0, kv.1))
        }
      }
      let mut failure : @types.SqlError? = None
      keyed.sort_by((a, b) => {
        let c = entry.compare(a.0, b.0) catch {
          e => {
            failure = Some(e)
            0
          }
        }
        if c != 0 {
          c
        } else {
          a.1.compare(b.1)
        }
      })
      if failure is Some(e) {
        raise e
      }
      entry.index = Some(keyed)
      keyed
    }
  }
  // first key >= values
  let mut lo = 0
  let mut hi = index.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if entry.compare(index[mid].0, values) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let out = []
  while lo < index.length() && entry.compare(index[lo].0, values) == 0 {
    out.push((index[lo].1, index[lo].2))
    lo += 1
  }
  Some(out)
}
