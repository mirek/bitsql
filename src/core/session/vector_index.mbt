///|
fn vector_parameters(start : Int) -> String {
  "{\"StartId\":\"\{start}\", \"L\":\"48\", \"M\":\"8\", \"R\":\"48\"}"
}

///|
fn Session::exec_create_vector_index(
  self : Session,
  ci : @ast.CreateIndex,
) -> Unit raise {
  self.cur_cmd = 253
  self.ddl_cmd = 253
  if !self.preview_enabled() {
    raise @types.sql_error(
      343,
      "Unknown object type 'VECTOR' used in a CREATE, DROP, or ALTER statement.",
      state=2,
      severity=15,
    )
  }
  let mut metric : @store.VectorMetric? = None
  let mut dop = 32
  for option in ci.options {
    if option.name == "METRIC" {
      metric = Some(
        match
          option.value.unwrap_or("").trim_end(chars=" ").to_owned().to_lower() {
          "cosine" => @store.Cosine
          "euclidean" => @store.Euclidean
          _ => @store.Dot
        },
      )
    } else if option.name == "MAXDOP" {
      dop = @string.parse_int(option.value.unwrap_or("0")) catch {
        _ => raise @types.not_supported("vector index MAXDOP value")
      }
      if dop < 0 || dop > 32767 {
        raise @types.not_supported(
          "vector index MAXDOP outside the verified range",
        )
      }
      if dop == 0 {
        dop = 32
      }
    }
  }
  guard metric is Some(metric) else {
    raise @types.sql_error(
      153,
      "Invalid usage of the option metric in the CREATE VECTOR INDEX statement.",
      state=7,
      severity=15,
    )
  }
  guard self.find_table(ci.table) is Some((scope, t)) else {
    raise @types.sql_error(
      1088,
      "Cannot find the object \"\{object_text(ci.table)}\" because it does not exist or you do not have permissions.",
      state=12,
    )
  }
  if t.indexes.any(ix => ix.name.to_lower() == ci.name.name.to_lower()) {
    raise @types.sql_error(
      1913,
      "The operation failed because an index or statistics with name '\{ci.name.name}' already exists on table '\{object_text(ci.table)}'.",
      state=203,
    )
  }
  guard ci.columns is [column] else {
    raise @types.not_supported("multi-column vector index")
  }
  guard t.column_index(column.name.name) is Some(ordinal) else {
    raise @types.sql_error(
      1911,
      "Column name '\{column.name.name}' does not exist in the target table, index or view.",
      state=7,
    )
  }
  if !(t.columns[ordinal].ty is Vector(_, _)) {
    raise @types.sql_error(
      42215,
      "Could not create the vector index on the column '\{column.name.name}' on table '\{object_text(ci.table)}', because it is not of type vector.",
      state=3,
    )
  }
  let pk_error = "Table '\{object_text(ci.table)}' must have a clustered primary key on a single 4 byte INT column to create a vector index."
  guard t.indexes.iter().find_first(ix => ix.primary && ix.clustered)
    is Some(pk) else {
    raise @types.sql_error(42217, pk_error)
  }
  guard pk.columns is [(key_column, _)] else {
    raise @types.sql_error(42217, pk_error, state=2)
  }
  if t.columns[key_column].ty != @types.Int {
    raise @types.sql_error(42217, pk_error, state=2)
  }
  if t.indexes.any(ix => {
      ix.vector is Some(_) && ix.columns.any(c => c.0 == ordinal)
    }) {
    raise @types.sql_error(
      42230,
      "Cannot create vector index on column '\{column.name.name}' because it already has an existing vector index.",
    )
  }
  let db = self.db_of(scope)
  let input : Array[(Int, @types.VectorData)] = []
  for (_, row) in db.rows(t.id) {
    if row[ordinal] is Vector(vector) && row[key_column] is Int(key) {
      input.push((key, vector))
    }
  }
  input.sort_by((a, b) => a.0.compare(b.0))
  if input.length() > 10000 {
    raise @types.not_supported("vector index sampling above 10000 rows")
  }
  let mut index_id = 1152000
  while t.indexes.any(ix => ix.index_id == index_id) {
    index_id += 1
  }
  let ix : @store.Index = {
    json: None,
    vector: Some({ metric, start: 0, parameters: vector_parameters(0), }),
    index_id,
    object_id: 0,
    name: ci.name.name,
    auto_named: false,
    unique: false,
    primary: false,
    clustered: false,
    columns: [(ordinal, false)],
    included: [],
    filter: None,
    not_null_filter: [],
    filter_terms: [],
    fill_factor: 0,
    ignore_dup_key: false,
    is_constraint: false,
    disabled: false,
  }
  let indexes = t.indexes.copy()
  indexes.push(ix)
  indexes.sort_by((a, b) => a.index_id.compare(b.index_id))
  let indexed = { ..t, indexes, }
  self.write(scope, db.alter_table(indexed))
  self.info(
    8625,
    0,
    "Warning: The join order has been enforced because a local join hint is used.",
    self.stmt_line,
  )
  let start = @store.vector_seed(input, metric).unwrap_or(0) catch {
    error => {
      self.pending.push(error)
      raise @types.sql_error(
        42234, "Internal SQL error during DiskANN graph build.",
      )
    }
  }
  let mut a = dop
  let mut b = 30
  while b != 0 {
    let remainder = a % b
    a = b
    b = remainder
  }
  let alignment = dop / a * 30
  let graph = @store.vector_build(input, start, metric, alignment~) catch {
    error => {
      self.pending.push(error)
      raise @types.sql_error(
        42234, "Internal SQL error during DiskANN graph build.",
      )
    }
  }
  let indexes = indexed.indexes.map(ix => {
    if ix.index_id == index_id {
      {
        ..ix,
        vector: Some({ metric, start, parameters: vector_parameters(start), }),
      }
    } else {
      ix
    }
  })
  self.write(
    scope,
    self
    .db_of(scope)
    .alter_table({ ..indexed, indexes, })
    .with_vector_graph(t.id, index_id, graph),
  )
  if !input.is_empty() {
    self.out.push(InProcDone(cmd=186, count=None, error=false))
  }
  self.rt.rowcount = 0
  self.done(743)
}

