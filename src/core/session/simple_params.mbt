// SQL Server's simple parameterization, as far as it is observable: in an
// INSERT/UPDATE of a permanent table, run as a batch statement (not in a
// module), whose expressions use no variables, function calls or
// subqueries, string and binary literals become parameters of type
// varchar(8000) / nvarchar(4000) / varbinary(8000). That shows in the base
// type of values stored in sql_variant columns (SQL_VARIANT_PROPERTY
// MaxLength 8000 instead of the literal's length). Captured on SQL Server
// 17.0.5005 (variant/insert-values.sql, docs/reference/sql-variant.md):
// temp tables, procedures, statements with UPPER(...), (SELECT ...) or @x
// keep literal types; IF/BEGIN TRAN around the statement, CAST, COLLATE,
// `+`, multi-row VALUES and INSERT ... SELECT without FROM do not prevent
// it. Number literals keep their types either way.

///|
/// May these statement expressions be simply parameterized?
fn simple_param_exprs(exprs : Array[@ast.Expr]) -> Bool {
  let mut ok = true
  for e in exprs {
    walk_expr(e, x => {
      if x.kind
        is (Var(_)
        | GlobalVar(_)
        | Call(_)
        | Subquery(_)
        | Exists(_)
        | InQuery(_, _, ..)
        | Quantified(_, _, _, _)
        | NextValueFor(_)
        | Parse(_, _, ..)
        | AtTimeZone(_, _)) {
        ok = false
      }
    })
  }
  ok
}

///|
/// Applies simple parameterization to `env` when the statement qualifies.
fn Session::simple_params_env(
  self : Session,
  env : @bind.Env,
  target : Target,
  exprs : Array[@ast.Expr],
) -> @bind.Env {
  if target.scope == 0 && self.rt.nest_level == 0 && simple_param_exprs(exprs) {
    { ..env, literal_params: true, }
  } else {
    env
  }
}

///|
/// Expressions of an INSERT ... SELECT source that is a single SELECT
/// without FROM (None: not a simple shape, no parameterization).
fn simple_select_exprs(q : @ast.Query) -> Array[@ast.Expr]? {
  guard q.ctes.is_empty() && q.order_by.is_empty() && q.for_clause is None else {
    return None
  }
  guard q.body is Select(s) else { return None }
  guard s.from.is_empty() && s.top is None && !s.distinct && s.into is None else {
    return None
  }
  let out = []
  for it in s.items {
    match it.kind {
      ExprItem(e, ..) => out.push(e)
      _ => return None
    }
  }
  match s.where_ {
    Some(w) => out.push(w)
    None => ()
  }
  Some(out)
}
