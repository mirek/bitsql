///|
/// Observations belong to execution history, not transactional table snapshots.
/// Timings are deliberately absent until supplied by host measurement events.
priv struct QueryStoreExecution {
  database : String
  text : String
  object_id : Int
  context : String
  settings : (Int, Int, Int, Int)
  first_time : Int64
  sequence : Int
}

///|
// Catalog projection will consume the identity/timestamp fields.
#warnings("-unused_field")
priv struct QueryStoreQuery {
  id : Int64
  text_id : Int64
  text : String
  object_id : Int
  context : String
  first_time : Int64
  last_time : Int64
  executions : Int64
  total_rows : Int64
  last_rows : Int64
  min_rows : Int64
  max_rows : Int64
}

///|
priv struct QueryStoreHistory {
  queries : Map[Int64, QueryStoreQuery]
  keys : Map[(String, Int, String), Int64]
  texts : Map[String, Int64]
  contexts : Map[String, QueryStoreContext]
  mut next_query : Int64
  mut next_text : Int64
}

///|
fn QueryStoreHistory::new() -> QueryStoreHistory {
  {
    queries: Map([]),
    keys: Map([]),
    texts: Map([]),
    contexts: Map([]),
    next_query: 1L,
    next_text: 1L,
  }
}

///|
fn QueryStoreHistory::copy(self : QueryStoreHistory) -> QueryStoreHistory {
  {
    queries: self.queries.copy(),
    keys: self.keys.copy(),
    texts: self.texts.copy(),
    contexts: self.contexts.copy(),
    next_query: self.next_query,
    next_text: self.next_text,
  }
}

///|
fn Server::query_history(self : Server, database : String) -> QueryStoreHistory {
  let key = database.to_lower()
  match self.query_histories.get(key) {
    Some(h) => h
    None => {
      let h = QueryStoreHistory::new()
      self.query_histories[key] = h
      h
    }
  }
}

///|
/// Do not guess resource usage from a statement's text or row count. This
/// collector establishes identity and counts independently of timing samples.
fn Session::query_store_begin(
  self : Session,
  stmt : @ast.Stmt,
) -> QueryStoreExecution? {
  guard stmt.kind is (Select(_) | Insert(_) | Update(_) | Delete(_) | Merge(_)) else {
    return None
  }
  let sequence = self.query_store_seen
  self.query_store_seen += 1
  let options = self.server.db_options(self.rt.database).query_store
  guard options.enabled && options.operation == 2 else { return None }
  // AUTO/CUSTOM admission needs CPU/compile observations. Until those arrive,
  // admission is not implemented yet; do not claim ALL semantics.
  if options.capture is (2 | 4) {
    return None
  }
  let proc = self.frame().proc_name.bind(name => {
    self.server.procs.get(name.to_lower())
  })
  let source = match proc {
    Some(p) => p.source
    None => self.text
  }
  guard stmt.span.start >= 0 && stmt.span.end <= source.length() else {
    return None
  }
  let statement = source[stmt.span.start:stmt.span.end]
    .trim()
    .trim_end(chars=";")
    .to_owned()
  guard statement != "" else { return None }
  let text = match proc {
    Some(p) if !p.def.params.is_empty() => {
      let declarations = p.def.params.map(param => {
        let span = param.type_.span
        let ty = if span.start >= 0 && span.end <= source.length() {
          source[span.start:span.end].to_owned()
        } else {
          type_text(param.type_)
        }
        param.name + " " + ty
      })
      "(" + declarations.join(",") + ")" + statement
    }
    _ => statement
  }
  let object_id = match proc {
    Some(p) => {
      let (schema, base) = split_name(p.def.name)
      self.db_of(0).lookup(schema, base).unwrap_or(0)
    }
    None => 0
  }
  let settings = self.query_store_context()
  let context = "\{settings.0}:\{settings.1}:\{settings.2}:\{settings.3}"
  let history = self.server.query_history(self.rt.database)
  // NONE stops new queries but existing entries may continue collecting.
  if options.capture == 3 && !history.keys.contains((text, object_id, context)) {
    return None
  }
  Some({
    database: self.rt.database,
    text,
    object_id,
    context,
    settings,
    first_time: self.rt.now,
    sequence,
  })
}

