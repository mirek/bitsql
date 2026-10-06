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
  priv props : PMap[String, ExtendedProperty] // xprops.mbt
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
    props: PMap::empty(str_cmp),
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
fn index_keys(
  ix : Index,
  row : Row,
  rowid : Int64,
) -> Array[Array[@types.Value]] {
  if ix.json is Some(options) {
    guard ix.columns is [(column, _)] && row[column] is NativeJson(data) else {
      return []
    }
    return data
      .index_paths()
      .filter(path => options.prefixes.any(prefix => path.has_prefix(prefix)))
      .map(path => [String(path), BigInt(rowid)])
  }
  let key = ix.columns.map(c => row[c.0])
  if !ix.unique {
    key.push(BigInt(rowid))
  }
  [key]
}

///|
/// Filtered indexes skip rows outside their filter.
fn in_index(ix : Index, row : Row) -> Bool {
  !ix.disabled && ix.covers(row)
}

///|
fn empty_index(t : Table, ix : Index) -> IndexData {
  if ix.json is Some(_) {
    return {
      map: PMap::empty(
        key_comparator([NVarChar(None, @types.json_collation), BigInt], [
          false, false,
        ]),
      ),
    }
  }
  let types = ix.columns.map(c => t.columns[c.0].ty)
  let desc = ix.columns.map(c => c.1)
  if !ix.unique {
    types.push(BigInt)
    desc.push(false)
  }
  { map: PMap::empty(key_comparator(types, desc)), }
}

