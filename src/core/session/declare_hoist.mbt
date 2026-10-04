///|
/// SQL Server declares a scope's variables when it compiles it: a variable
/// declared inside a branch that does not run exists (NULL) afterwards,
/// and a DECLARE inside a loop does not reset the value (captured: msduck
/// gaps-functions #071, `DECLARE @z int` in a WHILE keeps counting).
/// Scalar variables are pre-declared here at their first DECLARE; the
/// DECLARE statement then only runs its initializer. Declarations whose
/// type does not resolve (or table, cursor and LOB variables) are left to
/// the statement, which raises its errors when it runs.
fn Session::hoist_declares(self : Session, stmts : Array[@ast.Stmt]) -> Unit {
  let seen : Set[String] = Set([])
  for s in stmts {
    self.hoist_stmt(s, seen)
  }
}

///|
/// Only the first DECLARE of a name in the text is hoisted (a later one is
/// 134 when it runs, also after a table variable of that name).
fn Session::hoist_stmt(
  self : Session,
  s : @ast.Stmt,
  seen : Set[String],
) -> Unit {
  match s.kind {
    Declare(vars) =>
      for v in vars {
        let key = v.name.to_lower()
        let f = self.frame()
        if seen.contains(key) {
          continue
        }
        seen.add(key)
        if is_cursor_type(v.type_) ||
          f.vars.contains(key) ||
          f.tables.contains(key) {
          continue
        }
        let ty = try self.decl_type(v.type_, self.db_collation()) catch {
          _ => continue
        } noraise {
          ScalarDecl(ty, _, _) => ty
          TableDecl(_) => continue
        }
        if ty.is_lob() {
          continue
        }
        ignore(f.add_var(v.name, ty))
        f.decl_sites[key] = v.span.start
      }
    DeclareTable(name, _) => seen.add(name.to_lower())
    If(_, a, b) => {
      self.hoist_stmt(a, seen)
      if b is Some(x) {
        self.hoist_stmt(x, seen)
      }
    }
    While(_, b) => self.hoist_stmt(b, seen)
    Block(list) => list.each(x => self.hoist_stmt(x, seen))
    TryCatch(a, b) => {
      a.each(x => self.hoist_stmt(x, seen))
      b.each(x => self.hoist_stmt(x, seen))
    }
    _ => ()
  }
}
