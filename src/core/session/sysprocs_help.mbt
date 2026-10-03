// The sp_help family as SQL Server returns it: sp_help, sp_helptext,
// sp_columns, sp_tables, sp_pkeys, sp_fkeys, sp_who. Result shapes, the
// procedures' internal completions (DONEINPROC 192/193 sequences, captured
// per path) and messages come from harness/corpus/sysprocs/*.sql. Argument
// forms and object kinds that were not captured raise Emulator errors.

///|
/// A result column of a system procedure: name, type and the captured TDS
/// flags (1 nullable, 8 updateable, 0x20 computed).
fn spc(name : String, ty : @types.SqlType, flags : Int) -> @tds.Column {
  { name, type_info: type_info(ty, (flags & 1) != 0), flags, user_type: 0, }
}

///|
fn sysname_t() -> @types.SqlType {
  NVarChar(Some(128), @types.default_collation)
}

///|
fn nvc(n : Int) -> @types.SqlType {
  NVarChar(Some(n), @types.default_collation)
}

///|
fn vch(n : Int) -> @types.SqlType {
  VarChar(Some(n), @types.default_collation)
}

///|
fn opt_i(x : Int?) -> @types.Value {
  match x {
    Some(n) => Int(n)
    None => Null
  }
}

///|
fn opt_si(x : Int?) -> @types.Value {
  match x {
    Some(n) => SmallInt(n)
    None => Null
  }
}

///|
/// Sends one result set (COLMETADATA, optional ORDER, rows) and its
/// DONEINPROC 193 (with the row count unless the procedure runs with
/// NOCOUNT ON).
fn Session::sp_result(
  self : Session,
  cols : Array[@tds.Column],
  rows : Array[Array[@types.Value]],
  order? : Array[Int] = [],
) -> Unit {
  self.out.push(ResultSet(cols))
  if !order.is_empty() {
    self.out.push(Order(order))
  }
  for r in rows {
    self.out.push(Row(r.map(wire_value)))
  }
  self.done(193, count=Some(rows.length().to_int64()), result_set=true)
}

///|
/// Internal statement completions of a system procedure: `-1` is a CurCmd
/// 192 completion without a count, `n >= 0` a 193 completion counting n.
fn Session::sp_dones(self : Session, seq : Array[Int]) -> Unit {
  for c in seq {
    if c < 0 {
      self.done(192)
    } else {
      self.done(193, count=Some(c.to_int64()))
    }
  }
}

///|
/// An informational message of a system procedure (class 0).
fn Session::sp_info(
  self : Session,
  proc : String,
  line : Int,
  number : Int,
  text : String,
) -> Unit {
  self.out.push(
    Message({
      number,
      state: 1,
      class: 0,
      message: text,
      procedure: proc,
      line,
    }),
  )
}

///|
/// An error of a system procedure: ERROR, then DONEINPROC 246 with the
/// error flag (captured: 15009, 15197, 15007).
fn Session::sp_error(
  self : Session,
  proc : String,
  line : Int,
  number : Int,
  text : String,
) -> Unit {
  self.out.push(
    Message({
      number,
      state: 1,
      class: 16,
      message: text,
      procedure: proc,
      line,
    }),
  )
  self.rt.error = number
  self.out.push(InProcDone(cmd=246, count=None, error=true))
}

///|
/// Arguments of a system procedure by parameter name (positional ones in
/// declaration order). Unknown parameter names are not supported.
fn Session::sp_args(
  self : Session,
  proc : String,
  names : Array[String],
  args : Array[@ast.ExecArg],
) -> Map[String, @types.Value] raise {
  let out : Map[String, @types.Value] = Map([])
  for i, a in args {
    let key = match a.name {
      Some(n) => n.to_lower()
      None =>
        match names.get(i) {
          Some(n) => n
          None => raise @types.not_supported("this many arguments for \{proc}")
        }
    }
    if !names.contains(key) {
      raise @types.not_supported("parameter \{key} of \{proc}")
    }
    out[key] = self.eval(a.value).0
  }
  out
}

///|
fn arg_text(args : Map[String, @types.Value], key : String) -> String? {
  match args.get(key) {
    Some(String(s)) => Some(s)
    Some(Int(n)) | Some(SmallInt(n)) | Some(TinyInt(n)) => Some(n.to_string())
    Some(BigInt(n)) => Some(n.to_string())
    _ => None
  }
}

///|
/// Runs a system procedure body at @@NESTLEVEL + 1 and completes the EXEC
/// (RETURNSTATUS + DONEPROC, or DONEINPROC 224 when nested).
fn Session::run_sysproc(
  self : Session,
  return_var : String?,
  nocount : Bool,
  body : () -> Int raise,
) -> Unit raise {
  self.rt.nest_level += 1
  let saved = self.nocount
  if nocount {
    self.nocount = true
  }
  errdefer {
    self.rt.nest_level -= 1
    self.nocount = saved
  }
  let status = body()
  self.rt.nest_level -= 1
  self.nocount = saved
  match return_var {
    Some(rv) =>
      match self.frame().vars.get(rv.to_lower()) {
        Some(info) =>
          self.frame().values[info.slot] = @types.cast(
            Int(status),
            Int,
            info.ty,
          )
        None => ()
      }
    None => ()
  }
  self.proc_done(status)
}

///|
/// Parameter names (in order) and the NOCOUNT setting of the sp_help
/// family; None for other procedures.
fn help_proc_spec(name : String) -> (Array[String], Bool)? {
  match name {
    "sp_help" => Some((["@objname"], true))
    "sp_helptext" => Some((["@objname", "@columnname"], true))
    "sp_columns" =>
      Some(
        (
          [
            "@table_name", "@table_owner", "@table_qualifier", "@column_name", "@odbcver",
          ],
          false,
        ),
      )
    "sp_tables" =>
      Some(
        (
          [
            "@table_name", "@table_owner", "@table_qualifier", "@table_type", "@fusepattern",
          ],
          false,
        ),
      )
    "sp_pkeys" =>
      Some((["@table_name", "@table_owner", "@table_qualifier"], false))
    "sp_fkeys" =>
      Some(
        (
          [
            "@pktable_name", "@pktable_owner", "@pktable_qualifier", "@fktable_name",
            "@fktable_owner", "@fktable_qualifier",
          ],
          true,
        ),
      )
    "sp_who" => Some((["@loginame"], false))
    _ => None
  }
}

