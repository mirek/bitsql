///|
/// Named windows (`SELECT … WINDOW w AS (…)`, `OVER w`, `OVER (w …)`),
/// resolved while parsing into plain OVER clauses. Rules captured on SQL
/// Server 17 (tail5/b1-named-window, msduck distribution-reference#006):
/// names are case-insensitive and local to their SELECT (a subquery does not
/// see them; its query's ORDER BY does); a window may name another one
/// (also defined later); OVER/definition elements (PARTITION BY, ORDER BY,
/// frame) may only be added, not repeated. Errors are compile errors of the
/// whole batch: 5362 "Window 'x' is undefined." (state 3 without a WINDOW
/// clause, 4 when the clause lacks the name, 7 inside a definition), 16211
/// repeated name, 5365 cycle, 5367 element redefined in a definition, 4123
/// element repeated in OVER, 5364 frame without ORDER BY, 5366 ranking
/// (state 3) / offset and value (state 2) functions over a named window
/// without ORDER BY. `OVER (w)` alone is 102 near ')'.
priv struct WindowScope {
  /// lower-cased name → resolved window
  defs : Map[String, @ast.Over]
  /// the look-ahead found a WINDOW clause
  has_clause : Bool
  /// its definitions did not parse: the real parse reports the error
  failed : Bool
  /// token range of the clause (`WINDOW` .. after the last definition)
  start : Int
  end : Int
}

///|
priv struct WindowDef {
  name : @ast.Ident
  base : @ast.Ident?
  partition_by : Array[@ast.Expr]
  order_by : Array[@ast.OrderItem]
  frame : @ast.Frame?
  span : @ast.Span
}

///|
fn Parser::defer_error(self : Parser, e : @ast.SyntaxError) -> Unit {
  if self.deferred is None {
    self.deferred = Some(e)
  }
}

///|
fn window_error(
  number : Int,
  state : Int,
  message : String,
  span : @ast.Span,
) -> @ast.SyntaxError {
  @ast.SyntaxError(number~, severity=15, state~, message~, span~)
}

///|
fn window_key(id : @ast.Ident) -> String {
  id.name.to_upper()
}

///|
fn ident_token(t : @lex.Token) -> Bool {
  match t.kind {
    QuotedIdent => true
    Word => !is_reserved(t.text)
    _ => false
  }
}

///|
/// `WINDOW name AS (` at token `j`.
fn Parser::window_clause_at(self : Parser, j : Int) -> Bool {
  j + 3 < self.toks.length() &&
  self.toks[j].is_kw("WINDOW") &&
  ident_token(self.toks[j + 1]) &&
  self.toks[j + 2].is_kw("AS") &&
  self.toks[j + 3].is_punct("(")
}

///|
/// Words that end the look-ahead for a SELECT's WINDOW clause at its own
/// nesting level (set operations, the query's ORDER BY/OPTION, a new
/// statement).
let window_scan_stops : Array[String] = [
  "UNION", "EXCEPT", "INTERSECT", "ORDER", "OPTION", "SELECT", "INSERT", "UPDATE",
  "DELETE", "MERGE", "DECLARE", "SET", "IF", "WHILE", "EXEC", "EXECUTE", "PRINT",
  "RETURN", "RAISERROR", "THROW", "CREATE", "ALTER", "DROP", "TRUNCATE", "USE", "GO",
  "COMMIT", "ROLLBACK", "SAVE", "GOTO", "WAITFOR", "BREAK", "CONTINUE",
]

///|
/// Look ahead from the select list for this SELECT's WINDOW clause and
/// resolve its definitions (errors deferred).
fn Parser::prescan_windows(self : Parser) -> WindowScope? {
  let mut depth = 0
  let mut j = self.pos
  let mut found = -1
  while j < self.toks.length() {
    let t = self.toks[j]
    if t.kind is Eof || t.is_punct(";") {
      break
    }
    if t.is_punct("(") {
      depth += 1
    } else if t.is_punct(")") {
      if depth == 0 {
        break
      }
      depth -= 1
    } else if depth == 0 {
      if self.window_clause_at(j) {
        found = j
        break
      }
      if t.kind is Word &&
        window_scan_stops.contains(t.text.to_upper()) &&
        j > self.pos {
        break
      }
    }
    j += 1
  }
  if found < 0 {
    return None
  }
  let saved_pos = self.pos
  let saved_depth = self.depth
  let saved_windows = self.windows
  // definitions see no other scope while parsing
  self.windows = None
  self.pos = found
  let scope = try {
    let defs = self.window_defs()
    let end = self.pos
    {
      defs: self.resolve_windows(defs),
      has_clause: true,
      failed: false,
      start: found,
      end,
    }
  } catch {
    _ =>
      {
        defs: Map([]),
        has_clause: true,
        failed: true,
        start: found,
        end: found,
      }
  }
  self.pos = saved_pos
  self.depth = saved_depth
  self.windows = saved_windows
  Some(scope)
}

