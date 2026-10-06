// Compact S-expression rendering for snapshot tests and debugging. Spans and
// module definitions are omitted.

///|
priv struct W {
  sb : StringBuilder
}

///|
fn W::s(self : W, text : String) -> Unit {
  self.sb.write_string(text)
}

///|
/// `(tag` ... `)`
fn W::open(self : W, tag : String) -> Unit {
  self.sb.write_char('(')
  self.sb.write_string(tag)
}

///|
fn W::close(self : W) -> Unit {
  self.sb.write_char(')')
}

///|
fn W::sp(self : W) -> Unit {
  self.sb.write_char(' ')
}

///|
fn W::atom(self : W, text : String) -> Unit {
  self.sp()
  self.s(text)
}

///|
fn ident_text(i : Ident) -> String {
  if i.quoted {
    "[" + i.name + "]"
  } else {
    i.name
  }
}

///|
fn parts_text(parts : Array[Ident]) -> String {
  parts.map(ident_text).join(".")
}

///|
/// `a.[b c]`
pub fn ObjectName::to_sexp(self : ObjectName) -> String {
  parts_text(self.parts)
}

///|
/// `nvarchar(max)`, `decimal(10,2)`, `dbo.t`
pub fn TypeName::to_sexp(self : TypeName) -> String {
  let base = match self.schema {
    Some(s) => ident_text(s) + "." + self.name
    None => self.name
  }
  if self.args.length() == 0 {
    base
  } else {
    let args = self.args.map(a => {
      match a {
        Num(n) | Named(n) => n
        Max => "max"
      }
    })
    base + "(" + args.join(",") + ")"
  }
}

///|
fn bin_text(op : BinOp) -> String {
  match op {
    ConcatSql => "||"
    Add => "+"
    Sub => "-"
    Mul => "*"
    Div => "/"
    Mod => "%"
    BitAnd => "&"
    BitOr => "|"
    BitXor => "^"
  }
}

///|
fn cmp_text(op : CmpOp) -> String {
  match op {
    Eq => "="
    Ne => "<>"
    Lt => "<"
    Le => "<="
    Gt => ">"
    Ge => ">="
    NotLt => "!<"
    NotGt => "!>"
  }
}

///|
fn assign_text(op : AssignOp) -> String {
  match op {
    Assign => "="
    AddAssign => "+="
    SubAssign => "-="
    MulAssign => "*="
    DivAssign => "/="
    ModAssign => "%="
    AndAssign => "&="
    OrAssign => "|="
    XorAssign => "^="
  }
}

///|
fn quote(s : String) -> String {
  "'" + s.replace_all(old="'", new="''") + "'"
}

