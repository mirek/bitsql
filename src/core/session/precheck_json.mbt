///|
/// Batch-level compile errors of FOR JSON: SQL Server rejects the whole
/// batch before running anything (captured: msduck gaps-json_string#052,
/// `SELECT 1 AS k; SELECT 2 AS v FOR JSON AUTO` returns only the error):
/// 13620 for ROOT with WITHOUT_ARRAY_WRAPPER, 13600 for FOR JSON AUTO
/// without a table (no FROM, or only table-valued functions).
fn precheck_json(stmts : Array[@ast.Stmt]) -> (@types.SqlError, Int)? {
  let c : JsonCheck = { failure: None, }
  for s in stmts {
    c.stmt(s)
  }
  c.failure
}

///|
priv struct JsonCheck {
  mut failure : (@types.SqlError, Int)?
}

///|
fn JsonCheck::query(self : JsonCheck, q : @ast.Query, line : Int) -> Unit {
  if self.failure is Some(_) {
    return
  }
  match q.for_clause {
    Some(ForJson(mode~, root~, without_array_wrapper~, ..)) =>
      if root is Some(_) && without_array_wrapper {
        self.failure = Some(
          (
            @types.sql_error(
              13620, "ROOT option and WITHOUT_ARRAY_WRAPPER option cannot be used together in FOR JSON. Remove one of these options.",
            ),
            line,
          ),
        )
      } else if mode is JsonAuto && !has_auto_table(q) {
        self.failure = Some(
          (
            @types.sql_error(
              13600, "FOR JSON AUTO requires at least one table for generating JSON objects. Use FOR JSON PATH or add a FROM clause with a table name.",
            ),
            line,
          ),
        )
      }
    _ => ()
  }
  query_vars(q, e => self.expr(e), _ => ())
}

///|
fn JsonCheck::expr(self : JsonCheck, e : @ast.Expr) -> Unit {
  walk_expr(e, x => {
    match x.kind {
      Subquery(q) | Exists(q) | InQuery(_, q, ..) => self.query(q, x.span.line)
      Call(c) if self.failure is None &&
        c.args.length() == 2 &&
        c.name.parts.length() == 1 &&
        c.name.base().to_upper() == "ISJSON" =>
        self.failure = isjson_option_error(c.args[1]).map(e => (e, x.span.line))
      _ => ()
    }
  })
}

///|
/// ISJSON's type argument is checked for the whole batch (captured:
/// json3/isjson-path-exists, `DECLARE @t int = 1; SELECT ISJSON(N'1', @t)`
/// runs nothing): anything but a bare word is 1023 (an unknown word is the
/// parser's 155).
fn isjson_option_error(a : @ast.Expr) -> @types.SqlError? {
  match a.kind {
    Column([_]) => None
    _ =>
      Some(
        @types.sql_error(
          1023,
          "Invalid parameter 2 specified for isjson.",
          severity=15,
        ),
      )
  }
}

///|
fn JsonCheck::stmt(self : JsonCheck, s : @ast.Stmt) -> Unit {
  let line = s.span.line
  match s.kind {
    Select(q) => self.query(q, line)
    Declare(vars) =>
      for v in vars {
        if v.init is Some(i) {
          self.expr(i)
        }
      }
    SetVar(_, _, e) | Print(e) => self.expr(e)
    Insert({ source: InsertQuery(q), .. }) => self.query(q, line)
    If(c, a, b) => {
      self.expr(c)
      self.stmt(a)
      if b is Some(x) {
        self.stmt(x)
      }
    }
    While(c, b) => {
      self.expr(c)
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
/// Whether a FOR JSON AUTO query reads a table: a set operation does; a
/// SELECT needs a FROM source other than a table-valued function.
fn has_auto_table(q : @ast.Query) -> Bool {
  guard q.body is Select(s) else { return true }
  fn source(r : @ast.TableRef) -> Bool {
    match r.kind {
      TableFunc(_, _, ..) | Nodes(_, _, ..) => false
      Join(_, l, rr, ..) => source(l) || source(rr)
      _ => true
    }
  }
  s.from.iter().any(source)
}
