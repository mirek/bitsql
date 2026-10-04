///|
/// Compile-time checks of column-level constraints in CREATE TABLE, ALTER
/// TABLE … ADD and table variables; SQL Server rejects the whole batch
/// (captured: constraints/inline-fk-columns):
/// - a column-level FOREIGN KEY with more than one column is 8140;
/// - two column CHECKs on one column are 8148;
/// - a column CHECK naming another column is 8141, then 1750 (a name that
///   is no column at all is 207 when the statement runs, so it is left to
///   the binder).
fn Session::precheck_constraints(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> Array[(@types.SqlError, Int)]? {
  for s in stmts {
    match self.constraint_errors(s) {
      Some(e) => return Some(e)
      None => ()
    }
  }
  None
}

///|
fn Session::constraint_errors(
  self : Session,
  s : @ast.Stmt,
) -> Array[(@types.SqlError, Int)]? {
  let line = s.span.line
  match s.kind {
    CreateTable({ body, .. })
    | AlterTable(_, Add(body, ..))
    | DeclareTable(_, body) if bad_collation(body) is Some(name) =>
      Some([
        (@types.sql_error(448, "Invalid collation '\{name}'.", state=2), line),
      ])
    CreateTable({ name, body, .. }) =>
      body_constraint_errors(
        body,
        written_name(name),
        name.parts[name.parts.length() - 1].name,
        [],
        line,
      )
    AlterTable(name, Add(body, ..)) => {
      // a table created later in the batch compiles when the ALTER runs
      // (new_check raises 8141 there)
      guard self.find_table(name) is Some((_, t)) else { return None }
      let existing = t.columns.map(c => c.name)
      body_constraint_errors(
        body,
        written_name(name),
        name.parts[name.parts.length() - 1].name,
        existing,
        line,
      )
    }
    DeclareTable(n, body) => body_constraint_errors(body, n, n, [], line)
    If(_, a, b) =>
      match self.constraint_errors(a) {
        Some(e) => Some(e)
        None =>
          match b {
            Some(x) => self.constraint_errors(x)
            None => None
          }
      }
    While(_, b) => self.constraint_errors(b)
    Block(list) => self.precheck_constraints(list)
    TryCatch(a, b) =>
      match self.precheck_constraints(a) {
        Some(e) => Some(e)
        None => self.precheck_constraints(b)
      }
    _ => None
  }
}

///|
/// A column COLLATE name SQL Server does not know: 448 state 2 for the
/// whole batch (captured: msduck default-collation columns-unknown-name*).
/// Real collations bitsql does not model stay the binder's Emulator error.
fn bad_collation(body : @ast.TableBody) -> String? {
  for c in body.columns {
    if c.collate is Some(i) &&
      @types.Collation::parse(i.name) is None &&
      @types.unknown_collation_error(i.name).number() == 448 {
      return Some(i.name)
    }
  }
  None
}

///|
/// An object name as written, without brackets (`dbo.t`).
fn written_name(name : @ast.ObjectName) -> String {
  name.parts.map(p => p.name).join(".")
}

///|
fn body_constraint_errors(
  body : @ast.TableBody,
  written : String,
  base : String,
  existing : Array[String],
  line : Int,
) -> Array[(@types.SqlError, Int)]? {
  for k in body.constraints {
    if k.column_level && k.kind is ForeignKey(cols, _) && cols.length() > 1 {
      return Some([
        (
          @types.sql_error(
            8140,
            "More than one key specified in column level FOREIGN KEY constraint, table '\{written}'.",
            state=0,
          ),
          line,
        ),
      ])
    }
  }
  let known : Array[String] = existing.map(n => n.to_lower())
  for c in body.columns {
    known.push(c.name.name.to_lower())
  }
  // any unknown name in a column CHECK is the binder's 207 first
  for c in body.columns {
    for k in c.constraints {
      if k.kind is ColCheck(e, ..) &&
        !expr_has_subquery(e) &&
        expr_column_names(e).iter().any(n => !known.contains(n.to_lower())) {
        return None
      }
    }
  }
  for c in body.columns {
    let checks = c.constraints.filter(k => k.kind is ColCheck(_, ..))
    if checks.length() > 1 {
      return Some([
        (
          @types.sql_error(
            8148,
            "More than one column CHECK constraint specified for column '\{c.name.name}', table '\{written}'.",
            state=0,
          ),
          line,
        ),
      ])
    }
    for k in checks {
      guard k.kind is ColCheck(e, ..) else { continue }
      if expr_has_subquery(e) {
        continue
      }
      let names = expr_column_names(e).map(n => n.to_lower())
      if names.iter().any(n => n != c.name.name.to_lower()) {
        return Some([
          (
            @types.sql_error(
              8141,
              "Column CHECK constraint for column '\{c.name.name}' references another column, table '\{base}'.",
              state=0,
            ),
            line,
          ),
          (
            @types.sql_error(
              1750,
              "Could not create constraint or index. See previous errors.",
              state=0,
            ),
            line,
          ),
        ])
      }
    }
  }
  None
}