///|
fn Session::help_proc_run(
  self : Session,
  name : String,
  a : Map[String, @types.Value],
) -> Int raise {
  match name {
    "sp_help" => self.sp_help(arg_text(a, "@objname"))
    "sp_helptext" => {
      if a.contains("@columnname") {
        raise @types.not_supported("sp_helptext @columnname")
      }
      self.sp_helptext(arg_text(a, "@objname"))
    }
    "sp_columns" => self.sp_columns(a)
    "sp_tables" => self.sp_tables(a)
    "sp_pkeys" => self.sp_pkeys(a)
    "sp_fkeys" => self.sp_fkeys(a)
    _ => self.sp_who(a)
  }
}

///|
/// The sp_help family in a batch; false when `name` is not one of them.
fn Session::exec_help_proc(
  self : Session,
  name : String,
  args : Array[@ast.ExecArg],
  return_var : String?,
) -> Bool raise {
  guard help_proc_spec(name) is Some((names, nocount)) else { return false }
  let a = self.sp_args(name, names, args)
  self.run_sysproc(return_var, nocount, () => self.help_proc_run(name, a))
  true
}

///|
/// The sp_help family called by RPC name (tedious callProcedure): the
/// return status, or None for other procedures.
fn Session::rpc_help_proc(
  self : Session,
  name : String,
  params : Array[(String, @types.Value)],
) -> Int? raise {
  guard help_proc_spec(name) is Some((names, nocount)) else { return None }
  let a : Map[String, @types.Value] = Map([])
  for i, p in params {
    let key = if p.0 == "" {
      match names.get(i) {
        Some(n) => n
        None => raise @types.not_supported("this many arguments for \{name}")
      }
    } else {
      p.0.to_lower()
    }
    if !names.contains(key) {
      raise @types.not_supported("parameter \{key} of \{name}")
    }
    a[key] = p.1
  }
  self.rt.nest_level += 1
  let saved = self.nocount
  if nocount {
    self.nocount = true
  }
  errdefer {
    self.rt.nest_level -= 1
    self.nocount = saved
  }
  let status = self.help_proc_run(name, a)
  self.rt.nest_level -= 1
  self.nocount = saved
  Some(status)
}

// ---------------------------------------------------------------- sp_help

///|
/// sys.columns facts SQL Server's sp_help prints as Prec / Scale: char(5)
/// left-justified; real and float have no scale (captured).
fn help_prec_scale(t : @types.SqlType) -> (@types.Value, @types.Value) {
  let pad = (n : Int) => {
    let s = n.to_string()
    @types.Value::String(s + " ".repeat(@cmp.maximum(0, 5 - s.length())))
  }
  let blank = @types.Value::String("     ")
  let (_, _, _, p, sc) = type_ids(t)
  match t {
    TinyInt
    | SmallInt
    | Int
    | BigInt
    | Decimal(_, _)
    | Numeric(_, _)
    | Money
    | SmallMoney
    | Date
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_) => (pad(p), pad(sc))
    Real | Float => (pad(p), Null)
    _ => (blank, blank)
  }
}

///|
fn is_char_type(t : @types.SqlType) -> Bool {
  t is (Char(_, _) | VarChar(_, _) | NChar(_, _) | NVarChar(_, _))
}

///|
/// The columns result set of sp_help (tables and views).
fn Session::help_columns(
  self : Session,
  cols : Array[@store.Column],
) -> Unit raise {
  let rows : Array[Array[@types.Value]] = []
  for c in cols {
    if c.user_type is Some(_) {
      raise @types.not_supported("sp_help of a column of an alias type")
    }
    let (_, _, len, _, _) = type_ids(c.ty)
    let (prec, scale) = help_prec_scale(c.ty)
    let padded = c.ty
      is (Char(_, _) | VarChar(_, _) | Binary(_) | VarBinary(_) | Variant)
    let fixed_len = c.ty
      is (Char(_, _) | VarChar(_, _) | Binary(_) | VarBinary(_))
    rows.push([
      String(c.name),
      String(c.ty.base_name()),
      String(if c.computed is Some(_) { "yes" } else { "no" }),
      Int(len),
      prec,
      scale,
      String(if c.nullable { "yes" } else { "no" }),
      String(if padded { "no" } else { "(n/a)" }),
      String(
        if fixed_len {
          if c.nullable {
            "yes"
          } else {
            "no"
          }
        } else {
          "(n/a)"
        },
      ),
      if is_char_type(c.ty) {
        opt_s(c.ty.collation().map(x => x.name))
      } else {
        Null
      },
    ])
  }
  self.sp_result(
    [
      spc("Column_name", sysname_t(), 9),
      spc("Type", sysname_t(), 33),
      spc("Computed", vch(35), 33),
      spc("Length", Int, 33),
      spc("Prec", vch(5), 33),
      spc("Scale", vch(5), 33),
      spc("Nullable", vch(35), 33),
      spc("TrimTrailingBlanks", vch(35), 33),
      spc("FixedLenNullInSource", vch(35), 33),
      spc("Collation", sysname_t(), 9),
    ],
    rows,
  )
}

///|
fn Session::help_identity_rowguid(
  self : Session,
  cols : Array[@store.Column],
) -> Unit {
  let ident : Array[@types.Value] = match
    cols.search_by(c => c.identity is Some(_)) {
    Some(k) => {
      let c = cols[k]
      let id = c.identity.unwrap_or({ seed: 1L, increment: 1L, })
      let n = (v : Int64) => {
        @types.cast(BigInt(v), BigInt, Numeric(38, 0)) catch {
          _ => Null
        }
      }
      [String(c.name), n(id.seed), n(id.increment), Int(0)]
    }
    None => [String("No identity column defined."), Null, Null, Null]
  }
  self.sp_result(
    [
      spc("Identity", sysname_t(), 32),
      spc("Seed", Numeric(38, 0), 33),
      spc("Increment", Numeric(38, 0), 33),
      spc("Not For Replication", Int, 33),
    ],
    [ident],
  )
  self.sp_info("sp_help", 173, 0, " ")
  let guid = match cols.search_by(c => c.rowguidcol) {
    Some(k) => cols[k].name
    None => "No rowguidcol column defined."
  }
  self.sp_result([spc("RowGuidCol", sysname_t(), 32)], [[String(guid)]])
}

