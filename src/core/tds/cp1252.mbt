///|
/// Unicode code points of CP1252 bytes 0x80..0x9F (0 = undefined).
let cp1252_high : FixedArray[Int] = [
  0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
  0x2039, 0x0152, 0, 0x017D, 0, 0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013,
  0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
]

///|
/// Encodes to Windows-1252; unmappable characters become '?', as SQL Server
/// does for varchar without a best-fit mapping. (Best-fit mapping is a
/// known gap: see msduck windows-1252-best-fit captures.)
pub fn cp1252_encode(s : String) -> Bytes {
  let out = Buffer(size_hint=s.length())
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 || (cp >= 0xA0 && cp <= 0xFF) {
      out.write_byte(cp.to_byte())
    } else {
      let mut found = -1
      for i in 0..<32 {
        // the five undefined bytes (0x81, 0x8D, 0x8F, 0x90, 0x9D) are held
        // as U+0081… and go out as themselves (captured: CHAR(129) reaches
        // tedious as byte 0x81, msduck char-byte)
        if (cp1252_high[i] == cp && cp != 0) ||
          (cp1252_high[i] == 0 && cp == 0x80 + i) {
          found = 0x80 + i
          break
        }
      }
      out.write_byte((if found >= 0 { found } else { '?'.to_int() }).to_byte())
    }
  }
  out.to_bytes()
}

///|
pub fn cp1252_decode(b : BytesView) -> String {
  let sb = StringBuilder(size_hint=b.length())
  for byte in b {
    let v = byte.to_int()
    let cp = if v >= 0x80 && v < 0xA0 && cp1252_high[v - 0x80] != 0 {
      cp1252_high[v - 0x80]
    } else {
      v
    }
    sb.write_char(cp.unsafe_to_char())
  }
  sb.to_string()
}

///|
/// The collation's fUTF8 flag (0x40 in the flags byte of the 5-byte TDS
/// collation): char/varchar/text data travels as UTF-8.
pub fn collation_is_utf8(c : Bytes) -> Bool {
  c.length() >= 4 && (c[3].to_int() & 0x04) != 0
}

///|
/// Wire bytes of char/varchar/text data under a collation.
pub fn char_encode(s : String, collation : Bytes) -> Bytes {
  if collation_is_utf8(collation) {
    utf8_encode(s)
  } else {
    cp1252_encode(s)
  }
}

///|
/// Text of char/varchar/text wire bytes under a collation.
pub fn char_decode(b : BytesView, collation : Bytes) -> String {
  if collation_is_utf8(collation) {
    @utf8.decode_lossy(b)
  } else {
    cp1252_decode(b)
  }
}

///|
/// UTF-8 bytes of a string; a lone surrogate becomes '?' (never aborts).
fn utf8_encode(s : String) -> Bytes {
  let out : Array[Byte] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let u = s.code_unit_at(i).to_int()
    let cp = if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
      let lo = s.code_unit_at(i + 1).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        i += 1
        0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
      } else {
        0x3F
      }
    } else if u >= 0xD800 && u <= 0xDFFF {
      0x3F
    } else {
      u
    }
    if cp < 0x80 {
      out.push(cp.to_byte())
    } else if cp < 0x800 {
      out.push((0xC0 | (cp >> 6)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      out.push((0xE0 | (cp >> 12)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      out.push((0xF0 | (cp >> 18)).to_byte())
      out.push((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    }
    i += 1
  }
  Bytes::from_array(out)
}