///|
fn W::expr(self : W, e : Expr) -> Unit {
  match e.kind {
    Null => self.s("NULL")
    Default => self.s("DEFAULT")
    IntLit(t) | DecimalLit(t) | FloatLit(t) | MoneyLit(t) | BinaryLit(t) =>
      self.s(t)
    StrLit(t, national~) => self.s((if national { "N" } else { "" }) + quote(t))
    Var(v) | GlobalVar(v) => self.s(v)
    Column(parts) => self.s(parts_text(parts))
    Unary(op, x) => {
      self.open(
        match op {
          Neg => "-"
          Plus => "+"
          BitNot => "~"
        },
      )
      self.sp()
      self.expr(x)
      self.close()
    }
    Binary(op, a, b) => self.node2(bin_text(op), a, b)
    Compare(op, a, b) => self.node2(cmp_text(op), a, b)
    Quantified(op, q, a, query) => {
      self.open(cmp_text(op))
      self.atom(
        match q {
          All => "all"
          Any => "any"
          Some_ => "some"
        },
      )
      self.sp()
      self.expr(a)
      self.sp()
      self.query(query)
      self.close()
    }
    Not(x) => {
      self.open("not")
      self.sp()
      self.expr(x)
      self.close()
    }
    And(a, b) => self.node2("and", a, b)
    Or(a, b) => self.node2("or", a, b)
    IsNull(x, negated~) => {
      self.open(if negated { "is-not-null" } else { "is-null" })
      self.sp()
      self.expr(x)
      self.close()
    }
    Like(a, b, escape~, negated~) => {
      self.open(if negated { "not-like" } else { "like" })
      self.sp()
      self.expr(a)
      self.sp()
      self.expr(b)
      if escape is Some(x) {
        self.s(" (escape ")
        self.expr(x)
        self.close()
      }
      self.close()
    }
    Between(a, lo, hi, negated~) => {
      self.open(if negated { "not-between" } else { "between" })
      for x in [a, lo, hi] {
        self.sp()
        self.expr(x)
      }
      self.close()
    }
    InList(a, items, negated~) => {
      self.open(if negated { "not-in" } else { "in" })
      self.sp()
      self.expr(a)
      for x in items {
        self.sp()
        self.expr(x)
      }
      self.close()
    }
    InQuery(a, q, negated~) => {
      self.open(if negated { "not-in" } else { "in" })
      self.sp()
      self.expr(a)
      self.sp()
      self.query(q)
      self.close()
    }
    Exists(q) => {
      self.open("exists")
      self.sp()
      self.query(q)
      self.close()
    }
    Subquery(q) => {
      self.open("subquery")
      self.sp()
      self.query(q)
      self.close()
    }
    Case(operand~, whens~, else_~) => {
      self.open("case")
      if operand is Some(o) {
        self.sp()
        self.expr(o)
      }
      for w in whens {
        self.s(" (when ")
        self.expr(w.0)
        self.sp()
        self.expr(w.1)
        self.close()
      }
      if else_ is Some(x) {
        self.s(" (else ")
        self.expr(x)
        self.close()
      }
      self.close()
    }
    Cast(x, ty, try_~) => {
      self.open(if try_ { "try-cast" } else { "cast" })
      self.sp()
      self.expr(x)
      self.atom(ty.to_sexp())
      self.close()
    }
    Convert(ty, x, style~, try_~) => {
      self.open(if try_ { "try-convert" } else { "convert" })
      self.atom(ty.to_sexp())
      self.sp()
      self.expr(x)
      if style is Some(s) {
        self.sp()
        self.expr(s)
      }
      self.close()
    }
    Parse(x, ty, culture~, try_~) => {
      self.open(if try_ { "try-parse" } else { "parse" })
      self.sp()
      self.expr(x)
      self.atom(ty.to_sexp())
      if culture is Some(c) {
        self.sp()
        self.expr(c)
      }
      self.close()
    }
    Call(c) => self.call(c)
    Collate(x, c) => {
      self.open("collate")
      self.sp()
      self.expr(x)
      self.atom(c.name)
      self.close()
    }
    AtTimeZone(x, z) => self.node2("at-time-zone", x, z)
    NextValueFor(n, over) => {
      self.open("next-value-for")
      self.atom(n.to_sexp())
      if over is Some(o) {
        self.over(o)
      }
      self.close()
    }
    Paren(x) => {
      self.open("paren")
      self.sp()
      self.expr(x)
      self.close()
    }
    MethodCall(target, name, args) => {
      self.open("method")
      self.atom(ident_text(name))
      self.sp()
      self.expr(target)
      for a in args {
        self.sp()
        self.expr(a)
      }
      self.close()
    }
  }
}

///|
fn W::node2(self : W, tag : String, a : Expr, b : Expr) -> Unit {
  self.open(tag)
  self.sp()
  self.expr(a)
  self.sp()
  self.expr(b)
  self.close()
}

///|
fn W::call(self : W, c : FuncCall) -> Unit {
  if c.niladic {
    self.open("call")
    self.atom(c.name.to_sexp())
    self.close()
    return
  }
  self.open("call")
  self.atom(c.name.to_sexp())
  if c.distinct {
    self.atom("distinct")
  }
  if c.star {
    self.atom("*")
  }
  for a in c.args {
    self.sp()
    self.expr(a)
  }
  if c.within_group.length() > 0 {
    self.s(" (within-group")
    self.order_items(c.within_group)
    self.close()
  }
  if c.over is Some(o) {
    self.over(o)
  }
  self.close()
}

