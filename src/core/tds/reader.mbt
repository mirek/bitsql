///|
/// Bounds-checked little-endian cursor over a message payload.
pub struct Reader {
  data : BytesView
  mut pos : Int
}

///|
pub fn Reader::new(data : BytesView) -> Reader {
  { data, pos: 0, }
}

///|
pub fn Reader::remaining(self : Reader) -> Int {
  self.data.length() - self.pos
}

///|
pub fn Reader::at_end(self : Reader) -> Bool {
  self.pos >= self.data.length()
}

///|
fn Reader::need(self : Reader, n : Int, what : String) -> Unit raise TdsError {
  if n < 0 || self.pos + n > self.data.length() {
    raise Malformed("truncated \{what}")
  }
}

///|
pub fn Reader::u8(self : Reader) -> Int raise TdsError {
  self.need(1, "byte")
  let v = self.data[self.pos].to_int()
  self.pos += 1
  v
}

///|
pub fn Reader::u16le(self : Reader) -> Int raise TdsError {
  self.need(2, "uint16")
  let d = self.data
  let p = self.pos
  self.pos += 2
  d[p].to_int() | (d[p + 1].to_int() << 8)
}

///|
pub fn Reader::u16be(self : Reader) -> Int raise TdsError {
  self.need(2, "uint16")
  let d = self.data
  let p = self.pos
  self.pos += 2
  (d[p].to_int() << 8) | d[p + 1].to_int()
}

///|
/// Unsigned 32-bit little-endian, as Int64 so values above 2^31 stay positive.
pub fn Reader::u32le(self : Reader) -> Int64 raise TdsError {
  self.need(4, "uint32")
  let d = self.data
  let p = self.pos
  self.pos += 4
  d[p].to_int64() |
  (d[p + 1].to_int64() << 8) |
  (d[p + 2].to_int64() << 16) |
  (d[p + 3].to_int64() << 24)
}

///|
pub fn Reader::i32le(self : Reader) -> Int raise TdsError {
  self.u32le().to_int()
}

///|
pub fn Reader::u32be(self : Reader) -> Int64 raise TdsError {
  self.need(4, "uint32")
  let d = self.data
  let p = self.pos
  self.pos += 4
  (d[p].to_int64() << 24) |
  (d[p + 1].to_int64() << 16) |
  (d[p + 2].to_int64() << 8) |
  d[p + 3].to_int64()
}

///|
pub fn Reader::u64le(self : Reader) -> UInt64 raise TdsError {
  let lo = self.u32le().reinterpret_as_uint64()
  let hi = self.u32le().reinterpret_as_uint64()
  lo | (hi << 32)
}

///|
pub fn Reader::bytes(self : Reader, n : Int) -> Bytes raise TdsError {
  self.need(n, "bytes")
  let v = self.data[self.pos:self.pos + n].to_owned()
  self.pos += n
  v
}

///|
pub fn Reader::skip(self : Reader, n : Int) -> Unit raise TdsError {
  self.need(n, "skip")
  self.pos += n
}

///|
/// `n` UCS-2 code units (2n bytes) as a String.
pub fn Reader::ucs2(self : Reader, n : Int) -> String raise TdsError {
  self.need(n * 2, "UCS-2 string")
  let d = self.data
  let p = self.pos
  self.pos += n * 2
  let sb = StringBuilder(size_hint=n)
  for i in 0..<n {
    let unit = d[p + i * 2].to_int() | (d[p + i * 2 + 1].to_int() << 8)
    sb.write_char(unit.unsafe_to_char())
  }
  sb.to_string()
}

///|
/// B_VARCHAR: byte length in characters, then UCS-2.
pub fn Reader::b_varchar(self : Reader) -> String raise TdsError {
  let n = self.u8()
  self.ucs2(n)
}

///|
/// US_VARCHAR: uint16 length in characters, then UCS-2.
pub fn Reader::us_varchar(self : Reader) -> String raise TdsError {
  let n = self.u16le()
  self.ucs2(n)
}
