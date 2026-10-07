///|
priv enum Phase {
  AwaitPrelogin
  AwaitLogin
  LoggedIn
} derive(Debug)

///|
priv struct Conn {
  id : Int
  reassembler : @tds.Reassembler
  mut phase : Phase
  mut packet_size : Int
  /// Negotiated PRELOGIN encryption (ENCRYPT_OFF: TLS for LOGIN7 only).
  mut encryption : Int
}

///|
struct Engine {
  config : Config
  seed : Int64
  conns : Map[Int, Conn]
  server : @session.Server
  sessions : Map[Int, @session.Session]
  /// Requests waiting for locks, by connection id (decisions.md: request
  /// restart). Re-run when their session is woken.
  parked : Map[Int, Parked]
  /// RESETCONNECTION tokens to send before a connection's next response.
  reset_prefix : Map[Int, Bytes]
  http_pending : Map[Int, Int]
  mut http_generation : Int
}

///|
priv enum Parked {
  ParkedBatch(String)
  /// Remaining RPC calls (the parked one first) and the response bytes of
  /// the calls before it.
  ParkedRpc(Array[@tds.RpcCall], Bytes)
}

///|
pub fn Engine::new(config : Config, seed : Int64) -> Engine {
  let server = @session.Server::new()
  for name in config.databases {
    server.create_database(name)
  }
  {
    config,
    seed,
    conns: Map([]),
    server,
    sessions: Map([]),
    parked: Map([]),
    reset_prefix: Map([]),
    http_pending: Map([]),
    http_generation: 0,
  }
}

///|
pub fn Engine::handle(self : Engine, event : Event) -> Array[Output] {
  let out = []
  match event.input {
    Connected(id) =>
      self.conns[id] = {
        id,
        reassembler: @tds.Reassembler::new(),
        phase: AwaitPrelogin,
        packet_size: @tds.DEFAULT_PACKET_SIZE,
        encryption: @tds.ENCRYPT_NOT_SUP,
      }
    Closed(id) => {
      self.cancel_http(id, out)
      match self.sessions.get(id) {
        Some(s) => s.close()
        None => ()
      }
      self.parked.remove(id)
      self.conns.remove(id)
      self.sessions.remove(id)
      self.drain(event.now, out) catch {
        e => out.push(Log("drain after close: \{e}"))
      }
    }
    Received(id, bytes) =>
      match self.conns.get(id) {
        None => out.push(Log("data for unknown connection \{id}"))
        Some(conn) =>
          try {
            for msg in conn.reassembler.push(bytes) {
              self.on_message(conn, msg, event.now, out)
            }
            self.drain(event.now, out)
          } catch {
            e => {
              self.cancel_http(id, out)
              out.push(Log("connection \{id}: protocol error: \{e}"))
              out.push(Close(id))
              self.conns.remove(id)
            }
          }
      }
    TimerFired(id) =>
      // lock timeout of a parked request: it re-runs and fails with 1222
      if self.parked.contains(id) {
        self.sessions[id].time_out()
        try {
          self.rerun(id, event.now, out)
          self.drain(event.now, out)
        } catch {
          e => out.push(Log("lock timeout re-run: \{e}"))
        }
      }
    HttpCompleted(id, generation, result) =>
      if self.http_pending.get(id) == Some(generation) &&
        self.parked.contains(id) {
        self.http_pending.remove(id)
        self.sessions[id].complete_http(result)
        try {
          self.rerun(id, event.now, out)
          self.drain(event.now, out)
        } catch {
          e => out.push(Log("HTTP completion: \{e}"))
        }
      }
    Resume => ()
  }
  out
}

///|
fn Engine::send(
  self : Engine,
  conn : Conn,
  payload : Bytes,
  out : Array[Output],
  complete? : Bool = true,
) -> Unit {
  // tokens of a RESETCONNECTION go first (once, even if the request parked)
  let payload = match self.reset_prefix.get(conn.id) {
    Some(prefix) => {
      self.reset_prefix.remove(conn.id)
      prefix + payload
    }
    None => payload
  }
  out.push(
    Send(
      conn.id,
      @tds.frame(
        TabularResult,
        payload,
        packet_size=conn.packet_size,
        end_of_message=complete,
      ),
    ),
  )
}

