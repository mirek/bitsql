///|
/// Little-endian byte writer used by every encoder in this package.
pub struct Writer {
  buf : Buffer
}

///|
pub fn Writer::new(size_hint? : Int = 64) -> Writer {
  { buf: Buffer(size_hint~), }
}

///|
pub fn Writer::length(self : Writer) -> Int {
  self.buf.length()
}

///|
pub fn Writer::to_bytes(self : Writer) -> Bytes {
  self.buf.to_bytes()
}

///|
pub fn Writer::u8(self : Writer, v : Int) -> Unit {
  self.buf.write_byte(v.to_byte())
}

///|
pub fn Writer::u16le(self : Writer, v : Int) -> Unit {
  self.buf.write_byte(v.to_byte())
  self.buf.write_byte((v >> 8).to_byte())
}

///|
pub fn Writer::u16be(self : Writer, v : Int) -> Unit {
  self.buf.write_byte((v >> 8).to_byte())
  self.buf.write_byte(v.to_byte())
}

///|
pub fn Writer::i32le(self : Writer, v : Int) -> Unit {
  self.buf.write_int_le(v)
}

///|
pub fn Writer::u32le(self : Writer, v : Int64) -> Unit {
  self.buf.write_int_le(v.to_int())
}

///|
pub fn Writer::u32be(self : Writer, v : Int64) -> Unit {
  self.buf.write_int_be(v.to_int())
}

///|
pub fn Writer::i64le(self : Writer, v : Int64) -> Unit {
  self.buf.write_int64_le(v)
}

///|
pub fn Writer::u64le(self : Writer, v : UInt64) -> Unit {
  self.buf.write_uint64_le(v)
}

///|
pub fn Writer::bytes(self : Writer, b : BytesView) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// UCS-2 little-endian code units, no length prefix.
pub fn Writer::ucs2(self : Writer, s : String) -> Unit {
  for i in 0..<s.length() {
    let unit = s.code_unit_at(i).to_int()
    self.u16le(unit)
  }
}

///|
/// B_VARCHAR: character count as one byte, then UCS-2.
pub fn Writer::b_varchar(self : Writer, s : String) -> Unit {
  self.u8(s.length())
  self.ucs2(s)
}

///|
/// US_VARCHAR: character count as uint16, then UCS-2.
pub fn Writer::us_varchar(self : Writer, s : String) -> Unit {
  self.u16le(s.length())
  self.ucs2(s)
}

///|
/// B_VARBYTE: byte count as one byte, then the bytes.
pub fn Writer::b_varbyte(self : Writer, b : BytesView) -> Unit {
  self.u8(b.length())
  self.bytes(b)
}

///|
/// Lowercase hex of `b`, space separated: the format used by codec tests.
pub fn hex(b : BytesView) -> String {
  let sb = StringBuilder()
  let digits = "0123456789abcdef"
  for i, byte in b {
    if i > 0 {
      sb.write_char(' ')
    }
    let v = byte.to_int()
    sb.write_char(digits.code_unit_at(v >> 4).to_int().unsafe_to_char())
    sb.write_char(digits.code_unit_at(v & 15).to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Parses whitespace-separated hex (tests and fixtures).
pub fn from_hex(s : String) -> Bytes {
  let out = Buffer()
  let mut hi = -1
  for c in s {
    let v = match c {
      '0'..='9' => c.to_int() - '0'.to_int()
      'a'..='f' => c.to_int() - 'a'.to_int() + 10
      'A'..='F' => c.to_int() - 'A'.to_int() + 10
      _ => -1
    }
    if v < 0 {
      continue
    }
    if hi < 0 {
      hi = v
    } else {
      out.write_byte(((hi << 4) | v).to_byte())
      hi = -1
    }
  }
  out.to_bytes()
}
