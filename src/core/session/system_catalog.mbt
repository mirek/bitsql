// SQL Server's system objects (sys.system_objects: catalog views, DMVs,
// system procedures and functions) and their columns (sys.system_columns),
// seeded from the oracle (sysviews_system_data.mbt, generated). The compact
// text tables are parsed on first use and cached: the rows are the same in
// every database and never change.

///|
/// One system object.
priv struct SysObject {
  name : String
  id : Int
  schema_id : Int
  code : String
  desc : String
  created : @types.Value
  modified : @types.Value
}

///|
/// One system column.
priv struct SysColumn {
  object_id : Int
  name : String
  column_id : Int
  ty : Int
  flags : Int
}

///|
priv struct SystemCatalog {
  objects : Array[SysObject]
  columns : Array[SysColumn]
  by_id : Map[Int, Int]
  /// "<schema id>|<lower-case name>" → index into `objects`
  by_name : Map[String, Int]
  mut loaded : Bool
}

///|
let system_catalog : SystemCatalog = {
  objects: [],
  columns: [],
  by_id: Map([]),
  by_name: Map([]),
  loaded: false,
}

///|
fn int_of(s : StringView) -> Int {
  @string.parse_int(s) catch {
    _ => 0
  }
}

///|
fn sys_datetime(units : Int) -> @types.Value {
  let day = 25920000
  DateTime(system_objects_base_day + units / day, units % day)
}

///|
fn system_catalog_loaded() -> SystemCatalog {
  let c = system_catalog
  if c.loaded {
    return c
  }
  let descs : Map[String, String] = Map([])
  for p in system_object_descs {
    descs[p.0] = p.1
  }
  for line in system_objects_text.split("\n") {
    let f = line.split("|").collect()
    if f.length() < 6 {
      continue
    }
    let code = f[3].to_owned()
    c.by_id[int_of(f[1])] = c.objects.length()
    c.by_name["\{int_of(f[2])}|\{f[0].to_owned().to_lower()}"] = c.objects.length()
    c.objects.push({
      name: f[0].to_owned(),
      id: int_of(f[1]),
      schema_id: int_of(f[2]),
      code,
      desc: descs.get(code).unwrap_or(""),
      created: sys_datetime(int_of(f[4])),
      modified: sys_datetime(int_of(f[5])),
    })
  }
  let mut owner = 0
  let mut next = 1
  for line in system_columns_text.split("\n") {
    if line.has_prefix("@") {
      owner = int_of(line.view(start_offset=1))
      next = 1
      continue
    }
    let f = line.split("|").collect()
    if f.length() < 3 {
      continue
    }
    c.columns.push({
      object_id: owner,
      name: f[0].to_owned(),
      column_id: next,
      ty: int_of(f[1]),
      flags: int_of(f[2]),
    })
    next += 1
  }
  c.loaded = true
  c
}

///|
fn sys_object_row(o : SysObject) -> VRow {
  vrow([
    ("name", s(o.name)),
    ("object_id", i(o.id)),
    ("schema_id", i(o.schema_id)),
    ("parent_object_id", i(0)),
    ("type", s(pad2(o.code))),
    ("type_desc", s(o.desc)),
    ("create_date", o.created),
    ("modify_date", o.modified),
    ("is_ms_shipped", b(true)),
    ("is_published", b(false)),
    ("is_schema_published", b(false)),
  ])
}

///|
fn sys_column_row(c : SysColumn) -> VRow {
  let (st, ut, len, p, sc, coll) = system_column_types[c.ty]
  vrow([
    ("object_id", i(c.object_id)),
    ("name", s(c.name)),
    ("column_id", i(c.column_id)),
    ("system_type_id", TinyInt(st)),
    ("user_type_id", i(ut)),
    ("max_length", SmallInt(len)),
    ("precision", TinyInt(p)),
    ("scale", TinyInt(sc)),
    ("collation_name", if coll == "" { Null } else { s(coll) }),
    ("is_nullable", b(c.flags % 2 == 1)),
    ("is_ansi_padded", b(c.flags / 2 == 1)),
    ("generated_always_type", TinyInt(0)),
    ("generated_always_type_desc", s("NOT_APPLICABLE")),
  ])
}

///|
/// sys.system_objects rows.
fn system_objects_rows() -> Array[VRow] {
  system_catalog_loaded().objects.map(sys_object_row)
}

///|
/// sys.system_columns rows.
fn system_columns_rows() -> Array[VRow] {
  system_catalog_loaded().columns.map(sys_column_row)
}

