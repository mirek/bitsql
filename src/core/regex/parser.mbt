///|
priv struct Parser {
  text : String
  mut pos : Int
  mut fold : Bool
  mut dotall : Bool
  mut multiline : Bool
  mut ungreedy : Bool
  mut groups : Int
  mut depth : Int
}

///|
fn Parser::peek(self : Parser) -> Int {
  if self.pos < self.text.length() {
    self.text[self.pos].to_int()
  } else {
    -1
  }
}

///|
fn Parser::take(self : Parser) -> Int raise @types.SqlError {
  let c = self.peek()
  if c < 0 {
    return c
  }
  self.pos += 1
  if c >= 0xD800 && c <= 0xDBFF {
    let low = self.peek()
    if low >= 0xDC00 && low <= 0xDFFF {
      self.pos += 1
      return 0x10000 + ((c - 0xD800) << 10) + low - 0xDC00
    }
  }
  if c >= 0xD800 && c <= 0xDFFF {
    raise @types.not_supported("lone surrogates in regular expression patterns")
  }
  c
}

///|
fn Parser::fragment(self : Parser, start : Int) -> String {
  self.text.unsafe_substring(start~, end=self.pos)
}

///|
fn Parser::invalid(self : Parser, detail : String) -> @types.SqlError {
  @types.sql_error(
    19300,
    "An invalid Pattern '\{self.text}' was provided. Error '\{detail}' occurred during evaluation of the Pattern.",
  )
}

///|
fn Parser::missing(self : Parser, bracket : Bool) -> @types.SqlError {
  @types.sql_error(
    19308,
    "Missing '\{if bracket { "]" } else { ")" }}' in the Pattern \{self.text}.",
    state=if bracket { 2 } else { 1 },
  )
}

///|
fn Parser::choice(self : Parser) -> Node raise @types.SqlError {
  let choices : Array[Node] = [self.sequence()]
  while self.peek() == 124 {
    self.pos += 1
    choices.push(self.sequence())
  }
  if choices.length() == 1 {
    choices[0]
  } else {
    Choice(choices)
  }
}

///|
fn Parser::sequence(self : Parser) -> Node raise @types.SqlError {
  let nodes : Array[Node] = []
  while self.peek() != -1 && self.peek() != 41 && self.peek() != 124 {
    let start = self.pos
    let quoted = self.peek() == 92 &&
      self.pos + 1 < self.text.length() &&
      self.text[self.pos + 1].to_int() == 81
    let mut atom = self.atom()
    if quoted && atom is Sequence(parts) {
      if parts.is_empty() {
        if !(self.peek() is (42 | 43 | 63 | 123)) {
          continue
        }
        guard nodes.pop() is Some(previous) else {
          let at = self.pos
          ignore(self.take())
          raise self.invalid(
            "no argument for repetition operator: \{self.fragment(at)}",
          )
        }
        atom = previous
      } else {
        for i in 0..<(parts.length() - 1) {
          nodes.push(parts[i])
        }
        atom = parts[parts.length() - 1]
      }
    }
    let mut min = 0
    let mut max : Int? = None
    let quantifier = match self.peek() {
      42 => {
        self.pos += 1
        true
      }
      43 => {
        self.pos += 1
        min = 1
        true
      }
      63 => {
        self.pos += 1
        max = Some(1)
        true
      }
      123 => {
        let saved = self.pos
        self.pos += 1
        if self.number() is Some(n) {
          min = n
          max = Some(n)
          if self.peek() == 44 {
            self.pos += 1
            max = self.number()
          }
          if self.peek() == 125 {
            self.pos += 1
            if min > 1000 || (max is Some(m) && (m > 1000 || m < min)) {
              raise self.invalid(
                "invalid repetition size: \{self.fragment(saved)}",
              )
            }
            true
          } else {
            self.pos = saved
            false
          }
        } else {
          self.pos = saved
          false
        }
      }
      _ => false
    }
    if quantifier {
      let mut greedy = !self.ungreedy
      if self.peek() == 63 {
        self.pos += 1
        greedy = !greedy
      }
      if self.peek() is (42 | 43 | 63) {
        self.pos += 1
        raise self.invalid(
          "invalid nested repetition operator: \{self.fragment(start)}",
        )
      }
      nodes.push(Repeat(atom, min, max, greedy))
    } else {
      nodes.push(atom)
    }
  }
  if nodes.is_empty() {
    Empty
  } else if nodes.length() == 1 {
    nodes[0]
  } else {
    Sequence(nodes)
  }
}

