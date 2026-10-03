///|
fn login7_payload(user : String, password : String, database : String) -> Bytes {
  let w = @tds.Writer::new()
  w.u32le(0)
  w.u32le(0x74000004)
  w.u32le(8192)
  w.u32le(7)
  w.u32le(1)
  w.u32le(0)
  w.u8(0xE0)
  w.u8(0x03)
  w.u8(0)
  w.u8(0)
  w.i32le(0)
  w.u32le(0x0409)
  let user_off = 94
  let pw_off = user_off + user.length() * 2
  let db_off = pw_off + password.length() * 2
  let pairs = [
    (user_off, 0),
    (user_off, user.length()),
    (pw_off, password.length()),
    (db_off, 0),
    (db_off, 0),
    (db_off, 0),
    (db_off, 0),
    (db_off, 0),
    (db_off, database.length()),
  ]
  for p in pairs {
    w.u16le(p.0)
    w.u16le(p.1)
  }
  w.bytes(Bytes::make(22, b'\x00'))
  w.ucs2(user)
  w.bytes(@tds.scramble_password(password))
  w.ucs2(database)
  let raw = w.to_bytes().to_array()
  raw[0] = raw.length().to_byte()
  raw[1] = (raw.length() >> 8).to_byte()
  Bytes::from_array(raw)
}

///|
fn sent(outs : Array[@engine.Output]) -> Array[@tds.Message] raise {
  let r = @tds.Reassembler::new()
  let msgs = []
  for o in outs {
    if o is Send(_, b) {
      msgs.append(r.push(b))
    }
  }
  msgs
}

///|
fn ev(input : @engine.Input) -> @engine.Event {
  { input, now: @engine.UNIX_EPOCH_TICKS, }
}

///|
test "prelogin, login and batch flow" {
  let e = @engine.Engine::new(@engine.Config::default(), 42)
  assert_eq(e.handle(ev(Connected(1))), [])
  // tedious with encrypt:false sends ENCRYPT_NOT_SUP
  let pre = @tds.from_hex(
    "00 00 10 00 06 01 00 16 00 01 04 00 17 00 01 FF 0c 00 00 00 00 00 02 00",
  )
  let r1 = sent(e.handle(ev(Received(1, @tds.frame(Prelogin, pre)))))
  assert_eq(r1.length(), 1)
  let p = @tds.decode_prelogin(r1[0].payload)
  assert_eq(p.encryption, Some(@tds.ENCRYPT_NOT_SUP))
  assert_eq(p.version, Some((17, 0, 5005, 0)))
  // LOGIN7 split across two chunks
  let login = @tds.frame(Login7, login7_payload("sa", "secret", "tempdb"))
  assert_eq(e.handle(ev(Received(1, login[0:10].to_owned()))), [])
  let r2 = sent(e.handle(ev(Received(1, login[10:].to_owned()))))
  assert_eq(r2.length(), 1)
  let hex = @tds.hex(r2[0].payload)
  // starts with ENVCHANGE database 'tempdb' / 'master', ends with DONE final
  assert_true(
    hex.has_prefix("e3 1b 00 01 06 74 00 65 00 6d 00 70 00 64 00 62 00"),
  )
  assert_true(hex.has_suffix("fd 00 00 00 00 00 00 00 00 00 00 00 00"))
  // packet size 8192 negotiated: ENVCHANGE type 4 with "8192"
  assert_true(
    hex.contains("04 04 38 00 31 00 39 00 32 00 04 38 00 31 00 39 00 32 00"),
  )
  // SET-only batch completes with a single final DONE
  let batch = @tds.Writer::new()
  batch.bytes(
    @tds.from_hex(
      "16 00 00 00 12 00 00 00 02 00 00 00 00 00 00 00 00 00 01 00 00 00",
    ),
  )
  batch.ucs2("set textsize 2147483647\nset ansi_nulls on\n")
  let r3 = sent(
    e.handle(ev(Received(1, @tds.frame(SqlBatch, batch.to_bytes())))),
  )
  // each SET completes with its own DONE (cmd 185), the last one final
  assert_eq(
    @tds.hex(r3[0].payload),
    "fd 01 00 b9 00 00 00 00 00 00 00 00 00 fd 00 00 b9 00 00 00 00 00 00 00 00 00",
  )
}

///|
test "client requiring encryption is closed" {
  let e = @engine.Engine::new(@engine.Config::default(), 42)
  ignore(e.handle(ev(Connected(7))))
  let pre = @tds.from_hex(
    "00 00 10 00 06 01 00 16 00 01 04 00 17 00 01 FF 0c 00 00 00 00 00 01 00",
  )
  let outs = e.handle(ev(Received(7, @tds.frame(Prelogin, pre))))
  assert_true(outs.contains(Close(7)))
}

