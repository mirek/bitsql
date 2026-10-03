///|
pub type Row = Array[@types.Value]

///|
/// Index entries: key values (+ rowid for non-unique indexes) → rowid.
pub struct IndexData {
  priv map : PMap[Array[@types.Value], Int64]
}

///|
/// Rows of one table keyed by an internal row id, plus index maps aligned
/// with `Table::indexes`.
pub struct TableData {
  rows : PMap[Int64, Row]
  indexes : Array[IndexData]
}

///|
/// An immutable database value: catalog plus data. Every write returns a new
/// `Db`; snapshots and rollback keep old values (design: storage-concurrency).
pub struct Db {
  priv names : PMap[String, Int] // "schema.name" lowercased → object id
  priv tables : PMap[Int, Table]
  priv data : PMap[Int, TableData]
  priv modules : PMap[Int, Module]
  priv schemas : PMap[String, (String, Int)] // lowercased name → (name, id)
  priv types : PMap[Int, UserType] // user_type_id → type
  priv type_names : PMap[String, Int] // "schema.name" lowercased → id
}

///|
/// Schemas present in every new database (captured: sys.schemas of a fresh
/// SQL Server 2025 database; principal_id equals schema_id).
let builtin_schemas : Array[(String, Int)] = [
  ("dbo", 1),
  ("guest", 2),
  ("INFORMATION_SCHEMA", 3),
  ("sys", 4),
  ("db_owner", 16384),
  ("db_accessadmin", 16385),
  ("db_securityadmin", 16386),
  ("db_ddladmin", 16387),
  ("db_backupoperator", 16389),
  ("db_datareader", 16390),
  ("db_datawriter", 16391),
  ("db_denydatareader", 16392),
  ("db_denydatawriter", 16393),
]

///|
fn str_cmp(a : String, b : String) -> Int {
  a.compare(b)
}

///|
fn int_cmp(a : Int, b : Int) -> Int {
  a.compare(b)
}

///|
fn i64_cmp(a : Int64, b : Int64) -> Int {
  a.compare(b)
}

///|
pub fn Db::empty() -> Db {
  let mut schemas = PMap::empty(str_cmp)
  for s in builtin_schemas {
    schemas = schemas.add(s.0.to_lower(), s)
  }
  {
    names: PMap::empty(str_cmp),
    tables: PMap::empty(int_cmp),
    data: PMap::empty(int_cmp),
    modules: PMap::empty(int_cmp),
    schemas,
    types: PMap::empty(int_cmp),
    type_names: PMap::empty(str_cmp),
  }
}

///|
/// A user-defined type by schema and name.
pub fn Db::lookup_type(self : Db, schema : String, name : String) -> UserType? {
  match self.type_names.get(qualified_key(schema, name)) {
    Some(id) => self.types.get(id)
    None => None
  }
}

///|
pub fn Db::get_type(self : Db, id : Int) -> UserType? {
  self.types.get(id)
}

///|
/// User-defined types ordered by user_type_id.
pub fn Db::user_types(self : Db) -> Array[UserType] {
  self.types.iter().map(kv => kv.1).collect()
}

///|
/// Next user_type_id (SQL Server starts at 257, after sysname's 256).
pub fn Db::next_type_id(self : Db) -> Int {
  let mut m = 256
  for kv in self.types.iter() {
    if kv.0 > m {
      m = kv.0
    }
  }
  m + 1
}

///|
pub fn Db::add_type(self : Db, t : UserType) -> Db {
  {
    ..self,
    types: self.types.add(t.id, t),
    type_names: self.type_names.add(qualified_key(t.schema, t.name), t.id),
  }
}

///|
pub fn Db::drop_type(self : Db, id : Int) -> Db {
  match self.types.get(id) {
    Some(t) =>
      {
        ..self,
        types: self.types.remove(id),
        type_names: self.type_names.remove(qualified_key(t.schema, t.name)),
      }
    None => self
  }
}

///|
pub fn qualified_key(schema : String, name : String) -> String {
  schema.to_lower() + "." + name.to_lower()
}

///|
pub fn Db::lookup(self : Db, schema : String, name : String) -> Int? {
  self.names.get(qualified_key(schema, name))
}

///|
pub fn Db::table(self : Db, id : Int) -> Table? {
  self.tables.get(id)
}

///|
pub fn Db::get_module(self : Db, id : Int) -> Module? {
  self.modules.get(id)
}

///|
pub fn Db::tables(self : Db) -> Array[Table] {
  self.tables.iter().map(kv => kv.1).collect()
}

///|
pub fn Db::modules(self : Db) -> Array[Module] {
  self.modules.iter().map(kv => kv.1).collect()
}

///|
pub fn Db::schema_id(self : Db, name : String) -> Int? {
  self.schemas.get(name.to_lower()).map(s => s.1)
}

///|
/// Schema name by id (as created).
pub fn Db::schema_name(self : Db, id : Int) -> String? {
  for kv in self.schemas.iter() {
    if kv.1.1 == id {
      return Some(kv.1.0)
    }
  }
  None
}

