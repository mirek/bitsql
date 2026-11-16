///|
/// The write side of one connection. `send` never suspends: the engine
/// emits replies while it holds the engine lock, and awaiting a socket there
/// let one client that stopped reading (without closing) stall every
/// session until its write failed. With nothing backlogged, `send` hands the
/// bytes to the kernel without blocking; whatever the kernel does not take
/// waits in `backlog` for the connection's writer task (`Sink::run`), which
/// keeps the stream in order. A stalled client's backlog grows in memory.
priv struct Sink {
  tcp : @socket.Tcp
  /// `None` closes the socket once everything before it is written.
  backlog : @aqueue.Queue[Bytes?]
  /// Items in `backlog` not yet fully written.
  mut pending : Int
  mut shut : Bool
}

///|
fn Sink::new(tcp : @socket.Tcp) -> Sink {
  { tcp, backlog: @aqueue.Queue(kind=Unbounded), pending: 0, shut: false, }
}

///|
#borrow(buf)
extern "C" fn try_send(fd : Int, buf : Bytes, offset : Int, len : Int) -> Int = "bitsql_try_send"

///|
fn Sink::send(self : Sink, bytes : BytesView) -> Unit {
  guard !self.shut && bytes.length() > 0 else { return }
  let mut rest = bytes
  if self.pending == 0 {
    // -1 (reset, broken pipe): the writer's write raises and drops the
    // connection, the same path as a failure while backlogged
    let n = try_send(
      self.tcp.fd(),
      bytes.data(),
      bytes.start_offset(),
      bytes.length(),
    )
    guard n < bytes.length() else { return }
    rest = bytes[@cmp.maximum(n, 0):]
  }
  // always a copy: `to_owned` returns the underlying buffer itself when the
  // view spans all of it, and TLS hands over its reused write buffer
  let copy = FixedArray::make(rest.length(), (0 : Byte))
  copy.blit_from_bytesview(0, rest)
  self.pending += 1
  ignore(
    self.backlog.try_put(Some(copy.unsafe_reinterpret_as_bytes())) catch {
      _ => false
    },
  )
}

///|
/// No more output: the socket closes after the backlog is written.
fn Sink::close(self : Sink) -> Unit {
  guard !self.shut else { return }
  self.shut = true
  ignore(self.backlog.try_put(None) catch { _ => false })
}

///|
/// The writer task: drains the backlog, then closes the socket (also when a
/// write fails, which ends the connection).
async fn Sink::run(self : Sink) -> Unit {
  defer {
    self.shut = true
    self.tcp.close()
    self.backlog.close()
  }
  while self.backlog.get() is Some(bytes) {
    self.tcp.write(bytes)
    self.pending -= 1
  }
}