///|
/// `WINDOW name AS (spec) [, name AS (spec)]...` at the current token.
fn Parser::window_defs(
  self : Parser,
) -> Array[WindowDef] raise @ast.SyntaxError {
  self.expect_kw("WINDOW")
  let out : Array[WindowDef] = []
  while true {
    let start = self.start()
    let name = self.ident()
    self.expect_kw("AS")
    self.expect_punct("(")
    let base = self.window_base(allow_alone=true)
    let (partition_by, order_by, frame) = self.window_elements(
      frame_needs_keys=false,
    )
    self.expect_punct(")")
    out.push({
      name,
      base,
      partition_by,
      order_by,
      frame,
      span: self.span_from(start),
    })
    if !self.eat_punct(",") {
      break
    }
  }
  out
}

///|
/// An optional leading window name inside `(`; `OVER (w)` alone is 102 near
/// ')' (a definition `AS (w)` is fine).
fn Parser::window_base(
  self : Parser,
  allow_alone~ : Bool,
) -> @ast.Ident? raise @ast.SyntaxError {
  let t = self.peek()
  if !ident_token(t) ||
    t.is_kw("PARTITION") ||
    t.is_kw("ROWS") ||
    t.is_kw("RANGE") {
    return None
  }
  let id = self.ident()
  if !allow_alone && self.is_punct(")") {
    raise self.error()
  }
  Some(id)
}

///|
/// `[PARTITION BY ...] [ORDER BY ...] [ROWS|RANGE ...]` of a window.
fn Parser::window_elements(
  self : Parser,
  frame_needs_keys~ : Bool,
) -> (Array[@ast.Expr], Array[@ast.OrderItem], @ast.Frame?) raise @ast.SyntaxError {
  let partition_by = []
  if self.is_kw("PARTITION") && self.is_kw_at(1, "BY") {
    self.pos += 2
    partition_by.push(self.scalar())
    while self.eat_punct(",") {
      partition_by.push(self.scalar())
    }
  }
  let order_by = if self.is_kw("ORDER") {
    self.pos += 1
    self.expect_kw("BY")
    self.order_items()
  } else {
    []
  }
  let frame : @ast.Frame? = if self.is_kw("ROWS") || self.is_kw("RANGE") {
    // captured: a frame with neither PARTITION BY nor ORDER BY is a syntax
    // error at ROWS/RANGE (with PARTITION BY only it is 10756)
    if frame_needs_keys && partition_by.is_empty() && order_by.is_empty() {
      raise self.error()
    }
    let unit : @ast.FrameUnit = if self.eat_kw("ROWS") {
      Rows
    } else {
      self.pos += 1
      Range
    }
    if self.eat_kw("BETWEEN") {
      let s = self.frame_bound(start=true)
      self.expect_kw("AND")
      let e = self.frame_bound(start=false)
      Some({ unit, start: s, end: Some(e), })
    } else {
      Some({ unit, start: self.frame_bound(start=true), end: None, })
    }
  } else {
    None
  }
  (partition_by, order_by, frame)
}

///|
/// Resolves the definitions of a WINDOW clause (errors deferred).
fn Parser::resolve_windows(
  self : Parser,
  defs : Array[WindowDef],
) -> Map[String, @ast.Over] {
  let raw : Map[String, WindowDef] = Map([])
  for d in defs {
    let k = window_key(d.name)
    if raw.contains(k) {
      self.defer_error(
        window_error(
          16211,
          1,
          "Cannot repeat window name in the WINDOW clause.",
          d.name.span,
        ),
      )
      continue
    }
    raw[k] = d
  }
  let out : Map[String, @ast.Over] = Map([])
  for d in defs {
    let k = window_key(d.name)
    if !out.contains(k) {
      ignore(self.resolve_window(k, raw, out, []))
    }
  }
  out
}

///|
fn Parser::resolve_window(
  self : Parser,
  k : String,
  raw : Map[String, WindowDef],
  out : Map[String, @ast.Over],
  visiting : Array[String],
) -> @ast.Over? {
  if out.get(k) is Some(o) {
    return Some(o)
  }
  guard raw.get(k) is Some(d) else { return None }
  let mut o : @ast.Over = {
    partition_by: d.partition_by,
    order_by: d.order_by,
    frame: d.frame,
    span: d.span,
    ignore_nulls: false,
  }
  match d.base {
    Some(b) => {
      let bk = window_key(b)
      if visiting.contains(bk) {
        self.defer_error(
          window_error(
            5365,
            1,
            "Cyclic window references are not permitted.",
            b.span,
          ),
        )
        return None
      }
      // a window naming itself is undefined, not cyclic (captured)
      if !raw.contains(bk) || bk == k {
        self.defer_error(
          window_error(5362, 7, "Window '\{b.name}' is undefined.", b.span),
        )
        return None
      }
      guard self.resolve_window(bk, raw, out, [..visiting, k]) is Some(base) else {
        return None
      }
      match merge_window(base, o) {
        Some(m) => o = m
        None => {
          self.defer_error(
            window_error(
              5367,
              2,
              "Window specification defined in one window can not be redefined in another window.",
              b.span,
            ),
          )
          return None
        }
      }
    }
    None => ()
  }
  if o.frame is Some(_) && o.order_by.is_empty() {
    self.defer_error(frame_without_order(d.span))
  }
  out[k] = o
  Some(o)
}

