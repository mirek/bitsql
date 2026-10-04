// The SQL Server 2025 `json` data type.
//
// SQL Server stores json values in a binary format and sends them to TDS 7.4
// clients as varchar(max) with collation Latin1_General_100_BIN2_UTF8. bitsql
// keeps a json value as `Value::String` holding the canonical text SQL Server
// prints back. Rules captured on 17.0.5005.3 (harness/corpus/json4/*.sql,
// docs/reference/json.md "The json data type"):
//
// - The root must be an object or an array; whitespace (space, tab, LF, CR)
//   is dropped; duplicate member names keep the first member (also nested).
// - Strings are re-escaped: `"` and `\`, \b \f \n \r \t, other control
//   characters as \u00XX (upper-case hex); everything else (also `/`, DEL,
//   U+2028) raw; a lone surrogate, raw or escaped, becomes U+FFFD.
// - Numbers without exponent and at most 38 significant digits keep their
//   text (scale included; `-0` → `0`). Others convert through float to
//   decimal(38,10): `1e2` → `100.0000000000`; more than 28 integer digits
//   is 1007 state 5, a 39+ digit integer 1007 state 3.
// - Errors: 13609 state 9 with the 0-based **UTF-8 byte** position (the
//   character shown is that byte as Latin-1, `.` at the end); errors inside
//   a string point at its opening quote, malformed numbers and literals at
//   their first character; nesting beyond 128 is 13645.

///|
/// Collation json values carry on the wire and in describe output.
pub let json_collation : Collation = Collation::parse(
  "Latin1_General_100_BIN2_UTF8",
).unwrap()

///|
priv struct JsonTypeParser {
  b : Bytes
  mut pos : Int
}

///|
fn JsonTypeParser::fail_at(self : JsonTypeParser, pos : Int) -> SqlError {
  let c = if pos < self.b.length() {
    self.b[pos].to_int().unsafe_to_char().to_string()
  } else {
    "."
  }
  sql_error(
    13609,
    "JSON text is not properly formatted. Unexpected character '\{c}' is found at position \{pos}.",
    state=9,
  )
}

///|
fn JsonTypeParser::peek(self : JsonTypeParser) -> Int {
  if self.pos < self.b.length() {
    self.b[self.pos].to_int()
  } else {
    -1
  }
}

///|
fn JsonTypeParser::ws(self : JsonTypeParser) -> Unit {
  while self.peek() is (0x20 | 0x09 | 0x0A | 0x0D) {
    self.pos += 1
  }
}

///|
fn json_type_depth_error() -> SqlError {
  sql_error(13645, "Nested level of JSON document exceeds limit 128.")
}

///|
/// Canonical text of a json value parsed from `text` (CAST/assignment of a
/// character value to json).
pub fn json_type_normalize(text : String) -> String raise SqlError {
  let p : JsonTypeParser = {
    b: utf8_bytes(replace_lone_surrogates(text)),
    pos: 0,
  }
  p.ws()
  if !(p.peek() is (0x7B | 0x5B)) {
    raise p.fail_at(p.pos)
  }
  let out = StringBuilder()
  p.value(out, 0)
  p.ws()
  if p.pos < p.b.length() {
    raise p.fail_at(p.pos)
  }
  out.to_string()
}

///|
fn replace_lone_surrogates(s : String) -> String {
  let n = s.length()
  let mut clean = true
  let mut i = 0
  while i < n {
    let u = s.code_unit_at(i).to_int()
    if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
      let lo = s.code_unit_at(i + 1).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        i += 2
        continue
      }
    }
    if u >= 0xD800 && u <= 0xDFFF {
      clean = false
      break
    }
    i += 1
  }
  if clean {
    return s
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    let u = s.code_unit_at(i).to_int()
    if u >= 0xD800 && u <= 0xDBFF && i + 1 < n {
      let lo = s.code_unit_at(i + 1).to_int()
      if lo >= 0xDC00 && lo <= 0xDFFF {
        sb.write_char(s.code_unit_at(i).to_int().unsafe_to_char())
        sb.write_char(lo.unsafe_to_char())
        i += 2
        continue
      }
    }
    if u >= 0xD800 && u <= 0xDFFF {
      sb.write_char('\u{FFFD}')
    } else {
      sb.write_char(u.unsafe_to_char())
    }
    i += 1
  }
  sb.to_string()
}