///|
pub fn Db::create_table(self : Db, t0 : Table) -> Db {
  let t = self.lob_mark(t0)
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
  t0 : Table,
  convert? : (Row) -> Row = r => r,
) -> Db {
  let t = self.lob_mark(t0)
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
        for key in index_keys(ix, kv.1, kv.0) {
          d = { map: d.map.add(key, kv.0), }
        }
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
  t0 : Table,
  rows : Array[(Int64, Row)],
) -> Db {
  let t = self.lob_mark(t0)
  let mut m : PMap[Int64, Row] = PMap::empty(i64_cmp)
  for kv in rows {
    m = m.add(kv.0, kv.1)
  }
  let indexes = t.indexes.map(ix => {
    let mut d = empty_index(t, ix)
    for kv in rows {
      if in_index(ix, kv.1) {
        for key in index_keys(ix, kv.1, kv.0) {
          d = { map: d.map.add(key, kv.0), }
        }
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
        let mut map = d.indexes[i].map
        for key in index_keys(ix, row, rowid) {
          map = map.add(key, rowid)
        }
        { map, }
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
        let mut map = d.indexes[i].map
        for key in index_keys(ix, row, rowid) {
          map = map.remove(key)
        }
        { map, }
      } else {
        d.indexes[i]
      },
    )
  }
  { ..self, data: self.data.add(id, { rows: d.rows.remove(rowid), indexes, }), }
}

///|
/// Inserts several rows: the same result as `insert_row` for each in
/// order, with the row and index maps merged in bulk (`PMap::add_all`).
pub fn Db::insert_rows(self : Db, id : Int, rows : Array[(Int64, Row)]) -> Db {
  guard self.data.get(id) is Some(d) && self.tables.get(id) is Some(t) else {
    return self
  }
  if rows.is_empty() {
    return self
  }
  let indexes = t.indexes.mapi((i, ix) => {
    let entries = []
    for r in rows {
      if in_index(ix, r.1) {
        for key in index_keys(ix, r.1, r.0) {
          entries.push((key, r.0))
        }
      }
    }
    if entries.is_empty() {
      d.indexes[i]
    } else {
      { map: d.indexes[i].map.add_all(entries), }
    }
  })
  { ..self, data: self.data.add(id, { rows: d.rows.add_all(rows), indexes, }), }
}

///|
/// Deletes several rows: the same result as `delete_row` for each, but a
/// large share of the table is removed by rebuilding the row and index
/// maps once (O(n)) instead of n path copies.
pub fn Db::delete_rows(self : Db, id : Int, rowids : Array[Int64]) -> Db {
  guard self.data.get(id) is Some(d) && self.tables.get(id) is Some(t) else {
    return self
  }
  if rowids.length() < 64 || rowids.length() * 8 < d.rows.size() {
    let mut db = self
    for r in rowids {
      db = db.delete_row(id, r)
    }
    return db
  }
  let removed : Set[Int64] = Set::from_array(rowids)
  // index entries map to their row id; disabled indexes are not
  // maintained (as in `delete_row`)
  let data : TableData = {
    rows: d.rows.retain((k, _) => !removed.contains(k)),
    indexes: d.indexes.mapi((i, ix) => {
      if t.indexes[i].disabled {
        ix
      } else {
        { map: ix.map.retain((_, r) => !removed.contains(r)), }
      }
    }),
  }
  { ..self, data: self.data.add(id, data), }
}

///|
pub fn Db::update_row(self : Db, id : Int, rowid : Int64, row : Row) -> Db {
  self.delete_row(id, rowid).insert_row(id, rowid, row)
}

///|
/// Whether replacing `old` by `new` leaves every index of `t` as it is:
/// same membership (filters) and identical key values. Disabled indexes
/// are not maintained, so a table with one never qualifies.
pub fn same_index_entries(t : Table, old : Row, new : Row) -> Bool {
  for ix in t.indexes {
    if ix.disabled {
      return false
    }
    let covered = ix.covers(old)
    if covered != ix.covers(new) {
      return false
    }
    if covered &&
      !ix.columns
      .iter()
      .all(c => physical_equal(old[c.0], new[c.0]) || old[c.0] == new[c.0]) {
      return false
    }
  }
  true
}

///|
/// Replaces the row stored under `rowid` without touching the indexes:
/// only valid when `same_index_entries` holds for the old and new row.
pub fn Db::replace_row(self : Db, id : Int, rowid : Int64, row : Row) -> Db {
  guard self.data.get(id) is Some(d) && d.rows.contains(rowid) else {
    return self
  }
  { ..self, data: self.data.add(id, { ..d, rows: d.rows.add(rowid, row), }), }
}

///|
/// `replace_row` of every (rowid, row) in order, in one bulk rebuild of the
/// table's rows when there are many (`PMap::add_all`).
pub fn Db::replace_rows(self : Db, id : Int, rows : Array[(Int64, Row)]) -> Db {
  guard self.data.get(id) is Some(d) else { return self }
  let present = rows.filter(r => d.rows.contains(r.0))
  if present.is_empty() {
    return self
  }
  { ..self, data: self.data.add(id, { ..d, rows: d.rows.add_all(present), }), }
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
/// The physical rows and indexes of table `id`: a new value after every
/// write, so `physical_equal` on two results tells whether a write
/// happened in between (statement caches, `Session::data_stamp`).
pub fn Db::table_data(self : Db, id : Int) -> TableData? {
  self.data.get(id)
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

///|
/// Keeps `Table::lob_used` sticky across rewrites of a table.
fn Db::lob_mark(self : Db, t : Table) -> Table {
  let before = match self.tables.get(t.id) {
    Some(o) => o.lob_used
    None => false
  }
  let used = t.lob_used || before || t.has_lob()
  if used == t.lob_used {
    t
  } else {
    { ..t, lob_used: used, }
  }
}

///|
/// Candidate row ids for a concrete JSON path prefix. Residual predicates
/// decide scalar comparisons and advanced accessor semantics.
pub fn Db::seek_json_path(
  self : Db,
  id : Int,
  index : Int,
  prefix : String,
) -> Array[Int64] {
  guard self.data.get(id) is Some(d) else { return [] }
  let rows : Set[Int64] = Set([])
  for (key, rowid) in d.indexes[index].map.range(lo=[String(prefix)]) {
    guard key[0] is String(path) && path.has_prefix(prefix) else { break }
    rows.add(rowid)
  }
  let out = rows.to_array()
  out.sort()
  out
}
