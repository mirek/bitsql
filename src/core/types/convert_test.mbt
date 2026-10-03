///|
fn units(xs : Array[Int]) -> String {
  let sb = StringBuilder()
  for x in xs {
    sb.write_char(x.unsafe_to_char())
  }
  sb.to_string()
}

///|
fn short_outcome(
  v : @types.Value,
  from : @types.SqlType,
  to : @types.SqlType,
) -> String {
  try @types.cast(v, from, to) catch {
    e => "\{e.number()}/\{e.state()}"
  } noraise {
    TinyInt(n) | SmallInt(n) | Int(n) => n.to_string()
    BigInt(n) => n.to_string()
    other => "unexpected \{repr(other)}"
  }
}

///|
test "nvarchar to integer types match the capture" {
  // msduck reference/unicode-integer.json
  let targets : Array[@types.SqlType] = [TinyInt, SmallInt, Int, BigInt]
  for case_ in unicode_integer_cases {
    let (name, us, expected) = case_
    for i, t in targets {
      assert_eq(
        short_outcome(s(units(us)), nvc(), t),
        expected[i],
        msg="\{name} as \{t}",
      )
    }
  }
  // long inputs (same capture): 4000 units convert, 4001 hit 8152 even in
  // TRY_CAST
  let ok = String::make(3999, '0') + "7"
  assert_eq(short_outcome(s(ok), nvc(), Int), "7")
  let long = String::make(4000, '0') + "7"
  assert_eq(short_outcome(s(long), nvc(), Int), "8152/10")
  assert_eq(
    outcome(() => @types.try_cast(s(long), nvc(), Int)),
    "8152/10 String or binary data would be truncated.",
  )
  assert_eq(
    short_outcome(s(String::make(5000, ' ') + "7"), nvc(), TinyInt),
    "8152/10",
  )
}

///|
test "string to integer error texts" {
  // captured texts: msduck reference/unicode-integer.json, integer-overflow
  inspect(
    outcome(() => @types.cast(s("abc"), vc(), Int)),
    content="245/1 Conversion failed when converting the varchar value 'abc' to data type int.",
  )
  inspect(
    outcome(() => @types.cast(s("\t7\t"), nvc(), SmallInt)),
    content="245/1 Conversion failed when converting the nvarchar value '\t7\t' to data type smallint.",
  )
  inspect(
    outcome(() => @types.cast(s("2147483648"), vc(), Int)),
    content="248/1 The conversion of the varchar value '2147483648' overflowed an int column.",
  )
  inspect(
    outcome(() => @types.cast(s("256"), vc(), TinyInt)),
    content="244/1 The conversion of the varchar value '256' overflowed an INT1 column. Use a larger integer column.",
  )
  inspect(
    outcome(() => @types.cast(s("-32769"), vc(), SmallInt)),
    content="244/2 The conversion of the varchar value '-32769' overflowed an INT2 column. Use a larger integer column.",
  )
  inspect(
    outcome(() => @types.cast(s("x"), nvc(), BigInt)),
    content="8114/5 Error converting data type nvarchar to bigint.",
  )
  inspect(
    outcome(() => @types.cast(s("9223372036854775808"), nvc(), BigInt)),
    content="8115/2 Arithmetic overflow error converting expression to data type bigint.",
  )
  inspect(
    outcome(() => @types.try_cast(s("abc"), vc(), Int)),
    content="ok NULL",
  )
  inspect(outcome(() => @types.cast(@types.Null, vc(), Int)), content="ok NULL")
}