///|
/// A system object (sys.system_objects or one of the seeded system tables
/// of sys.objects) by schema id and name, compared case-insensitively.
fn system_object_named(schema_id : Int, name : String) -> CatObj? {
  let lower = name.to_lower()
  // indexed: OBJECT_ID(N'sys.x') can run once per row of a large scan
  let c = system_catalog_loaded()
  match c.by_name.get("\{schema_id}|\{lower}") {
    Some(k) => return Some(sys_cat_obj(c.objects[k]))
    None => ()
  }
  for r in seed_system_objects {
    if r[3] is Int(sid) &&
      sid == schema_id &&
      r[0] is String(n) &&
      n.to_lower() == lower {
      return Some(seed_cat_obj(r))
    }
  }
  None
}

///|
/// A system object by id.
fn system_object_by_id(id : Int) -> CatObj? {
  let c = system_catalog_loaded()
  match c.by_id.get(id) {
    Some(k) => return Some(sys_cat_obj(c.objects[k]))
    None => ()
  }
  for r in seed_system_objects {
    if r[1] is Int(oid) && oid == id {
      return Some(seed_cat_obj(r))
    }
  }
  None
}

///|
fn sys_cat_obj(o : SysObject) -> CatObj {
  {
    id: o.id,
    name: o.name,
    schema_id: o.schema_id,
    parent: 0,
    code: o.code,
    desc: o.desc,
    created: 0L,
    modified: 0L,
  }
}

///|
fn seed_cat_obj(r : Array[@types.Value]) -> CatObj {
  let text = (k : Int) => {
    match r[k] {
      String(x) => x
      _ => ""
    }
  }
  {
    id: match r[1] {
      Int(x) => x
      _ => 0
    },
    name: text(0),
    schema_id: match r[3] {
      Int(x) => x
      _ => 4
    },
    parent: match r[4] {
      Int(x) => x
      _ => 0
    },
    code: text(5).trim().to_owned(),
    desc: text(6),
    created: 0L,
    modified: 0L,
  }
}

///|
/// sys.database_files of master or a user database. Sizes are those of a
/// fresh database (captured on the oracle: user databases 1024 pages, log
/// max 2 TB, growth 8192 pages; master 600/352 pages, 10% growth); SQL
/// Server's grow with the data, bitsql has no pages. A user database's
/// file_guid is random in SQL Server; bitsql derives one from the name.
fn database_file_rows(
  db : String,
  files : Array[(String, String)],
) -> Array[VRow] {
  let file = (
    id : Int,
    kind : Int,
    name : String,
    path : String,
    size : Int,
    max_size : Int,
    growth : Int,
    percent : Bool,
    guid : @types.Value,
  ) => {
    vrow([
      ("file_id", i(id)),
      ("file_guid", guid),
      ("type", TinyInt(kind)),
      ("type_desc", s(if kind == 0 { "ROWS" } else { "LOG" })),
      ("data_space_id", i(if kind == 0 { 1 } else { 0 })),
      ("name", s(name)),
      ("physical_name", s(path)),
      ("state", TinyInt(0)),
      ("state_desc", s("ONLINE")),
      ("size", i(size)),
      ("max_size", i(max_size)),
      ("growth", i(growth)),
      ("is_percent_growth", b(percent)),
    ])
  }
  if db.to_lower() == "master" {
    return [
      file(1, 0, files[0].0, files[0].1, 600, -1, 10, true, Null),
      file(2, 1, files[1].0, files[1].1, 352, -1, 10, true, Null),
    ]
  }
  [
    file(1, 0, files[0].0, files[0].1, 1024, -1, 8192, false, name_guid(db, 1)),
    file(
      2,
      1,
      files[1].0,
      files[1].1,
      1024,
      268435456,
      8192,
      false,
      name_guid(db, 2),
    ),
  ]
}

///|
/// A stable pseudo-random GUID for a name (FNV-1a over its code units).
fn name_guid(name : String, salt : Int) -> @types.Value {
  let buf = FixedArray::make(16, b'\x00')
  let mut h = 0xcbf29ce484222325UL ^ salt.to_uint64()
  for k in 0..<16 {
    for c in name {
      h = (h ^ c.to_int().to_uint64()) * 0x100000001b3UL
    }
    h = (h ^ k.to_uint64()) * 0x100000001b3UL
    buf[k] = (h >> 24).to_byte()
  }
  // version 4, RFC variant like NEWID()
  buf[7] = (buf[7] & b'\x0f') | b'\x40'
  buf[8] = (buf[8] & b'\x3f') | b'\x80'
  Guid(Bytes::from_array(buf))
}

///|
/// Is `name` one of the system types (sys.types seed rows, incl. sysname)?
fn is_system_type_name(name : String) -> Bool {
  let k = name.to_lower()
  let col = seed_type_columns.search("name").unwrap_or(0)
  seed_types.iter().any(r => r[col] is String(n) && n.to_lower() == k)
}

///|
/// sys.server_principals rows (the built-in logins and server roles).
fn server_principal_rows() -> Array[VRow] {
  seed_server_principals.map(r => {
    let m : Map[String, @types.Value] = Map([])
    for j, c in seed_server_principal_columns {
      m[c] = r[j]
    }
    m
  })
}
