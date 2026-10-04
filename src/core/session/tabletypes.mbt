// User-defined types (CREATE/DROP TYPE: alias types and table types),
// table variables declared with a table type, and READONLY table-valued
// parameters of procedures, functions and sp_executesql (also TVPs sent
// over TDS). Captures: harness/corpus/tabletypes/*.sql.
//
// Types live in the database (`@store.UserType`, sys.types); a table type
// keeps its type table (columns, keys, checks, defaults, identity), which
// DECLARE @t copies into the session's table variables (scope 3). A
// READONLY parameter shares the caller's table variable (it cannot be
// modified, 10700 at compile time); a TVP from the wire is loaded into a
// new one.

///|
/// System type names `@bind.resolve_type` knows: they win over user types
/// of the same name when the name is not schema-qualified.
let builtin_type_names : Array[String] = [
  "bit", "tinyint", "smallint", "int", "integer", "bigint", "decimal", "dec", "numeric",
  "money", "smallmoney", "float", "real", "char", "character", "varchar", "nchar",
  "nvarchar", "sysname", "binary", "varbinary", "date", "time", "datetime2", "datetimeoffset",
  "datetime", "smalldatetime", "uniqueidentifier", "rowversion", "timestamp", "sql_variant",
  "double precision", "xml", "text", "ntext", "image", "cursor", "table", "hierarchyid",
  "geometry", "geography", "json", "vector",
]

///|
fn is_builtin_type(tn : @ast.TypeName) -> Bool {
  match tn.schema {
    Some(s) if s.name.to_lower() != "sys" => false
    _ => builtin_type_names.contains(tn.name.to_lower())
  }
}

///|
/// A type name as written (`dbo.Email`, `Email`), for messages.
fn type_text(tn : @ast.TypeName) -> String {
  match tn.schema {
    Some(s) => s.name + "." + tn.name
    None => tn.name
  }
}

///|
/// The user-defined type `tn` names in the current database (unqualified
/// names resolve in dbo).
fn Session::find_user_type(
  self : Session,
  tn : @ast.TypeName,
) -> @store.UserType? {
  if is_builtin_type(tn) {
    return None
  }
  let schema = match tn.schema {
    Some(s) => s.name
    None => "dbo"
  }
  self.db_of(0).lookup_type(schema, tn.name)
}

///|
/// A declared type: a scalar type (with the alias type's user_type_id and
/// NULL default) or a table type.
priv enum DeclType {
  ScalarDecl(@types.SqlType, Int?, Bool?)
  TableDecl(@store.UserType)
}

///|
fn Session::decl_type(
  self : Session,
  tn : @ast.TypeName,
  collation : @types.Collation,
) -> DeclType raise @types.SqlError {
  match self.find_user_type(tn) {
    Some({ table: Some(_), .. } as ut) => TableDecl(ut)
    Some({ base: Some(b), .. } as ut) =>
      ScalarDecl(b, Some(ut.id), Some(ut.nullable))
    _ =>
      ScalarDecl(
        @bind.resolve_type(tn, Declaration, collation) catch {
          @types.SqlError(number=2715, state~, ..) =>
            raise missing_type(tn, state)
          e => raise e
        },
        None,
        None,
      )
  }
}

///|
/// 2715 naming the type as written (captured: "Cannot find data type
/// dbo.NoSuch."); state 6 for columns and parameters, 3 for DECLARE.
/// A table column names its ordinal in the table (captured: corpus
/// catalog/computed-forward-refs, `#3` for the third column, counting the
/// existing ones under ALTER TABLE ADD).
fn missing_type(
  tn : @ast.TypeName,
  state : Int,
  position? : Int = 1,
) -> @types.SqlError {
  @types.sql_error(
    2715,
    "Column, parameter, or variable #\{position}: Cannot find data type \{type_text(tn)}.",
    state~,
  )
}

