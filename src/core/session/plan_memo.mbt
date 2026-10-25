///|
/// Bound plans of queries reused across requests (an sp_executesql loop,
/// an ORM's repeated queries). The binder reads nothing but its `Env`: the
/// frame's variables, the database collation, ANSI_NULLS, the SET options
/// and the callbacks of `Session::catalog`. A `BindStamp` records every
/// input those read (catalogs by physical identity, `Db::same_catalog`;
/// session settings by value), and a memo entry is used only while all of
/// them are unchanged and the query is the same parsed object (the parse
/// cache returns one AST per text). Only plans over database tables and
/// built-in expressions are kept (`memo_plan_ok`): no catalog views,
/// table variables, temp tables, functions or sequences, whose bindings
/// read more session state or carry values. Entries are per session: the
/// SET options and frames are.
priv struct BindStamp {
  database : String
  dbs : Array[(String, @store.Db)]
  db_names : Array[(String, String)]
  db_ids : Array[(String, Int)]
  db_options : Array[(String, DbOptions)]
  temp : @store.Db
  tvars : @store.Db
  flags_version : Int
  option_bits : Int
  dates : @types.DateSettings
  datefirst : Int
  identity_insert : Int?
  isolation : String
  nest_level : Int
  trancount : Int
  frames : Int
  proc_name : String?
  vars : Array[(String, @bind.VarInfo)]
  rpc : Bool
}

///|
priv struct PlanMemo {
  query : @ast.Query
  stamp : BindStamp
  bound : @bind.BoundQuery
}

///|
/// Plans remembered per session (round robin beyond this).
const PLAN_MEMO_LIMIT : Int = 16

///|
fn Session::bind_stamp(self : Session) -> BindStamp {
  let frame = self.frame()
  {
    database: self.rt.database,
    dbs: self.server.dbs.iter().to_array(),
    db_names: self.server.db_names.iter().to_array(),
    db_ids: self.server.db_ids.iter().to_array(),
    db_options: self.server.db_options.iter().to_array(),
    temp: self.temp,
    tvars: self.tvars,
    flags_version: self.flags_version,
    option_bits: self.rt.option_bits,
    dates: self.rt.dates,
    datefirst: self.rt.datefirst,
    identity_insert: self.identity_insert,
    isolation: self.isolation,
    nest_level: self.rt.nest_level,
    trancount: self.rt.trancount,
    frames: self.frames.length(),
    proc_name: frame.proc_name,
    vars: frame.vars.iter().to_array(),
    rpc: self.rpc,
  }
}

///|
/// Every binder input is as when `s` was taken (cheapest checks first).
fn Session::stamp_holds(self : Session, s : BindStamp) -> Bool {
  guard self.flags_version == s.flags_version &&
    self.rt.option_bits == s.option_bits &&
    self.rt.datefirst == s.datefirst &&
    self.rt.nest_level == s.nest_level &&
    self.rt.trancount == s.trancount &&
    self.frames.length() == s.frames &&
    self.rpc == s.rpc &&
    self.identity_insert == s.identity_insert &&
    (
      physical_equal(self.rt.database, s.database) ||
      self.rt.database == s.database
    ) &&
    (
      physical_equal(self.isolation, s.isolation) ||
      self.isolation == s.isolation
    ) &&
    self.rt.dates == s.dates &&
    self.temp.same_catalog(s.temp) &&
    self.tvars.same_catalog(s.tvars) else {
    return false
  }
  let frame = self.frame()
  guard frame.proc_name == s.proc_name &&
    self.server.dbs.length() == s.dbs.length() &&
    self.server.db_names.length() == s.db_names.length() &&
    self.server.db_ids.length() == s.db_ids.length() &&
    self.server.db_options.length() == s.db_options.length() &&
    frame.vars.length() == s.vars.length() else {
    return false
  }
  let mut i = 0
  for k, v in self.server.dbs {
    let (k2, v2) = s.dbs[i]
    if !same_key(k, k2) || !v.same_catalog(v2) {
      return false
    }
    i += 1
  }
  i = 0
  for k, v in self.server.db_names {
    let (k2, v2) = s.db_names[i]
    if !same_key(k, k2) || !same_key(v, v2) {
      return false
    }
    i += 1
  }
  i = 0
  for k, v in self.server.db_ids {
    let (k2, v2) = s.db_ids[i]
    if !same_key(k, k2) || v != v2 {
      return false
    }
    i += 1
  }
  i = 0
  for k, v in self.server.db_options {
    let (k2, v2) = s.db_options[i]
    if !same_key(k, k2) || !physical_equal(v, v2) {
      return false
    }
    i += 1
  }
  i = 0
  for k, v in frame.vars {
    let (k2, v2) = s.vars[i]
    if !same_key(k, k2) || v.slot != v2.slot || v.ty != v2.ty {
      return false
    }
    i += 1
  }
  true
}

///|
fn same_key(a : String, b : String) -> Bool {
  physical_equal(a, b) || a == b
}

///|
/// The remembered plan of `q`, when nothing its binding read has changed.
fn Session::memo_plan(self : Session, q : @ast.Query) -> @bind.BoundQuery? {
  guard self.tx is None && self.triggers.is_empty() else { return None }
  for m in self.plan_memo {
    if physical_equal(m.query, q) {
      return if self.stamp_holds(m.stamp) { Some(m.bound) } else { None }
    }
  }
  None
}

