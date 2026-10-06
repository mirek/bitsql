///|
fn json_internal_object(
  t : @store.Table,
  ix : @store.Index,
  j : @store.JsonIndex,
) -> CatObj {
  {
    id: j.internal_id,
    name: "json_index_\{t.id}_\{ix.index_id}",
    schema_id: 4,
    parent: t.id,
    code: "IT",
    desc: "INTERNAL_TABLE",
    created: j.created,
    modified: j.modified,
  }
}

///|
fn json_internal_row_count(
  db : @store.Db,
  t : @store.Table,
  ix : @store.Index,
  j : @store.JsonIndex,
) -> Int64 {
  if ix.disabled && j.disabled_rows is Some(n) {
    return n
  }
  guard ix.columns is [(column, _)] else { return 0L }
  let mut count = 0L
  for (_, row) in db.rows(t.id) {
    if row[column] is NativeJson(data) {
      for path in data.index_scalar_paths() {
        if j.prefixes.any(prefix => path.has_prefix(prefix)) {
          count += 1L
        }
      }
    }
  }
  count
}

///|
fn json_internal_column(
  name : String,
  ty : @types.SqlType,
  nullable : Bool,
  ordinal : Int,
) -> @store.Column {
  {
    column_id: ordinal,
    name,
    ty,
    nullable,
    identity: None,
    default_: None,
    default_name: None,
    default_id: 0,
    default_auto: false,
    computed: None,
    result_nullable: nullable,
    persisted: false,
    rowguidcol: false,
    user_type: None,
  }
}

///|
fn json_internal_columns(
  t : @store.Table,
  coll : @types.Collation,
) -> Array[@store.Column] {
  let cols = [
    json_internal_column(
      "json_path",
      VarChar(Some(630), @types.json_collation),
      false,
      1,
    ),
    json_internal_column("json_array_index", VarBinary(Some(512)), true, 2),
    json_internal_column("sql_value", Variant, true, 3),
    json_internal_column("status", SmallInt, true, 4),
    json_internal_column(
      "full_json_path",
      VarChar(Some(8000), @types.json_collation),
      true,
      5,
    ),
    json_internal_column("full_json_value", NVarChar(None, coll), true, 6),
  ]
  for ix in t.indexes {
    if ix.primary && ix.clustered {
      for k, (c, _) in ix.columns {
        cols.push(
          json_internal_column(
            "posting_\{k + 1}",
            t.columns[c].ty,
            false,
            k + 7,
          ),
        )
      }
      break
    }
  }
  cols
}

///|
/// Catalog projections of the maintained JSON index. Its internal clustered
/// partition survives DISABLE; nonclustered partitions disappear until REBUILD.
fn Session::json_internal_view_rows(
  self : Session,
  key : String,
  db : @store.Db,
  out : Array[VRow],
) -> Unit {
  if !(key
    is ("sys.internal_tables"
    | "sys.columns"
    | "sys.indexes"
    | "sys.index_columns"
    | "sys.partitions"
    | "sys.stats")) {
    return
  }
  for t in db.tables() {
    for ix in t.indexes {
      guard ix.json is Some(j) else { continue }
      if key == "sys.internal_tables" {
        let row = object_row(json_internal_object(t, ix, j))
        row["internal_type"] = TinyInt(235)
        row["internal_type_desc"] = s("JSON_INDEX_TABLE")
        row["parent_id"] = i(t.id)
        row["parent_minor_id"] = i(ix.index_id)
        row["lob_data_space_id"] = i(1)
        out.push(row)
        continue
      }
      let cols = json_internal_columns(t, self.db_collation())
      if key == "sys.columns" {
        for c in cols {
          out.push(column_row(j.internal_id, c))
        }
        continue
      }
      let names = [ix.name, "json_index_posting_col_nci"]
      if j.array_search {
        names.push("json_index_search_optimization_nci")
      }
      for k, name in names {
        let id = k + 1
        match key {
          "sys.indexes" =>
            out.push(
              vrow([
                ("object_id", i(j.internal_id)),
                ("name", s(name)),
                ("index_id", i(id)),
                ("type", TinyInt(if id == 1 { 1 } else { 2 })),
                (
                  "type_desc",
                  s(if id == 1 { "CLUSTERED" } else { "NONCLUSTERED" }),
                ),
                ("data_space_id", i(1)),
                ("is_disabled", b(ix.disabled)),
                ("allow_row_locks", b(j.row_locks)),
                ("allow_page_locks", b(j.page_locks)),
                ("fill_factor", TinyInt(ix.fill_factor)),
                ("is_padded", b(j.padded)),
              ]),
            )
          "sys.stats" =>
            out.push(
              vrow([
                ("object_id", i(j.internal_id)),
                ("name", s(name)),
                ("stats_id", i(id)),
                ("auto_created", b(false)),
                ("user_created", b(false)),
                ("no_recompute", b(false)),
                ("stats_generation_method_desc", s("Sort based statistics")),
                ("replica_role_id", i(1)),
                ("replica_role_desc", s("PRIMARY")),
              ]),
            )
          "sys.index_columns" => {
            let keys = if id == 1 {
              [1, 2, 3]
            } else if id == 2 {
              (7).until(cols.length() + 1).collect()
            } else {
              [1, 3, 2, 4]
            }
            let included = if id == 3 {
              (7).until(cols.length() + 1).collect()
            } else {
              []
            }
            for n, c in keys + included {
              out.push(
                vrow([
                  ("object_id", i(j.internal_id)),
                  ("index_id", i(id)),
                  ("index_column_id", i(n + 1)),
                  ("column_id", i(c)),
                  (
                    "key_ordinal",
                    TinyInt(if n < keys.length() { n + 1 } else { 0 }),
                  ),
                  ("partition_ordinal", TinyInt(0)),
                  ("is_descending_key", b(false)),
                  ("is_included_column", b(n >= keys.length())),
                ]),
              )
            }
          }
          "sys.partitions" => {
            if ix.disabled && id != 1 {
              continue
            }
            let pid : @types.Value = BigInt(hobt_id(j.internal_id, id))
            out.push(
              vrow([
                ("partition_id", pid),
                ("object_id", i(j.internal_id)),
                ("index_id", i(id)),
                ("partition_number", i(1)),
                ("hobt_id", pid),
                ("rows", BigInt(json_internal_row_count(db, t, ix, j))),
                ("filestream_filegroup_id", SmallInt(0)),
                ("data_compression", TinyInt(j.compression)),
                (
                  "data_compression_desc",
                  s(
                    match j.compression {
                      1 => "ROW"
                      2 => "PAGE"
                      _ => "NONE"
                    },
                  ),
                ),
                ("xml_compression", b(false)),
                ("xml_compression_desc", s("OFF")),
              ]),
            )
          }
          _ => ()
        }
      }
    }
  }
}
