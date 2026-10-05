///|
/// Pairs where key order disagrees with `compare` (NULL first).
fn sort_key_mismatches(
  values : Array[Value],
  collation : Collation,
  ansi : Bool,
) -> Array[(Value, Value)] {
  let keys = values.map(v => sort_key(v, collation~, ansi~))
  let bad = []
  for i, a in values {
    for j, b in values {
      let expected = match (a, b) {
        (Null, Null) => 0
        (Null, _) => -1
        (_, Null) => 1
        _ => (compare(a, b, collation~, ansi~) catch { _ => None }).unwrap_or(9)
      }
      let actual = compare_sort_keys(keys[i], keys[j], collation~, ansi~) catch {
        _ => 9
      }
      if expected != actual {
        bad.push((a, b))
      }
    }
  }
  bad
}

///|
test "text sort keys order like compare_strings" {
  // units with special paths: case, accents (precomposed and combining),
  // expansions, word-sort punctuation, trailing spaces and ignorables,
  // width and kana variants, final sigma, dotted/dotless i, surrogates
  let strings = all_strings(
    [
      "a", "A", "\u{e9}", "e", "\u{301}", "\u{df}", "s", "\u{e6}", "-", "'", " ",
      "\u{0}", "0", "\u{ff41}", "\u{30a2}", "\u{3042}", "\u{3c2}", "\u{3a3}", "\u{130}",
      "\u{131}", "\u{2d}", "\u{ad}", "\u{17d}",
    ],
    2,
  )
  let sb = StringBuilder()
  sb.write_char((0xD83D).unsafe_to_char())
  let lone_surrogate = sb.to_string()
  strings.push(lone_surrogate)
  strings.push("a" + lone_surrogate)
  strings.push(lone_surrogate + "a")
  for s in all_strings(["a", "-", " ", "\u{e1}", "B", "'"], 3) {
    strings.push(s)
  }
  // every ASCII unit (the direct ASCII path), alone and around letters
  for u in 0..<128 {
    let c = u.unsafe_to_char().to_string()
    strings.push(c)
    strings.push("a" + c + "B")
    strings.push(c + "-" + c)
  }
  let values = strings.map(s => Value::String(s))
  values.push(Null)
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "SQL_Latin1_General_CP1_CS_AS", "Latin1_General_CI_AS",
      "Latin1_General_CS_AS_KS_WS", "Latin1_General_100_CI_AI", "Latin1_General_100_CS_AS_KS_WS",
      "Latin1_General_100_CI_AS_SC_UTF8", "Latin1_General_BIN2", "Latin1_General_BIN",
    ] {
    let c = Collation::parse(name).unwrap()
    for ansi in [false, true] {
      let bad = sort_key_mismatches(values, c, ansi)
      if !bad.is_empty() {
        fail(
          "\{name} ansi=\{ansi}: \{bad.length()} mismatches, first \{@debug.to_string(bad[0])}",
        )
      }
    }
  }
}

///|
test "numeric and temporal sort keys order like compare" {
  let values : Array[Value] = [
    Null,
    TinyInt(0),
    TinyInt(255),
    SmallInt(-5),
    Int(-2147483648),
    Int(7),
    Int(2147483647),
    BigInt(-9223372036854775808L),
    BigInt(7L),
    BigInt(9223372036854775807L),
    Float(6.5),
    Bit(true),
    Date(0),
    Date(738000),
    DateTime2(0L),
    DateTime2(738000L * TICKS_PER_DAY),
    DateTime2(738000L * TICKS_PER_DAY + 1L),
    DateTime(0, 0),
    DateTime(-53690, 1),
  ]
  let bad = sort_key_mismatches(values, default_collation, false)
  // incomparable pairs raise on both sides (9 == 9)
  if !bad.is_empty() {
    fail("\{bad.length()} mismatches, first \{@debug.to_string(bad[0])}")
  }
}
