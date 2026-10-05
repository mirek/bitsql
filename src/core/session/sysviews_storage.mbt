// sys.partitions and sys.allocation_units. Row counts are exact; page counts
// come from a model of the on-disk row format (decisions.md 2026-10-05:
// storage catalogs): exact for small tables (one data page: total 9, used 2,
// data 1; empty: 0), estimates beyond that.

///|
/// Base of partition, hobt and allocation unit ids (SQL Server's are
/// 72057594...-style too).
let storage_id_base : Int64 = 72057594037927936L

///|
/// hobt_id (= partition_id) of a heap or index: stable per (object, index).
fn hobt_id(object_id : Int, index_id : Int) -> Int64 {
  storage_id_base + (object_id.to_int64() << 16) + index_id.to_int64()
}

///|
/// Bytes of a data page available to rows and their slots.
let page_bytes : Int = 8096

///|
/// Largest in-row record.
let max_row_bytes : Int = 8060

///|
priv enum StorageKind {
  Fixed
  Variable
  /// varchar(max) and friends: in row up to 8000 bytes, else off-row
  LargeValue
  /// text, ntext, image: always off-row behind a 16-byte pointer
  TextPointer
}

///|
fn storage_kind(t : @types.SqlType) -> StorageKind {
  match t {
    VarChar(None, _) | NVarChar(None, _) | VarBinary(None) | Xml | Json =>
      LargeValue
    Text(_) | NText(_) | Image => TextPointer
    VarChar(_, _) | NVarChar(_, _) | VarBinary(_) | Variant => Variable
    _ => Fixed
  }
}

///|
/// Stored bytes of a non-NULL value of a variable-length column.
fn value_bytes(v : @types.Value, t : @types.SqlType) -> Int {
  match v {
    Null => 0
    String(x) => if t.is_unicode() { x.length() * 2 } else { x.length() }
    Binary(x) => x.length()
    Variant(inner, base) => @types.variant_data_length(inner, base) + 2
    _ => type_ids(t).2.max(0)
  }
}

///|
/// One stored record layout: the columns (ordinals into the table) plus
/// a fixed extra (row locator) of `extra` bytes.
priv struct RecordShape {
  cols : Array[Int]
  extra : Int
  /// leaf header: 4 for heap/clustered records, 1 for index records
  header : Int
}

///|
/// Page estimate of one heap or index: (rows, in-row data pages, upper
/// index levels, row-overflow pages, LOB pages).
priv struct Footprint {
  rows : Int
  data : Int
  upper : Int
  overflow : Int
  lob : Int
}

///|
fn ceil_div(a : Int, b : Int) -> Int {
  (a + b - 1) / b
}

///|
fn record_footprint(
  t : @store.Table,
  shape : RecordShape,
  keep : (Array[@types.Value]) -> Bool,
  data : Array[(Int64, @store.Row)],
  keyed : Bool,
) -> Footprint {
  let fixed = shape.cols.fold(init=shape.extra, (acc, c) => {
    let ty = t.columns[c].ty
    if storage_kind(ty) is Fixed {
      acc + type_ids(ty).2.max(0)
    } else {
      acc
    }
  })
  let nvar = shape.cols
    .iter()
    .filter(c => !(storage_kind(t.columns[c].ty) is Fixed))
    .count()
  let bitmap = 2 + ceil_div(shape.cols.length(), 8)
  let mut n = 0
  let mut in_row = 0
  let mut overflow = 0
  let mut lob = 0
  let mut key_bytes = 0
  for entry in data {
    let row = entry.1
    guard keep(row) else { continue }
    n += 1
    let vars : Array[Int] = []
    let mut size = shape.header + fixed + bitmap
    for c in shape.cols {
      let ty = t.columns[c].ty
      let v = if c < row.length() { row[c] } else { Null }
      match storage_kind(ty) {
        Fixed => ()
        Variable => vars.push(value_bytes(v, ty))
        LargeValue => {
          let len = value_bytes(v, ty)
          if len > 8000 {
            lob += len
            vars.push(16)
          } else {
            vars.push(len)
          }
        }
        TextPointer =>
          if !(v is Null) {
            lob += value_bytes(v, ty)
            vars.push(16)
          } else {
            vars.push(0)
          }
      }
    }
    if nvar > 0 {
      size += 2 + 2 * nvar
    }
    // the largest variable values move to row-overflow pages until the
    // record fits
    vars.sort()
    let mut k = vars.length() - 1
    let mut total = size + vars.fold(init=0, (a, x) => a + x)
    while total > max_row_bytes && k >= 0 {
      if vars[k] > 24 {
        overflow += vars[k]
        total = total - vars[k] + 24
      }
      k -= 1
    }
    in_row += total + 2
    key_bytes += total
  }
  let data_pages = if n == 0 { 0 } else { ceil_div(in_row, page_bytes) }
  // non-leaf levels of a B-tree: one row (key + child pointer) per page
  // below
  let mut upper = 0
  if keyed && data_pages > 1 {
    let fanout = (page_bytes / (key_bytes / n + 9)).max(2)
    let mut level = data_pages
    while level > 1 {
      level = ceil_div(level, fanout)
      upper += level
    }
  }
  {
    rows: n,
    data: data_pages,
    upper,
    overflow: ceil_div(overflow, max_row_bytes),
    lob: ceil_div(lob, 8040),
  }
}

