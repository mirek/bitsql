// Server cursors: DECLARE CURSOR, cursor variables (`DECLARE @c CURSOR`,
// `SET @c = CURSOR ...`, `SET @c = name`, CURSOR VARYING OUTPUT
// parameters), OPEN / FETCH / CLOSE / DEALLOCATE, CURSOR_STATUS,
// @@CURSOR_ROWS, @@FETCH_STATUS, sys.dm_exec_cursors and positioned
// UPDATE/DELETE (WHERE CURRENT OF). Captured: msduck-runs/cursor,
// harness/corpus/stmts/cursor-*.
//
// The created cursor type follows SQL Server's implicit conversions
// (captured sys.dm_exec_cursors properties, stmts/cursor-models):
// - STATIC / INSENSITIVE, and any query with GROUP BY, aggregates,
//   DISTINCT, UNION, window functions or no table (except FAST_FORWARD,
//   which never converts): Snapshot.
// - KEYSET, SCROLL without a type: Keyset when every table has a unique
//   index, else Snapshot.
// - DYNAMIC and the default (forward-only) cursor: Dynamic; over one table
//   with TOP, a select-list subquery or an ORDER BY no index provides it
//   becomes Keyset (Snapshot without a unique index); joins stay Dynamic.
// Concurrency: Snapshot and Fast_Forward are Read Only, else READ_ONLY /
// SCROLL_LOCKS / Optimistic.
//
// Data models:
// - Static: rows copied at OPEN.
// - Keyset (one table): row ids and unique-key values fixed at OPEN; each
//   FETCH re-reads the row. A deleted (or re-keyed) row fetches with
//   @@FETCH_STATUS -2, ROWSTAT 2 and blank values (NULL, else 0 / spaces /
//   zero bytes / the type's zero date).
// - Dynamic (one table): each FETCH re-runs the query and positions after
//   the current row's ordering tuple (ORDER BY keys or the clustered key,
//   then the row id), so deleted rows are skipped and inserted rows appear.
// - Frozen: keyset / dynamic / fast-forward cursors over queries bitsql
//   does not track row by row (joins, views): rows copied at OPEN, and a
//   FETCH after a base table changed raises an Emulator error instead of
//   returning stale rows.

///|
priv enum CursorModel {
  Static
  Keyset
  Dynamic
  Frozen
} derive(Eq)

///|
/// Dynamic cursor position: before the first row, on the row with this
/// ordering tuple (hidden columns), or after the last row.
priv enum DynPos {
  Before
  At(Array[@types.Value])
  After
}

///|
priv struct CursorState {
  def : @ast.Cursor
  /// Declared name (as written), or the cursor variable's name.
  name : String
  is_local : Bool
  /// sys.dm_exec_cursors type: Snapshot, Keyset, Dynamic, Fast_Forward.
  kind : String
  /// Read Only, Optimistic or Scroll Locks.
  concurrency : String
  scroll : Bool
  /// Names (cursor variables, cursor names) referencing the cursor; it is
  /// deallocated when the last one goes.
  mut refs : Int
  mut open : Bool
  mut model : CursorModel
  mut columns : Array[@ir.ResultColumn]
  mut order : Array[Int]
  mut tabname : Array[Array[String]]
  mut colinfo : Array[@tds.ColInfo]
  /// Variable values at OPEN (the query runs with them).
  mut vars : Array[@types.Value]
  /// Static / Frozen: the rows. Keyset: [row id, unique key values...]
  /// per entry. Dynamic: unused.
  mut rows : Array[Array[@types.Value]]
  /// Static / Keyset / Frozen: current row index (-1 before the first,
  /// rows.length() after the last).
  mut pos : Int
  /// One-table models: (scope, id) of the base table.
  mut table : (Int, Int)?
  /// Keyset: re-read plan (visible columns ++ row id ++ unique key) over
  /// all base rows. Dynamic: the query (visible columns ++ ordering tuple
  /// ++ row id) without its ORDER BY.
  mut plan : @ir.Plan?
  /// Ordering tuple of the dynamic model: (descending, collation) per
  /// hidden column (the last is the row id).
  mut tuple : Array[(Bool, @types.Collation?)]
  mut dpos : DynPos
  /// Base row of the last fetched row (WHERE CURRENT OF); None before the
  /// first fetch or after fetching past either end.
  mut current : Int64?
  /// Frozen: base tables and the databases at OPEN.
  mut tables : Array[(Int, Int)]
  mut opened : (@store.Db, @store.Db)?
  /// Cached re-read rows (keyset map / dynamic rows) and the database they
  /// were read from.
  mut cache : Map[Int64, Array[@types.Value]]
  mut cache_rows : Array[Array[@types.Value]]
  mut cache_db : @store.Db?
}

