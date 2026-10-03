///|
priv struct Lexer {
  src : String
  mut pos : Int
  mut line : Int
  mut line_start : Int
  tokens : Array[Token]
}

///|
fn is_space(c : Int) -> Bool {
  c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12 || c == 0xA0
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_hex(c : Int) -> Bool {
  is_digit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}

///|
fn is_letter(c : Int) -> Bool {
  (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c >= 0x80
}

///|
fn is_word_start(c : Int) -> Bool {
  is_letter(c) || c == 95 || c == 35 // _ #
}

///|
fn is_word_part(c : Int) -> Bool {
  is_letter(c) || is_digit(c) || c == 95 || c == 35 || c == 36 || c == 64 // _ # $ @
}

///|
fn Lexer::at(self : Lexer, i : Int) -> Int {
  if i < self.src.length() {
    self.src[i].to_int()
  } else {
    -1
  }
}

///|
/// Span for `[start, end)`; `start` must be on the current line bookkeeping,
/// i.e. call before `advance_to(end)`.
fn Lexer::span(self : Lexer, start : Int, end : Int) -> @ast.Span {
  { start, end, line: self.line, col: start - self.line_start + 1, }
}

///|
/// Moves to `end`, counting newlines on the way.
fn Lexer::advance_to(self : Lexer, end : Int) -> Unit {
  for i in self.pos..<end {
    if self.src[i] == '\n' {
      self.line += 1
      self.line_start = i + 1
    }
  }
  self.pos = end
}

///|
fn Lexer::push(
  self : Lexer,
  kind : TokenKind,
  text : String,
  start : Int,
  end : Int,
) -> Unit {
  self.tokens.push({ kind, text, span: self.span(start, end), })
  self.advance_to(end)
}

///|
fn lex_error(
  number : Int,
  message : String,
  span : @ast.Span,
) -> @ast.SyntaxError {
  @ast.SyntaxError(number~, severity=15, state=1, message~, span~)
}

///|
/// Scans a delimited run closed by `close`, where a doubled `close` is an
/// escaped literal. Returns (unescaped text, end offset after the closing
/// delimiter) or None when unterminated.
fn Lexer::delimited(self : Lexer, from : Int, close : Int) -> (String, Int)? {
  let sb = StringBuilder()
  let n = self.src.length()
  for i = from, seg = from; i < n; {
    if self.src[i].to_int() == close {
      if i + 1 < n && self.src[i + 1].to_int() == close {
        sb.write_substring(self.src, seg, i + 1 - seg)
        continue i + 2, i + 2
      }
      sb.write_substring(self.src, seg, i - seg)
      break Some((sb.to_string(), i + 1))
    }
    continue i + 1, seg
  } nobreak {
    None
  }
}

///|
let punct2 : Array[String] = [
  ">=", "<=", "<>", "!=", "!<", "!>", "+=", "-=", "*=", "/=", "%=", "&=", "^=", "|=",
  "::",
]

///|
const PUNCT1 : String = "(),.;=<>+-*/%&^|~:"

///|
/// Tokenizes a T-SQL batch. Whitespace and comments are skipped; the result
/// always ends with an `Eof` token. Linear time.
///
/// Raises 105 (unclosed quotation mark), 113 (missing end comment mark) or
/// 102 (unexpected character).
pub fn lex(src : String) -> Array[Token] raise @ast.SyntaxError {
  let lx : Lexer = { src, pos: 0, line: 1, line_start: 0, tokens: [], }
  let n = src.length()
  while lx.pos < n {
    let start = lx.pos
    let c = lx.at(start)
    let c1 = lx.at(start + 1)
    if is_space(c) {
      lx.advance_to(start + 1)
    } else if c == 45 && c1 == 45 { // --
      let mut end = start + 2
      while end < n && src[end] != '\n' {
        end += 1
      }
      lx.advance_to(end)
    } else if c == 47 && c1 == 42 { // /*
      let span = lx.span(start, start + 2)
      let mut depth = 1
      let mut i = start + 2
      while depth > 0 {
        if i >= n {
          raise lex_error(113, "Missing end comment mark '*/'.", span)
        }
        let a = lx.at(i)
        let b = lx.at(i + 1)
        if a == 47 && b == 42 {
          depth += 1
          i += 2
        } else if a == 42 && b == 47 {
          depth -= 1
          i += 2
        } else {
          i += 1
        }
      }
      lx.advance_to(i)
    } else if c == 39 || ((c == 78 || c == 110) && c1 == 39) { // ' or N'
      let national = c != 39
      let from = if national { start + 2 } else { start + 1 }
      match lx.delimited(from, 39) {
        Some((text, end)) =>
          lx.push(if national { NStr } else { Str }, text, start, end)
        None => {
          let rest = src.view(start_offset=from).to_owned()
          raise lex_error(
            105,
            "Unclosed quotation mark after the character string '\{rest}'.",
            lx.span(start, n),
          )
        }
      }
    } else if c == 91 || c == 34 { // [ or "
      let close = if c == 91 { 93 } else { 34 }
      match lx.delimited(start + 1, close) {
        Some((text, end)) => lx.push(QuotedIdent, text, start, end)
        None => {
          let rest = src.view(start_offset=start + 1).to_owned()
          raise lex_error(
            105,
            "Unclosed quotation mark after the character string '\{rest}'.",
            lx.span(start, n),
          )
        }
      }
    } else if c == 64 { // @
      let global = c1 == 64
      let mut end = if global { start + 2 } else { start + 1 }
      while end < n && is_word_part(lx.at(end)) {
        end += 1
      }
      lx.push(
        if global {
          GlobalVariable
        } else {
          Variable
        },
        src.view(start_offset=start, end_offset=end).to_owned(),
        start,
        end,
      )
    } else if c == 48 && (c1 == 120 || c1 == 88) { // 0x
      let mut end = start + 2
      while end < n && is_hex(lx.at(end)) {
        end += 1
      }
      lx.push(
        BinaryLit,
        src.view(start_offset=start, end_offset=end).to_owned(),
        start,
        end,
      )
    } else if is_digit(c) || (c == 46 && is_digit(c1)) {
      let (kind, end) = lx.number_end(start)
      lx.push(
        kind,
        src.view(start_offset=start, end_offset=end).to_owned(),
        start,
        end,
      )
    } else if c == 36 && (is_digit(c1) || c1 == 46) { // $12.50
      let (_, end) = lx.number_end(start + 1)
      lx.push(
        Money,
        src.view(start_offset=start, end_offset=end).to_owned(),
        start,
        end,
      )
    } else if is_word_start(c) || (c == 36 && is_word_start(c1)) {
      let mut end = start + 1
      while end < n && is_word_part(lx.at(end)) {
        end += 1
      }
      lx.push(
        Word,
        src.view(start_offset=start, end_offset=end).to_owned(),
        start,
        end,
      )
    } else {
      let two = if start + 2 <= n {
        src.view(start_offset=start, end_offset=start + 2).to_owned()
      } else {
        ""
      }
      if two != "" && punct2.contains(two) {
        lx.push(Punct, two, start, start + 2)
      } else if PUNCT1.contains_code_unit(src[start]) {
        lx.push(
          Punct,
          src.view(start_offset=start, end_offset=start + 1).to_owned(),
          start,
          start + 1,
        )
      } else {
        let ch = src.view(start_offset=start, end_offset=start + 1).to_owned()
        raise lex_error(
          102,
          "Incorrect syntax near '\{ch}'.",
          lx.span(start, start + 1),
        )
      }
    }
  }
  lx.tokens.push({ kind: Eof, text: "", span: lx.span(n, n), })
  lx.tokens
}

///|
/// End of a numeric literal starting at `start` (digits or `.`), and its kind.
fn Lexer::number_end(self : Lexer, start : Int) -> (TokenKind, Int) {
  let mut end = start
  let mut kind = IntNum
  while is_digit(self.at(end)) {
    end += 1
  }
  if self.at(end) == 46 {
    kind = DecimalNum
    end += 1
    while is_digit(self.at(end)) {
      end += 1
    }
  }
  let e = self.at(end)
  if e == 101 || e == 69 {
    let mut exp = end + 1
    let s = self.at(exp)
    if s == 43 || s == 45 {
      exp += 1
    }
    if is_digit(self.at(exp)) {
      kind = FloatNum
      end = exp
      while is_digit(self.at(end)) {
        end += 1
      }
    }
  }
  (kind, end)
}
