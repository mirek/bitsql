// INFO 2701 for database-qualified temp table names (captured: msduck
// gaps-temp_tables #005, corpus stmts/temp-qualified-names):
//
// - `db..#t` / `db.schema.#t` names a temp table whatever `db` is (any
//   name, even a missing database); compiling it sends INFO 2701 state 99
//   "Database name '<db as written>' ignored, referencing object in
//   tempdb." with the line of the reference.
// - Compiling a batch (or EXEC string / sp_executesql text) sends one 2701
//   per reference, in text order, before anything runs.
// - A statement whose temp table did not exist at that point is compiled
//   again when it runs (deferred name resolution) and sends its 2701s
//   again right before it executes (then 208 if the table is still
//   missing).

///|
/// Database-qualified temp table references in `text`: (offset, line,
/// database as written, temp table name). Token-level: strings and
/// comments do not count.
fn temp_db_references(text : String) -> Array[(Int, Int, String, String)] {
  let out = []
  if !text.contains("#") {
    return out
  }
  let toks = @lex.lex(text) catch { _ => return out }
  let ident = (t : @lex.Token) => t.kind is (Word | QuotedIdent)
  for k, t in toks {
    guard ident(t) && !t.text.has_prefix("#") else { continue }
    if k > 0 && toks[k - 1].is_punct(".") {
      continue
    }
    guard toks.get(k + 1) is Some(d1) && d1.is_punct(".") else { continue }
    // db..#t or db.schema.#t
    let name_at = match (toks.get(k + 2), toks.get(k + 3)) {
      (Some(d2), _) if d2.is_punct(".") => k + 3
      (Some(s), Some(d2)) if ident(s) && d2.is_punct(".") => k + 4
      _ => continue
    }
    guard toks.get(name_at) is Some(n) && ident(n) && n.text.has_prefix("#") else {
      continue
    }
    if toks.get(name_at + 1) is Some(after) && after.is_punct(".") {
      continue
    }
    out.push((t.span.start, t.span.line, t.text, n.text))
  }
  out
}

///|
/// Compiles the temp table references of `text`: sends their 2701s and
/// returns the ones whose table does not exist yet (sent again when their
/// statement runs).
fn Session::compile_temp_refs(
  self : Session,
  text : String,
) -> Array[(Int, Int, String)] {
  let deferred = []
  for r in temp_db_references(text) {
    let (offset, line, db, name) = r
    self.info(2701, 99, temp_db_message(db), line)
    if self.temp.lookup("dbo", name) is None {
      deferred.push((offset, line, db))
    }
  }
  deferred
}

///|
fn temp_db_message(db : String) -> String {
  "Database name '\{db}' ignored, referencing object in tempdb."
}

///|
/// Before a (non-compound) statement runs: the 2701s of its deferred
/// temp table references.
fn Session::recompile_temp_refs(self : Session, s : @ast.Stmt) -> Unit {
  if self.temp_db_refs.is_empty() ||
    s.kind is (If(_, _, _) | While(_, _) | Block(_) | TryCatch(_, _)) {
    return
  }
  let keep = []
  for r in self.temp_db_refs {
    let (offset, line, db) = r
    if offset >= s.span.start && offset < s.span.end {
      self.info(2701, 99, temp_db_message(db), line)
    } else {
      keep.push(r)
    }
  }
  self.temp_db_refs = keep
}
