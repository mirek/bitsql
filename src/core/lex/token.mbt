///|
pub(all) enum TokenKind {
  /// Identifier or keyword (raw text; includes `#temp`, `##global`,
  /// `$action`).
  Word
  /// `[x]` or `"x"`; text is unescaped.
  QuotedIdent
  /// `'x'`; text is unescaped.
  Str
  /// `N'x'`; text is unescaped.
  NStr
  /// Integer literal, raw text.
  IntNum
  /// Decimal literal (`1.5`, `.5`, `1.`), raw text.
  DecimalNum
  /// Float literal (`1e3`, `1.5E-2`), raw text.
  FloatNum
  /// Money literal (`$12.50`), raw text including `$`.
  Money
  /// `0x...`, raw text.
  BinaryLit
  /// `@x`, raw text.
  Variable
  /// `@@x`, raw text.
  GlobalVariable
  /// Operator or punctuation, raw text.
  Punct
  /// End of input; its span is zero-width at the end of the source.
  Eof
} derive(Eq, Debug)

///|
pub(all) struct Token {
  kind : TokenKind
  text : String
  span : @ast.Span
} derive(Eq, Debug)

///|
/// True when the token is a `Word` equal to `kw` (ASCII case-insensitive;
/// `kw` must be upper case).
pub fn Token::is_kw(self : Token, kw : String) -> Bool {
  self.kind is Word && eq_upper(self.text, kw)
}

///|
/// True when the token is punctuation `p`.
pub fn Token::is_punct(self : Token, p : String) -> Bool {
  self.kind is Punct && self.text == p
}

///|
/// ASCII case-insensitive comparison against an upper-case word.
pub fn eq_upper(text : String, upper : String) -> Bool {
  if text.length() != upper.length() {
    return false
  }
  for i in 0..<text.length() {
    let a = text[i].to_int()
    let a = if a >= 97 && a <= 122 { a - 32 } else { a }
    if a != upper[i].to_int() {
      return false
    }
  }
  true
}
