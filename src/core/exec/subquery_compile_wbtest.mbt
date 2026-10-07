///|
test "compiled subqueries preserve cache invalidation effects and errors" {
  let col : @ir.Expr = { kind: Col(0), ty: Int, nullable: true, }
  let value : @ir.Expr = { kind: Col(1), ty: Int, nullable: true, }
  let outer : @ir.Expr = { kind: OuterCol(1, 0), ty: Int, nullable: true, }
  let variable : @ir.Expr = { kind: Var(0), ty: Int, nullable: true, }
  let equal : @ir.Expr = {
    kind: Cmp(Eq, col, outer, None),
    ty: Bit,
    nullable: true,
  }
  let scan = @ir.Plan::Scan(scope=0, id=1, rowid=false)
  let filtered = @ir.Plan::Filter(scan, equal)
  let call : @ir.AggCall = {
    func: Count,
    arg: Some(value),
    separator: None,
    distinct: false,
    order: [],
    ty: Int,
  }
  let fn_value : @ir.Expr = {
    kind: UserFn(1, [value]),
    ty: Int,
    nullable: true,
  }
  let plans : Array[@ir.Plan] = [
    Project(filtered, [value]),
    Aggregate(filtered, [], [call], sets=[]),
    Project(scan, [variable]),
    Project(OneRow, [{ kind: OuterCol(2, 0), ty: Int, nullable: true, }]),
    Project(filtered, [fn_value]),
    Project(
      Filter(scan, {
        kind: And(equal, {
          kind: Cmp(Gt, value, variable, None),
          ty: Bit,
          nullable: true,
        }),
        ty: Bit,
        nullable: true,
      }),
      [value],
    ),
  ]
  for plan in plans {
    for scalar in [false, true] {
      let expr : @ir.Expr = {
        kind: if scalar {
          Subquery(plan)
        } else {
          Exists(plan)
        },
        ty: if scalar {
          Int
        } else {
          Bit
        },
        nullable: scalar,
      }
      for stamped in [false, true] {
        assert_eq(
          subquery_execution_trace(expr, stamped, true),
          subquery_execution_trace(expr, stamped, false),
        )
      }
    }
  }
}

///|
fn subquery_execution_trace(
  expr : @ir.Expr,
  stamped : Bool,
  compiled : Bool,
) -> Array[
  (
    Result[@types.Value, @types.SqlError],
    Int64,
    Int64,
    Bool,
    Array[@types.Value],
  ),
] {
  let mut revision = 1L
  let mut rows : Array[(Int64, Row)] = [
    (1L, [Int(1), Int(10)]),
    (2L, [Int(2), Null]),
    (3L, [Int(1), Int(11)]),
  ]
  let effects : Array[@types.Value] = []
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [Int(0)],
    // Deliberately different from every row passed to the compiled closure.
    row: [Int(-999)],
    outer: [[Int(77)]],
    source: (_, _) => rows,
    ext: (_, _) => None,
    user_fn: (_, args) => {
      effects.push(args[0])
      if args[0] == @types.Value::Int(99) {
        raise @types.not_supported("test expression failure")
      }
      args[0]
    },
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    stamp: (_, _) => if stamped { Some(revision) } else { None },
  }
  let f = compile(expr)
  let out = []
  let inputs : Array[@types.Value] = [
    Int(1),
    Int(2),
    Int(1),
    Null,
    Int(1),
    Int(2),
    Int(1),
    Int(1),
    Int(1),
    Int(1),
  ]
  for i, v in inputs {
    if i == 4 {
      rows = [(4L, [Int(1), Int(99)])]
      revision += 1L
    }
    if i == 6 {
      ctx.vars[0] = Int(100)
    }
    if i == 8 {
      ctx.rt.clear_caches()
    }
    effects.clear()
    ctx.rt.row_seq = 0L
    ctx.rt.work_done = 0L
    ctx.rt.null_eliminated = false
    ctx.rt.work_limit = if i == 9 { 1L } else { default_work_limit }
    let row = [v]
    let result = Ok(
      if compiled {
        f(ctx, row)
      } else {
        eval(ctx.with_row(row), expr)
      },
    ) catch {
      e => Err(e)
    }
    out.push(
      (
        result,
        ctx.rt.row_seq,
        ctx.rt.work_done,
        ctx.rt.null_eliminated,
        effects.copy(),
      ),
    )
  }
  out
}
