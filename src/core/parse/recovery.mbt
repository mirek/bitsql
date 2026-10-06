///|
/// Every syntax error SQL Server reports for a batch, in order (empty when
/// it parses). After an error the parser recovers like SQL Server's yacc
/// parser: an error at `WITH` also reports 319 there (the `WITH` restarts as
/// an unterminated CTE statement; captured: tail/tablevar-hints, msduck
/// gaps-merge#008), then statements restart at later tokens and a further
/// error is reported only once three tokens were accepted since the last
/// one (yacc's error-recovery rule; captured: `MERGE @t WITH (HOLDLOCK) AS x
/// USING (SELECT 1 AS a) s` adds 102 near 's', `... VALUES (1) SELECT 2 x
/// y` 102 near 'y'; tail5/b1-syntax-recovery). Only 102/156/319 recover;
/// other numbers end parsing.
pub fn batch_errors(src : String) -> Array[@ast.SyntaxError] {
  let p = new_parser(src) catch { e => return [e] }
  let first = try {
    ignore(p.stmt_list(never, top=true))
    return match p.deferred {
      Some(e) => [e]
      None => []
    }
  } catch {
    e => e
  }
  let errors = [first]
  // Once CREATE VECTOR INDEX has entered its column grammar, WITH starts
  // a fresh CTE diagnostic even with fewer than three accepted tokens.
  // A rejected modifier (CREATE UNIQUE VECTOR INDEX) never enters it.
  let vector_index = match token_index(p, first) {
    Some(i) => {
      let mut found = false
      let mut j = i - 1
      while j >= 0 && p.toks[j].text != ";" {
        if p.toks[j].is_kw("CREATE") {
          found = j + 2 < i &&
            p.toks[j + 1].is_kw("VECTOR") &&
            p.toks[j + 2].is_kw("INDEX")
          break
        }
        j -= 1
      }
      found
    }
    None => false
  }
  let eof = p.toks.length() - 1 // index of the Eof token
  let mut last = first
  while recoverable(last.number()) {
    guard token_index(p, last) is Some(i) else { break }
    let mut q = i
    if p.toks[i].is_kw("WITH") {
      if last.number() != 319 {
        errors.push(
          syntax_error(
            319,
            "Incorrect syntax near the keyword 'with'. If this statement is a common table expression, an xmlnamespaces clause or a change tracking context clause, the previous statement must be terminated with a semicolon.",
            p.toks[i].span,
          ),
        )
      }
      q = i + 1
    }
    // restart statements at q, q+1, ... until one error is reported
    let mut reported : @ast.SyntaxError? = None
    while q < eof && reported is None {
      p.pos = q
      p.depth = 0
      p.windows = None
      try {
        ignore(p.stmt_list(never, resumed=true))
        q = eof
      } catch {
        e =>
          match token_index(p, e) {
            Some(j) if j - q >= 3 || (vector_index && e.number() == 319) =>
              reported = Some(e)
            Some(j) if j >= q => q = j + 1
            _ => q = q + 1
          }
      }
    }
    match reported {
      Some(e) => {
        errors.push(e)
        last = e
      }
      None => break
    }
  }
  errors
}

///|
fn recoverable(n : Int) -> Bool {
  n == 102 || n == 156 || n == 319
}

///|
/// Index of the token an error points at (the last token for errors
/// reported at end of input).
fn token_index(p : Parser, e : @ast.SyntaxError) -> Int? {
  let SyntaxError(span~, ..) = e
  for i, t in p.toks {
    if t.span.start == span.start && !(t.kind is Eof) {
      return Some(i)
    }
  }
  None
}
