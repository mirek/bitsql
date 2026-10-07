///|
test "flat count inputs preserve cardinality NULL warnings and errors" {
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
      for values in cases {
        let rows = values.map(v => [v])
        for distinct in [false, true] {
          for star in [false, true] {
            let call : @ir.AggCall = {
              func: Count,
              arg: if star {
                None
              } else {
                Some({
                  kind: UserFn(1, [{ kind: Col(0), ty, nullable: true, }]),
                  ty,
                  nullable: true,
                })
              },
              separator: None,
              distinct,
              order: [],
              ty: Int,
            }
            ctx.rt.null_eliminated = false
            trace.clear()
            let expected = Ok(
              if star {
                rows.length()
              } else {
                agg_inputs(ctx, call, rows[:]).length()
              },
            ) catch {
              e => Err(e)
            }
            let expected_trace = trace.copy()
            trace.clear()
            let warning = ctx.rt.null_eliminated
            ctx.rt.null_eliminated = false
            let actual = Ok(count_inputs(ctx, call, rows[:])) catch {
              e => Err(e)
            }
            assert_eq(actual, expected)
            assert_eq(trace, expected_trace)
            assert_eq(ctx.rt.null_eliminated, warning)
          }
        }
      }
    }
  }
}