///|
fn JsonTypeParser::value(
  self : JsonTypeParser,
  out : StringBuilder,
  depth : Int,
) -> Unit raise SqlError {
  match self.peek() {
    0x7B => {
      if depth >= 128 {
        raise json_type_depth_error()
      }
      self.pos += 1
      self.ws()
      out.write_char('{')
      if self.peek() == 0x7D {
        self.pos += 1
        out.write_char('}')
        return
      }
      let seen : Set[String] = Set([])
      let mut first = true
      while true {
        if self.peek() != 0x22 {
          raise self.fail_at(self.pos)
        }
        let key = self.string()
        self.ws()
        if self.peek() != 0x3A {
          raise self.fail_at(self.pos)
        }
        self.pos += 1
        self.ws()
        let v = StringBuilder()
        self.value(v, depth + 1)
        if !seen.contains(key) {
          seen.add(key)
          if !first {
            out.write_char(',')
          }
          first = false
          write_json_type_string(out, key)
          out.write_char(':')
          out.write_string(v.to_string())
        }
        self.ws()
        match self.peek() {
          0x2C => {
            self.pos += 1
            self.ws()
          }
          0x7D => {
            self.pos += 1
            break
          }
          _ => raise self.fail_at(self.pos)
        }
      }
      out.write_char('}')
    }
    0x5B => {
      if depth >= 128 {
        raise json_type_depth_error()
      }
      self.pos += 1
      self.ws()
      out.write_char('[')
      if self.peek() == 0x5D {
        self.pos += 1
        out.write_char(']')
        return
      }
      let mut first = true
      while true {
        if !first {
          out.write_char(',')
        }
        first = false
        self.value(out, depth + 1)
        self.ws()
        match self.peek() {
          0x2C => {
            self.pos += 1
            self.ws()
          }
          0x5D => {
            self.pos += 1
            break
          }
          _ => raise self.fail_at(self.pos)
        }
      }
      out.write_char(']')
    }
    0x22 => write_json_type_string(out, self.string())
    0x74 => self.literal("true", out)
    0x66 => self.literal("false", out)
    0x6E => self.literal("null", out)
    c if c == 0x2D || (c >= 0x30 && c <= 0x39) =>
      out.write_string(self.number())
    _ => raise self.fail_at(self.pos)
  }
}

///|
fn JsonTypeParser::literal(
  self : JsonTypeParser,
  word : String,
  out : StringBuilder,
) -> Unit raise SqlError {
  let start = self.pos
  for i in 0..<word.length() {
    if start + i >= self.b.length() ||
      self.b[start + i].to_int() != word.code_unit_at(i).to_int() {
      raise self.fail_at(start)
    }
  }
  self.pos = start + word.length()
  out.write_string(word)
}

///|
fn hex_digit(c : Int) -> Int {
  if c >= 0x30 && c <= 0x39 {
    c - 0x30
  } else if c >= 0x41 && c <= 0x46 {
    c - 0x41 + 10
  } else if c >= 0x61 && c <= 0x66 {
    c - 0x61 + 10
  } else {
    -1
  }
}

///|
/// A string token starting at `"`; returns the decoded text. Any error
/// inside it is reported at the opening quote (captured).
fn JsonTypeParser::string(self : JsonTypeParser) -> String raise SqlError {
  let start = self.pos
  self.pos += 1
  let sb = StringBuilder()
  let n = self.b.length()
  // a pending high surrogate from a \u escape
  let mut high = -1
  let flush_high = () => {
    if high >= 0 {
      sb.write_char('\u{FFFD}')
      high = -1
    }
  }
  while true {
    if self.pos >= n {
      raise self.fail_at(start)
    }
    let c = self.b[self.pos].to_int()
    if c == 0x22 {
      self.pos += 1
      break
    }
    if c < 0x20 {
      raise self.fail_at(start)
    }
    if c == 0x5C {
      if self.pos + 1 >= n {
        raise self.fail_at(start)
      }
      let e = self.b[self.pos + 1].to_int()
      self.pos += 2
      let ch = match e {
        0x22 => 0x22
        0x5C => 0x5C
        0x2F => 0x2F
        0x62 => 0x08
        0x66 => 0x0C
        0x6E => 0x0A
        0x72 => 0x0D
        0x74 => 0x09
        0x75 => {
          if self.pos + 4 > n {
            raise self.fail_at(start)
          }
          let mut v = 0
          for k in 0..<4 {
            let d = hex_digit(self.b[self.pos + k].to_int())
            if d < 0 {
              raise self.fail_at(start)
            }
            v = v * 16 + d
          }
          self.pos += 4
          v
        }
        _ => raise self.fail_at(start)
      }
      if ch >= 0xD800 && ch <= 0xDBFF {
        flush_high()
        high = ch
      } else if ch >= 0xDC00 && ch <= 0xDFFF {
        if high >= 0 {
          sb.write_char(high.unsafe_to_char())
          sb.write_char(ch.unsafe_to_char())
          high = -1
        } else {
          sb.write_char('\u{FFFD}')
        }
      } else {
        flush_high()
        sb.write_char(ch.unsafe_to_char())
      }
      continue
    }
    flush_high()
    // a UTF-8 sequence (the bytes came from valid UTF-16)
    let (cp, len) = if c < 0x80 {
      (c, 1)
    } else if c < 0xE0 {
      (((c & 0x1F) << 6) | (self.b[self.pos + 1].to_int() & 0x3F), 2)
    } else if c < 0xF0 {
      (
        ((c & 0x0F) << 12) |
        ((self.b[self.pos + 1].to_int() & 0x3F) << 6) |
        (self.b[self.pos + 2].to_int() & 0x3F),
        3,
      )
    } else {
      (
        ((c & 0x07) << 18) |
        ((self.b[self.pos + 1].to_int() & 0x3F) << 12) |
        ((self.b[self.pos + 2].to_int() & 0x3F) << 6) |
        (self.b[self.pos + 3].to_int() & 0x3F),
        4,
      )
    }
    self.pos += len
    sb.write_char(cp.unsafe_to_char())
  }
  flush_high()
  sb.to_string()
}

