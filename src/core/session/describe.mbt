// sys.dm_exec_describe_first_result_set(@tsql, @params, @browse): the
// metadata of the first result set of a batch, from the binder (captured
// probes and msduck greatest-least / charindex-patindex / soundex
// describe cases). One row per column: name, type text and facts as
// sys.columns reports them, nullability, base-column flags (identity,
// updateable, computed) and the ORDER BY position; compile errors become
// two error rows (column_ordinal 0 and 1). Browse mode (@browse <> 0) and
// statements other than SELECT are not emulated beyond "no rows".

///|
fn describe_columns() -> Array[@bind.ColumnRef] {
  let c = (name : String, ty : @types.SqlType) => @bind.ColumnRef::{
    untyped_null: false,
    qualifier: "",
    name,
    ty,
    nullable: true,
    origin: BaseColumn(identity=false),
  }
  let sysname : @types.SqlType = NVarChar(Some(128), @types.default_collation)
  [
    c("is_hidden", Bit),
    c("column_ordinal", Int),
    c("name", sysname),
    c("is_nullable", Bit),
    c("system_type_id", Int),
    c("system_type_name", sysname),
    c("max_length", SmallInt),
    c("precision", TinyInt),
    c("scale", TinyInt),
    c("collation_name", sysname),
    c("user_type_id", Int),
    c("user_type_database", sysname),
    c("user_type_schema", sysname),
    c("user_type_name", sysname),
    c(
      "assembly_qualified_type_name",
      NVarChar(Some(4000), @types.default_collation),
    ),
    c("xml_collection_id", Int),
    c("xml_collection_database", sysname),
    c("xml_collection_schema", sysname),
    c("xml_collection_name", sysname),
    c("is_xml_document", Bit),
    c("is_case_sensitive", Bit),
    c("is_fixed_length_clr_type", Bit),
    c("source_server", sysname),
    c("source_database", sysname),
    c("source_schema", sysname),
    c("source_table", sysname),
    c("source_column", sysname),
    c("is_identity_column", Bit),
    c("is_part_of_unique_key", Bit),
    c("is_updateable", Bit),
    c("is_computed_column", Bit),
    c("is_sparse_column_set", Bit),
    c("ordinal_in_order_by_list", SmallInt),
    c("order_by_is_descending", Bit),
    c("order_by_list_length", SmallInt),
    c("error_number", Int),
    c("error_severity", Int),
    c("error_state", Int),
    c("error_message", NVarChar(Some(2048), @types.default_collation)),
    c("error_type", Int),
    c("error_type_desc", NVarChar(Some(30), @types.default_collation)),
  ]
}

///|
/// The two error rows of a batch that does not compile: the error itself,
/// then 11501 (compile errors; error_type 2 SYNTAX) or, after a missing
/// object, 11529 (every code path fails; 1 MISC). Unverified beyond 189,
/// 8116, 208 and a parse failure.
fn describe_error_rows(e : @types.SqlError) -> Array[Array[@types.Value]] {
  let width = describe_columns().length()
  let row = (
    ordinal : Int,
    n : Int,
    sev : Int,
    st : Int,
    msg : String,
    ty : Int,
  ) => {
    let r = Array::make(width, @types.Value::Null)
    r[1] = Int(ordinal)
    r[width - 6] = Int(n)
    r[width - 5] = Int(sev)
    r[width - 4] = Int(st)
    r[width - 3] = String(msg)
    r[width - 2] = Int(ty)
    r[width - 1] = String(if ty == 2 { "SYNTAX" } else { "MISC" })
    r
  }
  let missing = e.number() is (208 | 2812)
  let first_type = if e.number() == 2812 { 1 } else { 2 }
  [
    row(0, e.number(), e.severity(), e.state(), e.message(), first_type),
    if missing {
      row(
        1, 11529, 16, 1, "The metadata could not be determined because every code path results in an error; see previous errors for some of these.",
        1,
      )
    } else {
      row(
        1, 11501, 16, 1, "The batch could not be analyzed because of compile errors.",
        2,
      )
    },
  ]
}