///|
fn Session::query_store_finish(
  self : Session,
  execution : QueryStoreExecution?,
  rows : Int64,
) -> Unit {
  guard execution is Some(e) else { return }
  // A suspended request can replay an already completed nested statement.
  // Its history survives rollback, but its replay must not count twice.
  guard !self.query_store_recorded.contains(e.sequence) else { return }
  self.query_store_recorded.add(e.sequence)
  let history = self.server.query_history(e.database)
  if !history.contexts.contains(e.context) {
    history.contexts[e.context] = {
      id: history.contexts.length().to_int64() + 1L,
      options: e.settings.0,
      language: e.settings.1,
      format: e.settings.2,
      datefirst: e.settings.3,
    }
  }
  let key = (e.text, e.object_id, e.context)
  match history.keys.get(key).bind(id => history.queries.get(id)) {
    Some(q) =>
      history.queries[q.id] = {
        ..q,
        last_time: self.rt.now,
        executions: q.executions + 1L,
        total_rows: q.total_rows + rows,
        last_rows: rows,
        min_rows: @cmp.minimum(q.min_rows, rows),
        max_rows: @cmp.maximum(q.max_rows, rows),
      }
    None => {
      let text_id = match history.texts.get(e.text) {
        Some(id) => id
        None => {
          let id = history.next_text
          history.next_text += 1L
          history.texts[e.text] = id
          id
        }
      }
      let id = history.next_query
      history.next_query += 1L
      history.keys[key] = id
      history.queries[id] = {
        id,
        text_id,
        text: e.text,
        object_id: e.object_id,
        context: e.context,
        first_time: e.first_time,
        last_time: self.rt.now,
        executions: 1L,
        total_rows: rows,
        last_rows: rows,
        min_rows: rows,
        max_rows: rows,
      }
    }
  }
}

///|
priv struct QueryStoreContext {
  id : Int64
  options : Int
  language : Int
  format : Int
  datefirst : Int
}

///|
/// Oracle context-settings: NOCOUNT/XACT_ABORT do not change plan identity.
fn Session::query_store_context(self : Session) -> (Int, Int, Int, Int) {
  let mut bits = 130 // ANSI_NULL_DFLT_ON plus the captured default status bit.
  for
    (name, mask, default_) in [
      ("ANSI_PADDING", 1, true),
      ("CONCAT_NULL_YIELDS_NULL", 8, true),
      ("ANSI_WARNINGS", 16, true),
      ("ANSI_NULLS", 32, true),
      ("QUOTED_IDENTIFIER", 64, true),
      ("ARITHABORT", 4096, true),
      ("NUMERIC_ROUNDABORT", 8192, false),
    ] {
    if self.session_flags.get(name).unwrap_or(default_) {
      bits = bits | mask
    }
  }
  let format = match self.rt.dates.format {
    Mdy => 1
    Dmy => 2
    Ymd => 3
    Ydm => 4
    Myd => 5
    Dym => 6
  }
  (bits, self.rt.dates.language, format, self.rt.datefirst)
}

///|
fn QueryStoreContext::row(self : QueryStoreContext) -> VRow {
  vrow([
    ("context_settings_id", BigInt(self.id)),
    (
      "set_options",
      Binary(Bytes::makei(4, i => (self.options >> (8 * (3 - i))).to_byte())),
    ),
    ("language_id", SmallInt(self.language)),
    ("date_format", SmallInt(self.format)),
    ("date_first", TinyInt(self.datefirst)),
    ("status", Binary(b"\x04\x00")),
    ("required_cursor_options", Int(0)),
    ("acceptable_cursor_options", Int(0)),
    ("merge_action_type", SmallInt(0)),
    ("default_schema_id", Int(-2)),
    ("is_replication_specific", Bit(false)),
    ("is_contained", Binary(b"\x00")),
  ])
}