///|
/// Conflicting cursor options (1048, compile time; the pair's wording is
/// fixed per pair, captured: stmts/cursor-options), or old and new syntax
/// mixed (1049).
fn cursor_option_error(c : @ast.Cursor) -> @types.SqlError? {
  let opts = c.options
  let iso_count = if c.iso {
    let mut k = 0
    while k < opts.length() && (opts[k] == "INSENSITIVE" || opts[k] == "SCROLL") {
      k += 1
    }
    k
  } else {
    0
  }
  if c.iso && iso_count < opts.length() && opts[iso_count] != "READ ONLY" {
    return Some(
      @types.sql_error(
        1049,
        "Mixing old and new syntax to specify cursor options is not allowed.",
        severity=15,
      ),
    )
  }
  let has = (o : String) => {
    if o == "FOR UPDATE" {
      c.for_update
    } else {
      opts.contains(o)
    }
  }
  let pairs = [
    ("LOCAL", "GLOBAL"),
    ("SCROLL", "FORWARD_ONLY"),
    ("SCROLL", "FAST_FORWARD"),
    ("STATIC", "KEYSET"),
    ("STATIC", "DYNAMIC"),
    ("KEYSET", "DYNAMIC"),
    ("STATIC", "FAST_FORWARD"),
    ("KEYSET", "FAST_FORWARD"),
    ("DYNAMIC", "FAST_FORWARD"),
    ("FAST_FORWARD", "SCROLL_LOCKS"),
    ("FAST_FORWARD", "OPTIMISTIC"),
    ("READ_ONLY", "SCROLL_LOCKS"),
    ("OPTIMISTIC", "READ_ONLY"),
    ("SCROLL_LOCKS", "OPTIMISTIC"),
    ("STATIC", "SCROLL_LOCKS"),
    ("FAST_FORWARD", "FOR UPDATE"),
    ("FOR UPDATE", "STATIC"),
    ("FOR UPDATE", "INSENSITIVE"),
    ("FOR UPDATE", "READ_ONLY"),
  ]
  for p in pairs {
    if has(p.0) && has(p.1) {
      return Some(
        @types.sql_error(
          1048,
          "Conflicting cursor options \{p.0} and \{p.1}.",
          severity=15,
        ),
      )
    }
  }
  None
}

///|
fn plan_tables(p : @ir.Plan, out : Array[(Int, Int)]) -> Unit {
  match p {
    Scan(scope~, id~, ..) | TableFunc(VectorSearch(scope~, id~, ..), _) =>
      out.push((scope, id))
    Project(x, _)
    | Filter(x, _)
    | Sort(x, _)
    | Limit(x, _, _)
    | Top(x, _, ..)
    | NoNullWarning(x)
    | Distinct(x, _) => plan_tables(x, out)
    Aggregate(x, _, _, ..) | Window(x, _) => plan_tables(x, out)
    Join(_, a, b, _, ..) | Apply(a, b, ..) | SetOp(_, a, b, _) => {
      plan_tables(a, out)
      plan_tables(b, out)
    }
    UnionAll(parts) => parts.each(x => plan_tables(x, out))
    _ => ()
  }
}

///|
/// Queries every cursor type except FAST_FORWARD turns into a Snapshot:
/// grouping, aggregates, DISTINCT, set operations, window functions,
/// table functions, or no table at all (captured: stmts/cursor-models).
fn snapshot_only(p : @ir.Plan) -> Bool {
  fn walk(p : @ir.Plan) -> Bool {
    match p {
      Scan(..) => false
      Project(x, _)
      | Filter(x, _)
      | Sort(x, _)
      | Limit(x, _, _)
      | Top(x, _, ..)
      | NoNullWarning(x)
      | WithParams(_, x) => walk(x)
      Join(_, a, b, _, ..) | Apply(a, b, ..) => walk(a) || walk(b)
      _ => true
    }
  }

  let tables = []
  plan_tables(p, tables)
  tables.is_empty() || walk(p)
}

///|
/// The one-table shape `Project(Filter/Sort/Top/Limit*(Scan))`.
fn chain_scan(p : @ir.Plan) -> (Int, Int)? {
  match p {
    Scan(scope~, id~, ..) => Some((scope, id))
    Filter(x, _) | Sort(x, _) | Limit(x, _, _) | Top(x, _, ..) => chain_scan(x)
    _ => None
  }
}

///|
fn chain_sort(p : @ir.Plan) -> Array[@ir.SortKey] {
  match p {
    Sort(_, keys) => keys
    Filter(x, _) | Limit(x, _, _) | Top(x, _, ..) => chain_sort(x)
    _ => []
  }
}

///|
fn chain_top(p : @ir.Plan) -> Bool {
  match p {
    Limit(_, _, _) | Top(_, _, ..) => true
    Filter(x, _) | Sort(x, _) => chain_top(x)
    _ => false
  }
}

///|
/// The plan with the base scan producing a trailing row id; with `sorted`
/// false, without its ORDER BY.
fn chain_rowid(p : @ir.Plan, sorted : Bool) -> @ir.Plan {
  match p {
    Scan(scope~, id~, ..) => Scan(scope~, id~, rowid=true)
    Filter(x, e) => Filter(chain_rowid(x, sorted), e)
    Sort(x, keys) =>
      if sorted {
        Sort(chain_rowid(x, sorted), keys)
      } else {
        chain_rowid(x, sorted)
      }
    Limit(x, a, b) => Limit(chain_rowid(x, sorted), a, b)
    Top(x, c, percent~, ties~) =>
      Top(chain_rowid(x, sorted), c, percent~, ties~)
    other => other
  }
}

///|
fn col_expr(i : Int, ty : @types.SqlType, nullable : Bool) -> @ir.Expr {
  { kind: Col(i), ty, nullable, }
}

///|
/// The unique index a keyset identifies rows by (primary key first).
fn keyset_index(t : @store.Table) -> @store.Index? {
  match t.primary_key() {
    Some(pk) => Some(pk)
    None =>
      t.indexes
      .iter()
      .find_first(ix => ix.unique && ix.filter is None && !ix.columns.is_empty())
  }
}

///|
/// Does an index provide this ORDER BY (plain columns forming a prefix of
/// an index key extended by the clustered key, or covering a unique key)?
/// Captured: stmts/cursor-models (ORDER BY q with an index on q, ORDER BY
/// q, id and ORDER BY id, q stay Dynamic; ORDER BY v without one is Keyset).
fn index_provides(t : @store.Table, keys : Array[@ir.SortKey]) -> Bool {
  let cols = []
  for k in keys {
    match k.expr.kind {
      Col(i) => cols.push(i)
      _ => return false
    }
  }
  let clustered = match t.indexes.iter().find_first(ix => ix.clustered) {
    Some(ix) => ix.columns.map(c => c.0)
    None => []
  }
  for ix in t.indexes {
    if ix.filter is Some(_) {
      continue
    }
    let ext = ix.columns.map(c => c.0)
    for c in clustered {
      if !ext.contains(c) {
        ext.push(c)
      }
    }
    // prefix of the (extended) index key
    let mut ok = cols.length() <= ext.length()
    for j, c in cols {
      if ok && ext[j] != c {
        ok = false
      }
    }
    if ok {
      return true
    }
    // a unique key first: later keys do not matter
    if ix.unique && cols.length() >= ix.columns.length() {
      let mut covers = true
      for j, c in ix.columns {
        if cols[j] != c.0 {
          covers = false
        }
      }
      if covers {
        return true
      }
    }
  }
  false
}