///|
/// sp_help @objname (captured for tables, views, procedures, alias and
/// table types, missing objects).
fn Session::sp_help(self : Session, objname : String?) -> Int raise {
  guard objname is Some(written) else {
    raise @types.not_supported("sp_help without an object name")
  }
  let target = self.name_target(written)
  let db = self.db_of(0)
  let obj = match target {
    Some((0, schema, base)) => db.lookup(schema, base)
    _ => None
  }
  let header = (name : String, schema : String, kind : String, created : Int64) => {
    self.sp_result(
      [
        spc("Name", sysname_t(), 8),
        spc("Owner", sysname_t(), 33),
        spc("Type", nvc(31), 33),
        spc("Created_datetime", DateTime, 8),
      ],
      [[String(name), String(schema), String(kind), dt(created)]],
    )
    self.sp_info("sp_help", 122, 0, " ")
  }
  match obj {
    Some(id) =>
      match (db.table(id), db.get_module(id)) {
        (Some(t), _) => {
          header(t.name, t.schema, "user table", t.created)
          self.help_table(db, t, written)
          return 0
        }
        (_, Some(m)) if m.kind is View => {
          header(m.name, m.schema, "view", m.created)
          self.sp_info("sp_help", 135, 0, " ")
          self.help_columns(m.columns)
          self.sp_info("sp_help", 164, 0, " ")
          self.help_identity_rowguid(m.columns)
          self.sp_info("sp_help", 223, 0, " ")
          self.sp_info(
            "sp_help",
            224,
            15469,
            "No constraints are defined on object '\{written}', or you do not have permissions.",
          )
          self.sp_info("sp_help", 225, 0, " ")
          self.sp_info(
            "sp_help",
            226,
            15470,
            "No foreign keys reference table '\{written}', or you do not have permissions on referencing tables.",
          )
          self.sp_info(
            "sp_helpindex",
            64,
            15472,
            "The object '\{written}' does not have any indexes, or you do not have permissions.",
          )
          return 0
        }
        (_, Some(m)) if m.kind is Procedure => {
          let params = module_params(m)
          let rows : Array[Array[@types.Value]] = []
          for k, p in params {
            rows.push(self.help_param(p, k + 1))
          }
          header(m.name, m.schema, "stored procedure", m.created)
          if !rows.is_empty() {
            self.sp_info("sp_help", 184, 0, " ")
            self.sp_result(
              [
                spc("Parameter_name", sysname_t(), 9),
                spc("Type", sysname_t(), 33),
                spc("Length", SmallInt, 8),
                spc("Prec", Int, 33),
                spc("Scale", Int, 33),
                spc("Param_order", Int, 8),
                spc("Collation", sysname_t(), 33),
              ],
              rows,
            )
          }
          return 0
        }
        (_, Some(m)) => {
          let (_, desc) = m.kind.code()
          raise @types.not_supported("sp_help of a \{desc.to_lower()}")
        }
        _ => ()
      }
    None => ()
  }
  match target {
    Some((0, schema, base)) =>
      match db.lookup_type(schema, base) {
        Some(ut) => {
          let row : Array[@types.Value] = match (ut.base, ut.table) {
            (Some(t), _) => {
              let (_, _, len, p, sc) = type_ids(t)
              let (prec, scale) : (@types.Value, @types.Value) = match t {
                Decimal(_, _) | Numeric(_, _) => (Int(p), Int(sc))
                Char(n, _)
                | VarChar(Some(n), _)
                | NChar(n, _)
                | NVarChar(Some(n), _) => (Int(n), Null)
                _ => raise @types.not_supported("sp_help of this alias type")
              }
              [
                String(ut.name),
                String(t.base_name()),
                SmallInt(len),
                prec,
                scale,
                String(if ut.nullable { "yes" } else { "no" }),
                String("none"),
                String("none"),
                if is_char_type(t) {
                  opt_s(t.collation().map(x => x.name))
                } else {
                  Null
                },
              ]
            }
            _ =>
              [
                String(ut.name),
                String("table type"),
                SmallInt(-1),
                Int(0),
                Null,
                String("no"),
                String("none"),
                String("none"),
                Null,
              ]
          }
          self.sp_result(
            [
              spc("Type_name", sysname_t(), 8),
              spc("Storage_type", sysname_t(), 33),
              spc("Length", SmallInt, 8),
              spc("Prec", Int, 33),
              spc("Scale", Int, 33),
              spc("Nullable", vch(35), 33),
              spc("Default_name", sysname_t(), 33),
              spc("Rule_name", sysname_t(), 33),
              spc("Collation", sysname_t(), 33),
            ],
            [row],
          )
          return 0
        }
        None => ()
      }
    _ => ()
  }
  self.sp_error(
    "sp_help",
    79,
    15009,
    "The object '\{written}' does not exist in database '\{self.rt.database}' or is invalid for this operation.",
  )
  1
}

///|
/// One row of sp_help's parameter list (captured for int, bigint, bit,
/// decimal, float, date, datetime2, uniqueidentifier and character /
/// binary types).
fn Session::help_param(
  self : Session,
  p : @ast.Param,
  order : Int,
) -> Array[@types.Value] raise {
  let t = match self.decl_type(p.type_, @types.default_collation) {
    ScalarDecl(t, None, _) => t
    _ =>
      raise @types.not_supported(
        "sp_help of a procedure with this parameter type",
      )
  }
  let (_, _, len, p0, sc) = type_ids(t)
  let (prec, scale) : (Int, @types.Value) = match t {
    TinyInt
    | SmallInt
    | Int
    | BigInt
    | Decimal(_, _)
    | Numeric(_, _)
    | Date
    | DateTime2(_) => (p0, Int(sc))
    Bit | Float | UniqueIdentifier => (p0, Null)
    Char(n, _) | NChar(n, _) | Binary(n) => (n, Null)
    VarChar(n, _) | NVarChar(n, _) | VarBinary(n) => (n.unwrap_or(0), Null)
    _ =>
      raise @types.not_supported(
        "sp_help of a procedure with a \{t.base_name()} parameter",
      )
  }
  [
    String(p.name),
    String(t.base_name()),
    SmallInt(len),
    Int(prec),
    scale,
    Int(order),
    if is_char_type(t) {
      opt_s(t.collation().map(x => x.name))
    } else {
      Null
    },
  ]
}