///|
fn frame_without_order(span : @ast.Span) -> @ast.SyntaxError {
  window_error(
    5364, 1, "Window frame with ROWS or RANGE must have an ORDER BY clause.", span,
  )
}

///|
/// `base` extended by the elements of `ext`; None when an element is given
/// twice.
fn merge_window(base : @ast.Over, ext : @ast.Over) -> @ast.Over? {
  if (!base.partition_by.is_empty() && !ext.partition_by.is_empty()) ||
    (!base.order_by.is_empty() && !ext.order_by.is_empty()) ||
    (base.frame is Some(_) && ext.frame is Some(_)) {
    return None
  }
  Some({
    partition_by: if ext.partition_by.is_empty() {
      base.partition_by
    } else {
      ext.partition_by
    },
    order_by: if ext.order_by.is_empty() {
      base.order_by
    } else {
      ext.order_by
    },
    frame: if ext.frame is Some(_) {
      ext.frame
    } else {
      base.frame
    },
    span: ext.span,
    ignore_nulls: false,
  })
}

///|
/// The window a name refers to in the current SELECT (5362 deferred when
/// it is missing; an empty window stands in).
fn Parser::named_window(
  self : Parser,
  id : @ast.Ident,
  span : @ast.Span,
) -> @ast.Over {
  let empty : @ast.Over = {
    partition_by: [],
    order_by: [],
    frame: None,
    span,
    ignore_nulls: false,
  }
  match self.windows {
    Some(sc) if sc.has_clause =>
      match sc.defs.get(window_key(id)) {
        Some(o) => { ..o, span, }
        None => {
          // definitions that failed to parse report their own syntax error
          if !sc.failed {
            self.defer_error(
              window_error(
                5362,
                4,
                "Window '\{id.name}' is undefined.",
                id.span,
              ),
            )
          }
          empty
        }
      }
    _ => {
      self.defer_error(
        window_error(5362, 3, "Window '\{id.name}' is undefined.", id.span),
      )
      empty
    }
  }
}

///|
/// After HAVING: steps over the WINDOW clause found by the look-ahead (or
/// parses one it could not, to report its syntax error).
fn Parser::skip_window_clause(self : Parser) -> Unit raise @ast.SyntaxError {
  match self.windows {
    Some(sc) if !sc.failed && self.pos == sc.start => self.pos = sc.end
    _ => if self.window_clause_at(self.pos) { ignore(self.window_defs()) }
  }
}

///|
/// 5366: ranking and offset functions over a named window need ORDER BY.
fn Parser::check_named_window_order(
  self : Parser,
  name : @ast.ObjectName,
  over : @ast.Over,
) -> Unit {
  if !self.over_named || !over.order_by.is_empty() {
    return
  }
  let fname = name.base()
  let state = match fname.to_upper() {
    "ROW_NUMBER"
    | "RANK"
    | "DENSE_RANK"
    | "NTILE"
    | "PERCENT_RANK"
    | "CUME_DIST" => 3
    "LAG" | "LEAD" | "FIRST_VALUE" | "LAST_VALUE" => 2
    _ => return
  }
  self.defer_error(
    window_error(
      5366,
      state,
      "The function '\{fname.to_lower()}' must have an OVER clause or a WINDOW with ORDER BY.",
      over.span,
    ),
  )
}

///|
/// A scope whose names are not checked (resolve to an empty window).
fn unchecked_windows() -> WindowScope {
  { defs: Map([]), has_clause: true, failed: true, start: -1, end: -1, }
}

///|
/// Runs `f` with NEXT VALUE FOR … OVER forbidden (11717: UPDATE, MERGE,
/// DEFAULT; captured: tail5/b1-next-value-over).
fn[T] Parser::forbid_nvf_over(
  self : Parser,
  f : () -> T raise @ast.SyntaxError,
) -> T raise @ast.SyntaxError {
  let saved = self.nvf_over_forbidden
  self.nvf_over_forbidden = true
  errdefer {
    self.nvf_over_forbidden = saved
  }
  let r = f()
  self.nvf_over_forbidden = saved
  r
}