///|
fn W::over(self : W, o : Over) -> Unit {
  self.s(" (over")
  if o.partition_by.length() > 0 {
    self.s(" (partition-by")
    for p in o.partition_by {
      self.sp()
      self.expr(p)
    }
    self.close()
  }
  if o.order_by.length() > 0 {
    self.s(" (order-by")
    self.order_items(o.order_by)
    self.close()
  }
  if o.frame is Some(f) {
    self.s(
      match f.unit {
        Rows => " (rows"
        Range => " (range"
      },
    )
    self.frame_bound(f.start)
    if f.end is Some(e) {
      self.frame_bound(e)
    }
    self.close()
  }
  self.close()
}

///|
fn W::frame_bound(self : W, b : FrameBound) -> Unit {
  match b {
    UnboundedPreceding => self.atom("unbounded-preceding")
    UnboundedFollowing => self.atom("unbounded-following")
    CurrentRow => self.atom("current-row")
    Preceding(e) => {
      self.s(" (preceding ")
      self.expr(e)
      self.close()
    }
    Following(e) => {
      self.s(" (following ")
      self.expr(e)
      self.close()
    }
  }
}

///|
fn W::order_items(self : W, items : Array[OrderItem]) -> Unit {
  for i in items {
    self.sp()
    if i.desc {
      self.s("(desc ")
      self.expr(i.expr)
      self.close()
    } else {
      self.expr(i.expr)
    }
  }
}

///|
fn W::query(self : W, q : Query) -> Unit {
  let plain = q.ctes.length() == 0 &&
    q.order_by.length() == 0 &&
    q.offset is None &&
    q.for_clause is None &&
    q.options.length() == 0
  if plain {
    self.body(q.body)
    return
  }
  self.open("query")
  if q.ctes.length() > 0 {
    self.ctes(q.ctes)
  }
  self.sp()
  self.body(q.body)
  if q.order_by.length() > 0 {
    self.s(" (order-by")
    self.order_items(q.order_by)
    self.close()
  }
  if q.offset is Some(o) {
    self.s(" (offset ")
    self.expr(o)
    self.close()
  }
  if q.fetch is Some(f) {
    self.s(" (fetch ")
    self.expr(f)
    self.close()
  }
  match q.for_clause {
    Some(ForJson(mode~, root~, include_null_values~, without_array_wrapper~)) => {
      self.s(" (for-json ")
      self.s(
        match mode {
          JsonPath => "path"
          JsonAuto => "auto"
        },
      )
      if root is Some(r) {
        self.s(" (root " + quote(r) + ")")
      }
      if include_null_values {
        self.atom("include-null-values")
      }
      if without_array_wrapper {
        self.atom("without-array-wrapper")
      }
      self.close()
    }
    Some(ForXml(mode~, element~, options~)) => {
      self.s(" (for-xml " + mode)
      if element is Some(e) {
        self.atom(quote(e))
      }
      for o in options {
        self.atom(o)
      }
      self.close()
    }
    Some(ForBrowse) => self.s(" (for-browse)")
    None => ()
  }
  self.hints(q.options)
  self.close()
}

///|
fn W::hints(self : W, hints : Array[QueryHint]) -> Unit {
  if hints.length() > 0 {
    self.s(" (option")
    for h in hints {
      self.atom(quote(h.text))
    }
    self.close()
  }
}

///|
fn W::ctes(self : W, ctes : Array[Cte]) -> Unit {
  self.s(" (with")
  for c in ctes {
    self.s(" (" + ident_text(c.name))
    if c.columns.length() > 0 {
      self.s(" (" + c.columns.map(ident_text).join(" ") + ")")
    }
    self.sp()
    self.query(c.query)
    self.close()
  }
  self.close()
}