///|
fn check_vector_dml(t : @store.Table) -> Unit raise @types.SqlError {
  if t.indexes.any(ix => ix.vector is Some(_)) {
    raise @types.sql_error(
      42231,
      "Data modification statement failed because table '\{t.name}' has a vector index on it.",
    )
  }
}

///|
fn Session::search_vector_index(
  self : Session,
  scope : Int,
  id : Int,
  index_id : Int,
  query : @types.VectorData,
  top : Int64,
  width : Int64,
  expansion : Int64,
) -> Array[Array[@types.Value]] raise @types.SqlError {
  let db = self.db_of(scope)
  guard db.table(id) is Some(t) else {
    raise @types.not_supported("vector search after table removal")
  }
  guard t.indexes.iter().find_first(ix => ix.index_id == index_id) is Some(ix) &&
    ix.vector is Some(vector) else {
    raise @types.not_supported("vector search after index removal")
  }
  let ty = t.columns[ix.columns[0].0].ty
  if ty is Vector(dimensions, base) {
    if dimensions != query.dimensions() {
      raise @types.sql_error(
        42204,
        "The vector dimensions \{dimensions} and \{query.dimensions()} do not match.",
        state=3,
      )
    }
    if base != query.base() {
      raise @types.sql_error(
        42243, "VECTOR_DISTANCE function does not support different base types for vector arguments.",
      )
    }
  }
  guard db.vector_graph(id, index_id) is Some(graph) else {
    raise @types.not_supported("search of an incomplete vector index")
  }
  guard t.indexes.search_by(ix => ix.primary && ix.clustered) is Some(pk) else {
    raise @types.not_supported("vector index without its primary key")
  }
  let rows : Array[Array[@types.Value]] = []
  for
    candidate in graph.search_parameters(
      query,
      vector.metric,
      top,
      width,
      expansion,
    ) {
    if db.find_key(id, pk, [Int(candidate.key)]) is Some(rowid) &&
      db.row(id, rowid) is Some(row) {
      let result : Array[@types.Value] = [Float(candidate.distance)]
      result.append(row)
      rows.push(result)
    }
  }
  rows
}
