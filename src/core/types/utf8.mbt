// varchar under UTF-8 collations (`…_SC_UTF8`, `…_BIN2_UTF8`, code page
// 65001): values stay MoonBit Strings holding any Unicode text; byte
// lengths (varchar(n) capacity, DATALENGTH), varbinary conversions and
// hashes use their UTF-8 encoding. Captured: settings/utf8.

///|
/// A UTF-8 collation: varchar data is stored as UTF-8.
pub fn Collation::utf8(self : Collation) -> Bool {
  self.code_page == 65001
}

///|
/// UTF-8 encoding of varchar text; a lone surrogate (never stored in a
/// UTF-8 varchar) encodes as '?'.
pub fn utf8_bytes(s : String) -> Bytes {
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

///|
/// UTF-8 byte length of one UTF-16 code unit position: 1-3 bytes, 4 for a
/// surrogate pair (counted on its high half, 0 on the low half).
fn utf8_unit_length(s : String, i : Int) -> Int {
  let u = s.code_unit_at(i).to_int()
  if u < 0x80 {
    1
  } else if u < 0x800 {
    2
  } else if u >= 0xD800 && u <= 0xDBFF {
    if i + 1 < s.length() &&
      s.code_unit_at(i + 1).to_int() >= 0xDC00 &&
      s.code_unit_at(i + 1).to_int() <= 0xDFFF {
      4
    } else {
      1
    }
  } else if u >= 0xDC00 && u <= 0xDFFF {
    if i > 0 &&
      s.code_unit_at(i - 1).to_int() >= 0xD800 &&
      s.code_unit_at(i - 1).to_int() <= 0xDBFF {
      0
    } else {
      1
    }
  } else {
    3
  }
}

///|
/// UTF-8 length in bytes.
pub fn utf8_length(s : String) -> Int {
  let mut n = 0
  for i in 0..<s.length() {
    n += utf8_unit_length(s, i)
  }
  n
}

///|
/// The longest prefix of whole characters that fits in `cap` UTF-8 bytes
/// (captured: 'ééééé' as varchar(5) is 'éé').
pub fn utf8_prefix(s : String, cap : Int) -> String {
  let mut used = 0
  let mut end = 0
  let n = s.length()
  while end < n {
    let w = utf8_unit_length(s, end)
    let units = if w == 4 { 2 } else { 1 }
    if used + w > cap {
      break
    }
    used += w
    end += units
  }
  s.unsafe_substring(start=0, end~)
}

///|
/// Text of UTF-8 bytes (invalid sequences become U+FFFD).
pub fn utf8_text(b : BytesView) -> String {
  @utf8.decode_lossy(b)
}

///|
/// The bytes SQL Server stores for varchar text under collation `c`.
pub fn varchar_bytes(s : String, c : Collation) -> Bytes {
  if c.utf8() {
    utf8_bytes(s)
  } else if c.code_page == 1254 {
    @codepage.cp1254_encode(s)
  } else {
    cp1252_bytes(s)
  }
}

///|
/// Text converted into the code page of collation `c` (varchar storage):
/// CP1252/CP1254 with best fit, or UTF-8 (lossless except lone surrogates).
pub fn to_code_page(s : String, c : Collation) -> String {
  if c.utf8() {
    if s.iter().any(ch => ch.to_int() >= 0xD800 && ch.to_int() <= 0xDFFF) {
      utf8_text(utf8_bytes(s))
    } else {
      s
    }
  } else if c.code_page == 1254 {
    @codepage.cp1254_decode(@codepage.cp1254_encode(s)[:])
  } else {
    to_cp1252(s)
  }
}

///|
/// Decode stored varchar bytes using the declared collation's code page.
pub fn varchar_text(bytes : BytesView, c : Collation) -> String {
  if c.utf8() {
    utf8_text(bytes)
  } else if c.code_page == 1254 {
    @codepage.cp1254_decode(bytes)
  } else {
    cp1252_string(bytes)
  }
}
