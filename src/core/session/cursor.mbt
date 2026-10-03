///|
/// A declared cursor. v1 supports STATIC (snapshot at OPEN) and FAST_FORWARD
/// / default cursors. The latter are read from a snapshot too, so if their
/// base tables change while open, FETCH raises an Emulator error instead of
/// silently returning stale rows (DYNAMIC/KEYSET semantics are out of scope).
priv struct CursorState {
  def : @ast.Cursor
  is_static : Bool
  fast_forward : Bool
  scroll : Bool
  mut rows : Array[Array[@types.Value]]?
  mut columns : Array[@ir.ResultColumn]
  mut pos : Int // index of the current row; -1 before the first
  mut tables : Array[(Int, Int)]
  mut opened : (@store.Db, @store.Db)?
}

///|
fn plan_tables(p : @ir.Plan, out : Array[(Int, Int)]) -> Unit {
  match p {
    Scan(scope~, id~, ..) => out.push((scope, id))
    Project(x, _)
    | Filter(x, _)
    | Sort(x, _)
    | Limit(x, _, _)
    | Distinct(x, _) => plan_tables(x, out)
    Join(_, a, b, _, ..) => {
      plan_tables(a, out)
      plan_tables(b, out)
    }
    UnionAll(parts) => parts.each(x => plan_tables(x, out))
    _ => ()
  }
}

///|
fn Session::find_cursor(
  self : Session,
  name : String,
  global : Bool,
) -> CursorState raise {
  let key = name.to_lower()
  if !global {
    let mut i = self.frames.length() - 1
    while i >= 0 {
      match self.frames[i].cursors.get(key) {
        Some(c) => return c
        None => ()
      }
      i -= 1
    }
  }
  match self.cursors.get(key) {
    Some(c) => c
    None =>
      raise @types.sql_error(
        16916,
        "A cursor with the name '\{name}' does not exist.",
      )
  }
}

///|
fn Session::exec_declare_cursor(self : Session, c : @ast.Cursor) -> Unit raise {
  let opts = c.options
  for o in opts {
    if o == "DYNAMIC" || o == "KEYSET" {
      raise @types.not_supported("\{o} cursors")
    }
  }
  if c.for_update {
    raise @types.not_supported("updatable cursors (FOR UPDATE)")
  }
  let key = c.name.name.to_lower()
  let state : CursorState = {
    def: c,
    is_static: opts.contains("STATIC") || opts.contains("INSENSITIVE"),
    fast_forward: opts.contains("FAST_FORWARD"),
    scroll: opts.contains("SCROLL"),
    rows: None,
    columns: [],
    pos: -1,
    tables: [],
    opened: None,
  }
  // Default scope is GLOBAL (database option CURSOR_DEFAULT = GLOBAL).
  if opts.contains("LOCAL") {
    if self.frame().cursors.contains(key) {
      raise @types.sql_error(
        16915,
        "A cursor with the name '\{c.name.name}' already exists.",
      )
    }
    self.frame().cursors[key] = state
  } else {
    if self.cursors.contains(key) {
      raise @types.sql_error(
        16915,
        "A cursor with the name '\{c.name.name}' already exists.",
      )
    }
    self.cursors[key] = state
  }
  self.done(193)
}

///|
fn Session::exec_open_cursor(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  let c = self.find_cursor(name.name, global)
  if c.rows is Some(_) {
    raise @types.sql_error(16905, "The cursor is already open.")
  }
  let bound = @bind.bind_query(self.env(), c.def.query)
  let rows = @exec.run(self.ctx(), bound.plan)
  c.rows = Some(rows)
  c.columns = bound.columns
  c.pos = -1
  let tables = []
  plan_tables(bound.plan, tables)
  c.tables = tables
  c.opened = Some((self.db_of(0), self.db_of(1)))
  self.rt.cursor_rows = if c.is_static { rows.length() } else { -1 }
  self.done(32)
}

