///|
pub fn cp1254_byte(unit : Int) -> Int {
  let mut lo = 0
  let mut hi = cp1254_encoding.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (u, b) = cp1254_encoding[mid]
    if u == unit {
      return b
    }
    if u < unit {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  63
}

///|
pub fn cp1254_unit(byte : Int) -> Int {
  if byte >= 0 && byte < 256 {
    cp1254_decoding[byte]
  } else {
    63
  }
}

///|
pub fn cp1254_encode(text : String) -> Bytes {
  Bytes::makei(text.length(), i => {
    cp1254_byte(text.code_unit_at(i).to_int()).to_byte()
  })
}

///|
pub fn cp1254_decode(bytes : BytesView) -> String {
  let out = StringBuilder()
  for b in bytes {
    out.write_char(cp1254_unit(b.to_int()).unsafe_to_char())
  }
  out.to_string()
}
