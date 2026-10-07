///|
let current : Ref[@session.Session] = Ref(new_session())

///|
fn new_session() -> @session.Session {
  let server = @session.Server::new()
  server.create_database("playground")
  let s = @session.Session::new(server, spid=51, database="playground", seed=1L)
  s.set_work_limit(1000000L)
  s
}

///|
pub fn reset() -> Unit {
  current.val = new_session()
}

///|
struct ResultSet {
  columns : Array[String]
  types : Array[String]
  rows : Array[Array[Json]]
} derive(ToJson)

///|
/// A display adapter over the real session executor, with no SQL semantics of
/// its own. Strings retain exact bigint/decimal values across the JS boundary.
pub fn execute(sql : String, now : Double) -> String {
  let session = current.val
  let items : Array[@reply.Item] = session.run_batch(
    sql,
    now.to_int64() * 10000L + @engine.UNIX_EPOCH_TICKS,
  )
  let sets : Array[ResultSet] = []
  let messages : Array[Json] = []
  let counts : Array[String] = []
  let mut columns : Array[@tds.Column] = []
  for item in items {
    match item {
      ResultSet(cols) => {
        columns = cols
        sets.push({
          columns: cols.map(c => c.name),
          types: cols.map(c => @debug.to_string(c.type_info)),
          rows: [],
        })
      }
      Row(values) =>
        if sets.last() is Some(set) {
          set.rows.push(
            values.mapi((i, value) => display_cell(columns[i].type_info, value)),
          )
        }
      Message(m) =>
        messages.push({
          "number": m.number.to_json(),
          "severity": m.class.to_json(),
          "line": m.line.to_json(),
          "text": m.message.to_json(),
        })
      StatementDone(count=Some(n), ..)
      | InProcDone(count=Some(n), ..)
      | ProcDone(count=Some(n), ..) => counts.push(n.to_string())
      _ => ()
    }
  }
  // A browser has no host scheduler or outbound HTTP adapter. Never pretend a
  // parked request completed. Reset so partial work cannot leak into the next run.
  let interrupted = session.is_parked() || session.pending_http() is Some(_)
  if interrupted {
    reset()
  }
  let result : Json = {
    "sets": sets.to_json(),
    "messages": messages.to_json(),
    "counts": counts.to_json(),
    "interrupted": interrupted.to_json(),
  }
  result.stringify()
}

///|
fn display_cell(ti : @tds.TypeInfo, value : @tds.WireValue) -> Json {
  match value {
    Null => Json::null()
    Variant(base, inner) => display_cell(base, inner)
    _ => {
      let ty = @session.param_type(ti)
      let v = @session.param_value(ty, value)
      let style = match value {
        Binary(_) => Some(1)
        Float(_) => Some(3)
        Money(_) => Some(2)
        Date(_)
        | Time(_)
        | DateTime2(_, _)
        | DateTimeOffset(_, _, _)
        | DateTime(_, _) => Some(126)
        _ => None
      }
      let text = @types.render(v, ty, style) catch {
        _ => "Display unavailable: " + @debug.to_string(value)
      }
      text.to_json()
    }
  }
}
