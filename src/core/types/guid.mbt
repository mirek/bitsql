// uniqueidentifier: 16 bytes in SQL Server storage order, i.e. the bytes
// `CONVERT(binary(16), g)` returns and TDS sends: Data1 (4 bytes), Data2 and
// Data3 (2 bytes each) little-endian, Data4 (8 bytes) as written. The text
// `00112233-4455-6677-8899-AABBCCDDEEFF` is stored as
// `33 22 11 00 55 44 77 66 88 99 AA BB CC DD EE FF`.

///|
fn hex_value(c : UInt16) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Text position (in the 36-character canonical form) of each storage byte's
/// two hex digits.
let guid_text_positions : FixedArray[Int] = [
  6, 4, 2, 0, 11, 9, 16, 14, 19, 21, 24, 26, 28, 30, 32, 34,
]

///|
fn parse_canonical(s : String, at : Int) -> Bytes? {
  if s.length() < at + 36 {
    return None
  }
  for k in [8, 13, 18, 23] {
    if s[at + k] != '-' {
      return None
    }
  }
  let out = FixedArray::make(16, b'\x00')
  for i in 0..<16 {
    let p = at + guid_text_positions[i]
    match (hex_value(s[p]), hex_value(s[p + 1])) {
      (Some(hi), Some(lo)) => out[i] = (hi * 16 + lo).to_byte()
      _ => return None
    }
  }
  Some(Bytes::from_array(out[:]))
}

///|
/// Parse character text as SQL Server converts it to uniqueidentifier
/// (msduck docs/guid-conversion-order.md, reference/guid-character-conversion.json):
/// a canonical 36-character `8-4-4-4-12` hex prefix converts and anything
/// after it is ignored; a `{`-braced GUID converts if the closing `}`
/// follows, again ignoring the rest. Case-insensitive. Leading spaces,
/// missing hyphens, short text and empty text fail (error 8169).
pub fn parse_guid(s : String) -> Bytes? {
  if s.length() > 0 && s[0] == '{' {
    if s.length() < 38 || s[37] != '}' {
      return None
    }
    parse_canonical(s, 1)
  } else {
    parse_canonical(s, 0)
  }
}

///|
/// Uppercase canonical text, as `CAST(g AS varchar(36))` prints it.
pub fn format_guid(bytes : Bytes) -> String {
  let digits = "0123456789ABCDEF"
  let out = FixedArray::make(36, '-')
  for i in 0..<16 {
    let p = guid_text_positions[i]
    let b = bytes[i].to_int()
    out[p] = digits[b / 16].to_int().unsafe_to_char()
    out[p + 1] = digits[b % 16].to_int().unsafe_to_char()
  }
  String::from_array(out[:])
}

///|
/// Storage byte indexes in SQL Server's comparison order: bytes 10..15
/// first, then 8..9, 6..7, 4..5 and 0..3, each group in storage order
/// (captured ORDER BY results: msduck reference/guid-conversion-order.json).
let guid_compare_order : FixedArray[Int] = [
  10, 11, 12, 13, 14, 15, 8, 9, 6, 7, 4, 5, 0, 1, 2, 3,
]

///|
/// Compare two uniqueidentifiers the way SQL Server orders them.
pub fn guid_compare(a : Bytes, b : Bytes) -> Int {
  for i in guid_compare_order {
    let c = a[i].compare(b[i])
    if c != 0 {
      return c
    }
  }
  0
}