///|
fn query_has_select_subquery(q : @ast.Query) -> Bool {
  guard q.body is Select(sel) else { return false }
  let mut found = false
  for item in sel.items {
    match item.kind {
      ExprItem(e, ..) =>
        walk_expr(e, x => if x.kind is Subquery(_) { found = true })
      _ => ()
    }
  }
  found
}

///|
/// The created type and data model of a cursor over `plan` (see the file
/// header). `declared`: STATIC, KEYSET, DYNAMIC, FAST_FORWARD or "".
fn Session::cursor_type(
  self : Session,
  c : @ast.Cursor,
  plan : @ir.Plan,
) -> (String, CursorModel) {
  let opts = c.options
  let declared = if opts.contains("STATIC") || opts.contains("INSENSITIVE") {
    "STATIC"
  } else if opts.contains("KEYSET") {
    "KEYSET"
  } else if opts.contains("DYNAMIC") {
    "DYNAMIC"
  } else if opts.contains("FAST_FORWARD") {
    "FAST_FORWARD"
  } else if opts.contains("SCROLL") && !c.iso {
    "KEYSET"
  } else if c.iso {
    // ISO SCROLL without INSENSITIVE: a keyset when possible
    if opts.contains("SCROLL") {
      "KEYSET"
    } else {
      "DYNAMIC"
    }
  } else {
    "DYNAMIC"
  }
  if declared == "STATIC" {
    return ("Snapshot", Static)
  }
  let single = match plan {
    Project(inner, _) =>
      match chain_scan(inner) {
        Some((scope, id)) =>
          match self.db_of(scope).table(id) {
            Some(t) => Some((inner, t))
            None => None
          }
        None => None
      }
    _ => None
  }
  if declared == "FAST_FORWARD" {
    let tracked = match single {
      Some((inner, t)) => {
        let keys = chain_sort(inner)
        !chain_top(inner) && (keys.is_empty() || index_provides(t, keys))
      }
      None => false
    }
    return ("Fast_Forward", if tracked { Dynamic } else { Frozen })
  }
  if snapshot_only(plan) {
    return ("Snapshot", Static)
  }
  match single {
    Some((inner, t)) => {
      let unique = keyset_index(t) is Some(_)
      let keyset = if unique {
        ("Keyset", Keyset)
      } else {
        ("Snapshot", Static)
      }
      if declared == "KEYSET" {
        return keyset
      }
      let keys = chain_sort(inner)
      if chain_top(inner) ||
        query_has_select_subquery(c.query) ||
        (!keys.is_empty() && !index_provides(t, keys)) {
        return keyset
      }
      ("Dynamic", Dynamic)
    }
    None => {
      // joins: a keyset needs a unique index on every table
      let tables = []
      plan_tables(plan, tables)
      let all_unique = tables
        .iter()
        .all(x => {
          match self.db_of(x.0).table(x.1) {
            Some(t) => keyset_index(t) is Some(_)
            None => false
          }
        })
      if declared == "KEYSET" {
        if all_unique {
          ("Keyset", Frozen)
        } else {
          ("Snapshot", Static)
        }
      } else {
        ("Dynamic", Frozen)
      }
    }
  }
}

///|
fn cursor_concurrency(c : @ast.Cursor, kind : String) -> String {
  if kind == "Snapshot" ||
    kind == "Fast_Forward" ||
    c.options.contains("READ_ONLY") ||
    c.options.contains("READ ONLY") {
    "Read Only"
  } else if c.options.contains("SCROLL_LOCKS") {
    "Scroll Locks"
  } else {
    "Optimistic"
  }
}

///|
/// A new cursor for `c`: the query is bound here only to choose the created
/// type (it is bound again at OPEN, with the variables of that moment). A
/// query that does not bind yet keeps the requested type until OPEN.
fn Session::new_cursor(
  self : Session,
  c : @ast.Cursor,
  name : String,
  is_local : Bool,
) -> CursorState {
  let (kind, model) = try @bind.bind_query(self.env(), c.query) catch {
    _ => {
      let o = c.options
      if o.contains("STATIC") || o.contains("INSENSITIVE") {
        ("Snapshot", Static)
      } else if o.contains("FAST_FORWARD") {
        ("Fast_Forward", Frozen)
      } else if o.contains("KEYSET") || o.contains("SCROLL") {
        ("Keyset", Frozen)
      } else {
        ("Dynamic", Frozen)
      }
    }
  } noraise {
    bound => self.cursor_type(c, bound.plan)
  }
  let o = c.options
  // STATIC / KEYSET / DYNAMIC scroll unless FORWARD_ONLY (ISO: SCROLL)
  let scroll = if c.iso {
    o.contains("SCROLL")
  } else {
    !o.contains("FORWARD_ONLY") &&
    !o.contains("FAST_FORWARD") &&
    (
      o.contains("SCROLL") ||
      o.contains("STATIC") ||
      o.contains("KEYSET") ||
      o.contains("DYNAMIC")
    )
  }
  {
    def: c,
    name,
    is_local,
    kind,
    concurrency: cursor_concurrency(c, kind),
    scroll,
    refs: 1,
    open: false,
    model,
    columns: [],
    order: [],
    tabname: [],
    colinfo: [],
    vars: [],
    rows: [],
    pos: -1,
    table: None,
    plan: None,
    tuple: [],
    dpos: Before,
    current: None,
    tables: [],
    opened: None,
    cache: Map([]),
    cache_rows: [],
    cache_db: None,
  }
}

