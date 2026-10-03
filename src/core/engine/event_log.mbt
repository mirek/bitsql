///|
/// Event log format, so a CI run can be replayed byte for byte:
/// header = "BSQLEV1\n" + seed (i64 LE); then one record per event:
/// tag u8 (0 Connected, 1 Received, 2 Closed, 3 TimerFired, 4 Resume),
/// now i64 LE, id i32 LE, and for Received a u32 LE length plus the bytes.
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
  }
  w.u8(tag)
  w.i64le(e.now)
  w.i32le(id)
  if e.input is Received(_, b) {
    w.u32le(b.length().to_int64())
    w.bytes(b)
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
