///|
priv struct Parser {
  src : String
  toks : Array[@lex.Token]
  mut pos : Int
  mut depth : Int
  /// Parsing a procedure body: CREATE PROCEDURE there is 156 near the
  /// keyword, not 111 (captured: gaps-procedures #137).
  mut in_procedure : Bool
  /// Parsing a table variable's columns: named constraints are a syntax
  /// error there (captured: msduck-runs table-variable#010).
  mut table_variable : Bool
  /// Named windows of the SELECT being parsed (its WINDOW clause, found by
  /// a look-ahead before the select list; window.mbt)
  mut windows : WindowScope?
  /// Named windows of the last SELECT finished (for its query's ORDER BY)
  mut last_windows : WindowScope?
  /// The last OVER clause used a named window
  mut over_named : Bool
  /// First compile error found while parsing (5362, 4123, ...): raised once
  /// the whole batch parsed, so syntax errors anywhere come first
  mut deferred : @ast.SyntaxError?
  /// Inside UPDATE / MERGE / a DEFAULT: NEXT VALUE FOR … OVER is 11717
  mut nvf_over_forbidden : Bool
}

///|
/// Maximum nesting of expressions / statements before error 191.
const MAX_DEPTH : Int = 400

///|
/// SQL Server reserved keywords (T-SQL "Reserved Keywords" list). These are
/// rejected as bare identifiers and reported as error 156 ("near the keyword").
/// `THROW`, `OUTPUT`, `USING`, `OFFSET`, `TRY`, `CATCH` are deliberately not
/// here: they are not reserved in SQL Server either. `PRECISION` is on the
/// documented list but SQL Server accepts it as a column name, alias and
/// table column (captured: `SELECT precision FROM sys.columns`).
let reserved_words : Map[String, Bool] = {
  let words = [
    "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "AUTHORIZATION", "BACKUP",
    "BEGIN", "BETWEEN", "BREAK", "BROWSE", "BULK", "BY", "CASCADE", "CASE", "CHECK",
    "CHECKPOINT", "CLOSE", "CLUSTERED", "COALESCE", "COLLATE", "COLUMN", "COMMIT",
    "COMPUTE", "CONSTRAINT", "CONTAINS", "CONTAINSTABLE", "CONTINUE", "CONVERT",
    "CREATE", "CROSS", "CURRENT", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
    "CURRENT_USER", "CURSOR", "DATABASE", "DBCC", "DEALLOCATE", "DECLARE", "DEFAULT",
    "DELETE", "DENY", "DESC", "DISK", "DISTINCT", "DISTRIBUTED", "DOUBLE", "DROP",
    "DUMP", "ELSE", "END", "ERRLVL", "ESCAPE", "EXCEPT", "EXEC", "EXECUTE", "EXISTS",
    "EXIT", "EXTERNAL", "FETCH", "FILE", "FILLFACTOR", "FOR", "FOREIGN", "FREETEXT",
    "FREETEXTTABLE", "FROM", "FULL", "FUNCTION", "GOTO", "GRANT", "GROUP", "HAVING",
    "HOLDLOCK", "IDENTITY", "IDENTITY_INSERT", "IDENTITYCOL", "IF", "IN", "INDEX",
    "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "KILL", "LEFT",
    "LIKE", "LINENO", "LOAD", "MERGE", "NATIONAL", "NOCHECK", "NONCLUSTERED", "NOT",
    "NULL", "NULLIF", "OF", "OFF", "OFFSETS", "ON", "OPEN", "OPENDATASOURCE", "OPENQUERY",
    "OPENROWSET", "OPENXML", "OPTION", "OR", "ORDER", "OUTER", "OVER", "PERCENT",
    "PIVOT", "PLAN", "PRIMARY", "PRINT", "PROC", "PROCEDURE", "PUBLIC", "RAISERROR",
    "READ", "READTEXT", "RECONFIGURE", "REFERENCES", "REPLICATION", "RESTORE", "RESTRICT",
    "RETURN", "REVERT", "REVOKE", "RIGHT", "ROLLBACK", "ROWCOUNT", "ROWGUIDCOL",
    "RULE", "SAVE", "SCHEMA", "SECURITYAUDIT", "SELECT", "SEMANTICKEYPHRASETABLE",
    "SEMANTICSIMILARITYDETAILSTABLE", "SEMANTICSIMILARITYTABLE", "SESSION_USER",
    "SET", "SETUSER", "SHUTDOWN", "SOME", "STATISTICS", "SYSTEM_USER", "TABLE", "TABLESAMPLE",
    "TEXTSIZE", "THEN", "TO", "TOP", "TRAN", "TRANSACTION", "TRIGGER", "TRUNCATE",
    "TRY_CONVERT", "TSEQUAL", "UNION", "UNIQUE", "UNPIVOT", "UPDATE", "UPDATETEXT",
    "USE", "USER", "VALUES", "VARYING", "VIEW", "WAITFOR", "WHEN", "WHERE", "WHILE",
    "WITH", "WITHIN", "WRITETEXT",
  ]
  let m : Map[String, Bool] = Map([])
  for w in words {
    m[w] = true
  }
  m
}

///|
/// True when `word` is a T-SQL reserved keyword (case-insensitive).
pub fn is_reserved(word : String) -> Bool {
  reserved_words.contains(word.to_upper())
}

///|
fn Parser::peek(self : Parser) -> @lex.Token {
  self.toks[self.pos]
}

///|
fn Parser::peek_at(self : Parser, k : Int) -> @lex.Token {
  let i = self.pos + k
  if i < self.toks.length() {
    self.toks[i]
  } else {
    self.toks[self.toks.length() - 1]
  }
}

