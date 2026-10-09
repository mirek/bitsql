///|
/// Thin native host: moves bytes between sockets and the pure engine and
/// fires timers. Knows nothing about SQL or TDS.
///
/// Usage: host [--version] [--listen HOST:PORT] [--record FILE] [--database NAME]...
///             [--auto-create-databases]
///   --listen    default 127.0.0.1:47333; port 0 picks a free port
///   --record    append every engine event to FILE for `replay`
///   --database  create database NAME at startup (repeatable)
///   --auto-create-databases  logins to unknown databases create them
///               instead of failing with 4060 (not SQL Server behavior)
///   --max-request-work N  work units per request before it fails with
///               50108 (runaway protection; default 300000000)
///   --tls-cert FILE --tls-key FILE  PEM certificate and key for TLS
///               (default: a built-in self-signed localhost certificate)
///   --http-ca FILE  PEM trust roots for outbound HTTPS (default: system roots)
///   --no-tls    refuse encryption like a server without a certificate
/// Prints `listening on HOST:PORT` to stderr once bound (harness contract).
async fn main {
  let args = @env.args()
  if args.contains("--version") {
    @stdio.stdout.write("bitsql \{@engine.version()}\n")
    return
  }
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
  let tls_files = setup_tls(args)
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
    max_request_work: match flag(args, "--max-request-work") {
      Some(n) =>
        @string.parse_int64(n) catch {
          _ => @engine.default_max_request_work
        }
      None => @engine.default_max_request_work
    },
    tls: tls_files is Some(_),
  }
  let engine = @engine.Engine::new(config, seed)
  let monitoring : @engine.Event = {
    input: MonitoringStarted(cpu_count(), memory_kb()),
    now: clock_ticks(),
  }
  if record is Some(f) {
    f.write(@engine.encode_event(monitoring))
  }
  ignore(engine.handle(monitoring))
  let sockets = socket_count()
  let facts : @engine.Event = {
    input: SystemFacts([
      ("socket_count", sockets.to_int64()),
      ("cores_per_socket", cores_per_socket().to_int64()),
      (
        "hyperthread_ratio",
        if sockets > 0 {
          cpu_count().to_int64() / sockets.to_int64()
        } else {
          0L
        },
      ),
      ("numa_node_count", numa_count().to_int64()),
      ("container_type", container_type().to_int64()),
      ("sqlserver_start_time_ms_ticks", boot_ms()),
    ]),
    now: monitoring.now,
  }
  if record is Some(f) {
    f.write(@engine.encode_event(facts))
  }
  ignore(engine.handle(facts))
  let http_trust : @tls.TrustedRoot = match flag(args, "--http-ca") {
    Some(path) => CustomPemFile(path)
    None => SystemRoot
  }
  let http_tasks : Map[Int, @async.Task[Unit]] = Map([])
  let queue : @aqueue.Queue[@engine.Input] = @aqueue.Queue(kind=Unbounded)
  let conns : Map[Int, Conn] = Map([])
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
        let cpu_before = cpu_us()
        let outputs = engine.handle(event)
        let cpu_delta = cpu_us() - cpu_before
        let event_id = match input {
          Received(id, _) | TimerFired(id) | HttpCompleted(id, _, _) => Some(id)
          _ => None
        }
        if event_id is Some(id) {
          let charge : @engine.Event = {
            input: CpuUsed(id, cpu_delta),
            now: event.now,
          }
          if record is Some(f) {
            f.write(@engine.encode_event(charge))
          }
          ignore(engine.handle(charge))
        }
        // Measurement handshakes run immediately: no other request, socket I/O,
        // or scheduling delay is charged to the measured statement.
        let mut sample_index = 0
        while sample_index < outputs.length() {
          if outputs[sample_index] is Sample(id) {
            let sample : @engine.Event = {
              input: Measured(id, 0L),
              now: clock_ticks(),
            }
            if record is Some(f) {
              f.write(@engine.encode_event(sample))
            }
            let before = cpu_us()
            outputs.append(engine.handle(sample))
            let charge : @engine.Event = {
              input: CpuUsed(id, cpu_us() - before),
              now: sample.now,
            }
            if record is Some(f) {
              f.write(@engine.encode_event(charge))
            }
            ignore(engine.handle(charge))
          }
          sample_index += 1
        }
        for o in outputs {
          match o {
            Sample(_) => ()
            Send(id, bytes) =>
              match conns.get(id) {
                Some(conn) =>
                  try {
                    match conn.mode {
                      Tls({ tls: Some(tls), .. }) => tls.write(bytes)
                      _ => conn.tcp.write(bytes)
                    }
                  } catch {
                    _ => {
                      conn.tcp.close()
                      conns.remove(id)
                    }
                  }
                None => ()
              }
            Close(id) =>
              match conns.get(id) {
                Some(conn) => {
                  conn.tcp.close()
                  conns.remove(id)
                }
                None => ()
              }
            StartTls(id) =>
              match conns.get(id) {
                Some(conn) => conn.mode = Pending
                None => ()
              }
            EndTls(id) =>
              match conns.get(id) {
                Some(conn) => {
                  if conn.mode is Tls(wire) {
                    wire.chunks.close()
                  }
                  conn.mode = Plain
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
            FetchHttp(id, generation, request) => {
              let task = group.spawn(allow_failure=true, () => {
                let result = perform_http(request, http_trust)
                http_tasks.remove(generation)
                queue.put(HttpCompleted(id, generation, result))
              })
              http_tasks[generation] = task
            }
            CancelHttp(_, generation) =>
              if http_tasks.get(generation) is Some(task) {
                http_tasks.remove(generation)
                task.cancel()
              }
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
      let conn = { tcp, mode: Plain, }
      conns[id] = conn
      queue.put(Connected(id))
      group.spawn_bg(allow_failure=true, () => {
        defer queue.try_put(Closed(id)) |> ignore
        defer (if conn.mode is Tls(wire) { wire.chunks.close() })
        while tcp.read_some() is Some(bytes) {
          match conn.mode {
            Plain => queue.put(Received(id, bytes))
            Tls(wire) => wire.chunks.put(bytes)
            Pending =>
              match tls_files {
                Some(files) => {
                  let wire = TlsWire::new(tcp)
                  conn.mode = Tls(wire)
                  wire.chunks.put(bytes)
                  group.spawn_bg(allow_failure=true, () => {
                    run_tls(wire, files, b => queue.put(Received(id, b))) catch {
                      e => {
                        @stdio.stderr.write("connection \{id}: TLS: \{e}\n")
                        tcp.close()
                        return
                      }
                    }
                    // EOF: unless login-only TLS ended, the session is over
                    if conn.mode is Tls(_) {
                      tcp.close()
                    }
                  })
                }
                None => tcp.close()
              }
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
