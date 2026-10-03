///|
let fuzz_alphabet : Array[String] = [
  "1", "2024", "99999999999", "/", ":", ".", "-", "+", ",", " ", "\t", "T", "Z",
  "Jan", "PM", "x",
]

///|
fn fuzz_visit(prefix : String, depth : Int, f : (String) -> Unit) -> Unit {
  f(prefix)
  if depth > 0 {
    for a in fuzz_alphabet {
      fuzz_visit(prefix + a, depth - 1, f)
    }
  }
}

///|
test "date string parsing never aborts" {
  // every string of up to 4 tokens over an alphabet of date pieces, into
  // every temporal type under a few styles: errors are fine, an abort
  // would take the server down
  let types : Array[@types.SqlType] = [
    DateTime,
    SmallDateTime,
    Date,
    Time(7),
    DateTime2(7),
    DateTimeOffset(7),
  ]
  let mut parsed = 0
  fuzz_visit("", 4, text => {
    for t in types {
      for style in [0, 103, 112, 127] {
        try @types.cast(s(text), vc(), t, style~) catch {
          _ => ()
        } noraise {
          _ => parsed += 1
        }
      }
    }
  })
  assert_true(parsed > 0)
}
