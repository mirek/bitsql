///|
fn type_of_name(name : String) -> @types.SqlType {
  let scale = fn(prefix : String) -> Int {
    let digit = name[prefix.length() + 1].to_int() - '0'.to_int()
    digit
  }
  if name.has_prefix("TIME(") {
    Time(scale("TIME"))
  } else if name.has_prefix("DATETIME2(") {
    DateTime2(scale("DATETIME2"))
  } else if name.has_prefix("DATETIMEOFFSET(") {
    DateTimeOffset(scale("DATETIMEOFFSET"))
  } else if name == "DATE" {
    Date
  } else if name == "DATETIME" {
    DateTime
  } else if name == "SMALLDATETIME" {
    SmallDateTime
  } else {
    UniqueIdentifier
  }
}

///|
fn render_outcome(
  literal : String,
  ty : @types.SqlType,
  style : Int?,
) -> String {
  try {
    let v = @types.cast(s(literal), vc(), ty)
    @types.render(v, ty, style)
  } catch {
    e => "\{e.number()}/\{e.state()}"
  }
}

///|
test "temporal and guid text matches the capture" {
  // msduck reference/temporal-guid-format.json
  let failures = []
  for row in temporal_format_cases {
    let (name, literal, cast_text, style0, style121) = row
    let ty = type_of_name(name)
    for pair in [(None, cast_text), (Some(0), style0), (Some(121), style121)] {
      let got = render_outcome(literal, ty, pair.0)
      if got != pair.1 {
        failures.push(
          "\{name} '\{literal}' style \{repr_style(pair.0)}: got \{got}, expected \{pair.1}",
        )
      }
    }
  }
  assert_eq(failures, [])
  assert_eq(temporal_format_cases.length(), 162)
}

///|
fn repr_style(s : Int?) -> String {
  match s {
    Some(n) => n.to_string()
    None => "cast"
  }
}

///|
test "calendar round trip" {
  assert_eq(@types.days_from_civil(1, 1, 1), 0)
  assert_eq(@types.days_from_civil(1900, 1, 1), @types.DAYS_TO_1900)
  assert_eq(@types.days_from_civil(1753, 1, 1), @types.DAYS_TO_1753)
  assert_eq(@types.days_from_civil(9999, 12, 31), @types.MAX_DAYS)
  assert_eq(@types.days_from_civil(2079, 6, 6), @types.DAYS_TO_2079_06_06)
  for d in 0..<(@types.MAX_DAYS + 1) {
    if d % 997 == 0 || d == @types.MAX_DAYS {
      let (y, m, dd) = @types.civil_from_days(d)
      assert_eq(@types.days_from_civil(y, m, dd), d)
    }
  }
  assert_eq(
    @types.civil_from_days(@types.days_from_civil(2024, 2, 29)),
    (2024, 2, 29),
  )
  assert_false(@types.is_valid_date(2023, 2, 29))
  assert_true(@types.is_valid_date(2000, 2, 29))
  assert_false(@types.is_valid_date(1900, 2, 29))
}

///|
fn cast_text(literal : String, ty : @types.SqlType, style? : Int) -> String {
  @types.render(@types.cast(s(literal), vc(), ty), ty, style) catch {
    e => "\{e.number()}/\{e.state()} \{e.message()}"
  }
}

///|
test "datetime2 representation is exact 100ns ticks" {
  assert_eq(
    try! @types.cast(s("0001-01-01 00:00:00.0000001"), vc(), DateTime2(7)),
    @types.DateTime2(1L),
  )
  assert_eq(
    try! @types.cast(s("9999-12-31T23:59:59.9999999"), vc(), DateTime2(7)),
    @types.DateTime2(3_155_378_975_999_999_999L),
  )
  // half up at the declared scale; day carry
  assert_eq(
    cast_text("2024-02-29 23:59:59.95", DateTime2(1)),
    "2024-03-01 00:00:00.0",
  )
  assert_eq(
    cast_text("2024-02-29 23:59:59.96", DateTime2(1)),
    "2024-03-01 00:00:00.0",
  )
  assert_eq(
    cast_text("2024-02-29 23:59:59.94", DateTime2(1)),
    "2024-02-29 23:59:59.9",
  )
  inspect(
    cast_text("9999-12-31 23:59:59.9", DateTime2(0)),
    content="241/1 Conversion failed when converting date and/or time from character string.",
  )
}

