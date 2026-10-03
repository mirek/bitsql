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
      }
    Closed(id) => {
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
      @tds.frame(TabularResult, payload, packet_size=conn.packet_size),
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
      match @tds.negotiate_encryption_without_tls(p.encryption) {
        None => {
          out.push(
            Log(
              "connection \{conn.id}: client requires encryption; TLS is not supported (use encrypt: false)",
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
          out.push(Send(conn.id, @tds.frame(TabularResult, payload)))
          conn.phase = AwaitLogin
        }
      }
    }
    (AwaitLogin, Login7) => {
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
      let req = @tds.decode_rpc(msg.payload)
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
      // A parked request is abandoned; otherwise execution already
      // finished. Acknowledge as a separate message (tedious skill).
      if self.parked.contains(conn.id) {
        self.parked.remove(conn.id)
        self.sessions[conn.id].cancel_wait()
        out.push(CancelTimer(conn.id))
      }
      let w = @tds.Writer::new()
      @tds.write_done(w, Done, @tds.DONE_ATTN, 0, 0)
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
  self.send(conn, @reply.render(Batch, items, self.config.server_name), out)
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
    w.bytes(@reply.render(Rpc, items, self.config.server_name))
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
  match self.sessions[id].wait_timeout() {
    Some(ms) => out.push(SetTimer(id, ms))
    None => ()
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
