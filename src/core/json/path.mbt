///|
pub(all) enum Step {
  Key(String)
  /// `[n]`, also `[n to n]`. Indexes above Int's range are clamped (they
  /// never match an element).
  Index(Int)
  /// `.*`: every member value of an object.
  AnyKey
  /// `[*]`: every element of an array.
  AnyIndex
  /// `[a to b]` with a < b (SQL Server 2025 advanced accessor).
  Range(Int64, Int64)
  Elements(Array[(Int64, Int64)])
} derive(Debug, Eq)

///|
/// True for the advanced accessors that can select several values.
pub fn Step::is_multi(self : Step) -> Bool {
  self is (AnyKey | AnyIndex | Range(_, _) | Elements(_))
}

///|
pub(all) struct Path {
  strict : Bool
  append : Bool
  steps : Array[Step]
} derive(Debug, Eq)

///|
fn Path::is_multi(self : Path) -> Bool {
  self.steps.iter().any(s => s.is_multi())
}

///|
const ADVANCED_REVERSED : String = "Reversed indexing not yet supported for advanced JSON array accessors."

///|
const ADVANCED_LAST : String = "Last operator not yet supported for advanced JSON array accessors."

///|
const ADVANCED_COMMA : String = "Comma operator not yet supported for advanced JSON array accessors."

///|
/// Path lexer/parser state. Error states (13607) captured from SQL Server
/// 2025 (harness/corpus/json3/path-syntax, msduck json-advanced-path):
///
/// - 14: a known token in the wrong place (`$ . [ ] * ,`, a number, a
///   quoted string, a keyword) or the end of the path;
/// - 22: an unknown word or symbol outside brackets (`$a`, `$.a#`, `x`);
/// - 21: an unknown word or symbol inside brackets (`[a]`, `[-1]`, `[0 TO 1]`);
/// - 15: a number immediately followed by a word character (`[0to0]`, `.1a`);
/// - 16: an index that overflows a 32-bit unsigned accumulator;
/// - 17: a bad escape in a quoted key; 20: an unterminated quoted key.
///
/// Whitespace (space, tab, CR, LF) may surround every token. Unquoted keys
/// are ASCII words `[A-Za-z_][A-Za-z0-9_]*`.
priv struct PathLexer {
  text : String
  mut pos : Int
}

///|
fn PathLexer::at(self : PathLexer, i : Int) -> Int {
  if i < self.text.length() {
    self.text.code_unit_at(i).to_int()
  } else {
    -1
  }
}

///|
fn PathLexer::peek(self : PathLexer) -> Int {
  self.at(self.pos)
}

///|
fn PathLexer::ws(self : PathLexer) -> Unit {
  while self.peek() is (0x20 | 0x09 | 0x0A | 0x0D) {
    self.pos += 1
  }
}

///|
fn PathLexer::fail(self : PathLexer, state : Int, pos? : Int) -> JsonError {
  JsonError(
    13607,
    state,
    unexpected("path", self.text, pos.unwrap_or(self.pos)),
  )
}

///|
fn is_word_start(c : Int) -> Bool {
  c is (0x41..=0x5A | 0x61..=0x7A | 0x5F)
}

///|
fn is_word_char(c : Int) -> Bool {
  is_word_start(c) || c is (0x30..=0x39)
}

///|
/// The word at `pos` (empty when none).
fn PathLexer::word_at(self : PathLexer) -> String {
  if !is_word_start(self.peek()) {
    return ""
  }
  let start = self.pos
  let mut i = start
  while is_word_char(self.at(i)) {
    i += 1
  }
  self.text.unsafe_substring(start~, end=i)
}

///|
fn is_keyword(w : String) -> Bool {
  w is ("lax" | "strict" | "append" | "to" | "last")
}

///|
/// The error for an unexpected token at `pos`: 14 for a known token or
/// the end, otherwise `unknown` (22 outside brackets, 21 inside).
fn PathLexer::unexpected_token(self : PathLexer, unknown : Int) -> JsonError {
  let c = self.peek()
  let known = c < 0 ||
    c is (0x24 | 0x2E | 0x5B | 0x5D | 0x2A | 0x2C | 0x22 | 0x30..=0x39) ||
    is_keyword(self.word_at())
  self.fail(if known { 14 } else { unknown })
}

///|
/// Reads an unsigned index: 32-bit wrap-around accumulation where a value
/// that decreases is 16 (captured: `$[9999999999]` is accepted,
/// `$[4294967297]` fails at its last digit). A word character right after
/// the digits is 15.
fn PathLexer::number(self : PathLexer) -> Int64 raise JsonError {
  let mut v : UInt = 0
  while self.peek() is (0x30..=0x39) {
    let next = v * 10U + (self.peek() - 0x30).reinterpret_as_uint()
    if next < v {
      raise self.fail(16)
    }
    v = next
    self.pos += 1
  }
  if is_word_char(self.peek()) {
    raise self.fail(15)
  }
  v.to_uint64().reinterpret_as_int64()
}

///|
fn clamp_index(v : Int64) -> Int {
  if v > 2147483647L {
    2147483647
  } else {
    v.to_int()
  }
}

