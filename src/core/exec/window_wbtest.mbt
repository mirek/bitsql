///|
test "row number scan agrees with partition materialization" {
  let words = ["a", "A", "á", "a ", "é", "é", "", " ", "z"]
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_CI_AI", "Latin1_General_100_CS_AS",
      "Latin1_General_100_BIN2",
    ] {
    let collation = @types.Collation::parse(name).unwrap()
    for n in [0, 1, 2, 1000] {
      for np in [0, 1, 2] {
        // Arbitrary key runs also cover boundaries whose equality differs
        // from the sort's ANSI key semantics. Positions are a permutation.
        let keyed : Array[(Array[@types.Value], Int)] = Array::makei(n, i => {
          let v : @types.Value = if i % 13 == 0 {
            Null
          } else {
            String(words[i / 3 % words.length()])
          }
          ([v, Int(i / 11)], n - i - 1)
        })
        let collations = [Some(collation), None]
        let expected = Array::make(n, @types.Value::Null)
        let parts : Array[(Int, Int)] = []
        let mut start = 0
        for j in 1..<=n {
          if j == n || !same_prefix(keyed[j - 1].0, keyed[j].0, np, collations) {
            if j > start {
              parts.push((start, j))
            }
            start = j
          }
        }
        for p in parts {
          for j in p.0..<p.1 {
            expected[keyed[j].1] = BigInt((j - p.0 + 1).to_int64())
          }
        }
        let actual = Array::make(n, @types.Value::Null)
        row_numbers(keyed, np, collations, actual)
        assert_eq(actual, expected)
      }
    }
  }
}

///|
test "normalized row numbers preserve ranks and the stable permutation" {
  let words = [
    "a", "A", "á", "a ", "é", "é", "", " ", "z", "a-b", "ab", "a\u0000", "éshared-long-prefix-a",
    "éshared-long-prefix-b",
  ]
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_CI_AI", "Latin1_General_100_CS_AS",
      "Latin1_General_100_BIN2",
    ] {
    let coll = @types.Collation::parse(name).unwrap()
    for ansi in [false, true] {
      let text : @types.SqlType = if ansi {
        VarChar(Some(80), coll)
      } else {
        NVarChar(Some(80), coll)
      }
      for n in [0, 1, 2, 400] {
        for np in [0, 1, 2] {
          for desc in [false, true] {
            let keys : Array[@ir.SortKey] = [
              {
                expr: { kind: Col(0), ty: text, nullable: true, },
                collation: Some(coll),
                desc: if np > 0 {
                  false
                } else {
                  desc
                },
              },
              {
                expr: { kind: Col(1), ty: BigInt, nullable: true, },
                collation: None,
                desc: if np > 1 {
                  false
                } else {
                  desc
                },
              },
            ]
            let values : Array[Array[@types.Value]] = Array::makei(n, i => {
              [
                if i % 13 == 0 {
                  Null
                } else {
                  String(words[(n - i - 1) * 7 % words.length()])
                },
                if i % 17 == 0 {
                  Null
                } else {
                  BigInt((i % 9).to_int64())
                },
              ]
            })
            let keyed = values.mapi((i, v) => (v, i))
            let sorted = sort_keyed(keyed, keys)
            let expected = Array::make(n, @types.Value::Null)
            let collations = [Some(coll), None]
            row_numbers(sorted, np, collations, expected)
            let actual = Array::make(n, @types.Value::Null)
            match row_numbers_normalized(values, keys, np, actual) {
              Some(order) => {
                assert_eq(order, sorted.map(kv => kv.1))
                assert_eq(actual, expected)
              }
              None => {
                assert_eq(actual, Array::make(n, @types.Value::Null))
                // Exercise the exact fallback on the already evaluated values.
                row_numbers(sort_keyed(keyed, keys), np, collations, actual)
                assert_eq(actual, expected)
              }
            }
            if ansi && np > 0 {
              assert_eq(row_numbers_normalized(values, keys, np, actual), None)
            }
          }
        }
      }
    }
  }
  // No partition or ordering keys: the stable input permutation survives.
  let values : Array[Array[@types.Value]] = [[], [], []]
  let actual = Array::make(3, @types.Value::Null)
  assert_eq(row_numbers_normalized(values, [], 0, actual), Some([0, 1, 2]))
  let expected = Array::make(3, @types.Value::Null)
  row_numbers([([], 0), ([], 1), ([], 2)], 0, [], expected)
  assert_eq(actual, expected)
}

///|
test "normalized row numbers reject mixed and inexact keys before rank writes" {
  let keys : Array[@ir.SortKey] = [
    {
      expr: { kind: Col(0), ty: BigInt, nullable: true, },
      collation: None,
      desc: false,
    },
  ]
  for
    values in [
      [[@types.Value::Int(1)], [String("1")]],
      [[@types.Value::Int(1)], [Date(1)]],
      [[@types.Value::Float(1.0)], [Float(2.0)]],
      [[@types.Value::Int(1)], [String("invalid")]],
    ] {
    let result = Array::make(values.length(), @types.Value::Null)
    assert_eq(row_numbers_normalized(values, keys, 1, result), None)
    assert_eq(result, Array::make(values.length(), @types.Value::Null))
    // The caller retains the same values and reaches the original comparator,
    // including its errors; normalization itself neither compares nor raises.
  }
}

