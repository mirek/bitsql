// Native JSON construction sizes captured in sql2025/json-binary-{size,boundaries}.
// This accounts for a freshly built document, not retained allocations after
// JSON_MODIFY or the modify method. Callers must preserve that distinction.

///|
fn json_storage_string(text : String) -> Int {
  let n = utf8_length(text)
  if n == 0 {
    return 0
  }
  let mut length_bytes = 1
  let mut remaining = n >> 7
  while remaining > 0 {
    length_bytes += 1
    remaining = remaining >> 7
  }
  n + 1 + length_bytes
}

///|
fn json_storage_number(text : String) -> Int raise SqlError {
  guard Decimal::parse(text[:]) is Some(d) else {
    raise internal("noncanonical native JSON number")
  }
  let coef = d.coef()
  if d.scale() == 0 {
    if coef.compare_int(-536870912) >= 0 && coef.compare_int(536870911) <= 0 {
      return 0
    }
    if coef >= @bigint.BigInt::from_int64(-9223372036854775808L) &&
      coef <= @bigint.BigInt::from_int64(9223372036854775807L) {
      return 9
    }
  }
  let bits = big_abs(coef).bit_length()
  5 + 4 * (if bits == 0 { 1 } else { (bits + 31) / 32 })
}

///|
fn JsonTypeParser::storage_value(
  self : JsonTypeParser,
  keys : Set[String],
  depth : Int,
) -> Int raise SqlError {
  self.ws()
  match self.peek() {
    0x7B | 0x5B => {
      if depth >= 128 {
        raise json_type_depth_error()
      }
      let object = self.peek() == 0x7B
      let close = if object { 0x7D } else { 0x5D }
      self.pos += 1
      self.ws()
      if self.peek() == close {
        self.pos += 1
        return 0
      }
      let mut count = 0
      let mut payload = 0
      while true {
        if object {
          if self.peek() != 0x22 {
            raise self.fail_at(self.pos)
          }
          keys.add(self.string())
          self.ws()
          if self.peek() != 0x3A {
            raise self.fail_at(self.pos)
          }
          self.pos += 1
        }
        payload += self.storage_value(keys, depth + 1)
        count += 1
        self.ws()
        if self.peek() == close {
          self.pos += 1
          break
        }
        if self.peek() != 0x2C {
          raise self.fail_at(self.pos)
        }
        self.pos += 1
        self.ws()
      }
      4 + count * (if object { 6 } else { 4 }) + payload
    }
    0x22 => json_storage_string(self.string())
    0x74 | 0x66 | 0x6E => {
      let word = match self.peek() {
        0x74 => "true"
        0x66 => "false"
        _ => "null"
      }
      self.literal(word, StringBuilder())
      0
    }
    c if c == 0x2D || (c >= 0x30 && c <= 0x39) =>
      json_storage_number(self.number())
    _ => raise self.fail_at(self.pos)
  }
}

///|
/// Binary size of a newly constructed native JSON document. The input must
/// already be canonical (in particular, duplicate object keys removed).
/// This is not the size of a document carrying retained mutation allocations.
pub fn json_constructed_storage_bytes(canonical : String) -> Int raise SqlError {
  let parser : JsonTypeParser = { b: utf8_bytes(canonical), pos: 0, }
  let keys : Set[String] = Set([])
  let mut size = 18 + parser.storage_value(keys, 0)
  parser.ws()
  if parser.pos != parser.b.length() {
    raise parser.fail_at(parser.pos)
  }
  if !keys.is_empty() {
    size += 4 + 8 * keys.length()
    for key in keys {
      size += json_storage_string(key)
    }
  }
  size
}

///|
/// A native JSON value carries its canonical text and storage provenance.
/// A text round trip constructs fresh storage; native assignment preserves it.
pub struct JsonData {
  text : String
  storage_bytes : Int?
} derive(Debug, Eq)

///|
pub fn JsonData::parse(text : String) -> JsonData raise SqlError {
  let canonical = json_type_normalize(text)
  {
    text: canonical,
    storage_bytes: Some(json_constructed_storage_bytes(canonical)),
  }
}

///|
/// Retained mutation allocation must not be mistaken for a rebuilt document.
/// Until the allocator is modeled, preserve that the storage size is unknown.
pub fn JsonData::modified(text : String) -> JsonData raise SqlError {
  { text: json_type_normalize(text), storage_bytes: None, }
}

///|
pub fn JsonData::text(self : JsonData) -> String {
  self.text
}

///|
pub fn JsonData::storage_bytes(self : JsonData) -> Int? {
  self.storage_bytes
}
