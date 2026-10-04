///|
fn new_parser(src : String) -> Parser raise @ast.SyntaxError {
  {
    src,
    toks: @lex.lex(src),
    pos: 0,
    depth: 0,
    in_procedure: false,
    table_variable: false,
  }
}

///|
/// Parses one T-SQL batch (no `GO`; see `@lex.split_go_batches`) into its
/// statements. Raises a `SyntaxError` carrying SQL Server's error number
/// (102 / 156 incorrect syntax, 105 / 113 lexical, 111 module not first in
/// batch, 319 CTE after unterminated statement, 10713 MERGE without `;`,
/// 191 nesting too deep) and the line of the offending token. Never panics.
pub fn parse_batch(src : String) -> Array[@ast.Stmt] raise @ast.SyntaxError {
  let p = new_parser(src)
  p.stmt_list(never, top=true)
}

///|
/// Parses exactly one statement (an optional trailing `;` is allowed).
pub fn parse_statement(src : String) -> @ast.Stmt raise @ast.SyntaxError {
  let p = new_parser(src)
  while p.eat_punct(";") {

  }
  let s = p.statement(true)
  while p.eat_punct(";") {

  }
  if !(p.peek().kind is Eof) {
    raise p.error()
  }
  s
}

///|
/// Parses a standalone search condition / expression.
pub fn parse_expr(src : String) -> @ast.Expr raise @ast.SyntaxError {
  let p = new_parser(src)
  let e = p.cond()
  if !(p.peek().kind is Eof) {
    raise p.error()
  }
  e
}