///|
/// A scalar declaration type: alias types resolve to their base type; a
/// table type is 2715 (captured: a table type as a column type).
fn Session::scalar_type(
  self : Session,
  tn : @ast.TypeName,
  collation : @types.Collation,
) -> @types.SqlType raise @types.SqlError {
  match self.decl_type(tn, collation) {
    ScalarDecl(t, _, _) => t
    TableDecl(_) => raise missing_type(tn, 6)
  }
}

///|
/// The type of a DECLAREd variable: unknown types are 2715 state 3 followed
/// by INFO 2724 (captured: tabletypes/type-errors).
fn Session::declared_var_type(
  self : Session,
  name : String,
  tn : @ast.TypeName,
) -> DeclType raise @types.SqlError {
  self.decl_type(tn, self.db_collation()) catch {
    @types.SqlError(number=2715, ..) => {
      self.trailing.push(
        @types.sql_error(
          2724,
          "Parameter or variable '\{name}' has an invalid data type.",
          state=2,
          severity=0,
        ),
      )
      raise missing_type(tn, 3)
    }
    e => raise e
  }
}

///|
/// CREATE TYPE: sends no DONE of its own (captured; like CREATE SCHEMA).
fn Session::exec_create_type(
  self : Session,
  ct : @ast.CreateType,
) -> Unit raise {
  let (schema, base) = split_name(ct.name)
  let db = self.db_of(0)
  if db.schema_id(schema) is None {
    raise @types.sql_error(
      2760,
      "The specified schema name \"\{schema}\" either does not exist or you do not have permission to use it.",
    )
  }
  // a system type name (int, varchar, sysname) exists in every schema
  // (captured: msduck-runs table-type-catalog #003, tail/catalog-column-types)
  if db.lookup_type(schema, base) is Some(_) || is_system_type_name(base) {
    raise @types.sql_error(
      219,
      "The type '\{object_text(ct.name)}' already exists, or you do not have permission to create it.",
    )
  }
  let id = db.next_type_id()
  let ut : @store.UserType = match (ct.base, ct.table) {
    (Some(bt), _) => {
      if self.find_user_type(bt) is Some(_) {
        raise @types.sql_error(
          222,
          "The base type \"\{type_text(bt)}\" is not a valid base type for the alias data type.",
        )
      }
      let ty = self.alias_base(bt, ct.name)
      {
        id,
        schema,
        name: base,
        base: Some(ty),
        nullable: ct.nullable.unwrap_or(true),
        table: None,
        created: self.rt.now,
      }
    }
    (None, Some(body)) => {
      let oid = self.server.object_id()
      let t = self.table_from_body(oid, schema, base, body, db, 4)
      {
        id,
        schema,
        name: base,
        base: None,
        nullable: false,
        table: Some(t),
        created: self.rt.now,
      }
    }
    (None, None) => raise @types.not_supported("CREATE TYPE without a body")
  }
  self.write(0, self.db_of(0).add_type(ut))
  self.rt.rowcount = 0
  self.schema_ddl = true
}

///|
/// The base type of an alias type; an oversized length is 2717 then 225
/// (captured: `FROM nvarchar(5000)`).
fn Session::alias_base(
  self : Session,
  bt : @ast.TypeName,
  name : @ast.ObjectName,
) -> @types.SqlType raise @types.SqlError {
  let mut invalid = false
  let ty = @bind.resolve_type(bt, Declaration, @types.default_collation) catch {
    @types.SqlError(number=2715, state~, ..) => raise missing_type(bt, state)
    @types.SqlError(number=2716, ..) as e => {
      invalid = true
      match bt.name.to_lower() {
        "nchar" | "nvarchar" => NChar(1, @types.default_collation)
        "char" | "varchar" | "binary" | "varbinary" => Binary(1)
        _ => raise e
      }
    }
    e => raise e
  }
  if invalid {
    let limit = match ty {
      NChar(_, _) | NVarChar(_, _) => Some(4000)
      Char(_, _) | VarChar(_, _) | Binary(_) | VarBinary(_) => Some(8000)
      _ => None
    }
    let size = match bt.args.get(0) {
      Some(Num(n)) => n
      _ => ""
    }
    guard limit is Some(max) else {
      raise @types.not_supported("this alias type base")
    }
    self.pending.push(
      @types.sql_error(
        2717,
        "The size (\{size}) given to the parameter '\{bt.name.to_lower()}' exceeds the maximum allowed (\{max}).",
        state=2,
      ),
    )
    raise @types.sql_error(
      225,
      "The parameters supplied for the UDT \"\{object_text(name)}\" are not valid.",
    )
  }
  ty
}

