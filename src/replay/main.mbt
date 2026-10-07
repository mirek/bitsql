///|
/// Replays an event log recorded with `host --record FILE` through a fresh
/// engine with the recorded seed, printing every output. Because the core is
/// pure, the outputs are exactly what the recorded run sent.
///
/// Usage: replay FILE [--hex]
async fn main {
  let args = @env.args()
  let hex = args.contains("--hex")
  let path = args[1:].iter().find_first(a => !a.has_prefix("--"))
  guard path is Some(path) else {
    @stdio.stderr.write("usage: replay FILE [--hex]\n")
    return
  }
  let data = @fs.read_file(path).binary()
  let (seed, events) = @engine.decode_event_log(data)
  let engine = @engine.Engine::new(@engine.Config::default(), seed)
  for i, ev in events {
    for o in engine.handle(ev) {
      let line = match o {
        Send(id, b) =>
          if hex {
            "#\{i} conn \{id} send \{b.length()}: \{@tds.hex(b)}"
          } else {
            "#\{i} conn \{id} send \{b.length()} bytes"
          }
        Close(id) => "#\{i} conn \{id} close"
        Log(m) => "#\{i} log \{m}"
        SetTimer(t, ms) => "#\{i} set timer \{t} \{ms}ms"
        CancelTimer(t) => "#\{i} cancel timer \{t}"
        Yield => "#\{i} yield"
        StartTls(id) => "#\{i} conn \{id} start tls"
        EndTls(id) => "#\{i} conn \{id} end tls"
        FetchHttp(id, generation, _) =>
          "#\{i} conn \{id} fetch HTTP \{generation}"
        CancelHttp(id, generation) =>
          "#\{i} conn \{id} cancel HTTP \{generation}"
      }
      @stdio.stdout.write(line + "\n")
    }
  }
  @async.sleep(0)
}
