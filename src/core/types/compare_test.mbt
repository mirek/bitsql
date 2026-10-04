///|
fn cmp(
  a : @types.Value,
  b : @types.Value,
  collation? : @types.Collation = @types.default_collation,
  ansi? : Bool = false,
) -> String {
  try @types.compare(a, b, collation~, ansi~) catch {
    e => "\{e.number()} \{e.message()}"
  } noraise {
    Some(c) => c.to_string()
    None => "unknown"
  }
}

///|
test "unicode collation comparisons match the capture" {
  // msduck reference/unicode-collation.json (140 comparisons)
  let failures = []
  for row in unicode_collation_cases {
    let (name, l, r, expected) = row
    let c = @types.Collation::parse(name).unwrap()
    let got = @types.compare_strings(units(l), units(r), c)
    if got != expected {
      failures.push(
        "\{name} \{l.map(x => x.to_string()).join(",")} vs \{r.map(x => x.to_string()).join(",")}: got \{got}, expected \{expected}",
      )
    }
  }
  assert_eq(failures, [])
  assert_eq(unicode_collation_cases.length(), 140)
}

///|
test "case, accent and padding rules" {
  let cs = @types.Collation::parse("Latin1_General_CS_AS").unwrap()
  let ai = @types.Collation::parse("SQL_Latin1_General_CP1_CI_AI").unwrap()
  let bin2 = @types.latin1_general_100_bin2
  assert_eq(cmp(s("abc"), s("ABC  ")), "0")
  assert_eq(cmp(s("abc"), s("ABD")), "-1")
  assert_eq(cmp(s("abc"), s("ABC"), collation=cs), "-1")
  assert_eq(cmp(s("ÀÉÎÕÜ"), s("àéîõü")), "0")
  assert_eq(cmp(s("ÀÉÎÕÜ"), s("aeiou")), "1")
  assert_eq(cmp(s("ÀÉÎÕÜ"), s("aeiou"), collation=ai), "0")
  assert_eq(cmp(s("Łódź"), s("lodz"), collation=ai), "0")
  assert_eq(cmp(s("Łódź"), s("ŁÓDŹ")), "0")
  assert_eq(cmp(s("résumé"), s("resume")), "1")
  assert_eq(cmp(s("resume"), s("résumé")), "-1")
  assert_eq(cmp(s("Straße"), s("STRASSE")), "0")
  assert_eq(cmp(s("b"), s("á")), "1")
  assert_eq(cmp(s("Z"), s("a")), "1")
  assert_eq(cmp(s("10"), s("9")), "-1")
  assert_eq(cmp(s("a"), s("1")), "1")
  assert_eq(cmp(s(""), s("   ")), "0")
  // BIN2: code units, space padding
  assert_eq(cmp(s("B"), s("a"), collation=bin2), "-1")
  assert_eq(cmp(s("a"), s("a  "), collation=bin2), "0")
  assert_eq(cmp(s("a"), s("a\u{0}"), collation=bin2), "1")
  // word sort for Unicode / Windows collations; string sort for varchar
  // under SQL_ collations
  assert_eq(cmp(s("ab"), s("a-c")), "-1")
  assert_eq(cmp(s("ab"), s("a-c"), ansi=true), "1")
  assert_eq(cmp(s("coop"), s("co-op")), "-1")
  assert_eq(cmp(s("co-op"), s("coop"), ansi=true), "-1")
}

///|
test "three-valued comparison of values" {
  assert_eq(cmp(@types.Null, @types.Int(1)), "unknown")
  assert_eq(cmp(@types.Int(1), @types.Null), "unknown")
  assert_eq(cmp(@types.Int(2), @types.BigInt(10L)), "-1")
  assert_eq(cmp(dec("1.50"), dec("1.5")), "0")
  assert_eq(cmp(dec("1.5"), @types.Int(1)), "1")
  assert_eq(cmp(@types.Money(15000), dec("1.5")), "0")
  assert_eq(cmp(@types.Float(1.5), dec("1.5")), "0")
  assert_eq(cmp(@types.Bit(true), @types.Int(1)), "0")
  assert_eq(try! @types.sql_equal(s("A"), s("a ")), Some(true))
  // temporal: datetimeoffset compares instants
  let dto = fn(text : String) -> @types.Value {
    try! @types.cast(s(text), vc(), DateTimeOffset(7))
  }
  assert_eq(
    cmp(dto("2024-01-01 10:00 +02:00"), dto("2024-01-01 08:00 +00:00")),
    "0",
  )
  assert_eq(
    cmp(dto("2024-01-01 10:00 +02:00"), dto("2024-01-01 09:00 +00:00")),
    "-1",
  )
  let d2 = try! @types.cast(
    s("2024-01-01 00:00:00.0033333"),
    vc(),
    DateTime2(7),
  )
  let dt = try! @types.cast(s("2024-01-01 00:00:00.003"), vc(), DateTime)
  let day = try! @types.cast(s("2024-01-01"), vc(), Date)
  assert_eq(cmp(dt, d2), "1")
  assert_eq(cmp(day, dt), "-1")
  assert_eq(
    cmp(@types.Value::Binary(b"\x01"), @types.Value::Binary(b"\x01\x00")),
    "0",
  )
  assert_eq(
    cmp(@types.Value::Binary(b"\x01"), @types.Value::Binary(b"\x01\x01")),
    "-1",
  )
  inspect(
    cmp(@types.Int(1), s("1")),
    content="50199 Emulator: incomparable values",
  )
}

