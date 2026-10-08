///|
fn suspension_ctx() -> Ctx {
  {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [(0L, [Int(1)]), (1L, [Int(2)])],
    scan_row: (_, _, row) => if row == 1L { raise @types.Suspend },
    ext: (_, _) => raise @types.Suspend,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    profile: None,
    stamp: no_stamp,
  }
}

///|
test "scan suspension preserves earlier streamed rows and cannot be filtered out" {
  let ctx = suspension_ctx()
  let col : @ir.Expr = { kind: Col(0), ty: Int, nullable: false, }
  let pred : @ir.Expr = {
    kind: Cmp(Eq, col, @ir.Expr::lit(Int(1), Int), None),
    ty: Bit,
    nullable: false,
  }
  let plan = @ir.Plan::Filter(Scan(scope=2, id=0, rowid=false), pred)
  let rows : Array[Row] = []
  let suspended = try {
    stream(ctx, plan, r => rows.push(r))
    false
  } catch {
    @types.Suspend => true
    e => raise e
  }
  assert_true(suspended)
  assert_eq(rows, [[Int(1)]])
  let suspended = try {
    ignore(run(ctx, plan))
    false
  } catch {
    @types.Suspend => true
    e => raise e
  }
  assert_true(suspended)
}

///|
test "TRY_CAST and compiled expressions propagate internal suspension" {
  let ctx = suspension_ctx()
  let call : @ir.Expr = {
    kind: Call(Named("%SUSPEND"), []),
    ty: Int,
    nullable: true,
  }
  let expr : @ir.Expr = {
    kind: Cast(call, try_=true, style=None),
    ty: BigInt,
    nullable: true,
  }
  let interpreted = try {
    ignore(eval(ctx, expr))
    false
  } catch {
    @types.Suspend => true
    e => raise e
  }
  let compiled = try {
    ignore(compile(expr)(ctx, []))
    false
  } catch {
    @types.Suspend => true
    e => raise e
  }
  assert_true(interpreted && compiled)
}