///|
test "row number prefix reuse preserves expression evaluation and failures" {
  let coll = @types.default_collation
  let trace : Array[(Int, @types.Value)] = []
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: (id, args) => {
      trace.push((id, args[0]))
      if args[0] == @types.Value::String("fail") {
        raise @types.not_supported("test expression failure")
      }
      args[0]
    },
    user_table: no_user_table,
    seek: no_seek,
    stamp: no_stamp,
  }
  for ansi in [false, true] {
    let ty : @types.SqlType = if ansi {
      VarChar(Some(20), coll)
    } else {
      NVarChar(Some(20), coll)
    }
    let partition : @ir.Expr = {
      kind: UserFn(1, [{ kind: Col(0), ty, nullable: true, }]),
      ty,
      nullable: true,
    }
    let ordering : @ir.Expr = {
      kind: UserFn(2, [{ kind: Col(1), ty: Int, nullable: false, }]),
      ty: Int,
      nullable: false,
    }
    let call : @ir.WindowCall = {
      func: RowNumber,
      args: [],
      partition: [partition],
      partition_collations: [Some(coll)],
      order: [{ expr: ordering, collation: None, desc: true, }],
      frame: None,
      ty: BigInt,
      ignore_nulls: false,
    }
    for
      rows in [
        [
          [@types.Value::String("b"), Int(1)],
          [String("a"), Int(2)],
          [String("A"), Int(3)],
        ],
        [[@types.Value::String("b"), Int(1)], [String("fail"), Int(2)]],
        [[@types.Value::Int(1), Int(1)], [String("invalid"), Int(2)]],
      ] {
      trace.clear()
      let actual = Ok(window_values_ordered(ctx, rows, call)) catch {
        e => Err(e)
      }
      let actual_trace = trace.copy()
      trace.clear()
      let expected = try {
        let keys : Array[@ir.SortKey] = [
          { expr: partition, collation: Some(coll), desc: false, },
          call.order[0],
        ]
        let cs = keys.map(k => compile(k.expr))
        let keyed = rows.mapi((i, r) => (cs.map(f => f(ctx, r)), i))
        let sorted = sort_keyed(keyed, keys)
        let result = Array::make(rows.length(), @types.Value::Null)
        row_numbers(sorted, 1, [Some(coll)], result)
        Ok((result, sorted.map(kv => kv.1)))
      } catch {
        e => Err(e)
      }
      assert_eq(actual, expected)
      assert_eq(actual_trace, trace)
    }
  }
}

///|
test "direct window columns preserve materialized-key results and failures" {
  let ctx : Ctx = {
    rt: Runtime::new(database="master", spid=51, now=0L, seed=1L),
    vars: [],
    row: [],
    outer: [],
    source: (_, _) => [],
    ext: (_, _) => None,
    user_fn: no_user_fn,
    user_table: no_user_table,
    seek: no_seek,
    stamp: no_stamp,
  }
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_CI_AI", "Latin1_General_100_BIN2",
    ] {
    let coll = @types.Collation::parse(name).unwrap()
    for ansi in [false, true] {
      let ty : @types.SqlType = if ansi {
        VarChar(Some(80), coll)
      } else {
        NVarChar(Some(80), coll)
      }
      let partition : @ir.Expr = { kind: Col(1), ty, nullable: true, }
      let ordering : @ir.Expr = { kind: Col(0), ty: Int, nullable: true, }
      let keys : Array[@ir.SortKey] = [
        { expr: partition, collation: Some(coll), desc: false, },
        { expr: ordering, collation: None, desc: true, },
      ]
      let call : @ir.WindowCall = {
        func: RowNumber,
        args: [],
        partition: [partition],
        partition_collations: [Some(coll)],
        order: [keys[1]],
        frame: None,
        ty: BigInt,
        ignore_nulls: false,
      }
      let words = ["a", "A", "a ", "á", "b", "é", "é"]
      for n in [0, 1, 1000] {
        for mode in 0..<3 {
          let rows : Array[Row] = Array::makei(n, i => {
            let first : @types.Value = if mode == 1 {
              @types.cast(Int(i % 17), Int, Decimal(12, 2))
            } else if mode == 2 && i == n - 1 {
              String("invalid number")
            } else {
              Int(i % 17)
            }
            [
              first,
              if i % 13 == 0 {
                Null
              } else {
                String(words[i % words.length()])
              },
              Float(1.5),
            ]
          })
          let expected = try {
            let cs = keys.map(k => compile(k.expr))
            let keyed = rows.mapi((i, r) => (cs.map(f => f(ctx, r)), i))
            let sorted = sort_keyed(keyed, keys)
            let result = Array::make(n, @types.Value::Null)
            row_numbers(sorted, 1, [Some(coll)], result)
            Ok((result, sorted.map(kv => kv.1)))
          } catch {
            e => Err(e)
          }
          let actual = Ok(window_values_ordered(ctx, rows, call)) catch {
            e => Err(e)
          }
          assert_eq(actual, expected)
          if expected is Ok((values, order)) {
            let expected_rows = order.map(i => {
              let row = rows[i].copy()
              row.push(values[i])
              row
            })
            assert_eq(run_window(ctx, rows, [call]), expected_rows)
          }
        }
      }
    }
  }
}