///|
test "garbage closes the connection" {
  let e = @engine.Engine::new(@engine.Config::default(), 42)
  ignore(e.handle(ev(Connected(3))))
  let outs = e.handle(ev(Received(3, @tds.from_hex("12 01 00 02 00 00 00 00"))))
  assert_true(outs.contains(Close(3)))
}

///|
test "render: batch error and rpc framing" {
  let err : @reply.SqlMessage = {
    number: 50100,
    state: 1,
    class: 16,
    message: "x",
    procedure: "",
    line: 1,
  }
  let b = @reply.render(Batch, [Message(err)], "s")
  assert_true(@tds.hex(b).has_suffix("fd 02 00 00 00 00 00 00 00 00 00 00 00"))
  let cols : Array[@tds.Column] = [
    { name: "a", type_info: Int4, flags: 0, user_type: 0, },
  ]
  let rpc = @reply.render(
    Rpc,
    [
      ResultSet(cols),
      Row([Int(1)]),
      StatementDone(cmd=@tds.CMD_SELECT, count=Some(1), error=false),
      ReturnStatus(0),
    ],
    "s",
  )
  assert_true(
    @tds.hex(rpc).has_suffix(
      "d1 01 00 00 00 ff 11 00 c1 00 01 00 00 00 00 00 00 00 79 00 00 00 00 fe 00 00 e0 00 00 00 00 00 00 00 00 00",
    ),
  )
}

///|
test "event log round trip and truncation tolerance" {
  let events : Array[@engine.Event] = [
    { input: Connected(1), now: 10, },
    { input: Received(1, b"\x12\x01"), now: 11, },
    { input: TimerFired(3), now: 12, },
    { input: Resume, now: 13, },
    { input: Closed(1), now: 14, },
  ]
  let w = @tds.Writer::new()
  w.bytes(@engine.encode_event_log_header(-7))
  for e in events {
    w.bytes(@engine.encode_event(e))
  }
  let log = w.to_bytes()
  let (seed, back) = @engine.decode_event_log(log)
  assert_eq(seed, -7)
  assert_eq(back, events)
  let (_, partial) = @engine.decode_event_log(log[0:log.length() - 3])
  assert_eq(partial.length(), 4)
}

///|
fn connect(e : @engine.Engine, id : Int) -> Unit {
  ignore(e.handle(ev(Connected(id))))
  let pre = @tds.from_hex(
    "00 00 10 00 06 01 00 16 00 01 04 00 17 00 01 FF 0c 00 00 00 00 00 02 00",
  )
  ignore(e.handle(ev(Received(id, @tds.frame(Prelogin, pre)))))
  ignore(
    e.handle(
      ev(Received(id, @tds.frame(Login7, login7_payload("sa", "x", "master")))),
    ),
  )
}

///|
fn batch(e : @engine.Engine, id : Int, sql : String) -> Array[@engine.Output] {
  let w = @tds.Writer::new()
  w.bytes(
    @tds.from_hex(
      "16 00 00 00 12 00 00 00 02 00 00 00 00 00 00 00 00 00 01 00 00 00",
    ),
  )
  w.ucs2(sql)
  e.handle(ev(Received(id, @tds.frame(SqlBatch, w.to_bytes()))))
}

///|
/// Connections that received a response in these outputs.
fn responded(outs : Array[@engine.Output]) -> Array[Int] {
  let ids = []
  for o in outs {
    if o is Send(id, _) && !ids.contains(id) {
      ids.push(id)
    }
  }
  ids
}

///|
/// ERROR numbers sent to `conn`.
fn errors_to(outs : Array[@engine.Output], conn : Int) -> Array[Int] raise {
  let nums = []
  for m in sent(outs.filter(o => o is Send(id, _) && id == conn)) {
    let r = @tds.Reader::new(m.payload)
    // scan for ERROR tokens (0xAA): len16, number int32
    let p = m.payload
    let mut i = 0
    while i + 7 < p.length() {
      if p[i] == b'\xAA' {
        let n = p[i + 3].to_int() |
          (p[i + 4].to_int() << 8) |
          (p[i + 5].to_int() << 16)
        if n == 1205 || n == 2627 || n == 1222 {
          nums.push(n)
        }
      }
      i += 1
    }
    ignore(r)
  }
  nums
}

///|
test "a writer waits for another transaction's lock and resumes on COMMIT" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  connect(e, 2)
  ignore(
    batch(
      e, 1, "CREATE TABLE t (id int PRIMARY KEY, v int); INSERT t VALUES (1, 1)",
    ),
  )
  assert_eq(
    responded(batch(e, 1, "BEGIN TRAN; UPDATE t SET v = 2 WHERE id = 1")),
    [1],
  )
  // conn 2 blocks: no response yet
  assert_eq(responded(batch(e, 2, "UPDATE t SET v = v + 10 WHERE id = 1")), [])
  // COMMIT releases the lock: both connections get responses now
  assert_eq(responded(batch(e, 1, "COMMIT")), [1, 2])
  let out = batch(e, 1, "SELECT v FROM t")
  let rows = sent(out)
  // v = 2 + 10 (the waiting UPDATE ran after the commit)
  assert_true(@tds.hex(rows[0].payload).contains("d1 04 0c 00 00 00"))
}

