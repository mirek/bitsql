///|
/// Thin native host: moves bytes between sockets and the pure engine and
/// fires timers. Knows nothing about SQL or TDS.
///
/// Usage: host [--listen HOST:PORT] [--record FILE] [--database NAME]...
///             [--auto-create-databases]
///   --listen    default 127.0.0.1:47333; port 0 picks a free port
///   --record    append every engine event to FILE for `replay`
///   --database  create database NAME at startup (repeatable)
///   --auto-create-databases  logins to unknown databases create them
///               instead of failing with 4060 (not SQL Server behavior)
/// Prints `listening on HOST:PORT` to stderr once bound (harness contract).
async fn main {
  let args = @env.args()
  let listen = flag(args, "--listen").unwrap_or("127.0.0.1:47333")
  let seed = now_ticks()
  let record = match flag(args, "--record") {
    Some(path) => {
      let f = @fs.create(path, allow_existing=true)
      f.write(@engine.encode_event_log_header(seed))
      Some(f)
    }
    None => None
  }
  let server = @socket.TcpServer(@socket.Addr::parse(listen), reuse_addr=true)
  let port = server.addr.port()
  let host = listen.split(":").next().unwrap_or("127.0.0.1").to_owned()
  @stdio.stderr.write("listening on \{host}:\{port}\n")
  let databases = []
  for i in 0..<args.length() {
    if args[i] == "--database" && i + 1 < args.length() {
      databases.push(args[i + 1])
    }
  }
  let config : @engine.Config = {
    ..@engine.Config::default(),
    databases,
    auto_create_databases: args.contains("--auto-create-databases"),
  }
  let engine = @engine.Engine::new(config, seed)
  let queue : @aqueue.Queue[@engine.Input] = @aqueue.Queue(kind=Unbounded)
  let conns : Map[Int, @socket.Tcp] = Map([])
  // pending timers: id → generation (a re-set or cancel invalidates it)
  let timers : Map[Int, Int] = Map([])
  let mut timer_gen = 0
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      while true {
        let input = queue.get()
        let event : @engine.Event = { input, now: now_ticks(), }
        if record is Some(f) {
          f.write(@engine.encode_event(event))
        }
        let outputs = engine.handle(event)
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
            SetTimer(id, ms) => {
              timer_gen += 1
              let gen = timer_gen
              timers[id] = gen
              group.spawn_bg(() => {
                @async.sleep(ms)
                if timers.get(id) == Some(gen) {
                  timers.remove(id)
                  queue.put(TimerFired(id))
                }
              })
            }
            CancelTimer(id) => timers.remove(id)
            Yield => ()
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
fn flag(args : Array[String], name : String) -> String? {
  for i in 0..<args.length() {
    if args[i] == name && i + 1 < args.length() {
      return Some(args[i + 1])
    }
  }
  None
}

///|
/// Host clock as 100 ns ticks since 0001-01-01 UTC.
fn now_ticks() -> Int64 {
  @async.now() * 10000L + @engine.UNIX_EPOCH_TICKS
}