///|
test "numeric to integer: truncation and overflow" {
  assert_eq(short_outcome(dec("-2.9"), Decimal(5, 1), Int), "-2")
  assert_eq(short_outcome(dec("2.9"), Decimal(5, 1), Int), "2")
  assert_eq(short_outcome(@types.Float(-2.9), Float, Int), "-2")
  assert_eq(short_outcome(@types.Money(25000), Money, Int), "3")
  assert_eq(
    short_outcome(dec("2147483647.99"), Decimal(12, 2), Int),
    "2147483647",
  )
  inspect(
    outcome(() => @types.cast(dec("3000000000"), Numeric(10, 0), Int)),
    content=(
      #|8115/2 Arithmetic overflow error converting expression to data type int.
    ),
  )
  // captured: CAST(1e30 AS INT) → 232 state 3 (output-joined-runtime-errors.json)
  inspect(
    outcome(() => @types.cast(@types.Float(1.0e30), Float, Int)),
    content="232/3 Arithmetic overflow error for type int, value = 1000000000000000000000000000000.000000.",
  )
  inspect(
    outcome(() => @types.cast(@types.Int(256), Int, TinyInt)),
    content="220/1 Arithmetic overflow error for data type tinyint, value = 256.",
  )
  inspect(
    outcome(() => @types.cast(@types.BigInt(3000000000L), BigInt, Int)),
    content=(
      #|8115/2 Arithmetic overflow error converting expression to data type int.
    ),
  )
  inspect(
    outcome(() => @types.cast(@types.Int(-1), Int, TinyInt)),
    content="220/1 Arithmetic overflow error for data type tinyint, value = -1.",
  )
  assert_eq(outcome(() => @types.cast(@types.Int(5), Int, Bit)), "ok 1")
  assert_eq(outcome(() => @types.cast(s(" true "), vc(), Bit)), "ok 1")
  assert_eq(outcome(() => @types.cast(s("False"), vc(), Bit)), "ok 0")
  inspect(
    outcome(() => @types.cast(s("yes"), vc(), Bit)),
    content="245/1 Conversion failed when converting the varchar value 'yes' to data type bit.",
  )
}

///|
test "integers and decimals to text" {
  assert_eq(text_of(@types.Int(-42), Int), "-42")
  assert_eq(
    text_of(@types.BigInt(9223372036854775807L), BigInt),
    "9223372036854775807",
  )
  // too long: '*' for varchar, error for nvarchar (captured message)
  assert_eq(text_of(@types.Int(123), Int, to=vc(n=2)), "*")
  inspect(
    text_of(@types.Int(123), Int, to=nvc(n=2)),
    content="8115/2 Arithmetic overflow error converting expression to data type nvarchar.",
  )
  assert_eq(text_of(@types.Int(7), Int, to=@types.Char(3, coll)), "7  ")
  assert_eq(text_of(dec("-0.5"), Decimal(5, 2)), "-0.5")
  assert_eq(
    text_of(
      @types.cast(dec("-0.5"), Decimal(5, 1), Decimal(5, 2)) catch {
        _ => @types.Null
      },
      Decimal(5, 2),
    ),
    "-0.50",
  )
  inspect(
    text_of(dec("123.45"), Decimal(5, 2), to=vc(n=4)),
    content="8115/1 Arithmetic overflow error converting numeric to data type varchar.",
  )
  assert_eq(text_of(@types.Money(123456789), Money), "12345.68")
  assert_eq(text_of(@types.Money(123456789), Money, style=1), "12,345.68")
  assert_eq(text_of(@types.Money(123456789), Money, style=2), "12345.6789")
  assert_eq(
    text_of(@types.Money(-1234567890000), Money, style=1),
    "-123,456,789.00",
  )
  assert_eq(text_of(@types.Bit(true), Bit), "1")
  assert_eq(text_of(@types.Float(1234567.0), Float), "1.23457e+006")
  assert_eq(text_of(@types.Float(1234567.0), Float, style=1), "1.2345670e+006")
}