///|
fn Engine::on_message(
  self : Engine,
  conn : Conn,
  msg : @tds.Message,
  now : Int64,
  out : Array[Output],
) -> Unit raise {
  match (conn.phase, msg.ty) {
    (AwaitPrelogin, Prelogin) => {
      let p = @tds.decode_prelogin(msg.payload)
      match @tds.negotiate_encryption(p.encryption, tls=self.config.tls) {
        None => {
          out.push(
            Log(
              "connection \{conn.id}: client requires encryption; TLS is not available",
            ),
          )
          out.push(Close(conn.id))
          self.conns.remove(conn.id)
        }
        Some(enc) => {
          let (major, minor, build) = self.config.version
          let payload = @tds.encode_prelogin_response(
            version=(major, minor, build, 0),
            encryption=enc,
          )
          conn.encryption = enc
          if enc == @tds.ENCRYPT_OFF || enc == @tds.ENCRYPT_ON {
            out.push(StartTls(conn.id))
          }
          out.push(Send(conn.id, @tds.frame(TabularResult, payload)))
          conn.phase = AwaitLogin
        }
      }
    }
    (AwaitLogin, Login7) => {
      if conn.encryption == @tds.ENCRYPT_OFF {
        out.push(EndTls(conn.id))
      }
      let login = @tds.decode_login7(msg.payload)
      if login.packet_size >= 512 && login.packet_size <= 32767 {
        conn.packet_size = login.packet_size
      }
      let db = if login.database == "" {
        self.config.default_database
      } else {
        login.database
      }
      if !self.server.has_database(db) {
        if self.config.auto_create_databases {
          self.server.create_database(db)
        } else {
          // Captured (msduck login-database-error): 4060 + 18456 +
          // DONE_ERROR, then the server closes the connection.
          let w = @tds.Writer::new()
          @tds.write_message(
            w,
            is_error=true,
            number=4060,
            state=1,
            class=11,
            message="Cannot open database \"\{db}\" requested by the login. The login failed.",
            server=self.config.server_name,
            procedure="",
            line=1,
          )
          @tds.write_message(
            w,
            is_error=true,
            number=18456,
            state=1,
            class=14,
            message="Login failed for user '\{login.user_name.to_lower()}'.",
            server=self.config.server_name,
            procedure="",
            line=1,
          )
          @tds.write_done(w, Done, @tds.DONE_ERROR, 0, 0)
          self.send(conn, w.to_bytes(), out)
          out.push(Close(conn.id))
          self.conns.remove(conn.id)
          return
        }
      }
      conn.phase = LoggedIn
      self.sessions[conn.id] = @session.Session::new(
        self.server,
        spid=50 + conn.id,
        database=self.server.database_name(db),
        seed=self.seed + conn.id.to_int64(),
        server_name=self.config.server_name,
        build=self.config.version,
      )
      self.sessions[conn.id].set_work_limit(self.config.max_request_work)
      self.sessions[conn.id].set_login(
        login.user_name,
        login.host_name,
        login.app_name,
        library=login.library_name,
        encrypted=conn.encryption == @tds.ENCRYPT_ON,
        now~,
      )
      self.send(conn, self.login_response(db, conn.packet_size), out)
    }
    (LoggedIn, SqlBatch | Rpc | TransactionManager) if (
        msg.status & @tds.STATUS_RESET_CONNECTION
      ) !=
      0 &&
      !self.reset_prefix.contains(conn.id) &&
      !self.parked.contains(conn.id) => {
      let items = self.sessions[conn.id].reset()
      self.reset_prefix[conn.id] = @reply.render(
        Batch,
        items,
        self.config.server_name,
      )
      self.on_message(
        conn,
        { ..msg, status: msg.status & (0xFF ^ @tds.STATUS_RESET_CONNECTION), },
        now,
        out,
      )
    }
    (LoggedIn, SqlBatch) => {
      if (msg.status & @tds.STATUS_IGNORE) != 0 {
        self.send(conn, done_only(), out)
        return
      }
      let batch = @tds.decode_sql_batch(msg.payload)
      self.run_batch(conn, batch.text, now, out)
    }
    (LoggedIn, Rpc) => {
      if (msg.status & @tds.STATUS_IGNORE) != 0 {
        self.send(conn, done_only(), out)
        return
      }
      let req = @tds.decode_rpc(msg.payload) catch {
        @tds.RpcStream(number, state, message) => {
          let items = self.sessions[conn.id].stream_error(
            number, state, message, now,
          )
          self.send(
            conn,
            @reply.render(Batch, items, self.config.server_name),
            out,
          )
          return
        }
        e => raise e
      }
      self.run_rpc(conn, req.calls, b"", now, out)
    }
    (LoggedIn, BulkLoad) => {
      let (columns, rows) = @tds.decode_bulk_load(msg.payload)
      let items = self.sessions[conn.id].run_bulk(columns, rows, now)
      self.send(conn, @reply.render(Batch, items, self.config.server_name), out)
    }
    (LoggedIn, TransactionManager) => {
      if (msg.status & @tds.STATUS_IGNORE) != 0 {
        self.send(conn, done_only(), out)
        return
      }
      let (_, req) = @tds.decode_tm(msg.payload)
      let items = self.sessions[conn.id].run_tm(req, now)
      self.send(conn, @reply.render(Batch, items, self.config.server_name), out)
    }
    (LoggedIn, Attention) => {
      // A parked request (lock wait, WAITFOR) is re-run in cancel mode: it
      // stops at its wait and sends its own response (session/attention.mbt).
      // Otherwise execution already finished and its response went out.
      // Either way DONE_ATTN follows as a separate message, as SQL Server
      // sends it (captured; tedious reads two messages after a cancel).
      if self.parked.contains(conn.id) {
        self.cancel_http(conn.id, out)
        out.push(CancelTimer(conn.id))
        self.sessions[conn.id].attention()
        self.rerun(conn.id, now, out)
        if self.parked.contains(conn.id) {
          // the re-run parked again (not expected): abandon it
          self.parked.remove(conn.id)
          self.sessions[conn.id].cancel_wait()
          let w = @tds.Writer::new()
          @tds.write_done(w, Done, @tds.DONE_ERROR, 253, 0)
          self.send(conn, w.to_bytes(), out)
        }
      }
      let w = @tds.Writer::new()
      @tds.write_done(w, Done, @tds.DONE_ATTN, 253, 0)
      self.send(conn, w.to_bytes(), out)
    }
    (phase, ty) =>
      raise @tds.Malformed(
        "unexpected \{@debug.to_string(ty)} in phase \{@debug.to_string(phase)}",
      )
  }
}

