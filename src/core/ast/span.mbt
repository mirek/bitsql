///|
/// Source location of a token or AST node.
///
/// `start`/`end` are offsets in UTF-16 code units into the batch text (the
/// native `String` indexing of MoonBit, and also TDS's UCS-2 units), `end`
/// exclusive. `line` and `col` are 1-based and describe `start`; lines are
/// counted by `\n` only, which is what `ERROR_LINE()` reports.
pub(all) struct Span {
  start : Int
  end : Int
  line : Int
  col : Int
} derive(Eq, Debug)

///|
/// Span covering `self` through `other` (line/col of `self`).
pub fn Span::to(self : Span, other : Span) -> Span {
  { start: self.start, end: other.end, line: self.line, col: self.col, }
}

///|
/// Zero-width span used for synthesized nodes.
pub let empty_span : Span = { start: 0, end: 0, line: 1, col: 1, }

///|
/// A batch-level compile error with SQL Server's number, severity, state and
/// message text (e.g. 102 / 15 / 1 / "Incorrect syntax near 'x'.").
/// `span.line` is the line SQL Server reports.
pub(all) suberror SyntaxError {
  SyntaxError(
    number~ : Int,
    severity~ : Int,
    state~ : Int,
    message~ : String,
    span~ : Span
  )
} derive(Debug)

///|
pub fn SyntaxError::number(self : SyntaxError) -> Int {
  match self {
    SyntaxError(number~, ..) => number
  }
}

///|
pub fn SyntaxError::message(self : SyntaxError) -> String {
  match self {
    SyntaxError(message~, ..) => message
  }
}

///|
pub fn SyntaxError::state(self : SyntaxError) -> Int {
  match self {
    SyntaxError(state~, ..) => state
  }
}

///|
pub fn SyntaxError::line(self : SyntaxError) -> Int {
  match self {
    SyntaxError(span~, ..) => span.line
  }
}

///|
/// `Msg <number>, Level <severity>, State <state>, Line <line>: <message>`.
pub fn SyntaxError::render(self : SyntaxError) -> String {
  match self {
    SyntaxError(number~, severity~, state~, message~, span~) =>
      "Msg \{number}, Level \{severity}, State \{state}, Line \{span.line}: \{message}"
  }
}