///|
/// DROP TYPE [IF EXISTS]: no DONE of its own (captured); 218 when missing,
/// 3732 while a table column or a module parameter uses it.
fn Session::exec_drop_type(
  self : Session,
  if_exists : Bool,
  names : Array[@ast.ObjectName],
) -> Unit raise {
  for n in names {
    let (schema, base) = split_name(n)
    let db = self.db_of(0)
    match db.lookup_type(schema, base) {
      None =>
        if !if_exists {
          raise @types.sql_error(
            218,
            "Could not find the type '\{object_text(n)}'. Either it does not exist or you do not have the necessary permission.",
          )
        }
      Some(ut) => {
        match self.type_user(db, ut) {
          Some(obj) =>
            raise @types.sql_error(
              3732,
              "Cannot drop type '\{object_text(n)}' because it is being referenced by object '\{obj}'. There may be other objects that reference this type.",
            )
          None => ()
        }
        self.write(0, db.drop_type(ut.id))
      }
    }
  }
  self.rt.rowcount = 0
  self.schema_ddl = true
}

///|
/// An object using the type: a table with a column of it, or a procedure /
/// function with a parameter of it.
fn Session::type_user(
  self : Session,
  db : @store.Db,
  ut : @store.UserType,
) -> String? {
  for t in db.tables() {
    if t.columns.iter().any(c => c.user_type == Some(ut.id)) {
      return Some(t.name)
    }
  }
  for m in db.modules() {
    for p in module_params(m) {
      match self.find_user_type(p.type_) {
        Some(x) if x.id == ut.id => return Some(m.name)
        _ => ()
      }
    }
  }
  None
}

///|
/// Parameters of a stored procedure or function (from its definition).
fn module_params(m : @store.Module) -> Array[@ast.Param] {
  guard m.kind is (Procedure | ScalarFunction | InlineFunction | TableFunction) else {
    return []
  }
  let stmts = @parse.parse_batch(m.definition) catch { _ => return [] }
  for s in stmts {
    match s.kind {
      CreateProcedure(p) => return p.params
      CreateFunction(f) => return f.params
      _ => ()
    }
  }
  []
}

///|
/// DECLARE @t <table type>: a table variable with the type's columns and
/// constraints.
fn Session::declare_typed_table(
  self : Session,
  name : String,
  ut : @store.UserType,
) -> Unit raise {
  let key = name.to_lower()
  if self.frame().tables.contains(key) || self.frame().vars.contains(key) {
    raise @types.sql_error(
      134,
      "The variable name '\{name}' has already been declared. Variable names must be unique within a query batch or stored procedure.",
      severity=15,
    )
  }
  let id = self.new_typed_table(ut)
  self.frame().tables[key] = id
}

///|
/// A new, empty table variable of table type `ut`; returns its id.
fn Session::new_typed_table(self : Session, ut : @store.UserType) -> Int {
  guard ut.table is Some(tt) else { return 0 }
  let id = self.server.object_id()
  let t : @store.Table = {
    ..tt,
    id,
    schema: "dbo",
    name: "@" + id.to_string(),
    created: self.rt.now,
    modified: self.rt.now,
  }
  self.tvars = self.tvars.create_table(t)
  id
}