///|
fn Parser::advance(self : Parser) -> @lex.Token {
  let t = self.toks[self.pos]
  if !(t.kind is Eof) {
    self.pos += 1
  }
  t
}

///|
/// Span of the last consumed token.
fn Parser::prev(self : Parser) -> @ast.Span {
  if self.pos > 0 {
    self.toks[self.pos - 1].span
  } else {
    self.toks[0].span
  }
}

///|
fn Parser::span_from(self : Parser, start : @ast.Span) -> @ast.Span {
  let p = self.prev()
  if p.end < start.start {
    start
  } else {
    start.to(p)
  }
}

///|
fn Parser::start(self : Parser) -> @ast.Span {
  self.peek().span
}

///|
fn Parser::is_kw(self : Parser, kw : String) -> Bool {
  self.peek().is_kw(kw)
}

///|
fn Parser::is_kw_at(self : Parser, k : Int, kw : String) -> Bool {
  self.peek_at(k).is_kw(kw)
}

///|
fn Parser::is_punct(self : Parser, p : String) -> Bool {
  self.peek().is_punct(p)
}

///|
fn Parser::is_punct_at(self : Parser, k : Int, p : String) -> Bool {
  self.peek_at(k).is_punct(p)
}

///|
fn Parser::eat_kw(self : Parser, kw : String) -> Bool {
  if self.is_kw(kw) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::eat_punct(self : Parser, p : String) -> Bool {
  if self.is_punct(p) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::expect_kw(self : Parser, kw : String) -> Unit raise @ast.SyntaxError {
  if !self.eat_kw(kw) {
    raise self.error()
  }
}

///|
fn Parser::expect_punct(
  self : Parser,
  p : String,
) -> Unit raise @ast.SyntaxError {
  if !self.eat_punct(p) {
    raise self.error()
  }
}

///|
fn syntax_error(
  number : Int,
  message : String,
  span : @ast.Span,
) -> @ast.SyntaxError {
  @ast.SyntaxError(number~, severity=15, state=1, message~, span~)
}

///|
/// "Incorrect syntax near ..." for token `t` (102, or 156 for keywords).
fn near(t : @lex.Token) -> @ast.SyntaxError {
  match t.kind {
    Word if is_reserved(t.text) =>
      syntax_error(
        156,
        "Incorrect syntax near the keyword '\{t.text}'.",
        t.span,
      )
    _ => syntax_error(102, "Incorrect syntax near '\{t.text}'.", t.span)
  }
}

///|
/// Syntax error at the current token; at end of input SQL Server reports the
/// last token of the batch.
fn Parser::error(self : Parser) -> @ast.SyntaxError {
  let t = self.peek()
  if t.kind is Eof && self.pos > 0 {
    near(self.toks[self.pos - 1])
  } else {
    near(t)
  }
}

///|
fn Parser::enter(self : Parser) -> Unit raise @ast.SyntaxError {
  self.depth += 1
  if self.depth > MAX_DEPTH {
    raise syntax_error(
      191,
      "Some part of your SQL statement is nested too deeply. Rewrite the query or break it up into smaller queries.",
      self.start(),
    )
  }
}

///|
fn Parser::leave(self : Parser) -> Unit {
  self.depth -= 1
}

///|
/// True when the current token is a word that can be a bare identifier.
fn Parser::at_ident(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    QuotedIdent => true
    Word => !is_reserved(t.text)
    _ => false
  }
}

///|
fn tok_ident(t : @lex.Token) -> @ast.Ident {
  { name: t.text, quoted: t.kind is QuotedIdent, span: t.span, }
}

///|
/// Bare (non-reserved) or delimited identifier.
fn Parser::ident(self : Parser) -> @ast.Ident raise @ast.SyntaxError {
  if self.at_ident() {
    tok_ident(self.advance())
  } else {
    raise self.error()
  }
}

///|
/// Any word (reserved or not) or delimited identifier.
fn Parser::any_ident(self : Parser) -> @ast.Ident raise @ast.SyntaxError {
  let t = self.peek()
  if t.kind is Word || t.kind is QuotedIdent {
    tok_ident(self.advance())
  } else {
    raise self.error()
  }
}

///|
/// `a.b.c`, `a..c`; the head must be a bare or delimited identifier, later
/// parts may be any word.
fn Parser::object_name(self : Parser) -> @ast.ObjectName raise @ast.SyntaxError {
  let start = self.start()
  let parts = [self.ident()]
  while self.is_punct(".") {
    self.pos += 1
    if self.is_punct(".") {
      let s = self.peek().span
      parts.push({ name: "", quoted: false, span: { ..s, end: s.start, }, })
    } else {
      parts.push(self.any_ident())
    }
  }
  if parts.length() > 4 {
    raise near(self.toks[self.pos - 1])
  }
  { parts, span: self.span_from(start), }
}

///|
/// Comma-separated identifiers inside parentheses: `(a, b)`.
fn Parser::paren_idents(
  self : Parser,
) -> Array[@ast.Ident] raise @ast.SyntaxError {
  self.expect_punct("(")
  let out = [self.ident()]
  while self.eat_punct(",") {
    out.push(self.ident())
  }
  self.expect_punct(")")
  out
}

///|
/// Upper-cased text of a word token.
fn upper(t : @lex.Token) -> String {
  t.text.to_upper()
}

///|
fn Parser::slice(self : Parser, span : @ast.Span) -> String {
  self.src.view(start_offset=span.start, end_offset=span.end).to_owned()
}
