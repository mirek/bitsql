///|
fn Session::exec_create_json_index(
  self : Session,
  ci : @ast.CreateIndex,
  paths : Array[String],
) -> Unit raise {
  self.cur_cmd = 253
  self.ddl_cmd = 253
  guard self.find_table(ci.table) is Some((scope, t)) else {
    if self.find_module(ci.table) is Some({ kind: View, .. }) {
      raise @types.sql_error(
        13678,
        "Could not create the JSON index on object '\{object_text(ci.table)}' because that object is not a table. Create the index on the base table column.",
      )
    }
    raise @types.sql_error(
      1088,
      "Cannot find the object \"\{object_text(ci.table)}\" because it does not exist or you do not have permissions.",
      state=12,
    )
  }
  for option in ci.options {
    if option.name is ("ONLINE" | "IGNORE_DUP_KEY" | "STATISTICS_NORECOMPUTE") {
      raise @types.sql_error(
        153,
        "Invalid usage of the option \{option.name} in the CREATE JSON INDEX statement.",
        state=35,
        severity=15,
      )
    }
  }
  let (fill_factor, _, drop_existing) = index_with_options(
    ci.options.filter(o => o.name != "OPTIMIZE_FOR_ARRAY_SEARCH"),
    false,
  )
  let mut padded = false
  let mut array_search = false
  let mut row_locks = true
  let mut page_locks = true
  let mut compression = 0
  for o in ci.options {
    let value = o.value.unwrap_or("").to_upper()
    match o.name {
      "PAD_INDEX" => padded = value == "ON"
      "OPTIMIZE_FOR_ARRAY_SEARCH" => array_search = value == "ON"
      "ALLOW_ROW_LOCKS" => row_locks = value == "ON"
      "ALLOW_PAGE_LOCKS" => page_locks = value == "ON"
      "DATA_COMPRESSION" =>
        compression = if value == "PAGE" {
          2
        } else if value == "ROW" {
          1
        } else {
          0
        }
      "ONLINE" if value == "ON" =>
        raise @types.sql_error(
          153,
          "Invalid usage of the option ONLINE in the CREATE JSON INDEX statement.",
          state=35,
          severity=15,
        )
      _ => ()
    }
  }
  let existing = t.indexes.search_by(ix => {
    ix.name.to_lower() == ci.name.name.to_lower()
  })
  if !drop_existing && existing is Some(_) {
    raise @types.sql_error(
      1913,
      "The operation failed because an index or statistics with name '\{ci.name.name}' already exists on table '\{object_text(ci.table)}'.",
      state=3,
    )
  }

  guard ci.columns is [c] else {
    raise @types.not_supported("JSON index with multiple document columns")
  }
  if existing is Some(k) && t.indexes[k].json is None {
    raise @types.sql_error(
      13685,
      "A JSON index '\{ci.name.name}' cannot be found on column '\{c.name.name}' on table '\{object_text(ci.table)}'.",
    )
  }
  guard t.column_index(c.name.name) is Some(column) else {
    raise @types.sql_error(
      1911,
      "Column name '\{c.name.name}' does not exist in the target table, index or view.",
      state=7,
    )
  }
  if drop_existing && existing is None {
    raise @types.sql_error(
      13685,
      "A JSON index '\{ci.name.name}' cannot be found on column '\{c.name.name}' on table '\{object_text(ci.table)}'.",
      state=2,
    )
  }
  if !(t.columns[column].ty is Json) {
    raise @types.sql_error(
      13680,
      "Column '\{c.name.name}' on table '\{object_text(ci.table)}' is not of JSON data type, which is required to create a JSON index on it.",
    )
  }
  if !t.indexes.any(ix => ix.primary && ix.clustered && ix.columns.length() < 32) {
    raise @types.sql_error(
      13672,
      "Table '\{object_text(ci.table)}' needs to have a clustered primary key with less than 32 columns in it in order to create a JSON index on it.",
    )
  }
  for i, ix in t.indexes {
    if ix.json is Some(_) &&
      ix.columns.any(c => c.0 == column) &&
      existing != Some(i) {
      raise @types.sql_error(
        13681,
        "A JSON index '\{ix.name}' already exists on column '\{c.name.name}' on table '\{object_text(ci.table)}', and multiple JSON indexes per column are not allowed.",
      )
    }
  }
  let prefixes : Array[String] = []
  let parsed_paths : Array[@json.Path] = []
  for text in paths {
    let path = @json.parse_path(text, native=true) catch {
      @json.JsonError(n, state, message) =>
        raise @types.sql_error(n, message, state~)
    }
    for step in path.steps {
      match step {
        Key(_) | Index(_) => ()
        AnyIndex =>
          raise @types.sql_error(
            13683,
            "Invalid JSON paths in JSON index.",
            state=2,
          )
        _ =>
          raise @types.sql_error(
            13683,
            "Invalid JSON paths in JSON index.",
            state=3,
          )
      }
    }
    let prefix = path.concrete_prefix()
    // Oracle overlap checks in the default CI database compare semantic paths.
    for prior in parsed_paths {
      let n = @cmp.minimum(prior.steps.length(), path.steps.length())
      let mut equal = true
      for i in 0..<n {
        let matches = match (prior.steps[i], path.steps[i]) {
          (Key(a), Key(b)) =>
            @types.compare_strings(a, b, self.scope_collation(scope)) == 0
          (Index(a), Index(b)) => a == b
          _ => false
        }
        if !matches {
          equal = false
          break
        }
      }
      if equal {
        raise @types.sql_error(13683, "Invalid JSON paths in JSON index.")
      }
    }
    parsed_paths.push(path)
    prefixes.push(prefix)
  }
  let index_id = match existing {
    Some(k) => t.indexes[k].index_id
    None =>
      t.indexes.fold(init=1215999, (id, ix) => {
        if ix.json is Some(_) && ix.index_id > id {
          ix.index_id
        } else {
          id
        }
      }) +
      1
  }
  let ix : @store.Index = {
    index_id,
    object_id: 0,
    name: ci.name.name,
    auto_named: false,
    unique: false,
    primary: false,
    clustered: false,
    columns: [(column, false)],
    included: [],
    filter: None,
    not_null_filter: [],
    filter_terms: [],
    fill_factor,
    ignore_dup_key: false,
    is_constraint: false,
    disabled: false,
    vector: None,
    json: Some({
      internal_id: self.server.object_id(),
      created: self.rt.now,
      modified: self.rt.now,
      disabled_rows: None,
      paths,
      prefixes,
      array_search,
      padded,
      row_locks,
      page_locks,
      compression,
    }),
  }
  let indexes = t.indexes.filter(old => old.index_id != index_id)
  indexes.push(ix)
  indexes.sort_by((a, b) => a.index_id.compare(b.index_id))
  self.write(scope, self.db_of(scope).alter_table({ ..t, indexes, }))
  self.rt.rowcount = 0
  self.done(744)
}