///|
test "date/time string parsing" {
  assert_eq(cast_text("2024-01-02", Date), "2024-01-02")
  assert_eq(cast_text("20240102", Date), "2024-01-02")
  assert_eq(cast_text("2024-1-2", Date), "2024-01-02")
  assert_eq(cast_text("  2024-01-02  ", Date), "2024-01-02")
  assert_eq(cast_text("", Date), "1900-01-01")
  assert_eq(cast_text("12:30", Date), "1900-01-01")
  assert_eq(cast_text("12:30", DateTime2(0)), "1900-01-01 12:30:00")
  assert_eq(cast_text("2024-01-02", Time(0)), "00:00:00")
  assert_eq(cast_text("2024-01-02 7:05:06.5", Time(1)), "07:05:06.5")
  assert_eq(
    cast_text("2024-01-02T10:00:00Z", DateTimeOffset(0)),
    "2024-01-02 10:00:00 +00:00",
  )
  assert_eq(
    cast_text("2024-01-02 10:00:00 -05:00", DateTimeOffset(0)),
    "2024-01-02 10:00:00 -05:00",
  )
  assert_eq(
    cast_text("2024-01-02", DateTimeOffset(0)),
    "2024-01-02 00:00:00 +00:00",
  )
  // the offset is dropped for datetime2 (local clock kept)
  assert_eq(
    cast_text("2024-01-02 10:00:00+05:00", DateTime2(0)),
    "2024-01-02 10:00:00",
  )
  let invalid = "241/1 Conversion failed when converting date and/or time from character string."
  assert_eq(cast_text("2024-02-30", Date), invalid)
  assert_eq(cast_text("2023-02-29", DateTime2(0)), invalid)
  assert_eq(cast_text("2024-13-01", Date), invalid)
  assert_eq(cast_text("24:00", Time(0)), invalid)
  assert_eq(cast_text("12:60", Time(0)), invalid)
  assert_eq(cast_text("2024-01-02 +01:00", DateTimeOffset(7)), invalid)
  assert_eq(cast_text("2024-01-02 10:00 +15:00", DateTimeOffset(7)), invalid)
  assert_eq(cast_text("hello", Date), invalid)
  assert_eq(cast_text("2024-01-02 12:00:00.1234", DateTime), invalid)
  // captured (harness/corpus/datestrings): us_english / mdy forms
  assert_eq(
    cast_text("2024-01-02 12:00:00.12345678", DateTime2(7)),
    "2024-01-02 12:00:00.1234568",
  )
  assert_eq(cast_text("Jan 2 2024", Date), "2024-01-02")
  assert_eq(cast_text("01/02/2024", Date), "2024-01-02")
  assert_eq(cast_text("2024.01.02", Date), "2024-01-02")
  assert_eq(cast_text("02-01-2024", Date), "2024-02-01")
  assert_eq(cast_text("1/2/49", Date), "2049-01-02")
  assert_eq(cast_text("1/2/50", Date), "1950-01-02")
  assert_eq(cast_text("12:00 PM", Time(0)), "12:00:00")
  assert_eq(cast_text("12:00:00:123", Time(3)), "12:00:00.123")
  assert_eq(cast_text("10:11 1/2/2024", Date), invalid)
  assert_eq(
    cast_text("10:11 1/2/2024", DateTime, style=121),
    "2024-01-02 10:11:00.000",
  )
  let out_of_range = "242/3 The conversion of a varchar data type to a datetime data type resulted in an out-of-range value."
  assert_eq(cast_text("13/1/2024", DateTime), out_of_range)
  assert_eq(cast_text("1/2/123", DateTime), out_of_range)
  assert_eq(
    cast_text("garbage", SmallDateTime),
    "295/3 Conversion failed when converting character string to smalldatetime data type.",
  )
  // TRY_CAST: invalid → NULL
  assert_eq(
    outcome(() => @types.try_cast(s("2024-02-30"), vc(), Date)),
    "ok NULL",
  )
  assert_eq(
    outcome(() => @types.try_cast(s("2/30/2024"), vc(), DateTime)),
    "ok NULL",
  )
}

