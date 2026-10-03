///|
/// A bound query: its plan and the result-set description.
pub(all) struct BoundQuery {
  plan : @ir.Plan
  columns : Array[@ir.ResultColumn]
  /// ORDER token ordinals (1-based projected positions, 0 = hidden key);
  /// empty when no ORDER BY.
  order : Array[Int]
} derive(Debug)

///|
fn item_name(item : @ast.SelectItem) -> String {
  match item.kind {
    ExprItem(_, alias_=Some(a)) => a.name
    ExprItem({ kind: Column(parts), .. }, alias_=None) =>
      parts[parts.length() - 1].name
    _ => ""
  }
}

///|
/// Binds FROM into a plan and the columns it exposes.
fn bind_from(
  env : Env,
  from : Array[@ast.TableRef],
) -> (@ir.Plan, Array[ColumnRef]) raise @types.SqlError {
  if from.is_empty() {
    return (OneRow, [])
  }
  if from.length() > 1 {
    raise @types.not_supported("comma joins")
  }
  match from[0].kind {
    Values(rows, alias_~, columns~) => {
      let bound = rows.map(r => r.map(e => bind_expr(env, e)))
      let width = bound[0].length()
      for r in bound {
        if r.length() != width {
          raise err(
            10709, "The number of columns for each row in a table value constructor must be the same.",
          )
        }
      }
      if columns.length() != width {
        raise err(
          8158,
          "'\{alias_.name}' has more columns than were specified in the column list.",
        )
      }
      let cols = []
      let typed = bound.copy()
      for j in 0..<width {
        let t = unify_types(bound.map(r => r[j].ty))
        let nullable = bound.iter().any(r => r[j].nullable)
        cols.push(ColumnRef::{
          qualifier: alias_.name.to_lower(),
          name: columns[j].name,
          ty: t,
          nullable,
          origin: Computed,
        })
      }
      let rows2 = typed.map(r => {
        let out = []
        for j, e in r {
          out.push(coerce(e, cols[j].ty)) |> ignore_raise
        }
        out
      })
      (Values(rows2), cols)
    }
    _ => raise @types.not_supported("this FROM clause")
  }
}

///|
fn ignore_raise(_u : Unit) -> Unit {
  ()
}

///|
/// Binds a SELECT body (no set operations).
fn bind_select(
  env : Env,
  s : @ast.Select,
) -> (@ir.Plan, Array[@ir.ResultColumn], Array[@ir.Expr], Env) raise @types.SqlError {
  if !s.group_by.is_empty() || s.having is Some(_) {
    raise @types.not_supported("GROUP BY / HAVING")
  }
  if s.into is Some(_) {
    raise @types.not_supported("SELECT INTO")
  }
  let (source, cols) = bind_from(env, s.from)
  let inner = if s.from.is_empty() { env } else { env.with_columns(cols) }
  let plan = match s.where_ {
    Some(w) => @ir.Plan::Filter(source, bind_expr(inner, w))
    None => source
  }
  let exprs = []
  let result = []
  for item in s.items {
    match item.kind {
      Star(qualifier) => {
        if cols.is_empty() {
          raise err(263, "Must specify table to select from.", severity=16)
        }
        let q = qualifier.map(i => i.name.to_lower())
        for i, c in cols {
          if q.is_empty() || q[q.length() - 1] == c.qualifier {
            exprs.push(mk(Col(i), c.ty, c.nullable))
            result.push(@ir.ResultColumn::{
              name: c.name,
              ty: c.ty,
              nullable: c.nullable,
              origin: c.origin,
            })
          }
        }
      }
      ExprItem(e, ..) => {
        let b = bind_expr(inner, e)
        let origin : @ir.Origin = match (e.kind, b.kind) {
          (Column(_), Col(i)) => cols[i].origin
          _ => Computed
        }
        exprs.push(b)
        result.push(@ir.ResultColumn::{
          name: item_name(item),
          ty: b.ty,
          nullable: b.nullable,
          origin,
        })
      }
      Assign(_, _, _) =>
        raise err(
          141,
          "A SELECT statement that assigns a value to a variable must not be combined with data-retrieval operations.",
          severity=15,
        )
    }
  }
  (plan, result, exprs, inner)
}

