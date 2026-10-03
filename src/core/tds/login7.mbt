///|
/// Decoded LOGIN7 (MS-TDS 2.2.6.4). Password is descrambled.
pub(all) struct Login7 {
  tds_version : Int64
  packet_size : Int
  client_prog_ver : Int64
  client_pid : Int64
  connection_id : Int64
  option_flags1 : Int
  option_flags2 : Int
  type_flags : Int
  option_flags3 : Int
  client_time_zone : Int
  client_lcid : Int64
  host_name : String
  user_name : String
  password : String
  app_name : String
  server_name : String
  library_name : String
  language : String
  database : String
  /// FeatureExt entries (feature id, data); empty when not present.
  features : Array[(Int, Bytes)]
} derive(Debug)

///|
fn descramble(b : Int) -> Int {
  let x = b ^ 0xA5
  ((x >> 4) | (x << 4)) & 0xFF
}

///|
/// Client-side scrambling, used by tests to build LOGIN7 payloads.
pub fn scramble_password(password : String) -> Bytes {
  let w = Writer::new()
  w.ucs2(password)
  let raw = w.to_bytes()
  Bytes::makei(raw.length(), i => {
    let b = raw[i].to_int()
    ((((b << 4) & 0xFF) | (b >> 4)) ^ 0xA5).to_byte()
  })
}

///|
pub fn decode_login7(payload : BytesView) -> Login7 raise TdsError {
  let r = Reader::new(payload)
  let length = r.u32le()
  if length > payload.length().to_int64() || length < 94L {
    raise Malformed("LOGIN7 length \{length}")
  }
  let tds_version = r.u32le()
  let packet_size = r.u32le().to_int()
  let client_prog_ver = r.u32le()
  let client_pid = r.u32le()
  let connection_id = r.u32le()
  let option_flags1 = r.u8()
  let option_flags2 = r.u8()
  let type_flags = r.u8()
  let option_flags3 = r.u8()
  let client_time_zone = r.i32le()
  let client_lcid = r.u32le()
  // 36: offset/length pairs. Index: 0 host, 1 user, 2 password, 3 app,
  // 4 server, 5 extension (or unused), 6 library, 7 language, 8 database.
  let pairs = []
  for _ in 0..<9 {
    let off = r.u16le()
    let cnt = r.u16le()
    pairs.push((off, cnt))
  }
  fn chars(i : Int) -> String raise TdsError {
    let (off, cnt) = pairs[i]
    if off + cnt * 2 > payload.length() {
      raise Malformed("LOGIN7 field \{i} out of bounds")
    }
    Reader::new(payload[off:off + cnt * 2]).ucs2(cnt)
  }

  let password = {
    let (off, cnt) = pairs[2]
    if off + cnt * 2 > payload.length() {
      raise Malformed("LOGIN7 password out of bounds")
    }
    let sb = StringBuilder()
    for i in 0..<cnt {
      let lo = descramble(payload[off + i * 2].to_int())
      let hi = descramble(payload[off + i * 2 + 1].to_int())
      sb.write_char((lo | (hi << 8)).unsafe_to_char())
    }
    sb.to_string()
  }
  let features = []
  if (option_flags3 & 0x10) != 0 {
    let (off, _) = pairs[5]
    if off + 4 <= payload.length() {
      let ptr = Reader::new(payload[off:off + 4]).u32le().to_int()
      if ptr > 0 && ptr < payload.length() {
        let f = Reader::new(payload[ptr:])
        while !f.at_end() {
          let id = f.u8()
          if id == 0xFF {
            break
          }
          let n = f.u32le().to_int()
          features.push((id, f.bytes(n)))
        }
      }
    }
  }
  {
    tds_version,
    packet_size,
    client_prog_ver,
    client_pid,
    connection_id,
    option_flags1,
    option_flags2,
    type_flags,
    option_flags3,
    client_time_zone,
    client_lcid,
    host_name: chars(0),
    user_name: chars(1),
    password,
    app_name: chars(3),
    server_name: chars(4),
    library_name: chars(6),
    language: chars(7),
    database: chars(8),
    features,
  }
}
