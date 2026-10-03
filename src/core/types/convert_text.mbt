// Conversions to character and binary types, and value → text rendering
// (CONVERT styles).

///|
fn style_unsupported(style : Int, from : SqlType) -> SqlError {
  not_supported(
    "CONVERT style \{style} for \{from.base_name()}",
    number=EMU_STYLE_NOT_SUPPORTED,
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
/// Text of a temporal value for a CONVERT style (None = CAST).
///
/// Captured (msduck reference/temporal-guid-format.json, us_english):
/// CAST of date/time/datetime2/datetimeoffset is ISO with the declared
/// number of fraction digits (`2024-03-01 00:00:00.00 +01:30`); CAST of
/// datetime/smalldatetime and style 0 of everything is `Mon dd yyyy
/// hh:miAM` (`Jan  2 2024  3:04AM`, time alone `11:59PM`); style 121 is
/// ISO with the declared fraction digits (3 for datetime/smalldatetime).
/// Styles 1-12/101-112, 20/120, 23, 8/108, 126 and 127 follow the CONVERT
/// documentation and are unverified. Month names are us_english only.
pub fn render_temporal(
  v : Value,
  from : SqlType,
  style : Int?,
) -> String raise SqlError {
  let inst = instant_of(v, from)
  let days = inst.days.unwrap_or(DAYS_TO_1900)
  // display ticks: legacy datetime shows whole milliseconds
  let time = match v {
    DateTime(_, u) => {
      let sec = u / 300
      let ms = (u % 300 * 10 + 1) / 3
      sec.to_int64() * TICKS_PER_SECOND + ms.to_int64() * 10_000L
    }
    _ => inst.time.unwrap_or(0L)
  }
  let digits = match from {
    Time(s) | DateTime2(s) | DateTimeOffset(s) => s
    _ => 3
  }
  let date_only = from is Date
  let time_only = from is Time(_)
  let offset_text = match inst.offset {
    Some(o) => " " + format_offset(o)
    None => ""
  }
  let iso = fn(fraction_digits : Int, sep : String) -> String {
    if date_only {
      format_date_iso(days)
    } else if time_only {
      format_time_iso(time, fraction_digits)
    } else {
      format_date_iso(days) + sep + format_time_iso(time, fraction_digits)
    }
  }
  let (y, m, d) = civil_from_days(days)
  let yyyy = format_date_iso(days).unsafe_substring(start=0, end=4)
  let yy = yyyy.unsafe_substring(start=2, end=4)
  let mm = pad2s(m)
  let dd = pad2s(d)
  ignore(y)
  match style {
    None =>
      match from {
        DateTime | SmallDateTime => render_temporal(v, from, Some(0))
        _ => iso(digits, " ") + offset_text
      }
    Some(0 | 100) =>
      if date_only {
        format_date_style0(days)
      } else if time_only {
        format_time_style0(time)
      } else {
        format_date_style0(days) + " " + format_time_style0(time) + offset_text
      }
    Some(20 | 120) => {
      if inst.offset is Some(_) {
        raise style_unsupported(style.unwrap(), from)
      }
      iso(0, " ")
    }
    Some(21 | 25 | 121) => iso(digits, " ") + offset_text
    Some(23) => format_date_iso(days)
    Some(126) => {
      if inst.offset is Some(_) {
        raise style_unsupported(126, from)
      }
      match from {
        DateTime | SmallDateTime =>
          iso(if time % TICKS_PER_SECOND == 0L { 0 } else { 3 }, "T")
        _ => iso(digits, "T")
      }
    }
    Some(127) =>
      match v {
        DateTimeOffset(utc, _) => {
          let ud = (utc / TICKS_PER_DAY).to_int()
          let ut = utc % TICKS_PER_DAY
          format_date_iso(ud) +
          "T" +
          format_time_iso(
            ut,
            if ut % TICKS_PER_SECOND == 0L {
              0
            } else {
              digits
            },
          ) +
          "Z"
        }
        _ => render_temporal(v, from, Some(126))
      }
    Some(1) => mm + "/" + dd + "/" + yy
    Some(101) => mm + "/" + dd + "/" + yyyy
    Some(2) => yy + "." + mm + "." + dd
    Some(102) => yyyy + "." + mm + "." + dd
    Some(3) => dd + "/" + mm + "/" + yy
    Some(103) => dd + "/" + mm + "/" + yyyy
    Some(4) => dd + "." + mm + "." + yy
    Some(104) => dd + "." + mm + "." + yyyy
    Some(5) => dd + "-" + mm + "-" + yy
    Some(105) => dd + "-" + mm + "-" + yyyy
    Some(10) => mm + "-" + dd + "-" + yy
    Some(110) => mm + "-" + dd + "-" + yyyy
    Some(11) => yy + "/" + mm + "/" + dd
    Some(111) => yyyy + "/" + mm + "/" + dd
    Some(12) => yy + mm + dd
    Some(112) => yyyy + mm + dd
    Some(8 | 24 | 108) => format_time_iso(time, 0)
    Some(s) => raise style_unsupported(s, from)
  }
}

///|
fn money_text(
  units : Int64,
  style : Int,
  from : SqlType,
) -> String raise SqlError {
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
    _ => raise style_unsupported(style, from)
  }
}

///|
/// Text of a non-character value for a CONVERT style (None = CAST).
pub fn render(v : Value, from : SqlType, style : Int?) -> String raise SqlError {
  match v {
    Null => raise internal("render of NULL")
    String(s) => s
    Bit(b) => if b { "1" } else { "0" }
    TinyInt(n) | SmallInt(n) | Int(n) => n.to_string()
    BigInt(n) => n.to_string()
    Decimal(d) => d.to_string()
    Money(u) => money_text(u, style.unwrap_or(0), from)
    Float(d) =>
      match style.unwrap_or(0) {
        0 => format_float_general(d)
        1 => format_float_scientific(d, 8)
        2 => format_float_scientific(d, 16)
        s => raise style_unsupported(s, from)
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
    | SmallDateTime(_, _) => render_temporal(v, from, style)
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
) -> Value raise SqlError {
  let text = match v {
    String(s) => s
    Binary(b) if style.unwrap_or(0) == 0 =>
      if to.is_unicode() {
        utf16le_string(b)
      } else {
        cp1252_string(b)
      }
    _ => render(v, from, style)
  }
  let text = if to.is_unicode() { text } else { to_cp1252(text) }
  let mut out = text
  match char_capacity(to) {
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
        _ => text.unsafe_substring(start=0, end=cap)
      }
    _ => ()
  }
  match to {
    Char(n, _) | NChar(n, _) if out.length() < n =>
      out = out + String::make(n - out.length(), ' ')
    _ => ()
  }
  String(out)
}

///|
fn parse_hex(s : String, start : Int) -> Bytes? {
  let n = s.length() - start
  if n % 2 != 0 {
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
        st => raise style_unsupported(st, from)
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
    _ => raise conversion_unsupported(from, to)
  }
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
        if left_aligned {
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
