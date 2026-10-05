///|
test "text grouping agrees with pairwise SQL comparison" {
  let words = [
    "a", "A", "á", "Á", "ab", "a b", "a-b", "ab ", "", " ", "z", "Z", "ä", "ae",
    "æ", "o", "ö", "oe", "ß", "ss", "-", "'", "é", "é", "x", "ǅ",
  ]
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "Latin1_General_100_CI_AI", "Latin1_General_100_CS_AS",
      "Latin1_General_100_BIN2",
    ] {
    let collation = @types.Collation::parse(name).unwrap()
    for ansi in [false, true] {
      let rows : Array[Row] = Array::makei(400, i => {
        if i % 13 == 0 {
          [Null]
        } else {
          [String(words[i * 7 % words.length()])]
        }
      })
      let representatives : Array[@types.Value] = []
      let expected : Array[Int] = []
      for row in rows {
        let mut id = -1
        for j, v in representatives {
          let equal = match (row[0], v) {
            (Null, Null) => true
            (Null, _) | (_, Null) => false
            _ => @types.compare(row[0], v, collation~, ansi~) == Some(0)
          }
          if equal {
            id = j
            break
          }
        }
        if id < 0 {
          id = representatives.length()
          representatives.push(row[0])
        }
        expected.push(id)
      }
      let (ids, count) = group_ids(rows, [Some(collation)], ansi~)
      assert_eq(ids, expected)
      assert_eq(count, representatives.length())
    }
  }
}

///|
test "single-column slots preserve first occurrence for temporal keys" {
  // Date and datetime2 use the same exact key kind. Equal values with
  // different constructors must meet even after hash-slot collisions.
  let rows : Array[Row] = Array::makei(2000, i => {
    let day = i * 37 % 997
    if i % 13 == 0 {
      [Null]
    } else if i % 2 == 0 {
      [Date(day)]
    } else {
      [DateTime2(day.to_int64() * 864000000000L)]
    }
  })
  let reference : Map[@types.SortKey, Int] = Map([])
  let expected = rows.map(r => {
    let k = @types.sort_key(r[0])
    match reference.get(k) {
      Some(id) => id
      None => {
        let id = reference.length()
        reference[k] = id
        id
      }
    }
  })
  let (ids, count) = group_ids(rows, [None])
  assert_eq(ids, expected)
  assert_eq(count, reference.length())
  assert_eq(group_ids([], [None]), ([], 0))
  assert_eq(group_ids([[Null], [Null]], [None]), ([0, 0], 1))
}