///|
fn Parser::number(self : Parser) -> Int? {
  let start = self.pos
  let mut n = 0
  while self.peek() >= 48 && self.peek() <= 57 {
    n = if n >= 10000 { 10000 } else { n * 10 + self.peek() - 48 }
    self.pos += 1
  }
  if self.pos == start {
    None
  } else {
    Some(n)
  }
}

///|
fn Parser::atom(self : Parser) -> Node raise @types.SqlError {
  let start = self.pos
  match self.take() {
    40 => self.group(start)
    91 => self.char_class()
    92 => self.escape(false)
    46 =>
      Rune(
        if self.dotall {
          [(0, 0x10FFFF)]
        } else {
          [(0, 9), (11, 0x10FFFF)]
        },
        false,
        false,
      )
    94 => Assert(if self.multiline { 2 } else { 0 })
    36 => Assert(if self.multiline { 3 } else { 1 })
    42 | 43 | 63 =>
      raise self.invalid(
        "no argument for repetition operator: \{self.fragment(start)}",
      )
    c => Rune([(c, c)], false, self.fold)
  }
}

///|
fn Parser::group(self : Parser, start : Int) -> Node raise @types.SqlError {
  self.depth += 1
  if self.depth > 128 {
    raise @types.emulator_error(
      @types.EMU_WORK_BUDGET,
      "regular expression nesting exceeded the compilation budget",
    )
  }
  let saved = (self.fold, self.dotall, self.multiline, self.ungreedy)
  let mut capture = true
  if self.peek() == 63 {
    self.pos += 1
    if self.peek() == 58 {
      self.pos += 1
      capture = false
    } else if self.peek() == 80 || self.peek() == 60 {
      if self.peek() == 80 {
        self.pos += 1
      }
      if self.peek() != 60 {
        raise self.invalid("invalid perl operator: \{self.fragment(start)}")
      }
      self.pos += 1
      if self.peek() is (61 | 33) {
        raise self.invalid("invalid perl operator: \{self.fragment(start)}")
      }
      while self.peek() != 62 && self.peek() != -1 {
        ignore(self.take())
      }
      if self.peek() != 62 {
        raise self.invalid("invalid named capture: \{self.fragment(start)}")
      }
      self.pos += 1
    } else {
      let mut enabled = true
      let mut any = false
      while self.peek() is (105 | 109 | 115 | 85 | 45) {
        let flag = self.take()
        match flag {
          45 => enabled = false
          105 => {
            self.fold = enabled
            any = true
          }
          109 => {
            self.multiline = enabled
            any = true
          }
          115 => {
            self.dotall = enabled
            any = true
          }
          _ => {
            self.ungreedy = enabled
            any = true
          }
        }
      }
      if !any || !(self.peek() is (58 | 41)) {
        if self.peek() >= 0 {
          ignore(self.take())
        }
        raise self.invalid("invalid perl operator: \{self.fragment(start)}")
      }
      if self.peek() == 41 {
        self.pos += 1
        self.depth -= 1
        return Empty
      }
      self.pos += 1
      capture = false
    }
  }
  let group = if capture {
    self.groups += 1
    self.groups
  } else {
    0
  }
  let body = self.choice()
  if self.peek() != 41 {
    raise self.missing(false)
  }
  self.pos += 1
  self.depth -= 1
  self.fold = saved.0
  self.dotall = saved.1
  self.multiline = saved.2
  self.ungreedy = saved.3
  if capture {
    Capture(group, body)
  } else {
    body
  }
}

///|
fn ascii_ranges(c : Int) -> Array[(Int, Int)] {
  match c {
    100 | 68 => [(48, 57)]
    115 | 83 => [(9, 10), (12, 13), (32, 32)]
    _ => [(48, 57), (65, 90), (95, 95), (97, 122)]
  }
}