///|
fn W::body(self : W, b : QueryBody) -> Unit {
  match b {
    Select(s) => self.select(s)
    SetOperation(op, l, r) => {
      self.open(
        match op {
          Union => "union"
          UnionAll => "union-all"
          Except => "except"
          Intersect => "intersect"
        },
      )
      self.sp()
      self.body(l)
      self.sp()
      self.body(r)
      self.close()
    }
    Nested(q) => {
      self.open("nested")
      self.sp()
      self.query(q)
      self.close()
    }
  }
}

///|
fn W::top(self : W, t : Top?) -> Unit {
  if t is Some(t) {
    self.s(" (top ")
    self.expr(t.count)
    if t.percent {
      self.atom("percent")
    }
    if t.with_ties {
      self.atom("with-ties")
    }
    self.close()
  }
}

///|
fn W::select_items(self : W, items : Array[SelectItem]) -> Unit {
  for i in items {
    self.sp()
    match i.kind {
      Star(q) =>
        if q.length() == 0 {
          self.s("*")
        } else {
          self.s(parts_text(q) + ".*")
        }
      ExprItem(e, alias_~) =>
        match alias_ {
          Some(a) => {
            self.s("(as ")
            self.expr(e)
            self.atom(ident_text(a))
            self.close()
          }
          None => self.expr(e)
        }
      Assign(v, op, e) => {
        self.open(assign_text(op))
        self.atom(v)
        self.sp()
        self.expr(e)
        self.close()
      }
    }
  }
}

///|
fn W::select(self : W, s : Select) -> Unit {
  self.open("select")
  if s.distinct {
    self.atom("distinct")
  }
  self.top(s.top)
  self.select_items(s.items)
  if s.into is Some(n) {
    self.s(" (into " + n.to_sexp() + ")")
  }
  if s.from.length() > 0 {
    self.s(" (from")
    for t in s.from {
      self.sp()
      self.table_ref(t)
    }
    self.close()
  }
  self.where_(s.where_)
  if s.group_by.length() > 0 {
    self.s(" (group-by")
    for g in s.group_by {
      self.sp()
      self.group_item(g)
    }
    self.close()
  }
  if s.having is Some(h) {
    self.s(" (having ")
    self.expr(h)
    self.close()
  }
  self.close()
}

///|
fn W::where_(self : W, w : Expr?) -> Unit {
  if w is Some(w) {
    self.s(" (where ")
    self.expr(w)
    self.close()
  }
}

///|
fn W::exprs(self : W, es : Array[Expr]) -> Unit {
  self.s("(")
  for i, e in es {
    if i > 0 {
      self.sp()
    }
    self.expr(e)
  }
  self.close()
}

///|
fn W::group_item(self : W, g : GroupItem) -> Unit {
  match g {
    GroupExpr(e) => self.expr(e)
    GroupEmpty => self.s("()")
    GroupTuple(es) => self.exprs(es)
    Rollup(units) | Cube(units) => {
      self.open(if g is Rollup(_) { "rollup" } else { "cube" })
      for u in units {
        self.sp()
        self.exprs(u)
      }
      self.close()
    }
    GroupingSets(sets) => {
      self.open("grouping-sets")
      for x in sets {
        self.sp()
        self.group_item(x)
      }
      self.close()
    }
  }
}

///|
fn W::alias_cols(self : W, alias_ : Ident?, columns : Array[Ident]) -> Unit {
  if alias_ is Some(a) {
    self.s(" (as " + ident_text(a))
    for c in columns {
      self.atom(ident_text(c))
    }
    self.close()
  }
}

///|
fn W::table_hints(self : W, hints : Array[TableHint]) -> Unit {
  if hints.length() > 0 {
    self.s(" (with")
    for h in hints {
      if h.args.length() == 0 {
        self.atom(h.name)
      } else {
        self.atom(h.name + "(" + h.args.join(",") + ")")
      }
    }
    self.close()
  }
}