///|
/// One bracket accessor after `[`: `*`, `n`, `a to b`, `last` (13660/2),
/// lists (13660/5) and reversed ranges (13660/1).
fn PathLexer::bracket(self : PathLexer, native : Bool) -> Step raise JsonError {
  self.ws()
  if self.peek() == 0x2A {
    self.pos += 1
    self.ws()
    if self.peek() != 0x5D {
      raise self.fail(14)
    }
    self.pos += 1
    return AnyIndex
  }
  let elements : Array[(Int64, Int64)] = []
  let mut list = false
  let mut saw_last = false
  let mut first : Step? = None
  while true {
    // one element: n | last | (n | last) to (n | last)
    let mut lo : Int64 = -1
    let mut element_last = false
    if self.peek() is (0x30..=0x39) {
      lo = self.number()
    } else if self.word_at() == "last" {
      self.pos += 4
      element_last = true
    } else {
      raise self.unexpected_token(21)
    }
    self.ws()
    let mut hi = lo
    if self.word_at() == "to" {
      if element_last && !native {
        raise JsonError(13660, 2, ADVANCED_LAST)
      }
      self.pos += 2
      self.ws()
      if self.peek() is (0x30..=0x39) {
        hi = self.number()
        if hi < lo {
          raise JsonError(13660, 1, ADVANCED_REVERSED)
        }
      } else if self.word_at() == "last" {
        self.pos += 4
        element_last = true
        hi = -1L
      } else {
        raise self.unexpected_token(21)
      }
      self.ws()
    }
    elements.push((lo, hi))
    saw_last = saw_last || element_last
    if !element_last {
      first = Some(
        if hi == lo {
          Index(clamp_index(lo))
        } else {
          Range(lo, hi)
        },
      )
    }
    match self.peek() {
      0x2C => {
        if element_last && !native {
          raise JsonError(13660, 2, ADVANCED_LAST)
        }
        list = true
        self.pos += 1
        self.ws()
      }
      0x5D => {
        self.pos += 1
        if native && (list || saw_last) {
          return Elements(elements)
        }
        if list {
          raise JsonError(13660, 5, ADVANCED_COMMA)
        }
        if saw_last {
          raise JsonError(13660, 2, ADVANCED_LAST)
        }
        break
      }
      _ => raise self.unexpected_token(21)
    }
  }
  first.unwrap()
}

///|
/// Parses `[append] [lax|strict] $ accessor*` (append only when
/// `allow_append`). See `PathLexer` for the error states.
pub fn parse_path(
  path : String,
  allow_append? : Bool = false,
  native? : Bool = false,
) -> Path raise JsonError {
  let lx : PathLexer = { text: path, pos: 0, }
  lx.ws()
  let mut append = false
  let mut strict = false
  if allow_append && lx.word_at() == "append" {
    append = true
    lx.pos += 6
    lx.ws()
  }
  match lx.word_at() {
    "strict" => {
      strict = true
      lx.pos += 6
    }
    "lax" => lx.pos += 3
    _ => ()
  }
  lx.ws()
  if lx.peek() != 0x24 {
    raise lx.unexpected_token(22)
  }
  lx.pos += 1
  let steps = []
  while true {
    lx.ws()
    match lx.peek() {
      -1 => break
      0x2E => {
        lx.pos += 1
        lx.ws()
        match lx.peek() {
          0x22 => {
            let s : Scanner = { text: path, pos: lx.pos, doc_state: 0, }
            let key = s.string_value() catch {
              _ =>
                raise lx.fail(
                  if s.pos >= path.length() {
                    20
                  } else {
                    17
                  },
                  pos=s.pos,
                )
            }
            lx.pos = s.pos
            if is_word_char(lx.peek()) {
              raise lx.fail(14)
            }
            steps.push(Key(key))
          }
          0x2A => {
            lx.pos += 1
            if is_word_char(lx.peek()) {
              raise lx.fail(14)
            }
            steps.push(AnyKey)
          }
          c if is_word_start(c) => {
            let w = lx.word_at()
            lx.pos += w.length()
            steps.push(Key(w))
          }
          0x30..=0x39 => {
            // a number where a key belongs: `.1a` is 15, `.1` is 14
            let start = lx.pos
            ignore(lx.number())
            raise lx.fail(14, pos=start)
          }
          _ => raise lx.unexpected_token(22)
        }
      }
      0x5B => {
        lx.pos += 1
        steps.push(lx.bracket(native))
      }
      _ => raise lx.unexpected_token(22)
    }
  }
  { strict, append, steps, }
}

///|
/// Canonical concrete prefix, stopping before the first multi-value accessor.
pub fn Path::concrete_prefix(self : Path) -> String {
  let out = StringBuilder()
  out.write_char('$')
  for step in self.steps {
    match step {
      Key(key) => {
        out.write_char('.')
        out.write_string(quote(key))
      }
      Index(i) => {
        out.write_char('[')
        out.write_string(i.to_string())
        out.write_char(']')
      }
      _ => break
    }
  }
  out.to_string()
}