///|
fn complement(ranges : Array[(Int, Int)]) -> Array[(Int, Int)] {
  let sorted = ranges.copy()
  sorted.sort_by((a, b) => a.0.compare(b.0))
  let out = []
  let mut at = 0
  for r in sorted {
    if r.0 > at {
      out.push((at, r.0 - 1))
    }
    if r.1 + 1 > at {
      at = r.1 + 1
    }
  }
  if at <= 0x10FFFF {
    out.push((at, 0x10FFFF))
  }
  out
}

///|
fn Parser::escape(self : Parser, in_class : Bool) -> Node raise @types.SqlError {
  let start = self.pos - 1
  let c = self.take()
  let value = match c {
    100 | 68 | 115 | 83 | 119 | 87 => {
      let rs = ascii_ranges(c)
      return Rune(
        if c >= 65 && c <= 90 {
          complement(rs)
        } else {
          rs
        },
        false,
        self.fold,
      )
    }
    67 if !in_class => return ByteAny
    65 if !in_class => return Assert(0)
    122 if !in_class => return Assert(1)
    98 if !in_class => return Assert(4)
    66 if !in_class => return Assert(5)
    110 => 10
    114 => 13
    116 => 9
    102 => 12
    118 => 11
    97 => 7
    112 | 80 => {
      let mut negate = c == 80
      let name = if self.peek() == 123 {
        self.pos += 1
        if self.peek() == 94 {
          negate = !negate
          self.pos += 1
        }
        let at = self.pos
        while self.peek() >= 0 && self.peek() != 125 {
          self.pos += 1
        }
        let name = self.fragment(at)
        if self.peek() != 125 {
          raise self.invalid(
            "invalid character class range: \{self.fragment(start)}",
          )
        }
        self.pos += 1
        name
      } else if self.peek() >= 0 {
        let at = self.pos
        ignore(self.take())
        self.fragment(at)
      } else {
        ""
      }
      guard unicode_ranges(name) is Some(rs) else {
        raise self.invalid(
          "invalid character class range: \{self.fragment(start)}",
        )
      }
      return Rune(rs, negate, self.fold)
    }
    81 if !in_class => {
      let nodes : Array[Node] = []
      while self.peek() >= 0 {
        if self.peek() == 92 &&
          self.pos + 1 < self.text.length() &&
          self.text[self.pos + 1].to_int() == 69 {
          self.pos += 2
          break
        }
        let literal = self.take()
        nodes.push(Rune([(literal, literal)], false, self.fold))
      }
      return Sequence(nodes)
    }
    120 => {
      let braces = self.peek() == 123
      if braces {
        self.pos += 1
      }
      let mut count = 0
      let mut n = 0
      while self.peek() >= 0 && (braces || count < 2) {
        let d = match self.peek() {
          48..=57 => self.peek() - 48
          65..=70 => self.peek() - 65 + 10
          97..=102 => self.peek() - 97 + 10
          _ => break
        }
        n = n * 16 + d
        count += 1
        self.pos += 1
        if n > 0x10FFFF {
          raise self.invalid("invalid escape sequence: \{self.fragment(start)}")
        }
      }
      if count == 0 || (!braces && count != 2) || (braces && self.peek() != 125) {
        raise self.invalid("invalid escape sequence: \{self.fragment(start)}")
      }
      if braces {
        self.pos += 1
      }
      n
    }
    48..=55 => {
      let mut n = c - 48
      let mut count = 1
      while count < 3 && self.peek() >= 48 && self.peek() <= 55 {
        n = n * 8 + self.take() - 48
        count += 1
      }
      if c != 48 && count < 3 {
        raise self.invalid("invalid escape sequence: \{self.fragment(start)}")
      }
      n
    }
    _ => {
      if c < 0 ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) {
        raise self.invalid("invalid escape sequence: \{self.fragment(start)}")
      }
      c
    }
  }
  Rune([(value, value)], false, self.fold)
}

