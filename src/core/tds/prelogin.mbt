///|
/// PRELOGIN ENCRYPTION option values.
pub const ENCRYPT_OFF : Int = 0x00

///|
pub const ENCRYPT_ON : Int = 0x01

///|
pub const ENCRYPT_NOT_SUP : Int = 0x02

///|
pub const ENCRYPT_REQ : Int = 0x03

///|
/// Decoded client PRELOGIN. Unknown options are kept raw in `options`.
pub(all) struct Prelogin {
  version : (Int, Int, Int, Int)? // major, minor, build, subbuild
  encryption : Int? // ENCRYPT_* value
  instance : String?
  thread_id : Int64?
  mars : Bool?
  options : Array[(Int, Bytes)]
} derive(Debug)

///|
pub fn decode_prelogin(payload : BytesView) -> Prelogin raise TdsError {
  let r = Reader::new(payload)
  let options = []
  while true {
    let token = r.u8()
    if token == 0xFF {
      break
    }
    let offset = r.u16be()
    let length = r.u16be()
    if offset + length > payload.length() {
      raise Malformed("PRELOGIN option \{token} out of bounds")
    }
    options.push((token, payload[offset:offset + length].to_owned()))
  }
  let mut version = None
  let mut encryption = None
  let mut instance = None
  let mut thread_id = None
  let mut mars = None
  for opt in options {
    let (token, data) = opt
    let d = Reader::new(data[:])
    match token {
      0x00 if data.length() >= 6 =>
        version = Some((d.u8(), d.u8(), d.u16be(), d.u16le()))
      0x01 if data.length() >= 1 => encryption = Some(data[0].to_int())
      0x02 => {
        let sb = StringBuilder()
        for b in data {
          if b == 0 {
            break
          }
          sb.write_char(b.to_int().unsafe_to_char())
        }
        instance = Some(sb.to_string())
      }
      0x03 if data.length() >= 4 => thread_id = Some(d.u32le())
      0x04 if data.length() >= 1 => mars = Some(data[0] != 0)
      _ => ()
    }
  }
  { version, encryption, instance, thread_id, mars, options, }
}

///|
/// Server encryption reply for a server without TLS: OFF and NOT_SUP are
/// answered NOT_SUP (plaintext session); ON/REQ cannot be served (None).
/// Note tedious with `encrypt: false` sends NOT_SUP, not OFF.
pub fn negotiate_encryption_without_tls(client : Int?) -> Int? {
  match client {
    None => Some(ENCRYPT_NOT_SUP)
    Some(c) if c == ENCRYPT_OFF || c == ENCRYPT_NOT_SUP => Some(ENCRYPT_NOT_SUP)
    _ => None
  }
}

///|
/// Server PRELOGIN response payload: VERSION, ENCRYPTION, MARS (off). This
/// matches the msduck/mssqlite vector that tedious accepts.
pub fn encode_prelogin_response(
  version~ : (Int, Int, Int, Int),
  encryption~ : Int,
) -> Bytes {
  let (major, minor, build, sub) = version
  let v = Writer::new()
  v.u8(major)
  v.u8(minor)
  v.u16be(build)
  v.u16le(sub)
  let options : Array[(Int, Bytes)] = [
    (0x00, v.to_bytes()),
    (0x01, Bytes::make(1, encryption.to_byte())),
    (0x04, Bytes::make(1, b'\x00')),
  ]
  let w = Writer::new()
  let mut offset = options.length() * 5 + 1
  for opt in options {
    w.u8(opt.0)
    w.u16be(offset)
    w.u16be(opt.1.length())
    offset += opt.1.length()
  }
  w.u8(0xFF)
  for opt in options {
    w.bytes(opt.1)
  }
  w.to_bytes()
}
