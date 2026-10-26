///|
let cp1254_encoding_rows : Ref[Array[(Int, Int)]?] = Ref(None)

///|
fn cp1254_encoding() -> Array[(Int, Int)] {
  if cp1254_encoding_rows.val is Some(rows) {
    return rows
  }
  let rows = @tabletext.int_rows(cp1254_encoding_text).map(r => (r[0], r[1]))
  cp1254_encoding_rows.val = Some(rows)
  rows
}

///|
pub fn cp1254_byte(unit : Int) -> Int {
  let encoding = cp1254_encoding()
  let mut lo = 0
  let mut hi = encoding.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (u, b) = encoding[mid]
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