///|
/// INFO 16956 when TYPE_WARNING was given and the created type is not the
/// requested one (captured: msduck-runs/cursor #035, at the DECLARE's line
/// before its DONE).
fn Session::cursor_type_warning(self : Session, st : CursorState) -> Unit {
  let o = st.def.options
  if !o.contains("TYPE_WARNING") {
    return
  }
  let requested = if o.contains("STATIC") {
    "Snapshot"
  } else if o.contains("KEYSET") {
    "Keyset"
  } else if o.contains("DYNAMIC") {
    "Dynamic"
  } else if o.contains("FAST_FORWARD") {
    "Fast_Forward"
  } else {
    st.kind
  }
  if requested != st.kind {
    self.info(
      16956,
      1,
      "The created cursor is not of the requested type.",
      self.stmt_line,
    )
  }
}

///|
fn Session::exec_declare_cursor(self : Session, c : @ast.Cursor) -> Unit raise {
  self.cur_cmd = 193
  let key = c.name.name.to_lower()
  // Default scope: the database option CURSOR_DEFAULT (GLOBAL unless
  // ALTER DATABASE … SET CURSOR_DEFAULT LOCAL)
  let is_local = c.options.contains("LOCAL") ||
    (
      !c.options.contains("GLOBAL") &&
      self.server.db_options(self.rt.database).local_cursors
    )
  let exists = if is_local {
    self.frame().cursors.contains(key)
  } else {
    self.cursors.contains(key)
  }
  if exists {
    raise @types.sql_error(
      16915,
      "A cursor with the name '\{c.name.name}' already exists.",
    )
  }
  let st = self.new_cursor(c, c.name.name, is_local)
  if is_local {
    self.frame().cursors[key] = st
  } else {
    self.cursors[key] = st
  }
  self.cursor_type_warning(st)
  self.done(193)
}

///|
/// `SET @v = CURSOR ... FOR query`: a new cursor owned by the variable.
fn Session::exec_set_cursor(self : Session, c : @ast.Cursor) -> Unit raise {
  self.cur_cmd = 193
  let vname = c.name.name
  let (frame, _) = self.cursor_var(vname)
  let st = self.new_cursor(c, vname, true)
  self.release_ref(frame.cursor_vars.get(vname.to_lower()).unwrap_or(None))
  frame.cursor_vars[vname.to_lower()] = Some(st)
  self.cursor_type_warning(st)
  self.done(193)
}

///|
/// The frame declaring cursor variable `name` and its cursor. Raises 137
/// for an undeclared variable.
fn Session::cursor_var(
  self : Session,
  name : String,
) -> (Frame, CursorState?) raise @types.SqlError {
  let f = self.frame()
  match f.cursor_vars.get(name.to_lower()) {
    Some(c) => (f, c)
    None =>
      raise @types.sql_error(
        137,
        "Must declare the scalar variable \"\{name}\".",
        state=2,
        severity=15,
      )
  }
}

///|
/// `SET @cv = cursor_name` or `SET @cv = @other`: the variable now
/// references that cursor (completes like an assignment: count 1).
fn Session::assign_cursor_var(
  self : Session,
  vname : String,
  e : @ast.Expr,
) -> Unit raise {
  self.cur_cmd = 193
  let (frame, old) = self.cursor_var(vname)
  let target = match e.kind {
    Column([n]) => self.find_cursor(n.name, false, missing_line=false)
    Var(v) =>
      match self.cursor_var(v) {
        (_, Some(c)) => c
        (_, None) =>
          raise @types.sql_error(
            16950,
            "The variable '\{v}' does not currently have a cursor allocated to it.",
            state=2,
          )
      }
    _ =>
      raise @types.sql_error(
        206, "Operand type clash: cursor is incompatible with the assigned value.",
      )
  }
  target.refs += 1
  self.release_ref(old)
  frame.cursor_vars[vname.to_lower()] = Some(target)
  self.rt.rowcount = 1
  self.done(193, count=Some(1L))
}

///|
/// Drops one reference; the last one closes and frees the cursor.
fn Session::release_ref(self : Session, c : CursorState?) -> Unit {
  guard c is Some(st) else { return }
  st.refs -= 1
  if st.refs <= 0 && st.open {
    self.close_cursor(st)
  }
}

///|
fn Session::close_cursor(self : Session, c : CursorState) -> Unit {
  c.open = false
  c.rows = []
  c.cache = Map([])
  c.cache_rows = []
  c.cache_db = None
  c.opened = None
  c.current = None
  match self.last_opened {
    Some(l) if physical_equal(l, c) => self.rt.cursor_rows = 0
    _ => ()
  }
}

///|
/// Resolves a cursor reference: `@var` (16950 when it holds none), or a
/// name (LOCAL cursors of the current scope first, unless GLOBAL). A
/// missing name is 16916; OPEN and FETCH report it at the line of the
/// previous statement (`missing_line`, captured: stmts/cursor-lines).
fn Session::find_cursor(
  self : Session,
  name : String,
  global : Bool,
  missing_line? : Bool = true,
) -> CursorState raise {
  if name.has_prefix("@") {
    match self.cursor_var(name) {
      (_, Some(c)) => return c
      (_, None) => {
        if missing_line {
          self.error_line = Some(self.prev_line)
        }
        raise @types.sql_error(
          16950,
          "The variable '\{name}' does not currently have a cursor allocated to it.",
          state=2,
        )
      }
    }
  }
  let key = name.to_lower()
  if !global {
    match self.frame().cursors.get(key) {
      Some(c) => return c
      None => ()
    }
  }
  match self.cursors.get(key) {
    Some(c) => c
    None => {
      if missing_line {
        self.error_line = Some(self.prev_line)
      }
      raise @types.sql_error(
        16916,
        "A cursor with the name '\{name}' does not exist.",
      )
    }
  }
}

