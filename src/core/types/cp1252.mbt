// Code page 1252 (Windows Latin 1), the code page of every collation bitsql
// models. varchar values are kept as MoonBit Strings whose code units are
// all CP1252-representable, so the String length is the byte length.
//
// Unicode → CP1252 converts each UTF-16 code unit on its own (captured,
// docs/reference/result-metadata.md "Code page 1252 conversion"): the 256
// exact mappings, then SQL Server's best-fit table (cp1252_best_fit.mbt,
// e.g. U+0100 Ā → 'A', U+0301 → 0xB4), else '?' — surrogate halves
// included, so a supplementary character becomes "??". The five bytes
// undefined in CP1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D) round-trip as U+0081
// etc., as Windows' MultiByteToWideChar does.

///|
/// Unicode code points of bytes 0x80..0x9F (0 = maps to the same value).
let cp1252_high : FixedArray[Int] = [
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
  0x2039, 0x0152, 0, 0x017D, 0, 0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013,
  0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
]

///|
/// CP1252 byte → UTF-16 code unit.
pub fn cp1252_decode(byte : Int) -> Int {
  if byte >= 0x80 && byte <= 0x9F {
    let u = cp1252_high[byte - 0x80]
    if u == 0 {
      byte
    } else {
      u
    }
  } else {
    byte
  }
}

///|
/// UTF-16 code unit → CP1252 byte, or None if there is no exact mapping.
pub fn cp1252_encode(unit : Int) -> Int? {
  if unit < 0x80 || (unit >= 0xA0 && unit <= 0xFF) {
    return Some(unit)
  }
  for i, u in cp1252_high {
    if u == unit || (u == 0 && unit == 0x80 + i) {
      return Some(0x80 + i)
    }
  }
  None
}

///|
/// The CP1252 byte SQL Server stores for one UTF-16 code unit: exact
/// mapping, best fit, else '?'.
pub fn cp1252_byte_of(unit : Int) -> Int {
  match cp1252_encode(unit) {
    Some(b) => b
    None => {
      let mut lo = 0
      let mut hi = cp1252_best_fit.length()
      while lo < hi {
        let mid = (lo + hi) / 2
        let (u, b) = cp1252_best_fit[mid]
        if u == unit {
          return b
        } else if u < unit {
          lo = mid + 1
        } else {
          hi = mid
        }
      }
      0x3F
    }
  }
}

///|
/// Converts a Unicode string to its CP1252 representation (one character
/// per UTF-16 code unit, best fit or '?' where there is no exact mapping),
/// returned as the decoded String bitsql keeps varchar values in.
pub fn to_cp1252(s : String) -> String {
  let mut exact = true
  for i in 0..<s.length() {
    if cp1252_encode(s[i].to_int()) is None {
      exact = false
      break
    }
  }
  if exact {
    return s
  }
  let sb = StringBuilder()
  for i in 0..<s.length() {
    sb.write_char(cp1252_decode(cp1252_byte_of(s[i].to_int())).unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Encode a string as CP1252 bytes (best fit / '?' for unmapped units).
pub fn cp1252_bytes(s : String) -> Bytes {
  Bytes::makei(s.length(), fn(i) { cp1252_byte_of(s[i].to_int()).to_byte() })
}

///|
/// Decode CP1252 bytes.
pub fn cp1252_string(b : BytesView) -> String {
  let sb = StringBuilder()
  for x in b {
    sb.write_char(cp1252_decode(x.to_int()).unsafe_to_char())
  }
  sb.to_string()
}