///|
/// Parameter declaration checks for CREATE PROCEDURE / FUNCTION and
/// sp_executesql: a table type needs READONLY (352), READONLY needs a table
/// type (346). Returns the READONLY parameter names (lowercased).
fn Session::check_param_decls(
  self : Session,
  params : Array[@ast.Param],
) -> Set[String] raise @types.SqlError {
  let out : Set[String] = Set([])
  for p in params {
    let table = match self.find_user_type(p.type_) {
      Some({ table: Some(_), .. }) => true
      _ => false
    }
    if table && !p.read_only {
      raise @types.sql_error(
        352,
        "The table-valued parameter \"\{p.name}\" must be declared with the READONLY option.",
        severity=15,
      )
    }
    if !table && p.read_only {
      raise @types.sql_error(
        346,
        "The parameter \"\{p.name}\" can not be declared READONLY since it is not a table-valued parameter.",
        severity=15,
      )
    }
    if table {
      out.add(p.name.to_lower())
    }
  }
  out
}

///|
/// 10700 for a statement modifying a READONLY table-valued parameter.
fn readonly_error(name : String) -> @types.SqlError {
  @types.sql_error(
    10700,
    "The table-valued parameter \"\{name}\" is READONLY and cannot be modified.",
  )
}

///|
/// The first READONLY parameter an INSERT/UPDATE/DELETE/MERGE (or OUTPUT
/// INTO) of `stmts` writes to.
fn readonly_target(
  stmts : Array[@ast.Stmt],
  read_only_tvps : Set[String],
) -> String? {
  if read_only_tvps.is_empty() {
    return None
  }
  fn hit(r : @ast.TableRef) -> String? {
    match r.kind {
      TableVar(n, ..) if read_only_tvps.contains(n.to_lower()) => Some(n)
      _ => None
    }
  }

  fn outputs(list : Array[@ast.OutputClause]) -> String? {
    for o in list {
      match o.into {
        Some((r, _)) =>
          match hit(r) {
            Some(n) => return Some(n)
            None => ()
          }
        None => ()
      }
    }
    None
  }

  fn either(a : String?, b : String?) -> String? {
    match a {
      Some(_) => a
      None => b
    }
  }

  fn walk(list : Array[@ast.Stmt]) -> String? {
    for s in list {
      let found = match s.kind {
        Insert(i) => either(hit(i.target), outputs(i.output))
        Update(u) => either(hit(u.target), outputs(u.output))
        Delete(d) => either(hit(d.target), outputs(d.output))
        Merge(m) => hit(m.target)
        If(_, a, b) =>
          either(
            walk([a]),
            match b {
              Some(x) => walk([x])
              None => None
            },
          )
        While(_, b) => walk([b])
        Block(l) => walk(l)
        TryCatch(a, b) => either(walk(a), walk(b))
        _ => None
      }
      if found is Some(_) {
        return found
      }
    }
    None
  }

  walk(stmts)
}

///|
/// CREATE PROCEDURE / FUNCTION checks of table-valued parameters (352, 346,
/// 10700; captured: tabletypes/readonly-params).
fn Session::check_module_params(
  self : Session,
  params : Array[@ast.Param],
  body : Array[@ast.Stmt],
) -> Unit raise @types.SqlError {
  let read_only_tvps = self.check_param_decls(params)
  match readonly_target(body, read_only_tvps) {
    Some(n) => raise readonly_error(n)
    None => ()
  }
}

///|
/// A table-valued argument: the caller's table variable (shared: the
/// parameter is READONLY) or rows of a TVP sent over TDS.
priv enum TableArg {
  Borrowed(Int)
  Wire(@tds.Tvp)
}

