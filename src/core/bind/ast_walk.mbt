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
    NextValueFor(n, Some(o)) =>
      NextValueFor(
        n,
        Some({ ..o, order_by: o.order_by.map(i => { ..i, expr: m(i.expr), }), }),
      )
    // No child changed, and Expr's fields are immutable.
    _ => return e
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
        if x.kind is NextValueFor(_, _) {
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
    // captured (tail5/b1-next-value-over): TOP/OFFSET 11739, a plain NEXT
    // VALUE FOR in a query with ORDER BY 11723
    Select(s) if (s.top is Some(_) || q.offset is Some(_)) &&
      uses_next_value(select_exprs(s)) =>
      raise @types.sql_error(
        11739,
        "NEXT VALUE FOR function cannot be used if ROWCOUNT option has been set, or the query contains TOP or OFFSET.",
        severity=15,
      )
    Select(s) if !q.order_by.is_empty() &&
      select_exprs(s).iter().any(plain_next_value) =>
      raise @types.sql_error(
        11723,
        "NEXT VALUE FOR function cannot be used directly in a statement that contains an ORDER BY clause unless the OVER clause is specified.",
        severity=15,
      )
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

///|
/// 8117 for a COUNT/COUNT_BIG/SUM/AVG over a NULL literal anywhere in `e`
/// (it wins over 157 in an UPDATE SET list; captured: msduck-runs
/// count-null-compilation#064).
pub fn null_aggregate_error(e : @ast.Expr) -> @types.SqlError? {
  null_aggregate(e).map(n => {
    err(8117, "Operand data type NULL is invalid for \{n} operator.")
  })
}

///|
fn has_next_value(e : @ast.Expr) -> Bool {
  any_expr(e, x => x.kind is NextValueFor(_, _))
}

///|
/// 11720: NEXT VALUE FOR in WHERE / ORDER BY (captured:
/// tail5/b1-next-value-over).
fn next_value_misplaced() -> @types.SqlError {
  @types.sql_error(
    11720,
    "NEXT VALUE FOR function is not allowed in the TOP, OVER, OUTPUT, ON, WHERE, GROUP BY, HAVING, or ORDER BY clauses.",
    severity=15,
  )
}

///|
/// 11727: every NEXT VALUE FOR of one sequence in a select list needs the
/// same OVER clause (or none) (captured: tail5/b1-next-value-over).
fn check_next_value_overs(
  env : Env,
  items : Array[@ast.Expr?],
) -> Unit raise @types.SqlError {
  let seen : Map[String, String] = Map([])
  for item in items {
    guard item is Some(e) else { continue }
    ignore(
      map_expr(e, x => {
        guard x.kind is NextValueFor(name, over) else { return None }
        let key = match (env.catalog.sequence)(name) {
          Some((k, _)) => k
          None => return None
        }
        let shape = match over {
          Some(o) =>
            o.order_by
            .map(i => expr_key(i.expr) + (if i.desc { " desc" } else { "" }))
            .join(",")
          None => ""
        }
        match seen.get(key) {
          Some(s) if s != shape =>
            raise @types.sql_error(
              11727, "NEXT VALUE FOR functions for a given sequence object must have exactly the same OVER clause definition.",
            )
          _ => seen[key] = shape
        }
        None
      }),
    )
  }
}

///|
/// True when `e` uses NEXT VALUE FOR … OVER (outside subqueries).
pub fn has_next_value_over(e : @ast.Expr) -> Bool {
  any_expr(e, x => x.kind is NextValueFor(_, Some(_)))
}

///|
/// A NEXT VALUE FOR without OVER outside window function calls (inside one
/// it is 11720 when the call binds; captured: msduck
/// percentile-runtime-fraction#040).
fn plain_next_value(e : @ast.Expr) -> Bool {
  let mut found = false
  ignore(
    map_expr(e, x => {
      if is_window(x) {
        return Some(x)
      }
      if x.kind is NextValueFor(_, None) {
        found = true
      }
      None
    }) catch {
      _ => e
    },
  )
  found
}