///|
test "uniqueidentifier text, bytes and ordering" {
  // msduck reference/guid-conversion-order.json
  let cases = [
    ("zero", "00000000-0000-0000-0000-000000000000"),
    ("first_low", "00000001-0000-0000-0000-000000000000"),
    ("first_high", "01000000-0000-0000-0000-000000000000"),
    ("second_low", "00000000-0001-0000-0000-000000000000"),
    ("second_high", "00000000-0100-0000-0000-000000000000"),
    ("third_low", "00000000-0000-0001-0000-000000000000"),
    ("third_high", "00000000-0000-0100-0000-000000000000"),
    ("fourth_low", "00000000-0000-0000-0001-000000000000"),
    ("fourth_high", "00000000-0000-0000-0100-000000000000"),
    ("last", "00000000-0000-0000-0000-000000000001"),
    ("last_high", "00000000-0000-0000-0000-010000000000"),
    ("max", "ffffffff-ffff-ffff-ffff-ffffffffffff"),
  ]
  let guids = cases.map(c => {
    (c.0, try! @types.cast(s(c.1), vc(), UniqueIdentifier))
  })
  let sorted = guids.copy()
  sorted.sort_by((x, y) => try! @types.compare(x.1, y.1).unwrap())
  assert_eq(
    sorted.map(x => x.0).join(","),
    "zero,first_high,first_low,second_high,second_low,third_high,third_low,fourth_low,fourth_high,last,last_high,max",
  )
  // storage bytes (CONVERT(binary(16), g)), captured
  let bytes = fn(label : String) -> String {
    for g in guids {
      if g.0 == label {
        return bin_of(g.1, UniqueIdentifier, Binary(16))
      }
    }
    ""
  }
  assert_eq(bytes("first_high"), "0x00000001000000000000000000000000")
  assert_eq(bytes("second_low"), "0x00000000010000000000000000000000")
  assert_eq(bytes("fourth_high"), "0x00000000000000000100000000000000")
  assert_eq(bytes("last_high"), "0x00000000000000000000010000000000")
  // text: uppercase canonical (captured)
  assert_eq(
    text_of(
      try! @types.cast(
        s("6f9619ff-8b86-d011-b42d-00c04fc964ff"),
        vc(),
        UniqueIdentifier,
      ),
      UniqueIdentifier,
    ),
    "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  )
  // character parsing rules (guid-character-conversion.json)
  let g = fn(text : String) -> String {
    outcome(() => @types.cast(s(text), vc(), UniqueIdentifier))
  }
  let ok = "ok 6F9619FF-8B86-D011-B42D-00C04FC964FF"
  assert_eq(g("6F9619FF-8B86-D011-B42D-00C04FC964FFEXTRA"), ok)
  assert_eq(g("{6F9619FF-8B86-D011-B42D-00C04FC964FF}"), ok)
  assert_eq(g("{6F9619FF-8B86-D011-B42D-00C04FC964FF}tail"), ok)
  assert_eq(g("6F9619FF-8B86-D011-B42D-00C04FC964FF  "), ok)
  let bad = "8169/2 Conversion failed when converting from a character string to uniqueidentifier."
  assert_eq(g(" 6F9619FF-8B86-D011-B42D-00C04FC964FF"), bad)
  assert_eq(g("{6F9619FF-8B86-D011-B42D-00C04FC964FF"), bad)
  assert_eq(g("6F9619FF8B86D011B42D00C04FC964FF"), bad)
  assert_eq(g("6F9619FF-8B86-D011-B42D-00C04FC964F"), bad)
  assert_eq(g(""), bad)
  assert_eq(
    outcome(() => @types.try_cast(s("nope"), vc(), UniqueIdentifier)),
    "ok NULL",
  )
  inspect(
    text_of(guids[0].1, UniqueIdentifier, to=vc(n=10)),
    content="8170/1 Insufficient result space to convert uniqueidentifier value to char.",
  )
}

///|
test "collation names" {
  let names = [
    "SQL_Latin1_General_CP1_CI_AS", "sql_latin1_general_cp1_cs_as", "Latin1_General_CI_AS",
    "Latin1_General_100_CI_AS_KS_WS", "Latin1_General_100_CI_AS_SC", "Latin1_General_BIN",
    "Latin1_General_100_BIN2", "Latin1_General_140_CS_AI", "French_CI_AS", "Latin1_General_100_CI_AS_SC_UTF8",
  ]
  inspect(
    names
    .map(n => {
      match @types.Collation::parse(n) {
        Some(c) => c.name
        None => "-"
      }
    })
    .join(" "),
    content=(
      #|SQL_Latin1_General_CP1_CI_AS SQL_Latin1_General_CP1_CS_AS Latin1_General_CI_AS Latin1_General_100_CI_AS_KS_WS Latin1_General_100_CI_AS_SC Latin1_General_BIN Latin1_General_100_BIN2 Latin1_General_140_CS_AI - Latin1_General_100_CI_AS_SC_UTF8
    ),
  )
}
