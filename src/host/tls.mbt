///|
/// TLS for TDS 7.x (MS-TDS 2.2.6.5 / 3.3.4): after a PRELOGIN exchange that
/// negotiated encryption, the client sends its TLS handshake records inside
/// PRELOGIN packets and expects one PRELOGIN message back per flight. Once
/// the handshake completes, TLS records travel bare on the socket. With
/// login-only encryption (ENCRYPT_OFF) TLS ends right after LOGIN7.
///
/// The engine never sees ciphertext: it asks for TLS with `StartTls` and
/// `EndTls`, and the host feeds it the plaintext.

///|
/// Server key and certificate files, written once at startup.
priv struct TlsFiles {
  key : String
  cert : String
}

///|
/// OpenSSL config capping the protocol at TLS 1.2. SQL Server does TLS 1.3
/// only with TDS 8 (strict). Under TDS 7 wrapping it would also break
/// clients: TLS 1.3 session tickets follow the client's Finished, after the
/// client has already stopped unwrapping PRELOGIN packets. tedious caps at
/// 1.2 itself; tiberius (Prisma's schema engine) does not.
let openssl_conf : String =
  #|openssl_conf = bitsql_init
  #|[bitsql_init]
  #|ssl_conf = bitsql_ssl
  #|[bitsql_ssl]
  #|system_default = bitsql_tls
  #|[bitsql_tls]
  #|MaxProtocol = TLSv1.2
  #|

///|
/// Prepares TLS: writes the built-in certificate (unless `--tls-cert` and
/// `--tls-key` name files), points OpenSSL at the 1.2 cap, then runs a
/// loopback handshake so a missing libssl or a bad key disables TLS at
/// startup with a message instead of failing every encrypted login.
async fn setup_tls(args : Array[String]) -> TlsFiles? {
  if args.contains("--no-tls") {
    return None
  }
  try {
    let dir = @fs.tmpdir(prefix="bitsql-tls")
    let conf = dir + "/openssl.cnf"
    @fs.write_file(conf, openssl_conf, create_mode=CreateOrTruncate)
    @env.set_env_var("OPENSSL_CONF", conf)
    let files = match (flag(args, "--tls-cert"), flag(args, "--tls-key")) {
      (Some(cert), Some(key)) => { key, cert, }
      (None, None) => {
        let files = { key: dir + "/key.pem", cert: dir + "/cert.pem", }
        @fs.write_file(
          files.key,
          builtin_private_key,
          create_mode=CreateOrTruncate,
          permission=0o600,
        )
        @fs.write_file(
          files.cert,
          builtin_certificate,
          create_mode=CreateOrTruncate,
        )
        files
      }
      _ => fail("--tls-cert and --tls-key go together")
    }
    @async.with_timeout(5000, () => self_test(files))
    Some(files)
  } catch {
    e => {
      @stdio.stderr.write(
        "TLS disabled (encrypting clients will be refused): \{e}\n",
      )
      None
    }
  }
}

///|
/// One handshake and one record each way over in-memory pipes.
#warnings("-alert_internal")
async fn self_test(files : TlsFiles) -> Unit {
  let (server_in, client_out) = @io.pipe()
  let (client_in, server_out) = @io.pipe()
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let tls = @tls.Tls::server_from_pair(
        server_in,
        server_out,
        private_key_file=files.key,
        private_key_type=PEM,
        certificate_file=files.cert,
        certificate_type=PEM,
      )
      defer tls.close()
      tls.write(tls.read_exactly(4))
    })
    let tls = @tls.Tls::client_from_pair(
      client_in,
      client_out,
      trust=NoVerification,
    )
    defer tls.close()
    tls.write("ping")
    guard tls.read_exactly(4) == b"ping" else { fail("TLS self-test echo") }
  })
}

///|
/// What a connection's socket currently carries.
priv enum Mode {
  Plain
  /// `StartTls` seen; the client's next bytes start the handshake.
  Pending
  /// Handshake running, or TLS up (`tls` set): socket bytes go to `wire`.
  Tls(TlsWire)
}

