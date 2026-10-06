///|
/// SQL Server compiles a whole batch before running it: a type error in
/// any statement (206, 257, 402, 8116, 8117) fails the batch with nothing
/// run, also inside an IF branch or TRY block (captured:
/// conversion/datetime-arithmetic, msduck try-binding-error,
/// gaps-computed session-variant-writes). bitsql binds statement by
/// statement, so this pass binds the batch up front, in compile-only mode,
/// when nothing in it can change what later statements bind against (no
/// DDL, EXEC, USE, SELECT INTO, cursors or binding-relevant SET options);
/// a statement naming a missing object is left to run time (deferred name
/// resolution). Returns the first failing statement's errors (earlier
/// binder errors it collected first) with its line.
fn Session::prebind_batch(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> (Array[@types.SqlError], Int)? {
  if !stmts.iter().all(prebindable) {
    return None
  }
  let out_len = self.out.length()
  let cur_cmd = self.cur_cmd
  let compile_only = self.compile_only
  let error = self.rt.error
  self.compile_only = true
  self.prebound_candidate = prebound_candidate(stmts)
  defer {
    self.prebound_candidate = None
    self.compile_only = compile_only
    self.rt.error = error
    self.cur_cmd = cur_cmd
    while self.out.length() > out_len {
      ignore(self.out.pop())
    }
  }
  self.prebind_list(stmts)
}

///|
fn Session::prebind_list(
  self : Session,
  stmts : Array[@ast.Stmt],
) -> (Array[@types.SqlError], Int)? {
  for s in stmts {
    match self.prebind_stmt(s) {
      Some(e) => return Some(e)
      None => ()
    }
  }
  None
}

///|
fn Session::prebind_stmt(
  self : Session,
  s : @ast.Stmt,
) -> (Array[@types.SqlError], Int)? {
  let line = s.span.line
  let attempt = (f : () -> Unit raise) => {
    self.deferred.clear()
    try f() catch {
      @types.SqlError(number~, ..) as e if compile_type_error(number) =>
        Some((self.deferred.copy() + [e], line))
      _ => None
    } noraise {
      _ => None
    }
  }
  let expr = (e : @ast.Expr) => {
    attempt(() => ignore(@bind.bind_expr(self.env(), e)))
  }
  match s.kind {
    Select({ body: Select(sel), .. }) if sel.items.length() > 0 &&
      sel.items.iter().all(i => i.kind is Assign(_, _, _)) =>
      attempt(() => self.compile_statement(s))
    Select(q) => {
      let mut indexed_error : @types.SqlError? = None
      let result = attempt(() => {
        let out_len = self.out.length()
        let cur_cmd = self.cur_cmd
        let error = self.rt.error
        let bound = @bind.bind_query(self.env(), q)
        self.check_json_index_paths(bound.plan) catch {
          e => indexed_error = Some(e)
        }
        self.keep_prebound(q, bound, out_len, cur_cmd, error)
      })
      match indexed_error {
        Some(e) => Some(([e], line))
        None => result
      }
    }
    Insert(_) | Update(_) | Delete(_) | Merge(_) | Print(_) =>
      attempt(() => self.compile_statement(s))
    SetVarMethod(name, meth, args) =>
      try ignore(self.bind_var_mutator(name, meth.name, args)) catch {
        @types.SqlError(number~, ..) as e if number
          is (137 | 174 | 258 | 313 | 8116 | 8144) => Some(([e], line))
        _ => None
      } noraise {
        _ => None
      }
    SetVar(name, op, e) =>
      attempt(() => ignore(self.bind_assignment(name, op, e)))
    Declare(vars) => {
      for v in vars {
        if v.init is Some(i) {
          match attempt(() => ignore(self.bind_assignment(v.name, Assign, i))) {
            Some(e) => return Some(e)
            None => ()
          }
        }
      }
      None
    }
    If(c, a, b) =>
      match expr(c) {
        Some(e) => Some(e)
        None =>
          match self.prebind_stmt(a) {
            Some(e) => Some(e)
            None =>
              match b {
                Some(x) => self.prebind_stmt(x)
                None => None
              }
          }
      }
    While(c, b) =>
      match expr(c) {
        Some(e) => Some(e)
        None => self.prebind_stmt(b)
      }
    Block(list) => self.prebind_list(list)
    TryCatch(a, b) =>
      match self.prebind_list(a) {
        Some(e) => Some(e)
        None => self.prebind_list(b)
      }
    _ => None
  }
}

///|
/// A pre-bound query and the binder's deferred errors it left.
priv struct Prebound {
  query : @ast.Query
  bound : @bind.BoundQuery
  deferred : Array[@types.SqlError]
}

///|
/// Keeps the pre-bind's plan of the batch's first statement, a plain query
/// (`prebound_candidate`), for `exec_query` when it runs next: binding is
/// deterministic, nothing the binder reads changes before that statement
/// runs (no transaction whose views `refresh_tx` could rebase; the
/// statement prologue resets only per-statement runtime state), and the
/// bind left no other trace (no output, CurCmd or @@ERROR change) that the
/// run's own binding would have repeated. Its deferred errors are replayed.
fn Session::keep_prebound(
  self : Session,
  q : @ast.Query,
  bound : @bind.BoundQuery,
  out_len : Int,
  cur_cmd : Int,
  error : Int,
) -> Unit {
  guard self.prebound_candidate is Some(c) && physical_equal(c, q) else {
    return
  }
  self.prebound_candidate = None
  if self.tx is None &&
    self.out.length() == out_len &&
    self.cur_cmd == cur_cmd &&
    self.rt.error == error {
    self.prebound = Some({ query: q, bound, deferred: self.deferred.copy(), })
  }
}

///|
/// The first statement when it is a query `exec_query` runs as written:
/// not a variable assignment and without INTO.
fn prebound_candidate(stmts : Array[@ast.Stmt]) -> @ast.Query? {
  guard stmts.get(0) is Some({ kind: Select(q), .. }) else { return None }
  match q.body {
    Select(sel) if sel.into is Some(_) ||
      sel.items.iter().any(i => i.kind is Assign(_, _, _)) => None
    _ => Some(q)
  }
}

///|
/// Errors the binder raises that SQL Server raises while compiling.
fn compile_type_error(number : Int) -> Bool {
  number
  is (102
  | 174
  | 189
  | 206
  | 257
  | 402
  | 1001
  | 2717
  | 8116
  | 8117
  | 42238
  | 42246)
}

///|
/// Statements after which later statements still bind the same way.
fn prebindable(s : @ast.Stmt) -> Bool {
  match s.kind {
    Select({ body: Select(sel), .. }) => sel.into is None
    Select(_) => true
    Insert({ source: InsertExec(_), .. }) => false
    Insert(_) | Update(_) | Delete(_) | Merge(_) => true
    Declare(_) | SetVar(_, _, _) | SetVarMethod(_, _, _) | Print(_) => true
    Break | Continue | Return(_) => true
    BeginTran(..) | Commit(..) | Rollback(..) | Save(..) => true
    Throw(_) | RaisError(_, ..) => true
    SetIsolation(_) => true
    SetOption(names, _) =>
      names
      .iter()
      .all(n => n.to_upper() is ("NOCOUNT" | "XACT_ABORT" | "LOCK_TIMEOUT"))
    If(_, a, b) => prebindable(a) && b.map(prebindable).unwrap_or(true)
    While(_, b) => prebindable(b)
    Block(list) => list.iter().all(prebindable)
    TryCatch(a, b) => a.iter().all(prebindable) && b.iter().all(prebindable)
    _ => false
  }
}