///|
/// The query context with the variable values captured at OPEN.
fn Session::cursor_ctx(self : Session, c : CursorState) -> @exec.Ctx {
  { ..self.ctx(), vars: c.vars, }
}

///|
fn Session::exec_open_cursor(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  self.cur_cmd = 32
  let c = self.find_cursor(name.name, global)
  if c.open {
    raise @types.sql_error(16905, "The cursor is already open.")
  }
  let bound = @bind.bind_query(self.env(), c.def.query)
  // the created type was chosen at DECLARE; a query that did not bind then
  // is classified now
  let (_, model) = self.cursor_type(c.def, bound.plan)
  c.model = if c.kind == "Snapshot" { Static } else { model }
  if c.kind != "Snapshot" && c.model == Static {
    // a requested keyset/dynamic cursor the table no longer supports
    c.model = Frozen
  }
  c.columns = bound.columns
  c.order = bound.order
  c.vars = self.frame().values.copy()
  self.browse_metadata(c, bound.plan)
  c.pos = -1
  c.dpos = Before
  c.current = None
  c.table = None
  c.plan = None
  c.cache = Map([])
  c.cache_rows = []
  c.cache_db = None
  let ctx = self.cursor_ctx(c)
  match (c.model, bound.plan) {
    (Keyset, Project(inner, exprs)) => {
      guard chain_scan(inner) is Some((scope, id)) else { raise_internal() }
      guard self.db_of(scope).table(id) is Some(t) else { raise_internal() }
      guard keyset_index(t) is Some(ix) else { raise_internal() }
      let w = t.columns.length()
      let keys = ix.columns.map(k => {
        let col = t.columns[k.0]
        col_expr(k.0, col.ty, col.nullable)
      })
      let rid = col_expr(w, BigInt, false)
      let entry : @ir.Plan = Project(chain_rowid(inner, true), [rid] + keys)
      c.rows = @exec.run(ctx, entry)
      c.table = Some((scope, id))
      let reread : @ir.Plan = Project(
        Scan(scope~, id~, rowid=true),
        exprs + [rid] + keys,
      )
      c.plan = Some(reread)
    }
    (Dynamic, Project(inner, exprs)) => {
      guard chain_scan(inner) is Some((scope, id)) else { raise_internal() }
      guard self.db_of(scope).table(id) is Some(t) else { raise_internal() }
      let w = t.columns.length()
      let keys = chain_sort(inner)
      let hidden : Array[@ir.Expr] = []
      let tuple : Array[(Bool, @types.Collation?)] = []
      if keys.is_empty() {
        match t.indexes.iter().find_first(ix => ix.clustered) {
          Some(ix) =>
            for k in ix.columns {
              let col = t.columns[k.0]
              hidden.push(col_expr(k.0, col.ty, col.nullable))
              tuple.push((k.1, col.ty.collation()))
            }
          None => ()
        }
      } else {
        for k in keys {
          hidden.push(k.expr)
          tuple.push((k.desc, k.collation))
        }
      }
      hidden.push(col_expr(w, BigInt, false))
      tuple.push((false, None))
      c.tuple = tuple
      c.table = Some((scope, id))
      let rerun : @ir.Plan = Project(chain_rowid(inner, false), exprs + hidden)
      c.plan = Some(rerun)
    }
    _ => {
      c.rows = @exec.run(ctx, bound.plan)
      let tables = []
      plan_tables(bound.plan, tables)
      c.tables = tables
      c.opened = Some((self.db_of(0), self.db_of(1)))
    }
  }
  c.open = true
  self.last_opened = Some(c)
  self.rt.cursor_rows = match c.kind {
    "Snapshot" | "Keyset" => c.rows.length()
    _ => -1
  }
  self.done(32)
}

///|
fn raise_internal() -> Unit raise @types.SqlError {
  raise @types.emulator_error(@types.EMU_INTERNAL, "cursor plan shape changed")
}

///|
/// TABNAME/COLINFO of FETCH results: the base tables with a result column
/// (captured: COUNT(*) and constant queries send COLINFO only).
fn Session::browse_metadata(
  self : Session,
  c : CursorState,
  plan : @ir.Plan,
) -> Unit {
  let tables = []
  plan_tables(plan, tables)
  let names = []
  if c.columns
    .iter()
    .any(x => x.origin is (BaseColumn(..) | InsertableIdentity)) {
    for x in tables {
      match self.db_of(x.0).table(x.1) {
        Some(t) => names.push([t.schema, t.name])
        None => ()
      }
    }
  }
  let info : Array[@tds.ColInfo] = []
  for i, col in c.columns {
    let base = col.origin is (BaseColumn(..) | InsertableIdentity) &&
      names.length() == 1
    info.push({
      column: i + 1,
      table: if base {
        1
      } else {
        0
      },
      status: if base {
        0
      } else {
        0x04
      },
      base_name: None,
    })
  }
  // ROWSTAT
  info.push({
    column: c.columns.length() + 1,
    table: 0,
    status: 0x04 | 0x10,
    base_name: None,
  })
  c.tabname = names
  c.colinfo = info
}