///|
fn Parser::class_atom(self : Parser) -> Array[(Int, Int)] raise @types.SqlError {
  if self.peek() == 92 {
    self.pos += 1
    match self.escape(true) {
      Rune(ranges, negate, fold) => {
        let ranges = if fold { fold_ranges(ranges) } else { ranges }
        if negate {
          complement(ranges)
        } else {
          ranges
        }
      }
      _ => raise self.invalid("invalid character class")
    }
  } else if self.peek() == 91 &&
    self.pos + 1 < self.text.length() &&
    self.text[self.pos + 1].to_int() == 58 {
    self.pos += 2
    let start = self.pos
    while self.peek() != 58 && self.peek() >= 0 {
      self.pos += 1
    }
    let raw_name = self.fragment(start)
    let negate = raw_name.has_prefix("^")
    let name = if negate { raw_name[1:].to_owned() } else { raw_name }
    if self.peek() != 58 {
      raise self.missing(true)
    }
    self.pos += 1
    if self.peek() != 93 {
      raise self.missing(true)
    }
    self.pos += 1
    let ranges = match name {
      "digit" => [(48, 57)]
      "alpha" => [(65, 90), (97, 122)]
      "alnum" => [(48, 57), (65, 90), (97, 122)]
      "word" => ascii_ranges(119)
      "space" => [(9, 13), (32, 32)]
      "blank" => [(9, 9), (32, 32)]
      "lower" => [(97, 122)]
      "upper" => [(65, 90)]
      "xdigit" => [(48, 57), (65, 70), (97, 102)]
      "ascii" => [(0, 127)]
      "cntrl" => [(0, 31), (127, 127)]
      "graph" => [(33, 126)]
      "print" => [(32, 126)]
      "punct" => [(33, 47), (58, 64), (91, 96), (123, 126)]
      _ => raise self.invalid("invalid character class range: [:\{raw_name}:]")
    }
    if negate {
      complement(if self.fold { fold_ranges(ranges) } else { ranges })
    } else {
      ranges
    }
  } else {
    let c = self.take()
    [(c, c)]
  }
}

///|
fn Parser::char_class(self : Parser) -> Node raise @types.SqlError {
  let negate = self.peek() == 94
  if negate {
    self.pos += 1
  }
  let ranges : Array[(Int, Int)] = []
  let mut first = true
  while self.peek() >= 0 && (self.peek() != 93 || first) {
    let start = self.pos
    let rs = self.class_atom()
    first = false
    if self.peek() == 45 &&
      self.pos + 1 < self.text.length() &&
      self.text[self.pos + 1].to_int() != 93 {
      self.pos += 1
      let end = self.class_atom()
      if rs.length() != 1 ||
        end.length() != 1 ||
        rs[0].0 != rs[0].1 ||
        end[0].0 != end[0].1 ||
        rs[0].0 > end[0].0 {
        raise self.invalid(
          "invalid character class range: \{self.fragment(start)}",
        )
      }
      ranges.push((rs[0].0, end[0].0))
    } else {
      ranges.append(rs)
    }
  }
  if self.peek() != 93 {
    raise self.missing(true)
  }
  self.pos += 1
  Rune(ranges, negate, self.fold)
}

///|
pub fn compile(
  pattern : String,
  flags : String,
) -> Program raise @types.SqlError {
  let p : Parser = {
    text: pattern,
    pos: 0,
    fold: false,
    dotall: false,
    multiline: false,
    ungreedy: false,
    groups: 0,
    depth: 0,
  }
  let invalid = StringBuilder()
  for flag in flags.iter() {
    match flag {
      'c' => p.fold = false
      'i' => p.fold = true
      's' => p.dotall = true
      'm' => p.multiline = true
      _ => invalid.write_char(flag)
    }
  }
  let bad = invalid.to_string()
  if !bad.is_empty() {
    raise @types.sql_error(
      19303,
      "Invalid flag provided. '\{bad}' are not valid flags. Only {c,i,s,m} flags are valid.",
      state=0,
    )
  }
  let node = p.choice()
  if p.peek() >= 0 {
    raise p.invalid("unexpected ): \{p.fragment(p.pos)}")
  }
  program(node, p.groups)
}