///|
/// Binds READONLY table-valued parameter `p` of type `ut` in `frame`.
/// Without an argument the parameter is an empty table (captured: EXEC
/// without it); a scalar argument is 206.
fn Session::bind_table_param(
  self : Session,
  frame : Frame,
  p : @ast.Param,
  ut : @store.UserType,
  arg : Arg?,
) -> Unit raise {
  let key = p.name.to_lower()
  frame.read_only_tvps.add(key)
  match arg {
    Some({ table: Some(Borrowed(id)), .. }) => frame.tables[key] = id
    Some({ table: Some(Wire(tvp)), .. }) => {
      let id = self.new_typed_table(ut)
      frame.tables[key] = id
      frame.owned.add(key)
      self.load_tvp(id, p.name, tvp)
    }
    Some(a) =>
      raise @types.sql_error(
        206,
        "Operand type clash: \{a.ty.clash_name()} is incompatible with \{ut.name}",
        state=2,
      )
    None => {
      frame.tables[key] = self.new_typed_table(ut)
      frame.owned.add(key)
    }
  }
}

///|
/// Loads the rows of a TVP into table variable `id`, enforcing the type's
/// NOT NULL, CHECK and key constraints. A failure is reported at line 0
/// before the procedure runs (captured: 2627 for a duplicate key, then
/// 3621, no RETURNSTATUS).
fn Session::load_tvp(
  self : Session,
  id : Int,
  display : String,
  tvp : @tds.Tvp,
) -> Unit raise {
  guard self.tvars.table(id) is Some(t) else { return }
  guard tvp.rows is Some(rows) else { return }
  if tvp.columns.length() != t.columns.length() {
    raise @types.not_supported(
      "a table-valued parameter whose columns differ from its table type",
    )
  }
  if t.columns.iter().any(c => c.identity is Some(_) || c.computed is Some(_)) {
    raise @types.not_supported(
      "table-valued parameters of a table type with IDENTITY or computed columns",
    )
  }
  let target : Target = {
    scope: 3,
    table: t,
    display,
    qualifier: display.to_lower(),
  }
  let mut db = self.tvars
  self.tvp_error = true
  for src in rows {
    let row = Array::make(t.columns.length(), @types.Value::Null)
    for i, c in t.columns {
      let col = tvp.columns[i]
      if (col.flags & @tds.TVP_DEFAULT_COLUMN) != 0 {
        match c.default_ {
          Some(d) => row[i] = self.eval_text(target, d, row, c.ty)
          None => ()
        }
        continue
      }
      let ty = param_type(col.type_info)
      let v = param_value(ty, src[i])
      row[i] = self.to_column(target, c, v, ty)
    }
    self.check_row(target, db, row, "INSERT")
    db = insert_checked(target, db, self.server.rowid(), row)
  }
  self.tvp_error = false
  self.tvars = db
}

///|
/// TVP rows of an RPC parameter as a table argument.
fn tvp_arg(p : @tds.RpcParam) -> Arg? {
  match p.tvp {
    Some(t) =>
      Some({ value: Null, ty: Int, output: p.by_ref, table: Some(Wire(t)), })
    None => None
  }
}

///|
/// An EXEC argument naming a table variable passes the table itself.
fn Session::table_var_arg(self : Session, e : @ast.Expr) -> Arg? {
  guard e.kind is Var(name) else { return None }
  if self.frame().vars.contains(name.to_lower()) {
    return None
  }
  match self.find_table_var(name) {
    Some(t) =>
      Some({ value: Null, ty: Int, output: false, table: Some(Borrowed(t.id)), })
    None => None
  }
}

///|
/// TYPE_ID of a user-defined type name (`dbo.IdList`, `[dbo].[Names]`).
fn Session::user_type_id(self : Session, text : String) -> Int? {
  let name = match
    (@parse.parse_statement("DROP TYPE " + text) catch { _ => return None }).kind {
    Drop(_, [n], ..) => n
    _ => return None
  }
  let k = name.parts.length()
  let tn : @ast.TypeName = {
    schema: if k >= 2 {
      Some(name.parts[k - 2])
    } else {
      None
    },
    name: name.parts[k - 1].name,
    args: [],
    span: name.span,
  }
  self.find_user_type(tn).map(ut => ut.id)
}