///|
/// The table part of sp_help (after the header).
fn Session::help_table(
  self : Session,
  db : @store.Db,
  t : @store.Table,
  written : String,
) -> Unit raise {
  if db.modules().iter().any(m => m.kind is View && m.schema_bound) {
    raise @types.not_supported(
      "sp_help of a table when schema-bound views exist",
    )
  }
  self.sp_info("sp_help", 135, 0, " ")
  self.help_columns(t.columns)
  self.sp_info("sp_help", 164, 0, " ")
  self.help_identity_rowguid(t.columns)
  self.sp_info("sp_help", 202, 0, " ")
  self.sp_result([spc("Data_located_on_filegroup", sysname_t(), 8)], [
    [String("PRIMARY")],
  ])
  self.sp_info("sp_help", 204, 0, " ")
  if t.indexes.is_empty() {
    self.sp_info(
      "sp_helpindex",
      64,
      15472,
      "The object '\{written}' does not have any indexes, or you do not have permissions.",
    )
  } else {
    self.sp_result(
      [
        spc("index_name", sysname_t(), 8),
        spc("index_description", vch(210), 33),
        spc("index_keys", nvc(2126), 9),
      ],
      helpindex_rows(t).map(r => [String(r.0), String(r.1), String(r.2)]),
      order=[1],
    )
  }
  self.sp_info("sp_help", 206, 0, " ")
  let cons = self.help_constraints(t)
  if cons.is_empty() {
    self.sp_info(
      "sp_helpconstraint",
      340,
      15469,
      "No constraints are defined on object '\{written}', or you do not have permissions.",
    )
  } else {
    self.sp_result(
      [
        spc("constraint_type", nvc(256), 8),
        spc("constraint_name", sysname_t(), 8),
        spc("delete_action", vch(11), 0),
        spc("update_action", vch(11), 0),
        spc("status_enabled", vch(8), 0),
        spc("status_for_replication", vch(19), 0),
        spc("constraint_keys", nvc(2126), 9),
      ],
      cons,
      order=[0, 2],
    )
  }
  self.sp_info("sp_help", 342, 0, " ")
  let refs = []
  for other in db.tables() {
    for fk in other.foreign_keys {
      if fk.ref_table == t.id {
        refs.push(
          "\{self.rt.database}.\{other.schema}.\{other.name}: \{fk.name}",
        )
      }
    }
  }
  if refs.is_empty() {
    self.sp_info(
      "sp_helpconstraint",
      353,
      15470,
      "No foreign keys reference table '\{written}', or you do not have permissions on referencing tables.",
    )
  } else {
    refs.sort_by((a, b) => collate_cmp(a, b))
    self.sp_result(
      [spc("Table is referenced by foreign key", nvc(516), 33)],
      refs.map(r => [String(r)]),
      order=[1],
    )
  }
  self.sp_info(
    "sp_help",
    211,
    15647,
    "No views with schema binding reference table '\{written}'.",
  )
}

///|
fn collate_cmp(a : String, b : String) -> Int {
  (@types.compare(String(a), String(b), collation=@types.default_collation) catch {
    _ => None
  }).unwrap_or(0)
}

///|
fn ref_action_text(a : @store.RefAction) -> String {
  match a {
    NoAction => "No Action"
    Cascade => "Cascade"
    SetNull => "Set Null"
    SetDefault => "Set Default"
  }
}

///|
/// sp_helpconstraint's rows (as sp_help shows them), ordered by constraint
/// name; a FOREIGN KEY row is followed by its REFERENCES row.
fn Session::help_constraints(
  self : Session,
  t : @store.Table,
) -> Array[Array[@types.Value]] {
  let items : Array[(String, Array[Array[@types.Value]])] = []
  let na = @types.Value::String("(n/a)")
  let keys = (cols : Array[(Int, Bool)]) => {
    cols
    .map(c => t.columns[c.0].name + (if c.1 { "(-)" } else { "" }))
    .join(", ")
  }
  for c in t.checks {
    let single = check_column_suffix(t, c.expr)
    let kind = if c.column_id != 0 || single != "" {
      let name = match t.column_by_id(c.column_id) {
        Some(col) => col.name
        None => {
          // ", column 'x'" → x
          let n = single.length()
          single.unsafe_substring(start=10, end=n - 1)
        }
      }
      "CHECK on column \{name}"
    } else {
      "CHECK Table Level "
    }
    items.push(
      (
        c.name,
        [
          [
            String(kind),
            String(c.name),
            na,
            na,
            String(if c.enabled { "Enabled" } else { "Disabled" }),
            String(
              if c.not_for_replication {
                "Not_For_Replication"
              } else {
                "Is_For_Replication"
              },
            ),
            String(definition_text(c.expr)),
          ],
        ],
      ),
    )
  }
  for c in t.columns {
    match (c.default_name, c.default_) {
      (Some(n), Some(d)) =>
        items.push(
          (
            n,
            [
              [
                String("DEFAULT on column \{c.name}"),
                String(n),
                na,
                na,
                na,
                na,
                String(definition_text(d)),
              ],
            ],
          ),
        )
      _ => ()
    }
  }
  for fk in t.foreign_keys {
    let parent = self.db_of(0).table(fk.ref_table)
    let pname = match parent {
      Some(p) => "\{self.rt.database}.\{p.schema}.\{p.name}"
      None => ""
    }
    let pcols = match parent {
      Some(p) => fk.ref_columns.map(i => p.columns[i].name).join(", ")
      None => ""
    }
    let sp = @types.Value::String(" ")
    items.push(
      (
        fk.name,
        [
          [
            String("FOREIGN KEY"),
            String(fk.name),
            String(ref_action_text(fk.on_delete)),
            String(ref_action_text(fk.on_update)),
            String(if fk.enabled { "Enabled" } else { "Disabled" }),
            String(
              if fk.not_for_replication {
                "Not_For_Replication"
              } else {
                "Is_For_Replication"
              },
            ),
            String(fk.columns.map(i => t.columns[i].name).join(", ")),
          ],
          [sp, sp, sp, sp, sp, sp, String("REFERENCES \{pname} (\{pcols})")],
        ],
      ),
    )
  }
  for ix in t.indexes {
    guard ix.is_constraint else { continue }
    let cl = if ix.clustered { "clustered" } else { "non-clustered" }
    let kind = if ix.primary { "PRIMARY KEY (\{cl})" } else { "UNIQUE (\{cl})" }
    items.push(
      (
        ix.name,
        [
          [
            String(kind),
            String(ix.name),
            na,
            na,
            na,
            na,
            String(keys(ix.columns)),
          ],
        ],
      ),
    )
  }
  items.sort_by((a, b) => collate_cmp(a.0, b.0))
  let out = []
  for it in items {
    out.append(it.1)
  }
  out
}

