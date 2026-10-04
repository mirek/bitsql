///|
/// Bottom-up-free rewrite of an AST expression: `f` may replace a node
/// (returning Some); otherwise children are rewritten. Subquery bodies are
/// not entered (they bind in their own scope).
fn map_expr(
  e : @ast.Expr,
  f : (@ast.Expr) -> @ast.Expr? raise @types.SqlError,
) -> @ast.Expr raise @types.SqlError {
  match f(e) {
    Some(r) => return r
    None => ()
  }
  let m = (x : @ast.Expr) => map_expr(x, f)
  let mo = (x : @ast.Expr?) => {
    match x {
      Some(y) => Some(map_expr(y, f))
      None => None
    }
  }
  let kind : @ast.ExprKind = match e.kind {
    Unary(op, a) => Unary(op, m(a))
    Binary(op, a, b) => Binary(op, m(a), m(b))
    Compare(op, a, b) => Compare(op, m(a), m(b))
    Quantified(op, q, a, query) => Quantified(op, q, m(a), query)
    Not(a) => Not(m(a))
    And(a, b) => And(m(a), m(b))
    Or(a, b) => Or(m(a), m(b))
    IsNull(a, negated~) => IsNull(m(a), negated~)
    Like(a, b, escape~, negated~) =>
      Like(m(a), m(b), escape=mo(escape), negated~)
    Between(a, b, c, negated~) => Between(m(a), m(b), m(c), negated~)
    InList(a, items, negated~) => InList(m(a), items.map(m), negated~)
    InQuery(a, q, negated~) => InQuery(m(a), q, negated~)
    Case(operand~, whens~, else_~) =>
      Case(
        operand=mo(operand),
        whens=whens.map(w => (m(w.0), m(w.1))),
        else_=mo(else_),
      )
    Cast(a, tn, try_~) => Cast(m(a), tn, try_~)
    Convert(tn, a, style~, try_~) => Convert(tn, m(a), style=mo(style), try_~)
    Parse(a, tn, culture~, try_~) => Parse(m(a), tn, culture=mo(culture), try_~)
    Call(c) => {
      let over = match c.over {
        Some(o) =>
          Some(@ast.Over::{
            ..o,
            partition_by: o.partition_by.map(m),
            order_by: o.order_by.map(i => { ..i, expr: m(i.expr), }),
          })
        None => None
      }
      Call({
        ..c,
        args: c.args.map(m),
        within_group: c.within_group.map(i => { ..i, expr: m(i.expr), }),
        over,
      })
    }
    Collate(a, id) => Collate(m(a), id)
    AtTimeZone(a, b) => AtTimeZone(m(a), m(b))
    Paren(a) => Paren(m(a))
    MethodCall(t, n, args) => MethodCall(m(t), n, args.map(m))
    other => other
  }
  { kind, span: e.span, }
}

///|
/// True when `pred` holds for some node of `e` (subquery bodies excluded
/// unless `subqueries`).
fn any_expr(
  e : @ast.Expr,
  pred : (@ast.Expr) -> Bool,
  subqueries? : Bool = false,
) -> Bool {
  let found = Ref(false)
  ignore(
    map_expr(e, x => {
      if found.val {
        return Some(x)
      }
      if pred(x) {
        found.val = true
        return Some(x)
      }
      if subqueries &&
        x.kind
        is (Subquery(_)
        | Exists(_)
        | InQuery(_, _, ..)
        | Quantified(_, _, _, _)) {
        found.val = true
        return Some(x)
      }
      None
    }) catch {
      _ => e
    },
  )
  found.val
}

///|
let aggregate_names : Array[String] = [
  "COUNT", "COUNT_BIG", "SUM", "AVG", "MIN", "MAX", "STRING_AGG", "STDEV", "STDEVP",
  "VAR", "VARP", "GROUPING", "GROUPING_ID", "CHECKSUM_AGG", "APPROX_COUNT_DISTINCT",
  "JSON_ARRAYAGG", "JSON_OBJECTAGG",
]

///|
/// An aggregate call (not windowed).
fn is_aggregate(e : @ast.Expr) -> Bool {
  match e.kind {
    Call(c) =>
      c.over is None &&
      c.name.parts.length() == 1 &&
      aggregate_names.contains(c.name.base().to_upper())
    _ => false
  }
}

