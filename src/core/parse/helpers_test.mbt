///|
/// Renders a batch as S-expressions (one statement per line) or its error.
fn sx(sql : String) -> String {
  try @parse.parse_batch(sql) catch {
    e => e.render()
  } noraise {
    ss => ss.map(s => s.to_sexp()).join("\n")
  }
}

///|
fn ex(sql : String) -> String {
  try @parse.parse_expr(sql) catch {
    e => e.render()
  } noraise {
    e => e.to_sexp()
  }
}