///|
/// sp_helpindex rows of a table: (name, description, keys) by name.
fn helpindex_rows(t : @store.Table) -> Array[(String, String, String)] {
  let rows = t.indexes.map(ix => {
    let parts = [if ix.clustered { "clustered" } else { "nonclustered" }]
    if ix.unique {
      parts.push("unique")
    }
    if ix.primary {
      parts.push("primary key")
    } else if ix.object_id != 0 {
      parts.push("unique key")
    }
    let keys = ix.columns.map(c => {
      t.columns[c.0].name + (if c.1 { "(-)" } else { "" })
    })
    (ix.name, parts.join(", ") + " located on PRIMARY", keys.join(", "))
  })
  rows.sort_by((a, b) => collate_cmp(a.0, b.0))
  rows
}

// ------------------------------------------------------------ sp_helptext

///|
/// Splits module text like sp_helptext: a line ends after CR LF or at 255
/// characters (a lone CR or LF does not end it; captured).
fn helptext_lines(text : String) -> Array[String] {
  let out = []
  let cur = StringBuilder()
  let mut n = 0
  let len = text.length()
  let mut k = 0
  while k < len {
    let c = text.code_unit_at(k)
    if c.to_int() == 13 &&
      k + 1 < len &&
      text.code_unit_at(k + 1).to_int() == 10 {
      if n + 2 > 255 {
        // keep CR LF together on a new line (not captured either way)
        out.push(cur.to_string())
        cur.reset()
        n = 0
      }
      cur.write_char(c.unsafe_to_char())
      cur.write_char(text.code_unit_at(k + 1).unsafe_to_char())
      out.push(cur.to_string())
      cur.reset()
      n = 0
      k += 2
      continue
    }
    cur.write_char(c.unsafe_to_char())
    n += 1
    if n == 255 {
      out.push(cur.to_string())
      cur.reset()
      n = 0
    }
    k += 1
  }
  if n > 0 {
    out.push(cur.to_string())
  }
  out
}

///|
fn Session::sp_helptext(self : Session, objname : String?) -> Int raise {
  guard objname is Some(written) else {
    raise @types.not_supported("sp_helptext without an object name")
  }
  let db = self.db_of(0)
  let id = match self.name_target(written) {
    Some((0, schema, base)) => db.lookup(schema, base)
    _ => None
  }
  match id {
    None => {
      self.sp_error(
        "sp_helptext",
        54,
        15009,
        "The object '\{written}' does not exist in database '\{self.rt.database}' or is invalid for this operation.",
      )
      1
    }
    Some(id) =>
      match db.get_module(id) {
        Some(m) if m.kind
          is (View
          | Procedure
          | ScalarFunction
          | InlineFunction
          | TableFunction
          | Trigger) => {
          self.sp_result(
            [spc("Text", nvc(255), 9)],
            helptext_lines(m.definition).map(l => [String(l)]),
            order=[0],
          )
          0
        }
        Some(m) => {
          let (_, desc) = m.kind.code()
          raise @types.not_supported("sp_helptext of a \{desc.to_lower()}")
        }
        None => {
          self.sp_error(
            "sp_helptext",
            107,
            15197,
            "There is no text for object '\{written}'.",
          )
          1
        }
      }
  }
}

// ------------------------------------------------------- ODBC catalog procs

///|
/// `name` matched against an ODBC catalog pattern (`_` any character;
/// `%` and `[` patterns are not supported).
fn odbc_match(pattern : String, name : String) -> Bool raise {
  if pattern.contains("%") || pattern.contains("[") {
    raise @types.not_supported(
      "wildcard patterns in catalog procedure arguments",
    )
  }
  if pattern.length() != name.length() {
    return false
  }
  let p = pattern.to_lower()
  let n = name.to_lower()
  for k in 0..<p.length() {
    let c = p.code_unit_at(k)
    if c.to_int() != 95 && c != n.code_unit_at(k) {
      return false
    }
  }
  true
}

///|
/// Tables (and views) whose name and owner match the arguments.
fn Session::odbc_objects(
  self : Session,
  name : String,
  owner : String?,
  qualifier : String?,
  views : Bool,
) -> Array[(String, String, Bool, @store.Table?, @store.Module?)] raise {
  match qualifier {
    Some(q) if q.to_lower() != self.rt.database.to_lower() =>
      raise @types.not_supported("catalog procedures for another database")
    _ => ()
  }
  let db = self.db_of(0)
  let out = []
  let owner_ok = (s : String) => {
    match owner {
      Some(o) => odbc_match(o, s)
      None => true
    }
  }
  for t in db.tables() {
    if odbc_match(name, t.name) && owner_ok(t.schema) {
      out.push((t.schema, t.name, false, Some(t), None))
    }
  }
  if views {
    for m in db.modules() {
      if m.kind is View && odbc_match(name, m.name) && owner_ok(m.schema) {
        out.push((m.schema, m.name, true, None, Some(m)))
      }
    }
  }
  out
}

