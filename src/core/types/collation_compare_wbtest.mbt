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
/// disagrees with the reference element-array comparison
/// (collation_reference_wbtest.mbt).
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
        let slow = if a == b {
          0
        } else {
          ref_compare_linguistic(a, b, c, ansi)
        }
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

///|
/// Units that take every branch of `push_unit_elements`: all of Latin-1,
/// Latin Extended-A/B start, combining marks, Greek and basic Cyrillic
/// case pairs, fullwidth ASCII, katakana/hiragana, surrogates, ignorables
/// (version 0 and 100) and a few unknown code points.
fn element_test_units() -> Array[Int] {
  let units = []
  for u in 0..<0x460 {
    if u < 0x250 || u >= 0x300 {
      units.push(u)
    }
  }
  for
    u in [
      0x200C, 0x200D, 0x200E, 0x2010, 0x20AC, 0x3041, 0x3042, 0x3096, 0x30A1, 0x30A2,
      0x30F6, 0x30F7, 0xD800, 0xD83D, 0xDC00, 0xDFFF, 0xFEFF, 0xFF01, 0xFF21, 0xFF41,
      0xFF5E, 0xFF5F, 0xFFFD, 0xFFFF,
    ] {
    units.push(u)
  }
  units
}

///|
let element_test_collations : Array[String] = [
  "SQL_Latin1_General_CP1_CI_AS", "SQL_Latin1_General_CP1_CS_AS", "Latin1_General_CI_AI",
  "Latin1_General_CS_AS_KS_WS", "Latin1_General_100_CI_AI", "Latin1_General_100_CS_AS_KS_WS",
  "Latin1_General_100_CI_AS_SC_UTF8",
]

///|
/// A unit as a one-unit string (lone surrogates included).
fn unit_string(u : Int) -> String {
  let sb = StringBuilder()
  sb.write_char(u.unsafe_to_char())
  sb.to_string()
}

///|
/// The packed elements must decode to exactly the reference elements, for
/// every unit alone and in context (after a letter, before a space and a
/// hyphen, doubled before an apostrophe), under both sort-table versions
/// and both word and string sort.
test "packed elements decode to the reference elements" {
  let mut checked = 0
  for name in element_test_collations {
    let c = Collation::parse(name).unwrap()
    for ansi in [false, true] {
      for u in element_test_units() {
        let ch = unit_string(u)
        for s in [ch, "A" + ch + "b", ch + " -x", "x" + ch + ch + "'"] {
          let (re, rw) = ref_collation_elements(s, c, ansi)
          let es : Array[Int] = []
          let ws : Array[Int] = []
          collation_elements_into(s, 0, c, ansi, es, ws)
          let decoded = es.map(e => {
            [
              element_weight(e, 0),
              element_weight(e, 1),
              element_weight(e, 2),
              element_weight(e, 3),
              element_weight(e, 4),
            ]
          })
          let expected = re.map(e => {
            [e.primary, e.secondary, e.tertiary, e.kana, e.width]
          })
          let flat_ws : Array[Int] = []
          for w in rw {
            flat_ws.push(w.0)
            flat_ws.push(w.1)
          }
          if decoded != expected || ws != flat_ws {
            fail(
              "\{name} ansi=\{ansi} U+\{u.to_string(radix=16)} in case \{checked}",
            )
          }
          checked += 1
        }
      }
    }
  }
  debug_inspect(checked, content="54208")
}

///|
/// `compare_linguistic` on packed elements against the reference, on all
/// pairs over a non-ASCII alphabet that exercises every level (accents,
/// case, kana, width, expansions, word sort, ignorables, surrogates).
test "packed compare agrees with the reference comparison" {
  let strings = all_strings(
    [
      "a",
      "\u{c1}",
      "\u{e0}",
      "\u{301}",
      "\u{df}",
      "S",
      "\u{c6}",
      "\u{153}",
      "\u{130}",
      "\u{131}",
      "\u{3a3}",
      "\u{3c2}",
      "\u{30a2}",
      "\u{3042}",
      "\u{ff41}",
      "\u{b2}",
      "-",
      " ",
      "\u{0}",
      "\u{1}",
      "\u{ad}",
      "\u{17d}",
      unit_string(0xD83D),
    ],
    2,
  )
  let mut mismatches = 0
  let mut checked = 0
  for name in element_test_collations {
    let c = Collation::parse(name).unwrap()
    for ansi in [false, true] {
      for a in strings {
        for b in strings {
          if compare_linguistic(a, b, 0, c, ansi) !=
            ref_compare_linguistic(a, b, c, ansi) {
            mismatches += 1
          }
          checked += 1
        }
      }
    }
  }
  debug_inspect((checked, mismatches), content="(4281326, 0)")
}