///|
/// A Frozen cursor's tables changed since OPEN: not modelled.
fn Session::check_frozen(self : Session, c : CursorState) -> Unit raise {
  guard c.model == Frozen && c.opened is Some((db0, db1)) else { return }
  for t in c.tables {
    let (scope, id) = t
    let now = self.db_of(scope)
    let then = if scope == 1 { db1 } else { db0 }
    if !now.same_table_data(then, id) {
      raise @types.not_supported(
        "fetching from a \{c.kind} cursor over a join or view after its tables changed",
      )
    }
  }
}

///|
/// Compares two dynamic ordering tuples (NULL first ascending).
fn tuple_compare(
  a : Array[@types.Value],
  b : Array[@types.Value],
  dirs : Array[(Bool, @types.Collation?)],
) -> Int {
  for i, d in dirs {
    let x = a.get(i).unwrap_or(Null)
    let y = b.get(i).unwrap_or(Null)
    let r = match (x, y) {
      (Null, Null) => 0
      (Null, _) => -1
      (_, Null) => 1
      _ => {
        let cmp = try {
          match d.1 {
            Some(coll) => @types.compare(x, y, collation=coll)
            None => @types.compare(x, y)
          }
        } catch {
          _ => None
        }
        cmp.unwrap_or(0)
      }
    }
    if r != 0 {
      return if d.0 { -r } else { r }
    }
  }
  0
}

///|
/// The base table's current database (scope 0 or 1).
fn Session::cursor_db(self : Session, c : CursorState) -> @store.Db? {
  match c.table {
    Some((scope, _)) => Some(self.db_of(scope))
    None => None
  }
}

///|
/// Re-reads the rows of a one-table model unless the table is unchanged.
fn Session::cursor_reread(self : Session, c : CursorState) -> Unit raise {
  guard c.table is Some((_, id)) && c.plan is Some(plan) else { return }
  guard self.cursor_db(c) is Some(db) else { return }
  match c.cache_db {
    Some(then) if db.same_table_data(then, id) => return
    _ => ()
  }
  let rows = @exec.run(self.cursor_ctx(c), plan)
  let w = c.columns.length()
  if c.model == Keyset {
    let m : Map[Int64, Array[@types.Value]] = Map([])
    for r in rows {
      match r.get(w) {
        Some(BigInt(rid)) => m[rid] = r
        _ => ()
      }
    }
    c.cache = m
  } else {
    let dirs = c.tuple
    rows.sort_by((a, b) => {
      tuple_compare(a[w:].to_owned(), b[w:].to_owned(), dirs)
    })
    c.cache_rows = rows
  }
  c.cache_db = Some(db)
}

///|
/// Blank value of a deleted keyset row's column (captured:
/// stmts/cursor-keyset-blank): NULL when nullable, else zero, spaces,
/// zero bytes or the type's zero date.
fn blank_value(c : @ir.ResultColumn) -> @types.Value {
  if c.nullable {
    return Null
  }
  match c.ty {
    Char(n, _) | NChar(n, _) => String(" ".repeat(@cmp.minimum(n, 8000)))
    VarChar(Some(n), _) | NVarChar(Some(n), _) =>
      String(" ".repeat(@cmp.minimum(n, 8000)))
    VarChar(None, _) | NVarChar(None, _) | Text(_) | NText(_) => String("")
    Binary(n) | VarBinary(Some(n)) =>
      Binary(Bytes::make(@cmp.minimum(n, 8000), b'\x00'))
    VarBinary(None) | Image => Binary(b"")
    RowVersion => Binary(Bytes::make(8, b'\x00'))
    UniqueIdentifier => Guid(Bytes::make(16, b'\x00'))
    Date => Date(0)
    Time(_) => Time(0L)
    DateTime2(_) => DateTime2(0L)
    DateTimeOffset(_) => DateTimeOffset(0L, 0)
    DateTime => DateTime(0, 0)
    SmallDateTime => SmallDateTime(0, 0)
    Bit => Bit(false)
    ty => @types.assign(Int(0), Int, ty) catch { _ => Null }
  }
}

///|
/// Result of positioning a FETCH: the row (visible values), its status
/// (ROWSTAT 1 fetched, 2 deleted) and base row id; None past either end.
priv struct Fetched {
  row : Array[@types.Value]
  status : Int
  rowid : Int64?
}

///|
fn Session::fetch_row(
  self : Session,
  c : CursorState,
  f : @ast.Fetch,
) -> Fetched? raise {
  let w = c.columns.length()
  let amount = (e : @ast.Expr) => {
    let (v, _) = self.eval(e)
    v.as_int64().unwrap_or(0L).to_int()
  }
  match c.model {
    Dynamic => {
      self.cursor_reread(c)
      let rows = c.cache_rows
      let n = rows.length()
      let dirs = c.tuple
      let key = (r : Array[@types.Value]) => r[w:].to_owned()
      // first index whose tuple is >= t (and whether it is equal)
      let lower = (t : Array[@types.Value]) => {
        let mut i = 0
        while i < n && tuple_compare(key(rows[i]), t, dirs) < 0 {
          i += 1
        }
        (i, i < n && tuple_compare(key(rows[i]), t, dirs) == 0)
      }
      let target = match (f.orientation, c.dpos) {
        (First, _) => 0
        (Last, _) => n - 1
        (Next, Before) => 0
        (Next, After) => n
        (Next, At(t)) => {
          let (i, eq) = lower(t)
          if eq {
            i + 1
          } else {
            i
          }
        }
        (Prior, Before) => -1
        (Prior, After) => n - 1
        (Prior, At(t)) => lower(t).0 - 1
        (Relative(e), pos) => {
          let k = amount(e)
          match pos {
            Before => k - 1
            After => n + k
            At(t) => {
              let (i, eq) = lower(t)
              if eq || k <= 0 {
                i + k
              } else {
                i + k - 1
              }
            }
          }
        }
        (Absolute(_), _) => n
      }
      if target < 0 {
        c.dpos = Before
        None
      } else if target >= n {
        c.dpos = After
        None
      } else {
        let r = rows[target]
        c.dpos = At(key(r))
        let rid = match r.last() {
          Some(BigInt(x)) => Some(x)
          _ => None
        }
        Some({ row: r[0:w].to_owned(), status: 1, rowid: rid, })
      }
    }
    _ => {
      self.check_frozen(c)
      let n = c.rows.length()
      let target = match f.orientation {
        Next => c.pos + 1
        Prior => c.pos - 1
        First => 0
        Last => n - 1
        Absolute(e) => {
          let k = amount(e)
          if k > 0 {
            k - 1
          } else if k < 0 {
            n + k
          } else {
            -1
          }
        }
        Relative(e) => c.pos + amount(e)
      }
      if target < 0 || target >= n {
        c.pos = if target < 0 { -1 } else { n }
        return None
      }
      c.pos = target
      if c.model == Keyset {
        self.cursor_reread(c)
        let entry = c.rows[target]
        let rid = match entry.get(0) {
          Some(BigInt(x)) => x
          _ => -1L
        }
        match c.cache.get(rid) {
          Some(r) if r[w + 1:].to_owned() == entry[1:].to_owned() =>
            Some({ row: r[0:w].to_owned(), status: 1, rowid: Some(rid), })
          _ =>
            Some({
              row: c.columns.map(blank_value),
              status: 2,
              rowid: Some(rid),
            })
        }
      } else {
        Some({ row: c.rows[target], status: 1, rowid: None, })
      }
    }
  }
}