///|
priv struct Conn {
  tcp : @socket.Tcp
  mut mode : Mode
}

///|
#warnings("-alert_internal")
priv struct TlsWire {
  /// The socket side of one TLS session, handed to OpenSSL as its reader and
  /// writer. The connection's read loop pushes raw socket bytes into `chunks`.
  /// While `wrapped`, incoming bytes are PRELOGIN packets whose payloads are
  /// TLS records, and outgoing records are batched per flight into one
  /// PRELOGIN message (sent when OpenSSL next waits for input, or when the
  /// handshake completes).
  tcp : @socket.Tcp
  chunks : @aqueue.Queue[Bytes]
  reader_buf : @io.ReaderBuffer
  unwrap : @tds.Reassembler
  mut wrapped : Bool
  mut input : Bytes
  mut input_pos : Int
  flight : @buffer.Buffer
  mut tls : @tls.Tls?
}

///|
#warnings("-alert_internal")
fn TlsWire::new(tcp : @socket.Tcp) -> TlsWire {
  {
    tcp,
    chunks: @aqueue.Queue(kind=Unbounded),
    reader_buf: @io.ReaderBuffer::new(),
    unwrap: @tds.Reassembler::new(),
    wrapped: true,
    input: b"",
    input_pos: 0,
    flight: @buffer.Buffer(),
    tls: None,
  }
}

///|
async fn TlsWire::send_flight(self : TlsWire) -> Unit {
  guard self.flight.length() > 0 else { return }
  let records = self.flight.to_bytes()
  self.flight.reset()
  // captured: SQL Server's handshake replies are PRELOGIN, EOM, packet id 0
  self.tcp.write(@tds.frame(Prelogin, records, first_packet_id=0))
}

///|
#warnings("-alert_internal")
impl @io.Reader for TlsWire with fn _get_internal_buffer(self) {
  self.reader_buf
}

///|
#warnings("-alert_internal")
impl @io.Reader for TlsWire with fn _direct_read(self, buf, offset~, max_len~) {
  if self.wrapped {
    self.send_flight()
  }
  while self.input_pos >= self.input.length() {
    let chunk = self.chunks.get() catch { _ => return 0 }
    if self.wrapped {
      let payload = @buffer.Buffer()
      for msg in self.unwrap.push(chunk) {
        guard msg.ty is Prelogin else {
          fail("TLS handshake: expected a PRELOGIN packet")
        }
        payload.write_bytes(msg.payload)
      }
      self.input = payload.to_bytes()
    } else {
      self.input = chunk
    }
    self.input_pos = 0
  }
  let n = @cmp.minimum(max_len, self.input.length() - self.input_pos)
  buf.blit_from_bytes(offset, self.input, self.input_pos, n)
  self.input_pos += n
  n
}

///|
impl @io.Writer for TlsWire with fn write_once(self, buf, offset~, len~) {
  if self.wrapped {
    self.flight.write_bytesview(buf[offset:offset + len])
  } else {
    self.tcp.write(buf[offset:offset + len])
  }
  len
}

///|
#warnings("-alert_internal")
/// Runs one TLS session: handshake, then decrypted bytes go to the engine
/// until EOF, `EndTls` (which closes `chunks`), or an error (which drops
/// the connection, as SQL Server does).
async fn run_tls(
  wire : TlsWire,
  files : TlsFiles,
  deliver : async (Bytes) -> Unit,
) -> Unit {
  let tls = @tls.Tls::server_from_pair(
    wire,
    wire,
    private_key_file=files.key,
    private_key_type=PEM,
    certificate_file=files.cert,
    certificate_type=PEM,
  )
  defer tls.close()
  wire.send_flight()
  wire.wrapped = false
  wire.tls = Some(tls)
  while tls.read_some() is Some(bytes) {
    deliver(bytes)
  }
}
