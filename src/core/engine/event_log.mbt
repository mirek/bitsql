///|
/// Event log format, so a CI run can be replayed byte for byte:
/// header = "BSQLEV1\n" + seed (i64 LE); then one record per event:
/// tag u8 (0 Connected, 1 Received, 2 Closed, 3 TimerFired, 4 Resume,
/// 5 HttpCompleted),
/// now i64 LE, id i32 LE, and for Received a u32 LE length plus the bytes.
/// HttpCompleted adds generation/status i32 LE (-1 = transport failure),
/// then a u32 LE UTF-8 byte length and response body/failure text.
let event_log_magic : Bytes = b"BSQLEV1\n"

///|
pub fn encode_event_log_header(seed : Int64) -> Bytes {
  let w = @tds.Writer::new()
  w.bytes(event_log_magic)
  w.i64le(seed)
  w.to_bytes()
}

///|
pub fn encode_event(e : Event) -> Bytes {
  let w = @tds.Writer::new()
  let (tag, id) = match e.input {
    Connected(id) => (0, id)
    Received(id, _) => (1, id)
    Closed(id) => (2, id)
    TimerFired(id) => (3, id)
    Resume => (4, 0)
    HttpCompleted(id, _, _) => (5, id)
    Measured(id, _) => (6, id)
    MonitoringStarted(cpus, _) => (7, cpus)
    CpuUsed(id, _) => (8, id)
    SystemFacts(_) => (9, 0)
  }
  w.u8(tag)
  w.i64le(e.now)
  w.i32le(id)
  if e.input is SystemFacts(facts) {
    w.u32le(facts.length().to_int64())
    for (key, value) in facts {
      let bytes = @utf8.encode(key)
      w.u32le(bytes.length().to_int64())
      w.bytes(bytes)
      w.i64le(value)
    }
  }
  if e.input is (MonitoringStarted(_, cpu) | CpuUsed(_, cpu)) {
    w.i64le(cpu)
  }
  if e.input is Measured(_, cpu) {
    w.i64le(cpu)
  }
  if e.input is Received(_, b) {
    w.u32le(b.length().to_int64())
    w.bytes(b)
  }
  if e.input is HttpCompleted(_, generation, result) {
    w.i32le(generation)
    let (status, text) = match result {
      HttpResponse(status, body) => (status, body)
      HttpFailure(reason) => (-1, reason)
    }
    w.i32le(status)
    let bytes = @utf8.encode(text)
    w.u32le(bytes.length().to_int64())
    w.bytes(bytes)
  }
  w.to_bytes()
}

///|
/// Decodes a whole log: (seed, events). A truncated final record (host
/// killed mid-write) is dropped rather than failing the replay.
pub fn decode_event_log(
  data : BytesView,
) -> (Int64, Array[Event]) raise @tds.TdsError {
  let r = @tds.Reader::new(data)
  if r.bytes(event_log_magic.length()) != event_log_magic {
    raise @tds.Malformed("not a bitsql event log")
  }
  let seed = r.u64le().reinterpret_as_int64()
  let events = []
  while !r.at_end() {
    let record : Event? = try {
      let tag = r.u8()
      let now = r.u64le().reinterpret_as_int64()
      let id = r.i32le()
      let input : Input = match tag {
        0 => Connected(id)
        1 => {
          let n = r.u32le().to_int()
          Received(id, r.bytes(n))
        }
        2 => Closed(id)
        3 => TimerFired(id)
        4 => Resume
        6 => Measured(id, r.u64le().reinterpret_as_int64())
        7 => MonitoringStarted(id, r.u64le().reinterpret_as_int64())
        8 => CpuUsed(id, r.u64le().reinterpret_as_int64())
        9 => {
          let n = r.u32le().to_int()
          if n < 0 || n > 128 {
            raise @tds.Malformed("too many system facts")
          }
          let facts = []
          for _ in 0..<n {
            let key = @utf8.decode(r.bytes(r.u32le().to_int())) catch {
              _ => raise @tds.Malformed("invalid system fact name")
            }
            facts.push((key, r.u64le().reinterpret_as_int64()))
          }
          SystemFacts(facts)
        }
        5 => {
          let generation = r.i32le()
          let status = r.i32le()
          let bytes = r.bytes(r.u32le().to_int())
          let body = @utf8.decode(bytes) catch {
            _ => raise @tds.Malformed("invalid UTF-8 HTTP event")
          }
          HttpCompleted(
            id,
            generation,
            if status == -1 {
              HttpFailure(body)
            } else {
              HttpResponse(status, body)
            },
          )
        }
        t => raise @tds.Malformed("bad event tag \{t}")
      }
      Some({ input, now, })
    } catch {
      @tds.Malformed(m) if m.has_prefix("truncated") => None
      e => raise e
    }
    match record {
      Some(ev) => events.push(ev)
      None => break
    }
  }
  (seed, events)
}