///|
fn Session::exec_fetch(self : Session, f : @ast.Fetch) -> Unit raise {
  self.cur_cmd = 193
  let c = self.find_cursor(f.cursor.name, f.global)
  let fail = (e : @types.SqlError) => {
    self.rt.fetch_status = -1
    raise e
  }
  if !c.open {
    fail(@types.sql_error(16917, "Cursor is not open.", state=2))
  }
  let forward_only = !c.scroll
  if !(f.orientation is Next) && forward_only {
    fail(
      @types.sql_error(
        16911,
        "fetch: The fetch type \{fetch_name(f.orientation)} cannot be used with forward only cursors.",
      ),
    )
  }
  if f.orientation is Absolute(_) && c.kind == "Dynamic" {
    fail(
      @types.sql_error(
        16925, "The fetch type Absolute cannot be used with dynamic cursors.",
      ),
    )
  }
  if !f.into.is_empty() && f.into.length() != c.columns.length() {
    fail(
      @types.sql_error(
        16924, "Cursorfetch: The number of variables declared in the INTO list must match that of selected columns.",
      ),
    )
  }
  let got = self.fetch_row(c, f)
  c.current = match got {
    Some(r) => r.rowid
    None => None
  }
  let status = match got {
    Some({ status: 2, .. }) => -2
    Some(_) => 0
    None => -1
  }
  if f.into.is_empty() {
    let cols = c.columns.map(tds_column)
    cols.push({ name: "ROWSTAT", type_info: Int4, flags: 0, user_type: 0, })
    self.out.push(ResultSet(cols))
    self.out.push(BrowseInfo(c.tabname, c.colinfo))
    if !c.order.is_empty() {
      self.out.push(Order(c.order))
    }
    let n = match got {
      Some(r) => {
        let values = r.row.map(wire_value)
        values.push(wire_value(Int(r.status)))
        self.out.push(Row(values))
        1L
      }
      None => 0L
    }
    self.rt.fetch_status = status
    self.rt.rowcount = n
    self.done(193, count=Some(n), result_set=true)
    return
  }
  match got {
    Some(r) =>
      for i, name in f.into {
        match self.frame().vars.get(name.to_lower()) {
          Some(info) =>
            self.frame().values[info.slot] = @types.assign(
              r.row[i],
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
    None => ()
  }
  self.rt.fetch_status = status
  self.rt.rowcount = if got is Some(_) { 1 } else { 0 }
  self.done(193)
}

///|
fn fetch_name(o : @ast.FetchOrientation) -> String {
  match o {
    Next => "next"
    Prior => "prior"
    First => "first"
    Last => "last"
    Absolute(_) => "absolute"
    Relative(_) => "relative"
  }
}

///|
fn Session::exec_close_cursor(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  self.cur_cmd = 43
  let c = self.find_cursor(name.name, global, missing_line=false)
  if !c.open {
    raise @types.sql_error(16917, "Cursor is not open.")
  }
  self.close_cursor(c)
  self.done(43)
}

///|
/// DEALLOCATE removes one reference (a name or a variable); the cursor
/// lives on while another one holds it (captured: msduck-runs/cursor #052).
fn Session::exec_deallocate(
  self : Session,
  name : @ast.Ident,
  global : Bool,
) -> Unit raise {
  self.cur_cmd = 44
  let c = self.find_cursor(name.name, global, missing_line=false)
  if name.name.has_prefix("@") {
    let (frame, _) = self.cursor_var(name.name)
    frame.cursor_vars[name.name.to_lower()] = None
  } else {
    let key = name.name.to_lower()
    let removed = !global &&
      (match self.frame().cursors.get(key) {
        Some(x) if physical_equal(x, c) => {
          self.frame().cursors.remove(key)
          true
        }
        _ => false
      })
    if !removed {
      self.cursors.remove(key)
    }
  }
  self.release_ref(Some(c))
  self.done(44)
}

///|
/// Cursors of a scope that ends (a module's frame): LOCAL cursors and
/// cursor variables release their references (CURSOR OUTPUT parameters
/// keep theirs until the caller took them over).
fn Session::release_frame_cursors(self : Session, f : Frame) -> Unit {
  for _, c in f.cursors {
    self.release_ref(Some(c))
  }
  for name, c in f.cursor_vars {
    if !f.cursor_params.contains(name) {
      self.release_ref(c)
    }
  }
}

///|
/// The `cursor` type name (variables and parameters).
fn is_cursor_type(t : @ast.TypeName) -> Bool {
  t.schema is None && t.name.to_lower() == "cursor"
}

///|
/// CURSOR_STATUS('local' | 'global' | 'variable', name) (captured,
/// harness/corpus/conversion/cursor-status, msduck-runs/cursor): -3 no such
/// cursor (a LOCAL lookup sees only LOCAL cursors) or variable, -2 a
/// variable without a cursor, -1 declared or closed, 0 an open static or
/// keyset cursor without rows, 1 otherwise (dynamic cursors always 1); an
/// unknown source is 16902 state 42, a NULL name 16902 state 43.
fn Session::cursor_status(
  self : Session,
  args : Array[@types.Value],
) -> @types.Value raise @types.SqlError {
  let source = match args.get(0) {
    Some(String(s)) => s.to_lower()
    _ => ""
  }
  let name = match args.get(1) {
    Some(String(s)) => s.to_lower()
    _ =>
      raise @types.sql_error(
        16902,
        "cursor_status: The value of the parameter 'cursor_identity' is invalid.",
        state=43,
      )
  }
  let found = match source {
    "local" => self.frame().cursors.get(name)
    "global" => self.cursors.get(name)
    "variable" =>
      match self.frame().cursor_vars.get(name) {
        Some(None) => return SmallInt(-2)
        Some(c) => c
        None => None
      }
    _ =>
      raise @types.sql_error(
        16902,
        "cursor_status: The value of the parameter 'cursor_source' is invalid.",
        state=42,
      )
  }
  SmallInt(
    match found {
      None => -3
      Some({ open: false, .. }) => -1
      Some(c) =>
        match c.kind {
          "Snapshot" | "Keyset" => if c.rows.is_empty() { 0 } else { 1 }
          _ => 1
        }
    },
  )
}

///|
/// sys.dm_exec_cursors rows of this session's cursors (the view is read
/// through `sys.dm_exec_cursors(session_id)`).
fn Session::cursor_view_rows(self : Session) -> Array[VRow] {
  let seen : Array[CursorState] = []
  let add = (c : CursorState) => {
    if !seen.iter().any(x => physical_equal(x, c)) {
      seen.push(c)
    }
  }
  for _, c in self.cursors {
    add(c)
  }
  for f in self.frames {
    for _, c in f.cursors {
      add(c)
    }
    for _, c in f.cursor_vars {
      match c {
        Some(x) => add(x)
        None => ()
      }
    }
  }
  seen.mapi((i, c) => {
    vrow([
      ("session_id", Int(self.rt.spid)),
      ("cursor_id", Int(i + 1)),
      ("name", s(c.name)),
      (
        "properties",
        s(
          "TSQL | \{c.kind} | \{c.concurrency} | \{if c.is_local { "Local" } else { "Global" }} (0)",
        ),
      ),
      ("is_open", Bit(c.open)),
      ("is_async_population", Bit(false)),
      ("is_close_on_commit", Bit(false)),
      ("fetch_status", Int(self.rt.fetch_status)),
      ("fetch_buffer_size", Int(1)),
      ("fetch_buffer_start", Int(0)),
      ("ansi_position", Int(0)),
      ("worker_time", BigInt(0L)),
      ("reads", BigInt(0L)),
      ("writes", BigInt(0L)),
      ("dormant_duration", BigInt(0L)),
    ])
  })
}

///|
/// WHERE CURRENT OF: the predicate selecting the cursor's current base row
/// in a DML source whose row id is column `rowid`. Errors (captured:
/// msduck-runs/cursor #037-#048): 16929 read-only cursor, 16933 another
/// table, 16932 a column outside FOR UPDATE OF, 16931 no current row,
/// 16947 the row is gone.
fn Session::current_of_predicate(
  self : Session,
  name : @ast.Ident,
  global : Bool,
  scope : Int,
  id : Int,
  rowid : Int,
  set_columns : Array[String]?,
) -> @ir.Expr raise {
  let c = self.find_cursor(name.name, global, missing_line=false)
  if c.concurrency == "Read Only" {
    raise @types.sql_error(16929, "The cursor is READ ONLY.")
  }
  if !c.open {
    raise @types.sql_error(16917, "Cursor is not open.")
  }
  let tables = []
  match c.table {
    Some(t) => tables.push(t)
    None => {
      let b = @bind.bind_query(self.env(), c.def.query)
      plan_tables(b.plan, tables)
    }
  }
  if !tables.iter().any(t => t.0 == scope && t.1 == id) {
    raise @types.sql_error(
      16933, "The cursor does not include the table being modified or the table is not updatable through the cursor.",
    )
  }
  match set_columns {
    Some(cols) if c.def.for_update && !c.def.update_columns.is_empty() => {
      let allowed = c.def.update_columns.map(x => x.name.to_lower())
      if cols.iter().any(x => !allowed.contains(x)) {
        raise @types.sql_error(
          16932, "The cursor has a FOR UPDATE list and the requested column to be updated is not in this list.",
        )
      }
    }
    _ => ()
  }
  if c.table is None {
    raise @types.not_supported(
      "WHERE CURRENT OF a \{c.kind} cursor over a join or view",
    )
  }
  guard c.current is Some(rid) else {
    raise @types.sql_error(
      16931, "There are no rows in the current fetch buffer.",
    )
  }
  if self.db_of(scope).row(id, rid) is None {
    raise @types.sql_error(16947, "No rows were updated or deleted.")
  }
  {
    kind: Cmp(
      Eq,
      col_expr(rowid, BigInt, false),
      @ir.Expr::lit(BigInt(rid), BigInt),
      None,
    ),
    ty: Bit,
    nullable: false,
  }
}
