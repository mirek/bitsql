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
      let rows : Array[Row] = Array::makei(12000, i => {
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

///|
test "integer RowSet agrees with general keys including conversions and errors" {
  let many : Array[Row] = Array::makei(3000, i => {
    let n = i * 37 % 997
    if i % 17 == 0 {
      [Null]
    } else {
      [Int(n)]
    }
  })
  let sets : Array[Array[Row]] = [
    [],
    [[Null], [Null]],
    [[TinyInt(7)], [SmallInt(-3)], [Int(7)], [BigInt(7L)], [Null]],
    [[BigInt(-9223372036854775808L)], [BigInt(9223372036854775807L)]],
    [[TinyInt(0)], [Int(256)]],
    [[Int(256)], [TinyInt(0)]],
    many,
  ]
  let probes : Array[@types.Value] = [
    Null,
    TinyInt(0),
    TinyInt(7),
    SmallInt(-3),
    Int(256),
    Int(-99),
    BigInt(-9223372036854775808L),
    BigInt(9223372036854775807L),
    Float(7.0),
    Float(7.5),
    Bit(true),
    String("7"),
    String("256"),
    String("not an integer"),
    Date(0),
  ]
  for rows in sets {
    let fast = RowSet::new(rows, [None])
    let reference = RowSet::new(rows, [None], integer_fast=false)
    for value in probes {
      let actual = Ok(fast.contains([value])) catch { e => Err(e) }
      let expected = Ok(reference.contains([value])) catch { e => Err(e) }
      assert_eq(actual, expected)
    }
    for n in -5..<1010 {
      assert_eq(fast.contains([Int(n)]), reference.contains([Int(n)]))
    }
  }
}

///|
test "adaptive text grouping handles unique input and changing distributions" {
  for mode in 0..<3 {
    let rows : Array[Row] = Array::makei(20000, i => {
      let k = if mode == 0 {
        i
      } else if mode == 1 && i >= 4096 {
        i
      } else if mode == 1 {
        i % 17
      } else {
        i % 5003
      }
      [String("v" + k.to_string())]
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
  }
}

///|
test "adaptive text grouping retains mixed-kind comparison errors" {
  let rows : Array[Row] = Array::makei(4096, _ => [String("not a number")])
  rows.push([Int(1)])
  let actual = try {
    ignore(group_ids(rows, [None]))
    Ok(())
  } catch {
    e => Err(e)
  }
  let expected = try {
    ignore(
      sort_key_rows(rows.map(r => key_row(r, [None], false)), [None], false),
    )
    Ok(())
  } catch {
    e => Err(e)
  }
  assert_eq(actual, expected)
  assert_true(actual is Err(_))
}