///|
fn done_only() -> Bytes {
  let w = @tds.Writer::new()
  @tds.write_done(w, Done, 0, 0, 0)
  w.to_bytes()
}

///|
/// Login response, in the order msduck/mssqlite verified with tedious:
/// ENVCHANGE database, INFO 5701, ENVCHANGE collation, ENVCHANGE language,
/// INFO 5703, LOGINACK, ENVCHANGE packet size, DONE.
fn Engine::login_response(
  self : Engine,
  database : String,
  packet_size : Int,
) -> Bytes {
  let w = @tds.Writer::new(size_hint=512)
  let server = self.config.server_name
  @tds.write_envchange(w, Database(database, "master"))
  @tds.write_message(
    w,
    is_error=false,
    number=5701,
    state=2,
    class=0,
    message="Changed database context to '\{database}'.",
    server~,
    procedure="",
    line=1,
  )
  @tds.write_envchange(w, Collation(@tds.default_collation, b""))
  @tds.write_envchange(w, Language("us_english", ""))
  @tds.write_message(
    w,
    is_error=false,
    number=5703,
    state=1,
    class=0,
    message="Changed language setting to us_english.",
    server~,
    procedure="",
    line=1,
  )
  let (major, minor, build) = self.config.version
  @tds.write_loginack(
    w,
    tds_version=@tds.TDS_74,
    prog_name="Microsoft SQL Server",
    version=(major, minor, build >> 8, build & 0xFF),
  )
  @tds.write_envchange(w, PacketSize(packet_size, packet_size))
  @tds.write_done(w, Done, 0, 0, 0)
  w.to_bytes()
}

///|
/// Seed for all engine randomness (NEWID, RAND); fixed per run for replay.
pub fn Engine::seed(self : Engine) -> Int64 {
  self.seed
}

