///|
/// A server message (ERROR or INFO token) in SQL Server terms.
pub(all) struct SqlMessage {
  number : Int
  state : Int
  class : Int // severity; >= 11 is an error
  message : String
  procedure : String
  line : Int
} derive(Debug, Eq)

///|
/// Statement-level response items produced by execution. The engine renders
/// them into tokens, choosing DONE vs DONEINPROC and the MORE/FINAL bits
/// from the request kind, so executors never deal with token framing.
pub(all) enum Item {
  /// Start of a result set (COLMETADATA).
  ResultSet(Array[@tds.Column])
  Row(Array[@tds.WireValue])
  /// End of one statement. `count` is Some when DONE_COUNT applies (NOCOUNT OFF
  /// and a counting statement); `error` sets DONE_ERROR.
  StatementDone(cmd~ : Int, count~ : Int64?, error~ : Bool)
  Message(SqlMessage)
  ReturnStatus(Int)
  ReturnValue(
    ordinal~ : Int,
    name~ : String,
    type_info~ : @tds.TypeInfo,
    value~ : @tds.WireValue
  )
} derive(Debug)

///|
pub(all) enum RequestKind {
  Batch
  Rpc
} derive(Debug, Eq)

///|
/// Renders execution items into one tabular-result payload. In a batch,
/// statements end with DONE(MORE) and the last DONE is FINAL; in an RPC they
/// end with DONEINPROC(MORE) and the call ends with DONEPROC(FINAL) after
/// RETURNVALUE/RETURNSTATUS (MS-TDS 4.9, mssqlite respond.ts).
pub fn render(
  kind : RequestKind,
  items : Array[Item],
  server_name : String,
) -> Bytes raise @tds.TdsError {
  let w = @tds.Writer::new(size_hint=256)
  let mut cols : Array[@tds.Column] = []
  let mut pending_error = false
  // Index of the last StatementDone, to know which one is final in a batch.
  let mut last_done = -1
  for i, it in items {
    if it is StatementDone(..) {
      last_done = i
    }
  }
  let mut any_done = false
  for i, it in items {
    match it {
      ResultSet(c) => {
        cols = c
        @tds.write_colmetadata(w, c)
      }
      Row(values) => @tds.write_row(w, cols, values)
      Message(m) => {
        if m.class > 10 {
          pending_error = true
        }
        @tds.write_message(
          w,
          is_error=m.class > 10,
          number=m.number,
          state=m.state,
          class=m.class,
          message=m.message,
          server=server_name,
          procedure=m.procedure,
          line=m.line,
        )
      }
      StatementDone(cmd~, count~, error~) => {
        any_done = true
        let mut status = 0
        if count is Some(_) {
          status = status | @tds.DONE_COUNT
        }
        if error || pending_error {
          status = status | @tds.DONE_ERROR
        }
        pending_error = false
        match kind {
          Batch => {
            if i != last_done {
              status = status | @tds.DONE_MORE
            }
            @tds.write_done(w, Done, status, cmd, count.unwrap_or(0))
          }
          Rpc => {
            status = status | @tds.DONE_MORE
            @tds.write_done(w, DoneInProc, status, cmd, count.unwrap_or(0))
          }
        }
      }
      ReturnStatus(s) => @tds.write_return_status(w, s)
      ReturnValue(ordinal~, name~, type_info~, value~) =>
        @tds.write_return_value(
          w,
          ordinal~,
          name~,
          udf=false,
          type_info~,
          value~,
        )
    }
  }
  match kind {
    Batch =>
      if !any_done {
        let status = if pending_error { @tds.DONE_ERROR } else { 0 }
        @tds.write_done(w, Done, status, 0, 0)
      }
    Rpc => {
      let status = if pending_error { @tds.DONE_ERROR } else { 0 }
      @tds.write_done(w, DoneProc, status, @tds.CMD_EXECUTE, 0)
    }
  }
  w.to_bytes()
}
