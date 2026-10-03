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
  priv schemas : PMap[String, Int] // lowercased schema name → schema id
}

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
  let schemas = PMap::empty(str_cmp)
    .add("dbo", 1)
    .add("guest", 2)
    .add("information_schema", 3)
    .add("sys", 4)
  {
    names: PMap::empty(str_cmp),
    tables: PMap::empty(int_cmp),
    data: PMap::empty(int_cmp),
    modules: PMap::empty(int_cmp),
    schemas,
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
  self.schemas.get(name.to_lower())
}

///|
pub fn Db::schema_names(self : Db) -> Array[(String, Int)] {
  self.schemas.iter().collect()
}

///|
pub fn Db::add_schema(self : Db, name : String, id : Int) -> Db {
  { ..self, schemas: self.schemas.add(name.to_lower(), id), }
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
      d = { map: d.map.add(index_key(ix, kv.1, kv.0), kv.0), }
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
    indexes.push({
      map: d.indexes[i].map.add(index_key(ix, row, rowid), rowid),
    })
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
    indexes.push({ map: d.indexes[i].map.remove(index_key(ix, row, rowid)), })
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
