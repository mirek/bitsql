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
}

///|
pub fn Engine::new(config : Config, seed : Int64) -> Engine {
  let server = @session.Server::new()
  for name in config.databases {
    server.create_database(name)
  }
  { config, seed, conns: Map([]), server, sessions: Map([]), }
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
      self.conns.remove(id)
      self.sessions.remove(id)
    }
    Received(id, bytes) =>
      match self.conns.get(id) {
        None => out.push(Log("data for unknown connection \{id}"))
        Some(conn) =>
          try {
            for msg in conn.reassembler.push(bytes) {
              self.on_message(conn, msg, event.now, out)
            }
          } catch {
            e => {
              out.push(Log("connection \{id}: protocol error: \{e}"))
              out.push(Close(id))
              self.conns.remove(id)
            }
          }
      }
    TimerFired(_) | Resume => ()
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
  ignore(self)
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
      )
      self.send(conn, self.login_response(db, conn.packet_size), out)
    }
    (LoggedIn, SqlBatch) => {
      if (msg.status & @tds.STATUS_IGNORE) != 0 {
        self.send(conn, done_only(), out)
        return
      }
      let batch = @tds.decode_sql_batch(msg.payload)
      let items = self.sessions[conn.id].run_batch(batch.text, now)
      self.send(conn, @reply.render(Batch, items, self.config.server_name), out)
    }
    (LoggedIn, Rpc) => {
      if (msg.status & @tds.STATUS_IGNORE) != 0 {
        self.send(conn, done_only(), out)
        return
      }
      let req = @tds.decode_rpc(msg.payload)
      let w = @tds.Writer::new()
      for call in req.calls {
        let items = self.sessions[conn.id].run_rpc(call, now)
        w.bytes(@reply.render(Rpc, items, self.config.server_name))
      }
      self.send(conn, w.to_bytes(), out)
    }
    (LoggedIn, Attention) => {
      // Execution is synchronous today, so the request already finished:
      // acknowledge as a separate message (tedious skill: never fold it).
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
