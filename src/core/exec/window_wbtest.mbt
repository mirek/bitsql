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