///|
/// ODBC 2 facts of a column for sp_columns: (DATA_TYPE, TYPE_NAME,
/// PRECISION, LENGTH, SCALE, RADIX, SQL_DATA_TYPE, SQL_DATETIME_SUB,
/// CHAR_OCTET_LENGTH, SS_DATA_TYPE), all captured
/// (sysprocs/sp-columns: tables kinds, kinds2).
fn odbc_column(
  t : @types.SqlType,
  nullable : Bool,
) -> (Int, String, Int, Int, Int?, Int?, Int, Int?, Int?, Int) {
  let nn = !nullable
  let temporal = (base : Int, s : Int) => base + (if s > 0 { s + 1 } else { 0 })
  match t {
    Bit => (-7, "bit", 1, 1, None, None, -7, None, None, 50)
    TinyInt =>
      (
        -6,
        "tinyint",
        3,
        1,
        Some(0),
        Some(10),
        -6,
        None,
        None,
        if nn {
          48
        } else {
          38
        },
      )
    SmallInt =>
      (
        5,
        "smallint",
        5,
        2,
        Some(0),
        Some(10),
        5,
        None,
        None,
        if nn {
          52
        } else {
          38
        },
      )
    Int =>
      (
        4,
        "int",
        10,
        4,
        Some(0),
        Some(10),
        4,
        None,
        None,
        if nn {
          56
        } else {
          38
        },
      )
    BigInt =>
      (
        -5,
        "bigint",
        19,
        8,
        Some(0),
        Some(10),
        -5,
        None,
        None,
        if nn {
          63
        } else {
          108
        },
      )
    Decimal(p, s) =>
      (
        3,
        "decimal",
        p,
        p + 2,
        Some(s),
        Some(10),
        3,
        None,
        None,
        if nn {
          55
        } else {
          106
        },
      )
    Numeric(p, s) =>
      (
        2,
        "numeric",
        p,
        p + 2,
        Some(s),
        Some(10),
        2,
        None,
        None,
        if nn {
          63
        } else {
          108
        },
      )
    Money =>
      (
        3,
        "money",
        19,
        21,
        Some(4),
        Some(10),
        3,
        None,
        None,
        if nn {
          60
        } else {
          110
        },
      )
    SmallMoney =>
      (
        3,
        "smallmoney",
        10,
        12,
        Some(4),
        Some(10),
        3,
        None,
        None,
        if nn {
          122
        } else {
          110
        },
      )
    Float =>
      (
        6,
        "float",
        15,
        8,
        None,
        Some(10),
        6,
        None,
        None,
        if nn {
          62
        } else {
          109
        },
      )
    Real =>
      (
        7,
        "real",
        7,
        4,
        None,
        Some(10),
        7,
        None,
        None,
        if nn {
          59
        } else {
          109
        },
      )
    DateTime =>
      (
        11,
        "datetime",
        23,
        16,
        Some(3),
        None,
        9,
        Some(3),
        None,
        if nn {
          61
        } else {
          111
        },
      )
    SmallDateTime =>
      (
        11,
        "smalldatetime",
        16,
        16,
        Some(0),
        None,
        9,
        Some(3),
        None,
        if nn {
          58
        } else {
          111
        },
      )
    Date => (-9, "date", 10, 20, None, None, -9, None, None, 0)
    Time(s) => {
      let p = temporal(8, s)
      (-9, "time", p, 2 * p, None, None, -9, None, None, 0)
    }
    DateTime2(s) => {
      let p = temporal(19, s)
      (-9, "datetime2", p, 2 * p, None, None, -9, None, None, 0)
    }
    DateTimeOffset(s) => {
      let p = temporal(26, s)
      (-9, "datetimeoffset", p, 2 * p, None, None, -9, None, None, 0)
    }
    UniqueIdentifier =>
      (-11, "uniqueidentifier", 36, 16, None, None, -11, None, None, 37)
    Char(n, _) =>
      (1, "char", n, n, None, None, 1, None, Some(n), if nn { 47 } else { 39 })
    VarChar(Some(n), _) =>
      (12, "varchar", n, n, None, None, 12, None, Some(n), 39)
    VarChar(None, _) =>
      (
        -1,
        "text",
        2147483647,
        2147483647,
        None,
        None,
        -1,
        None,
        Some(2147483647),
        39,
      )
    NChar(n, _) =>
      (
        -8,
        "nchar",
        n,
        2 * n,
        None,
        None,
        -8,
        None,
        Some(2 * n),
        if nn {
          47
        } else {
          39
        },
      )
    NVarChar(Some(n), _) =>
      (-9, "nvarchar", n, 2 * n, None, None, -9, None, Some(2 * n), 39)
    NVarChar(None, _) =>
      (
        -10,
        "ntext",
        1073741823,
        2147483646,
        None,
        None,
        -10,
        None,
        Some(2147483646),
        39,
      )
    Binary(n) =>
      (
        -2,
        "binary",
        n,
        n,
        None,
        None,
        -2,
        None,
        Some(n),
        if nn {
          45
        } else {
          37
        },
      )
    VarBinary(Some(n)) =>
      (-3, "varbinary", n, n, None, None, -3, None, Some(n), 37)
    VarBinary(None) =>
      (
        -4,
        "image",
        2147483647,
        2147483647,
        None,
        None,
        -4,
        None,
        Some(2147483647),
        37,
      )
    RowVersion => (-2, "timestamp", 8, 8, None, None, -2, None, Some(8), 45)
    Variant =>
      (-150, "sql_variant", 0, 8000, None, Some(10), -150, None, Some(8000), 39)
  }
}