///|
test "decimal conversions: rounding vs truncation" {
  let d = fn(
    text : String,
    from : @types.SqlType,
    to : @types.SqlType,
  ) -> String {
    outcome(() => @types.cast(dec(text), from, to))
  }
  // decimal → smaller scale rounds half away from zero
  assert_eq(d("2.345", Decimal(5, 3), Decimal(5, 2)), "ok 2.35")
  assert_eq(d("-2.345", Decimal(5, 3), Decimal(5, 2)), "ok -2.35")
  assert_eq(d("2.344", Decimal(5, 3), Decimal(5, 2)), "ok 2.34")
  assert_eq(
    d("9.995", Decimal(5, 3), Decimal(3, 2)),
    "8115/8 Arithmetic overflow error converting numeric to data type numeric.",
  )
  assert_eq(
    d("1", Decimal(1, 0), Decimal(38, 37)),
    "ok 1.0000000000000000000000000000000000000",
  )
  assert_eq(
    outcome(() => @types.cast(@types.Int(100), Int, Decimal(2, 0))),
    "8115/1 Arithmetic overflow error converting int to data type numeric.",
  )
  // string → decimal (captured: 8114 state 5; 8115 state 8)
  inspect(
    outcome(() => @types.cast(s("not-a-number"), vc(), Numeric(10, 0))),
    content="8114/5 Error converting data type varchar to numeric.",
  )
  inspect(
    outcome(() => @types.cast(s("12345.6"), vc(), Decimal(5, 1))),
    content="8115/8 Arithmetic overflow error converting varchar to data type numeric.",
  )
  assert_eq(
    outcome(() => @types.cast(s(" 00012.3456 "), vc(), Decimal(6, 2))),
    "ok 12.35",
  )
  assert_eq(
    outcome(() => @types.cast(s("-.5"), vc(), Decimal(3, 1))),
    "ok -0.5",
  )
  inspect(
    outcome(() => @types.cast(s("1e2"), vc(), Decimal(5, 0))),
    content="8114/5 Error converting data type varchar to numeric.",
  )
  // float → decimal goes through 17 significant digits (unverified: SQL
  // Server may use the exact binary value 0.1000000000000000055511...)
  assert_eq(
    outcome(() => @types.cast(@types.Float(0.1), Float, Decimal(38, 20))),
    "ok 0.10000000000000001000",
  )
  assert_eq(
    outcome(() => @types.cast(@types.Float(2.5), Float, Decimal(5, 0))),
    "ok 3",
  )
}

///|
test "money conversions" {
  assert_eq(
    outcome(() => @types.cast(s("$1,234.56789"), vc(), Money)),
    "ok 1234.57",
  )
  inspect(
    outcome(() => @types.cast(s("214748.3648"), vc(), SmallMoney)),
    content="294/0 The conversion from char data type to smallmoney data type resulted in a smallmoney overflow error.",
  )
  inspect(
    outcome(() => @types.cast(@types.Float(1.0e300), Float, Money)),
    content="8115/2 Arithmetic overflow error converting expression to data type money.",
  )
  inspect(
    outcome(() => @types.cast(s("12x"), vc(), Money)),
    content="235/1 Cannot convert a char value to money. The char value has incorrect syntax.",
  )
}

///|
test "float conversions" {
  assert_eq(outcome(() => @types.cast(s(" 1e3 "), vc(), Float)), "ok 1000")
  inspect(
    outcome(() => @types.cast(s("abc"), vc(), Float)),
    content="8114/5 Error converting data type varchar to float.",
  )
  inspect(
    outcome(() => @types.cast(s("1e39"), vc(), Real)),
    content="8115/2 Arithmetic overflow error converting expression to data type real.",
  )
  assert_eq(
    outcome(() => @types.cast(dec("0.5"), Decimal(2, 1), Float)),
    "ok 0.5",
  )
  // real keeps binary32 precision
  match (try! @types.cast(@types.Float(0.1), Float, Real)) {
    Float(x) => assert_eq(x, Float::from_double(0.1).to_double())
    _ => fail("expected float")
  }
}