///|
/// Remembers `bound`, bound from `q` under `stamp` without deferred errors
/// or other traces, when it qualifies (`memo_plan_ok`).
fn Session::remember_plan(
  self : Session,
  q : @ast.Query,
  stamp : BindStamp,
  bound : @bind.BoundQuery,
) -> Unit {
  guard self.tx is None &&
    self.triggers.is_empty() &&
    self.deferred.is_empty() &&
    memo_plan_ok(bound.plan) &&
    self.stamp_holds(stamp) else {
    return
  }
  let entry = { query: q, stamp, bound, }
  for i, m in self.plan_memo {
    if physical_equal(m.query, q) {
      self.plan_memo[i] = entry
      return
    }
  }
  if self.plan_memo.length() < PLAN_MEMO_LIMIT {
    self.plan_memo.push(entry)
  } else {
    self.plan_memo[self.plan_memo_next] = entry
    self.plan_memo_next = (self.plan_memo_next + 1) % PLAN_MEMO_LIMIT
  }
}

///|
/// Plans whose binding reads only what `BindStamp` records: database
/// tables (scope 0) and built-in expressions.
fn memo_plan_ok(p : @ir.Plan) -> Bool {
  match p {
    OneRow => true
    Scan(scope~, ..) => scope == 0
    Join(_, l, r, on, ..) =>
      memo_plan_ok(l) && memo_plan_ok(r) && on.map(memo_expr_ok).unwrap_or(true)
    Values(rows) => rows.iter().all(r => r.iter().all(memo_expr_ok))
    Project(p, es) => memo_plan_ok(p) && es.iter().all(memo_expr_ok)
    Filter(p, e) => memo_plan_ok(p) && memo_expr_ok(e)
    Sort(p, keys) =>
      memo_plan_ok(p) && keys.iter().all(k => memo_expr_ok(k.expr))
    Limit(p, a, b) =>
      memo_plan_ok(p) &&
      a.map(memo_expr_ok).unwrap_or(true) &&
      b.map(memo_expr_ok).unwrap_or(true)
    Distinct(p, _) => memo_plan_ok(p)
    UnionAll(ps) => ps.iter().all(memo_plan_ok)
    Aggregate(p, keys, aggs, ..) =>
      memo_plan_ok(p) &&
      keys.iter().all(memo_expr_ok) &&
      aggs
      .iter()
      .all(a => {
        a.arg.map(memo_expr_ok).unwrap_or(true) &&
        a.separator.map(memo_expr_ok).unwrap_or(true) &&
        a.order.iter().all(k => memo_expr_ok(k.expr))
      })
    SetOp(_, l, r, _) => memo_plan_ok(l) && memo_plan_ok(r)
    Top(p, e, ties~, ..) =>
      memo_plan_ok(p) &&
      memo_expr_ok(e) &&
      ties.iter().all(k => memo_expr_ok(k.expr))
    Apply(l, r, ..) => memo_plan_ok(l) && memo_plan_ok(r)
    _ => false
  }
}

///|
fn memo_expr_ok(e : @ir.Expr) -> Bool {
  match e.kind {
    Lit(_) | Var(_) | Col(_) | OuterCol(_, _) | Global(_) => true
    Cast(x, ..) | Collate(x) | Neg(x) | BitNot(x) | Not(x) | IsNull(x, ..) =>
      memo_expr_ok(x)
    Arith(_, a, b)
    | BitOp(_, a, b)
    | Concat(a, b)
    | Cmp(_, a, b, _)
    | And(a, b)
    | Or(a, b) => memo_expr_ok(a) && memo_expr_ok(b)
    Like(a, b, escape~, ..) =>
      memo_expr_ok(a) &&
      memo_expr_ok(b) &&
      escape.map(memo_expr_ok).unwrap_or(true)
    InList(x, xs, ..) => memo_expr_ok(x) && xs.iter().all(memo_expr_ok)
    Case(arms, other) =>
      arms.iter().all(a => memo_expr_ok(a.0) && memo_expr_ok(a.1)) &&
      other.map(memo_expr_ok).unwrap_or(true)
    // Named built-ins include catalog and sequence functions
    Call(Named(_), _) => false
    Call(_, args) => args.iter().all(memo_expr_ok)
    Subquery(p) | Exists(p) => memo_plan_ok(p)
    InQuery(x, p, ..) | Quantified(_, x, p, ..) =>
      memo_expr_ok(x) && memo_plan_ok(p)
    UserFn(_, _) => false
  }
}

///|
/// `precheck_hints(stmts)`, remembering a finding of nothing: it reads the
/// statements and, through `find_table` and `find_module`, what
/// `BindStamp` records (`hint_text` only words a failure).
fn Session::memo_precheck_hints(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> Result[Array[(String, Int)], Array[(@types.SqlError, Int)]] {
  guard self.tx is None && self.triggers.is_empty() else {
    return self.precheck_hints(stmts)
  }
  for i, m in self.hints_memo {
    if physical_equal(m.0, stmts) {
      if self.stamp_holds(m.1) {
        return Ok([])
      }
      self.hints_memo.remove(i) |> ignore
      break
    }
  }
  let stamp = self.bind_stamp()
  let result = self.precheck_hints(stmts)
  if result is Ok(warnings) && warnings.is_empty() && self.stamp_holds(stamp) {
    if self.hints_memo.length() >= PLAN_MEMO_LIMIT {
      self.hints_memo.remove(0) |> ignore
    }
    self.hints_memo.push((stmts, stamp))
  }
  result
}
