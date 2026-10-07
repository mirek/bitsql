///|
/// Existing vector sources bind before preceding DECLARE statements execute.
/// Defer missing objects and batches changing the schema to statement binding.
fn Session::precheck_vector(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> Array[(@types.SqlError, Int)] {
  let vars = Map::from_array(self.frame().vars.iter().to_array())
  let errors : Array[(@types.SqlError, Int)] = []
  let mut defer_schema = false
  fn has_vector(q : @ast.Query) -> Bool {
    fn source(r : @ast.TableRef) -> Bool {
      match r.kind {
        VectorSearch(_) => true
        Join(_, l, r, ..) => source(l) || source(r)
        Derived(q, ..) => has_vector(q)
        _ => false
      }
    }
    fn body(b : @ast.QueryBody) -> Bool {
      match b {
        Select(s) => s.from.any(source)
        SetOperation(_, l, r) => body(l) || body(r)
        Nested(q) => has_vector(q)
      }
    }
    body(q.body)
  }
  fn stmt(s : @ast.Stmt) -> Unit {
    if !errors.is_empty() {
      return
    }
    match s.kind {
      Declare(declarations) =>
        for v in declarations {
          let ty = @bind.resolve_type(
            v.type_,
            Declaration,
            self.db_collation(),
            preview=self.preview_enabled(),
          ) catch {
            _ => continue
          }
          vars[v.name.to_lower()] = { slot: vars.length(), ty, }
        }
      Select(q) if !defer_schema && has_vector(q) => {
        let before = []
        let env = @bind.Env::new(
          vars,
          catalog=self.catalog(),
          collation=self.db_collation(),
          deferred=before,
        )
        ignore(@bind.bind_query(env, q)) catch {
          e =>
            if e.number() != 208 && e.number() < 50100 {
              for previous in before {
                errors.push((previous, s.span.line))
              }
              errors.push((e, s.span.line))
            }
        }
      }
      Block(ss) => ss.each(stmt)
      If(_, a, b) => {
        stmt(a)
        if b is Some(b) {
          stmt(b)
        }
      }
      While(_, b) => stmt(b)
      TryCatch(a, b) => {
        a.each(stmt)
        b.each(stmt)
      }
      Select(_) | SetVar(_, _, _) | Print(_) => ()
      _ => defer_schema = true
    }
  }
  stmts.each(stmt)
  errors
}
