///|
/// The engine as a WebAssembly GC module for the npm package's TypeScript
/// host (npm/bitsql), which owns every socket, timer and clock. All data
/// crosses in one buffer at the start of the exported linear memory: the
/// host writes an input there and calls an export, which writes its result
/// over it and returns the length.
///
/// - `create(n)`: config (below) → engine
/// - `handle(n)`: one input event, in the event-log record format
///   (`@engine.decode_event`) → the encoded outputs (`encode_output`)
/// - `version()` → UTF-8 release name
/// - `tls_identity()` → built-in PEM key and certificate, each u32 length +
///   UTF-8 (the native host's default, `@tlscert`)
/// - `reserve(n)`: grows the buffer to at least n bytes
let engine : Ref[@engine.Engine?] = Ref(None)

///|
extern "wasm" fn load8(addr : Int) -> Int =
  #|(func (param i32) (result i32) (i32.load8_u (local.get 0)))

///|
extern "wasm" fn store8(addr : Int, value : Int) =
  #|(func (param i32) (param i32) (i32.store8 (local.get 0) (local.get 1)))

///|
extern "wasm" fn memory_pages() -> Int =
  #|(func (result i32) (memory.size))

///|
extern "wasm" fn memory_grow(pages : Int) -> Int =
  #|(func (param i32) (result i32) (memory.grow (local.get 0)))

///|
pub fn reserve(n : Int) -> Unit {
  let pages = (n + 65535) / 65536
  let have = memory_pages()
  if pages > have && memory_grow(pages - have) < 0 {
    abort("bitsql: out of linear memory")
  }
}

///|
fn input(n : Int) -> Bytes {
  Bytes::makei(n, i => load8(i).to_byte())
}

///|
fn output(b : Bytes) -> Int {
  reserve(b.length())
  for i, byte in b {
    store8(i, byte.to_int())
  }
  b.length()
}

///|
/// Config: seed i64, max_request_work i64 (negative: the default), flags u8 (1 auto-create
/// databases, 2 TLS), u32 database count, then each name as u32 length +
/// UTF-8.
pub fn create(n : Int) -> Unit {
  let r = @tds.Reader::new(input(n))
  let config = (fn() raise @tds.TdsError {
    let seed = r.u64le().reinterpret_as_int64()
    let max_request_work = r.u64le().reinterpret_as_int64()
    let flags = r.u8()
    let databases = []
    for _ in 0..<r.u32le().to_int() {
      databases.push(@utf8.decode(r.bytes(r.u32le().to_int()))) catch {
        _ => raise @tds.Malformed("database name is not UTF-8")
      }
    }
    let config : @engine.Config = {
      ..@engine.Config::default(),
      databases,
      auto_create_databases: (flags & 1) != 0,
      max_request_work: if max_request_work < 0L {
        @engine.default_max_request_work
      } else {
        max_request_work
      },
      tls: (flags & 2) != 0,
    }
    (config, seed)
  })() catch {
    _ => abort("bitsql: bad config")
  }
  engine.val = Some(@engine.Engine::new(config.0, config.1))
}

///|
pub fn handle(n : Int) -> Int {
  guard engine.val is Some(e) else { abort("bitsql: create() first") }
  let event = @engine.decode_event(@tds.Reader::new(input(n))) catch {
    _ => abort("bitsql: bad event")
  }
  let w = @tds.Writer::new()
  for o in e.handle(event) {
    encode_output(w, o)
  }
  output(w.to_bytes())
}

///|
pub fn version() -> Int {
  output(@utf8.encode(@engine.version()))
}

///|
pub fn tls_identity() -> Int {
  let w = @tds.Writer::new()
  string(w, @tlscert.builtin_private_key)
  string(w, @tlscert.builtin_certificate)
  output(w.to_bytes())
}

///|
fn string(w : @tds.Writer, s : String) -> Unit {
  let b = @utf8.encode(s)
  w.u32le(b.length().to_int64())
  w.bytes(b)
}

///|
/// Output: tag u8, then fields (ids and ints i32 LE, byte strings and
/// UTF-8 strings as u32 LE length + bytes):
/// 0 Send id bytes · 1 Close id · 2 SetTimer id ms · 3 CancelTimer id ·
/// 4 Yield · 5 Log text · 6 StartTls id · 7 EndTls id · 8 Sample id ·
/// 9 FetchHttp id generation url body headers(u32 n, key value...)
/// retry_count retry_statuses(u32 n, i32...) · 10 CancelHttp id generation
fn encode_output(w : @tds.Writer, o : @engine.Output) -> Unit {
  match o {
    Send(id, b) => {
      w.u8(0)
      w.i32le(id)
      w.u32le(b.length().to_int64())
      w.bytes(b)
    }
    Close(id) => {
      w.u8(1)
      w.i32le(id)
    }
    SetTimer(id, ms) => {
      w.u8(2)
      w.i32le(id)
      w.i32le(ms)
    }
    CancelTimer(id) => {
      w.u8(3)
      w.i32le(id)
    }
    Yield => w.u8(4)
    Log(text) => {
      w.u8(5)
      string(w, text)
    }
    StartTls(id) => {
      w.u8(6)
      w.i32le(id)
    }
    EndTls(id) => {
      w.u8(7)
      w.i32le(id)
    }
    Sample(id) => {
      w.u8(8)
      w.i32le(id)
    }
    FetchHttp(id, generation, request) => {
      w.u8(9)
      w.i32le(id)
      w.i32le(generation)
      string(w, request.url)
      string(w, request.body)
      w.u32le(request.headers.length().to_int64())
      for (key, value) in request.headers {
        string(w, key)
        string(w, value)
      }
      w.i32le(request.retry_count)
      w.u32le(request.retry_statuses.length().to_int64())
      for status in request.retry_statuses {
        w.i32le(status)
      }
    }
    CancelHttp(id, generation) => {
      w.u8(10)
      w.i32le(id)
      w.i32le(generation)
    }
  }
}
