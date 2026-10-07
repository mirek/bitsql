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
  let cascade = (
    target : @ast.TableRef,
    sets : Array[@ast.SetClause]?,
    line : Int,
  ) => {
    if defer_schema || !errors.is_empty() {
      return
    }
    guard target.kind is Table(name, ..) &&
      self.find_table(name) is Some((scope, t)) else {
      return
    }
    check_vector_dml(t) catch {
      e => {
        errors.push((e, line))
        return
      }
    }
    let columns = sets.map(sets => {
      sets.filter_map(s => {
        match s.target {
          SetColumn(parts) => t.column_index(parts[parts.length() - 1].name)
          _ => None
        }
      })
    })
    self.check_vector_cascades(scope, t.id, columns) catch {
      e => errors.push((e, line))
    }
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
      CreateIndex(ci) if ci.vector &&
        self.preview_enabled() &&
        !ci.options.any(o => o.name == "METRIC") =>
        errors.push(
          (
            @types.sql_error(
              153,
              "Invalid usage of the option metric in the CREATE VECTOR INDEX statement.",
              state=7,
              severity=15,
            ),
            s.span.line,
          ),
        )
      Insert(i) => cascade(i.target, Some([]), s.span.line)
      Update(u) => cascade(u.target, Some(u.sets), s.span.line)
      Delete(d) => cascade(d.target, None, s.span.line)
      Merge(m) =>
        for w in m.whens {
          match w.action {
            MergeDelete => cascade(m.target, None, s.span.line)
            MergeUpdate(sets) => cascade(m.target, Some(sets), s.span.line)
            MergeInsert(..) => cascade(m.target, Some([]), s.span.line)
          }
        }
      // Constraint toggles occur after the batch's potential cascade writes
      // are compiled against the existing foreign-key graph.
      AlterTable(_, CheckConstraints(_, ..)) => ()
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