///|
test "upsert pattern with UPDLOCK, HOLDLOCK serializes; same-key insert waits then 2627" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  connect(e, 2)
  ignore(batch(e, 1, "CREATE TABLE k (id int PRIMARY KEY, v int)"))
  assert_eq(responded(batch(e, 1, "BEGIN TRAN; INSERT k VALUES (5, 1)")), [1])
  // the same key from another session waits for the uncommitted insert
  assert_eq(responded(batch(e, 2, "INSERT k VALUES (5, 2)")), [])
  let outs = batch(e, 1, "COMMIT")
  assert_eq(responded(outs), [1, 2])
  assert_eq(errors_to(outs, 2), [2627])
}

///|
test "deadlock: one session gets 1205, the other proceeds" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  connect(e, 2)
  ignore(
    batch(
      e, 1, "CREATE TABLE a (id int PRIMARY KEY, v int); CREATE TABLE b (id int PRIMARY KEY, v int); INSERT a VALUES (1, 0); INSERT b VALUES (1, 0)",
    ),
  )
  ignore(batch(e, 1, "BEGIN TRAN; UPDATE a SET v = 1 WHERE id = 1"))
  ignore(batch(e, 2, "BEGIN TRAN; UPDATE b SET v = 2 WHERE id = 1"))
  assert_eq(responded(batch(e, 1, "UPDATE b SET v = 1 WHERE id = 1")), []) // waits for 2
  let outs = batch(e, 2, "UPDATE a SET v = 2 WHERE id = 1") // closes the cycle
  // session 1 (waiting longest, equal cost) is the victim: its parked
  // request re-runs and fails with 1205; session 2 proceeds
  assert_eq(errors_to(outs, 1), [1205])
  assert_eq(errors_to(outs, 2), [])
  assert_eq(responded(outs), [1, 2])
}

///|
test "SET LOCK_TIMEOUT 0 fails a conflicting request at once with 1222" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  connect(e, 2)
  ignore(
    batch(
      e, 1, "CREATE TABLE t (id int PRIMARY KEY, v int); INSERT t VALUES (1, 1)",
    ),
  )
  ignore(batch(e, 1, "BEGIN TRAN; UPDATE t SET v = 2 WHERE id = 1"))
  let outs = batch(e, 2, "SET LOCK_TIMEOUT 0; UPDATE t SET v = 3 WHERE id = 1")
  assert_eq(responded(outs), [2])
  assert_eq(errors_to(outs, 2), [1222])
}

///|
test "SET LOCK_TIMEOUT n arms a timer; TimerFired fails the parked request with 1222" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  connect(e, 2)
  ignore(
    batch(
      e, 1, "CREATE TABLE t (id int PRIMARY KEY, v int); INSERT t VALUES (1, 1)",
    ),
  )
  ignore(batch(e, 1, "BEGIN TRAN; UPDATE t SET v = 2 WHERE id = 1"))
  let outs = batch(
    e, 2, "SET LOCK_TIMEOUT 500; UPDATE t SET v = 3 WHERE id = 1",
  )
  assert_eq(responded(outs), [])
  assert_true(outs.contains(SetTimer(2, 500)))
  let fired = e.handle(ev(TimerFired(2)))
  assert_eq(responded(fired), [2])
  assert_eq(errors_to(fired, 2), [1222])
  // the lock holder is unaffected
  assert_eq(responded(batch(e, 1, "COMMIT")), [1])
}

///|
test "WAITFOR DELAY parks with a timer; the re-run passes the completed wait" {
  let e = @engine.Engine::new(@engine.Config::default(), 1)
  connect(e, 1)
  let outs = batch(
    e, 1, "SELECT 1 AS a; WAITFOR DELAY '00:00:01.5'; SELECT 2 AS b; WAITFOR DELAY '00:00:00.25'; SELECT 3 AS c",
  )
  assert_eq(responded(outs), [])
  assert_true(outs.contains(SetTimer(1, 1500)))
  let second = e.handle(ev(TimerFired(1)))
  assert_eq(responded(second), [])
  assert_true(second.contains(SetTimer(1, 250)))
  let done = e.handle(ev(TimerFired(1)))
  assert_eq(responded(done), [1])
  // three result sets, each sent once
  let hex = @tds.hex(sent(done)[0].payload)
  let mut sets = 0
  let mut i = 0
  while i + 2 <= hex.length() {
    if hex.unsafe_substring(start=i, end=i + 2) == "81" && i % 3 == 0 {
      sets += 1
    }
    i += 3
  }
  assert_eq(sets, 3)
}