///|
/// sp_columns @table_name [, @table_owner] [, @column_name] (captured;
/// the internal completions differ when the table is not found).
fn Session::sp_columns(
  self : Session,
  a : Map[String, @types.Value],
) -> Int raise {
  if a.contains("@odbcver") {
    raise @types.not_supported("sp_columns @ODBCVer")
  }
  guard arg_text(a, "@table_name") is Some(name) else {
    raise @types.not_supported("sp_columns without @table_name")
  }
  let objs = self.odbc_objects(
    name,
    arg_text(a, "@table_owner"),
    arg_text(a, "@table_qualifier"),
    true,
  )
  if objs.length() > 1 {
    raise @types.not_supported("sp_columns patterns matching several tables")
  }
  let column = arg_text(a, "@column_name")
  let rows : Array[Array[@types.Value]] = []
  for o in objs {
    let (schema, tname, _, t, m) = o
    let cols = match (t, m) {
      (Some(t), _) => t.columns
      (_, Some(m)) => m.columns
      _ => []
    }
    for k, c in cols {
      match column {
        Some(cn) => if !odbc_match(cn, c.name) { continue }
        None => ()
      }
      if c.user_type is Some(_) {
        raise @types.not_supported("sp_columns of a column of an alias type")
      }
      let (dt_, tn, prec, len, scale, radix, sqlt, sub, octet, ss) = odbc_column(
        c.ty,
        c.nullable,
      )
      rows.push([
        String(self.rt.database),
        String(schema),
        String(tname),
        String(c.name),
        SmallInt(dt_),
        String(if c.identity is Some(_) { tn + " identity" } else { tn }),
        Int(prec),
        Int(len),
        opt_si(scale),
        opt_si(radix),
        SmallInt(if c.nullable { 1 } else { 0 }),
        Null,
        match c.default_ {
          Some(d) => String(definition_text(d))
          None => Null
        },
        SmallInt(sqlt),
        opt_si(sub),
        opt_i(octet),
        Int(k + 1),
        String(if c.nullable { "YES" } else { "NO" }),
        TinyInt(ss),
      ])
    }
  }
  let found = !objs.is_empty()
  self.sp_dones([1, -1, 1, -1, -1, -1, -1, -1, -1, 1, 1, -1, -1])
  self.sp_dones(if found { [1, -1] } else { [-1] })
  let s = nvc(128)
  self.sp_result(
    [
      spc("TABLE_QUALIFIER", s, 33),
      spc("TABLE_OWNER", s, 33),
      spc("TABLE_NAME", s, 33),
      spc("COLUMN_NAME", s, 33),
      spc("DATA_TYPE", SmallInt, 33),
      spc("TYPE_NAME", s, 33),
      spc("PRECISION", Int, 33),
      spc("LENGTH", Int, 33),
      spc("SCALE", SmallInt, 33),
      spc("RADIX", SmallInt, 9),
      spc("NULLABLE", SmallInt, 33),
      spc("REMARKS", vch(254), 33),
      spc("COLUMN_DEF", nvc(4000), 33),
      spc("SQL_DATA_TYPE", SmallInt, 33),
      spc("SQL_DATETIME_SUB", SmallInt, 33),
      spc("CHAR_OCTET_LENGTH", Int, 33),
      spc("ORDINAL_POSITION", Int, 33),
      spc("IS_NULLABLE", vch(254), 33),
      spc("SS_DATA_TYPE", TinyInt, 33),
    ],
    rows,
    order=if found { [17] } else { [2, 3, 17] },
  )
  0
}

///|
/// sp_tables @table_name [, @table_owner] (captured; user tables and
/// views only: system objects matching the name are not listed).
fn Session::sp_tables(
  self : Session,
  a : Map[String, @types.Value],
) -> Int raise {
  if a.contains("@table_type") || a.contains("@fusepattern") {
    raise @types.not_supported("sp_tables @table_type / @fUsePattern")
  }
  guard arg_text(a, "@table_name") is Some(name) else {
    raise @types.not_supported("sp_tables without @table_name")
  }
  let owner = arg_text(a, "@table_owner")
  let objs = self.odbc_objects(
    name,
    owner,
    arg_text(a, "@table_qualifier"),
    true,
  )
  let rows = objs.map(o => {
    [
      @types.Value::String(self.rt.database),
      String(o.0),
      String(o.1),
      String(if o.2 { "VIEW" } else { "TABLE" }),
      Null,
    ]
  })
  rows.sort_by((x, y) => {
    let c = collate_cmp(value_text(x[3]), value_text(y[3]))
    if c != 0 {
      return c
    }
    let c2 = collate_cmp(value_text(x[1]), value_text(y[1]))
    if c2 != 0 {
      c2
    } else {
      collate_cmp(value_text(x[2]), value_text(y[2]))
    }
  })
  let found = !rows.is_empty()
  self.sp_dones([-1, -1, -1, -1, 1, -1, 1, -1, -1])
  if owner is None {
    self.sp_dones([-1])
  }
  self.sp_dones([1, 1])
  if found && owner is None {
    self.sp_dones([1])
  }
  self.sp_dones(if found { [-1, -1, 1, -1] } else { [-1, -1, -1] })
  let s = nvc(128)
  self.sp_result(
    [
      spc("TABLE_QUALIFIER", s, 33),
      spc("TABLE_OWNER", s, 33),
      spc("TABLE_NAME", s, 33),
      spc("TABLE_TYPE", vch(32), 33),
      spc("REMARKS", vch(254), 33),
    ],
    rows,
    order=[4, 1, 2, 3],
  )
  0
}

///|
/// sp_pkeys @table_name [, @table_owner] (captured).
fn Session::sp_pkeys(
  self : Session,
  a : Map[String, @types.Value],
) -> Int raise {
  guard arg_text(a, "@table_name") is Some(name) else {
    raise @types.not_supported("sp_pkeys without @table_name")
  }
  let owner = arg_text(a, "@table_owner")
  let objs = self.odbc_objects(
    name,
    owner,
    arg_text(a, "@table_qualifier"),
    false,
  )
  let rows : Array[Array[@types.Value]] = []
  for o in objs {
    guard o.3 is Some(t) else { continue }
    guard t.primary_key() is Some(pk) else { continue }
    for k, c in pk.columns {
      rows.push([
        @types.Value::String(self.rt.database),
        String(t.schema),
        String(t.name),
        String(t.columns[c.0].name),
        SmallInt(k + 1),
        String(pk.name),
      ])
    }
  }
  self.sp_dones(
    if owner is Some(_) {
      [-1, -1, -1, 1, 1]
    } else {
      [-1, -1, 1, 1]
    },
  )
  let s = nvc(128)
  self.sp_result(
    [
      spc("TABLE_QUALIFIER", s, 33),
      spc("TABLE_OWNER", s, 33),
      spc("TABLE_NAME", s, 33),
      spc("COLUMN_NAME", s, 33),
      spc("KEY_SEQ", SmallInt, 33),
      spc("PK_NAME", s, 33),
    ],
    rows,
    order=[1, 2, 3, 5],
  )
  0
}

///|
/// ODBC update/delete rule codes of sp_fkeys (1 = NO ACTION, captured).
fn odbc_rule(a : @store.RefAction) -> Int {
  match a {
    Cascade => 0
    NoAction => 1
    SetNull => 2
    SetDefault => 3
  }
}