///|
test "character conversions" {
  // truncation without error, char padding
  assert_eq(text_of(s("hello"), vc(), to=vc(n=3)), "hel")
  assert_eq(text_of(s("hi"), vc(), to=@types.NChar(4, coll)), "hi  ")
  // Unicode → varchar: exact CP1252, then best fit, else '?' per UTF-16
  // unit (captured: msduck left-right-casts, cp1252_best_fit.mbt)
  assert_eq(text_of(s("caf\u{e9} \u{20ac}"), nvc(), to=vc()), "café €")
  assert_eq(text_of(s("\u{100}\u{142}e\u{301}"), nvc(), to=vc()), "Ale\u{b4}")
  assert_eq(text_of(s("\u{4e00}\u{1f986}"), nvc(), to=vc()), "???")
  // binary ↔ character
  let b = @types.Value::Binary(b"AB")
  assert_eq(text_of(b, VarBinary(None)), "AB")
  assert_eq(text_of(b, VarBinary(None), to=nvc()), "\u{4241}")
  assert_eq(text_of(b, VarBinary(None), style=1), "0x4142")
  assert_eq(text_of(b, VarBinary(None), style=2), "4142")
}

///|

///|
fn bin_of(
  v : @types.Value,
  from : @types.SqlType,
  to : @types.SqlType,
  style? : Int,
) -> String {
  try @types.cast(v, from, to, style?) catch {
    e => "\{e.number()}/\{e.state()} \{e.message()}"
  } noraise {
    Binary(_) as r =>
      @types.render(r, VarBinary(None), Some(1)) catch {
        _ => "?"
      }
    other => repr(other)
  }
}

///|
test "binary conversions" {
  assert_eq(bin_of(@types.Int(258), Int, VarBinary(None)), "0x00000102")
  assert_eq(bin_of(@types.Int(258), Int, Binary(2)), "0x0102")
  assert_eq(bin_of(@types.Int(258), Int, Binary(6)), "0x000000000102")
  assert_eq(bin_of(s("ab"), vc(), Binary(4)), "0x61620000")
  assert_eq(bin_of(s("ab"), nvc(), VarBinary(None)), "0x61006200")
  assert_eq(bin_of(s("0x0aFF"), vc(), VarBinary(None), style=1), "0x0AFF")
  assert_eq(bin_of(s("0aFF"), vc(), VarBinary(None), style=2), "0x0AFF")
  inspect(
    bin_of(s("0x0"), vc(), VarBinary(None), style=1),
    content="8114/5 Error converting data type varchar to varbinary.",
  )
  // binary → int takes the rightmost bytes
  assert_eq(
    outcome(() => {
      @types.cast(
        @types.Value::Binary(b"\x01\x00\x00\x00\xff"),
        VarBinary(None),
        TinyInt,
      )
    }),
    "ok 255",
  )
  assert_eq(
    outcome(() => {
      @types.cast(
        @types.Value::Binary(b"\xff\xff\xff\xff"),
        VarBinary(None),
        Int,
      )
    }),
    "ok -1",
  )
  // stored bytes of a legacy datetime (captured: '0000b0eb00011f41' for
  // 2024-01-02 00:04:05.123, temporal-guid-format.json)
  let dt = try! @types.cast(s("2024-01-02T00:04:05.123"), vc(), DateTime)
  assert_eq(bin_of(dt, DateTime, Binary(8)), "0x0000B0EB00011F41")
  let sdt = try! @types.cast(s("2024-01-02T00:04:05.123"), vc(), SmallDateTime)
  assert_eq(bin_of(sdt, SmallDateTime, Binary(4)), "0xB0EB0004")
}

///|
test "disallowed conversions raise 529 even in TRY_CAST" {
  inspect(
    outcome(() => @types.try_cast(@types.Date(0), Date, Int)),
    content="529/1 Explicit conversion from data type date to int is not allowed.",
  )
  inspect(
    outcome(() => @types.cast(@types.Int(1), Int, Date)),
    content="529/1 Explicit conversion from data type int to date is not allowed.",
  )
  inspect(
    outcome(() => @types.cast(@types.Date(0), Date, Time(7))),
    content="529/1 Explicit conversion from data type date to time is not allowed.",
  )
  inspect(
    outcome(() => @types.cast(@types.Int(1), Int, UniqueIdentifier)),
    content="529/1 Explicit conversion from data type int to uniqueidentifier is not allowed.",
  )
}