///|
/// Binds a query that returns rows to the client.
pub fn bind_query(
  env : Env,
  q : @ast.Query,
) -> BoundQuery raise @types.SqlError {
  if !q.ctes.is_empty() {
    raise @types.not_supported("common table expressions")
  }
  if q.for_clause is Some(_) {
    raise @types.not_supported("FOR JSON / FOR XML")
  }
  match q.body {
    Select(s) => {
      let (plan, result, exprs, inner) = bind_select(env, s)
      let mut plan = plan
      let order = []
      if !q.order_by.is_empty() {
        let keys = []
        for o in q.order_by {
          // ORDER BY may name an output alias or position, or any source expression.
          let (key, ordinal) = order_key(inner, o.expr, result, exprs)
          keys.push(@ir.SortKey::{
            expr: key,
            desc: o.desc,
            collation: key.ty.collation(),
          })
          order.push(ordinal)
        }
        plan = Sort(plan, keys)
      }
      plan = Project(plan, exprs)
      if s.distinct {
        plan = Distinct(plan, result.map(c => c.ty.collation()))
      }
      plan = apply_top(env, plan, s.top, q.offset, q.fetch)
      { plan, columns: result, order, }
    }
    SetOperation(UnionAll, _, _) => {
      let parts = []
      flatten_union_all(q.body, parts)
      let bound = parts.map(p => {
        match p {
          Select(s) => {
            let (plan, result, exprs, _) = bind_select(env, s)
            (@ir.Plan::Project(plan, exprs), result)
          }
          _ => raise @types.not_supported("nested set operations")
        }
      })
      let width = bound[0].1.length()
      for b in bound {
        if b.1.length() != width {
          raise err(
            205, "All queries combined using a UNION, INTERSECT or EXCEPT operator must have an equal number of expressions in their target lists.",
          )
        }
      }
      let columns = []
      for j in 0..<width {
        let t = unify_types(bound.map(b => b.1[j].ty))
        columns.push(@ir.ResultColumn::{
          name: bound[0].1[j].name,
          ty: t,
          nullable: bound.iter().any(b => b.1[j].nullable),
          origin: SetOperation,
        })
      }
      if !q.order_by.is_empty() {
        raise @types.not_supported("ORDER BY on UNION")
      }
      // Branches convert to the unified column types when executed.
      let plans = bound.map(b => {
        let exprs = []
        for j, c in b.1 {
          exprs.push(coerce(mk(Col(j), c.ty, c.nullable), columns[j].ty))
        }
        @ir.Plan::Project(b.0, exprs)
      })
      { plan: UnionAll(plans), columns, order: [], }
    }
    _ => raise @types.not_supported("UNION / EXCEPT / INTERSECT")
  }
}

///|
fn flatten_union_all(b : @ast.QueryBody, out : Array[@ast.QueryBody]) -> Unit {
  match b {
    SetOperation(UnionAll, l, r) => {
      flatten_union_all(l, out)
      flatten_union_all(r, out)
    }
    Nested({ body, order_by: [], ctes: [], .. }) => flatten_union_all(body, out)
    other => out.push(other)
  }
}

///|
fn order_key(
  inner : Env,
  e : @ast.Expr,
  result : Array[@ir.ResultColumn],
  exprs : Array[@ir.Expr],
) -> (@ir.Expr, Int) raise @types.SqlError {
  match e.kind {
    IntLit(n) => {
      let i = parse_style(n)
      if i < 1 || i > exprs.length() {
        raise err(
          108,
          "The ORDER BY position number \{n} is out of range of the number of items in the select list.",
          severity=15,
        )
      }
      (exprs[i - 1], i)
    }
    Column([name]) => {
      for i, c in result {
        if c.name.to_lower() == name.name.to_lower() && c.name != "" {
          return (exprs[i], i + 1)
        }
      }
      (bind_expr(inner, e), 0)
    }
    _ => (bind_expr(inner, e), 0)
  }
}

///|
fn apply_top(
  env : Env,
  plan : @ir.Plan,
  top : @ast.Top?,
  offset : @ast.Expr?,
  fetch : @ast.Expr?,
) -> @ir.Plan raise @types.SqlError {
  match top {
    Some(t) => {
      if t.percent || t.with_ties {
        raise @types.not_supported("TOP PERCENT / WITH TIES")
      }
      Limit(plan, None, Some(coerce(bind_expr(env, t.count), BigInt)))
    }
    None =>
      if offset is None && fetch is None {
        plan
      } else {
        let off = match offset {
          Some(o) => Some(coerce(bind_expr(env, o), BigInt))
          None => None
        }
        let cnt = match fetch {
          Some(f) => Some(coerce(bind_expr(env, f), BigInt))
          None => None
        }
        Limit(plan, off, cnt)
      }
  }
}