///|
fn Session::seek_json(
  self : Session,
  scope : Int,
  id : Int,
  column : Int,
  path : String,
) -> Array[(Int64, Array[@types.Value])]? {
  if scope == 2 {
    return None
  }
  let parsed = @json.parse_path(path, native=true) catch { _ => return None }
  let prefix = parsed.concrete_prefix()
  let db = self.db_of(scope)
  guard db.table(id) is Some(t) else { return None }
  for i, ix in t.indexes {
    guard !ix.disabled &&
      ix.columns is [(c, _)] &&
      c == column &&
      ix.json is Some(options) else {
      continue
    }
    if !options.prefixes.any(root => prefix.has_prefix(root)) {
      continue
    }
    let out = []
    for rowid in db.seek_json_path(id, i, prefix) {
      if db.row(id, rowid) is Some(row) {
        out.push((rowid, row))
      }
    }
    return Some(out)
  }
  None
}

///|
/// An indexed predicate's literal path is validated during planning, before
/// result metadata. Variable paths retain runtime validation.
fn Session::check_json_index_paths(
  self : Session,
  plan : @ir.Plan,
) -> Unit raise @types.SqlError {
  match plan {
    Filter(Scan(scope~, id~, ..), pred) => {
      guard scope != 2 && self.db_of(scope).table(id) is Some(table) else {
        return
      }
      fn check(e : @ir.Expr) -> Unit raise @types.SqlError {
        match e.kind {
          Call(Named(name), args) if name
            is ("JSON_CONTAINS" | "JSON_PATH_EXISTS") => {
            let position = if name == "JSON_CONTAINS" { 2 } else { 1 }
            guard args[0].kind is Col(column) &&
              args[position].kind is Lit(String(path)) else {
              return
            }
            if table.indexes.any(ix => {
                !ix.disabled &&
                ix.json is Some(_) &&
                ix.columns.any(c => c.0 == column)
              }) {
              ignore(@json.parse_path(path, native=true)) catch {
                @json.JsonError(n, state, message) =>
                  raise @types.sql_error(n, message, state~)
              }
            }
          }
          Cmp(_, a, b, _) | And(a, b) | Or(a, b) => {
            check(a)
            check(b)
          }
          Not(inner) => check(inner)
          _ => ()
        }
      }
      check(pred)
    }
    Project(input, _)
    | Filter(input, _)
    | Sort(input, _)
    | Limit(input, _, _)
    | Distinct(input, _)
    | Aggregate(input, _, _, ..)
    | Window(input, _) => self.check_json_index_paths(input)
    Join(_, left, right, _, ..) | Apply(left, right, ..) => {
      self.check_json_index_paths(left)
      self.check_json_index_paths(right)
    }
    UnionAll(inputs) =>
      for input in inputs {
        self.check_json_index_paths(input)
      }
    _ => ()
  }
}
