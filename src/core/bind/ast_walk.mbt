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
  "VAR", "VARP", "GROUPING", "GROUPING_ID",
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
fn has_aggregate(e : @ast.Expr) -> Bool {
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