///|
/// All schemas as (name, schema_id), ordered by id.
pub fn Db::schema_names(self : Db) -> Array[(String, Int)] {
  let out = self.schemas.iter().map(kv => kv.1).collect()
  out.sort_by((a, b) => a.1.compare(b.1))
  out
}

///|
/// Next free user schema id (SQL Server allocates 5, 6, ...).
pub fn Db::next_schema_id(self : Db) -> Int {
  let mut m = 4
  for kv in self.schemas.iter() {
    if kv.1.1 < 16384 && kv.1.1 > m {
      m = kv.1.1
    }
  }
  m + 1
}

///|
pub fn Db::add_schema(self : Db, name : String, id : Int) -> Db {
  { ..self, schemas: self.schemas.add(name.to_lower(), (name, id)), }
}

///|
pub fn Db::drop_schema(self : Db, name : String) -> Db {
  { ..self, schemas: self.schemas.remove(name.to_lower()), }
}

///|
/// Comparator for index keys under the column types' collations.
pub fn key_comparator(
  types : Array[@types.SqlType],
  desc : Array[Bool],
) -> (Array[@types.Value], Array[@types.Value]) -> Int {
  fn(a, b) {
    let n = @cmp.minimum(a.length(), b.length())
    for i in 0..<n {
      let c = match (a[i], b[i]) {
        (Null, Null) => 0
        (Null, _) => -1
        (_, Null) => 1
        (x, y) => {
          let coll = if i < types.length() {
            types[i].collation()
          } else {
            None
          }
          (@types.compare(x, y, collation?=coll) catch { _ => None }).unwrap_or(
            0,
          )
        }
      }
      if c != 0 {
        return if i < desc.length() && desc[i] { -c } else { c }
      }
    }
    a.length().compare(b.length())
  }
}

///|
fn index_key(ix : Index, row : Row, rowid : Int64) -> Array[@types.Value] {
  let key = ix.columns.map(c => row[c.0])
  if !ix.unique {
    key.push(BigInt(rowid))
  }
  key
}

///|
/// Filtered indexes skip rows outside their filter.
fn in_index(ix : Index, row : Row) -> Bool {
  for c in ix.not_null_filter {
    if c < row.length() && row[c] is Null {
      return false
    }
  }
  true
}

///|
fn empty_index(t : Table, ix : Index) -> IndexData {
  let types = ix.columns.map(c => t.columns[c.0].ty)
  let desc = ix.columns.map(c => c.1)
  if !ix.unique {
    types.push(BigInt)
    desc.push(false)
  }
  { map: PMap::empty(key_comparator(types, desc)), }
}

///|
pub fn Db::create_table(self : Db, t : Table) -> Db {
  let data : TableData = {
    rows: PMap::empty(i64_cmp),
    indexes: t.indexes.map(ix => empty_index(t, ix)),
  }
  {
    ..self,
    names: self.names.add(qualified_key(t.schema, t.name), t.id),
    tables: self.tables.add(t.id, t),
    data: self.data.add(t.id, data),
  }
}

///|
/// Replaces a table definition, rebuilding its indexes from the rows
/// (ALTER TABLE, CREATE INDEX). `rows` maps old rows to the new shape.
pub fn Db::alter_table(
  self : Db,
  t : Table,
  convert? : (Row) -> Row = r => r,
) -> Db {
  let old = self.data.get(t.id)
  let mut rows : PMap[Int64, Row] = PMap::empty(i64_cmp)
  match old {
    Some(d) =>
      for kv in d.rows.iter() {
        rows = rows.add(kv.0, convert(kv.1))
      }
    None => ()
  }
  let indexes = t.indexes.map(ix => {
    let mut d = empty_index(t, ix)
    for kv in rows.iter() {
      if in_index(ix, kv.1) {
        d = { map: d.map.add(index_key(ix, kv.1, kv.0), kv.0), }
      }
    }
    d
  })
  let old_key = match self.tables.get(t.id) {
    Some(o) => Some(qualified_key(o.schema, o.name))
    None => None
  }
  let names = match old_key {
    Some(k) => self.names.remove(k)
    None => self.names
  }
  {
    ..self,
    names: names.add(qualified_key(t.schema, t.name), t.id),
    tables: self.tables.add(t.id, t),
    data: self.data.add(t.id, { rows, indexes, }),
  }
}

///|
/// Replaces a table definition and all of its rows (ALTER TABLE that adds
/// or drops columns), rebuilding the indexes.
pub fn Db::replace_table(
  self : Db,
  t : Table,
  rows : Array[(Int64, Row)],
) -> Db {
  let mut m : PMap[Int64, Row] = PMap::empty(i64_cmp)
  for kv in rows {
    m = m.add(kv.0, kv.1)
  }
  let indexes = t.indexes.map(ix => {
    let mut d = empty_index(t, ix)
    for kv in rows {
      if in_index(ix, kv.1) {
        d = { map: d.map.add(index_key(ix, kv.1, kv.0), kv.0), }
      }
    }
    d
  })
  let names = match self.tables.get(t.id) {
    Some(o) => self.names.remove(qualified_key(o.schema, o.name))
    None => self.names
  }
  {
    ..self,
    names: names.add(qualified_key(t.schema, t.name), t.id),
    tables: self.tables.add(t.id, t),
    data: self.data.add(t.id, { rows: m, indexes, }),
  }
}

