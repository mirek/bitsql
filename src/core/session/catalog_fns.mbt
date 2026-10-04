// Catalog/metadata functions evaluated with database access (bound in
// bind/functions_catalog.mbt as Fn::Named). Results follow captures in
// harness/corpus/catalog/functions.sql.

///|
/// Catalog/metadata functions. None = not a catalog function.
fn Session::catalog_fn(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> @types.Value? raise @types.SqlError {
  let arg = (k : Int) => if k < args.length() { args[k] } else { Null }
  let text = (k : Int) => {
    match arg(k) {
      String(t) => Some(t)
      Null => None
      v => Some(value_text(v))
    }
  }
  let num = (k : Int) => arg(k).as_int64().map(x => x.to_int())
  match self.trigger_fn(name, args) {
    Some(v) => return Some(v)
    None => ()
  }
  match self.security_fn(name, args) {
    Some(v) => return Some(v)
    None => ()
  }
  match self.applock_fn(name, args) {
    Some(v) => return Some(v)
    None => ()
  }
  if name == "%READPAST" {
    return Some(self.readpast_check(args))
  }
  if name == "CURSOR_STATUS" {
    return Some(self.cursor_status(args))
  }
  if name == "NEXT VALUE FOR" {
    return Some(self.sequence_next(text(0).unwrap_or("")))
  }
  let db = self.db_of(0)
  let r : @types.Value = match name {
    "OBJECT_ID" =>
      match text(0) {
        Some(n) =>
          match self.resolve_object(n, text(1)) {
            Some(o) => Int(o.id)
            None => Null
          }
        None => Null
      }
    "OBJECT_NAME" | "OBJECT_SCHEMA_NAME" =>
      match (num(0), arg(1)) {
        (Some(id), Null) | (Some(id), _) if args.length() < 2 ||
          num(1) == Some(self.db_id()) =>
          match self.object_by_id(id) {
            Some((o, schema)) =>
              String(if name == "OBJECT_NAME" { o.name } else { schema })
            None => Null
          }
        // another database's object (by its database_id)
        (Some(id), _) if num(1) is Some(dbid) &&
          self.server.database_key(dbid) is Some(key) => {
          let saved = self.rt.database
          self.rt.database = self.server.database_name(key)
          let found = self.object_by_id(id)
          self.rt.database = saved
          match found {
            Some((o, schema)) =>
              String(if name == "OBJECT_NAME" { o.name } else { schema })
            None => Null
          }
        }
        _ => Null
      }
    "SCHEMA_ID" =>
      match text(0) {
        Some(n) =>
          match db.schema_id(n) {
            Some(x) => Int(x)
            None => Null
          }
        None => if args.is_empty() { Int(1) } else { Null }
      }
    "SCHEMA_NAME" =>
      if args.is_empty() {
        String("dbo")
      } else {
        match num(0) {
          Some(id) =>
            match db.schema_name(id) {
              Some(x) => String(x)
              None => Null
            }
          None => Null
        }
      }
    "COL_LENGTH" =>
      match (text(0), text(1)) {
        (Some(t), Some(c)) =>
          match self.resolve_columns(t) {
            Some(cols) =>
              match find_column(cols, c) {
                Some(col) => SmallInt(type_ids(col.ty).2)
                None => Null
              }
            None => Null
          }
        _ => Null
      }
    "COL_NAME" =>
      match (num(0), num(1)) {
        (Some(id), Some(cid)) =>
          match self.columns_of(id) {
            Some(cols) =>
              match cols.iter().find_first(c => c.column_id == cid) {
                Some(c) => String(c.name)
                None => Null
              }
            None => Null
          }
        _ => Null
      }
    "COLUMNPROPERTY" =>
      match (num(0), text(1), text(2)) {
        (Some(id), Some(c), Some(p)) =>
          match self.columns_of(id) {
            Some(cols) =>
              match find_column(cols, c) {
                Some(col) => column_property(col, p)
                None => Null
              }
            None => Null
          }
        _ => Null
      }
    "OBJECTPROPERTY" =>
      match (num(0), text(1)) {
        (Some(id), Some(p)) => self.object_property(id, p)
        _ => Null
      }
    "INDEXPROPERTY" =>
      match (num(0), text(1), text(2)) {
        (Some(id), Some(ix), Some(p)) =>
          match db.table(id) {
            Some(t) =>
              match
                t.indexes
                .iter()
                .find_first(x => x.name.to_lower() == ix.to_lower()) {
                Some(x) =>
                  match p.to_lower() {
                    "isclustered" => Int(if x.clustered { 1 } else { 0 })
                    "isunique" => Int(if x.unique { 1 } else { 0 })
                    "indexid" => Int(x.index_id)
                    "isdisabled"
                    | "ispadindex"
                    | "isfulltextkey"
                    | "ishypothetical"
                    | "isstatistics"
                    | "isautostatistics" => Int(0)
                    "isrowlockdisallowed" | "ispagelockdisallowed" => Int(0)
                    _ => Null
                  }
                None => Null
              }
            None => Null
          }
        _ => Null
      }
    "TYPE_ID" =>
      match text(0) {
        Some(n) if self.user_type_id(n) is Some(id) => Int(id)
        Some(n) => {
          let mut found : @types.Value = Null
          for r in seed_types {
            if r[0] is String(tn) && tn.to_lower() == n.to_lower() {
              found = r[2]
            }
          }
          found
        }
        None => Null
      }
    "TYPE_NAME" =>
      match num(0) {
        Some(id) if self.db_of(0).get_type(id) is Some(ut) => String(ut.name)
        Some(id) => {
          let mut found : @types.Value = Null
          for r in seed_types {
            if r[2] is Int(u) && u == id {
              found = r[0]
            }
          }
          found
        }
        None => Null
      }
    "DB_ID" =>
      if args.is_empty() {
        SmallInt(self.db_id())
      } else {
        match text(0) {
          Some(n) =>
            match
              self
              .databases()
              .iter()
              .find_first(d => d.0.to_lower() == n.to_lower()) {
              Some(d) => SmallInt(d.1)
              None => Null
            }
          None => Null
        }
      }
    "DB_NAME" =>
      match num(0) {
        Some(id) =>
          match self.databases().iter().find_first(d => d.1 == id) {
            Some(d) => String(d.0)
            None => Null
          }
        None => Null
      }
    "IDENT_CURRENT" | "IDENT_SEED" | "IDENT_INCR" =>
      match text(0) {
        Some(n) =>
          match self.resolve_table_text(n, other_db=true) {
            Some((_, t)) =>
              match t.columns.iter().find_first(c => c.identity is Some(_)) {
                Some({ identity: Some(idn), .. }) => {
                  let v = match name {
                    "IDENT_SEED" => idn.seed
                    "IDENT_INCR" => idn.increment
                    _ => self.server.idents.get(t.id).unwrap_or(idn.seed)
                  }
                  Decimal(@types.Decimal::from_int64(v))
                }
                _ => Null
              }
            None => Null
          }
        None => Null
      }
    "OBJECT_DEFINITION" =>
      match num(0) {
        Some(id) => self.object_definition(id)
        None => Null
      }
    "HAS_PERMS_BY_NAME" =>
      // the emulator runs everything as sysadmin
      if arg(0) is Null {
        Null
      } else {
        Int(1)
      }
    _ => return None
  }
  Some(r)
}

///|
fn value_text(v : @types.Value) -> String {
  match v {
    String(s) => s
    TinyInt(n) | SmallInt(n) | Int(n) => n.to_string()
    BigInt(n) => n.to_string()
    _ => ""
  }
}

///|
/// database_id of the session database (sys.databases rows).
fn Session::db_id(self : Session) -> Int {
  let cur = self.rt.database.to_lower()
  for d in self.databases() {
    if d.0.to_lower() == cur {
      return d.1
    }
  }
  5
}

///|
/// (name, database_id) as sys.databases lists them.
/// Server-wide: every database of the server, in database_id order.
fn Session::databases(self : Session) -> Array[(String, Int)] {
  let out = []
  for k, id in self.server.db_ids {
    out.push((self.server.database_name(k), id))
  }
  out.sort_by_key(d => d.1)
  out
}

///|
/// Splits a multi-part name string (`[dbo].t`, `tempdb..#t`) into its parts.
fn split_name_text(n : String) -> Array[String] {
  let parts = []
  let cur = StringBuilder()
  let mut k = 0
  let len = n.length()
  while k < len {
    let c = n.code_unit_at(k).to_int()
    if c == '['.to_int() {
      k += 1
      while k < len {
        let d = n.code_unit_at(k).to_int()
        if d == ']'.to_int() {
          if k + 1 < len && n.code_unit_at(k + 1).to_int() == ']'.to_int() {
            cur.write_char(']')
            k += 2
            continue
          }
          break
        }
        cur.write_char(d.unsafe_to_char())
        k += 1
      }
      k += 1
    } else if c == '"'.to_int() {
      k += 1
      while k < len && n.code_unit_at(k).to_int() != '"'.to_int() {
        cur.write_char(n.code_unit_at(k).to_int().unsafe_to_char())
        k += 1
      }
      k += 1
    } else if c == '.'.to_int() {
      parts.push(cur.to_string())
      cur.reset()
      k += 1
    } else {
      cur.write_char(c.unsafe_to_char())
      k += 1
    }
  }
  parts.push(cur.to_string())
  parts
}

///|
/// Resolves a name string to (database scope, schema, name). None when the
/// name designates another database (unless `other_db`, which gives
/// scope `OTHER_DB_SCOPE + database_id` for an existing one) or is
/// malformed.
fn Session::name_target(
  self : Session,
  n : String,
  other_db? : Bool = false,
) -> (Int, String, String)? {
  let parts = split_name_text(n)
  let k = parts.length()
  if k > 3 || parts.iter().any(p => p.length() > 128) {
    return None
  }
  let base = parts[k - 1]
  let schema = if k >= 2 && parts[k - 2] != "" { parts[k - 2] } else { "dbo" }
  if k == 3 {
    let d = parts[0].to_lower()
    if d == "tempdb" {
      return if base.has_prefix("#") { Some((1, "dbo", base)) } else { None }
    }
    if d != "" && d != self.rt.database.to_lower() {
      if other_db && !base.has_prefix("#") {
        return self.server
          .database_id(d)
          .map(id => (OTHER_DB_SCOPE + id, schema, base))
      }
      return None
    }
  }
  if base.has_prefix("#") {
    // temp objects are only found through tempdb
    return None
  }
  Some((0, schema, base))
}

///|
/// OBJECT_ID: object (table, module or constraint) by name, optional type.
fn Session::resolve_object(
  self : Session,
  n : String,
  type_ : String?,
) -> CatObj? {
  guard self.name_target(n, other_db=true) is Some((scope, schema, base)) else {
    return None
  }
  let db = self.db_of(scope)
  let want = match type_ {
    Some(t) => Some(t.trim().to_upper())
    None => None
  }
  let objs = if scope == 1 {
    // temp tables only (constraints of temp tables are not visible here)
    db
    .tables()
    .map(t => CatObj::{
      id: t.id,
      name: t.name,
      schema_id: 1,
      parent: 0,
      code: "U",
      desc: "USER_TABLE",
      created: t.created,
      modified: t.modified,
    })
  } else {
    user_objects(db)
  }
  let sid = if scope == 1 { Some(1) } else { db.schema_id(schema) }
  guard sid is Some(sid) else { return None }
  for o in objs {
    if o.schema_id == sid &&
      o.name.to_lower() == base.to_lower() &&
      (scope == 1 || self.same_identifier(o.name, base)) {
      match want {
        Some(w) if w != o.code => return None
        _ => return Some(o)
      }
    }
  }
  // system objects: catalog views, system procedures, functions and tables
  // (captured: msduck-runs system-all-columns, OBJECT_ID(N'sys.columns'))
  if is_db_scope(scope) {
    match system_object_named(sid, base) {
      Some(o) =>
        match want {
          Some(w) if w != o.code => return None
          _ => return Some(o)
        }
      None => ()
    }
  }
  None
}

///|
/// Object and schema name by object id (user objects and seeded system
/// objects of the session database).
fn Session::object_by_id(self : Session, id : Int) -> (CatObj, String)? {
  let db = self.db_of(0)
  for o in user_objects(db) {
    if o.id == id {
      return Some((o, db.schema_name(o.schema_id).unwrap_or("dbo")))
    }
  }
  for ut in db.user_types() {
    if ut.table is Some(t) && t.id == id {
      return Some((type_table_obj(ut, t), "sys"))
    }
  }
  match system_object_by_id(id) {
    Some(o) => Some((o, db.schema_name(o.schema_id).unwrap_or("sys")))
    None => None
  }
}

///|
/// Table by name string (tempdb..#t included).
fn Session::resolve_table_text(
  self : Session,
  n : String,
  other_db? : Bool = false,
) -> (Int, @store.Table)? {
  guard self.name_target(n, other_db~) is Some((scope, schema, base)) else {
    return None
  }
  let db = self.db_of(scope)
  match db.lookup(schema, base) {
    Some(id) => db.table(id).map(t => (scope, t))
    None => None
  }
}

///|
/// Columns of a table or view named by a string.
fn Session::resolve_columns(
  self : Session,
  n : String,
) -> Array[@store.Column]? {
  match self.resolve_table_text(n, other_db=true) {
    Some((_, t)) => Some(t.columns)
    None =>
      match self.name_target(n) {
        Some((0, schema, base)) => {
          let db = self.db_of(0)
          match db.lookup(schema, base) {
            Some(id) =>
              match db.get_module(id) {
                Some(m) if m.kind is View => Some(m.columns)
                _ => None
              }
            None => None
          }
        }
        _ => None
      }
  }
}

///|
/// Columns of a table or view by object id (also temp tables).
fn Session::columns_of(self : Session, id : Int) -> Array[@store.Column]? {
  let db = self.db_of(0)
  match db.table(id) {
    Some(t) => Some(t.columns)
    None =>
      match db.get_module(id) {
        Some(m) if m.kind is View => Some(m.columns)
        _ => {
          // a table type's table (captured: COL_NAME, msduck-runs
          // table-type-catalog #013)
          for ut in db.user_types() {
            if ut.table is Some(t) && t.id == id {
              return Some(t.columns)
            }
          }
          self.temp.table(id).map(t => t.columns)
        }
      }
  }
}

///|
fn find_column(cols : Array[@store.Column], name : String) -> @store.Column? {
  let k = name.to_lower()
  cols.iter().find_first(c => c.name.to_lower() == k)
}

///|
fn flag(b : Bool) -> @types.Value {
  Int(if b { 1 } else { 0 })
}

///|
fn column_property(col : @store.Column, p : String) -> @types.Value {
  let (_, _, len, prec, scale) = type_ids(col.ty)
  match p.to_lower() {
    "allowsnull" => flag(col.nullable)
    "columnid" => Int(col.column_id)
    "iscomputed" => flag(col.computed is Some(_))
    "isidentity" => flag(col.identity is Some(_))
    "isrowguidcol" => flag(col.rowguidcol)
    "isidnotforrepl" => flag(false)
    "precision" =>
      match col.ty {
        Char(n, _) | NChar(n, _) | Binary(n) => Int(n)
        VarChar(n, _) | NVarChar(n, _) | VarBinary(n) => Int(n.unwrap_or(-1))
        // captured: json4/type-columns
        Json => Int(-1)
        _ => Int(prec)
      }
    "scale" =>
      match col.ty.family() {
        FInteger | FDecimal | FMoney | FTime | FDateTime => Int(scale)
        _ => Null
      }
    "charmaxlen" =>
      match col.ty {
        Char(n, _) | NChar(n, _) | Binary(n) => Int(n)
        VarChar(n, _) | NVarChar(n, _) | VarBinary(n) => Int(n.unwrap_or(-1))
        _ => Null
      }
    "ordinal" => Int(col.column_id)
    "length" => Int(len)
    _ => Null
  }
}

///|
fn Session::object_property(
  self : Session,
  id : Int,
  p : String,
) -> @types.Value {
  let db = self.db_of(0)
  guard self.object_by_id(id) is Some((o, _)) else { return Null }
  let t = db.table(id)
  let m = db.get_module(id)
  let table_flag = (f : (@store.Table) -> Bool) => {
    match t {
      Some(t) => flag(f(t))
      None => Null
    }
  }
  let code = o.code
  match p.to_lower() {
    "isusertable" => flag(code == "U")
    "istable" => flag(code == "U" || code == "S")
    "issystemtable" => flag(code == "S")
    "isview" => flag(code == "V")
    "isprocedure" => flag(code == "P")
    "isscalarfunction" => flag(code == "FN")
    "isinlinefunction" => flag(code == "IF")
    "istablefunction" => flag(code == "TF" || code == "IF")
    "istrigger" => flag(code == "TR")
    "isconstraint" => flag(["PK", "UQ", "F", "C", "D"].contains(code))
    "isprimarykey" => flag(code == "PK")
    "isforeignkey" => flag(code == "F")
    "ischeckcnst" => flag(code == "C")
    "isdefaultcnst" => flag(code == "D")
    "isuniquecnst" => flag(code == "UQ")
    "ismsshipped" => flag(system_object_by_id(id) is Some(_))
    "ownerid" => Int(1)
    "schemaid" => Int(o.schema_id)
    "isschemabound" =>
      match m {
        Some(m) => flag(m.schema_bound)
        None => flag(false)
      }
    // the CREATE-time SET ANSI_NULLS of tables and modules (probed:
    // tail/settings-ansi-nulls); ExecIsAnsiNullsOn is NULL for tables
    "isansinullson" =>
      match (m, t) {
        (Some(m), _) => flag(m.ansi_nulls)
        (_, Some(t)) => flag(t.ansi_nulls)
        _ => Int(1)
      }
    "execisansinullson" =>
      match m {
        Some(m) => flag(m.ansi_nulls)
        None => Null
      }
    "isquotedidenton" =>
      match m {
        Some(m) => flag(m.quoted_identifier)
        None => Int(1)
      }
    "execisquotedidenton" =>
      match m {
        Some(m) => flag(m.quoted_identifier)
        None => Null
      }
    "isencrypted" => Int(0)
    "execistriggerdisabled" =>
      match m {
        Some(m) if m.kind is Trigger => flag(m.disabled)
        _ => Null
      }
    "tablehasidentity" =>
      table_flag(t => t.columns.iter().any(c => c.identity is Some(_)))
    "tablehasprimarykey" =>
      table_flag(t => t.indexes.iter().any(i => i.primary))
    "tablehasclustindex" =>
      table_flag(t => t.indexes.iter().any(i => i.clustered))
    "tablehasindex" => table_flag(t => !t.indexes.is_empty())
    "tablehasnonclustindex" =>
      table_flag(t => t.indexes.iter().any(i => !i.clustered))
    "tablehasuniquecnst" =>
      table_flag(t => t.indexes.iter().any(i => i.is_constraint && !i.primary))
    "tablehascheckcnst" => table_flag(t => !t.checks.is_empty())
    "tablehasdefaultcnst" =>
      table_flag(t => t.columns.iter().any(c => c.default_id != 0))
    "tablehasforeignkey" => table_flag(t => !t.foreign_keys.is_empty())
    "tablehasforeignref" =>
      table_flag(t => {
        db
        .tables()
        .iter()
        .any(o => o.foreign_keys.iter().any(f => f.ref_table == t.id))
      })
    "tablehascolumnset" | "tablehastimestamp" =>
      table_flag(t => {
        p.to_lower() == "tablehastimestamp" &&
        t.columns.iter().any(c => c.ty is RowVersion)
      })
    _ => Null
  }
}

///|
/// OBJECT_DEFINITION: module source, or normalized constraint expression.
fn Session::object_definition(self : Session, id : Int) -> @types.Value {
  // 0 is the default_object_id of a column without a default: NULL, not
  // the definition of the first default-less column (captured: corpus
  // orm/prisma-introspection; Prisma's db pull panicked on "")
  if id == 0 {
    return Null
  }
  let db = self.db_of(0)
  match db.get_module(id) {
    Some(m) => return String(m.definition)
    None => ()
  }
  for t in db.tables() {
    for c in t.checks {
      if c.id == id {
        return String(definition_text(c.expr))
      }
    }
    for c in t.columns {
      if c.default_id == id {
        return String(definition_text(c.default_.unwrap_or("")))
      }
    }
  }
  Null
}

///|
/// Emits messages SQL Server sends before a statement-ending error.
fn Session::flush_pending(self : Session, line : Int) -> Unit {
  for e in self.pending {
    self.message(e, line)
  }
  self.pending.clear()
}

///|
fn Session::flush_trailing(self : Session, line : Int) -> Unit {
  for e in self.trailing {
    self.message(e, line)
  }
  self.trailing.clear()
}

///|
/// The statement fails with `e` followed by 3621 (captured for failed
/// index builds and column conversions).
fn Session::terminated(self : Session, e : @types.SqlError) -> @types.SqlError {
  self.trailing.push(
    @types.sql_error(
      3621,
      "The statement has been terminated.",
      state=0,
      severity=0,
    ),
  )
  e
}