///|
/// Largest possible in-row record: decides whether a ROW_OVERFLOW_DATA
/// allocation unit exists (captured: two varchar(8000) columns).
fn max_record_bytes(t : @store.Table, shape : RecordShape) -> Int {
  let mut size = shape.header +
    shape.extra +
    2 +
    ceil_div(shape.cols.length(), 8)
  let mut nvar = 0
  for c in shape.cols {
    let ty = t.columns[c].ty
    match storage_kind(ty) {
      Fixed => size += type_ids(ty).2.max(0)
      Variable => {
        nvar += 1
        size += type_ids(ty).2.max(0)
      }
      _ => nvar += 1
    }
  }
  if nvar > 0 {
    size + 2 + 2 * nvar
  } else {
    size
  }
}

///|
/// Stored columns of a table: non-persisted computed columns take no space.
fn stored_columns(t : @store.Table) -> Array[Int] {
  let out = []
  for k, c in t.columns {
    if c.computed is None || c.persisted {
      out.push(k)
    }
  }
  out
}

///|
/// One heap or index of a table: (index_id, footprint, has LOB unit,
/// has row-overflow unit).
fn table_storage(
  db : @store.Db,
  t : @store.Table,
) -> Array[(Int, Footprint, Bool, Bool)] {
  let data = db.rows(t.id)
  let out = []
  let stored = stored_columns(t)
  let lob_table = t.lob_used || t.has_lob()
  let clustered = t.indexes.iter().find_first(ix => ix.clustered)
  // the row locator of nonclustered records: the clustering key, or an
  // 8-byte RID of a heap
  let (locator_cols, locator_extra) = match clustered {
    Some(cx) => (cx.columns.map(c => c.0), if cx.unique { 0 } else { 4 })
    None => ([], 8)
  }
  let base_shape = { cols: stored, extra: 0, header: 4, }
  match clustered {
    None => {
      let fp = record_footprint(t, base_shape, _ => true, data, false)
      let ov = max_record_bytes(t, base_shape) > max_row_bytes
      out.push((0, fp, lob_table, ov))
    }
    Some(_) => ()
  }
  for ix in t.indexes {
    // a disabled nonclustered index has no partition (captured)
    if ix.disabled && !ix.clustered {
      continue
    }
    let shape = if ix.clustered {
      { ..base_shape, extra: if ix.unique { 0 } else { 4 }, }
    } else {
      let cols = ix.columns.map(c => c.0)
      for c in ix.included {
        if !cols.contains(c) {
          cols.push(c)
        }
      }
      for c in locator_cols {
        if !cols.contains(c) {
          cols.push(c)
        }
      }
      { cols, extra: locator_extra, header: 1, }
    }
    let fp = record_footprint(t, shape, row => ix.covers(row), data, true)
    let lob = if ix.clustered {
      lob_table
    } else {
      shape.cols
      .iter()
      .any(c => storage_kind(t.columns[c].ty) is (LargeValue | TextPointer))
    }
    let ov = max_record_bytes(t, shape) > max_row_bytes
    out.push((ix.index_id, fp, lob, ov))
  }
  out
}

///|
/// total_pages / used_pages / data_pages of one allocation unit holding
/// `pages` pages (plus its IAM page), allocated in whole extents.
fn unit_pages(pages : Int, data : Int) -> VRow {
  let used = if pages == 0 { 0 } else { pages + 1 }
  let total = if pages == 0 { 0 } else { ceil_div(pages, 8) * 8 + 1 }
  vrow([
    ("total_pages", BigInt(total.to_int64())),
    ("used_pages", BigInt(used.to_int64())),
    ("data_pages", BigInt(data.to_int64())),
    ("data_space_id", i(1)),
  ])
}

///|
fn partition_rows(db : @store.Db, out : Array[VRow]) -> Unit {
  for t in db.tables() {
    for e in table_storage(db, t) {
      let (index_id, fp, _, _) = e
      let id : @types.Value = BigInt(hobt_id(t.id, index_id))
      out.push(
        vrow([
          ("partition_id", id),
          ("object_id", i(t.id)),
          ("index_id", i(index_id)),
          ("partition_number", i(1)),
          ("hobt_id", id),
          ("rows", BigInt(fp.rows.to_int64())),
          ("filestream_filegroup_id", SmallInt(0)),
          ("data_compression", TinyInt(0)),
          ("data_compression_desc", s("NONE")),
          ("xml_compression", b(false)),
          ("xml_compression_desc", s("OFF")),
        ]),
      )
    }
  }
}

///|
fn allocation_unit_rows(db : @store.Db, out : Array[VRow]) -> Unit {
  for t in db.tables() {
    for e in table_storage(db, t) {
      let (index_id, fp, lob, ov) = e
      let hobt = hobt_id(t.id, index_id)
      let unit = (ty : Int, desc : String, pages : Int, data : Int) => {
        let r = unit_pages(pages, data)
        r["allocation_unit_id"] = BigInt(hobt + (ty.to_int64() << 52))
        r["type"] = TinyInt(ty)
        r["type_desc"] = s(desc)
        // IN_ROW and ROW_OVERFLOW units belong to the hobt, LOB units to
        // the partition (equal ids here, as in SQL Server)
        r["container_id"] = BigInt(hobt)
        out.push(r)
      }
      unit(1, "IN_ROW_DATA", fp.data + fp.upper, fp.data)
      if lob {
        unit(2, "LOB_DATA", fp.lob, 0)
      }
      if ov {
        unit(3, "ROW_OVERFLOW_DATA", fp.overflow, 0)
      }
    }
  }
}