///|
/// A JSON string in the json type's canonical escaping.
fn write_json_type_string(out : StringBuilder, s : String) -> Unit {
  out.write_char('"')
  for i in 0..<s.length() {
    let u = s.code_unit_at(i).to_int()
    match u {
      0x22 => out.write_string("\\\"")
      0x5C => out.write_string("\\\\")
      0x08 => out.write_string("\\b")
      0x0C => out.write_string("\\f")
      0x0A => out.write_string("\\n")
      0x0D => out.write_string("\\r")
      0x09 => out.write_string("\\t")
      _ if u < 0x20 => {
        let h = u.to_string(radix=16).to_upper()
        out.write_string(
          "\\u" + "0000".unsafe_substring(start=0, end=4 - h.length()) + h,
        )
      }
      _ => out.write_char(u.unsafe_to_char())
    }
  }
  out.write_char('"')
}

///|
/// A number token: canonical text, or 1007 / 13609.
fn JsonTypeParser::number(self : JsonTypeParser) -> String raise SqlError {
  let start = self.pos
  let b = self.b
  let n = b.length()
  let digit = (i : Int) => i < n && b[i] >= b'0' && b[i] <= b'9'
  let mut i = start
  if i < n && b[i] == b'-' {
    i += 1
  }
  if !digit(i) {
    raise self.fail_at(start)
  }
  let int_start = i
  if b[i] == b'0' {
    i += 1
    if digit(i) {
      raise self.fail_at(start)
    }
  } else {
    while digit(i) {
      i += 1
    }
  }
  let int_digits = if i - int_start == 1 && b[int_start] == b'0' {
    0
  } else {
    i - int_start
  }
  let mut frac_digits = 0
  let mut has_frac = false
  if i < n && b[i] == b'.' {
    i += 1
    if !digit(i) {
      raise self.fail_at(start)
    }
    has_frac = true
    while digit(i) {
      i += 1
      frac_digits += 1
    }
  }
  let mut has_exp = false
  if i < n && (b[i] == b'e' || b[i] == b'E') {
    i += 1
    if i < n && (b[i] == b'+' || b[i] == b'-') {
      i += 1
    }
    if !digit(i) {
      raise self.fail_at(start)
    }
    has_exp = true
    while digit(i) {
      i += 1
    }
  }
  self.pos = i
  let lexeme = utf8_text(b[start:i])
  let out_of_range = (state : Int) => {
    sql_error(
      1007,
      "The number '\{lexeme}' is out of the range for numeric representation (maximum precision 38).",
      state~,
    )
  }
  if !has_exp && int_digits + frac_digits <= 38 {
    match Decimal::parse(lexeme) {
      Some(d) => return d.to_string()
      None => raise self.fail_at(start)
    }
  }
  if !has_exp && !has_frac {
    raise out_of_range(3)
  }
  let d = @string.parse_double(lexeme) catch { _ => raise out_of_range(5) }
  match json_type_decimal(d) {
    Some(t) => t
    None => raise out_of_range(5)
  }
}

///|
/// A float as the json type stores it: decimal(38,10), or None when it
/// does not fit (more than 28 integer digits, or not finite).
pub fn json_type_decimal(d : Double) -> String? {
  if d.is_nan() || d.is_inf() {
    return None
  }
  let x = Decimal::from_double_exact(d).rescale(10)
  if x.digits() > 38 {
    None
  } else {
    Some(x.to_string())
  }
}

///|
/// json → char/varchar/nchar/nvarchar: the text, or 13640 when a character
/// has no exact equivalent in the target code page, 13639 when the target
/// is too short (checked in that order; captured json4 probes). Fixed
/// targets are padded.
pub fn json_type_to_text(text : String, to : SqlType) -> String raise SqlError {
  let coll = to.collation().unwrap_or(default_collation)
  let mut text = text
  let size = if to.is_unicode() {
    text.length()
  } else if coll.utf8() {
    utf8_length(text)
  } else {
    // best fit applies (U+0100 is 'A', captured); a character without any
    // mapping (it would become '?') is 13640
    let mapped = to_code_page(text, coll)
    let mut lost = mapped.length() != text.length()
    for i in 0..<text.length() {
      if !lost && mapped.code_unit_at(i) == '?' && text.code_unit_at(i) != '?' {
        lost = true
      }
    }
    text = mapped
    if lost {
      raise sql_error(
        13640,
        "Conversion of one or more characters from the JSON instance to target codepage \{coll.code_page} will result in data loss. Choose a different target collation or use nvarchar.",
      )
    }
    text.length()
  }
  match to {
    Char(n, _) | VarChar(Some(n), _) | NChar(n, _) | NVarChar(Some(n), _) if size >
      n =>
      raise sql_error(
        13639, "Target string size is too small to represent the JSON instance.",
      )
    Char(n, _) | NChar(n, _) if size < n => text + String::make(n - size, ' ')
    _ => text
  }
}
