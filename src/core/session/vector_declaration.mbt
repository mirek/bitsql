///|
// A rejected vector descriptor leaves its declared variable unavailable to
// the following statement. Captured: sql2025/vector-descriptors. Recovery
// needs tokens here because the rejected declaration has no AST.
fn vector_decl_reference_error(
  text : String,
  error : @ast.SyntaxError,
) -> @ast.SyntaxError? {
  if error.number() != 102 {
    return None
  }
  let toks = @lex.lex(text) catch { _ => return None }
  let @ast.SyntaxError(span~, ..) = error
  let mut at = -1
  for i, t in toks {
    if t.span.start == span.start {
      at = i
      break
    }
  }
  if at < 0 {
    return None
  }
  let mut variable : String? = None
  let declared_before : Set[String] = Set([])
  for i in 0..<at {
    if toks[i].text == ";" {
      variable = None
    }
    if toks[i].is_kw("DECLARE") &&
      i + 2 < toks.length() &&
      toks[i + 1].kind is Variable {
      let name = toks[i + 1].text.to_lower()
      if toks[i + 2].is_kw("VECTOR") && !declared_before.contains(name) {
        variable = Some(name)
      } else {
        variable = None
      }
      declared_before.add(name)
    }
  }
  guard variable is Some(name) else { return None }
  let mut following = false
  for i in at..<toks.length() {
    let t = toks[i]
    if t.text == ";" || t.is_kw("SELECT") {
      following = true
    }
    if !following {
      continue
    }
    if t.is_kw("DECLARE") &&
      i + 1 < toks.length() &&
      toks[i + 1].kind is Variable &&
      toks[i + 1].text.to_lower() == name {
      return None
    }
    if t.kind is Variable && t.text.to_lower() == name {
      return Some(
        @ast.SyntaxError(
          number=137,
          message="Must declare the scalar variable \"\{t.text}\".",
          span=t.span,
          state=2,
          severity=15,
        ),
      )
    }
  }
  None
}

///|
/// Unknown vector options have a parser 155 followed by a semantic 153.
/// Keep the latter out of the parser-only syntax contract.
fn vector_index_option_error(
  text : String,
  error : @ast.SyntaxError,
) -> @ast.SyntaxError? {
  if error.number() != 155 ||
    error.state() != 1 ||
    !error
    .message()
    .has_suffix("is not a recognized CREATE VECTOR INDEX option.") {
    return None
  }
  let @ast.SyntaxError(span~, ..) = error
  let tokens = @lex.lex(text) catch { _ => return None }
  guard tokens.iter().find_first(t => t.span.start == span.start) is Some(token) else {
    return None
  }
  Some(
    @ast.SyntaxError(
      number=153,
      state=1,
      severity=15,
      message="Invalid usage of the option \{token.text} in the INDEX statement.",
      span~,
    ),
  )
}
