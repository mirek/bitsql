///|
test "flat aggregate keys preserve representatives evaluation order and errors" {
  let trace : Array[@types.Value] = []
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: (_, args) => {
      trace.push(args[0])
      if args[0] == @types.Value::String("fail") {
        raise @types.not_supported("test expression failure")
      }
      args[0]
    },
    user_table: no_user_table,
    seek: no_seek,
    seek_json: no_json_seek,
    vector_search: no_vector_search,
    stamp: no_stamp,
  }
  let cases : Array[Array[@types.Value]] = [
    [],
    [Null],
    [Null, Null],
    [Int(1), Null, Int(1), Int(2)],
    [TinyInt(1), SmallInt(1), BigInt(2L), Null],
    [Float(1.5), Float(1.5), Float(-2.0), Null],
    [Variant(Int(1), Int), Variant(Float(1.0), Float), Null],
    [
      @types.cast(Int(1), Int, Decimal(12, 2)),
      @types.cast(Int(2), Int, Decimal(12, 2)),
      Null,
    ],
    [String("a"), String("A"), String("a "), String("á"), Null],
    [String("7"), Int(7), Null],
    [String("bad"), Int(7), Null],
    [String("ok"), Null, String("fail"), Int(2)],
    [Date(5), DateTime2(4320000000000L), Null],
    [Binary(b"a"), Binary(b"a"), Binary(b"b"), Null],
    Array::makei(12000, i => {
      if i % 13 == 0 {
        Null
      } else {
        String("v" + (i % 997).to_string())
      }
    }),
  ]
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_CI_AI", "Latin1_General_100_BIN2",
    ] {
    let coll = @types.Collation::parse(name).unwrap()
    for
      ty in [@types.SqlType::NVarChar(Some(80), coll), VarChar(Some(80), coll)] {
      let expr : @ir.Expr = {
        kind: UserFn(1, [{ kind: Col(0), ty, nullable: true, }]),
        ty,
        nullable: true,
      }
      let call : @ir.AggCall = {
        func: Count,
        arg: Some({ kind: Col(0), ty, nullable: true, }),
        separator: None,
        distinct: false,
        order: [],
        ty: Int,
      }
      for values in cases {
        let rows = values.map(v => [v])
        for keys in [[expr], [], [expr, expr]] {
          trace.clear()
          ctx.rt.null_eliminated = false
          let expected = Ok(
            aggregate_materialized_keys(ctx, rows, keys, [call]),
          ) catch {
            e => Err(e)
          }
          let expected_trace = trace.copy()
          let warning = ctx.rt.null_eliminated
          trace.clear()
          ctx.rt.null_eliminated = false
          let actual = Ok(run_aggregate_fast(ctx, rows, keys, [call])) catch {
            e => Err(e)
          }
          assert_eq(actual, expected)
          assert_eq(trace, expected_trace)
          assert_eq(ctx.rt.null_eliminated, warning)
          assert_eq(rows, values.map(v => [v]))
        }
      }
    }
  }
}

///|
// Reference key materialization used before the flat single-column path.
fn aggregate_materialized_keys(
  ctx : Ctx,
  rows : Array[Row],
  keys : Array[@ir.Expr],
  aggs : Array[@ir.AggCall],
) -> Array[Row] raise @types.SqlError {
  let (ids, firsts) = if keys.is_empty() {
    (Array::make(rows.length(), 0), [[]])
  } else {
    let cs = keys.map(compile)
    let kvs = rows.map(r => cs.map(f => f(ctx, r)))
    let (ids, _) = group_ids(kvs, keys.map(k => k.ty.collation()))
    let firsts : Array[Row] = []
    for j, id in ids {
      if id == firsts.length() {
        firsts.push(kvs[j])
      }
    }
    (ids, firsts)
  }
  let args = aggs.map(a => a.arg.map(compile))
  let states = new_states(aggs, firsts.length())
  for j, row in rows {
    accumulate(ctx, aggs, args, states, ids[j], row)
  }
  firsts.mapi((g, key) => finish_group(aggs, states, g, key))
}
