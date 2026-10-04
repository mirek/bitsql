///|
/// Batch-level checks of table hints in FROM clauses (captured: msduck-runs
/// tedious-compat-gaps #080-#098, tail/table-hints). SQL Server rejects the
/// whole batch before running anything. First pass, over the whole batch:
/// unknown hints 321 (as written), conflicting locking hints 1047,
/// FORCESEEK with FORCESCAN 10746 (all class 15). Second pass: SNAPSHOT
/// 367, NOEXPAND on a table or non-indexed view 8171 state 2,
/// IGNORE_CONSTRAINTS / IGNORE_TRIGGERS 8171 state 1, a missing INDEX name
/// 308 or id 307, INDEX(0) with another index 8622 state 2, FORCESEEK
/// without a seek predicate 8622 state 1.
///
/// Without a failure, the warnings to send before the batch runs: INFO
/// 4430 per view reference with an INDEX hint (view name, line).
fn Session::precheck_hints(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> Result[Array[(String, Int)], Array[(@types.SqlError, Int)]] {
  let warnings = []
  for phase in 1..<=2 {
    let c : HintCheck = {
      session: self,
      phase,
      failure: None,
      before: [],
      warnings,
    }
    for s in stmts {
      c.stmt(s)
    }
    if c.failure is Some(f) {
      return Err(c.before + [f])
    }
  }
  Ok(warnings)
}

///|
priv struct HintCheck {
  session : Session
  phase : Int
  mut failure : (@types.SqlError, Int)?
  /// errors sent before `failure` (207s before 215)
  before : Array[(@types.SqlError, Int)]
  warnings : Array[(String, Int)]
}

///|
fn HintCheck::fail(self : HintCheck, e : @types.SqlError, line : Int) -> Unit {
  if self.failure is None {
    self.failure = Some((e, line))
  }
}

///|
fn HintCheck::stmt(self : HintCheck, s : @ast.Stmt) -> Unit {
  let line = s.span.line
  match s.kind {
    Select(q) => self.query(q, line)
    Declare(vars) =>
      for v in vars {
        if v.init is Some(i) {
          self.expr(i, line)
        }
      }
    SetVar(_, _, e) | Print(e) => self.expr(e, line)
    Insert({ source: InsertQuery(q), .. }) => self.query(q, line)
    Update({ from, where_, .. }) | Delete({ from, where_, .. }) =>
      self.from_list(from, where_, line)
    If(c, a, b) => {
      self.expr(c, line)
      self.stmt(a)
      if b is Some(x) {
        self.stmt(x)
      }
    }
    While(c, b) => {
      self.expr(c, line)
      self.stmt(b)
    }
    Block(list) => list.each(x => self.stmt(x))
    TryCatch(a, b) => {
      a.each(x => self.stmt(x))
      b.each(x => self.stmt(x))
    }
    _ => ()
  }
}

///|
fn HintCheck::query(self : HintCheck, q : @ast.Query, line : Int) -> Unit {
  for c in q.ctes {
    self.query(c.query, line)
  }
  self.body(q.body, line, q.ctes.map(c => c.name.name.to_lower()))
}

///|
fn HintCheck::body(
  self : HintCheck,
  b : @ast.QueryBody,
  line : Int,
  ctes : Array[String],
) -> Unit {
  match b {
    Select(s) => {
      for item in s.items {
        match item.kind {
          ExprItem(e, ..) | Assign(_, _, e) => self.expr(e, line)
          Star(_) => ()
        }
      }
      self.from_list(s.from, s.where_, line, ctes~)
      if s.having is Some(h) {
        self.expr(h, line)
      }
    }
    SetOperation(_, l, r) => {
      self.body(l, line, ctes)
      self.body(r, line, ctes)
    }
    Nested(q) => self.query(q, line)
  }
}

///|
fn HintCheck::expr(self : HintCheck, e : @ast.Expr, line : Int) -> Unit {
  walk_expr(e, x => {
    match x.kind {
      Subquery(q) | Exists(q) | InQuery(_, q, ..) => self.query(q, line)
      _ => ()
    }
  })
}

///|
/// The tables of one FROM list with the predicates that may drive a seek
/// (WHERE and every ON clause).
fn HintCheck::from_list(
  self : HintCheck,
  from : Array[@ast.TableRef],
  where_ : @ast.Expr?,
  line : Int,
  ctes? : Array[String] = [],
) -> Unit {
  let preds : Array[@ast.Expr] = []
  if where_ is Some(w) {
    self.expr(w, line)
    ast_conjuncts(w, preds)
  }
  let tables : Array[@ast.TableRef] = []
  fn collect(r : @ast.TableRef) {
    match r.kind {
      Join(_, a, b, on~, ..) => {
        collect(a)
        collect(b)
        if on is Some(o) {
          ast_conjuncts(o, preds)
        }
      }
      Pivot(src, _, ..) => collect(src)
      _ => tables.push(r)
    }
  }
  from.each(collect)
  for p in preds {
    self.expr(p, line)
  }
  for r in tables {
    match r.kind {
      Table(name, alias_~, hints~) if !hints.is_empty() => {
        let is_cte = name.parts.length() == 1 &&
          ctes.contains(name.base().to_lower())
        self.table_hints(name, alias_, hints, preds, line, is_cte)
      }
      Derived(q, ..) => self.query(q, line)
      TableFunc(name, args, openjson_with=None, columns=[], ..) if self.phase ==
        1 => self.legacy_hints(name, args, line)
      _ => ()
    }
  }
}

///|
/// `FROM t (a, b)` on a table or view (not a function): unless it is one
/// legacy hint word (`t (NOLOCK)`, also bracketed), every bare word is 207
/// "Invalid column name" and then 215, for the whole batch; 215 reports
/// line 13 for a schema-qualified name (captured: tail/table-hints-gaps,
/// tail5/b2-hints).
fn HintCheck::legacy_hints(
  self : HintCheck,
  name : @ast.ObjectName,
  args : Array[@ast.Expr],
  line : Int,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  if args is [{ kind: Column([w]), .. }] &&
    legacy_hint_words.contains(w.name.to_upper()) {
    return
  }
  let is_object = self.session.find_table(name) is Some(_) ||
    (self.session.find_module(name) is Some(m) && m.kind is View)
  if !is_object {
    return
  }
  let words = []
  for a in args {
    match a.kind {
      Column([w]) => words.push(w.name)
      IntLit(_) | DecimalLit(_) | StrLit(_, ..) => ()
      _ => return
    }
  }
  for w in words {
    self.before.push(
      (@types.sql_error(207, "Invalid column name '\{w}'."), line),
    )
  }
  let written = name.parts.map(p => p.name).join(".")
  self.fail(
    @types.sql_error(
      215,
      "Parameters supplied for object '\{written}' which is not a function. If the parameters are intended as a table hint, a WITH keyword is required.",
    ),
    if name.parts.length() > 1 {
      13
    } else {
      line
    },
  )
}

///|
/// Hints that may follow a table without WITH when they are the only one.
let legacy_hint_words : Array[String] = [
  "NOLOCK", "READUNCOMMITTED", "UPDLOCK", "REPEATABLEREAD", "SERIALIZABLE", "READCOMMITTED",
  "TABLOCK", "TABLOCKX", "PAGLOCK", "ROWLOCK", "NOWAIT", "READPAST", "XLOCK", "HOLDLOCK",
]

///|
fn ast_conjuncts(e : @ast.Expr, out : Array[@ast.Expr]) -> Unit {
  match e.kind {
    And(a, b) => {
      ast_conjuncts(a, out)
      ast_conjuncts(b, out)
    }
    Paren(a) => ast_conjuncts(a, out)
    _ => out.push(e)
  }
}

///|
/// Hints accepted on a FROM table that this module recognizes.
let from_table_hints : Array[String] = [
  "NOEXPAND", "INDEX", "FORCESEEK", "FORCESCAN", "HOLDLOCK", "NOLOCK", "NOWAIT",
  "PAGLOCK", "READCOMMITTED", "READCOMMITTEDLOCK", "READPAST", "READUNCOMMITTED",
  "REPEATABLEREAD", "ROWLOCK", "SERIALIZABLE", "SNAPSHOT", "SPATIAL_WINDOW_MAX_CELLS",
  "TABLOCK", "TABLOCKX", "UPDLOCK", "XLOCK", "KEEPIDENTITY", "KEEPDEFAULTS", "IGNORE_CONSTRAINTS",
  "IGNORE_TRIGGERS", "TABLESAMPLE",
]

///|
/// The isolation class of a locking hint (NOLOCK = READUNCOMMITTED,
/// HOLDLOCK = SERIALIZABLE).
fn isolation_class(h : String) -> String? {
  match h {
    "NOLOCK" | "READUNCOMMITTED" => Some("RU")
    "READCOMMITTED" => Some("RC")
    "READCOMMITTEDLOCK" => Some("RCL")
    "REPEATABLEREAD" => Some("RR")
    "SERIALIZABLE" | "HOLDLOCK" => Some("SR")
    _ => None
  }
}

///|
/// The hint's name as written in the batch text (321 quotes it so).
fn Session::hint_text(self : Session, h : @ast.TableHint) -> String {
  let n = h.name.length()
  if h.span.start >= 0 && h.span.start + n <= self.text.length() {
    let s = self.text.unsafe_substring(start=h.span.start, end=h.span.start + n)
    if s.to_upper() == h.name {
      return s
    }
  }
  h.name
}

///|
fn HintCheck::table_hints(
  self : HintCheck,
  name : @ast.ObjectName,
  alias_ : @ast.Ident?,
  hints : Array[@ast.TableHint],
  preds : Array[@ast.Expr],
  line : Int,
  is_cte : Bool,
) -> Unit {
  if self.failure is Some(_) {
    return
  }
  let names = hints.map(h => h.name)
  let iso = names.filter_map(isolation_class)
  if self.phase == 1 {
    for h in hints {
      if !from_table_hints.contains(h.name) {
        self.fail(
          @types.sql_error(
            321,
            "\"\{self.session.hint_text(h)}\" is not a recognized table hints option.",
            severity=15,
          ),
          line,
        )
        return
      }
    }
    let conflict = () => {
      self.fail(
        @types.sql_error(
          1047,
          "Conflicting locking hints specified.",
          severity=15,
        ),
        line,
      )
    }
    if iso.iter().any(c => c != iso[0]) {
      return conflict()
    }
    let gran = names.filter(n => {
      n is ("ROWLOCK" | "PAGLOCK" | "TABLOCK" | "TABLOCKX")
    })
    if gran.iter().any(g => g != gran[0]) {
      return conflict()
    }
    let mode = names.filter(n => n is ("UPDLOCK" | "XLOCK"))
    if mode.iter().any(m => m != mode[0]) {
      return conflict()
    }
    if iso.contains("RU") && (!gran.is_empty() || !mode.is_empty()) {
      return conflict()
    }
    if names.contains("FORCESEEK") && names.contains("FORCESCAN") {
      self.fail(
        @types.sql_error(
          10746,
          "The FORCESCAN hint is specified simultaneously with the FORCESEEK hint. Remove one of the hints and resubmit the query.",
          severity=15,
        ),
        line,
      )
    }
    return
  }
  if is_cte {
    return
  }
  let base = name.base()
  if names.contains("SNAPSHOT") {
    self.fail(
      @types.sql_error(
        367, "The hint 'SNAPSHOT' is valid only with memory optimized tables.",
      ),
      line,
    )
    return
  }
  for h in hints {
    if h.name is ("NOEXPAND" | "IGNORE_CONSTRAINTS" | "IGNORE_TRIGGERS") {
      self.fail(
        @types.sql_error(
          8171,
          "Hint '\{h.name.to_lower()}' on object '\{base}' is invalid.",
          state=if h.name == "NOEXPAND" { 2 } else { 1 },
        ),
        line,
      )
      return
    }
  }
  let table = self.session.find_table(name).map(x => x.1)
  let is_view = table is None &&
    self.session.find_module(name) is Some(m) &&
    m.kind is View
  let plan_error = (state : Int) => {
    self.fail(
      @types.sql_error(
        8622,
        "Query processor could not produce a query plan because of the hints defined in this query. Resubmit the query without specifying any hints and without using SET FORCEPLAN.",
        state~,
      ),
      line,
    )
  }
  // INDEX(...) hints: ids or names, every one must exist; index 0 (the
  // heap / clustered scan) cannot be combined with another index
  let index_args = hints
    .filter(h => h.name == "INDEX")
    .map(h => h.args)
    .fold(init=[], (acc, xs) => acc + xs)
  if !index_args.is_empty() {
    // INDEX hints on a view are ignored with INFO 4430 at compile time,
    // once per reference, index names unchecked (captured: tail5/b2-hints)
    if is_view {
      self.warnings.push((base, line))
    }
    guard table is Some(t) else { return }
    let mut zero = false
    for a in index_args {
      let text = a.trim().to_owned()
      let digits = text != "" && text.iter().all(c => c >= '0' && c <= '9')
      let n = if digits && text.length() < 9 {
        text.iter().fold(init=0, (acc, c) => acc * 10 + (c.to_int() - 48))
      } else {
        -1
      }
      match n {
        n if n >= 0 =>
          if n == 0 {
            zero = true
          } else if n == 1 {
            if !t.indexes.iter().any(i => i.clustered) {
              self.fail(@types.not_supported("INDEX(1) on a heap"), line)
              return
            }
          } else if !t.indexes.iter().any(i => i.index_id == n) {
            self.fail(
              @types.sql_error(
                307,
                "Index ID \{n} on table '\{base}' (specified in the FROM clause) does not exist.",
              ),
              line,
            )
            return
          }
        _ => {
          let iname = if text.has_prefix("[") && text.has_suffix("]") {
            text.unsafe_substring(start=1, end=text.length() - 1)
          } else {
            text
          }
          if !t.indexes.iter().any(i => i.name.to_lower() == iname.to_lower()) {
            self.fail(
              @types.sql_error(
                308,
                "Index '\{iname}' on table '\{base}' (specified in the FROM clause) does not exist.",
              ),
              line,
            )
            return
          }
        }
      }
    }
    if zero && index_args.length() > 1 {
      plan_error(2)
      return
    }
    if zero && names.contains("FORCESEEK") {
      plan_error(1)
      return
    }
  }
  if names.contains("FORCESEEK") {
    if table is None && !preds.is_empty() {
      self.fail(
        @types.not_supported("FORCESEEK on a view with predicates"),
        line,
      )
      return
    }
    let q = match alias_ {
      Some(a) => a.name.to_lower()
      None => base.to_lower()
    }
    let has_column = (c : String) => {
      match table {
        Some(t) => t.column_index(c) is Some(_)
        None => false
      }
    }
    // a column of this table: qualified by its alias/name, or unqualified
    // and present in the table
    let own = (e : @ast.Expr) => {
      match e.kind {
        Column(parts) if parts.length() >= 2 =>
          if parts[parts.length() - 2].name.to_lower() == q {
            Some(parts[parts.length() - 1].name)
          } else {
            None
          }
        Column([p]) if has_column(p.name) => Some(p.name)
        _ => None
      }
    }
    let reads_own = (e : @ast.Expr) => {
      let mut found = false
      walk_expr(e, x => if own(x) is Some(_) { found = true })
      found
    }
    let leading : Array[String] = match table {
      Some(t) =>
        t.indexes.filter_map(i => {
          i.columns.get(0).map(c => t.columns[c.0].name.to_lower())
        })
      None => []
    }
    let lead = (e : @ast.Expr) => {
      match own(e) {
        Some(c) => leading.contains(c.to_lower())
        None => false
      }
    }
    // a seek needs a predicate on the leading key column of an index
    let reads_lead = (e : @ast.Expr) => {
      let mut found = false
      walk_expr(e, x => if lead(x) { found = true })
      found
    }
    let mut seekable = false
    let mut mentions = false
    for p in preds {
      if reads_lead(p) {
        mentions = true
      }
      match p.kind {
        Compare(_, a, b) if lead(a) && !reads_own(b) => seekable = true
        Compare(_, a, b) if lead(b) && !reads_own(a) => seekable = true
        Between(a, lo, hi, negated=false) if lead(a) &&
          !reads_own(lo) &&
          !reads_own(hi) => seekable = true
        InList(a, items, negated=false) if lead(a) &&
          !items.iter().any(reads_own) => seekable = true
        _ => ()
      }
    }
    if seekable && table is Some(_) && hints.iter().all(h => h.args.is_empty()) {
      return
    }
    if !mentions {
      plan_error(1)
      return
    }
    self.fail(
      @types.not_supported("FORCESEEK with this predicate or index"),
      line,
    )
  }
}