///|
/// sp_fkeys @pktable_name / @fktable_name [, owners] (captured).
fn Session::sp_fkeys(
  self : Session,
  a : Map[String, @types.Value],
) -> Int raise {
  let pk_name = arg_text(a, "@pktable_name")
  let fk_name = arg_text(a, "@fktable_name")
  if pk_name is None && fk_name is None {
    raise @types.not_supported("sp_fkeys without a table name")
  }
  let pk_tables = match pk_name {
    Some(n) =>
      Some(
        self
        .odbc_objects(
          n,
          arg_text(a, "@pktable_owner"),
          arg_text(a, "@pktable_qualifier"),
          false,
        )
        .map(o => o.1.to_lower() + "." + o.0.to_lower()),
      )
    None => None
  }
  let fk_tables = match fk_name {
    Some(n) =>
      Some(
        self
        .odbc_objects(
          n,
          arg_text(a, "@fktable_owner"),
          arg_text(a, "@fktable_qualifier"),
          false,
        )
        .map(o => o.1.to_lower() + "." + o.0.to_lower()),
      )
    None => None
  }
  let db = self.db_of(0)
  let rows : Array[Array[@types.Value]] = []
  for t in db.tables() {
    match fk_tables {
      Some(l) =>
        if !l.contains(t.name.to_lower() + "." + t.schema.to_lower()) {
          continue
        }
      None => ()
    }
    for fk in t.foreign_keys {
      guard db.table(fk.ref_table) is Some(p) else { continue }
      match pk_tables {
        Some(l) =>
          if !l.contains(p.name.to_lower() + "." + p.schema.to_lower()) {
            continue
          }
        None => ()
      }
      // the referenced key: a unique index on exactly the referenced columns
      let key : @types.Value = match
        p.indexes.search_by(ix => {
          ix.unique && ix.columns.map(c => c.0) == fk.ref_columns
        }) {
        Some(k) => String(p.indexes[k].name)
        None => Null
      }
      for k, c in fk.columns {
        rows.push([
          @types.Value::String(self.rt.database),
          String(p.schema),
          String(p.name),
          String(p.columns[fk.ref_columns[k]].name),
          String(self.rt.database),
          String(t.schema),
          String(t.name),
          String(t.columns[c].name),
          SmallInt(k + 1),
          SmallInt(odbc_rule(fk.on_update)),
          SmallInt(odbc_rule(fk.on_delete)),
          String(fk.name),
          key,
          SmallInt(7),
        ])
      }
    }
  }
  // the ORDER columns (0-based)
  let by = if pk_name is Some(_) { [4, 5, 6, 8, 7] } else { [0, 1, 2, 8, 3] }
  rows.sort_by((x, y) => {
    for i in by {
      let c = if i == 8 {
        match (x[i], y[i]) {
          (SmallInt(p), SmallInt(q)) => p.compare(q)
          _ => 0
        }
      } else {
        collate_cmp(value_text(x[i]), value_text(y[i]))
      }
      if c != 0 {
        return c
      }
    }
    0
  })
  let s = nvc(128)
  self.sp_result(
    [
      spc("PKTABLE_QUALIFIER", s, 33),
      spc("PKTABLE_OWNER", s, 33),
      spc("PKTABLE_NAME", s, 33),
      spc("PKCOLUMN_NAME", s, 9),
      spc("FKTABLE_QUALIFIER", s, 33),
      spc("FKTABLE_OWNER", s, 33),
      spc("FKTABLE_NAME", s, 33),
      spc("FKCOLUMN_NAME", s, 9),
      spc("KEY_SEQ", SmallInt, 32),
      spc("UPDATE_RULE", SmallInt, 33),
      spc("DELETE_RULE", SmallInt, 33),
      spc("FK_NAME", s, 33),
      spc("PK_NAME", s, 9),
      spc("DEFERRABILITY", SmallInt, 33),
    ],
    rows,
    order=if pk_name is Some(_) { [5, 6, 7, 9, 8] } else { [1, 2, 3, 9, 4] },
  )
  0
}

// ----------------------------------------------------------------- sp_who

///|
fn pad_to(s : String, n : Int) -> String {
  if s.length() >= n {
    s
  } else {
    s + " ".repeat(n - s.length())
  }
}

///|
/// sp_who for the caller's own session id or an unknown login (15007);
/// other forms list system sessions bitsql does not have.
fn Session::sp_who(self : Session, a : Map[String, @types.Value]) -> Int raise {
  guard arg_text(a, "@loginame") is Some(who) else {
    raise @types.not_supported("sp_who without a session id")
  }
  let spid = digits_value(who.trim().to_owned())
  if spid == self.rt.spid {
    self.sp_dones([1, -1, -1, -1, 1])
    self.sp_result(
      [
        spc("spid", SmallInt, 8),
        spc("ecid", SmallInt, 8),
        spc("status", NChar(30, @types.default_collation), 8),
        spc("loginame", nvc(128), 33),
        spc("hostname", NChar(128, @types.default_collation), 8),
        spc("blk", Char(5, @types.default_collation), 33),
        spc("dbname", nvc(128), 33),
        spc("cmd", NChar(26, @types.default_collation), 8),
        spc("request_id", Int, 8),
      ],
      [
        [
          SmallInt(spid),
          SmallInt(0),
          String(pad_to("runnable", 30)),
          String(self.login),
          String(pad_to(self.host_name, 128)),
          String("0    "),
          String(self.rt.database),
          String(pad_to("SELECT", 26)),
          Int(0),
        ],
      ],
    )
    self.sp_dones([1])
    return 0
  }
  let lower = who.to_lower()
  if spid >= 0 || lower == "active" || lower == self.login.to_lower() {
    raise @types.not_supported("sp_who for other sessions or logins")
  }
  self.sp_dones([1, -1, -1, -1, 1, -1])
  self.sp_error(
    "sp_who",
    59,
    15007,
    "'\{who}' is not a valid login or you do not have permission.",
  )
  self.sp_dones([1])
  1
}

///|
/// A non-negative decimal number, or -1.
fn digits_value(s : String) -> Int {
  if s.is_empty() || s.length() > 9 {
    return -1
  }
  let mut v = 0
  for c in s {
    if c < '0' || c > '9' {
      return -1
    }
    v = v * 10 + (c.to_int() - '0'.to_int())
  }
  v
}