///|
/// The first statement of a batch that returns rows to the client.
fn first_result_query(stmts : Array[@ast.Stmt]) -> @ast.Query? {
  for s in stmts {
    match s.kind {
      Select(q) => {
        let assigns = match q.body {
          Select(b) =>
            b.into is Some(_) ||
            b.items.iter().any(i => i.kind is Assign(_, _, _))
          _ => false
        }
        if !assigns {
          return Some(q)
        }
      }
      Block(list) =>
        match first_result_query(list) {
          Some(q) => return Some(q)
          None => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// What describing a batch found: the first result's columns with its
/// query and binding, a compile error, or no result set.
priv enum Described {
  Columns(@ast.Query, @bind.BoundQuery)
  Failed(@types.SqlError)
  NoResult
}

///|
fn parse_failure(e : @ast.SyntaxError) -> Described {
  Failed(
    @types.sql_error(
      e.number(),
      e.message(),
      state=e.state(),
      severity=e.severity(),
    ),
  )
}

///|
/// Binds the first result set of `text` with the declared `params`
/// ('@a int, @b nvarchar(10)'). Browse mode is not emulated.
fn Session::describe_batch(
  self : Session,
  text : String,
  params : String?,
  browse : @types.Value?,
) -> Described raise @types.SqlError {
  if browse is Some(v) && !(v is (Null | Int(0) | TinyInt(0) | Bit(false))) {
    raise @types.not_supported("describing a result set in browse mode")
  }
  let vars : Map[String, @bind.VarInfo] = Map([])
  match params {
    Some(p) if p.trim() != "" => {
      let decl = @parse.parse_batch("DECLARE " + p) catch {
        e => return parse_failure(e)
      }
      for s in decl {
        if s.kind is Declare(list) {
          for v in list {
            let ty = @bind.resolve_type(
              v.type_,
              Declaration,
              @types.default_collation,
            )
            vars[v.name.to_lower()] = { slot: vars.length(), ty, }
          }
        }
      }
    }
    _ => ()
  }
  let stmts = @parse.parse_batch(text) catch { e => return parse_failure(e) }
  guard first_result_query(stmts) is Some(q) else { return NoResult }
  let env = @bind.Env::new(vars, catalog=self.catalog(), deferred=[])
  let bq = @bind.bind_query(env, q) catch { e => return Failed(e) }
  Columns(q, bq)
}

///|
/// The 35 leading facts of one described column (sys.dm_exec_describe_
/// first_result_set and sp_describe_first_result_set share them).
fn describe_facts(
  q : @ast.Query,
  bq : @bind.BoundQuery,
  j : Int,
) -> Array[@types.Value] {
  let c = bq.columns[j]
  // captured (json4): json is described as varchar(max)
  // Latin1_General_100_BIN2_UTF8, the type TDS 7.4 clients receive
  let c = if c.ty is Json {
    { ..c, ty: VarChar(None, @types.json_collation), }
  } else {
    c
  }
  let r = Array::make(35, @types.Value::Null)
  let (st, _, len, p, sc) = type_ids(c.ty)
  let base = c.origin is (BaseColumn(_) | InsertableIdentity)
  let identity = c.origin is (BaseColumn(identity=true) | InsertableIdentity)
  r[0] = Bit(false)
  r[1] = Int(j + 1)
  r[2] = if c.name == "" { Null } else { String(c.name) }
  r[3] = Bit(c.nullable)
  r[4] = Int(st)
  r[5] = String(c.ty.to_sql())
  r[6] = SmallInt(
    if c.ty.to_sql().has_suffix("(max)") || c.ty is Xml {
      -1
    } else {
      len
    },
  )
  r[7] = TinyInt(p)
  r[8] = TinyInt(sc)
  r[9] = match c.ty.collation() {
    Some(coll) => String(coll.name)
    None => Null
  }
  r[19] = Bit(false)
  // captured: xml reports case-sensitive
  r[20] = Bit(
    match c.ty.collation() {
      Some(coll) => coll.case_sensitive
      None => c.ty is Xml
    },
  )
  r[21] = Bit(false)
  r[27] = Bit(identity)
  r[29] = Bit(base && !identity)
  // captured (msduck json-aggregates#037/#069): aggregates are not
  // computed columns; a json-typed aggregate is (origin Computed)
  r[30] = Bit(!base && !(c.origin is Aggregate))
  r[31] = Bit(false)
  if !q.order_by.is_empty() {
    for k, ord in bq.order {
      if ord == j + 1 {
        r[32] = SmallInt(k + 1)
        r[33] = Bit(q.order_by.get(k).map(o => o.desc).unwrap_or(false))
        break
      }
    }
    r[34] = SmallInt(q.order_by.length())
  }
  r
}

///|
fn Session::describe_first_result_set(
  self : Session,
  args : Array[@types.Value],
) -> Array[Array[@types.Value]] raise @types.SqlError {
  let text = match args.get(0) {
    Some(String(s)) => s
    _ => return []
  }
  let params = match args.get(1) {
    Some(String(p)) => Some(p)
    _ => None
  }
  match self.describe_batch(text, params, args.get(2)) {
    NoResult => []
    Failed(e) => describe_error_rows(e)
    Columns(q, bq) =>
      bq.columns.mapi((j, _) => {
        describe_facts(q, bq, j) + [Null, Null, Null, Null, Null, Null]
      })
  }
}

///|
/// Catalog hook for system table-valued functions (bind_table_function).
fn Session::system_tvf(
  self : Session,
  name : String,
  args : Array[@types.Value],
) -> (Array[@bind.ColumnRef], Array[Array[@types.Value]])? raise @types.SqlError {
  match name {
    "dm_exec_describe_first_result_set" =>
      Some((describe_columns(), self.describe_first_result_set(args)))
    "fn_listextendedproperty" => Some(self.fn_listextendedproperty(args))
    _ => None
  }
}

///|
/// TDS facts of a result column type: COLMETADATA type id, length, and the
/// collation as an int (LCID and flags) and sort id (captured:
/// sp_describe_first_result_set tds_* columns; nullable wire types).
fn tds_facts(t : @types.SqlType) -> (Int, Int, @types.Value, @types.Value) {
  let coll = (b : Bytes) => {
    let id = b[0].to_int() |
      (b[1].to_int() << 8) |
      (b[2].to_int() << 16) |
      (b[3].to_int() << 24)
    (@types.Value::Int(id), @types.Value::TinyInt(b[4].to_int()))
  }
  match type_info(t, true) {
    IntN(n) => (38, n, Null, Null)
    BitN | Bit => (104, 1, Null, Null)
    FloatN(n) => (109, n, Null, Null)
    MoneyN(n) => (110, n, Null, Null)
    DateTimeN(n) => (111, n, Null, Null)
    Guid => (36, 16, Null, Null)
    DecimalN(_, _) => (106, 17, Null, Null)
    NumericN(_, _) => (108, 17, Null, Null)
    Date => (40, 3, Null, Null)
    Time(s) => (41, if s <= 2 { 3 } else if s <= 4 { 4 } else { 5 }, Null, Null)
    DateTime2(s) =>
      (42, if s <= 2 { 6 } else if s <= 4 { 7 } else { 8 }, Null, Null)
    DateTimeOffset(s) =>
      (43, if s <= 2 { 8 } else if s <= 4 { 9 } else { 10 }, Null, Null)
    BigVarChar(n, b) => {
      let (i, s) = coll(b)
      (167, n, i, s)
    }
    BigChar(n, b) => {
      let (i, s) = coll(b)
      (175, n, i, s)
    }
    NVarChar(n, b) => {
      let (i, s) = coll(b)
      (231, n, i, s)
    }
    NChar(n, b) => {
      let (i, s) = coll(b)
      (239, n, i, s)
    }
    BigVarBinary(n) => (165, n, Null, Null)
    BigBinary(n) => (173, n, Null, Null)
    Variant(_) => (98, 8009, Null, Null)
    Xml => (241, 8100, Null, Null)
    _ => (0, 0, Null, Null)
  }
}

///|
/// sp_describe_first_result_set: the same facts as a procedure result with
/// tds_* columns instead of error ones; a compile error is raised (the
/// error, then 11501 / 11529).
fn Session::sp_describe_first_result_set(
  self : Session,
  a : Map[String, @types.Value],
) -> Int raise {
  let text = match a.get("@tsql") {
    Some(String(s)) => s
    _ =>
      raise @types.not_supported("sp_describe_first_result_set without @tsql")
  }
  let params = match a.get("@params") {
    Some(String(p)) => Some(p)
    _ => None
  }
  match self.describe_batch(text, params, a.get("@browse_information_mode")) {
    Failed(e) => {
      let rows = describe_error_rows(e)
      self.message(e, 1)
      let w = rows[1].length()
      let n = match rows[1][w - 6] {
        Int(n) => n
        _ => 11501
      }
      let msg = match rows[1][w - 3] {
        String(m) => m
        _ => ""
      }
      raise @types.sql_error(n, msg)
    }
    NoResult => {
      self.sp_describe_result([])
      0
    }
    Columns(q, bq) => {
      let rows = bq.columns.mapi((j, c) => {
        let (tid, tlen, cid, sid) = tds_facts(c.ty)
        describe_facts(q, bq, j) + [Int(tid), Int(tlen), cid, sid]
      })
      self.sp_describe_result(rows)
      0
    }
  }
}

///|
fn Session::sp_describe_result(
  self : Session,
  rows : Array[Array[@types.Value]],
) -> Unit {
  let sn = sysname_t()
  let cols = [
    spc("is_hidden", Bit, 0),
    spc("column_ordinal", Int, 0),
    spc("name", sn, 1),
    spc("is_nullable", Bit, 0),
    spc("system_type_id", Int, 0),
    spc("system_type_name", sn, 1),
    spc("max_length", SmallInt, 0),
    spc("precision", TinyInt, 0),
    spc("scale", TinyInt, 0),
    spc("collation_name", sn, 1),
    spc("user_type_id", Int, 1),
    spc("user_type_database", sn, 1),
    spc("user_type_schema", sn, 1),
    spc("user_type_name", sn, 1),
    spc("assembly_qualified_type_name", nvc(4000), 1),
    spc("xml_collection_id", Int, 1),
    spc("xml_collection_database", sn, 1),
    spc("xml_collection_schema", sn, 1),
    spc("xml_collection_name", sn, 1),
    spc("is_xml_document", Bit, 0),
    spc("is_case_sensitive", Bit, 0),
    spc("is_fixed_length_clr_type", Bit, 0),
    spc("source_server", sn, 1),
    spc("source_database", sn, 1),
    spc("source_schema", sn, 1),
    spc("source_table", sn, 1),
    spc("source_column", sn, 1),
    spc("is_identity_column", Bit, 1),
    spc("is_part_of_unique_key", Bit, 1),
    spc("is_updateable", Bit, 1),
    spc("is_computed_column", Bit, 1),
    spc("is_sparse_column_set", Bit, 1),
    spc("ordinal_in_order_by_list", SmallInt, 1),
    spc("order_by_is_descending", Bit, 1),
    spc("order_by_list_length", SmallInt, 1),
    spc("tds_type_id", Int, 0),
    spc("tds_length", Int, 0),
    spc("tds_collation_id", Int, 1),
    spc("tds_collation_sort_id", TinyInt, 1),
  ]
  self.out.push(ResultSet(cols))
  for r in rows {
    self.out.push(Row(r.map(wire_value)))
  }
  // captured: DONEINPROC MORE|COUNT with CurCmd 224 (msduck
  // json-constructors #021)
  self.done(224, count=Some(rows.length().to_int64()), result_set=true)
}
