///|
/// Parsed batches and statements by source text, shared by all sessions.
/// Parsing is a pure function of the text (the parser reads no session
/// state; QUOTED_IDENTIFIER OFF is rejected before parsing) and nothing
/// mutates an AST after parsing, so a repeated text (sp_executesql
/// statement and parameter declarations, procedure bodies, an ORM's
/// prepared queries) reuses the first parse. Syntax errors are not cached:
/// their reporting path re-parses with error recovery anyway.
priv struct ParseCache {
  batches : Map[String, ParsedBatch]
  statements : Map[String, @ast.Stmt]
}

///|
priv struct ParsedBatch {
  stmts : Array[@ast.Stmt]
  /// Variable signatures (name and type of each known variable, in the
  /// frame's order) under which `precheck_batch` found nothing: it is a
  /// pure function of the statements, those types and the preview switch (its catalog
  /// callback only names the column of a failure).
  prechecked : Array[(Bool, Array[(String, @types.SqlType)])]
}

///|
/// Entries per map before it is emptied (a crude bound: workloads that
/// repeat texts repeat few of them).
const PARSE_CACHE_LIMIT : Int = 1024

///|
/// Longest text cached (longer ones are usually one-off DDL scripts).
const PARSE_CACHE_MAX_TEXT : Int = 65536

///|
/// Signatures remembered per batch text.
const PRECHECK_SIGNATURES : Int = 8

///|
fn ParseCache::new() -> ParseCache {
  { batches: Map([]), statements: Map([]), }
}

///|
fn Server::parse_batch(
  self : Server,
  text : String,
) -> Array[@ast.Stmt] raise @ast.SyntaxError {
  let cache = self.parse_cache.batches
  match cache.get(text) {
    Some(p) => p.stmts
    None => {
      let stmts = @parse.parse_batch(text)
      if text.length() <= PARSE_CACHE_MAX_TEXT {
        if cache.length() >= PARSE_CACHE_LIMIT {
          cache.clear()
        }
        cache[text] = { stmts, prechecked: [], }
      }
      stmts
    }
  }
}

///|
fn Server::parse_statement(
  self : Server,
  text : String,
) -> @ast.Stmt raise @ast.SyntaxError {
  let cache = self.parse_cache.statements
  match cache.get(text) {
    Some(stmt) => stmt
    None => {
      let stmt = @parse.parse_statement(text)
      if text.length() <= PARSE_CACHE_MAX_TEXT {
        if cache.length() >= PARSE_CACHE_LIMIT {
          cache.clear()
        }
        cache[text] = stmt
      }
      stmt
    }
  }
}

///|
fn var_signature(
  vars : Map[String, @bind.VarInfo],
) -> Array[(String, @types.SqlType)] {
  let out = []
  for k, v in vars {
    out.push((k, v.ty))
  }
  out
}

///|
/// `precheck_batch(stmts, vars, ..)` is known to find nothing (`stmts` is
/// the cached parse of `text`).
fn Server::prechecked(
  self : Server,
  text : String,
  stmts : Array[@ast.Stmt],
  signature : Array[(String, @types.SqlType)],
  preview : Bool,
) -> Bool {
  match self.parse_cache.batches.get(text) {
    Some(p) if physical_equal(p.stmts, stmts) =>
      p.prechecked.iter().any(s => s == (preview, signature))
    _ => false
  }
}

///|
fn Server::remember_prechecked(
  self : Server,
  text : String,
  stmts : Array[@ast.Stmt],
  signature : Array[(String, @types.SqlType)],
  preview : Bool,
) -> Unit {
  match self.parse_cache.batches.get(text) {
    Some(p) if physical_equal(p.stmts, stmts) &&
      p.prechecked.length() < PRECHECK_SIGNATURES =>
      p.prechecked.push((preview, signature))
    _ => ()
  }
}
