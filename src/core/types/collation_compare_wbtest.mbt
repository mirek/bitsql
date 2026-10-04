///|
/// All strings of up to `max_len` units over `alphabet`.
fn all_strings(alphabet : Array[String], max_len : Int) -> Array[String] {
  let strings : Array[String] = [""]
  let mut start = 0
  for _ in 0..<max_len {
    let end = strings.length()
    for k in start..<end {
      for c in alphabet {
        strings.push(strings[k] + c)
      }
    }
    start = end
  }
  strings
}

///|
/// Count pairs where `compare_strings` (shared prefix + ASCII fast path)
/// disagrees with the element-array comparison.
fn fast_path_mismatches(
  strings : Array[String],
  cases : Array[(String, Bool)],
) -> (Int, Int) {
  let mut checked = 0
  let mut mismatches = 0
  for case_ in cases {
    let (name, ansi) = case_
    let c = Collation::parse(name).unwrap()
    for a in strings {
      for b in strings {
        let slow = if a == b { 0 } else { compare_linguistic(a, b, c, ansi) }
        if compare_strings(a, b, c, ansi~) != slow {
          mismatches += 1
        }
        checked += 1
      }
    }
  }
  (checked, mismatches)
}

///|
/// The ASCII fast path must agree with the element-array comparison on
/// every pair of short strings over the units that take special paths
/// (case, digits, word-sort hyphen/apostrophe, spaces, NUL, controls),
/// under SQL and Windows collations, for Unicode and ansi operands.
test "ASCII fast path agrees with compare_linguistic" {
  let strings = all_strings(
    ["a", "A", "z", "-", "'", " ", "0", "\u{0}", "\u{1}"],
    3,
  )
  let cases = []
  for
    name in [
      "SQL_Latin1_General_CP1_CI_AS", "SQL_Latin1_General_CP1_CS_AS", "Latin1_General_CS_AS",
      "Latin1_General_100_CS_AS_KS_WS", "Latin1_General_100_CI_AI",
    ] {
    cases.push((name, false))
    cases.push((name, true))
  }
  debug_inspect(fast_path_mismatches(strings, cases), content="(6724000, 0)")
}

///|
/// Mixed ASCII / non-ASCII strings exercise the shared-prefix skip
/// (accents, combining marks, expansions, soft hyphen, surrogates, width).
test "shared prefix skip agrees with compare_linguistic" {
  let high = StringBuilder()
  high.write_char((0xD83D).unsafe_to_char())
  let strings = all_strings(
    [
      "a",
      "A",
      "-",
      " ",
      "\u{0}",
      "é",
      "\u{301}",
      "ß",
      "\u{AD}",
      high.to_string(),
      "\u{FF41}",
    ],
    3,
  )
  let cases = [
    ("Latin1_General_100_CS_AS_KS_WS", false),
    ("Latin1_General_CS_AS", false),
    ("SQL_Latin1_General_CP1_CS_AS", true),
  ]
  debug_inspect(fast_path_mismatches(strings, cases), content="(6429888, 0)")
}
