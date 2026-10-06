///|
test "compact ASCII keys preserve general collation equality and order" {
  let words = ["", " ", "        ", "a ", "A", "00000000", "zzzzzzzz"]
  for c in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" {
    let s = c.to_string()
    words.push(s)
    words.push(s + "0")
    words.push(s + "z")
    words.push(s + " ")
    words.push(s.repeat(8))
  }
  for a in words {
    for b in words {
      let x = compact_word(a).unwrap()
      let y = compact_word(b).unwrap()
      let expected = @types.compare_sort_keys(
        @types.sort_key(String(a)),
        @types.sort_key(String(b)),
      )
      assert_eq(if x < y { -1 } else if x > y { 1 } else { 0 }, expected)
    }
  }
  for s in ["123456789", "a-b", "a b", "a'b", "é", "İ", "ı", "\u{0000}"] {
    assert_eq(compact_word(s), None)
  }
}

///|
test "compact grouping and sort agree with general paths including late fallback" {
  let words = [
    "", " ", "0", "00", "00000000", "1", "10", "9", "A", "a", "A0", "a0 ", "I", "i",
    "Z", "zzzzzzzz", "ZZZZZZZZ",
  ]
  for extra in ["a", "123456789", "é", "a-b", "İ", "ı"] {
    let rows : Array[Row] = Array::makei(1200, i => {
      [if i % 17 == 0 { Null } else { String(words[i * 7 % words.length()]) }]
    })
    rows.push([String(extra)])
    for
      name in [
        "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_BIN2", "Latin1_General_100_CS_AS",
      ] {
      let coll = @types.Collation::parse(name).unwrap()
      for ansi in [false, true] {
        assert_eq(
          group_ids(rows, [Some(coll)], ansi~),
          group_ids_general(rows, [Some(coll)], ansi),
        )
        for desc in [false, true] {
          let ty : @types.SqlType = if ansi {
            VarChar(Some(32), coll)
          } else {
            NVarChar(Some(32), coll)
          }
          let keys : Array[@ir.SortKey] = [
            {
              expr: { kind: Col(0), ty, nullable: true, },
              desc,
              collation: Some(coll),
            },
          ]
          let prepared = rows.mapi((i, r) => (order_keys(r, keys, [ansi]), i))
          sort_prepared(prepared, keys, [ansi])
          let expected = prepared.map(p => p.1)
          match sort_order(rows, keys) {
            Some(actual) => assert_eq(actual, expected)
            None => assert_false(compact_collation(Some(coll), ansi))
          }
          let wide : Array[Row] = rows.mapi((i, r) => [Int(i), r[0]])
          assert_eq(
            normalized_keys(wide, keys, columns=Some([1])),
            normalized_keys(rows, keys),
          )
        }
      }
    }
  }
}

///|
test "compact normalized multi-column keys preserve boundaries and descending ties" {
  let coll = @types.default_collation
  let words = ["", " ", "0", "00", "A", "a", "a0", "zzzzzzzz"]
  let rows : Array[Row] = Array::makei(500, i => {
    [
      String(words[i % 8]),
      if i % 11 == 0 {
        Null
      } else {
        String(words[i / 8 % 8])
      },
      Int(i % 3),
    ]
  })
  for d0 in [false, true] {
    for d1 in [false, true] {
      let keys : Array[@ir.SortKey] = [
        {
          expr: { kind: Col(0), ty: NVarChar(Some(8), coll), nullable: false, },
          desc: d0,
          collation: Some(coll),
        },
        {
          expr: { kind: Col(1), ty: NVarChar(Some(8), coll), nullable: true, },
          desc: d1,
          collation: Some(coll),
        },
        {
          expr: { kind: Col(2), ty: Int, nullable: false, },
          desc: true,
          collation: None,
        },
      ]
      let prepared = rows.mapi((i, r) => {
        (order_keys(r, keys, [false, false, false]), i)
      })
      sort_prepared(prepared, keys, [false, false, false])
      assert_eq(sort_order(rows, keys), Some(prepared.map(p => p.1)))
    }
  }
}

///|
test "compact boundary probes never skip interior validation" {
  for at in [0, 1, 15, 30, 31] {
    for bad in ["é", "123456789", "a b", "İ", "\u{0000}"] {
      let values : Array[@types.Value] = Array::make(32, String("a"))
      values[at] = String(bad)
      assert_eq(compact_words(values, None, false), None)
      assert_eq(compact_row_words(values.map(v => [v]), 0), None)
      let rows = values.map(v => [v])
      assert_eq(group_ids(rows, [None]), group_ids_general(rows, [None], false))
    }
  }
}
