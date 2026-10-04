///|
/// Batch-level compile checks: a variable must be declared earlier in the
/// batch text (or be a parameter). SQL Server rejects the whole batch with
/// error 137 before running anything.
fn precheck_batch(
  stmts : Array[@ast.Stmt],
  params : Map[String, @bind.VarInfo],
  in_proc? : Bool = false,
) -> (@types.SqlError, Int)? {
  let declared : Set[String] = Set([])
  let temp_creates : Set[String] = Set([])
  // declared types, for RAISERROR substitution parameter checks
  let types : Map[String, @types.SqlType] = Map([])
  for k, v in params {
    declared.add(k)
    types[k] = v.ty
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
    walk_expr(e, fn(x) {
      match x.kind {
        Var(n) => check_name(n, x.span.line)
        // captured: COUNT(NULL) / COUNT_BIG(NULL), also parenthesized,
        // DISTINCT or windowed, is 8117 for the whole batch (msduck
        // count-null-compilation)
        Call(c) if failure is None && !c.star && c.args.length() == 1 => {
          let fname = c.name.base().to_lower()
          if (fname == "count" || fname == "count_big") &&
            @bind.is_null_argument(c.args[0]) {
            failure = Some(
              (
                @types.sql_error(
                  8117,
                  "Operand data type NULL is invalid for \{fname} operator.",
                ),
                x.span.line,
              ),
            )
          }
        }
        // captured: a style variable of a non-integer type is 8116 for the
        // whole batch (the DECLARE before it does not run)
        Convert(_, _, style=Some({ kind: Var(vn), .. }), ..) if failure is None =>
          match types.get(vn.to_lower()) {
            Some(t) if !(t.family() is FInteger) =>
              failure = Some(
                (
                  @types.sql_error(
                    8116,
                    "Argument data type \{t.base_name()} is invalid for argument 3 of convert function.",
                  ),
                  x.span.line,
                ),
              )
            _ => ()
          }
        _ => ()
      }
    })
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
          // a procedure body is compiled at CREATE: redeclaring a variable
          // or parameter is 134 there (captured: gaps-procedures #134)
          if in_proc && failure is None && declared.contains(v.name.to_lower()) {
            failure = Some((redeclared_error(v.name), line))
          }
          declared.add(v.name.to_lower())
          try
            @bind.resolve_type(v.type_, Declaration, @types.default_collation)
          catch {
            _ => ()
          } noraise {
            ty => types[v.name.to_lower()] = ty
          }
        }
      DeclareTable(name, _) => declared.add(name.to_lower())
      // two CREATE TABLEs of one temp table name (also ## and in other
      // branches or after a DROP) fail the whole batch: 2714 state 1 at
      // the second (captured: msduck gaps-temp_tables #015, corpus
      // stmts/temp-duplicate-create)
      CreateTable(ct) if ct.name.base().has_prefix("#") => {
        let base = ct.name.base()
        if failure is None && temp_creates.contains(base.to_lower()) {
          failure = Some(
            (
              @types.sql_error(
                2714,
                "There is already an object named '\{base}' in the database.",
              ),
              line,
            ),
          )
        }
        temp_creates.add(base.to_lower())
      }
      SetVar(n, _, e) => {
        check_name(n, line)
        expr(e, line)
      }
      Select(q) => query_vars(q, x => expr(x, line), n => check_name(n, line))
      Print(e) => {
        expr(e, line)
        // captured: PRINT of a sql_variant variable is a compile-time 257
        if failure is None &&
          e.kind is Var(n) &&
          types.get(n.to_lower()) is Some(Variant) {
          failure = Some(
            (
              @types.implicit_conversion_error(
                Variant,
                NVarChar(Some(1), @types.default_collation),
              ),
              line,
            ),
          )
        }
      }
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
      RaisError(args, ..) => {
        args.each(x => expr(x, line))
        if failure is None {
          failure = raiserror_compile_error(args, types).map(e => (e, line))
        }
      }
      Throw(args) => args.each(x => expr(x, line))
      Use(_) if in_proc && failure is None =>
        failure = Some(
          (
            @types.sql_error(
              154,
              "a USE database statement is not allowed in a procedure, function or trigger.",
              severity=15,
            ),
            line,
          ),
        )
      Return(Some(e)) if in_proc => expr(e, line)
      Return(Some(e)) => {
        // RETURN with a value outside a procedure (batch, sp_executesql
        // text): compile error 178 (captured: msduck raiserror-rpc)
        if failure is None {
          failure = Some(
            (
              @types.sql_error(
                178,
                "A RETURN statement with a return value cannot be used in this context.",
                severity=15,
              ),
              line,
            ),
          )
        }
        expr(e, line)
      }
      _ => ()
    }
  }

  for s in stmts {
    stmt(s)
  }
  if failure is None {
    failure = precheck_xml(stmts, types)
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
    MethodCall(t, _, args) => {
      walk_expr(t, f)
      args.each(x => walk_expr(x, f))
    }
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

///|
/// RAISERROR argument errors SQL Server raises while compiling the batch
/// (captured: msduck raiserror-arguments): more than 20 substitution
/// parameters (2747); a variable whose type cannot be substituted (2748).
fn raiserror_compile_error(
  args : Array[@ast.Expr],
  types : Map[String, @types.SqlType],
) -> @types.SqlError? {
  if args.length() > 23 {
    return Some(
      @types.sql_error(
        2747, "Too many substitution parameters for RAISERROR. Cannot exceed 20 substitution parameters.",
      ),
    )
  }
  for k in 3..<args.length() {
    guard args[k].kind is Var(name) else { continue }
    guard types.get(name.to_lower()) is Some(ty) else { continue }
    if !(ty
      is (TinyInt
      | SmallInt
      | Int
      | BigInt
      | Char(_, _)
      | VarChar(_, _)
      | NChar(_, _)
      | NVarChar(_, _)
      | Binary(_)
      | VarBinary(_)
      | Bit)) {
      return Some(
        @types.sql_error(
          2748,
          "Cannot specify \{ty.to_sql()} data type (parameter \{k + 1}) as a substitution parameter.",
        ),
      )
    }
  }
  None
}

///|
/// 134 "The variable name '@a' has already been declared. ..." (class 15).
fn redeclared_error(name : String) -> @types.SqlError {
  @types.sql_error(
    134,
    "The variable name '\{name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
    severity=15,
  )
}