///|
fn Engine::run_batch(
  self : Engine,
  conn : Conn,
  text : String,
  now : Int64,
  out : Array[Output],
) -> Unit raise {
  let session = self.sessions[conn.id]
  let items = session.run_batch(text, now)
  if session.is_parked() {
    self.parked[conn.id] = ParkedBatch(text)
    self.arm_timeout(conn.id, out)
    return
  }
  let disconnected = items.any(i => i is Disconnect)
  self.send(
    conn,
    @reply.render(Batch, items, self.config.server_name),
    out,
    complete=!disconnected || items.any(i => i is FatalDone(_)),
  )
  if disconnected {
    out.push(Close(conn.id))
  }
}

///|
fn Engine::run_rpc(
  self : Engine,
  conn : Conn,
  calls : Array[@tds.RpcCall],
  done_bytes : Bytes,
  now : Int64,
  out : Array[Output],
) -> Unit raise {
  let session = self.sessions[conn.id]
  let w = @tds.Writer::new()
  w.bytes(done_bytes)
  for i, call in calls {
    let items = session.run_rpc(call, now)
    if session.is_parked() {
      self.parked[conn.id] = ParkedRpc(calls[i:].to_owned(), w.to_bytes())
      self.arm_timeout(conn.id, out)
      return
    }
    if session.was_cancelled() {
      // ATTENTION ends the request: later calls do not run
      w.bytes(
        @reply.render(Rpc, items, self.config.server_name, cancelled=true),
      )
      break
    }
    w.bytes(@reply.render(Rpc, items, self.config.server_name))
    if items.any(it => it is Disconnect) {
      self.send(
        conn,
        w.to_bytes(),
        out,
        complete=items.any(i => i is FatalDone(_)),
      )
      out.push(Close(conn.id))
      return
    }
  }
  self.send(conn, w.to_bytes(), out)
}

///|
/// Re-runs parked requests of sessions woken by lock releases, and of
/// parked deadlock victims (which fail with 1205 at the same statement),
/// until nothing changes. Their responses go out in this same handle call.
fn Engine::drain(self : Engine, now : Int64, out : Array[Output]) -> Unit raise {
  let mut rounds = 0
  while rounds < 10000 {
    rounds += 1
    let victims = self.server.take_victims()
    let woken = self.server.take_woken()
    if victims.is_empty() && woken.is_empty() {
      break
    }
    for v in victims {
      let id = v - 50
      if self.parked.contains(id) {
        self.sessions[id].make_victim()
      }
    }
    for spid in victims + woken {
      let id = spid - 50
      match (self.parked.get(id), self.conns.get(id)) {
        (Some(_), Some(_)) => {
          out.push(CancelTimer(id))
          self.rerun(id, now, out)
        }
        _ => ()
      }
    }
  }
}

///|
/// SET LOCK_TIMEOUT > 0: the host fires TimerFired(connection id).
fn Engine::arm_timeout(self : Engine, id : Int, out : Array[Output]) -> Unit {
  if self.sessions[id].pending_http() is Some(request) {
    if !self.http_pending.contains(id) {
      self.http_generation += 1
      self.http_pending[id] = self.http_generation
      out.push(FetchHttp(id, self.http_generation, request))
    }
    return
  }
  match self.sessions[id].wait_timeout() {
    Some(ms) => out.push(SetTimer(id, ms))
    None => ()
  }
}

///|
fn Engine::cancel_http(self : Engine, id : Int, out : Array[Output]) -> Unit {
  if self.http_pending.get(id) is Some(generation) {
    self.http_pending.remove(id)
    out.push(CancelHttp(id, generation))
  }
}

///|
/// Re-runs a connection's parked request from the start.
fn Engine::rerun(
  self : Engine,
  id : Int,
  now : Int64,
  out : Array[Output],
) -> Unit raise {
  match (self.parked.get(id), self.conns.get(id)) {
    (Some(p), Some(conn)) => {
      self.parked.remove(id)
      match p {
        ParkedBatch(text) => self.run_batch(conn, text, now, out)
        ParkedRpc(calls, done) => self.run_rpc(conn, calls, done, now, out)
      }
    }
    _ => ()
  }
}

///|
/// The bitsql release (moon.mod version), for `host --version`.
pub fn version() -> String {
  @exec.bitsql_version
}
