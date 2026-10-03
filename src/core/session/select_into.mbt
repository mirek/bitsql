///|
/// `SELECT ... INTO t FROM ...`: runs the query, then creates `t` from the
/// result metadata (names, types, nullability) and inserts the rows.
/// Completion is cmd 194 with the row count (captured:
/// harness/corpus/query/select-into-assign). IDENTITY propagation is not
/// implemented (unverified: columns are created without identity).
fn Session::exec_select_into(
  self : Session,
  q : @ast.Query,
  sel : @ast.Select,
  into : @ast.ObjectName,
  line : Int,
) -> Unit raise {
  self.lock_reads(q)
  let bound = @bind.bind_query(self.env(), {
    ..q,
    body: Select({ ..sel, into: None, }),
  })
  let (schema, base) = split_name(into)
  let scope = if base.has_prefix("#") { 1 } else { 0 }
  let db = self.db_of(scope)
  let schema = if scope == 1 { "dbo" } else { schema }
  if db.lookup(schema, base) is Some(_) {
    raise @types.sql_error(
      2714,
      "There is already an object named '\{base}' in the database.",
      state=6,
    )
  }
  if scope == 0 && db.schema_id(schema) is None {
    raise @types.sql_error(
      2760,
      "The specified schema name \"\{schema}\" either does not exist or you do not have permission to use it.",
    )
  }
  let columns : Array[@store.Column] = []
  for c in bound.columns {
    if c.name == "" {
      raise @types.sql_error(
        1038,
        "An object or column name is missing or empty. For SELECT INTO statements, verify each column has a name. For other statements, look for empty alias names. Aliases defined as \"\" or [] are not allowed. Change the alias to a valid name.",
        severity=15,
      )
    }
    columns.push({
      column_id: columns.length() + 1,
      name: c.name,
      ty: c.ty,
      nullable: c.nullable,
      identity: None,
      default_: None,
      default_name: None,
      default_id: 0,
      default_auto: false,
      computed: None,
      persisted: false,
      rowguidcol: false,
    })
  }
  self.cur_cmd = 194
  self.rt.null_eliminated = false
  let rows = @exec.run(self.ctx(), bound.plan)
  self.emit_null_warning(line)
  let id = self.server.object_id()
  let t : @store.Table = {
    id,
    schema,
    name: base,
    columns,
    indexes: [],
    checks: [],
    foreign_keys: [],
    created: self.rt.now,
    modified: self.rt.now,
    max_column_id: columns.length(),
  }
  let mut db = self.db_of(scope).create_table(t)
  for r in rows {
    db = db.insert_row(id, self.server.rowid(), r)
  }
  self.write(scope, db)
  let n = rows.length().to_int64()
  self.rt.rowcount = n
  self.done(194, count=Some(n))
}

///|
/// INFO 8153 after a statement whose aggregates skipped NULLs (captured:
/// after the rows, before DONE).
fn Session::emit_null_warning(self : Session, line : Int) -> Unit {
  if self.rt.null_eliminated {
    self.rt.null_eliminated = false
    self.info(
      8153, 1, "Warning: Null value is eliminated by an aggregate or other SET operation.",
      line,
    )
  }
}

///|
/// `SELECT @v = expr, ... FROM ...`: values are assigned row by row (later
/// rows overwrite earlier ones); no rows leaves the variables unchanged.
fn Session::exec_assignment_select(
  self : Session,
  q : @ast.Query,
  line : Int,
) -> Unit raise {
  self.lock_reads(q)
  let (bound, targets) = @bind.bind_assignment_select(self.env(), q)
  for j, t in targets {
    @types.check_assign(bound.columns[j].ty, t.1)
  }
  self.cur_cmd = 193
  let ctx = self.ctx()
  self.rt.null_eliminated = false
  let mut n = 0L
  @exec.stream(ctx, bound.plan, row => {
    n += 1L
    for j, t in targets {
      ctx.vars[t.0] = @types.assign(row[j], bound.columns[j].ty, t.1)
    }
  })
  self.emit_null_warning(line)
  self.rt.rowcount = n
  self.done(193, count=Some(n))
}

///|
/// Streams a result set: rows produced before a run-time error stay sent
/// (SQL Server streams; captured 530 after 101 rows).
fn Session::exec_query(
  self : Session,
  q : @ast.Query,
  line : Int,
) -> Unit raise {
  self.lock_reads(q)
  if q.body is Select(sel) {
    check_sequence_refs(
      sel.items.filter_map(i => {
        match i.kind {
          ExprItem(e, ..) => Some(e)
          _ => None
        }
      }),
    )
  }
  let bound = @bind.bind_query(self.env(), q)
  let cols = bound.columns.map(tds_column)
  self.out.push(ResultSet(cols))
  self.cur_cmd = 193
  if !bound.order.is_empty() {
    self.out.push(Order(bound.order))
  }
  self.rt.null_eliminated = false
  self.rt.count_override = None
  let mut n = 0L
  @exec.stream(self.ctx(), bound.plan, r => {
    n += 1L
    self.out.push(Row(r.map(wire_value)))
  })
  if self.rt.count_override is Some(c) {
    n = c
    self.rt.count_override = None
  }
  self.emit_null_warning(line)
  self.rt.rowcount = n
  self.done(193, count=Some(n), result_set=true)
}
