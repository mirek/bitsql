// Conversions to character and binary types, and value → text rendering
// (CONVERT styles).

///|
/// 9809 state 1 (captured for binary ↔ character style 3): "The style 3 is
/// not supported for conversions from varchar to varbinary."
fn style_not_supported(style : Int, from : SqlType, to : SqlType) -> SqlError {
  sql_error(
    9809,
    "The style \{style} is not supported for conversions from \{from.base_name()} to \{to.base_name()}.",
  )
}

///|
fn pad2s(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn money_text(units : Int64, style : Int) -> String {
  let d = Decimal::new(@bigint.BigInt::from_int64(units), 4)
  match style {
    0 | 1 => {
      let s = d.rescale(2).to_string()
      if style == 0 {
        s
      } else {
        // thousands separators in the integer part
        let negative = s.has_prefix("-")
        let body = if negative {
          s.unsafe_substring(start=1, end=s.length())
        } else {
          s
        }
        let dot = body.length() - 3
        let int_part = body.unsafe_substring(start=0, end=dot)
        let sb = StringBuilder()
        for i in 0..<int_part.length() {
          if i > 0 && (int_part.length() - i) % 3 == 0 {
            sb.write_char(',')
          }
          sb.write_char(int_part[i].to_int().unsafe_to_char())
        }
        (if negative { "-" } else { "" }) +
        sb.to_string() +
        body.unsafe_substring(start=dot, end=body.length())
      }
    }
    2 | 126 => d.to_string()
    // captured: any other style number is style 0
    _ => d.rescale(2).to_string()
  }
}

///|
/// Text of a non-character value for a CONVERT style (None = CAST).
pub fn render(
  v : Value,
  from : SqlType,
  style : Int?,
  target? : String = "varchar",
  dates? : DateSettings = default_date_settings,
) -> String raise SqlError {
  match v {
    Vector(data) => data.to_text()
    Null => raise internal("render of NULL")
    String(s) => s
    Bit(b) => if b { "1" } else { "0" }
    TinyInt(n) | SmallInt(n) | Int(n) => n.to_string()
    BigInt(n) => n.to_string()
    Decimal(d) => d.to_string()
    Money(u) => money_text(u, style.unwrap_or(0))
    Float(d) =>
      match style.unwrap_or(0) {
        0 => format_float_general(d)
        // captured (harness/corpus/conversion/float-styles): 1 is 8
        // significant digits, 2 is 16, 3 is 17 (real too, of its double
        // value), 126 is 16 for float but 8 for real; every other style
        // number is style 0
        1 => format_float_scientific(d, 8)
        2 => format_float_scientific(d, 16)
        3 => format_float_scientific(d, 17)
        126 => format_float_scientific(d, if from is Real { 8 } else { 16 })
        _ => format_float_general(d)
      }
    Guid(b) => format_guid(b)
    Binary(b) =>
      match style.unwrap_or(0) {
        1 => "0x" + hex_upper(b)
        2 => hex_upper(b)
        _ => cp1252_string(b)
      }
    Date(_)
    | Time(_)
    | DateTime2(_)
    | DateTimeOffset(_, _)
    | DateTime(_, _)
    | SmallDateTime(_, _) => render_temporal(v, from, style, target~, dates~)
    Variant(_, _) => raise internal("render of a sql_variant")
    Xml(x) => x.to_text()
  }
}

///|
fn hex_upper(b : Bytes) -> String {
  let digits = "0123456789ABCDEF"
  let sb = StringBuilder()
  for x in b {
    sb.write_char(digits[x.to_int() / 16].to_int().unsafe_to_char())
    sb.write_char(digits[x.to_int() % 16].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// Binary as UTF-16LE text (odd final byte padded with a zero high byte).
fn utf16le_string(b : Bytes) -> String {
  let sb = StringBuilder()
  let n = b.length()
  let mut i = 0
  while i < n {
    let lo = b[i].to_int()
    let hi = if i + 1 < n { b[i + 1].to_int() } else { 0 }
    sb.write_char((hi * 256 + lo).unsafe_to_char())
    i += 2
  }
  sb.to_string()
}

///|
fn utf16le_bytes(s : String) -> Bytes {
  Bytes::makei(s.length() * 2, fn(i) {
    let u = s[i / 2].to_int()
    (if i % 2 == 0 { u % 256 } else { u / 256 }).to_byte()
  })
}

///|
fn char_capacity(t : SqlType) -> Int? {
  match t {
    Char(n, _) | NChar(n, _) => Some(n)
    VarChar(n, _) | NVarChar(n, _) => n
    _ => None
  }
}

///|
fn to_character(
  v : Value,
  from : SqlType,
  to : SqlType,
  style : Int?,
  dates : DateSettings,
) -> Value raise SqlError {
  let text = match v {
    String(s) => s
    Binary(b) if style.unwrap_or(0) == 0 =>
      if to.is_unicode() {
        utf16le_string(b)
      } else if to.collation().map(c => c.utf8()).unwrap_or(false) {
        utf8_text(b)
      } else {
        cp1252_string(b)
      }
    Binary(_) if !(style.unwrap_or(0) is (1 | 2)) =>
      raise style_not_supported(style.unwrap_or(0), from, to)
    _ => render(v, from, style, target=to.base_name(), dates~)
  }
  // varchar under a UTF-8 collation: capacity and padding count UTF-8
  // bytes, a cut keeps whole characters (captured: settings/utf8)
  let utf8 = !to.is_unicode() &&
    to.collation().map(c => c.utf8()).unwrap_or(false)
  let text = if to.is_unicode() {
    text
  } else if utf8 {
    to_code_page(text, to.collation().unwrap_or(default_collation))
  } else {
    to_cp1252(text)
  }
  let mut out = text
  let size = (s : String) => if utf8 { utf8_length(s) } else { s.length() }
  match char_capacity(to) {
    Some(cap) if utf8 && size(text) > cap =>
      out = match from.family() {
        FBit | FInteger => "*"
        FDecimal | FMoney | FFloat => raise overflow_from(from, to)
        FGuid =>
          raise sql_error(
            8170, "Insufficient result space to convert uniqueidentifier value to char.",
          )
        _ => utf8_prefix(text, cap)
      }
    Some(cap) if text.length() > cap =>
      out = match from.family() {
        FBit | FInteger =>
          if to.is_unicode() {
            // captured: "Arithmetic overflow error converting expression to
            // data type nvarchar."
            raise overflow_expression(to)
          } else {
            "*"
          }
        FDecimal | FMoney | FFloat => raise overflow_from(from, to)
        FGuid =>
          raise sql_error(
            8170, "Insufficient result space to convert uniqueidentifier value to char.",
          )
        // hex text keeps whole bytes (captured: 0x0A0B as varchar(3),
        // style 1, is `0x`; 0x0A0B0C, style 2, is `0A`)
        FBinary if style.unwrap_or(0) is (1 | 2) =>
          text.unsafe_substring(start=0, end=cap - cap % 2)
        _ => text.unsafe_substring(start=0, end=cap)
      }
    _ => ()
  }
  match to {
    Char(n, _) | NChar(n, _) if size(out) < n =>
      out = out + String::make(n - size(out), ' ')
    _ => ()
  }
  String(out)
}

///|
fn parse_hex(s : String, start : Int) -> Bytes? {
  let n = s.length() - start
  if n < 0 || n % 2 != 0 {
    return None
  }
  let out = FixedArray::make(n / 2, b'\x00')
  for i in 0..<(n / 2) {
    match (hex_value(s[start + 2 * i]), hex_value(s[start + 2 * i + 1])) {
      (Some(hi), Some(lo)) => out[i] = (hi * 16 + lo).to_byte()
      _ => return None
    }
  }
  Some(Bytes::from_array(out[:]))
}

///|
fn big_endian(n : Int64, width : Int) -> Bytes {
  Bytes::makei(width, fn(i) {
    (n >> (8 * (width - 1 - i))).to_int().land(0xFF).to_byte()
  })
}

///|
fn to_binary(
  v : Value,
  from : SqlType,
  to : SqlType,
  style : Int?,
) -> Value raise SqlError {
  let (bytes, left_aligned) = match v {
    String(s) =>
      match style.unwrap_or(0) {
        0 =>
          (
            if from.is_unicode() {
              utf16le_bytes(s)
            } else if from.collation().map(c => c.utf8()).unwrap_or(false) {
              utf8_bytes(s)
            } else {
              cp1252_bytes(s)
            },
            false,
          )
        1 | 2 => {
          let st = style.unwrap()
          let ok = if st == 1 {
            s.has_prefix("0x") || s.has_prefix("0X")
          } else {
            true
          }
          match (ok, parse_hex(s, if st == 1 { 2 } else { 0 })) {
            (true, Some(b)) => (b, false)
            _ => raise error_converting(from, to)
          }
        }
        st => raise style_not_supported(st, from, to)
      }
    Binary(b) => (b, false)
    Guid(b) => (b, false)
    Bit(b) => (big_endian(if b { 1L } else { 0L }, 1), true)
    TinyInt(n) => (big_endian(n.to_int64(), 1), true)
    SmallInt(n) => (big_endian(n.to_int64(), 2), true)
    Int(n) => (big_endian(n.to_int64(), 4), true)
    BigInt(n) => (big_endian(n, 8), true)
    DateTime(d, u) => {
      let a = big_endian(d.to_int64(), 4)
      let b = big_endian(u.to_int64(), 4)
      (Bytes::makei(8, fn(i) { if i < 4 { a[i] } else { b[i - 4] } }), true)
    }
    SmallDateTime(d, m) => {
      let a = big_endian(d.to_int64(), 2)
      let b = big_endian(m.to_int64(), 2)
      (Bytes::makei(4, fn(i) { if i < 2 { a[i] } else { b[i - 2] } }), true)
    }
    Date(_) | Time(_) | DateTime2(_) | DateTimeOffset(_, _) => {
      let b = temporal_storage_bytes(v, from)
      let cap = match to {
        Binary(k) | VarBinary(Some(k)) => Some(k)
        _ => None
      }
      match cap {
        Some(k) if k < b.length() =>
          // a cut date keeps its head under CONVERT but is NULL under
          // TRY_CONVERT (captured): not modelled; the scale-prefixed
          // types are 8152 state 17
          if v is Date(_) {
            raise not_supported(
              "CONVERT of date to a shorter binary type",
              number=EMU_CONVERSION_NOT_SUPPORTED,
            )
          } else {
            raise sql_error(
              8152,
              "String or binary data would be truncated.",
              state=17,
            )
          }
        _ => ()
      }
      (b, false)
    }
    Float(_) | Money(_) | Decimal(_) =>
      match numeric_storage_bytes(v, from) {
        Some(x) => x
        None => raise conversion_unsupported(from, to)
      }
    _ => raise conversion_unsupported(from, to)
  }
  // decimal storage keeps its head when cut but is padded on the left
  let pad_left = left_aligned || v is Decimal(_)
  let n = bytes.length()
  let fixed = match to {
    Binary(k) => Some(k)
    RowVersion => Some(8)
    _ => None
  }
  let cap = match to {
    VarBinary(Some(k)) => Some(k)
    _ => fixed
  }
  let fitted = match cap {
    Some(k) if n > k =>
      if left_aligned {
        Bytes::makei(k, fn(i) { bytes[n - k + i] })
      } else {
        Bytes::makei(k, fn(i) { bytes[i] })
      }
    _ => bytes
  }
  match fixed {
    Some(k) if fitted.length() < k => {
      let m = fitted.length()
      Binary(
        if pad_left {
          Bytes::makei(k, fn(i) {
            if i < k - m {
              b'\x00'
            } else {
              fitted[i - (k - m)]
            }
          })
        } else {
          Bytes::makei(k, fn(i) { if i < m { fitted[i] } else { b'\x00' } })
        },
      )
    }
    _ => Binary(fitted)
  }
}

///|
/// Storage bytes of date, time, datetime2 and datetimeoffset values as
/// CONVERT(varbinary, x) shows them: date = 3 bytes of days since
/// 0001-01-01 (little-endian); the others start with their scale, then the
/// time of day in units of 10^-scale s (3 bytes for scale 0-2, 4 for 3-4,
/// 5 for 5-7), then the date, then (datetimeoffset, UTC) the offset in
/// minutes as int16 (captured: msduck temporal-guid-format, corpus
/// tail/functions-binary).
fn temporal_storage_bytes(v : Value, from : SqlType) -> Bytes {
  let scale = match from {
    Time(s) | DateTime2(s) | DateTimeOffset(s) => s
    _ => 7
  }
  let out : Array[Int] = []
  let le = (n : Int64, width : Int) => {
    for i in 0..<width {
      out.push((n >> (8 * i)).to_int() & 0xFF)
    }
  }
  let time_part = (ticks : Int64) => {
    out.push(scale)
    let mut unit = 1L
    for _ in 0..<(7 - scale) {
      unit = unit * 10L
    }
    let width = if scale <= 2 { 3 } else if scale <= 4 { 4 } else { 5 }
    le(ticks / unit, width)
  }
  match v {
    Date(d) => le(d.to_int64(), 3)
    Time(t) => time_part(t)
    DateTime2(x) => {
      time_part(x % TICKS_PER_DAY)
      le(x / TICKS_PER_DAY, 3)
    }
    DateTimeOffset(utc, off) => {
      time_part(utc % TICKS_PER_DAY)
      le(utc / TICKS_PER_DAY, 3)
      le(off.to_int64(), 2)
    }
    _ => ()
  }
  Bytes::makei(out.length(), i => out[i].to_byte())
}