///|
fn Session::exec_fetch(self : Session, f : @ast.Fetch) -> Unit raise {
  let c = self.find_cursor(f.cursor.name, f.global)
  guard c.rows is Some(rows) else {
    raise @types.sql_error(16917, "Cursor is not open.")
  }
  if !c.is_static {
    match c.opened {
      Some((db0, db1)) =>
        for t in c.tables {
          let (scope, id) = t
          let now = self.db_of(scope)
          let then = if scope == 1 { db1 } else { db0 }
          if !now.same_table_data(then, id) {
            raise @types.not_supported(
              "reading a non-STATIC cursor after its tables changed (DYNAMIC semantics)",
            )
          }
        }
      None => ()
    }
  }
  let n = rows.length()
  let target = match f.orientation {
    Next => c.pos + 1
    Prior => c.pos - 1
    First => 0
    Last => n - 1
    Absolute(e) | Relative(e) => {
      let (v, _) = self.eval(e)
      let k = v.as_int64().unwrap_or(0L).to_int()
      if f.orientation is Absolute(_) {
        if k > 0 {
          k - 1
        } else if k < 0 {
          n + k
        } else {
          -1
        }
      } else {
        c.pos + k
      }
    }
  }
  if !(f.orientation is Next) && (c.fast_forward || !(c.scroll || c.is_static)) {
    raise @types.sql_error(
      16911,
      "fetch: The fetch type \{fetch_name(f.orientation)} cannot be used with forward only cursors.",
    )
  }
  self.cur_cmd = 193
  if target < 0 || target >= n {
    c.pos = if target < 0 { -1 } else { n }
    self.rt.fetch_status = -1
    self.rt.rowcount = 0
    self.done(193)
    return
  }
  c.pos = target
  let row = rows[target]
  if f.into.is_empty() {
    self.out.push(ResultSet(c.columns.map(tds_column)))
    self.out.push(Row(row.map(wire_value)))
    self.rt.fetch_status = 0
    self.rt.rowcount = 1
    self.done(193, count=Some(1L), result_set=true)
    return
  }
  if f.into.length() != row.length() {
    raise @types.sql_error(
      16924, "Cursorfetch: The number of variables declared in the INTO list must match that of selected columns.",
    )
  }
  for i, name in f.into {
    match self.frame().vars.get(name.to_lower()) {
      Some(info) =>
        self.frame().values[info.slot] = @types.cast(
          row[i],
          c.columns[i].ty,
          info.ty,
        )
      None =>
        raise @types.sql_error(
          137,
          "Must declare the scalar variable \"\{name}\".",
          state=2,
          severity=15,
        )
    }
  }
  self.rt.fetch_status = 0
  self.rt.rowcount = 1
  self.done(193)
}

///|
fn fetch_name(o : @ast.FetchOrientation) -> String {
  match o {
    Next => "FETCH_NEXT"
    Prior => "FETCH_PRIOR"
    First => "FETCH_FIRST"
    Last => "FETCH_LAST"
    Absolute(_) => "FETCH_ABSOLUTE"
    Relative(_) => "FETCH_RELATIVE"
  }
}

///|
fn Session::exec_close_cursor(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  let c = self.find_cursor(name.name, global)
  if c.rows is None {
    raise @types.sql_error(16917, "Cursor is not open.")
  }
  c.rows = None
  c.opened = None
  self.done(43)
}

///|
fn Session::exec_deallocate(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  let key = name.name.to_lower()
  let c = self.find_cursor(name.name, global)
  ignore(c)
  let mut removed = false
  if !global {
    let mut i = self.frames.length() - 1
    while i >= 0 && !removed {
      if self.frames[i].cursors.contains(key) {
        self.frames[i].cursors.remove(key)
        removed = true
      }
      i -= 1
    }
  }
  if !removed {
    self.cursors.remove(key)
  }
  self.done(44)
}