///|
fn is_window(e : @ast.Expr) -> Bool {
  match e.kind {
    Call(c) => c.over is Some(_)
    _ => false
  }
}

///|
/// True when `e` contains an aggregate call outside subqueries (DML
/// contexts use it for 157/158).
pub fn has_aggregate(e : @ast.Expr) -> Bool {
  any_expr(e, is_aggregate)
}

///|
fn has_window(e : @ast.Expr) -> Bool {
  any_expr(e, is_window)
}

///|
/// Span-insensitive structural key of an expression (GROUP BY matching).
fn expr_key(e : @ast.Expr) -> String {
  e.to_sexp().to_lower()
}

///|
/// True when a select list or predicate uses NEXT VALUE FOR (outside nested
/// subqueries, which are checked when they bind).
fn uses_next_value(exprs : Array[@ast.Expr]) -> Bool raise @types.SqlError {
  let mut found = false
  for e in exprs {
    ignore(
      map_expr(e, x => {
        if x.kind is NextValueFor(_) {
          found = true
        }
        None
      }),
    )
  }
  found
}

///|
fn select_exprs(s : @ast.Select) -> Array[@ast.Expr] {
  let out = s.items.filter_map(i => {
    match i.kind {
      ExprItem(e, ..) => Some(e)
      Assign(_, _, e) => Some(e)
      _ => None
    }
  })
  match s.where_ {
    Some(w) => out.push(w)
    None => ()
  }
  out
}

///|
fn body_uses_next_value(b : @ast.QueryBody) -> Bool raise @types.SqlError {
  match b {
    Select(s) => uses_next_value(select_exprs(s))
    Nested(q) => body_uses_next_value(q.body)
    SetOperation(_, l, r) => body_uses_next_value(l) || body_uses_next_value(r)
  }
}

///|
/// 11719 / 11721: contexts where NEXT VALUE FOR is not allowed (captured:
/// sequence/errors).
fn check_next_value_context(
  q : @ast.Query,
  subquery : Bool,
) -> Unit raise @types.SqlError {
  match q.body {
    Select(s) if subquery && uses_next_value(select_exprs(s)) =>
      raise @types.sql_error(
        11719,
        "NEXT VALUE FOR function is not allowed in check constraints, default objects, computed columns, views, user-defined functions, user-defined aggregates, user-defined table types, sub-queries, common table expressions, derived tables or return statements.",
        severity=15,
      )
    Select(s) if s.distinct && uses_next_value(select_exprs(s)) =>
      raise next_value_set_op()
    SetOperation(_, _, _) as b if body_uses_next_value(b) =>
      raise next_value_set_op()
    _ => ()
  }
}

///|
fn next_value_set_op() -> @types.SqlError {
  @types.sql_error(
    11721,
    "NEXT VALUE FOR function cannot be used directly in a statement that uses a DISTINCT, UNION, UNION ALL, EXCEPT or INTERSECT operator.",
    severity=15,
  )
}

///|
/// A NULL literal argument, possibly parenthesized or with unary plus.
pub fn is_null_argument(e : @ast.Expr) -> Bool {
  match e.kind {
    Null => true
    Paren(x) | Unary(Plus, x) => is_null_argument(x)
    _ => false
  }
}

///|
/// The innermost COUNT/COUNT_BIG/SUM/AVG call over a NULL literal in `e`
/// (lower-case name): SQL Server rejects it with 8117 (captured: msduck
/// count-null-compilation, COUNT(SUM(NULL)) names sum, SUM(COUNT(NULL))
/// count).
fn null_aggregate(e : @ast.Expr) -> String? {
  let mut found : String? = None
  ignore(
    any_expr(e, x => {
      match x.kind {
        Call(c) if found is None &&
          c.over is None &&
          !c.star &&
          c.args.length() == 1 => {
          let n = c.name.base().to_lower()
          if ["count", "count_big", "sum", "avg"].contains(n) {
            if is_null_argument(c.args[0]) {
              found = Some(n)
            } else {
              match null_aggregate(c.args[0]) {
                Some(inner) => found = Some(inner)
                None => ()
              }
            }
          }
        }
        _ => ()
      }
      found is Some(_)
    }),
  )
  found
}