///|
/// CONVERT(ty, literal, style) rendered as CAST text.
fn conv_text(literal : String, ty : @types.SqlType, style : Int) -> String {
  @types.render(@types.cast(s(literal), vc(), ty, style~), ty, None) catch {
    e => "\{e.number()}/\{e.state()} \{e.message()}"
  }
}

///|
test "CONVERT styles from character strings" {
  assert_eq(conv_text("31/12/2024", Date, 103), "2024-12-31")
  assert_eq(conv_text("31.12.2024", DateTime, 104), "Dec 31 2024 12:00AM")
  assert_eq(conv_text("2024/12/31", Date, 111), "2024-12-31")
  assert_eq(conv_text("20241231", Date, 112), "2024-12-31")
  assert_eq(
    conv_text("12/31/2024", Date, 112),
    "9807/0 The input character string does not follow style 112, either change the input character string or use a different style.",
  )
  assert_eq(
    conv_text("12/31/2024", Date, 13),
    "50105/1 Emulator: CONVERT style 13 from character strings to date is not supported.",
  )
}

///|
test "datetimeoffset range uses both local and UTC instants" {
  // captured (temporal-guid-format.json): local min with +14:00 and local
  // max with -14:00 fail with 8114 state 31
  inspect(
    cast_text("0001-01-01T00:00:00.0000000+14:00", DateTimeOffset(7)),
    content="8114/31 Error converting data type varchar to datetimeoffset.",
  )
  inspect(
    cast_text("9999-12-31T23:59:59.9999999-14:00", DateTimeOffset(7)),
    content="8114/31 Error converting data type varchar to datetimeoffset.",
  )
  assert_eq(
    cast_text("0001-01-01T14:00:00.0000000+14:00", DateTimeOffset(7)),
    "0001-01-01 14:00:00.0000000 +14:00",
  )
  // stored as UTC ticks + offset
  assert_eq(
    try! @types.cast(s("0001-01-01T14:00:00+14:00"), vc(), DateTimeOffset(0)),
    @types.DateTimeOffset(0L, 840),
  )
}

///|
test "legacy datetime and smalldatetime rounding" {
  // captured (temporal-guid-format.json)
  assert_eq(
    cast_text("2024-01-02T03:04:05.001", DateTime, style=121),
    "2024-01-02 03:04:05.000",
  )
  assert_eq(
    cast_text("2024-01-02T03:04:05.002", DateTime, style=121),
    "2024-01-02 03:04:05.003",
  )
  assert_eq(
    cast_text("2024-01-02T03:04:05.005", DateTime, style=121),
    "2024-01-02 03:04:05.007",
  )
  assert_eq(
    cast_text("2024-02-29T23:59:59.998", DateTime, style=121),
    "2024-02-29 23:59:59.997",
  )
  assert_eq(
    cast_text("2024-02-29T23:59:59.999", DateTime, style=121),
    "2024-03-01 00:00:00.000",
  )
  assert_eq(
    cast_text("2024-02-29T23:59:29.998", SmallDateTime, style=121),
    "2024-02-29 23:59:00.000",
  )
  assert_eq(
    cast_text("2024-02-29T23:59:29.999", SmallDateTime, style=121),
    "2024-03-01 00:00:00.000",
  )
  inspect(
    cast_text("2079-06-06T23:59:59", SmallDateTime),
    content="242/3 The conversion of a varchar data type to a smalldatetime data type resulted in an out-of-range value.",
  )
  inspect(
    cast_text("1752-12-31", DateTime),
    content="242/3 The conversion of a varchar data type to a datetime data type resulted in an out-of-range value.",
  )
  // numbers → datetime count days from 1900-01-01
  let dt = fn(v : @types.Value, t : @types.SqlType) -> String {
    @types.render(@types.cast(v, t, DateTime), DateTime, Some(121)) catch {
      e => "\{e.number()}/\{e.state()} \{e.message()}"
    }
  }
  assert_eq(dt(@types.Int(1), Int), "1900-01-02 00:00:00.000")
  assert_eq(dt(@types.Float(-0.5), Float), "1899-12-31 12:00:00.000")
  assert_eq(dt(dec("1.25"), Decimal(3, 2)), "1900-01-02 06:00:00.000")
  inspect(
    dt(@types.Int(3000000), Int),
    content="8115/2 Arithmetic overflow error converting expression to data type datetime.",
  )
  // datetime → number
  let v = try! @types.cast(s("1900-01-02 18:00"), vc(), DateTime)
  assert_eq(outcome(() => @types.cast(v, DateTime, Int)), "ok 2")
  assert_eq(outcome(() => @types.cast(v, DateTime, Float)), "ok 1.75")
}

