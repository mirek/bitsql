///|
// MS-TDS example 4.1 request (ENCRYPT_ON), vector shared with msduck/mssqlite.
let example_4_1 : String = "00 00 1A 00 06 01 00 20 00 01 02 00 21 00 01 03 00 22 00 04 04 00 26 00 01 FF 09 00 00 00 00 00 01 00 B8 0D 00 00 01"

///|
test "decode PRELOGIN example 4.1" {
  let p = @tds.decode_prelogin(@tds.from_hex(example_4_1))
  assert_eq(p.version, Some((9, 0, 0, 0)))
  assert_eq(p.encryption, Some(@tds.ENCRYPT_ON))
  assert_eq(p.instance, Some(""))
  assert_eq(p.thread_id, Some(0x0DB8L))
  assert_eq(p.mars, Some(true))
}

///|
test "encryption negotiation without TLS" {
  assert_eq(
    @tds.negotiate_encryption(Some(@tds.ENCRYPT_OFF), tls=false),
    Some(@tds.ENCRYPT_NOT_SUP),
  )
  assert_eq(
    @tds.negotiate_encryption(Some(@tds.ENCRYPT_NOT_SUP), tls=false),
    Some(@tds.ENCRYPT_NOT_SUP),
  )
  assert_eq(@tds.negotiate_encryption(Some(@tds.ENCRYPT_ON), tls=false), None)
  assert_eq(@tds.negotiate_encryption(Some(@tds.ENCRYPT_REQ), tls=false), None)
}

///|
test "encryption negotiation with TLS (captured replies)" {
  let reply = (c : Int) => @tds.negotiate_encryption(Some(c), tls=true)
  assert_eq(reply(@tds.ENCRYPT_OFF), Some(@tds.ENCRYPT_OFF))
  assert_eq(reply(@tds.ENCRYPT_ON), Some(@tds.ENCRYPT_ON))
  assert_eq(reply(@tds.ENCRYPT_NOT_SUP), Some(@tds.ENCRYPT_NOT_SUP))
  assert_eq(reply(@tds.ENCRYPT_REQ), Some(@tds.ENCRYPT_ON))
}

///|
test "PRELOGIN response matches msduck vector" {
  let bytes = @tds.encode_prelogin_response(
    version=(16, 0, 0, 0),
    encryption=@tds.ENCRYPT_NOT_SUP,
  )
  assert_eq(
    @tds.hex(bytes),
    "00 00 10 00 06 01 00 16 00 01 04 00 17 00 01 ff 10 00 00 00 00 00 02 00",
  )
}

///|
test "PRELOGIN option out of bounds raises" {
  try @tds.decode_prelogin(@tds.from_hex("00 00 10 00 06 FF")) catch {
    e => inspect(e.message(), content="PRELOGIN option 0 out of bounds")
  } noraise {
    _ => fail("expected error")
  }
}

///|
test "LOGIN7 decode with scrambled password" {
  let w = @tds.Writer::new()
  w.u32le(0) // patched below
  w.u32le(0x74000004)
  w.u32le(4096)
  w.u32le(7)
  w.u32le(4242)
  w.u32le(0)
  w.u8(0xE0)
  w.u8(0x03)
  w.u8(0)
  w.u8(0)
  w.i32le(0)
  w.u32le(0x0409)
  // 9 offset/count pairs starting at 36; data starts at 94
  let pairs = [
    (94, 0),
    (94, 2),
    (98, 9),
    (116, 7),
    (130, 0),
    (130, 0),
    (130, 7),
    (144, 0),
    (144, 6),
  ]
  for p in pairs {
    w.u16le(p.0)
    w.u16le(p.1)
  }
  w.bytes(Bytes::make(94 - 72, b'\x00')) // ClientID(6) + SSPI(4) + AttachDB(4) + ChangePassword(4) + cbSSPILong(4)
  w.ucs2("sa")
  w.bytes(@tds.scramble_password("p@ssw0rd!"))
  w.ucs2("tedious")
  w.ucs2("Tedious")
  w.ucs2("master")
  let raw = w.to_bytes().to_array()
  let len = raw.length()
  raw[0] = len.to_byte()
  raw[1] = (len >> 8).to_byte()
  let l = @tds.decode_login7(Bytes::from_array(raw))
  assert_eq(l.user_name, "sa")
  assert_eq(l.password, "p@ssw0rd!")
  assert_eq(l.app_name, "tedious")
  assert_eq(l.library_name, "Tedious")
  assert_eq(l.database, "master")
  assert_eq(l.packet_size, 4096)
  assert_eq(l.client_pid, 4242L)
}

///|
test "scramble vector from msduck" {
  assert_eq(
    @tds.hex(@tds.scramble_password("p@ssw0rd!")),
    "a2 a5 a1 a5 92 a5 92 a5 d2 a5 a6 a5 82 a5 e3 a5 b7 a5",
  )
}

///|
test "SQL batch with ALL_HEADERS" {
  let w = @tds.Writer::new()
  w.bytes(
    @tds.from_hex(
      "16 00 00 00 12 00 00 00 02 00 00 00 00 00 00 00 00 01 00 00 00 00",
    ),
  )
  w.ucs2("select 1")
  let b = @tds.decode_sql_batch(w.to_bytes())
  assert_eq(b.text, "select 1")
}
