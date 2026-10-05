///|
test "normalized keys sort exactly like sort_prepared" {
  let coll = @types.default_collation
  let text : @types.SqlType = NVarChar(Some(20), coll)
  let words = [
    "a", "A", "á", "Á", "ab", "a b", "a-b", "ab ", "", " ", "z", "Z", "ä", "ae",
    "æ", "o", "ö", "oe", "ß", "ss", "-", "'", "é", "é", "x", "ǅ",
  ]
  let ints : Array[Int64] = [
    -9223372036854775808L, -4294967296L, -4294967295L, -1L, 0L, 1L, 2147483647L,
    2147483648L, 4294967295L, 4294967296L, 9223372036854775807L,
  ]
  for d0 in [false, true] {
    for d1 in [false, true] {
      for d2 in [false, true] {
        let keys : Array[@ir.SortKey] = [
          {
            expr: { kind: Col(0), ty: text, nullable: true, },
            desc: d0,
            collation: Some(coll),
          },
          {
            expr: { kind: Col(1), ty: BigInt, nullable: true, },
            desc: d1,
            collation: None,
          },
          {
            expr: { kind: Col(2), ty: Date, nullable: true, },
            desc: d2,
            collation: None,
          },
        ]
        let values : Array[Array[@types.Value]] = Array::makei(600, i => {
          let a : @types.Value = if i % 13 == 0 {
            Null
          } else {
            String(words[i * 7 % words.length()])
          }
          let b : @types.Value = if i % 17 == 0 {
            Null
          } else {
            BigInt(ints[i * 5 % ints.length()])
          }
          let c : @types.Value = if i % 19 == 0 { Null } else { Date(i % 3) }
          [a, b, c]
        })
        let ansi = keys.map(ansi_key)
        let prepared = values.mapi((i, v) => (order_keys(v, keys, ansi), i))
        sort_prepared(prepared, keys, ansi)
        let expect = prepared.map(p => p.1)
        assert_eq(sort_order(values, keys), Some(expect))
      }
    }
  }
}