///|
test "temporal cross conversions" {
  let dt2 = try! @types.cast(
    s("2024-05-06 07:08:09.1234567"),
    vc(),
    DateTime2(7),
  )
  let r = fn(to : @types.SqlType) -> String {
    @types.render(@types.cast(dt2, DateTime2(7), to), to, None) catch {
      e => "\{e.number()}/\{e.state()} \{e.message()}"
    }
  }
  assert_eq(r(Date), "2024-05-06")
  assert_eq(r(Time(3)), "07:08:09.123")
  assert_eq(r(DateTime2(2)), "2024-05-06 07:08:09.12")
  assert_eq(r(DateTimeOffset(0)), "2024-05-06 07:08:09 +00:00")
  assert_eq(r(DateTime), "May  6 2024  7:08AM")
  let dto = try! @types.cast(
    s("2024-05-06 23:30:00 -02:00"),
    vc(),
    DateTimeOffset(0),
  )
  assert_eq(
    try! @types.render(
      @types.cast(dto, DateTimeOffset(0), DateTime2(0)),
      DateTime2(0),
      None,
    ),
    "2024-05-06 23:30:00",
  )
  assert_eq(
    try! @types.render(dto, DateTimeOffset(0), Some(127)),
    "2024-05-07T01:30:00Z",
  )
  let t = try! @types.cast(s("13:14:15.5"), vc(), Time(1))
  assert_eq(
    try! @types.render(
      @types.cast(t, Time(1), DateTime2(1)),
      DateTime2(1),
      None,
    ),
    "1900-01-01 13:14:15.5",
  )
}

///|
test "other CONVERT styles" {
  let v = try! @types.cast(s("2024-05-06 07:08:09.5"), vc(), DateTime)
  let st = fn(n : Int) -> String {
    @types.render(v, DateTime, Some(n)) catch {
      e => e.message()
    }
  }
  inspect(
    [
      1, 101, 2, 102, 3, 103, 4, 104, 5, 105, 10, 110, 11, 111, 12, 112, 23, 8, 108,
      20, 120, 126,
    ]
    .map(st)
    .join(" | "),
    content="05/06/24 | 05/06/2024 | 24.05.06 | 2024.05.06 | 06/05/24 | 06/05/2024 | 06.05.24 | 06.05.2024 | 06-05-24 | 06-05-2024 | 05-06-24 | 05-06-2024 | 24/05/06 | 2024/05/06 | 240506 | 20240506 | 2024-05-06 | 07:08:09 | 07:08:09 | 2024-05-06 07:08:09 | 2024-05-06 07:08:09 | 2024-05-06T07:08:09.500",
  )
  inspect(
    st(13),
    content="Emulator: CONVERT style 13 for datetime is not supported.",
  )
}
