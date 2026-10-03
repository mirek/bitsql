///|
/// Thin native host: moves bytes between sockets and the pure engine and
/// fires timers. Knows nothing about SQL or TDS.
///
/// Usage: host [--listen HOST:PORT]   (default 127.0.0.1:47333; port 0 = any)
/// Prints `listening on HOST:PORT` to stderr once bound (harness contract).
async fn main {
  let listen = parse_listen(@env.args())
  let server = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  let port = server.addr.port()
  let host = listen.split(":").next().unwrap_or("127.0.0.1").to_owned()
  @stdio.stderr.write("listening on \{host}:\{port}\n")
  let engine = @engine.Engine::new(@engine.Config::default(), now_ticks())
  let queue : @aqueue.Queue[@engine.Input] = @aqueue.Queue(kind=Unbounded)
  let conns : Map[Int, @socket.Tcp] = Map([])
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      while true {
        let input = queue.get()
        let outputs = engine.handle({ input, now: now_ticks(), })
        for o in outputs {
          match o {
            Send(id, bytes) =>
              match conns.get(id) {
                Some(tcp) =>
                  tcp.write(bytes) catch {
                    _ => {
                      tcp.close()
                      conns.remove(id)
                    }
                  }
                None => ()
              }
            Close(id) =>
              match conns.get(id) {
                Some(tcp) => {
                  tcp.close()
                  conns.remove(id)
                }
                None => ()
              }
            Log(msg) => @stdio.stderr.write("\{msg}\n")
            SetTimer(_, _) | CancelTimer(_) | Yield => ()
          }
        }
      }
    })
    let mut next_id = 0
    while true {
      let (tcp, _) = server.accept()
      next_id += 1
      let id = next_id
      conns[id] = tcp
      queue.put(Connected(id))
      group.spawn_bg(allow_failure=true, () => {
        defer queue.try_put(Closed(id)) |> ignore
        while true {
          match tcp.read_some() {
            Some(bytes) => queue.put(Received(id, bytes))
            None => break
          }
        }
      })
    }
  })
}

///|
fn parse_listen(args : Array[String]) -> String {
  for i in 0..<args.length() {
    if args[i] == "--listen" && i + 1 < args.length() {
      return args[i + 1]
    }
  }
  "127.0.0.1:47333"
}

///|
/// Host clock as 100 ns ticks since 0001-01-01 UTC.
fn now_ticks() -> Int64 {
  @async.now() * 10000L + @engine.UNIX_EPOCH_TICKS
}
