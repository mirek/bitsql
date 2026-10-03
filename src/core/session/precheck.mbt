///|
/// Batch-level compile checks: a variable must be declared earlier in the
/// batch text (or be a parameter). SQL Server rejects the whole batch with
/// error 137 before running anything.
fn precheck_batch(
  stmts : Array[@ast.Stmt],
  params : Map[String, @bind.VarInfo],
) -> (@types.SqlError, Int)? {
  let declared : Set[String] = Set([])
  for k, _ in params {
    declared.add(k)
  }
  let mut failure : (@types.SqlError, Int)? = None
  fn check_name(name : String, line : Int) -> Unit {
    if failure is None && !declared.contains(name.to_lower()) {
      failure = Some(
        (
          @types.sql_error(
            137,
            "Must declare the scalar variable \"\{name}\".",
            state=2,
            severity=15,
          ),
          line,
        ),
      )
    }
  }

  fn expr(e : @ast.Expr, line : Int) -> Unit {
    walk_expr(e, fn(x) { if x.kind is Var(n) { check_name(n, x.span.line) } })
    ignore(line)
  }

  fn stmt(s : @ast.Stmt) -> Unit {
    let line = s.span.line
    match s.kind {
      Declare(vars) =>
        for v in vars {
          if v.init is Some(i) {
            expr(i, line)
          }
          declared.add(v.name.to_lower())
        }
      DeclareTable(name, _) => declared.add(name.to_lower())
      SetVar(n, _, e) => {
        check_name(n, line)
        expr(e, line)
      }
      Select(q) => query_vars(q, x => expr(x, line), n => check_name(n, line))
      Print(e) => expr(e, line)
      If(c, a, b) => {
        expr(c, line)
        stmt(a)
        if b is Some(x) {
          stmt(x)
        }
      }
      While(c, b) => {
        expr(c, line)
        stmt(b)
      }
      Block(list) => list.each(stmt)
      TryCatch(a, b) => {
        a.each(stmt)
        b.each(stmt)
      }
      RaisError(args, ..) | Throw(args) => args.each(x => expr(x, line))
      Return(Some(e)) => expr(e, line)
      _ => ()
    }
  }

  for s in stmts {
    stmt(s)
  }
  failure
}

///|
fn query_vars(
  q : @ast.Query,
  on_expr : (@ast.Expr) -> Unit,
  on_assign : (String) -> Unit,
) -> Unit {
  match q.body {
    Select(s) => {
      for item in s.items {
        match item.kind {
          ExprItem(e, ..) => on_expr(e)
          Assign(n, _, e) => {
            on_assign(n)
            on_expr(e)
          }
          Star(_) => ()
        }
      }
      if s.where_ is Some(w) {
        on_expr(w)
      }
    }
    _ => ()
  }
  for o in q.order_by {
    on_expr(o.expr)
  }
}

///|
/// Pre-order traversal of an expression tree (not into subqueries).
fn walk_expr(e : @ast.Expr, f : (@ast.Expr) -> Unit) -> Unit {
  f(e)
  match e.kind {
    Unary(_, a)
    | Not(a)
    | Paren(a)
    | IsNull(a, ..)
    | Cast(a, _, ..)
    | Collate(a, _) => walk_expr(a, f)
    Binary(_, a, b)
    | Compare(_, a, b)
    | And(a, b)
    | Or(a, b)
    | AtTimeZone(a, b) => {
      walk_expr(a, f)
      walk_expr(b, f)
    }
    Like(a, b, escape~, ..) => {
      walk_expr(a, f)
      walk_expr(b, f)
      if escape is Some(x) {
        walk_expr(x, f)
      }
    }
    Between(a, b, c, ..) => {
      walk_expr(a, f)
      walk_expr(b, f)
      walk_expr(c, f)
    }
    InList(a, items, ..) => {
      walk_expr(a, f)
      items.each(x => walk_expr(x, f))
    }
    Case(operand~, whens~, else_~) => {
      if operand is Some(o) {
        walk_expr(o, f)
      }
      for w in whens {
        walk_expr(w.0, f)
        walk_expr(w.1, f)
      }
      if else_ is Some(x) {
        walk_expr(x, f)
      }
    }
    Convert(_, a, style~, ..) => {
      walk_expr(a, f)
      if style is Some(s) {
        walk_expr(s, f)
      }
    }
    Call(c) => c.args.each(x => walk_expr(x, f))
    _ => ()
  }
}
