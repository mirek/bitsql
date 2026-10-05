///|
test "top_n_values equals the first n rows of the sort-key sort" {
  let coll = @types.default_collation
  let text : @types.SqlType = NVarChar(Some(20), coll)
  let words = [
    "a", "A", "á", "Á", "ab", "a b", "a-b", "ab ", "", " ", "z", "Z", "ä", "ae",
    "æ", "o", "ö", "oe", "ß", "ss", "-", "'", "é", "é", "x",
  ]
  for desc in [false, true] {
    let keys : Array[@ir.SortKey] = [
      {
        expr: { kind: Col(0), ty: text, nullable: true, },
        desc,
        collation: Some(coll),
      },
      {
        expr: { kind: Col(1), ty: Int, nullable: true, },
        desc: false,
        collation: None,
      },
    ]
    // NULLs, ties on both keys and every word several times
    let values : Array[Array[@types.Value]] = Array::makei(400, i => {
      let a : @types.Value = if i % 11 == 0 {
        Null
      } else {
        String(words[i * 7 % words.length()])
      }
      [a, Int(i % 4)]
    })
    let rows : Array[Row] = Array::makei(400, i => [Int(i)])
    let ansi = keys.map(ansi_key)
    let prepared = rows.mapi((i, r) => (order_keys(values[i], keys, ansi), r))
    sort_prepared(prepared, keys, ansi)
    for n in [0, 1, 3, 10, 57, 99] {
      let expect = prepared[0:n].iter().map(p => p.1).to_array()
      assert_eq(top_n_values(values, rows, n, keys), expect)
    }
  }
}
