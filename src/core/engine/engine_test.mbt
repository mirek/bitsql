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
  assert_eq(p.version, Some((17, 0, 4065, 0)))
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
  assert_eq(@tds.hex(r3[0].payload), "fd 00 00 00 00 00 00 00 00 00 00 00 00")
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
  let err : @engine.SqlMessage = {
    number: 50100,
    state: 1,
    class: 16,
    message: "x",
    procedure: "",
    line: 1,
  }
  let b = @engine.render(Batch, [Message(err)], "s")
  assert_true(@tds.hex(b).has_suffix("fd 02 00 00 00 00 00 00 00 00 00 00 00"))
  let cols : Array[@tds.Column] = [
    { name: "a", type_info: Int4, flags: 0, user_type: 0, },
  ]
  let rpc = @engine.render(
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