///|
/// Renames a table or module (sp_rename).
pub fn Db::rename_module(self : Db, m : Module) -> Db {
  match self.modules.get(m.id) {
    Some(old) =>
      {
        ..self,
        names: self.names
        .remove(qualified_key(old.schema, old.name))
        .add(qualified_key(m.schema, m.name), m.id),
        modules: self.modules.add(m.id, m),
      }
    None => self
  }
}

///|
pub fn Db::drop_object(self : Db, id : Int) -> Db {
  let key = match self.tables.get(id) {
    Some(t) => Some(qualified_key(t.schema, t.name))
    None =>
      match self.modules.get(id) {
        Some(m) => Some(qualified_key(m.schema, m.name))
        None => None
      }
  }
  {
    ..self,
    names: match key {
      Some(k) => self.names.remove(k)
      None => self.names
    },
    tables: self.tables.remove(id),
    data: self.data.remove(id),
    modules: self.modules.remove(id),
  }
}

///|
pub fn Db::add_module(self : Db, m : Module) -> Db {
  {
    ..self,
    names: self.names.add(qualified_key(m.schema, m.name), m.id),
    modules: self.modules.add(m.id, m),
  }
}

///|
pub fn Db::rows(self : Db, id : Int) -> Array[(Int64, Row)] {
  match self.data.get(id) {
    Some(d) => d.rows.iter().collect()
    None => []
  }
}

///|
pub fn Db::row(self : Db, id : Int, rowid : Int64) -> Row? {
  match self.data.get(id) {
    Some(d) => d.rows.get(rowid)
    None => None
  }
}

///|
pub fn Db::row_count(self : Db, id : Int) -> Int {
  match self.data.get(id) {
    Some(d) => d.rows.size()
    None => 0
  }
}

///|
/// Rowid of an existing row with the same unique key, if any.
pub fn Db::find_key(
  self : Db,
  id : Int,
  index : Int,
  key : Array[@types.Value],
) -> Int64? {
  match self.data.get(id) {
    Some(d) => d.indexes[index].map.get(key)
    None => None
  }
}

///|
/// Index range scan (seek): rowids with keys in [lo, hi] (inclusive bounds
/// optional). Keys are prefixes of the index columns.
pub fn Db::seek(
  self : Db,
  id : Int,
  index : Int,
  lo? : Array[@types.Value],
  hi? : Array[@types.Value],
) -> Array[Int64] {
  match self.data.get(id) {
    Some(d) => d.indexes[index].map.range(lo?, hi?).map(kv => kv.1).collect()
    None => []
  }
}

///|
pub fn Db::insert_row(self : Db, id : Int, rowid : Int64, row : Row) -> Db {
  guard self.data.get(id) is Some(d) && self.tables.get(id) is Some(t) else {
    return self
  }
  let indexes = []
  for i, ix in t.indexes {
    indexes.push(
      if in_index(ix, row) {
        { map: d.indexes[i].map.add(index_key(ix, row, rowid), rowid), }
      } else {
        d.indexes[i]
      },
    )
  }
  {
    ..self,
    data: self.data.add(id, { rows: d.rows.add(rowid, row), indexes, }),
  }
}

///|
pub fn Db::delete_row(self : Db, id : Int, rowid : Int64) -> Db {
  guard self.data.get(id) is Some(d) && self.tables.get(id) is Some(t) else {
    return self
  }
  guard d.rows.get(rowid) is Some(row) else { return self }
  let indexes = []
  for i, ix in t.indexes {
    indexes.push(
      if in_index(ix, row) {
        { map: d.indexes[i].map.remove(index_key(ix, row, rowid)), }
      } else {
        d.indexes[i]
      },
    )
  }
  { ..self, data: self.data.add(id, { rows: d.rows.remove(rowid), indexes, }), }
}

///|
pub fn Db::update_row(self : Db, id : Int, rowid : Int64, row : Row) -> Db {
  self.delete_row(id, rowid).insert_row(id, rowid, row)
}

///|
pub fn Db::truncate(self : Db, id : Int) -> Db {
  guard self.tables.get(id) is Some(t) else { return self }
  {
    ..self,
    data: self.data.add(id, {
      rows: PMap::empty(i64_cmp),
      indexes: t.indexes.map(ix => empty_index(t, ix)),
    }),
  }
}

///|
/// True when `id`'s rows are physically the same in both databases (no
/// write happened in between). Used to detect modifications under open
/// cursors.
pub fn Db::same_table_data(self : Db, other : Db, id : Int) -> Bool {
  match (self.data.get(id), other.data.get(id)) {
    (Some(a), Some(b)) => physical_equal(a, b)
    (None, None) => true
    _ => false
  }
}
