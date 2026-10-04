// Three-part names (`db.schema.object`) naming another database of the
// server (decisions.md 2026-10-04: cross-database references). Tables of
// another database are bound with scope `OTHER_DB_SCOPE + database_id`
// (storage.mbt) and read and written like the session database's;
// CREATE TABLE, ALTER TABLE, CREATE INDEX and DROP TABLE run in that
// database. Everything else that
// would resolve names in the session's database instead is an explicit
// Emulator error here.

///|
/// Runs `f` with the session database switched to the database of a
/// table scope (no ENVCHANGE, as `db.schema.t` DDL resolves names there).
fn Session::in_scope_database(
  self : Session,
  scope : Int,
  f : () -> Unit raise,
) -> Unit raise {
  if scope < OTHER_DB_SCOPE {
    return f()
  }
  let saved = self.rt.database
  self.rt.database = self.scope_database(scope)
  defer {
    self.rt.database = saved
  }
  f()
}

///|
/// True when `name` (not a temporary object) has a database part naming
/// another database, existing or not.
fn Session::names_other_database(
  self : Session,
  name : @ast.ObjectName,
) -> Bool {
  !name.base().has_prefix("#") && self.name_scope(name) != Some(0)
}

///|
/// Statements whose object names may not name another database (not
/// emulated): raises before they would act on the session database.
fn Session::check_cross_database_ddl(
  self : Session,
  kind : @ast.StmtKind,
) -> Unit raise @types.SqlError {
  let names : Array[@ast.ObjectName] = match kind {
    DropIndex(if_exists=_, items) =>
      items.map(x => {
        match x.1 {
          Some(t) => t
          None => x.0
        }
      })
    AlterIndex(table~, ..) => [table]
    CreateView(v) => [v.name]
    CreateProcedure(p) => [p.name]
    CreateFunction(f) => [f.name]
    CreateTrigger(tr) => [tr.name, tr.table]
    CreateSynonym(n, _) => [n]
    CreateSequence(n, ..) => [n]
    AlterSequence(n, _) => [n]
    CreateType(ct) => [ct.name]
    AlterSchemaTransfer(_, _, n) => [n]
    SetIdentityInsert(n, _) => [n]
    InsertBulk(n, _, _) => [n]
    EnableTrigger(enable=_, _, Some(n)) => [n]
    Drop(DropTable | DropDatabase, if_exists=_, _) => []
    Drop(_, if_exists=_, names) => names
    _ => []
  }
  for n in names {
    if self.names_other_database(n) {
      raise @types.not_supported(
        "this statement on an object of another database",
      )
    }
  }
}

///|
/// CREATE TABLE `db.schema.t` of another database: created there (2702
/// for a database that does not exist; captured: corpus
/// database/cross-database-ddl).
fn Session::exec_create_table_in(
  self : Session,
  ct : @ast.CreateTable,
) -> Unit raise {
  match self.name_scope(ct.name) {
    Some(scope) =>
      self.in_scope_database(scope, () => self.exec_create_table(ct))
    None => {
      let n = ct.name.parts.length()
      raise @types.sql_error(
        2702,
        "Database '\{ct.name.parts[n - 3].name}' does not exist.",
        state=2,
      )
    }
  }
}

///|
/// ALTER TABLE / CREATE INDEX on `db.schema.t` of another (existing)
/// database: the statement runs in that database. Returns false when
/// `kind` is not one of them.
fn Session::exec_in_table_database(self : Session, s : @ast.Stmt) -> Bool raise {
  let name = match s.kind {
    AlterTable(n, _) => n
    CreateIndex(ci) => ci.table
    _ => return false
  }
  guard self.names_other_database(name) && self.name_scope(name) is Some(scope) else {
    return false
  }
  self.in_scope_database(scope, () => self.exec_stmt(s))
  true
}
