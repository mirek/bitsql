///|
/// A suspended batch resumes at its pending statement. Earlier statements
/// remain committed and their response items remain part of this request.
priv struct BatchResume {
  remaining : Array[@ast.Stmt]
  query_store_seen : Int
  waits_seen : Int
  configuration_reads_seen : Int
  embeddings_seen : Int
  clock_seen : Int
  temp_db_refs : Array[(Int, Int, String)]
}

///|
fn Frame::copy(self : Frame) -> Frame {
  {
    ..self,
    vars: copy_map(self.vars),
    values: self.values.copy(),
    tables: copy_map(self.tables),
    cursors: copy_map(self.cursors),
    cursor_vars: copy_map(self.cursor_vars),
    cursor_params: Set::from_array(self.cursor_params.to_array()),
    read_only_tvps: Set::from_array(self.read_only_tvps.to_array()),
    owned: Set::from_array(self.owned.to_array()),
    decl_sites: copy_map(self.decl_sites),
  }
}

///|
/// BEGIN/END has no variable or transaction scope. Flatten only the outer
/// batch's transparent blocks so a wait resumes at the actual statement.
fn batch_statements(stmts : Array[@ast.Stmt]) -> Array[@ast.Stmt] {
  let out = []
  fn add(stmts : Array[@ast.Stmt]) -> Unit {
    for stmt in stmts {
      match stmt.kind {
        Block(inner) => add(inner)
        _ => out.push(stmt)
      }
    }
  }
  add(stmts)
  out
}

///|
fn[K : Hash + Eq, V] restore_map(
  target : Map[K, V],
  source : Map[K, V],
) -> Unit {
  target.clear()
  for k, v in source {
    target[k] = v
  }
}

///|
fn Frame::restore(self : Frame, saved : Frame) -> Unit {
  restore_map(self.vars, saved.vars)
  self.values.clear()
  self.values.append(saved.values)
  restore_map(self.tables, saved.tables)
  restore_map(self.cursors, saved.cursors)
  restore_map(self.cursor_vars, saved.cursor_vars)
  restore_map(self.decl_sites, saved.decl_sites)
  self.cursor_params.clear()
  for k in saved.cursor_params {
    self.cursor_params.add(k)
  }
  self.read_only_tvps.clear()
  for k in saved.read_only_tvps {
    self.read_only_tvps.add(k)
  }
  self.owned.clear()
  for k in saved.owned {
    self.owned.add(k)
  }
  self.line_mark = saved.line_mark
  self.module_settings = saved.module_settings
  self.worst = saved.worst
}

///|
fn Session::continue_statements(self : Session) -> Unit raise {
  guard self.batch_resume is Some(r) else {
    raise @types.not_supported("missing suspended statement")
  }
  self.batch_resume = None
  self.query_store_seen = r.query_store_seen
  self.waits_seen = r.waits_seen
  self.configuration_reads_seen = r.configuration_reads_seen
  self.embeddings_seen = r.embeddings_seen
  self.rt.clock_seen = r.clock_seen
  self.rt.clock_cursor = 0
  self.temp_db_refs = r.temp_db_refs
  self.exec_list(r.remaining)
}
