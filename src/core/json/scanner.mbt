///|
/// Maximum nesting of values (SQL Server: a value inside 129 containers fails).
pub const MAX_DEPTH : Int = 128

///|
pub(all) enum Kind {
  Null // 0
  String // 1
  Number // 2
  Boolean // 3
  Array // 4
  Object // 5
} derive(Debug, Eq)

///|
pub fn Kind::code(self : Kind) -> Int {
  match self {
    Null => 0
    String => 1
    Number => 2
    Boolean => 3
    Array => 4
    Object => 5
  }
}

///|
/// Streaming JSON scanner over UTF-16 text. Like SQL Server it validates
/// lazily: callers only scan what they need, so malformed text after a match
/// is never seen. `doc_state` is the state number used for 13609 errors.
priv struct Scanner {
  text : String
  mut pos : Int
  doc_state : Int
}

///|
fn Scanner::peek(self : Scanner) -> Int {
  if self.pos < self.text.length() {
    self.text.code_unit_at(self.pos).to_int()
  } else {
    -1
  }
}

///|
fn Scanner::fail(self : Scanner) -> JsonError {
  JsonError(13609, self.doc_state, unexpected("text", self.text, self.pos))
}

///|
fn Scanner::ws(self : Scanner) -> Unit {
  while true {
    match self.peek() {
      0x20 | 0x09 | 0x0A | 0x0D => self.pos += 1
      _ => break
    }
  }
}

///|
fn Scanner::expect(self : Scanner, c : Int) -> Unit raise JsonError {
  if self.peek() != c {
    raise self.fail()
  }
  self.pos += 1
}

///|
fn Scanner::kind_at(self : Scanner) -> Kind raise JsonError {
  match self.peek() {
    0x7B => Object
    0x5B => Array
    0x22 => String
    0x74 | 0x66 => Boolean
    0x6E => Null
    0x2D | 0x30..=0x39 => Number
    _ => raise self.fail()
  }
}

///|
fn check_depth(depth : Int) -> Unit raise JsonError {
  if depth > MAX_DEPTH {
    raise JsonError(13606, 1, DEPTH_MESSAGE)
  }
}

///|
/// Scans one value starting at `pos` (no leading whitespace), validating it
/// entirely. `depth` is the number of enclosing containers. Nesting is
/// checked lazily like SQL Server (msduck isjson-depth, json3 probes): a
/// container opened inside 129 containers fails at once, while a scalar or
/// a member name inside 129 containers fails only once it is complete (so
/// `x` or an unterminated string there is a 13609 instead).
fn Scanner::skip_value(self : Scanner, depth : Int) -> Kind raise JsonError {
  let kind = self.kind_at()
  match kind {
    Object => {
      check_depth(depth)
      self.pos += 1
      self.ws()
      if self.peek() == 0x7D {
        self.pos += 1
        return kind
      }
      while true {
        ignore(self.string_value())
        check_depth(depth + 1)
        self.ws()
        self.expect(0x3A)
        self.ws()
        ignore(self.skip_value(depth + 1))
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
          _ => raise self.fail()
        }
      }
    }
    Array => {
      check_depth(depth)
      self.pos += 1
      self.ws()
      if self.peek() == 0x5D {
        self.pos += 1
        return kind
      }
      while true {
        ignore(self.skip_value(depth + 1))
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
          _ => raise self.fail()
        }
      }
    }
    String => {
      ignore(self.string_value())
      check_depth(depth)
    }
    Boolean => {
      if self.peek() == 0x74 {
        self.literal("true")
      } else {
        self.literal("false")
      }
      check_depth(depth)
    }
    Null => {
      self.literal("null")
      check_depth(depth)
    }
    Number => {
      self.number()
      check_depth(depth)
    }
  }
  kind
}

///|
fn Scanner::literal(self : Scanner, word : String) -> Unit raise JsonError {
  for i in 0..<word.length() {
    if self.peek() != word.code_unit_at(i).to_int() {
      raise self.fail()
    }
    self.pos += 1
  }
}

///|
fn Scanner::digits(self : Scanner) -> Int {
  let start = self.pos
  while self.peek() is (0x30..=0x39) {
    self.pos += 1
  }
  self.pos - start
}

///|
fn Scanner::number(self : Scanner) -> Unit raise JsonError {
  if self.peek() == 0x2D {
    self.pos += 1
  }
  if self.peek() == 0x30 {
    self.pos += 1
  } else if self.digits() == 0 {
    raise self.fail()
  }
  if self.peek() == 0x2E {
    self.pos += 1
    if self.digits() == 0 {
      raise self.fail()
    }
  }
  if self.peek() is (0x65 | 0x45) {
    self.pos += 1
    if self.peek() is (0x2B | 0x2D) {
      self.pos += 1
    }
    if self.digits() == 0 {
      raise self.fail()
    }
  }
}

///|
fn hex_digit(c : Int) -> Int {
  match c {
    0x30..=0x39 => c - 0x30
    0x61..=0x66 => c - 0x61 + 10
    0x41..=0x46 => c - 0x41 + 10
    _ => -1
  }
}

///|
/// Scans a string at `pos` and returns it decoded.
fn Scanner::string_value(self : Scanner) -> String raise JsonError {
  self.expect(0x22)
  let sb = StringBuilder()
  while true {
    let c = self.peek()
    if c < 0 {
      raise self.fail()
    }
    if c == 0x22 {
      self.pos += 1
      break
    }
    if c < 0x20 {
      raise self.fail()
    }
    if c == 0x5C {
      self.pos += 1
      let e = self.peek()
      let unit = match e {
        0x22 | 0x5C | 0x2F => e
        0x62 => 0x08
        0x66 => 0x0C
        0x6E => 0x0A
        0x72 => 0x0D
        0x74 => 0x09
        0x75 => {
          let mut v = 0
          for _ in 0..<4 {
            self.pos += 1
            let d = hex_digit(self.peek())
            if d < 0 {
              raise self.fail()
            }
            v = v * 16 + d
          }
          v
        }
        _ => raise self.fail()
      }
      sb.write_char(unit.unsafe_to_char())
      self.pos += 1
    } else {
      sb.write_char(c.unsafe_to_char())
      self.pos += 1
    }
  }
  sb.to_string()
}