///|
fn W::table_ref(self : W, t : TableRef) -> Unit {
  match t.kind {
    Table(n, alias_~, hints~) => {
      self.open("table")
      self.atom(n.to_sexp())
      self.alias_cols(alias_, [])
      self.table_hints(hints)
      self.close()
    }
    TableVar(v, alias_~, hints~) => {
      self.open("table")
      self.atom(v)
      self.alias_cols(alias_, [])
      self.table_hints(hints)
      self.close()
    }
    Derived(q, alias_~, columns~) => {
      self.open("derived")
      self.sp()
      self.query(q)
      self.alias_cols(alias_, columns)
      self.close()
    }
    Values(rows, alias_~, columns~) => {
      self.open("values")
      for r in rows {
        self.sp()
        self.exprs(r)
      }
      self.alias_cols(Some(alias_), columns)
      self.close()
    }
    VectorSearch(v) => {
      self.open("vector-search")
      self.atom(v.table.to_sexp())
      self.alias_cols(v.source_alias, [])
      self.atom(ident_text(v.column))
      self.sp()
      self.expr(v.query)
      self.atom(quote(v.metric))
      self.sp()
      self.expr(v.top)
      self.alias_cols(v.alias_, [])
      self.close()
    }
    TableFunc(n, args, openjson_with~, alias_~, columns~) => {
      self.open("tvf")
      self.atom(n.to_sexp())
      for a in args {
        self.sp()
        self.expr(a)
      }
      if openjson_with is Some(cols) {
        self.s(" (with-schema")
        for c in cols {
          self.s(" (" + ident_text(c.name) + " " + c.type_.to_sexp())
          if c.path is Some(p) {
            self.atom(quote(p))
          }
          if c.as_json {
            self.atom("as-json")
          }
          self.close()
        }
        self.close()
      }
      self.alias_cols(alias_, columns)
      self.close()
    }
    Pivot(src, clause, alias_~) => {
      let parts = (ps : Array[Ident]) => ps.map(ident_text).join(".")
      match clause {
        Pivot(agg~, value~, column~, values~) => {
          self.open("pivot")
          self.sp()
          self.table_ref(src)
          self.s(" (" + agg.to_sexp() + " " + parts(value) + ")")
          self.atom(parts(column))
          self.s(" (in " + values.map(ident_text).join(" ") + ")")
        }
        Unpivot(value~, name~, columns~) => {
          self.open("unpivot")
          self.sp()
          self.table_ref(src)
          self.atom(ident_text(value))
          self.atom(ident_text(name))
          self.s(" (in " + columns.map(parts).join(" ") + ")")
        }
      }
      self.alias_cols(Some(alias_), [])
      self.close()
    }
    Nodes(target, args, alias_~, columns~) => {
      self.open("nodes")
      self.sp()
      self.expr(target)
      for a in args {
        self.sp()
        self.expr(a)
      }
      self.alias_cols(alias_, columns)
      self.close()
    }
    Join(kind, l, r, on~, hint~) => {
      self.open(
        match kind {
          Inner => "join"
          Left => "left-join"
          Right => "right-join"
          Full => "full-join"
          Cross => "cross-join"
          CrossApply => "cross-apply"
          OuterApply => "outer-apply"
        },
      )
      if hint is Some(h) {
        self.atom(h)
      }
      self.sp()
      self.table_ref(l)
      self.sp()
      self.table_ref(r)
      if on is Some(c) {
        self.s(" (on ")
        self.expr(c)
        self.close()
      }
      self.close()
    }
  }
}

///|
pub fn Expr::to_sexp(self : Expr) -> String {
  let w : W = { sb: StringBuilder(), }
  w.expr(self)
  w.sb.to_string()
}

///|
pub fn Query::to_sexp(self : Query) -> String {
  let w : W = { sb: StringBuilder(), }
  w.query(self)
  w.sb.to_string()
}

///|
pub fn TableRef::to_sexp(self : TableRef) -> String {
  let w : W = { sb: StringBuilder(), }
  w.table_ref(self)
  w.sb.to_string()
}

///|
pub fn Stmt::to_sexp(self : Stmt) -> String {
  let w : W = { sb: StringBuilder(), }
  w.stmt(self)
  w.sb.to_string()
}
