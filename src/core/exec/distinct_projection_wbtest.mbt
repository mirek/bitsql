///|
test "flat DISTINCT projection and sorting preserve rows effects and errors" {
  let trace : Array[@types.Value] = []
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    scan_row: (_, _, _) => (),
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
      for values in cases {
        let source = values.map(v => (1L, [v]))
        let ctx = { ..ctx, source: (_, _) => source, }
        let project = @ir.Plan::Project(Scan(scope=0, id=1, rowid=false), [expr])
        trace.clear()
        ctx.rt.row_seq = 0L
        let expected = Ok(distinct_rows(run(ctx, project), [Some(coll)])) catch {
          e => Err(e)
        }
        let expected_rows = ctx.rt.row_seq
        let expected_trace = trace.copy()
        ctx.rt.row_seq = 0L
        trace.clear()
        let actual = Ok(run(ctx, Distinct(project, [Some(coll)]))) catch {
          e => Err(e)
        }
        assert_eq(actual, expected)
        assert_eq(ctx.rt.row_seq, expected_rows)
        assert_eq(trace, expected_trace)
        assert_eq(source.map(p => p.1), values.map(v => [v]))
        for desc in [false, true] {
          for sort_coll in [Some(coll), Some(@types.latin1_general_100_bin2)] {
            let key : @ir.SortKey = {
              expr: { kind: Col(0), ty, nullable: true, },
              desc,
              collation: sort_coll,
            }
            trace.clear()
            ctx.rt.row_seq = 0L
            let expected = Ok(
              sort_rows(ctx, distinct_rows(run(ctx, project), [Some(coll)]), [
                key,
              ]),
            ) catch {
              e => Err(e)
            }
            let expected_rows = ctx.rt.row_seq
            let expected_trace = trace.copy()
            trace.clear()
            ctx.rt.row_seq = 0L
            let actual = Ok(
              run(ctx, Sort(Distinct(project, [Some(coll)]), [key])),
            ) catch {
              e => Err(e)
            }
            assert_eq(actual, expected)
            assert_eq(ctx.rt.row_seq, expected_rows)
            assert_eq(trace, expected_trace)
            assert_eq(source.map(p => p.1), values.map(v => [v]))
          }
        }
      }
    }
  }
}
