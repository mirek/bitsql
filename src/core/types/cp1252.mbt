// Code page 1252 (Windows Latin 1), the code page of every collation bitsql
// models. varchar values are kept as MoonBit Strings whose code units are
// all CP1252-representable, so the String length is the byte length.
//
// Limits: SQL Server converts unrepresentable Unicode with a "best-fit"
// table (e.g. U+0100 Ā → 'A') and '?' otherwise. bitsql does not have that
// table and raises EMU_CODE_PAGE_BEST_FIT instead of guessing. The five
// bytes undefined in CP1252 (0x81, 0x8D, 0x8F, 0x90, 0x9D) round-trip as
// U+0081 etc., as Windows' MultiByteToWideChar does.

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
/// Check that every code unit of `s` is representable in code page 1252;
/// raise EMU_CODE_PAGE_BEST_FIT for the first one that is not.
pub fn require_cp1252(s : String) -> Unit raise SqlError {
  for i in 0..<s.length() {
    let u = s[i].to_int()
    if cp1252_encode(u) is None {
      let hex = u.to_string(radix=16).to_upper()
      raise emulator_error(
        EMU_CODE_PAGE_BEST_FIT,
        "converting U+\{String::make(4 - hex.length(), '0')}\{hex} to code page 1252 needs SQL Server's best-fit mapping, which is not supported.",
      )
    }
  }
}

///|
/// Encode a CP1252-representable string as bytes (callers ensure it is).
pub fn cp1252_bytes(s : String) -> Bytes {
  Bytes::makei(s.length(), fn(i) {
    cp1252_encode(s[i].to_int()).unwrap_or(0x3F).to_byte()
  })
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
