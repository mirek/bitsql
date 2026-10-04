///|
/// Keys whose value differs between two versions of a map: (key, old, new),
/// None meaning absent. Physically equal values are unchanged.
fn[K, V] PMap::changes(
  self : PMap[K, V],
  other : PMap[K, V],
) -> Array[(K, V?, V?)] {
  let out = []
  if physical_equal(self.root, other.root) {
    return out
  }
  let a = self.iter().collect()
  let b = other.iter().collect()
  let mut i = 0
  let mut j = 0
  while i < a.length() || j < b.length() {
    if j >= b.length() {
      out.push((a[i].0, Some(a[i].1), None))
      i += 1
    } else if i >= a.length() {
      out.push((b[j].0, None, Some(b[j].1)))
      j += 1
    } else {
      let c = (self.cmp)(a[i].0, b[j].0)
      if c < 0 {
        out.push((a[i].0, Some(a[i].1), None))
        i += 1
      } else if c > 0 {
        out.push((b[j].0, None, Some(b[j].1)))
        j += 1
      } else {
        if !physical_equal(a[i].1, b[j].1) {
          out.push((a[i].0, Some(a[i].1), Some(b[j].1)))
        }
        i += 1
        j += 1
      }
    }
  }
  out
}

///|
fn[V] same_opt(a : V?, b : V?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Applies base→mine changes onto `onto`. None when `onto` changed one of
/// the same keys since `base` (a write-write conflict).
fn[K, V] merge3(
  base : PMap[K, V],
  mine : PMap[K, V],
  onto : PMap[K, V],
  same? : (V?, V?) -> Bool = same_opt,
) -> PMap[K, V]? {
  let mut out = onto
  for ch in base.changes(mine) {
    let (k, old, new) = ch
    if !same(onto.get(k), old) {
      // both sides made the identical change: fine
      if same(onto.get(k), new) {
        continue
      }
      return None
    }
    out = match new {
      Some(v) => out.add(k, v)
      None => out.remove(k)
    }
  }
  Some(out)
}

///|
/// Re-applies the changes a transaction made (`base` → `self`) onto `onto`,
/// a newer committed state of the same database. Row changes merge per row
/// (key locks keep concurrent writers off the same rows); catalog changes
/// merge per object. Returns None on a conflicting change to the same row
/// or object. (design: storage-concurrency, request restart)
pub fn Db::rebase(self : Db, base : Db, onto : Db) -> Db? {
  if physical_equal(base, onto) {
    return Some(self)
  }
  if physical_equal(base, self) {
    return Some(onto)
  }
  let names = merge3(base.names, self.names, onto.names, same=(a, b) => a == b)
  let tables = merge3(base.tables, self.tables, onto.tables)
  let modules = merge3(base.modules, self.modules, onto.modules)
  let schemas = merge3(base.schemas, self.schemas, onto.schemas, same=(a, b) => {
    a == b
  })
  let types = merge3(base.types, self.types, onto.types)
  let type_names = merge3(base.type_names, self.type_names, onto.type_names, same=(
    a,
    b,
  ) => a == b)
  guard types is Some(types) && type_names is Some(type_names) else {
    return None
  }
  guard merge3(base.props, self.props, onto.props, same=(a, b) => a == b)
    is Some(props) else {
    return None
  }
  guard names is Some(names) &&
    tables is Some(tables) &&
    modules is Some(modules) &&
    schemas is Some(schemas) else {
    return None
  }
  let mut out : Db = {
    names,
    tables,
    data: onto.data,
    modules,
    schemas,
    types,
    type_names,
    props,
  }
  for ch in base.data.changes(self.data) {
    let (id, old, new) = ch
    let current = onto.data.get(id)
    if same_opt(current, old) {
      // only this transaction touched the table's data
      out = {
        ..out,
        data: match new {
          Some(d) => out.data.add(id, d)
          None => out.data.remove(id)
        },
      }
      continue
    }
    // both changed the table: merge rows; the table definition must be
    // unchanged on both sides
    guard old is Some(b) &&
      new is Some(m) &&
      current is Some(_) &&
      same_opt(base.tables.get(id), self.tables.get(id)) &&
      same_opt(base.tables.get(id), onto.tables.get(id)) else {
      return None
    }
    let onto_rows = current.unwrap().rows
    for rc in b.rows.changes(m.rows) {
      let (rowid, before, after) = rc
      if !same_opt(onto_rows.get(rowid), before) {
        return None
      }
      out = match after {
        Some(row) =>
          if before is Some(_) {
            out.update_row(id, rowid, row)
          } else {
            out.insert_row(id, rowid, row)
          }
        None => out.delete_row(id, rowid)
      }
    }
  }
  Some(out)
}
